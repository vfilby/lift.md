import XCTest
import SwiftUI
@testable import LiftMark

/// The Apple Watch Smart Stack card is a fixed size that varies by watch model;
/// content taller than the offered height spills over the card below it (issue #488).
/// The view must pick the richest layout that fits. See spec/services/live-activities.md.
@MainActor
final class SmartStackActivityViewTests: XCTestCase {

    private typealias State = WorkoutActivityAttributes.ContentState
    private typealias Layout = SmartStackActivityView.Layout

    private let width: CGFloat = 168

    // Render comparisons leave the rest timer out: a `.timer` text could tick
    // between two renders. The timer shares the header row with "Rest", so it
    // doesn't change the layout's height.
    private let active = State(
        isRestTimer: false, exerciseName: "Bench Press", setInfo: "Set 2/4",
        weightReps: "185 lbs × 5", nextExerciseName: "Overhead Press",
        nextSetDetail: "135 lbs × 8", progress: 0.35
    )
    private let rest = State(
        isRestTimer: true, exerciseName: "Rest", setInfo: "",
        weightReps: "", nextExerciseName: "Bench Press",
        nextSetDetail: "45 lbs × 8", progress: 0.1
    )

    /// Ideal height as `ViewThatFits` measures it: unconstrained, so no text is
    /// truncated or shrunk by `minimumScaleFactor`.
    private func idealHeight(_ state: State, _ layout: Layout) -> CGFloat {
        let view = SmartStackActivityView(state: state).content(layout)
            .environment(\.dynamicTypeSize, .large)
            .fixedSize()
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: 1_000, height: 1_000)).height
    }

    private func render(_ view: some View, height: CGFloat) -> Data? {
        let renderer = ImageRenderer(content: view
            .environment(\.dynamicTypeSize, .large)
            .frame(width: width, height: height))
        renderer.scale = 2
        return renderer.uiImage?.pngData()
    }

    /// The layout the adaptive view renders when offered `height`, or nil if it matches neither.
    private func renderedLayout(_ state: State, offeredHeight height: CGFloat) -> Layout? {
        let adaptive = render(SmartStackActivityView(state: state), height: height)
        XCTAssertNotNil(adaptive)
        return Layout.allCases.first { layout in
            let fixed = SmartStackActivityView(state: state).content(layout)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            return render(fixed, height: height) == adaptive
        }
    }

    // MARK: - Ideal heights

    func testCompactLayoutIsShorterThanRegular() {
        for state in [active, rest] {
            let regular = idealHeight(state, .regular)
            let compact = idealHeight(state, .compact)
            XCTAssertGreaterThan(compact, 0)
            XCTAssertLessThan(compact, regular, "isRestTimer=\(state.isRestTimer)")
        }
    }

    func testLongNamesStaySingleLine() {
        let longName = "Single-Arm Dumbbell Romanian Deadlift With Pause"
        var longActive = active
        longActive.exerciseName = longName
        longActive.nextExerciseName = longName
        var longRest = rest
        longRest.nextExerciseName = longName
        longRest.nextSetDetail = "102.5 lbs × 12 @ RPE 8"

        for layout in Layout.allCases {
            XCTAssertEqual(idealHeight(longActive, layout), idealHeight(active, layout), accuracy: 0.5, "\(layout)")
            XCTAssertEqual(idealHeight(longRest, layout), idealHeight(rest, layout), accuracy: 0.5, "\(layout)")
        }
    }

    func testRestTimerDoesNotChangeHeight() {
        var timed = rest
        timed.timerEndDate = Date().addingTimeInterval(90)
        for layout in Layout.allCases {
            XCTAssertEqual(idealHeight(timed, layout), idealHeight(rest, layout), accuracy: 0.5, "\(layout)")
        }
    }

    // MARK: - Adaptive choice

    func testRegularLayoutShownWhenItFits() {
        for state in [active, rest] {
            let regular = idealHeight(state, .regular)
            XCTAssertEqual(renderedLayout(state, offeredHeight: regular + 2), .regular, "isRestTimer=\(state.isRestTimer)")
            XCTAssertEqual(renderedLayout(state, offeredHeight: regular + 40), .regular, "isRestTimer=\(state.isRestTimer)")
        }
    }

    func testCompactLayoutShownWhenRegularWouldOverflow() {
        for state in [active, rest] {
            let regular = idealHeight(state, .regular)
            let compact = idealHeight(state, .compact)
            let offered = regular - 2
            XCTAssertGreaterThanOrEqual(offered, compact, "test setup: compact must fit")
            XCTAssertEqual(renderedLayout(state, offeredHeight: offered), .compact, "isRestTimer=\(state.isRestTimer)")
        }
    }
}
