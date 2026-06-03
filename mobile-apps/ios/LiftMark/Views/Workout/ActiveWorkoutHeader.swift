import SwiftUI

/// Top bar for the active workout screen with pause, notes, and finish controls.
///
/// Add Exercise is intentionally NOT in the top bar — it lives as a primary-styled
/// bottom action button (see `ActiveWorkoutFooter`) so the top cluster stays
/// readable on iPhone and the add action is larger and easier to hit mid-workout.
struct ActiveWorkoutHeader: View {
    let sessionName: String
    /// True when the active session already has non-empty notes. Used to badge the
    /// notes button so the user can see, at a glance, that notes exist.
    var hasNotes: Bool = false
    let onPause: () -> Void
    let onNotes: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Button {
                onPause()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pause.fill")
                        .font(.lmCaption)
                    Text("Pause")
                        .font(.lmSubheadline)
                }
            }
            .accessibilityIdentifier("active-workout-pause-button")
            .accessibilityLabel("Pause workout")
            .accessibilityHint("Returns to home screen without ending the workout")

            Spacer()

            Text(sessionName)
                .font(.lmHeadline)
                .lineLimit(1)

            Spacer()

            Button {
                onNotes()
            } label: {
                Image(systemName: hasNotes ? "note.text" : "square.and.pencil")
            }
            .accessibilityIdentifier("active-workout-notes-button")
            .accessibilityLabel(hasNotes ? "Edit workout notes" : "Add workout notes")
            .accessibilityHint("Opens a free-text editor for notes on this workout")

            Button {
                onFinish()
            } label: {
                Text("Finish")
                    .font(.lmSubheadline.bold())
            }
            .accessibilityIdentifier("active-workout-finish-button")
            .accessibilityLabel("Finish workout")
            .accessibilityHint("Completes and saves the workout session")
        }
        .padding()
        .background(LiftMarkTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("active-workout-header")
    }
}

/// Bottom action bar for the active workout screen.
///
/// Houses the primary **Add Exercise** button (moved out of the cramped top bar,
/// per #98) and a secondary bottom **Finish** button (per #99) so the user does not
/// have to reach back up to the top-right corner on large iPhones. The top-bar
/// Finish button is preserved for users who end from the top.
struct ActiveWorkoutFooter: View {
    let onAddExercise: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Button {
                onAddExercise()
            } label: {
                Label("Add Exercise", systemImage: "plus")
                    .font(.lmFootnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityIdentifier("active-workout-add-exercise-button")
            .accessibilityLabel("Add exercise")
            .accessibilityHint("Opens a sheet to add a new exercise to this workout")

            Button {
                onFinish()
            } label: {
                // Bottom button uses a distinct label from the top-bar "Finish" so
                // text-based UI test matchers (which search for `Finish`, `Finish Anyway`,
                // `Log Anyway` in confirm alerts) can't accidentally match this button
                // when the confirm alert is what should be hit.
                Text("End Workout")
                    .font(.lmFootnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Capsule())
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityIdentifier("active-workout-footer-finish-button")
            .accessibilityLabel("End workout")
            .accessibilityHint("Completes and saves the workout session")
        }
        .padding(.horizontal)
        .padding(.vertical, LiftMarkTheme.spacingSM)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("active-workout-footer")
    }
}

/// Progress bar showing completed and skipped sets.
///
/// Two-tone fill: blue for logged sets, orange (`LiftMarkTheme.warning`) for
/// skipped sets, and the remaining track in grey. A single-tone bar made an
/// all-but-finished workout look like the user had missed several sets — the
/// orange segment makes the "done, just not logged" share legible at a glance.
struct ActiveWorkoutProgressBar: View {
    let completedSets: Int
    let skippedSets: Int
    let totalSets: Int

    private var completedFraction: Double {
        totalSets > 0 ? Double(completedSets) / Double(totalSets) : 0
    }

    private var skippedFraction: Double {
        totalSets > 0 ? Double(skippedSets) / Double(totalSets) : 0
    }

    private var doneSets: Int { completedSets + skippedSets }

    private var completedColor: Color {
        doneSets >= totalSets && skippedSets == 0 ? LiftMarkTheme.success : LiftMarkTheme.primary
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LiftMarkTheme.tertiaryLabel.opacity(0.25))
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(completedColor)
                            .frame(width: geo.size.width * completedFraction)
                        Rectangle()
                            .fill(LiftMarkTheme.warning)
                            .frame(width: geo.size.width * skippedFraction)
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 4)
            Text("\(doneSets) / \(totalSets) sets done")
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
        }
        .padding(.horizontal)
        .padding(.bottom, LiftMarkTheme.spacingSM)
        .accessibilityIdentifier("active-workout-progress")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workout progress")
        .accessibilityValue(skippedSets > 0
            ? "\(completedSets) logged, \(skippedSets) skipped of \(totalSets) sets"
            : "\(completedSets) of \(totalSets) sets completed")
    }
}
