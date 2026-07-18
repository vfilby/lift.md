import XCTest
import CloudKit
import GRDB
@testable import LiftMark

/// Tests for the CKRecord system-fields cache that fixes the CKSyncEngine conflict loop:
/// records must be rehydrated from stored `encodedSystemFields` on upload (carrying the
/// current change tag) instead of being rebuilt fresh (nil tag → permanent
/// `serverRecordChanged`). Offline we can't mint a real server change tag, so rehydration
/// is proven via record *identity* preservation (the stored zone wins over the passed zone).
final class CKRecordMetadataStoreTests: XCTestCase {

    private var store: CKRecordMetadataStore!
    private var mapper: CKRecordMapper!
    // The "real" zone a record was first confirmed in (what gets stored)…
    private let storedZone = CKRecordZone.ID(zoneName: "StoredZone", ownerName: CKCurrentUserDefaultName)
    // …vs. the zone a later upload call passes in. Rehydration must use the stored one.
    private let callerZone = CKRecordZone.ID(zoneName: "CallerZone", ownerName: CKCurrentUserDefaultName)

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        _ = Logger.shared
        store = CKRecordMetadataStore()
        mapper = CKRecordMapper()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    private func now() -> String { isoFormatter.string(from: Date()) }

    // MARK: - Store round-trip

    func testSaveAndDecodeRoundtripPreservesIdentity() {
        let id = "rec-1"
        let record = CKRecord(recordType: "WorkoutSession",
                              recordID: CKRecord.ID(recordName: id, zoneID: storedZone))
        store.save(record)

        XCTAssertNotNil(store.systemFields(for: id))
        let decoded = store.decodedRecord(for: id)
        XCTAssertEqual(decoded?.recordID.recordName, id)
        XCTAssertEqual(decoded?.recordType, "WorkoutSession")
        XCTAssertEqual(decoded?.recordID.zoneID, storedZone)
    }

    func testSystemFieldsNilForUnknownRecord() {
        XCTAssertNil(store.systemFields(for: "does-not-exist"))
        XCTAssertNil(store.decodedRecord(for: "does-not-exist"))
    }

    func testRemoveDropsMetadata() {
        let id = "rec-rm"
        store.save(CKRecord(recordType: "Gym", recordID: CKRecord.ID(recordName: id, zoneID: storedZone)))
        XCTAssertNotNil(store.systemFields(for: id))
        store.remove(id)
        XCTAssertNil(store.systemFields(for: id))
    }

    func testClearAllEmptiesTable() {
        store.save(CKRecord(recordType: "Gym", recordID: CKRecord.ID(recordName: "a", zoneID: storedZone)))
        store.save(CKRecord(recordType: "Gym", recordID: CKRecord.ID(recordName: "b", zoneID: storedZone)))
        store.clearAll()
        XCTAssertNil(store.systemFields(for: "a"))
        XCTAssertNil(store.systemFields(for: "b"))
    }

    func testSaveUpsertsByRecordName() {
        let id = "rec-upsert"
        store.save(CKRecord(recordType: "Gym", recordID: CKRecord.ID(recordName: id, zoneID: storedZone)))
        store.save(CKRecord(recordType: "Gym", recordID: CKRecord.ID(recordName: id, zoneID: storedZone)))
        // Still exactly one row (PK on record_name); no error/dupe.
        XCTAssertNotNil(store.systemFields(for: id))
    }

    // MARK: - applyStoredSystemFields (tag rehydration)

    func testApplyStoredSystemFieldsRehydratesOntoStoredIdentityAndKeepsFields() {
        let id = "rec-rehydrate"
        // Confirmed once in storedZone.
        store.save(CKRecord(recordType: "WorkoutSession",
                            recordID: CKRecord.ID(recordName: id, zoneID: storedZone)))

        // A later upload builds a fresh record in callerZone with data fields…
        let fresh = CKRecord(recordType: "WorkoutSession",
                             recordID: CKRecord.ID(recordName: id, zoneID: callerZone))
        fresh["status"] = "completed" as CKRecordValue

        // …rehydration must use the STORED identity AND carry the data fields over.
        let result = mapper.applyStoredSystemFields(to: fresh)
        XCTAssertEqual(result.recordID.zoneID, storedZone, "Existing record must rehydrate from stored system fields")
        XCTAssertEqual(result["status"] as? String, "completed",
                       "Data fields must be preserved onto the rehydrated base")
    }

