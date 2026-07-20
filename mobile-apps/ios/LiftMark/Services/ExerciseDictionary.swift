import Foundation

struct ExerciseDefinition: Codable {
    let canonical: String
    let aliases: [String]
    let muscleGroups: [String]
    let category: String
}

/// Provides canonical name resolution and alias lookup for exercises.
/// Loads from exercise-dictionary.json bundled in the app.
enum ExerciseDictionary {
    // MARK: - Lazy-loaded maps

    /// Map from lowercase alias/canonical → canonical name
    private static let aliasToCanonical: [String: String] = {
        var map: [String: String] = [:]
        for entry in definitions {
            map[entry.canonical.lowercased()] = entry.canonical
            for alias in entry.aliases {
                map[alias.lowercased()] = entry.canonical
            }
        }
        return map
    }()

    /// Map from lowercase canonical → full definition
    private static let canonicalToDefinition: [String: ExerciseDefinition] = {
        var map: [String: ExerciseDefinition] = [:]
        for entry in definitions {
            map[entry.canonical.lowercased()] = entry
        }
        return map
    }()

    /// All definitions loaded from JSON
    private static let definitions: [ExerciseDefinition] = {
        guard let url = Bundle.main.url(forResource: "exercise-dictionary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let defs = try? JSONDecoder().decode([ExerciseDefinition].self, from: data) else {
            return []
        }
        return defs
    }()

    // MARK: - Public API

    /// Get the canonical (display-preferred) name for an exercise.
    /// Returns the original name if not found in the dictionary.
    static func getCanonicalName(_ name: String) -> String {
        aliasToCanonical[name.lowercased()] ?? name
    }

    /// Check if two exercise names refer to the same movement.
    static func isSameExercise(_ lhs: String, _ rhs: String) -> Bool {
        getCanonicalName(lhs) == getCanonicalName(rhs)
    }

    /// Get all lowercase aliases (including the canonical name lowercased)
    /// for a given exercise name. Useful for building SQL IN clauses.
    /// Returns a single-element array with the lowercased input if not found.
    static func getAliases(_ name: String) -> [String] {
        guard let canonical = aliasToCanonical[name.lowercased()],
              let definition = canonicalToDefinition[canonical.lowercased()] else {
            return [name.lowercased()]
        }
        return [definition.canonical.lowercased()] + definition.aliases.map { $0.lowercased() }
    }

    /// Get the full exercise definition for a name (canonical or alias).
    /// Returns nil if not found in the dictionary.
    static func getDefinition(_ name: String) -> ExerciseDefinition? {
        guard let canonical = aliasToCanonical[name.lowercased()] else { return nil }
        return canonicalToDefinition[canonical.lowercased()]
    }
}
