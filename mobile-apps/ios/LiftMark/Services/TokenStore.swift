import Foundation
import Security

/// Keychain wrapper for the LMWF access + refresh tokens.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — per-device so
/// signing in on Mac doesn't surprise an iPhone session. Keychain errors
/// are swallowed and logged; the only "expected" error is errSecItemNotFound
/// on first read, which simply returns nil.
final class TokenStore: @unchecked Sendable {
    private let service: String
    private let accessAccount = "access_token"
    private let refreshAccount = "refresh_token"

    init(service: String = "app.liftmark.auth") {
        self.service = service
    }

    // MARK: - Save

    func saveAccessToken(_ token: String) {
        store(token, account: accessAccount)
    }

    func saveRefreshToken(_ token: String) {
        store(token, account: refreshAccount)
    }

    /// Persist a rotated access + refresh pair, writing the **refresh token
    /// first**. After `/v1/auth/refresh` rotates, the refresh token is the
    /// durable proof of session: if the app is killed mid-write, we want the
    /// *new* refresh token on disk (so a relaunch never re-presents the
    /// consumed one). Writing refresh-before-access guarantees that ordering.
    func saveTokens(access: String, refresh: String) {
        store(refresh, account: refreshAccount)
        store(access, account: accessAccount)
    }

    // MARK: - Load

    func loadAccessToken() -> String? {
        load(account: accessAccount)
    }

    func loadRefreshToken() -> String? {
        load(account: refreshAccount)
    }

    // MARK: - Clear

    func clear() {
        delete(account: accessAccount)
        delete(account: refreshAccount)
    }

    // MARK: - Private

    private func store(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else {
            Logger.shared.error(.network, "TokenStore encode failed for \(account)")
            return
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            Logger.shared.warn(.network, "TokenStore update returned status \(updateStatus); falling back to add")
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Logger.shared.error(.network, "TokenStore add failed for \(account) status=\(addStatus)")
        }
    }

    private func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            Logger.shared.warn(.network, "TokenStore load failed for \(account) status=\(status)")
            return nil
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Logger.shared.warn(.network, "TokenStore delete failed for \(account) status=\(status)")
        }
    }
}