    func testApplyStoredSystemFieldsReturnsFreshWhenNoMetadata() {
        let fresh = CKRecord(recordType: "WorkoutSession",
                             recordID: CKRecord.ID(recordName: "brand-new", zoneID: callerZone))
        let result = mapper.applyStoredSystemFields(to: fresh)
        XCTAssertEqual(result.recordID.zoneID, callerZone, "New record must stay fresh in the caller's zone")
        XCTAssertNil(result.recordChangeTag)
    }

    func testApplyStoredSystemFieldsReturnsFreshOnTypeMismatch() {
        let id = "rec-typemismatch"
        store.save(CKRecord(recordType: "WorkoutSession",
                            recordID: CKRecord.ID(recordName: id, zoneID: storedZone)))
        // Wrong type for this name → ignore stale metadata, keep the fresh record.
        let fresh = CKRecord(recordType: "SetMeasurement",
                             recordID: CKRecord.ID(recordName: id, zoneID: callerZone))
        let result = mapper.applyStoredSystemFields(to: fresh)
        XCTAssertEqual(result.recordID.zoneID, callerZone)
    }

    func testCreateCKRecordRehydratesFromStoredSystemFields() throws {
        let id = "session-rehydrate"
        let dbQueue = try DatabaseManager.shared.database()
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO workout_sessions (id, name, date, status, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, "Push", "2026-06-07", "completed", now()]
            )
        }
        store.save(CKRecord(recordType: "WorkoutSession",
                            recordID: CKRecord.ID(recordName: id, zoneID: storedZone)))

        // Pass callerZone; because metadata exists, createCKRecord rehydrates onto storedZone
        // and still populates the data fields (no GRDB reentrancy from the nested metadata read).
        let record = mapper.createCKRecord(for: CKRecord.ID(recordName: id, zoneID: callerZone), zoneID: callerZone)
        XCTAssertEqual(record?.recordID.zoneID, storedZone)
        XCTAssertEqual(record?["status"] as? String, "completed")
        XCTAssertEqual(record?["name"] as? String, "Push")
    }

    func testCreateCKRecordBuildsFreshWhenNoMetadata() throws {
        let id = "session-fresh"
        let dbQueue = try DatabaseManager.shared.database()
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO workout_sessions (id, name, date, status, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, "Pull", "2026-06-07", "completed", now()]
            )
        }
        let record = mapper.createCKRecord(for: CKRecord.ID(recordName: id, zoneID: callerZone), zoneID: callerZone)
        XCTAssertEqual(record?.recordID.zoneID, callerZone)
        XCTAssertNil(record?.recordChangeTag, "A record with no stored metadata uploads as a fresh create")
    }

    func testParentAndChildMeasurementHaveIndependentMetadata() {
        let setId = "set-1"
        let measurementId = "meas-1"
        store.save(CKRecord(recordType: "SessionSet",
                            recordID: CKRecord.ID(recordName: setId, zoneID: storedZone)))
        store.save(CKRecord(recordType: "SetMeasurement",
                            recordID: CKRecord.ID(recordName: measurementId, zoneID: storedZone)))

        XCTAssertEqual(store.decodedRecord(for: setId)?.recordType, "SessionSet")
        XCTAssertEqual(store.decodedRecord(for: measurementId)?.recordType, "SetMeasurement")
    }

    // MARK: - mergeIncoming persists tags unconditionally

    func testMergeIncomingPersistsSystemFieldsEvenWhenLocalIsNewer() throws {
        let id = "session-local-newer"
        let dbQueue = try DatabaseManager.shared.database()
        // Local row is NEWER than the incoming server record.
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO workout_sessions (id, name, date, status, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, "Local", "2026-06-07", "completed", now()]
            )
        }

        let incoming = CKRecord(recordType: "WorkoutSession",
                                recordID: CKRecord.ID(recordName: id, zoneID: storedZone))
        incoming["name"] = "Server" as CKRecordValue
        incoming["date"] = "2026-06-07" as CKRecordValue
        incoming["status"] = "in_progress" as CKRecordValue
        incoming["updatedAt"] = Date(timeIntervalSinceNow: -3600) as CKRecordValue // older

        let merged = try mapper.mergeIncoming(incoming)

        XCTAssertFalse(merged, "Local is newer, so the row merge must be skipped")
        XCTAssertNotNil(mapper.metadataStore.systemFields(for: id),
                        "System fields must be persisted even when the row merge is skipped")

        // And the local row must be untouched (server did not clobber it).
        let status = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM workout_sessions WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(status, "completed")
    }
}
