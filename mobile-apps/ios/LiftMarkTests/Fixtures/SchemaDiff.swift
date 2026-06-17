import Foundation
import GRDB

/// Captures a normalized, order-independent view of a SQLite schema for diffing.
///
/// We compare `PRAGMA table_info` (per table) + `PRAGMA index_list` names rather than
/// `sqlite_master.sql` text. Raw SQL text is sensitive to whitespace, quote style, and
/// inline constraint formatting — none of which affect observable behavior.
struct SchemaSnapshot: Equatable {
    struct Column: Equatable, Comparable {
        let name: String
        let type: String
        let notNull: Bool
        let defaultValue: String?  // SQLite returns default literal as text
        let pkOrdinal: Int         // 0 if not part of PK

        static func < (lhs: Column, rhs: Column) -> Bool { lhs.name < rhs.name }
    }

    struct Table: Equatable {
        let name: String
        let columns: [Column]   // sorted by name
        let indexes: [String]   // sorted, excludes auto-indexes
    }

    let tables: [Table]   // sorted by name

    static func capture(_ db: Database) throws -> SchemaSnapshot {
        // Exclude migration-bookkeeping tables: legacy `schema_version` (still
        // present in frozen seeds) and GRDB's own `grdb_migrations` (created on the
        // live side by the migrator). Neither is app schema, and comparing them
        // would spuriously fail seed-vs-live diffs.
        let tableNames = try Row.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
              AND name NOT IN ('schema_version', 'grdb_migrations')
            ORDER BY name
        """).map { $0["name"] as String }

        var tables: [Table] = []
        for name in tableNames {
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(\(name))").map { row -> Column in
                Column(
                    name: row["name"],
                    type: (row["type"] as String?) ?? "",
                    notNull: (row["notnull"] as Int) != 0,
                    defaultValue: row["dflt_value"],
                    pkOrdinal: row["pk"]
                )
            }.sorted()
            let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(\(name))").compactMap { row -> String? in
                let origin: String = row["origin"]
                // Skip auto-indexes created by PRIMARY KEY / UNIQUE (origin == "pk" or "u")
                guard origin == "c" else { return nil }
                return row["name"]
            }.sorted()
            tables.append(Table(name: name, columns: cols, indexes: indexes))
        }
        return SchemaSnapshot(tables: tables)
    }

    /// Returns a human-readable diff, or nil if identical.
    func diff(vs other: SchemaSnapshot, label: String) -> String? {
        if self == other { return nil }

        var out: [String] = ["Schema mismatch: \(label)"]

        let selfNames = Set(tables.map(\.name))
        let otherNames = Set(other.tables.map(\.name))
        let onlySelf = selfNames.subtracting(otherNames).sorted()
        let onlyOther = otherNames.subtracting(selfNames).sorted()
        if !onlySelf.isEmpty { out.append("  Tables only in seed: \(onlySelf)") }
        if !onlyOther.isEmpty { out.append("  Tables only in live: \(onlyOther)") }

        for name in selfNames.intersection(otherNames).sorted() {
            let a = tables.first { $0.name == name }!
            let b = other.tables.first { $0.name == name }!
            if a == b { continue }

            if a.columns != b.columns {
                let aCols = Set(a.columns.map(\.name))
                let bCols = Set(b.columns.map(\.name))
                let addedInSeed = aCols.subtracting(bCols).sorted()
                let addedInLive = bCols.subtracting(aCols).sorted()
                if !addedInSeed.isEmpty { out.append("  [\(name)] columns only in seed: \(addedInSeed)") }
                if !addedInLive.isEmpty { out.append("  [\(name)] columns only in live: \(addedInLive)") }
                for colName in aCols.intersection(bCols).sorted() {
                    let ac = a.columns.first { $0.name == colName }!
                    let bc = b.columns.first { $0.name == colName }!
                    if ac != bc {
                        out.append("  [\(name).\(colName)] seed=\(ac) live=\(bc)")
                    }
                }
            }
            if a.indexes != b.indexes {
                out.append("  [\(name)] indexes seed=\(a.indexes) live=\(b.indexes)")
            }
        }
        return out.joined(separator: "\n")
    }
}
