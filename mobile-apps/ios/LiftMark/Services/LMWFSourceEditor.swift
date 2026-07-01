import Foundation

/// Applies an in-app exercise edit to a plan's `sourceMarkdown` by splicing the
/// single edited block back into the original document, instead of regenerating
/// the whole plan from the parsed model.
///
/// Regenerating the entire document (the pre-GH #264 behavior) flattened every
/// header to `##`, so `## Warmup` / `### Band Side Step` collapsed to two `##`
/// headers — breaking the section nesting and forcing the user to hand-repair
/// header levels before they could save again. It also discarded anything the
/// model doesn't round-trip: blank-line layout, comments, and unknown
/// `@metadata`.
///
/// This splice preserves everything the user didn't touch. It locates the edited
/// exercise's exact source span (via the parser, which owns the nesting rules),
/// renders only that block at the header level(s) found in the source, and
/// replaces those lines. Editing an exercise is therefore equivalent to
/// replacing that one section of the markdown with the user's edited version.
enum LMWFSourceEditor {

    /// Return `source` with the block for the exercise at `orderIndex` replaced
    /// by a re-render of `edited`, or `nil` if the block can't be located or the
    /// result wouldn't parse (caller should then leave `sourceMarkdown`
    /// untouched rather than risk corrupting it).
    ///
    /// - `edited` is the replacement unit as returned by the edit sheet: a single
    ///   element for a normal exercise or section child, or `[parent, child…]`
    ///   for a superset block.
    static func replacingExercise(
        orderIndex: Int,
        in source: String,
        with edited: [PlannedExercise]
    ) -> String? {
        guard let parent = edited.first else { return nil }

        let result = MarkdownParser.parseWorkout(source)
        guard result.success, let span = result.exerciseSpans[orderIndex] else { return nil }

        let blockLines: [String]
        if edited.count == 1 {
            blockLines = renderExercise(parent, level: span.headerLevel)
        } else {
            let childLevel = span.childHeaderLevel ?? (span.headerLevel + 1)
            blockLines = renderGroup(
                parent: parent,
                children: Array(edited.dropFirst()),
                parentLevel: span.headerLevel,
                childLevel: childLevel
            )
        }

        let spliced = splice(source, startLine: span.startLine, endLine: span.endLine, with: blockLines)

        // Never hand back markdown that won't round-trip — a silent parse failure
        // downstream would drop the user's edit.
        guard MarkdownParser.parseWorkout(spliced).success else { return nil }
        return spliced
    }

    // MARK: - Splicing

    /// Replace source lines `[startLine, endLine]` (1-based, inclusive) with
    /// `newLines`. Newlines are normalized to LF first so line indices match the
    /// parser's `lineNumber`s exactly; surrounding blank lines are untouched.
    static func splice(_ source: String, startLine: Int, endLine: Int, with newLines: [String]) -> String {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")

        let startIndex = startLine - 1
        let endIndex = endLine - 1
        guard startIndex >= 0, endIndex >= startIndex, endIndex < lines.count else {
            return source
        }

        lines.replaceSubrange(startIndex...endIndex, with: newLines)
        return lines.joined(separator: "\n")
    }

    // MARK: - Rendering

    private static func headerPrefix(_ level: Int) -> String {
        String(repeating: "#", count: max(1, level))
    }

    /// Render a section/superset parent header plus its children, each child one
    /// block at `childLevel`.
    private static func renderGroup(
        parent: PlannedExercise,
        children: [PlannedExercise],
        parentLevel: Int,
        childLevel: Int
    ) -> [String] {
        // `exerciseName` is the header text the parser reads back (and the field
        // the edit sheet updates on rename); `groupName` can lag behind it.
        var lines: [String] = ["\(headerPrefix(parentLevel)) \(parent.exerciseName)"]
        appendNotes(parent.notes, to: &lines)
        for child in children {
            lines.append("")
            lines.append(contentsOf: renderExercise(child, level: childLevel))
        }
        return lines
    }

    /// Render a single exercise block: header, optional `@type`, notes, sets.
    private static func renderExercise(_ exercise: PlannedExercise, level: Int) -> [String] {
        var lines: [String] = ["\(headerPrefix(level)) \(exercise.exerciseName)"]
        if let equip = exercise.equipmentType, !equip.isEmpty {
            lines.append("@type: \(equip)")
        }
        appendNotes(exercise.notes, to: &lines)
        for set in exercise.sets {
            if let line = renderSet(set) {
                lines.append(line)
            }
        }
        return lines
    }

    private static func appendNotes(_ notes: String?, to lines: inout [String]) {
        guard let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else { return }
        lines.append(contentsOf: notes.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    /// Render one set line, or `nil` when the set carries no numeric target
    /// (nothing meaningful to emit). Mirrors the LMWF the parser accepts and the
    /// completed-session encoder produces.
    private static func renderSet(_ set: PlannedSet) -> String? {
        let target = set.entries.first?.target
        var tokens: [String] = []

        if let weight = target?.weight {
            tokens.append(weight.value.formattedWeight)
            tokens.append(weight.unit.rawValue)
        }

        if let time = target?.time {
            tokens.append(tokens.isEmpty ? "\(time)s" : "x \(time)s")
        } else if set.isAmrap {
            tokens.append(tokens.isEmpty ? "AMRAP" : "x AMRAP")
        } else if let reps = target?.reps {
            tokens.append(tokens.isEmpty ? "\(reps)" : "x \(reps)")
        } else if let distance = target?.distance {
            tokens.append(distance.value.formattedWeight)
            tokens.append(distance.unit.rawValue)
        } else {
            // No reps/time/AMRAP/distance — a bare weight isn't a valid set.
            return nil
        }

        var line = "- " + tokens.joined(separator: " ")
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
}
