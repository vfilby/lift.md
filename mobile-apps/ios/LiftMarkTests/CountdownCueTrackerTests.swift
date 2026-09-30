import XCTest
@testable import LiftMark

/// Tests for `CountdownCueTracker` (shared countdown audio cues) and the
/// "starting a hold dismisses the rest timer" policy. Regression coverage for
/// GH #435 (stray rest timer keeps running over a new timed set) and GH #436
/// (hold countdown beeps finish before the hold's target).
final class CountdownCueTrackerTests: XCTestCase {

    /// Feed elapsed seconds `range` into the tracker; return (elapsed, cue) pairs.
    private func cues(
        _ tracker: inout CountdownCueTracker, over range: ClosedRange<Int>
    ) -> [(elapsed: Int, cue: CountdownCue)] {
        range.compactMap { elapsed in
            tracker.advance(toElapsed: elapsed).map { (elapsed, $0) }
        }
    }

    // MARK: - Cue timing relative to the timer's own target

    func testSixtySecondTargetCuesOnlyInFinalFiveSecondsAndCompletesAtTarget() {
        var tracker = CountdownCueTracker(targetSeconds: 60)
        let fired = cues(&tracker, over: 0...90)

        XCTAssertEqual(fired.map(\.elapsed), [55, 56, 57, 58, 59, 60])
        XCTAssertEqual(fired.map(\.cue), [
            .tick(remaining: 5), .tick(remaining: 4), .tick(remaining: 3),
            .tick(remaining: 2), .tick(remaining: 1), .complete
        ])
    }

    func testNoCueBeforeFinalFiveSeconds() {
        var tracker = CountdownCueTracker(targetSeconds: 60)
        XCTAssertTrue(cues(&tracker, over: 0...54).isEmpty)
        XCTAssertFalse(tracker.completionFired)
    }

    func testRepeatedObservationOfSameSecondTicksOnce() {
        var tracker = CountdownCueTracker(targetSeconds: 10)
        XCTAssertEqual(tracker.advance(toElapsed: 7), .tick(remaining: 3))
        XCTAssertNil(tracker.advance(toElapsed: 7))
        XCTAssertNil(tracker.advance(toElapsed: 7))
        XCTAssertEqual(tracker.advance(toElapsed: 8), .tick(remaining: 2))
    }

    func testCompleteFiresExactlyOnceIncludingOverrun() {
        var tracker = CountdownCueTracker(targetSeconds: 10)
        XCTAssertEqual(tracker.advance(toElapsed: 10), .complete)
        XCTAssertNil(tracker.advance(toElapsed: 10))
        XCTAssertNil(tracker.advance(toElapsed: 11))
        XCTAssertNil(tracker.advance(toElapsed: 120))
    }

    func testJumpPastZeroYieldsOnlyComplete() {
        // e.g. foreground return after the target passed while backgrounded.
        var tracker = CountdownCueTracker(targetSeconds: 30)
        XCTAssertNil(tracker.advance(toElapsed: 10))
        XCTAssertEqual(tracker.advance(toElapsed: 45), .complete)
        XCTAssertNil(tracker.advance(toElapsed: 46))
    }

    func testJumpIntoTickWindowTicksCurrentSecondOnly() {
        var tracker = CountdownCueTracker(targetSeconds: 30)
        XCTAssertEqual(tracker.advance(toElapsed: 27), .tick(remaining: 3))
        XCTAssertEqual(tracker.advance(toElapsed: 28), .tick(remaining: 2))
    }

    func testNegativeElapsedClampedToZero() {
        var tracker = CountdownCueTracker(targetSeconds: 3)
        XCTAssertEqual(tracker.advance(toElapsed: -2), .tick(remaining: 3))
    }

    // MARK: - GH #435: starting a hold dismisses the rest timer

    func testStartingTimedSetDismissesRestTimerOwnedBySameExercise() {
        // Plank set 2 completed → rest timer; user starts set 3's hold.
        let rest = RestTimerState(seconds: 30, triggeringSetId: "plank-2")
        XCTAssertNil(ActiveWorkoutViewModel.restTimer(rest, afterStartingTimedSet: "plank-3"))
    }

    func testStartingTimedSetDismissesRestTimerOwnedByAnotherCard() {
        let rest = RestTimerState(seconds: 90, triggeringSetId: "bench-3")
        XCTAssertNil(ActiveWorkoutViewModel.restTimer(rest, afterStartingTimedSet: "childs-pose-1"))
    }

    func testStartingTimedSetWithNoRestTimerStaysNil() {
        XCTAssertNil(ActiveWorkoutViewModel.restTimer(nil, afterStartingTimedSet: "plank-1"))
    }

    // MARK: - GH #436: only the hold's own cues are heard during the hold

    /// Simulates the reported scenario on a shared wall clock: a 60s rest
    /// timer starts at t=0 (previous set completed), and the user starts a
    /// Child's Pose hold (target 1:00) at t=15. The rest timer only produces
    /// cues while it is still alive, mirroring `RestTimerView`, whose display
    /// tick stops when the view leaves the hierarchy.
    ///
    /// Before the fix the rest timer stayed alive, so its 5..1 ticks and
    /// completion tone played at hold-elapsed 40..45 — the hold "beeped out"
    /// at 0:45 instead of 1:00.
    func testHoldCuesAreAlignedToHoldTargetWhenRestTimerWasRunning() {
        let restStart = 0
        let holdStart = 15
        let holdTarget = 60

        var restTimer: RestTimerState? = RestTimerState(seconds: 60, triggeringSetId: "cat-cow-1")
        var restCues = CountdownCueTracker(targetSeconds: 60)
        var holdCues = CountdownCueTracker(targetSeconds: holdTarget)
        var heard: [(holdElapsed: Int, cue: CountdownCue)] = []

        for now in 0...(holdStart + holdTarget + 30) {
            if now == holdStart {
                restTimer = ActiveWorkoutViewModel.restTimer(restTimer, afterStartingTimedSet: "childs-pose-1")
            }
            if restTimer != nil, let cue = restCues.advance(toElapsed: now - restStart), now >= holdStart {
                heard.append((now - holdStart, cue))
            }
            if now >= holdStart, let cue = holdCues.advance(toElapsed: now - holdStart) {
                heard.append((now - holdStart, cue))
            }
        }

        XCTAssertNil(restTimer, "Rest timer must be dismissed when the hold starts (#435)")
        XCTAssertEqual(heard.map(\.holdElapsed), [55, 56, 57, 58, 59, 60],
                       "Only the hold's own cues may play during the hold (#436)")
        XCTAssertEqual(heard.filter { $0.cue == .complete }.map(\.holdElapsed), [holdTarget])
    }
}
