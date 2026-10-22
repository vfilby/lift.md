import Foundation
import SwiftUI

// MARK: - Storage

/// Backing store for the BYOK key list. Production uses the Keychain; tests inject memory.
protocol AIKeyStorage: Sendable {
    func loadList() -> String?
    func saveList(_ json: String) throws
    func deleteList() throws
    func legacyAnthropicKey() -> String?
    func removeLegacyAnthropicKey() throws
}

struct KeychainAIKeyStorage: AIKeyStorage {
    static let account = "ai_provider_keys"

    func loadList() -> String? { SecureStorage.retrieve(key: Self.account) }
    func saveList(_ json: String) throws { try SecureStorage.store(key: Self.account, value: json) }
    func deleteList() throws { try SecureStorage.delete(key: Self.account) }
    func legacyAnthropicKey() -> String? { SecureStorage.getLegacyAnthropicApiKey() }
    func removeLegacyAnthropicKey() throws { try SecureStorage.removeLegacyAnthropicApiKey() }
}

// MARK: - AIKeyStore

/// The user's ordered list of BYOK provider keys. Order is generation fallback order.
/// Mutations persist first and only update in-memory state on success.
/// See spec/services/ai-providers.md.
@MainActor
@Observable
final class AIKeyStore {
    private(set) var keys: [AIProviderKey] = []
    private(set) var lastError: Error?
    private let storage: AIKeyStorage

    init(storage: AIKeyStorage = KeychainAIKeyStorage()) {
        self.storage = storage
    }

    /// At least one key generation may use (anything not marked invalid).
    var hasUsableKey: Bool {
        keys.contains { $0.status != .invalid }
    }

    // MARK: - Load / Migrate

    /// Load the list, migrating a pre-BYOK Anthropic key on first run.
    /// `legacyAnthropicStatus` is `user_settings.anthropic_api_key_status`.
    func load(legacyAnthropicStatus: ApiKeyStatus?) {
        if let json = storage.loadList() {
            do {
                keys = try JSONDecoder().decode([AIProviderKey].self, from: Data(json.utf8))
            } catch {
                keys = []
                record(error, "Failed to decode AI provider key list")
            }
            // Best-effort cleanup of a legacy item left by an interrupted migration.
            if storage.legacyAnthropicKey() != nil { try? storage.removeLegacyAnthropicKey() }
            return
        }
        guard let legacy = storage.legacyAnthropicKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !legacy.isEmpty else {
            keys = []
            return
        }
        let migrated = AIProviderKey(
            provider: .anthropic,
            apiKey: legacy,
            status: legacyAnthropicStatus == .verified ? .verified : .unverified
        )
        do {
            try persist([migrated])
            keys = [migrated]
            try storage.removeLegacyAnthropicKey()
            Logger.shared.info(.app, "Migrated legacy Anthropic API key into AI provider list")
        } catch {
            // Leave the legacy item in place; migration retries next launch.
            keys = [migrated]
            record(error, "Failed to migrate legacy Anthropic API key")
        }
    }

    // MARK: - Mutations

    /// Insert a new key at the end, or replace an existing one in place (matched by id).
    func save(_ key: AIProviderKey) throws {
        var updated = keys
        if let index = updated.firstIndex(where: { $0.id == key.id }) {
            updated[index] = key
        } else {
            updated.append(key)
        }
        try commit(updated)
    }

    func remove(id: String) {
        tryCommit(keys.filter { $0.id != id }, "Failed to remove AI provider key")
    }

    func remove(atOffsets offsets: IndexSet) {
        var updated = keys
        updated.remove(atOffsets: offsets)
        tryCommit(updated, "Failed to remove AI provider key")
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var updated = keys
        updated.move(fromOffsets: source, toOffset: destination)
        tryCommit(updated, "Failed to reorder AI provider keys")
    }

    func moveUp(id: String) {
        guard let index = keys.firstIndex(where: { $0.id == id }), index > 0 else { return }
        var updated = keys
        updated.swapAt(index, index - 1)
        tryCommit(updated, "Failed to reorder AI provider keys")
    }

    func moveDown(id: String) {
        guard let index = keys.firstIndex(where: { $0.id == id }), index < keys.count - 1 else { return }
        var updated = keys
        updated.swapAt(index, index + 1)
        tryCommit(updated, "Failed to reorder AI provider keys")
    }

    /// Apply status changes reported by `AIProviderService.generateWorkout(prompt:keys:)`.
    func apply(statusUpdates: [String: AIKeyStatus]) {
        guard !statusUpdates.isEmpty else { return }
        let updated = keys.map { key -> AIProviderKey in
            guard let status = statusUpdates[key.id] else { return key }
            var changed = key
            changed.status = status
            return changed
        }
        tryCommit(updated, "Failed to update AI provider key status")
    }

    /// Delete the persisted list (UI-test `--reset-data`).
    nonisolated static func clearPersisted(storage: AIKeyStorage = KeychainAIKeyStorage()) {
        try? storage.deleteList()
    }

    // MARK: - Persistence

    private func commit(_ updated: [AIProviderKey]) throws {
        try persist(updated)
        keys = updated
        lastError = nil
    }

    private func tryCommit(_ updated: [AIProviderKey], _ message: String) {
        do {
            try commit(updated)
        } catch {
            record(error, message)
        }
    }

    private func persist(_ list: [AIProviderKey]) throws {
        let data = try JSONEncoder().encode(list)
        guard let json = String(bytes: data, encoding: .utf8) else { throw SecureStorageError.encodingFailed }
        try storage.saveList(json)
    }

    private func record(_ error: Error, _ message: String) {
        lastError = error
        Logger.shared.error(.app, message, error: error)
    }
}
