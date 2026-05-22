"""Tests for check_ckrecord_drift."""

from check_ckrecord_drift import (
    FieldSet,
    diff_field_sets,
    extract_fields_from_source,
)


def test_extract_static_field_subscripts():
    source = """
    func toCKRecord(_ gym: GymRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "Gym", recordID: recordID)
        record["name"] = gym.name as CKRecordValue
        record["isDefault"] = Int64(gym.isDefault) as CKRecordValue
        return record
    }
    """
    fields = extract_fields_from_source(source)
    assert fields == {"Gym": {"name", "isDefault"}}


def test_extract_helper_call_keys():
    source = """
    func toCKRecord(_ ss: SessionSetRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "SessionSet", recordID: recordID)
        record["status"] = ss.status as CKRecordValue
        setOptionalString(on: record, key: "side", value: ss.side)
        setOptionalInt(on: record, key: "restSeconds", value: ss.restSeconds)
        setOptionalDate(on: record, key: "completedAt", isoString: ss.completedAt)
        return record
    }
    """
    fields = extract_fields_from_source(source)
    assert fields == {
        "SessionSet": {"status", "side", "restSeconds", "completedAt"}
    }


def test_extract_unions_multiple_overloads_for_same_record_type():
    source = """
    func toCKRecord(_ a: A) -> CKRecord {
        let record = CKRecord(recordType: "Shared", recordID: id)
        record["one"] = a.one as CKRecordValue
    }
    func toCKRecord(_ b: B) -> CKRecord {
        let record = CKRecord(recordType: "Shared", recordID: id)
        record["two"] = b.two as CKRecordValue
    }
    """
    fields = extract_fields_from_source(source)
    assert fields == {"Shared": {"one", "two"}}


def test_extract_skips_dynamic_field_names():
    # Interpolated field names like record["\(prefix)Weight"] are intentionally
    # ignored — the script's job is catching new *static* drift.
    source = r"""
    func toCKRecord(_ x: X) -> CKRecord {
        let record = CKRecord(recordType: "Dynamic", recordID: id)
        record["staticField"] = x.foo as CKRecordValue
        record["\(prefix)Weight"] = x.bar as CKRecordValue
    }
    """
    fields = extract_fields_from_source(source)
    assert fields == {"Dynamic": {"staticField"}}


def test_extract_ignores_non_toCKRecord_functions():
    source = """
    func mergeIncoming(_ record: CKRecord) {
        let record = CKRecord(recordType: "Shouldnt", recordID: id)
        record["ignored"] = "value" as CKRecordValue
    }
    func toCKRecord(_ g: G) -> CKRecord {
        let record = CKRecord(recordType: "Real", recordID: id)
        record["kept"] = g.kept as CKRecordValue
    }
    """
    fields = extract_fields_from_source(source)
    assert fields == {"Real": {"kept"}}


def test_diff_reports_added_fields():
    old = FieldSet(
        revision="deploy/1.0.111",
        by_record_type={"UserSettings": {"theme", "notificationsEnabled"}},
    )
    new = FieldSet(
        revision="WORKING",
        by_record_type={
            "UserSettings": {
                "theme",
                "notificationsEnabled",
                "defaultTimerCountdown",
                "defaultWeightStepLbs",
            }
        },
    )
    drift = diff_field_sets(old, new)
    assert drift == {"UserSettings": {"defaultTimerCountdown", "defaultWeightStepLbs"}}


def test_diff_ignores_removed_fields():
    # Schema deprecation (removing a field locally) is intentional and shouldn't
    # be flagged — CloudKit can't actually delete a deployed field anyway.
    old = FieldSet(
        revision="deploy/1.0.111",
        by_record_type={"Plan": {"a", "b", "c"}},
    )
    new = FieldSet(
        revision="WORKING",
        by_record_type={"Plan": {"a", "b"}},
    )
    assert diff_field_sets(old, new) == {}


def test_diff_reports_entirely_new_record_type():
    old = FieldSet(revision="t", by_record_type={})
    new = FieldSet(
        revision="WORKING",
        by_record_type={"Brand": {"newField"}},
    )
    assert diff_field_sets(old, new) == {"Brand": {"newField"}}


def test_diff_clean_when_no_changes():
    old = FieldSet(revision="t", by_record_type={"A": {"x"}})
    new = FieldSet(revision="WORKING", by_record_type={"A": {"x"}})
    assert diff_field_sets(old, new) == {}
