import SwiftUI

/// Countdown rest timer displayed inline after completing a set.
///
/// Uses wall-clock `Date()` timestamps so the timer survives app backgrounding.
/// When the countdown reaches zero the timer does **not** auto-dismiss — it
/// transitions into an overrun state (amber) and counts up (e.g. `+0:23`)
/// until the user taps **Stop** or the next set implicitly dismisses it.
///
/// Runtime state (remaining/overrun/display) is derived via the pure
/// `RestTimerTick` state machine, which is unit-tested independently.
struct RestTimerView: View {
    let totalSeconds: Int
    let onSkip: () -> Void

    @State private var startDate: Date = Date()
    @State private var timer: Timer?
    @State private var isRunning = false
    @State private var tick: RestTimerTick
    @State private var lastPlayedSecond: Int = -1
    /// Whether the zero-crossing alert (completion sound + haptic) has fired
    /// for the current timer instance. Ensures it plays exactly once per
    /// timer, not repeatedly on every overrun tick.
    @State private var zeroAlertFired: Bool = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var settingsStore

    init(totalSeconds: Int, onSkip: @escaping () -> Void) {
        self.totalSeconds = totalSeconds
        self.onSkip = onSkip
        self._tick = State(initialValue: RestTimerTick.compute(totalSeconds: totalSeconds, elapsedSeconds: 0))
    }

    /// Color for the timer display. Amber once in overrun; primary while counting down.
    private var timerColor: Color {
        tick.isOverrun ? LiftMarkTheme.warning : LiftMarkTheme.primary
    }

    private var accessibilityTimerLabel: String {
        if tick.isOverrun {
            return "Rest timer, overrun by \(tick.overrunSeconds) seconds"
        }
        return "Rest timer, \(tick.remainingSeconds) seconds remaining"
    }

