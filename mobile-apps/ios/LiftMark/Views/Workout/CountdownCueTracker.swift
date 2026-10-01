import Foundation

/// An audio cue a countdown timer should play.
enum CountdownCue: Equatable {
    /// Short tick with `remaining` seconds left (5...1).
    case tick(remaining: Int)
    /// Completion tone: elapsed has reached the target.
    case complete
}

/// Pure, side-effect-free source of countdown audio cues, shared by the rest
/// timer and the timed-set (hold) timer.
///
/// Cues are derived only from the owning timer's own `targetSeconds` and its
/// own elapsed seconds, so each timer beeps relative to its own start. Each
/// tick fires once per remaining second (5...1) and the completion tone fires
/// exactly once, when elapsed first reaches the target. See
/// `spec/screens/active-workout.md` → "Countdown cue computation" (GH #436).
struct CountdownCueTracker: Equatable {
    /// Number of seconds before the target that tick cues begin.
    static let tickWindow = 5

    let targetSeconds: Int
    private(set) var lastTickRemaining: Int?
    private(set) var completionFired = false

    init(targetSeconds: Int) {
        self.targetSeconds = targetSeconds
    }

    /// Observe the timer's current elapsed seconds and return the cue to play,
    /// if any. Safe to call repeatedly with the same value.
    mutating func advance(toElapsed elapsedSeconds: Int) -> CountdownCue? {
        guard !completionFired else { return nil }
        let remaining = targetSeconds - max(0, elapsedSeconds)
        if remaining <= 0 {
            completionFired = true
            return .complete
        }
        guard remaining <= Self.tickWindow, lastTickRemaining != remaining else { return nil }
        lastTickRemaining = remaining
        return .tick(remaining: remaining)
    }
}

extension AudioService {
    /// Play the sound for a countdown cue.
    func play(_ cue: CountdownCue) {
        switch cue {
        case .tick: playTick()
        case .complete: playComplete()
        }
    }
}
