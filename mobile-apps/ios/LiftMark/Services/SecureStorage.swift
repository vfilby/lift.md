import Foundation
import Security

// MARK: - SecureStorage

enum SecureStorage {

    private static let serviceName = "com.liftmark.app"
    /// Pre-BYOK single Anthropic key. Read once by `AIKeyStore` to migrate into
    /// the provider list, then deleted. See spec/services/ai-providers.md.
    private static let legacyAnthropicKeyAccount = "anthropic_api_key"

    // MARK: - Legacy Anthropic Key

    /// Retrieves the legacy Anthropic API key, if one is still stored.
    static func getLegacyAnthropicApiKey() -> String? {
        retrieve(key: legacyAnthropicKeyAccount)
    }

    /// Removes the legacy Anthropic API key. A missing item is not an error.
    static func removeLegacyAnthropicApiKey() throws {
        try delete(key: legacyAnthropicKeyAccount)
    }

    // MARK: - Generic Keychain Access

    /// Store arbitrary string data in the Keychain.
    static func store(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecureStorageError.encodingFailed
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStorageError.storageFailed(status)
        }
    }

    /// Retrieve arbitrary string data from the Keychain.
    static func retrieve(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Delete arbitrary data from the Keychain.
    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStorageError.deletionFailed(status)
        }
    }
}

// MARK: - Errors

enum SecureStorageError: LocalizedError {
    case encodingFailed
    case storageFailed(OSStatus)
    case deletionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode data for secure storage."
        case .storageFailed(let status):
            return "Failed to store data in Keychain (status: \(status))."
        case .deletionFailed(let status):
            return "Failed to remove data from Keychain (status: \(status))."
        }
    }
}