    var body: some View {
        HStack(spacing: LiftMarkTheme.spacingMD) {
            Spacer()

            Text(tick.displayString)
                .font(.lmTitle)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(timerColor)
                .accessibilityLabel(accessibilityTimerLabel)

            Button {
                stopTimer()
                onSkip()
            } label: {
                Text("Stop")
                    .font(.lmCaption)
                    .fontWeight(.semibold)
                    .foregroundStyle(LiftMarkTheme.destructive)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .overlay(
                        Capsule()
                            .stroke(LiftMarkTheme.destructive, lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop rest timer")
            .accessibilityHint("Dismisses the rest timer and moves to the next set")

            Spacer()
        }
        .padding(.vertical, LiftMarkTheme.spacingLG)
        .background(LiftMarkTheme.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM))
        .overlay(
            RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM)
                .strokeBorder(LiftMarkTheme.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
        )
        .onAppear {
            AudioService.shared.preloadSounds()
            startTimer()
        }
        .onDisappear { stopTimer() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                recalculate()
                // Restart tick timer aligned to second boundaries if still running.
                // We keep ticking even in overrun so the display continues to update.
                if isRunning {
                    restartDisplayTick()
                }
            }
        }
    }

    private func recalculate() {
        let previousTick = tick
        let newTick = RestTimerTick.compute(totalSeconds: totalSeconds, startDate: startDate, now: Date())
        tick = newTick

        guard settingsStore.settings?.countdownSoundsEnabled == true else { return }

        // Countdown ticks at 5..1 — only while still counting down.
        if newTick.phase == .counting,
           previousTick.remainingSeconds != newTick.remainingSeconds,
           newTick.remainingSeconds >= 1,
           newTick.remainingSeconds <= 5,
           lastPlayedSecond != newTick.remainingSeconds {
            lastPlayedSecond = newTick.remainingSeconds
            AudioService.shared.playTick()
        }

        // Zero-crossing completion alert: fire exactly once when we first
        // observe the overrun phase for this timer instance. Do NOT re-trigger
        // on subsequent overrun ticks — the alert represents "you hit zero",
        // not "you are still past zero".
        if newTick.isOverrun && !zeroAlertFired {
            zeroAlertFired = true
            AudioService.shared.playComplete()
        }
    }

    private func startTimer() {
        guard !isRunning else { return }
        startDate = Date()
        isRunning = true
        zeroAlertFired = false
        lastPlayedSecond = -1
        tick = RestTimerTick.compute(totalSeconds: totalSeconds, elapsedSeconds: 0)
        restartDisplayTick()
    }

    /// Restart the 1-second display tick, aligned to the next whole-second boundary.
    /// Used on initial start, scenePhase return-to-active, and whenever the
    /// system may have invalidated the Timer.
    private func restartDisplayTick() {
        timer?.invalidate()
        timer = nil
        let fractional = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        let delayToNextSecond = fractional < 0.001 ? 1.0 : (1.0 - fractional)
        timer = Timer.scheduledTimer(withTimeInterval: delayToNextSecond, repeats: false) { _ in
            recalculate()
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                recalculate()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }
}

/// Large exercise timer for timed exercises (e.g., planks).
/// Uses wall-clock Date() timestamps so the timer survives app backgrounding.
struct ExerciseTimerView: View {
    let targetSeconds: Int?
    let onComplete: (Int) -> Void

    /// The Date when the timer was last started/resumed. nil when paused or stopped.
    @State private var startDate: Date?
    /// Accumulated elapsed time from previous start/pause cycles.
    @State private var pausedElapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var isRunning = false
    /// Display value updated by the 1-second timer tick.
    @State private var displayElapsed: Int = 0
    @State private var lastPlayedSecond: Int = -1
    @State private var completionPlayed: Bool = false
    @State private var showCountdown: Bool = false
    /// Tracks whether `showCountdown` has been seeded from the user setting.
    /// Prevents re-seeding on subsequent `onAppear` calls (e.g. after backgrounding)
    /// so the user's in-session tap toggle is preserved.
    @State private var hasInitializedCountdownMode: Bool = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var settingsStore

    init(targetSeconds: Int?, onComplete: @escaping (Int) -> Void) {
        self.targetSeconds = targetSeconds
        self.onComplete = onComplete
    }

    /// Total elapsed seconds (running + paused accumulated).
    private var currentElapsed: Int {
        if let start = startDate {
            return Int(pausedElapsed + Date().timeIntervalSince(start))
        }
        return Int(pausedElapsed)
    }

    private var isComplete: Bool {
        guard let target = targetSeconds else { return false }
        return displayElapsed >= target
    }

    /// True while in count-down mode and elapsed has passed the target — the user is
    /// over the planned duration. Only meaningful in count-down mode; count-up has no overrun.
    private var isOverrun: Bool {
        guard showCountdown, let target = targetSeconds else { return false }
        return displayElapsed > target
    }

    /// Formatted display string. In count-down mode past target, shows `+M:SS` overrun.
    private var displayText: String {
        if showCountdown, let target = targetSeconds {
            if displayElapsed > target {
                return "+" + formatTime(displayElapsed - target)
            }
            return formatTime(max(0, target - displayElapsed))
        }
        return formatTime(displayElapsed)
    }

    private var timerColor: Color {
        if isOverrun { return LiftMarkTheme.warning }
        if isComplete { return LiftMarkTheme.success }
        return LiftMarkTheme.primary
    }

    private var timerAccessibilityLabel: String {
        if isOverrun, let target = targetSeconds {
            return "Exercise timer, overrun by \(displayElapsed - target) seconds"
        }
        return "Exercise timer, \(displayElapsed) seconds elapsed"
    }

    var body: some View {
        VStack(spacing: LiftMarkTheme.spacingSM) {
            // Timer display — tap to toggle count-up/count-down
            HStack(spacing: 6) {
                Text(displayText)
                    .font(.lmMono(size: 40, relativeTo: .largeTitle))
                    .foregroundStyle(timerColor)
                    .tracking(1)

                if targetSeconds != nil {
                    Image(systemName: showCountdown ? "arrow.down" : "arrow.up")
                        .font(.lmCaption)
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                }
            }
            .accessibilityLabel(timerAccessibilityLabel)
            .accessibilityHint(targetSeconds != nil ? "Tap to toggle between count-up and count-down" : "")
            .onTapGesture {
                if targetSeconds != nil {
                    showCountdown.toggle()
                }
            }

            // Target label
            if let target = targetSeconds {
                HStack(spacing: 4) {
                    Text("Target: \(formatTime(target))")
                        .font(.lmCaption)
                        .foregroundStyle(isComplete ? LiftMarkTheme.success : LiftMarkTheme.secondaryLabel)
                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.success)
                    }
                }
            }

            // Controls
            HStack(spacing: LiftMarkTheme.spacingSM) {
                Button {
                    if isRunning {
                        pauseTimer()
                    } else {
                        startTimer()
                    }
                } label: {
                    Text(isRunning ? "Pause" : (displayElapsed > 0 ? "Resume" : "Start"))
                        .font(.lmBody)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(isRunning ? LiftMarkTheme.warning : LiftMarkTheme.primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("exercise-timer-start-button")
                .accessibilityLabel(isRunning ? "Pause timer" : (displayElapsed > 0 ? "Resume timer" : "Start timer"))

                // Done button — available once the timer has been started.
                if isRunning || displayElapsed > 0 {
                    Button {
                        let elapsed = currentElapsed
                        stopTimer()
                        onComplete(elapsed)
                    } label: {
                        Text("Done")
                            .font(.lmBody)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(LiftMarkTheme.success)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("exercise-timer-done-button")
                    .accessibilityLabel("Done")
                    .accessibilityHint("Completes the timed set with the current elapsed time")
                }
            }
        }
        .padding()
        .background(LiftMarkTheme.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM))
        .overlay(
            RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM)
                .stroke(LiftMarkTheme.primary.opacity(0.2), lineWidth: 1.5)
        )
        .onAppear {
            // Initialize countdown mode from user setting on first appearance for this timed set.
            // Only applies when a target exists — count-down is meaningless otherwise.
            // Users may still tap the display to toggle per-exercise; this controls only the initial value.
            if targetSeconds != nil, !hasInitializedCountdownMode {
                showCountdown = settingsStore.settings?.defaultTimerCountdown ?? false
                hasInitializedCountdownMode = true
            }

            // Restart the display tick if the timer was running (e.g., after SwiftUI re-added the view)
            if isRunning && timer == nil {
                restartDisplayTick()
            }
        }
        .onDisappear {
            // Only invalidate the Timer scheduling object — do NOT reset timer state.
            // SwiftUI may call onDisappear during app backgrounding, but the timer
            // should continue tracking time via wall-clock timestamps.
            timer?.invalidate()
            timer = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                recalculate()
                // Restart tick timer aligned to second boundaries if still running
                if isRunning {
                    restartDisplayTick()
                }
            }
        }
    }

