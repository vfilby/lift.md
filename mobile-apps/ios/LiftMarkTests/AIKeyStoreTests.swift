import XCTest
@testable import LiftMark

/// In-memory `AIKeyStorage` so store tests never touch the real Keychain.
final class MemoryAIKeyStorage: AIKeyStorage, @unchecked Sendable {
    var list: String?
    var legacy: String?
    var failSaves = false
    var failLegacyRemoval = false
    private(set) var saveCount = 0

    struct Failure: Error {}

    init(list: String? = nil, legacy: String? = nil) {
        self.list = list
        self.legacy = legacy
    }

    func loadList() -> String? { list }
    func saveList(_ json: String) throws {
        if failSaves { throw Failure() }
        saveCount += 1
        list = json
    }
    func deleteList() throws { list = nil }
    func legacyAnthropicKey() -> String? { legacy }
    func removeLegacyAnthropicKey() throws {
        if failLegacyRemoval { throw Failure() }
        legacy = nil
    }

    func decoded() throws -> [AIProviderKey] {
        try JSONDecoder().decode([AIProviderKey].self, from: Data(XCTUnwrap(list).utf8))
    }
}

@MainActor
final class AIKeyStoreTests: XCTestCase {

    private func key(
        _ id: String, _ provider: AIProvider = .openai, _ status: AIKeyStatus = .verified
    ) -> AIProviderKey {
        AIProviderKey(id: id, provider: provider, apiKey: "k-\(id)", status: status)
    }

    private func makeStore(_ keys: [AIProviderKey]) throws -> (AIKeyStore, MemoryAIKeyStorage) {
        let json = String(bytes: try JSONEncoder().encode(keys), encoding: .utf8)
        let storage = MemoryAIKeyStorage(list: json)
        let store = AIKeyStore(storage: storage)
        store.load(legacyAnthropicStatus: nil)
        return (store, storage)
    }

    // MARK: - Load / persistence

    func testLoadEmpty() {
        let store = AIKeyStore(storage: MemoryAIKeyStorage())
        store.load(legacyAnthropicStatus: nil)
        XCTAssertEqual(store.keys, [])
        XCTAssertFalse(store.hasUsableKey)
    }

    func testSaveAppendsAndPersists() throws {
        let (store, storage) = try makeStore([])
        try store.save(key("1"))
        try store.save(key("2", .gemini))
        XCTAssertEqual(store.keys.map(\.id), ["1", "2"])
        XCTAssertEqual(try storage.decoded(), store.keys)

        let reloaded = AIKeyStore(storage: storage)
        reloaded.load(legacyAnthropicStatus: nil)
        XCTAssertEqual(reloaded.keys, store.keys, "round-trips through storage")
    }

    func testSaveExistingIdUpdatesInPlace() throws {
        let (store, _) = try makeStore([key("1"), key("2"), key("3")])
        var edited = key("2", .ollama, .unverified)
        edited.model = "qwen2.5:0.5b"
        try store.save(edited)
        XCTAssertEqual(store.keys.map(\.id), ["1", "2", "3"], "edit keeps position")
        XCTAssertEqual(store.keys[1].provider, .ollama)
        XCTAssertEqual(store.keys[1].model, "qwen2.5:0.5b")
    }

    func testFailedPersistLeavesStateUnchanged() throws {
        let (store, storage) = try makeStore([key("1")])
        storage.failSaves = true
        XCTAssertThrowsError(try store.save(key("2")))
        XCTAssertEqual(store.keys.map(\.id), ["1"])
        store.remove(id: "1")
        XCTAssertEqual(store.keys.map(\.id), ["1"])
        XCTAssertNotNil(store.lastError)
    }

    func testCorruptListLoadsEmptyAndRecordsError() {
        let store = AIKeyStore(storage: MemoryAIKeyStorage(list: "not json"))
        store.load(legacyAnthropicStatus: nil)
        XCTAssertEqual(store.keys, [])
        XCTAssertNotNil(store.lastError)
    }

    func testLoadCleansUpLegacyLeftOverFromInterruptedMigration() throws {
        let existing = try JSONEncoder().encode([key("1")])
        let storage = MemoryAIKeyStorage(list: String(bytes: existing, encoding: .utf8),
                                         legacy: AIProviderTests.validAnthropic)
        AIKeyStore(storage: storage).load(legacyAnthropicStatus: nil)
        XCTAssertNil(storage.legacy)
    }

    // MARK: - Remove / reorder

    func testRemove() throws {
        let (store, storage) = try makeStore([key("1"), key("2"), key("3")])
        store.remove(id: "2")
        XCTAssertEqual(store.keys.map(\.id), ["1", "3"])
        store.remove(atOffsets: IndexSet(integer: 0))
        XCTAssertEqual(store.keys.map(\.id), ["3"])
        XCTAssertEqual(try storage.decoded().map(\.id), ["3"])
    }

