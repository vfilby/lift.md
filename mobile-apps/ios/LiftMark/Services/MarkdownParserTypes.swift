import Foundation

// MARK: - Parse Result Types

struct LMWFParseResult {
    let success: Bool
    let data: WorkoutPlan?
    let errors: [String]
    let warnings: [String]
    /// Source-line spans for each parsed exercise/group, keyed by the exercise's
    /// `orderIndex`. Lets a caller locate and replace an exercise's exact block
    /// within the original markdown (see `LMWFSourceEditor`) instead of
    /// regenerating the whole document and flattening header levels. Empty on
    /// parse failure and for callers that don't need it.
    var exerciseSpans: [Int: LMWFSourceSpan] = [:]
}

/// The source-line footprint of one exercise (or group) inside a markdown
/// document. Line numbers are 1-based and match `ParsedLine.lineNumber` (i.e.
/// the document with CRLF/CR normalized to LF, split on `\n`).
struct LMWFSourceSpan: Equatable {
    /// 1-based line of this block's header (the `#…` line).
    let startLine: Int
    /// 1-based line of the last content line of the block. Trailing blank lines
    /// that merely separate this block from the next are excluded, so a splice
    /// leaves the surrounding whitespace intact.
    let endLine: Int
    /// Number of `#` on this block's header.
    let headerLevel: Int
    /// For a section/superset parent: the header level of its child exercises.
    /// Supersets may nest children at any level below the parent, so this is the
    /// level actually found in the source rather than an assumed `parent + 1`.
    let childHeaderLevel: Int?
}

struct ParseError {
    let line: Int
    let message: String
    let code: String
}

struct ParseWarning {
    let line: Int
    let message: String
    let code: String
}

// MARK: - Internal Parse Types

struct ParsedLine {
    let lineNumber: Int
    let raw: String
    let trimmed: String
    var headerLevel: Int?
    var headerText: String?
    var isList: Bool = false
    var listContent: String?
    var isMetadata: Bool = false
    var metadataKey: String?
    var metadataValue: String?
}

class ParseContext {
    var lines: [ParsedLine]
    var currentIndex: Int = 0
    var workoutHeaderLevel: Int?
    var exerciseHeaderLevel: Int?
    var errors: [ParseError] = []
    var warnings: [ParseWarning] = []
    /// Source spans collected during parsing, keyed by exercise `orderIndex`.
    var spans: [Int: LMWFSourceSpan] = [:]

    init(lines: [ParsedLine]) {
        self.lines = lines
    }

    /// The last content line of a block spanning source-array indices
    /// `[startIndex, stopIndex)`, skipping trailing blank lines. `stopIndex` is
    /// the first line *after* the block (`currentIndex` once the block is fully
    /// consumed, or `lines.count` at EOF).
    func blockEndLine(startIndex: Int, stopIndex: Int) -> Int {
        var endIndex = min(stopIndex, lines.count) - 1
        while endIndex > startIndex && lines[endIndex].trimmed.isEmpty {
            endIndex -= 1
        }
        return lines[endIndex].lineNumber
    }
}

struct ParsedSet {
    var weight: Double?
    var weightUnit: WeightUnit?
    var reps: Int?
    var time: Int? // seconds
    var distance: Double?
    var distanceUnit: DistanceUnit?
    var isAmrap: Bool?
    var rpe: Double?
    var rest: Int? // seconds
    var tempo: String?
    var isDropset: Bool?
    var isPerSide: Bool?
    var notes: String?
}

struct WorkoutSection {
    let name: String
    let tags: [String]
    let defaultWeightUnit: WeightUnit?
    let notes: String?
}
