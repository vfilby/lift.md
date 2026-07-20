import XCTest
@testable import LiftMark

/// Unit tests for `RestTimerTick` — the pure state machine backing the
/// rest timer view. Verifies zero-crossing, overrun formatting, phase
/// transitions, and edge cases. No SwiftUI or timers involved.
final class RestTimerTickTests: XCTestCase {

    // MARK: - Countdown phase

    func testAtStartCountingDownFromTotal() {
        let tick = RestTimerTick.compute(totalSeconds: 60, elapsedSeconds: 0)
        XCTAssertEqual(tick.phase, .counting)
        XCTAssertFalse(tick.isOverrun)
        XCTAssertEqual(tick.remainingSeconds, 60)
        XCTAssertEqual(tick.overrunSeconds, 0)
        XCTAssertEqual(tick.displayString, "1:00")
    }

    func testMidCountdownRemainingShrinks() {
        let tick = RestTimerTick.compute(totalSeconds: 60, elapsedSeconds: 25)
        XCTAssertEqual(tick.phase, .counting)
        XCTAssertEqual(tick.remainingSeconds, 35)
        XCTAssertEqual(tick.overrunSeconds, 0)
        XCTAssertEqual(tick.displayString, "0:35")
    }

    func testOneSecondBeforeZeroStillCountingDown() {
        let tick = RestTimerTick.compute(totalSeconds: 10, elapsedSeconds: 9)
        XCTAssertEqual(tick.phase, .counting)
        XCTAssertEqual(tick.remainingSeconds, 1)
        XCTAssertEqual(tick.displayString, "0:01")
    }

    // MARK: - Zero-crossing into overrun

    func testAtExactZeroEntersOverrun() {
        // elapsed == total ⇒ remaining 0 ⇒ overrun phase begins.
        // This is the boundary tick where the zero-alert should fire.
        let tick = RestTimerTick.compute(totalSeconds: 10, elapsedSeconds: 10)
        XCTAssertEqual(tick.phase, .overrun)
        XCTAssertTrue(tick.isOverrun)
        XCTAssertEqual(tick.remainingSeconds, 0)
        XCTAssertEqual(tick.overrunSeconds, 0)
        XCTAssertEqual(tick.displayString, "+0:00")
    }

    func testOverrunCountsUpFromZero() {
        let tick = RestTimerTick.compute(totalSeconds: 10, elapsedSeconds: 33)
        XCTAssertEqual(tick.phase, .overrun)
        XCTAssertEqual(tick.remainingSeconds, 0)
        XCTAssertEqual(tick.overrunSeconds, 23)
        XCTAssertEqual(tick.displayString, "+0:23")
    }

    func testOverrunCrossesMinuteBoundary() {
        // 10s countdown, elapsed 85s ⇒ overrun 75s ⇒ "+1:15"
        let tick = RestTimerTick.compute(totalSeconds: 10, elapsedSeconds: 85)
        XCTAssertEqual(tick.phase, .overrun)
        XCTAssertEqual(tick.overrunSeconds, 75)
        XCTAssertEqual(tick.displayString, "+1:15")
    }

    func testLongOverrunFormatsAsPlusMSS() {
        let tick = RestTimerTick.compute(totalSeconds: 30, elapsedSeconds: 30 + 605) // 10:05 over
        XCTAssertEqual(tick.phase, .overrun)
        XCTAssertEqual(tick.overrunSeconds, 605)
        XCTAssertEqual(tick.displayString, "+10:05")
    }

    // MARK: - Transition detection (for alert-once behaviour)

    func testPhaseTransitionFromCountingToOverrunHappensOnceAtZero() {
        // Simulate the sequence of ticks the view will observe.
        // There must be exactly one transition from .counting to .overrun.
        let total = 3
        let observed = (0...7).map { elapsed in
            RestTimerTick.compute(totalSeconds: total, elapsedSeconds: elapsed).phase
        }
        // 0,1,2 → counting; 3,4,5,6,7 → overrun.
        XCTAssertEqual(observed, [
            .counting, .counting, .counting,
            .overrun, .overrun, .overrun, .overrun, .overrun,
        ])

        // Exactly one counting→overrun transition.
        var transitions = 0
        for i in 1..<observed.count where observed[i - 1] == .counting && observed[i] == .overrun {
            transitions += 1
        }
        XCTAssertEqual(transitions, 1, "Zero-alert must fire exactly once per timer instance")
    }

    // MARK: - Date-based compute

    func testComputeFromDatesMatchesElapsedSeconds() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let now = start.addingTimeInterval(45)
        let tick = RestTimerTick.compute(totalSeconds: 60, startDate: start, now: now)
        XCTAssertEqual(tick.phase, .counting)
        XCTAssertEqual(tick.remainingSeconds, 15)
        XCTAssertEqual(tick.displayString, "0:15")
    }

    func testComputeFromDatesIntoOverrun() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let now = start.addingTimeInterval(90) // 30s overrun
        let tick = RestTimerTick.compute(totalSeconds: 60, startDate: start, now: now)
        XCTAssertEqual(tick.phase, .overrun)
        XCTAssertEqual(tick.overrunSeconds, 30)
        XCTAssertEqual(tick.displayString, "+0:30")
    }

    // MARK: - Edge cases

    func testNegativeElapsedClampsToZero() {
        // Clock skew guard: negative elapsed should never produce
        // nonsensical remaining > totalSeconds.
        let tick = RestTimerTick.compute(totalSeconds: 30, elapsedSeconds: -5)
        XCTAssertEqual(tick.phase, .counting)
        XCTAssertEqual(tick.remainingSeconds, 30)
        XCTAssertEqual(tick.displayString, "0:30")
    }

    func testZeroTotalImmediatelyOverrun() {
        // Degenerate input: a 0s timer is already overrun at elapsed=0.
        let tick = RestTimerTick.compute(totalSeconds: 0, elapsedSeconds: 0)
        XCTAssertEqual(tick.phase, .overrun)
        XCTAssertEqual(tick.overrunSeconds, 0)
        XCTAssertEqual(tick.displayString, "+0:00")
    }

    func testFormatMMSSPadsSeconds() {
        XCTAssertEqual(RestTimerTick.formatMMSS(0), "0:00")
        XCTAssertEqual(RestTimerTick.formatMMSS(5), "0:05")
        XCTAssertEqual(RestTimerTick.formatMMSS(59), "0:59")
        XCTAssertEqual(RestTimerTick.formatMMSS(60), "1:00")
        XCTAssertEqual(RestTimerTick.formatMMSS(125), "2:05")
    }

    // MARK: - "Dismiss" / "new-set" semantics
    //
    // Dismissing the timer (Stop button) or starting a new set both result in
    // the RestTimerState being replaced. The view is re-created with a fresh
    // `startDate` and `zeroAlertFired = false`. The state machine itself has
    // no persistent state between timer instances — verified below by
    // constructing fresh ticks.

    func testFreshTimerStartsInCountingPhaseAgain() {
        // First timer runs into overrun...
        let first = RestTimerTick.compute(totalSeconds: 10, elapsedSeconds: 25)
        XCTAssertTrue(first.isOverrun)

        // ...then the user completes the next set. A new RestTimerState
        // with fresh startDate is created — the derived tick at elapsed 0
        // is once again in the counting phase.
        let second = RestTimerTick.compute(totalSeconds: 10, elapsedSeconds: 0)
        XCTAssertEqual(second.phase, .counting)
        XCTAssertEqual(second.remainingSeconds, 10)
    }
}
