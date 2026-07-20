import Foundation

// MARK: - MarkdownParser Document Structure

extension MarkdownParser {

    // MARK: - Workout Header Detection

    /// Find the workout header — first header that has child headers with sets
    static func findWorkoutHeader(_ context: ParseContext) -> ParsedLine? {
        for i in 0..<context.lines.count {
            let line = context.lines[i]
            if let headerLevel = line.headerLevel, line.headerText != nil {
                if hasChildExercises(context, headerIndex: i, headerLevel: headerLevel) {
                    context.workoutHeaderLevel = headerLevel
                    context.exerciseHeaderLevel = headerLevel + 1
                    context.currentIndex = i
                    return line
                }
            }
        }
        return nil
    }

    /// Check if a header has child exercise headers (with sets)
    private static func hasChildExercises(_ context: ParseContext, headerIndex: Int, headerLevel: Int) -> Bool {
        let exerciseLevel = headerLevel + 1

        for i in (headerIndex + 1)..<context.lines.count {
            let line = context.lines[i]

            // Stop if we hit a header at same or higher level
            if let level = line.headerLevel, level <= headerLevel {
                break
            }

            // Check if this is an exercise header (one level below workout)
            if line.headerLevel == exerciseLevel {
                if hasSetsBelowHeader(context, headerIndex: i, headerLevel: exerciseLevel) {
                    return true
                }
            }
        }

        return false
    }

    /// Check if a header has sets below it (or nested headers with sets)
    static func hasSetsBelowHeader(_ context: ParseContext, headerIndex: Int, headerLevel: Int) -> Bool {
        for i in (headerIndex + 1)..<context.lines.count {
            let line = context.lines[i]

            // Stop if we hit a header at same or higher level
            if let level = line.headerLevel, level <= headerLevel {
                break
            }

            // Found a set
            if line.isList {
                return true
            }

            // Check nested headers (for supersets/sections)
            if let level = line.headerLevel, level > headerLevel {
                if hasSetsBelowHeader(context, headerIndex: i, headerLevel: level) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Workout Section Parsing

    static func parseWorkoutSection(_ context: ParseContext, headerLine: ParsedLine) -> WorkoutSection {
        let name = headerLine.headerText ?? ""
        var tags: [String] = []
        var defaultWeightUnit: WeightUnit?
        var noteLines: [String] = []

        // Move past header
        context.currentIndex += 1

        // Collect metadata and notes until we hit an exercise header
        while context.currentIndex < context.lines.count {
            let line = context.lines[context.currentIndex]

            // Stop at exercise header
            if line.headerLevel == context.exerciseHeaderLevel {
                break
            }

            // Stop at headers higher than workout level
            if let level = line.headerLevel, let workoutLevel = context.workoutHeaderLevel, level <= workoutLevel {
                break
            }

            // Parse metadata
            if line.isMetadata {
                if line.metadataKey == "tags" {
                    tags = parseTagsMetadata(line.metadataValue ?? "")
                } else if line.metadataKey == "units" {
                    if let unit = parseUnitsMetadata(
                        line.metadataValue ?? "", context: context, lineNumber: line.lineNumber
                    ) {
                        defaultWeightUnit = unit
                    }
                }
                // Ignore unknown metadata (forward compatible)
            } else if !line.trimmed.isEmpty {
                // Collect freeform notes (non-empty, non-metadata lines)
                noteLines.append(line.trimmed)
            }

            context.currentIndex += 1
        }

        return WorkoutSection(
            name: name,
            tags: tags,
            defaultWeightUnit: defaultWeightUnit,
            notes: noteLines.isEmpty ? nil : noteLines.joined(separator: "\n")
        )
    }

    /// Parse @tags metadata: "tag1, tag2, tag3" -> ["tag1", "tag2", "tag3"]
    private static func parseTagsMetadata(_ value: String) -> [String] {
        value.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parse @units metadata: "lbs" or "kg"
    private static func parseUnitsMetadata(_ value: String, context: ParseContext, lineNumber: Int) -> WeightUnit? {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "lbs", "lb":
            return .lbs
        case "kg", "kgs":
            return .kg
        default:
            context.errors.append(ParseError(
                line: lineNumber,
                message: "Invalid @units value \"\(value)\". Must be \"lbs\" or \"kg\"",
                code: "INVALID_UNITS"
            ))
            return nil
        }
    }
}
