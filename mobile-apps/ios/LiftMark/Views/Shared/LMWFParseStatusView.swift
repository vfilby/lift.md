import SwiftUI

// MARK: - LMWF Parse Status

/// What the markdown editors show beneath the text: the first parse error, or a
/// success summary plus warnings. Shared by `EditPlanMarkdownSheet` and `ImportView`.
struct LMWFParseStatus: Equatable {
    struct Summary: Equatable {
        let name: String
        let exerciseCount: Int
        let setCount: Int
    }

    /// First parser error, if parsing failed.
    var error: String?
    /// Parsed summary, if parsing succeeded.
    var summary: Summary?
    var warnings: [String] = []
    /// Quick fixes the parser offered (see `LMWFQuickFix`).
    var fixes: [LMWFQuickFix] = []

    /// Build the status for `markdown`. Parses the text as-is (not trimmed) so the
    /// line numbers in diagnostics and fixes match the editor's lines. Nil when the
    /// text is blank — the editors show nothing in that case.
    static func parse(_ markdown: String) -> LMWFParseStatus? {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let result = MarkdownParser.parseWorkout(markdown)
        if !result.errors.isEmpty {
            return LMWFParseStatus(error: result.errors.first ?? "Parse error", fixes: result.fixes)
        }
        return LMWFParseStatus(
            summary: Summary(
                name: result.data?.name ?? "Untitled",
                exerciseCount: result.data?.displayExerciseCount ?? 0,
                setCount: result.data?.plannedSetCount ?? 0
            ),
            warnings: result.warnings,
            fixes: result.fixes
        )
    }
}

// MARK: - LMWF Parse Status View

/// Inline parse feedback for a markdown editor: a red error row, or a green summary
/// row followed by orange warnings. When the parser supplied quick fixes, a trailing
/// **Fix** button applies them all to the editor text (GH #472 — `#push day` used to
/// yield only "No workout header found" with nothing pointing at the missing space).
struct LMWFParseStatusView: View {
    let status: LMWFParseStatus
    /// Prefix for accessibility identifiers: `{prefix}-error`, `{prefix}-fix-button`.
    let idPrefix: String
    /// Called with the fixes to apply when the user taps Fix.
    let onApplyFixes: ([LMWFQuickFix]) -> Void

    var body: some View {
        if let error = status.error {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LiftMarkTheme.destructive)
                Text(error)
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.destructive)
                Spacer()
                fixButton
            }
            .padding(.horizontal)
            .padding(.vertical, LiftMarkTheme.spacingSM)
            .background(LiftMarkTheme.destructive.opacity(0.1))
            // A container, so the row's id doesn't propagate onto the Fix button.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(idPrefix)-error")
        }

        if let summary = status.summary {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LiftMarkTheme.success)
                Text("\(summary.name) - \(summary.exerciseCount) exercises, \(summary.setCount) sets")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.success)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, LiftMarkTheme.spacingSM)
            .background(LiftMarkTheme.success.opacity(0.1))

            if !status.warnings.isEmpty {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(status.warnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.lmCaption2)
                                    .foregroundStyle(LiftMarkTheme.warning)
                                Text(warning)
                                    .font(.lmCaption2)
                                    .foregroundStyle(LiftMarkTheme.warning)
                            }
                        }
                    }
                    Spacer()
                    fixButton
                }
                .padding(.horizontal)
                .padding(.vertical, LiftMarkTheme.spacingXS)
            }
        }
    }

    @ViewBuilder
    private var fixButton: some View {
        if !status.fixes.isEmpty {
            Button("Fix") {
                onApplyFixes(status.fixes)
            }
            .font(.lmCaption)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityIdentifier("\(idPrefix)-fix-button")
        }
    }
}
