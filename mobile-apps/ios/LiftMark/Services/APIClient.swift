import Foundation

// MARK: - Errors

enum APIError: Error {
    case unauthorized
    case forbidden(message: String?)
    /// A 403 (or similar) produced at the edge — CloudFront/WAF — that never
    /// reached our API. These carry an HTML body, not our `{"error": "..."}`
    /// JSON. Transient/infra, NOT a permanent client error, so callers must
    /// retry rather than treat it as terminal.
    case edgeBlocked(status: Int)
    case notFound
    case conflict(message: String?)
    case server(status: Int, message: String?)
    case decoding(Error)
    case transport(Error)
}

// MARK: - Protocol

/// Behavioral abstraction over the LMWF HTTP API. The real client uses
/// URLSession; tests inject a mock. AuthenticationStore depends only on
/// this protocol so it can be exercised without a real network.
protocol APIClientProtocol: AnyObject, Sendable {
    func send<Req: Encodable, Res: Decodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws -> Res

    func sendEmpty<Req: Encodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws

    /// Send a pre-serialized JSON body. Used when the body is a
    /// `[String: Any]` (e.g. the WorkoutExportService payload reused by the
    /// outbox push) and a Swift Encodable wrapper would force a needless
    /// re-encoding round trip.
    func sendData<Res: Decodable>(
        path: String,
        method: String,
        bodyData: Data,
        accessToken: String?
    ) async throws -> Res
}

// MARK: - APIClient

/// Minimal URLSession-based JSON HTTP client for the LMWF API. Snake-case
/// in/out. Maps HTTP status codes to `APIError`. No retry/refresh logic —
/// `AuthenticationStore` owns the refresh-on-401 dance.
final class APIClient: APIClientProtocol, @unchecked Sendable {
    /// Hard-coded base URL (test injection / `LMWF_API_BASE_URL` plist
    /// override). When nil, `currentBaseURL()` consults the
    /// `feature_flag.useBetaApi` UserDefaults key per request so a runtime
    /// flag flip takes effect on the very next call without rebuilding
    /// the client. See `spec/services/feature-flags.md`.
    private let staticBaseURL: URL?
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter baseURL: Hard-override. When nil, the client reads (in
    ///   priority order) the `--api-base-url=<url>` launch argument (test-only,
    ///   see spec/services/ios-e2e-beta.md) and then `LMWF_API_BASE_URL` from
    ///   Info.plist — both hard-overrides — and otherwise resolves prod vs beta
    ///   per request from the `feature_flag.useBetaApi` UserDefaults key.
    ///   Default off → prod.
    init(baseURL: URL? = nil, session: URLSession = .shared) {
        if let baseURL {
            self.staticBaseURL = baseURL
        } else if let argURL = Self.launchArgBaseURL() {
            self.staticBaseURL = argURL
        } else if let plistValue = Bundle.main.object(forInfoDictionaryKey: "LMWF_API_BASE_URL") as? String,
                  let url = URL(string: plistValue) {
            self.staticBaseURL = url
        } else {
            self.staticBaseURL = nil
        }
        self.session = session

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Server emits ISO8601 with fractional seconds (e.g.
        // "2026-06-22T16:06:20.659Z"). The default .iso8601 strategy
        // rejects fractional seconds, so handle both forms manually.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let string = try dateDecoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: string) ?? plain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try dateDecoder.singleValueContainer(),
                debugDescription: "Not an ISO8601 date: \(string)"
            )
        }
        self.decoder = decoder
    }

    /// Parse the test-only `--api-base-url=<url>` launch argument. Lets the
    /// Layer-3 beta e2e plan point the client at the deployed beta backend for
    /// the test process only, without touching the production beta-mode toggle.
    /// See spec/services/ios-e2e-beta.md.
    private static func launchArgBaseURL() -> URL? {
        let prefix = "--api-base-url="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return URL(string: String(arg.dropFirst(prefix.count)))
    }

    func send<Req: Encodable, Res: Decodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws -> Res {
        let (data, _) = try await perform(path: path, method: method, body: body, accessToken: accessToken)
        do {
            return try decoder.decode(Res.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    func sendEmpty<Req: Encodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws {
        _ = try await perform(path: path, method: method, body: body, accessToken: accessToken)
    }

    func sendData<Res: Decodable>(
        path: String,
        method: String,
        bodyData: Data,
        accessToken: String?
    ) async throws -> Res {
        let (data, _) = try await performRaw(
            path: path, method: method, bodyData: bodyData, accessToken: accessToken
        )
        do {
            return try decoder.decode(Res.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: - Private

    /// Resolves the base URL for the *next* request. Reads the
    /// `useBetaApi` feature flag from UserDefaults so a toggle in
    /// Settings is honored on the very next API call. The hard-coded
    /// override (constructor / Info.plist) still wins when set —
    /// production builds always hit prod by default.
    private func currentBaseURL() -> URL {
        if let staticBaseURL { return staticBaseURL }
        // Flag absent → prod; flag set → use whatever it says.
        let useBeta: Bool
        if UserDefaults.standard.object(forKey: "feature_flag.useBetaApi") != nil {
            useBeta = UserDefaults.standard.bool(forKey: "feature_flag.useBetaApi")
        } else {
            useBeta = false
        }
        return useBeta
            // Canonical beta host (GH #248 beta cutover is live). beta.liftmark.app
            // now 308-redirects /v1/* here, but we target beta.getlift.md directly
            // to skip the hop.
            ? URL(string: "https://beta.getlift.md")!
            // Canonical prod host (GH #248). liftmark.app now 308-redirects
            // /v1/* here, but we target getlift.md directly to skip the hop.
            : URL(string: "https://getlift.md")!
    }

    private func perform<Req: Encodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = currentBaseURL().appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw APIError.decoding(error)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            throw APIError.unauthorized
        case 403:
            throw Self.forbiddenError(from: data)
        case 404:
            throw APIError.notFound
        case 409:
            throw APIError.conflict(message: Self.errorMessage(from: data))
        default:
            throw APIError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
    }

    private func performRaw(
        path: String,
        method: String,
        bodyData: Data,
        accessToken: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = currentBaseURL().appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            throw APIError.unauthorized
        case 403:
            throw Self.forbiddenError(from: data)
        case 404:
            throw APIError.notFound
        case 409:
            throw APIError.conflict(message: Self.errorMessage(from: data))
        default:
            throw APIError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? String
    }

    /// Disambiguate a 403 from our API vs. one injected at the edge.
    ///
    /// Our API's 403s ALWAYS carry a JSON `{"error": "..."}` body (scope/quota
    /// rejections). A CloudFront/WAF block returns a 403 with an HTML body and
    /// never reaches our API — those have no JSON `error` field. The former is a
    /// permanent client error; the latter is transient infra that must be
    /// retried, so map them to distinct cases.
    private static func forbiddenError(from data: Data) -> APIError {
        if let message = errorMessage(from: data) {
            return .forbidden(message: message)
        }
        return .edgeBlocked(status: 403)
    }
}

// MARK: - Empty Body Helper

/// Use as the `Req` generic when sending GET/DELETE with no body.
/// Pass `nil` for the `body` parameter — the type is just there to satisfy
/// the generic constraint.
struct EmptyBody: Encodable {}
