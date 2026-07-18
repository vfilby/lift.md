import Foundation

/// Encodes a completed `WorkoutSession` to LiftMark Workout Format (LMWF).
///
/// Session-level freeform notes are serialized using the existing LMWF
/// convention: any text block placed after the workout header (and after any
/// `@tags` / `@units` metadata) but before the first exercise is treated as
/// workout notes. This keeps LMWF a single canonical format — plans and
/// completed sessions share the same syntax, so a session can be exported,
/// imported, and round-tripped without a format change.
///
/// Only the details needed to round-trip structured data are emitted:
/// exercise name, sets (actual values preferred, falling back to target),
/// exercise notes, rest modifiers, per-side / dropset / AMRAP flags.
enum SessionLMWFEncoder {

    /// Render the session to an LMWF markdown string.
    static func encode(_ session: WorkoutSession) -> String {
        var lines: [String] = []
        lines.append("# \(session.name)")

        // Freeform workout notes (this is the round-trip slot for session-level notes).
        if let notes = session.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("")
            lines.append(contentsOf: notes.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }

        // Render exercises, preserving grouping (sections, supersets).
        let grouped = groupExercises(session.exercises)
        for group in grouped {
            lines.append("")
            lines.append(contentsOf: renderGroup(group))
        }

        // Collapse any runs of 3+ blank lines to two (cosmetic).
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            + "\n"
    }

    // MARK: - Grouping

    private enum ExerciseGroup {
        case single(SessionExercise)
        case section(parent: SessionExercise, children: [SessionExercise])
        case superset(parent: SessionExercise, children: [SessionExercise])
    }

    private static func groupExercises(_ exercises: [SessionExercise]) -> [ExerciseGroup] {
        var result: [ExerciseGroup] = []
        var processed = Set<String>()

        for exercise in exercises {
            if processed.contains(exercise.id) { continue }

            // Group parent? Collect children from the same list.
            if let gt = exercise.groupType, exercise.sets.isEmpty, gt == .section || gt == .superset {
                let children = exercises.filter { $0.parentExerciseId == exercise.id }
                processed.insert(exercise.id)
                for child in children { processed.insert(child.id) }
                if gt == .section {
                    result.append(.section(parent: exercise, children: children))
                } else {
                    result.append(.superset(parent: exercise, children: children))
                }
                continue
            }

            // Skip orphan children already attributed to a group (defensive).
            if exercise.parentExerciseId != nil { continue }

            processed.insert(exercise.id)
            result.append(.single(exercise))
        }
        return result
    }

    // MARK: - Rendering

    private static func renderGroup(_ group: ExerciseGroup) -> [String] {
        switch group {
        case .single(let ex):
            return renderExercise(ex, headerPrefix: "##")
        case .section(let parent, let children):
            var out: [String] = ["## \(parent.groupName ?? parent.exerciseName)"]
            for (i, child) in children.enumerated() {
                if i > 0 { out.append("") }
                out.append(contentsOf: renderExercise(child, headerPrefix: "###"))
            }
            return out
        case .superset(let parent, let children):
            var out: [String] = ["## \(parent.groupName ?? parent.exerciseName)"]
            for (i, child) in children.enumerated() {
                if i > 0 { out.append("") }
                out.append(contentsOf: renderExercise(child, headerPrefix: "###"))
            }
            return out
        }
    }

    private static func renderExercise(_ exercise: SessionExercise, headerPrefix: String) -> [String] {
        var lines: [String] = ["\(headerPrefix) \(exercise.exerciseName)"]
        if let equipment = exercise.equipmentType, !equipment.isEmpty {
            lines.append("@type: \(equipment)")
        }
        if let notes = exercise.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("")
            lines.append(contentsOf: notes.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
        // Blank line before set list if we emitted any metadata/notes.
        if lines.count > 1 { lines.append("") }
        for set in exercise.sets {
            if let line = renderSet(set) {
                lines.append(line)
            }
        }
        return lines
    }

    private static func renderSet(_ set: SessionSet) -> String? {
        // Prefer actual (performed) values; fall back to target (skipped / pending sets).
        let entry = set.entries.first
        let source = entry?.actual ?? entry?.target
        guard let source else { return nil }

        var tokens: [String] = []

        if let weight = source.weight {
            let weightStr = formatNumber(weight.value)
            tokens.append("\(weightStr) \(weight.unit.rawValue)")
        }

        if let time = source.time {
            // Weighted time: "45 lbs x 60s". Bodyweight time: "60s".
            if !tokens.isEmpty {
                tokens.append("x \(time)s")
            } else {
                tokens.append("\(time)s")
            }
        } else if set.isAmrap {
            if tokens.isEmpty {
                tokens.append("AMRAP")
            } else {
                tokens.append("x AMRAP")
            }
        } else if let reps = source.reps {
            if tokens.isEmpty {
                tokens.append("\(reps)")
            } else {
                tokens.append("x \(reps)")
            }
        } else if let distance = source.distance {
            tokens.append("\(formatNumber(distance.value)) \(distance.unit.rawValue)")
        } else {
            // No numeric info — nothing to emit.
            return nil
        }

        var line = "- " + tokens.joined(separator: " ")

        // Functional modifiers — order matches the spec's documented examples.
        if let rest = set.restSeconds, rest > 0 {
            line += " @rest: \(rest)s"
        }
        if set.isDropset {
            line += " @dropset"
        }
        if set.isPerSide {
            line += " @perside"
        }
        return line
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))"
        }
        return String(format: "%g", value)
    }
}