    private func recalculate() {
        let previousElapsed = displayElapsed
        displayElapsed = currentElapsed

        // Play countdown sounds if enabled and there is a target
        if let target = targetSeconds,
           settingsStore.settings?.countdownSoundsEnabled == true,
           displayElapsed != previousElapsed {
            let remaining = target - displayElapsed
            if remaining >= 1 && remaining <= 5 && lastPlayedSecond != remaining {
                lastPlayedSecond = remaining
                AudioService.shared.playTick()
            }
            if displayElapsed >= target && !completionPlayed {
                completionPlayed = true
                AudioService.shared.playComplete()
            }
        }
    }

    /// Restart the 1-second display tick, aligned to the next whole-second boundary.
    private func restartDisplayTick() {
        timer?.invalidate()
        timer = nil
        let fractional = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        let delayToNextSecond = fractional < 0.001 ? 1.0 : (1.0 - fractional)
        timer = Timer.scheduledTimer(withTimeInterval: delayToNextSecond, repeats: false) { _ in
            recalculate()
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                recalculate()
            }
        }
    }

    private func startTimer() {
        guard !isRunning else { return }
        AudioService.shared.preloadSounds()
        startDate = Date()
        isRunning = true
        restartDisplayTick()
    }

    private func pauseTimer() {
        if let start = startDate {
            pausedElapsed += Date().timeIntervalSince(start)
        }
        startDate = nil
        timer?.invalidate()
        timer = nil
        isRunning = false
        recalculate()
    }

    private func stopTimer() {
        startDate = nil
        pausedElapsed = 0
        timer?.invalidate()
        timer = nil
        isRunning = false
        displayElapsed = 0
    }

    private func formatTime(_ seconds: Int) -> String {
        DurationFormat.mmss(seconds)
    }
}
