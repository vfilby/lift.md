import SwiftUI

// MARK: - Full preview sheet

/// The sheet opened by holding an inline diff: that turn's proposed plan in
/// full, with the same highlighting. Read-only; Apply and Discard stay on the
/// Edit with AI sheet beneath. See `spec/screens/workout-detail.md`
/// ("AI Edit Sheet", full preview).
struct PlanEditFullPreviewSheet: View {
    /// Nil when the proposed markdown does not parse.
    let preview: PlanEditPreview?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlanEditPreviewView(preview: preview)
                .navigationTitle(PlanEditLabels.fullPreviewTitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("ai-edit-preview-done")
                    }
                }
        }
    }
}

// MARK: - Preview

/// A plan rendered as its sectioned exercise list, rows highlighted per the
/// `PlanEditPreview`'s diff. Fills the full preview sheet.
struct PlanEditPreviewView: View {
    /// Nil when the markdown does not parse.
    let preview: PlanEditPreview?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                if let preview {
                    header(preview)
                    ForEach(preview.sections) { section in
                        if let name = section.name {
                            WorkoutSectionHeader(name: name)
                        }
                        ForEach(section.items) { item in
                            switch item {
                            case .exercise(let row):
                                PlanEditPreviewRowView(row: row)
                            case .superset(_, let name, let rows):
                                PlanEditPreviewSupersetView(name: name, rows: rows)
                            }
                        }
                    }
                } else {
                    Text(PlanEditLabels.previewUnavailable)
                        .font(.lmSubheadline)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, LiftMarkTheme.spacingXL)
                }
            }
            .padding(LiftMarkTheme.spacingMD)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-edit-preview-full")
    }

    private func header(_ preview: PlanEditPreview) -> some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            Text(preview.title)
                .font(.lmTitle3)
                .foregroundStyle(LiftMarkTheme.label)
            if !preview.tags.isEmpty {
                Text(preview.tags.joined(separator: " \u{00B7} "))
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
            ForEach(preview.headerChanges, id: \.self) { change in
                Label(change, systemImage: "doc.text")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.warning)
            }
        }
    }
}

// MARK: - Superset

/// A superset group in the preview: the purple frame used by
/// `PlanSupersetCard`, with member rows inside.
struct PlanEditPreviewSupersetView: View {
    let name: String
    let rows: [PlanEditPreviewRow]

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SUPERSET \u{00B7} \(rows.count) EXERCISES")
                    .font(.lmCaption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.purple)
                Text(name)
                    .font(.lmCallout)
                    .fontWeight(.semibold)
                    .foregroundStyle(LiftMarkTheme.label)
            }
            ForEach(rows) { row in
                PlanEditPreviewRowView(row: row)
            }
        }
        .padding(LiftMarkTheme.spacingSM)
        .background(Color.purple.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
    }
}

// MARK: - Row

/// One exercise row. Highlighted kinds tint the row and show a marker in the
/// leading column; removed rows strike through their text and changed rows
/// show the previous set lines struck through above the new ones.
///
/// `.card` is the full preview's padded, tinted card. `.inline` is the bare
/// form used inside a transcript bubble: no card, smaller set lines, and the
/// enclosing superset or section named after the exercise since the bubble
/// has no surrounding structure to place the row in.
struct PlanEditPreviewRowView: View {
    enum Style {
        case card
        case inline
    }

    let row: PlanEditPreviewRow
    var style: Style = .card

    @ScaledMetric(relativeTo: .subheadline) private var markerWidth: CGFloat = 16

    private var tint: Color? {
        switch row.kind {
        case .unchanged: return nil
        case .added: return LiftMarkTheme.success
        case .removed: return LiftMarkTheme.destructive
        case .changed: return LiftMarkTheme.warning
        }
    }

    private var isRemoved: Bool { row.kind == .removed }
    private var isInline: Bool { style == .inline }

    var body: some View {
        HStack(alignment: .top, spacing: LiftMarkTheme.spacingSM) {
            Text(row.kind.marker ?? "")
                .font(.lmMono(size: 15, relativeTo: .subheadline))
                .fontWeight(.bold)
                .foregroundStyle(tint ?? LiftMarkTheme.tertiaryLabel)
                .frame(width: markerWidth, alignment: .center)
                .accessibilityHidden(row.kind.marker == nil)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: LiftMarkTheme.spacingSM) {
                    Text(row.name)
                        .font(isInline ? .lmSubheadline : .lmCallout)
                        .fontWeight(.semibold)
                        .foregroundStyle(isRemoved ? LiftMarkTheme.secondaryLabel : LiftMarkTheme.label)
                        .strikethrough(isRemoved)
                    if let equipment = row.equipmentType {
                        Text(equipment)
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    }
                    if isInline, let parent = row.parent {
                        Text("in \(parent)")
                            .font(.lmCaption2)
                            .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                    }
                }
                if !isInline, let notes = row.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.lmCaption)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        .italic()
                        .strikethrough(isRemoved)
                }
                if row.kind == .changed {
                    setLines(row.previousLines, color: LiftMarkTheme.tertiaryLabel, strike: true)
                }
                setLines(row.lines, color: LiftMarkTheme.secondaryLabel, strike: isRemoved)
            }
            Spacer(minLength: 0)
        }
        .padding(isInline ? 0 : LiftMarkTheme.spacingSM)
        .background(isInline ? Color.clear : (tint.map { $0.opacity(0.12) } ?? LiftMarkTheme.secondaryBackground))
        .clipShape(RoundedRectangle(cornerRadius: isInline ? 0 : LiftMarkTheme.cornerRadiusMD))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    @ViewBuilder
    private func setLines(_ lines: [String], color: Color, strike: Bool) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(isInline ? .lmCaption : .lmSubheadline)
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .strikethrough(strike)
                }
            }
        }
    }
}