    func testMoveFromOffsets() throws {
        let (store, storage) = try makeStore([key("1"), key("2"), key("3")])
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.keys.map(\.id), ["3", "1", "2"])
        XCTAssertEqual(try storage.decoded().map(\.id), ["3", "1", "2"])
    }

    func testMoveUpDownAndBounds() throws {
        let (store, storage) = try makeStore([key("1"), key("2"), key("3")])
        store.moveUp(id: "3")
        XCTAssertEqual(store.keys.map(\.id), ["1", "3", "2"])
        store.moveDown(id: "1")
        XCTAssertEqual(store.keys.map(\.id), ["3", "1", "2"])
        let saves = storage.saveCount
        store.moveUp(id: "3")
        store.moveDown(id: "2")
        store.moveUp(id: "missing")
        XCTAssertEqual(store.keys.map(\.id), ["3", "1", "2"])
        XCTAssertEqual(storage.saveCount, saves, "no-op moves don't write")
    }

    // MARK: - Status

    func testHasUsableKeyIgnoresInvalid() throws {
        let (store, _) = try makeStore([key("1", .openai, .invalid)])
        XCTAssertFalse(store.hasUsableKey)
        try store.save(key("2", .ollama, .unverified))
        XCTAssertTrue(store.hasUsableKey)
    }

    func testApplyStatusUpdates() throws {
        let (store, storage) = try makeStore([key("1"), key("2", .gemini, .unverified)])
        store.apply(statusUpdates: ["1": .invalid, "2": .verified, "gone": .invalid])
        XCTAssertEqual(store.keys.map(\.status), [.invalid, .verified])
        XCTAssertEqual(try storage.decoded().map(\.status), [.invalid, .verified])

        let saves = storage.saveCount
        store.apply(statusUpdates: [:])
        XCTAssertEqual(storage.saveCount, saves)
    }

    // MARK: - Legacy migration

    func testMigratesVerifiedLegacyAnthropicKey() throws {
        let storage = MemoryAIKeyStorage(legacy: " \(AIProviderTests.validAnthropic)\n")
        let store = AIKeyStore(storage: storage)
        store.load(legacyAnthropicStatus: .verified)

        XCTAssertEqual(store.keys.count, 1)
        let migrated = try XCTUnwrap(store.keys.first)
        XCTAssertEqual(migrated.provider, .anthropic)
        XCTAssertEqual(migrated.apiKey, AIProviderTests.validAnthropic)
        XCTAssertEqual(migrated.effectiveModel, "claude-haiku-4-5-20251001")
        XCTAssertEqual(migrated.status, .verified)
        XCTAssertEqual(try storage.decoded(), store.keys)
        XCTAssertNil(storage.legacy, "legacy item deleted after the list is persisted")
    }

    func testMigratedKeyUnverifiedUnlessLegacyStatusVerified() {
        for status in [ApiKeyStatus.invalid, .notSet, nil] {
            let store = AIKeyStore(storage: MemoryAIKeyStorage(legacy: AIProviderTests.validAnthropic))
            store.load(legacyAnthropicStatus: status)
            XCTAssertEqual(store.keys.first?.status, .unverified, "\(String(describing: status))")
        }
    }

    func testMigrationKeepsLegacyWhenPersistFails() {
        let storage = MemoryAIKeyStorage(legacy: AIProviderTests.validAnthropic)
        storage.failSaves = true
        let store = AIKeyStore(storage: storage)
        store.load(legacyAnthropicStatus: .verified)
        XCTAssertEqual(store.keys.count, 1, "still usable this session")
        XCTAssertNotNil(storage.legacy, "retry next launch")
        XCTAssertNil(storage.list)
    }

    func testNoMigrationWhenListExists() throws {
        let existing = try JSONEncoder().encode([key("1", .gemini)])
        let storage = MemoryAIKeyStorage(list: String(bytes: existing, encoding: .utf8),
                                         legacy: AIProviderTests.validAnthropic)
        let store = AIKeyStore(storage: storage)
        store.load(legacyAnthropicStatus: .verified)
        XCTAssertEqual(store.keys.map(\.id), ["1"], "existing list wins; legacy key is not imported")
        XCTAssertEqual(storage.saveCount, 0)
    }

    func testBlankLegacyKeyIgnored() {
        let storage = MemoryAIKeyStorage(legacy: "  ")
        let store = AIKeyStore(storage: storage)
        store.load(legacyAnthropicStatus: .verified)
        XCTAssertEqual(store.keys, [])
        XCTAssertNil(storage.list)
    }

    func testClearPersisted() {
        let storage = MemoryAIKeyStorage(list: "[]")
        AIKeyStore.clearPersisted(storage: storage)
        XCTAssertNil(storage.list)
    }
}
