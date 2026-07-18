import Foundation

/// Identity/configuration for an active rest timer instance.
/// Holds the total countdown duration and the id of the set whose completion
/// triggered the timer. The actual runtime state (remaining/overrun/display)
/// is derived from a `startDate` + current `Date()` via
/// `RestTimerTick.compute(...)`.
///
/// `triggeringSetId` scopes the inline timer to a single set so that when the
/// user completes sets out of order — leaving multiple exercises with pending
/// sets — the timer renders only on the card that owns the triggering set,
/// directly below that set row. See `spec/screens/active-workout.md`
/// → "Rest Timer / Single visible instance".
struct RestTimerState {
    let seconds: Int
    let triggeringSetId: String
}

/// Pure, testable state machine for the rest timer display.
///
/// Given the configured `totalSeconds`, the `startDate` at which the timer
/// began, and a `now` timestamp, computes:
///
/// - the countdown phase (`.counting`) when `now < startDate + totalSeconds`
/// - the overrun phase (`.overrun`) once the timer has crossed zero
///
/// Consumers render the `displayString` and switch color based on `isOverrun`.
/// Alerts (haptic/sound) fire exactly once at the zero-crossing transition
/// (see `RestTimerView`) — the state machine itself is side-effect free.
struct RestTimerTick: Equatable {
    enum Phase: Equatable {
        case counting       // Still counting down (remaining > 0)
        case overrun        // At or past zero; counting up from zero

        var isOverrun: Bool { self == .overrun }
    }

    let phase: Phase
    /// Seconds remaining in the countdown. 0 once overrun begins.
    let remainingSeconds: Int
    /// Seconds elapsed past zero. 0 while still counting down.
    let overrunSeconds: Int

    var isOverrun: Bool { phase.isOverrun }

    /// The formatted display string: `M:SS` while counting down,
    /// `+M:SS` once overrun.
    var displayString: String {
        switch phase {
        case .counting:
            return Self.formatMMSS(remainingSeconds)
        case .overrun:
            return "+" + Self.formatMMSS(overrunSeconds)
        }
    }

    /// Compute the tick for a given `totalSeconds`, `startDate`, and `now`.
    /// - Parameters:
    ///   - totalSeconds: The configured rest duration.
    ///   - startDate: When the timer was started.
    ///   - now: Current wall-clock time.
    static func compute(totalSeconds: Int, startDate: Date, now: Date) -> RestTimerTick {
        let elapsed = Int(now.timeIntervalSince(startDate))
        return compute(totalSeconds: totalSeconds, elapsedSeconds: elapsed)
    }

    /// Compute the tick from a known elapsed-seconds value. Useful for
    /// deterministic testing without constructing Dates.
    static func compute(totalSeconds: Int, elapsedSeconds: Int) -> RestTimerTick {
        let elapsed = max(0, elapsedSeconds)
        if elapsed < totalSeconds {
            return RestTimerTick(
                phase: .counting,
                remainingSeconds: totalSeconds - elapsed,
                overrunSeconds: 0
            )
        }
        return RestTimerTick(
            phase: .overrun,
            remainingSeconds: 0,
            overrunSeconds: elapsed - totalSeconds
        )
    }

    /// Format a non-negative second count as `M:SS`.
    /// For overrun display, callers prefix with `+`.
    static func formatMMSS(_ seconds: Int) -> String {
        DurationFormat.mmss(seconds)
    }
}
