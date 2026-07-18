import SwiftUI

// MARK: - Sparkline View

struct SparklineView: View {
    let values: [Double]

    private var trend: String {
        guard values.count >= 2 else { return "\u{2192}" }
        let last = values[values.count - 1]
        let previous = values[values.count - 2]
        let change = last - previous
        let threshold = previous * 0.02 // 2% threshold for flat
        if change > threshold {
            return "\u{2197}" // ↗
        } else if change < -threshold {
            return "\u{2198}" // ↘
        } else {
            return "\u{2192}" // →
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                let height: CGFloat = 32
                let minVal = values.min() ?? 0
                let maxVal = values.max() ?? 1
                let range = maxVal - minVal
                let safeRange = range == 0 ? 1.0 : range

                let points: [CGPoint] = values.enumerated().map { index, value in
                    let x = values.count > 1
                        ? width * CGFloat(index) / CGFloat(values.count - 1)
                        : width / 2
                    let y = height - (height * CGFloat(value - minVal) / CGFloat(safeRange))
                    return CGPoint(x: x, y: y)
                }

                ZStack {
                    // Filled area under the line
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: CGPoint(x: first.x, y: height))
                        path.addLine(to: first)
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                        if let last = points.last {
                            path.addLine(to: CGPoint(x: last.x, y: height))
                        }
                        path.closeSubpath()
                    }
                    .fill(LiftMarkTheme.primary.opacity(0.08))

                    // Line
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(LiftMarkTheme.primary, lineWidth: 1.5)

                    // Rightmost dot
                    if let last = points.last {
                        Circle()
                            .fill(LiftMarkTheme.primary)
                            .frame(width: 5, height: 5)
                            .position(last)
                    }
                }
            }
            .frame(height: 32)

            // Label
            Text("\(values.count) sessions \(trend)")
                .font(.lmCaption2)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
        }
    }
}

// MARK: - Max Lift Tile

struct MaxLiftTile: View {
    let exerciseName: String
    let maxWeight: Double?
    let unit: WeightUnit
    let isRegularWidth: Bool
    let sparklineData: [Double]
    let onLongPress: () -> Void

    var body: some View {
        VStack(spacing: LiftMarkTheme.spacingXS) {
            Text(exerciseName)
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .lineLimit(1)

            if let weight = maxWeight {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatWeight(weight))
                        .font(.lmTitle2.bold())
                    Text(unit.rawValue)
                        .font(.lmCaption2)
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                }
            } else {
                Text("\u{2014}")
                    .font(.lmTitle2.bold())
                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                Text("No data yet")
                    .font(.lmCaption2)
                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
            }

            if isRegularWidth && sparklineData.count >= 2 {
                SparklineView(values: sparklineData)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding(LiftMarkTheme.spacingLG)
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .onLongPressGesture(minimumDuration: 0.4) {
            onLongPress()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(maxWeight != nil
            ? "\(exerciseName), \(formatWeight(maxWeight!)) \(unit.rawValue)"
            : "\(exerciseName), no data yet")
        .accessibilityHint("Long press to change exercise")
    }

    private func formatWeight(_ weight: Double) -> String {
        weight.formattedWeight
    }
}

// MARK: - Workout Plan Card

struct WorkoutPlanCard: View {
    let plan: WorkoutPlan

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: LiftMarkTheme.spacingXS) {
                    Text(plan.name)
                        .font(.lmHeadline)
                        .foregroundStyle(LiftMarkTheme.label)
                    if plan.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.lmCaption)
                            .foregroundStyle(.pink)
                            .accessibilityHidden(true)
                    }
                }
                HStack(spacing: LiftMarkTheme.spacingSM) {
                    Text("\(plan.displayExerciseCount) exercises")
                        .font(.lmSubheadline)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    if !plan.tags.isEmpty {
                        Text(plan.tags.prefix(2).joined(separator: ", "))
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .padding()
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(plan.name)\(plan.isFavorite ? ", favorite" : ""), \(plan.displayExerciseCount) exercises"
            + "\(!plan.tags.isEmpty ? ", " + plan.tags.prefix(2).joined(separator: ", ") : "")")
    }
}
