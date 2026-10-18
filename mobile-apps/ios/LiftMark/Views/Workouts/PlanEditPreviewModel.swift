import Foundation

// MARK: - Preview

/// The full plan preview behind an inline diff in the Edit with AI sheet: a
/// proposed plan as a sectioned exercise list with diff highlighting. Built
/// from `PlanDiffEntry`s so a plan without a diff renders the same way.
/// See `spec/screens/workout-detail.md` ("AI Edit Sheet", full preview).
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
    /// Plan-level changes, shown above the first section.
    let headerChanges: [String]
    let sections: [Section]

    /// The preview of `plan`, highlighted per `diff` when there is one; `plan`
    /// is then the proposed plan the diff describes.
    init(plan: WorkoutPlan, diff: PlanDiff?) {
        let entries = diff?.entries ?? PlanDiffBuilder.unchangedEntries(of: plan)
        self.init(
            title: plan.name,
            tags: plan.tags,
            headerChanges: diff?.headerChanges ?? [],
            entries: entries
        )
    }

    /// The full preview behind an assistant turn's inline diff: that turn's
    /// proposed plan with its highlighting. Nil for user and error turns, and
    /// when the proposed markdown does not parse.
    init?(message: PlanEditMessage) {
        guard case .assistant(_, let diff, _, let markdown) = message.content,
              let plan = MarkdownParser.parseWorkout(markdown).data else { return nil }
        self.init(plan: plan, diff: diff)
    }

    init(title: String, tags: [String], headerChanges: [String], entries: [PlanDiffEntry]) {
        self.title = title
        self.tags = tags
        self.headerChanges = headerChanges
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

// MARK: - Inline diff

/// The compact diff in an assistant turn's transcript bubble: only the
/// highlighted rows, in diff order, with unchanged exercises collapsed to a
/// count. See `spec/screens/workout-detail.md` ("AI Edit Sheet", inline diff).
struct PlanEditInlineDiff: Equatable {
    let headerChanges: [String]
    let rows: [PlanEditPreviewRow]
    let unchangedCount: Int

    /// True when there is nothing to show but "No changes were made".
    var isEmpty: Bool { headerChanges.isEmpty && rows.isEmpty }

    init(diff: PlanDiff) {
        headerChanges = diff.headerChanges
        rows = diff.changedEntries.enumerated().map { PlanEditPreviewRow(id: $0.offset, entry: $0.element) }
        unchangedCount = diff.unchangedCount
    }
}

// MARK: - Row

/// One exercise row of the preview or inline diff: its diff kind, marker
/// glyph, the lines shown under the name, and its accessibility identifier.
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
    /// The enclosing superset or section, named in the inline diff where the
    /// row has no surrounding structure to place it; nil at the top level.
    let parent: String?
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
        parent = exercise.parent
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
