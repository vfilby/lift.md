import Foundation

// MARK: - Diff model

/// One exercise as the diff sees it: its name, the parent it lives under
/// (superset or section), and the LMWF rendering of its sets.
struct PlanDiffExercise: Equatable, Sendable {
    enum ParentKind: Equatable, Sendable {
        case section
        case superset
    }

    let name: String
    /// Name of the enclosing superset/section, nil at the top level.
    let parent: String?
    /// Whether `parent` is a section or a superset; nil at the top level.
    let parentKind: ParentKind?
    /// Name of the enclosing section, walking up through a superset parent;
    /// equals `parent` when `parentKind == .section`.
    let section: String?
    let notes: String?
    let equipmentType: String?
    /// Sets rendered as LMWF lines (`- 135 lbs x 5 @rest: 90s`), so two sets
    /// that differ only in how the unit was written compare equal.
    let setLines: [String]

    init(
        name: String,
        parent: String?,
        parentKind: ParentKind? = nil,
        section: String? = nil,
        notes: String?,
        equipmentType: String?,
        setLines: [String]
    ) {
        self.name = name
        self.parent = parent
        self.parentKind = parentKind
        self.section = section
        self.notes = notes
        self.equipmentType = equipmentType
        self.setLines = setLines
    }

    /// Same sets, notes, and equipment. The name is excluded: matched
    /// exercises already agree on it up to case and surrounding whitespace.
    func hasSameContent(as other: PlanDiffExercise) -> Bool {
        setLines == other.setLines && notes == other.notes && equipmentType == other.equipmentType
    }
}

enum PlanDiffEntry: Equatable, Sendable {
    case added(PlanDiffExercise)
    case removed(PlanDiffExercise)
    case changed(before: PlanDiffExercise, after: PlanDiffExercise)
    case unchanged(PlanDiffExercise)

    var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}

struct PlanDiff: Equatable, Sendable {
    let entries: [PlanDiffEntry]
    /// Plan-level changes (name, tags, units, workout notes), human-readable.
    let headerChanges: [String]

    /// True when every entry is `.unchanged` and there are no header changes.
    var isEmpty: Bool {
        headerChanges.isEmpty && entries.allSatisfy(\.isUnchanged)
    }

    var unchangedCount: Int { entries.filter(\.isUnchanged).count }

    /// Everything the sheet renders as its own row.
    var changedEntries: [PlanDiffEntry] { entries.filter { !$0.isUnchanged } }

    static let empty = PlanDiff(entries: [], headerChanges: [])
}

// MARK: - Builder

/// Exercise-level diff between two parsed plans. See
/// `spec/services/ai-plan-editing.md` ("Diff").
enum PlanDiffBuilder {

    static func diff(before: WorkoutPlan, after: WorkoutPlan) -> PlanDiff {
        let beforeItems = exercises(of: before)
        let afterItems = exercises(of: after)

        // Match each `after` exercise to the first still-unmatched `before`
        // exercise with the same key (trimmed, case-insensitive name within
        // the same parent).
        var unmatchedBefore = Array(beforeItems.indices)
        var matches: [Int: Int] = [:]   // after index → before index
        for (afterIndex, item) in afterItems.enumerated() {
            if let slot = unmatchedBefore.firstIndex(where: { beforeItems[$0].key == item.key }) {
                matches[afterIndex] = unmatchedBefore.remove(at: slot)
            }
        }
        var removedBefore = Set(unmatchedBefore)

        // Walk `after` in order, flushing removed `before` exercises at the
        // position they used to occupy so the row order reads naturally.
        var entries: [PlanDiffEntry] = []
        var nextBefore = 0
        for (afterIndex, item) in afterItems.enumerated() {
            if let beforeIndex = matches[afterIndex] {
                if beforeIndex >= nextBefore {
                    for index in nextBefore..<beforeIndex where removedBefore.contains(index) {
                        entries.append(.removed(beforeItems[index].exercise))
                        removedBefore.remove(index)
                    }
                    nextBefore = beforeIndex + 1
                }
                let old = beforeItems[beforeIndex].exercise
                if old.hasSameContent(as: item.exercise) {
                    entries.append(.unchanged(item.exercise))
                } else {
                    entries.append(.changed(before: old, after: item.exercise))
                }
            } else {
                entries.append(.added(item.exercise))
            }
        }
        for index in removedBefore.sorted() {
            entries.append(.removed(beforeItems[index].exercise))
        }

        return PlanDiff(entries: entries, headerChanges: headerChanges(before: before, after: after))
    }

    /// Every exercise of `plan` as an `.unchanged` entry, in plan order. The
    /// live preview uses this when no proposal is pending so one renderer
    /// serves both states.
    static func unchangedEntries(of plan: WorkoutPlan) -> [PlanDiffEntry] {
        exercises(of: plan).map { .unchanged($0.exercise) }
    }

    // MARK: - Private

    private struct Item {
        let key: String
        let exercise: PlanDiffExercise
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Flatten a plan's exercises into diffable items. Structural rows (empty
    /// section headers, empty superset parents) are containers, not exercises,
    /// so they only contribute their name as the children's `parent`.
    private static func exercises(of plan: WorkoutPlan) -> [Item] {
        let byId = Dictionary(plan.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.exercises.compactMap { exercise in
            guard !exercise.isStructuralHeader else { return nil }
            let parent = exercise.parentExerciseId.flatMap { byId[$0] }
            let parentName = parent?.exerciseName
            let parentKind: PlanDiffExercise.ParentKind? = parent.map {
                $0.groupType == .superset ? .superset : .section
            }
            let section = parentKind == .superset
                ? parent?.parentExerciseId.flatMap { byId[$0]?.exerciseName }
                : parentName
            let diffExercise = PlanDiffExercise(
                name: exercise.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines),
                parent: parentName?.trimmingCharacters(in: .whitespacesAndNewlines),
                parentKind: parentKind,
                section: section?.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: exercise.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                equipmentType: exercise.equipmentType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                setLines: exercise.sets.compactMap(LMWFSourceEditor.renderSetLine)
            )
            let key = (parentName.map(normalize) ?? "") + "/" + normalize(exercise.exerciseName)
            return Item(key: key, exercise: diffExercise)
        }
    }

    private static func headerChanges(before: WorkoutPlan, after: WorkoutPlan) -> [String] {
        var changes: [String] = []
        if normalize(before.name) != normalize(after.name) {
            changes.append("Renamed to \u{201C}\(after.name)\u{201D}")
        }
        if before.tags.map(normalize) != after.tags.map(normalize) {
            changes.append(after.tags.isEmpty ? "Tags removed" : "Tags: \(after.tags.joined(separator: ", "))")
        }
        if before.defaultWeightUnit != after.defaultWeightUnit {
            changes.append(after.defaultWeightUnit.map { "Units: \($0.rawValue)" } ?? "Units removed")
        }
        let beforeNotes = before.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let afterNotes = after.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if beforeNotes != afterNotes {
            changes.append(afterNotes.isEmpty ? "Workout notes removed" : "Workout notes changed")
        }
        return changes
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
