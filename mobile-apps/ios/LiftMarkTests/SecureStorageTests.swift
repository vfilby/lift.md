import XCTest
@testable import LiftMark

/// Real Keychain round-trips for the generic accessors and the legacy Anthropic item.
final class SecureStorageTests: XCTestCase {
    private let account = "liftmark_tests_secure_storage"

    override func tearDown() {
        try? SecureStorage.delete(key: account)
        super.tearDown()
    }

    func testStoreRetrieveOverwriteDelete() throws {
        try SecureStorage.store(key: account, value: "first")
        XCTAssertEqual(SecureStorage.retrieve(key: account), "first")
        try SecureStorage.store(key: account, value: "second")
        XCTAssertEqual(SecureStorage.retrieve(key: account), "second")
        try SecureStorage.delete(key: account)
        XCTAssertNil(SecureStorage.retrieve(key: account))
    }

    func testDeleteMissingItemIsNotAnError() {
        XCTAssertNoThrow(try SecureStorage.delete(key: account))
    }

    func testLegacyAnthropicKeyReadAndRemove() throws {
        let previous = SecureStorage.getLegacyAnthropicApiKey()
        defer { if let previous { try? SecureStorage.store(key: "anthropic_api_key", value: previous) } }

        try SecureStorage.store(key: "anthropic_api_key", value: "sk-ant-legacy")
        XCTAssertEqual(SecureStorage.getLegacyAnthropicApiKey(), "sk-ant-legacy")
        try SecureStorage.removeLegacyAnthropicApiKey()
        XCTAssertNil(SecureStorage.getLegacyAnthropicApiKey())
    }

    func testKeychainAIKeyStorageRoundTrip() throws {
        let storage = KeychainAIKeyStorage()
        let previous = storage.loadList()
        defer {
            if let previous { try? storage.saveList(previous) } else { try? storage.deleteList() }
        }

        try storage.saveList("[]")
        XCTAssertEqual(storage.loadList(), "[]")
        try storage.deleteList()
        XCTAssertNil(storage.loadList())
    }
}
