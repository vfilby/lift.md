import XCTest
@testable import LiftMark

/// Unit tests for the user-facing migrator-bridge failure record.
///
/// Message copy is the load-bearing piece here — it must match
/// `spec/services/migrator.md` §5.2 verbatim. Breaking this test means the spec and
/// app have diverged.
final class MigratorBridgeFailureTests: XCTestCase {

    private let defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        MigratorBridgeFailure.clearPersisted(defaults: defaults)
    }

    override func tearDown() {
        MigratorBridgeFailure.clearPersisted(defaults: defaults)
        super.tearDown()
    }

    // MARK: - Copy matches spec §5.2

    func testDiskFullMessageSubstitutesRequiredMegabytes() {
        // 50 MiB → expects 50 MB in message.
        let context = MigratorBridgeFailureContext(requiredBytes: 50 * 1024 * 1024)
        let message = MigratorBridgeFailure.diskFull.alertMessage(context: context)
        XCTAssertEqual(message, "Free up ~50 MB and relaunch.")
    }

    func testDiskFullRoundsUpPartialMegabyte() {
        // 50.5 MiB → rounds up to 51.
        let context = MigratorBridgeFailureContext(
            requiredBytes: 50 * 1024 * 1024 + 512 * 1024
        )
        let message = MigratorBridgeFailure.diskFull.alertMessage(context: context)
        XCTAssertEqual(message, "Free up ~51 MB and relaunch.")
    }

    func testIntegrityFailedMessage() {
        let message = MigratorBridgeFailure.integrityFailed.alertMessage(context: .init())
        XCTAssertEqual(
            message,
            "Your local workout database reports an inconsistency. lift.md will not upgrade until this is resolved. Tap here to export a copy for support."
        )
    }

    func testBackupFailedMessage() {
        let message = MigratorBridgeFailure.backupFailed.alertMessage(context: .init())
        XCTAssertEqual(
            message,
            "lift.md couldn't create a safety backup. Your data is unchanged. Please try again."
        )
    }

    func testBridgeWriteFailedMessage() {
        let message = MigratorBridgeFailure.bridgeWriteFailed.alertMessage(context: .init())
        XCTAssertEqual(
            message,
            "Database upgrade couldn't complete. Your data has been restored from backup. Please try again."
        )
    }

    func testPostBridgeMigrationFailedAndFkViolationShareMessage() {
        let postBridge = MigratorBridgeFailure.postBridgeMigrationFailed.alertMessage(context: .init())
        let fk = MigratorBridgeFailure.fkViolation.alertMessage(context: .init())
        XCTAssertEqual(postBridge, fk)
        XCTAssertEqual(
            postBridge,
            "Database upgrade failed and has been rolled back. Your data is unchanged."
        )
    }

    func testFutureVersionMessage() {
        let message = MigratorBridgeFailure.futureVersion.alertMessage(
            context: .init(fromVersion: 99)
        )
        XCTAssertEqual(
            message,
            "This database was written by a newer version of lift.md. Update the app to continue."
        )
    }

    // MARK: - Boot-blocking classification

    func testBootBlockingCases() {
        XCTAssertTrue(MigratorBridgeFailure.diskFull.isBootBlocking)
        XCTAssertTrue(MigratorBridgeFailure.integrityFailed.isBootBlocking)
        XCTAssertTrue(MigratorBridgeFailure.futureVersion.isBootBlocking)
    }

    func testInformationalCases() {
        XCTAssertFalse(MigratorBridgeFailure.backupFailed.isBootBlocking)
        XCTAssertFalse(MigratorBridgeFailure.bridgeWriteFailed.isBootBlocking)
        XCTAssertFalse(MigratorBridgeFailure.postBridgeMigrationFailed.isBootBlocking)
        XCTAssertFalse(MigratorBridgeFailure.fkViolation.isBootBlocking)
    }

    func testOnlyIntegrityFailedOffersSupportExport() {
        XCTAssertTrue(MigratorBridgeFailure.integrityFailed.offersSupportExport)
        for failure in MigratorBridgeFailure.allCases where failure != .integrityFailed {
            XCTAssertFalse(
                failure.offersSupportExport,
                "\(failure.rawValue) should not offer support export"
            )
        }
    }

    // MARK: - Persistence round-trip

    func testPersistAndLoadDiskFullPreservesContext() {
        MigratorBridgeFailure.persist(
            .diskFull,
            context: .init(requiredBytes: 100 * 1024 * 1024, dbSizeBytes: 50 * 1024 * 1024),
            defaults: defaults
        )
        let loaded = MigratorBridgeFailure.loadPersisted(defaults: defaults)
        XCTAssertEqual(loaded?.failure, .diskFull)
        XCTAssertEqual(loaded?.context.requiredBytes, 100 * 1024 * 1024)
        XCTAssertEqual(loaded?.context.dbSizeBytes, 50 * 1024 * 1024)
        XCTAssertNil(loaded?.context.fromVersion)
    }

    func testPersistAndLoadFutureVersionPreservesFromVersion() {
        MigratorBridgeFailure.persist(
            .futureVersion,
            context: .init(fromVersion: 42),
            defaults: defaults
        )
        let loaded = MigratorBridgeFailure.loadPersisted(defaults: defaults)
        XCTAssertEqual(loaded?.failure, .futureVersion)
        XCTAssertEqual(loaded?.context.fromVersion, 42)
    }

    func testLoadReturnsNilWhenLastAttemptFailedIsFalse() {
        MigratorBridgeFailure.persist(.backupFailed, defaults: defaults)
        defaults.set(false, forKey: MigratorBridgeBackup.UserDefaultsKey.lastAttemptFailed)
        XCTAssertNil(MigratorBridgeFailure.loadPersisted(defaults: defaults))
    }

    func testClearPersistedRemovesAllKeys() {
        MigratorBridgeFailure.persist(
            .diskFull,
            context: .init(requiredBytes: 1024, dbSizeBytes: 512, fromVersion: 3),
            defaults: defaults
        )
        MigratorBridgeFailure.clearPersisted(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: MigratorBridgeBackup.UserDefaultsKey.lastAttemptFailed))
        XCTAssertNil(defaults.string(forKey: MigratorBridgeFailure.PersistenceKey.lastFailureCase))
        XCTAssertNil(defaults.object(forKey: MigratorBridgeFailure.PersistenceKey.lastFailureRequiredBytes))
        XCTAssertNil(defaults.object(forKey: MigratorBridgeFailure.PersistenceKey.lastFailureDbSizeBytes))
        XCTAssertNil(defaults.object(forKey: MigratorBridgeFailure.PersistenceKey.lastFailureFromVersion))
        XCTAssertNil(MigratorBridgeFailure.loadPersisted(defaults: defaults))
    }

    func testPersistOverwritesPreviousRecord() {
        MigratorBridgeFailure.persist(
            .diskFull,
            context: .init(requiredBytes: 999),
            defaults: defaults
        )
        MigratorBridgeFailure.persist(
            .futureVersion,
            context: .init(fromVersion: 14),
            defaults: defaults
        )
        let loaded = MigratorBridgeFailure.loadPersisted(defaults: defaults)
        XCTAssertEqual(loaded?.failure, .futureVersion)
        // Stale requiredBytes from the prior call must not leak through.
        XCTAssertNil(loaded?.context.requiredBytes)
        XCTAssertEqual(loaded?.context.fromVersion, 14)
    }

    func testLoadReturnsNilForUnknownCaseRawValue() {
        defaults.set(true, forKey: MigratorBridgeBackup.UserDefaultsKey.lastAttemptFailed)
        defaults.set("not_a_real_case", forKey: MigratorBridgeFailure.PersistenceKey.lastFailureCase)
        XCTAssertNil(MigratorBridgeFailure.loadPersisted(defaults: defaults))
    }
}
