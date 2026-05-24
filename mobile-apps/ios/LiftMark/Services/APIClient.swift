import Foundation

// MARK: - Errors

enum APIError: Error {
    case unauthorized
    case forbidden(message: String?)
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
}

// MARK: - APIClient

/// Minimal URLSession-based JSON HTTP client for the LMWF API. Snake-case
/// in/out. Maps HTTP status codes to `APIError`. No retry/refresh logic —
/// `AuthenticationStore` owns the refresh-on-401 dance.
final class APIClient: APIClientProtocol, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter baseURL: Override; if nil, reads `LMWF_API_BASE_URL` from
    ///   Info.plist, otherwise defaults to the beta host (DEBUG) or the prod
    ///   host (RELEASE). NOTE: prod still points at beta until migration
    ///   completes — adjust the RELEASE default when prod is live.
    init(baseURL: URL? = nil, session: URLSession = .shared) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let plistValue = Bundle.main.object(forInfoDictionaryKey: "LMWF_API_BASE_URL") as? String,
                  let url = URL(string: plistValue) {
            self.baseURL = url
        } else {
            #if DEBUG
            self.baseURL = URL(string: "https://beta.liftmark.app")!
            #else
            // TODO: switch to https://liftmark.app once prod migration ships.
            self.baseURL = URL(string: "https://beta.liftmark.app")!
            #endif
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
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: s) ?? plain.date(from: s) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try d.singleValueContainer(),
                debugDescription: "Not an ISO8601 date: \(s)"
            )
        }
        self.decoder = decoder
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

    // MARK: - Private

    private func perform<Req: Encodable>(
        path: String,
        method: String,
        body: Req?,
        accessToken: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
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
            throw APIError.forbidden(message: Self.errorMessage(from: data))
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
}

// MARK: - Empty Body Helper

/// Use as the `Req` generic when sending GET/DELETE with no body.
/// Pass `nil` for the `body` parameter — the type is just there to satisfy
/// the generic constraint.
struct EmptyBody: Encodable {}
