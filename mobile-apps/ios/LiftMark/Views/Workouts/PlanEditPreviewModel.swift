import Foundation

// MARK: - Preview

/// The live plan preview in the Edit with AI sheet: the working plan as a
/// sectioned exercise list, with diff highlighting while a proposal is
/// pending. Built from `PlanDiffEntry`s so one renderer serves both states.
/// See `spec/screens/workout-detail.md` ("AI Edit Sheet", plan preview).
struct PlanEditPreview: Equatable {
    struct Section: Equatable, Identifiable {
        let id: Int
        /// Section header name; nil for top-level exercises.
        let name: String?
        var items: [Item]
    }

    enum Item: Equatable, Identifiable {
        case exercise(PlanEditPreviewRow)
        case superset(id: Int, name: String, rows: [PlanEditPreviewRow])

        var id: Int {
            switch self {
            case .exercise(let row): return row.id
            case .superset(let id, _, _): return id
            }
        }
    }

    let title: String
    let tags: [String]
    /// Plan-level changes, shown above the first section while a proposal is pending.
    let headerChanges: [String]
    let sections: [Section]
    /// True while a proposal is pending: rows carry diff highlighting and the
    /// container is `ai-edit-diff` rather than `ai-edit-preview`.
    let isDiff: Bool

    var accessibilityIdentifier: String { isDiff ? "ai-edit-diff" : "ai-edit-preview" }

    /// The preview of `plan`; highlighted per `diff` when one is pending.
    /// `plan` is the proposed plan in that case (the session's working plan).
    init(plan: WorkoutPlan, diff: PlanDiff?) {
        let entries = diff?.entries ?? PlanDiffBuilder.unchangedEntries(of: plan)
        self.init(
            title: plan.name,
            tags: plan.tags,
            headerChanges: diff?.headerChanges ?? [],
            entries: entries,
            isDiff: diff != nil
        )
    }

    init(title: String, tags: [String], headerChanges: [String], entries: [PlanDiffEntry], isDiff: Bool) {
        self.title = title
        self.tags = tags
        self.headerChanges = headerChanges
        self.isDiff = isDiff
        self.sections = Self.group(entries)
    }

    /// Consecutive entries sharing a section land in one section; within it,
    /// consecutive entries sharing a superset parent land in one superset
    /// item. Removed exercises keep the place the diff gave them.
    private static func group(_ entries: [PlanDiffEntry]) -> [Section] {
        var sections: [Section] = []
        for (ordinal, entry) in entries.enumerated() {
            let row = PlanEditPreviewRow(id: ordinal, entry: entry)
            let exercise = entry.exercise
            let superset = exercise.parentKind == .superset ? exercise.parent : nil

            if sections.isEmpty || sections[sections.count - 1].name != exercise.section {
                sections.append(Section(id: ordinal, name: exercise.section, items: []))
            }
            let sectionIndex = sections.count - 1

            if let superset {
                if case .superset(let id, let name, var rows)? = sections[sectionIndex].items.last, name == superset {
                    rows.append(row)
                    sections[sectionIndex].items[sections[sectionIndex].items.count - 1] =
                        .superset(id: id, name: name, rows: rows)
                } else {
                    sections[sectionIndex].items.append(.superset(id: ordinal, name: superset, rows: [row]))
                }
            } else {
                sections[sectionIndex].items.append(.exercise(row))
            }
        }
        return sections
    }
}

// MARK: - Row

/// One exercise row of the preview: its diff kind, marker glyph, the lines
/// shown under the name, and its accessibility identifier.
struct PlanEditPreviewRow: Equatable, Identifiable {
    enum Kind: String {
        case unchanged
        case added
        case removed
        case changed

        /// Leading glyph; nil for unchanged rows.
        var marker: String? {
            switch self {
            case .unchanged: return nil
            case .added: return "+"
            case .removed: return "\u{2212}"
            case .changed: return "~"
            }
        }
    }

    /// Ordinal within the preview; names can repeat, so this is the identity.
    let id: Int
    let kind: Kind
    let name: String
    let notes: String?
    let equipmentType: String?
    /// Set lines without the LMWF bullet (`135 lbs x 5 @rest: 90s`): the
    /// current sets for unchanged/added, the removed sets, or the *after*
    /// sets for changed.
    let lines: [String]
    /// The *before* set lines for changed rows, empty otherwise.
    let previousLines: [String]

    var slug: String { Self.slugify(name) }

    /// `ai-edit-diff-row-{kind}-{slug}` for highlighted rows,
    /// `ai-edit-preview-row-{slug}` for unchanged ones.
    var accessibilityIdentifier: String {
        kind == .unchanged
            ? "ai-edit-preview-row-\(slug)"
            : "ai-edit-diff-row-\(kind.rawValue)-\(slug)"
    }

    init(id: Int, entry: PlanDiffEntry) {
        self.id = id
        let exercise = entry.exercise
        name = exercise.name
        notes = exercise.notes
        equipmentType = exercise.equipmentType
        lines = Self.displayLines(exercise.setLines)
        switch entry {
        case .unchanged:
            kind = .unchanged
            previousLines = []
        case .added:
            kind = .added
            previousLines = []
        case .removed:
            kind = .removed
            previousLines = []
        case .changed(let before, _):
            kind = .changed
            previousLines = Self.displayLines(before.setLines)
        }
    }

    private static func displayLines(_ setLines: [String]) -> [String] {
        setLines.map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
    }

    /// Lower-cased, non-alphanumerics collapsed to single hyphens, trimmed:
    /// "Face Pull" → "face-pull".
    static func slugify(_ name: String) -> String {
        var out = ""
        var pendingHyphen = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        return out
    }
}

extension PlanDiffEntry {
    /// The exercise this entry describes: the *after* exercise for changed
    /// entries (its name and placement are what the preview shows).
    var exercise: PlanDiffExercise {
        switch self {
        case .added(let exercise), .removed(let exercise), .unchanged(let exercise):
            return exercise
        case .changed(_, let after):
            return after
        }
    }
}
