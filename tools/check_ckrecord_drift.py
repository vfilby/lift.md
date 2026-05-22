"""Detect CloudKit schema drift since the last release.

Parses every `toCKRecord(...)` function in the iOS app's CKRecordMapper sources,
collects the static field names written to each `CKRecord` (literal subscripts
like `record["foo"]` and helper-call key args like
`setOptionalString(on: record, key: "foo", ...)`), and diffs the set against
the same files at the last `deploy/*` git tag.

Any field present in HEAD but absent at the tag is reported. If drift exists,
exits 1 — the CloudKit Production schema must be promoted via CloudKit
Dashboard before the next TestFlight build, or every save against the affected
record type will fail with CKError 12 (invalidArguments) or 2006
(serverRejectedRequest).

Dynamic field names built via string interpolation (e.g. `record["\\(prefix)Weight"]`)
are not extracted — this script only catches new *static* fields, which is
where drift has historically come from.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MAPPER_FILES = [
    "mobile-apps/ios/LiftMark/Services/CKRecordMapper.swift",
    "mobile-apps/ios/LiftMark/Services/CKRecordMapper+SetMeasurement.swift",
]

FUNC_RE = re.compile(r"\bfunc\s+toCKRecord\b")
RECORD_TYPE_RE = re.compile(r'CKRecord\(\s*recordType:\s*"([^"]+)"')
SUBSCRIPT_RE = re.compile(r'\brecord\[\s*"([^"]+)"\s*\]')
HELPER_RE = re.compile(
    r'\bsetOptional\w+\s*\(\s*on:\s*record\s*,\s*key:\s*"([^"]+)"'
)


@dataclass(frozen=True)
class FieldSet:
    """Fields written per record type, plus the source revision label."""

    revision: str
    by_record_type: dict[str, set[str]]


def _extract_function_blocks(source: str) -> list[str]:
    """Return the body of every `func toCKRecord(...)` in `source`.

    Uses brace counting starting from the first `{` after the function keyword
    so we don't need a full Swift parser.
    """
    blocks: list[str] = []
    for match in FUNC_RE.finditer(source):
        i = source.find("{", match.end())
        if i == -1:
            continue
        depth = 1
        j = i + 1
        while j < len(source) and depth > 0:
            if source[j] == "{":
                depth += 1
            elif source[j] == "}":
                depth -= 1
            j += 1
        blocks.append(source[i + 1 : j - 1])
    return blocks


def extract_fields_from_source(source: str) -> dict[str, set[str]]:
    """Map each recordType to the set of static field names written to it."""
    result: dict[str, set[str]] = {}
    for block in _extract_function_blocks(source):
        m = RECORD_TYPE_RE.search(block)
        if not m:
            continue
        record_type = m.group(1)
        raw = set(SUBSCRIPT_RE.findall(block)) | set(HELPER_RE.findall(block))
        # Drop Swift string-interpolated field names — we can only diff static ones.
        fields = {f for f in raw if "\\(" not in f}
        # Multiple toCKRecord overloads can target the same record type
        # (e.g. PlannedSet/SessionSet via writeMeasurementFields). Union them.
        result.setdefault(record_type, set()).update(fields)
    return result


def _git_show(revision: str, path: str) -> str:
    """Read `path` at `revision`. Returns '' if the file didn't exist there."""
    try:
        return subprocess.check_output(
            ["git", "show", f"{revision}:{path}"],
            cwd=REPO_ROOT,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except subprocess.CalledProcessError:
        return ""


def collect_fields_at(revision: str) -> FieldSet:
    """Read every mapper file at `revision` and merge their extracted fields."""
    merged: dict[str, set[str]] = {}
    for rel in MAPPER_FILES:
        source = _git_show(revision, rel) if revision != "WORKING" else (REPO_ROOT / rel).read_text()
        for record_type, fields in extract_fields_from_source(source).items():
            merged.setdefault(record_type, set()).update(fields)
    return FieldSet(revision=revision, by_record_type=merged)


def latest_release_tag() -> str | None:
    """Most recent `deploy/*` tag by creator date, or None if none exist."""
    out = subprocess.check_output(
        ["git", "tag", "--list", "deploy/*", "--sort=-creatordate"],
        cwd=REPO_ROOT,
        text=True,
    ).strip()
    if not out:
        return None
    return out.splitlines()[0]


def diff_field_sets(old: FieldSet, new: FieldSet) -> dict[str, set[str]]:
    """Fields added in `new` per record type. Empty means no drift."""
    added: dict[str, set[str]] = {}
    for record_type, new_fields in new.by_record_type.items():
        old_fields = old.by_record_type.get(record_type, set())
        delta = new_fields - old_fields
        if delta:
            added[record_type] = delta
    return added


def format_report(old: FieldSet, drift: dict[str, set[str]]) -> str:
    if not drift:
        return f"✓ No CKRecord schema drift since {old.revision}.\n"
    lines = [
        f"✘ CKRecord schema drift detected since {old.revision}:",
        "",
    ]
    for record_type in sorted(drift):
        lines.append(f"  {record_type}:")
        for field in sorted(drift[record_type]):
            lines.append(f"    + {field}")
    lines.extend(
        [
            "",
            "Promote the CloudKit Production schema via CloudKit Dashboard",
            "before releasing, or saves against affected record types will fail",
            "with CKError 12 (invalidArguments) or 2006 (serverRejectedRequest).",
            "",
            "Container: iCloud.com.eff3.liftmark.v2",
            "Schema file: mobile-apps/ios/cloudkit-schema.ckdb",
        ]
    )
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--since",
        help="Revision to diff against (default: latest deploy/* tag).",
    )
    args = parser.parse_args(argv)

    baseline = args.since or latest_release_tag()
    if not baseline:
        print("No deploy/* tags found; nothing to diff against.", file=sys.stderr)
        return 0

    old = collect_fields_at(baseline)
    new = collect_fields_at("WORKING")
    drift = diff_field_sets(old, new)
    sys.stdout.write(format_report(old, drift))
    return 1 if drift else 0


if __name__ == "__main__":
    raise SystemExit(main())
