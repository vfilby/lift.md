@preconcurrency import XCTest
import UIKit
@preconcurrency import Foundation

/// Global multiplier for every UI-test timeout. Set the `UITEST_TIMEOUT_SCALE`
/// environment variable on slow runners (e.g. an Intel CI box, where simulator
/// boot, app launch, and animations run 2–3× slower) so the suite absorbs the
/// extra latency without loosening timeouts on fast dev machines. Default 1.0;
/// a value like `2.5` multiplies all waits accordingly. Invalid/≤0 values are
/// ignored. Read once per process.
enum UITestTiming {
    static let scale: Double = {
        guard let raw = ProcessInfo.processInfo.environment["UITEST_TIMEOUT_SCALE"],
              let value = Double(raw), value > 0 else {
            NSLog("[UITestTiming] UITEST_TIMEOUT_SCALE unset/invalid; using scale 1.0")
            return 1.0
        }
        NSLog("[UITestTiming] UITEST_TIMEOUT_SCALE=\(value) (all UI-test timeouts ×\(value))")
        return value
    }()

    /// Scale a base timeout (seconds) by the configured factor.
    static func scaled(_ base: TimeInterval) -> TimeInterval { base * scale }
}

/// Maps YAML E2E actions to XCUITest API calls.
///
/// Each action type from the schema (tap, replaceText, waitFor, etc.) is
/// handled by a corresponding method that translates the declarative action
/// into imperative XCUITest commands.
class ActionAdapter {
    let app: XCUIApplication
    let fixturesPath: String

    /// Internal state for cross-action communication (e.g., execScript → openURL).
    var sharedFilePath: String?
    /// Content from the last writeSharedFile, used to pass directly as a launch argument.
    var sharedFileContent: String?

    /// Track if first launch has happened (for data reset isolation).
    private var isFirstLaunch = true

    /// Track whether onboarding has already been dismissed in this process.
    /// Skip the accept-button probe on subsequent launches to avoid the
    /// repeated accessibility snapshot requests that SIGKILL the test host
    /// on iOS 26.
    private var onboardingDismissed = false

    init(app: XCUIApplication, fixturesPath: String) {
        self.app = app
        self.fixturesPath = fixturesPath
    }

    // MARK: - Public

    func execute(_ action: TestAction) throws {
        switch action.action {
        case "tap":
            try executeTap(action)
        case "longPress":
            try executeLongPress(action)
        case "tapText":
            try executeTapText(action)
        case "tapIndex":
            try executeTapIndex(action)
        case "replaceText":
            try executeReplaceText(action)
        case "typeText":
            try executeTypeText(action)
        case "waitFor":
            try executeWaitFor(action)
        case "waitForNot":
            try executeWaitForNot(action)
        case "waitForText":
            try executeWaitForText(action)
        case "expect":
            try executeExpect(action)
        case "scroll":
            try executeScroll(action)
        case "launchApp":
            try executeLaunchApp(action)
        case "openURL":
            try executeOpenURL(action)
        case "dismissAlert":
            try executeDismissAlert(action)
        case "delay":
            try executeDelay(action)
        case "tryCatch":
            try executeTryCatch(action)
        case "runFixture":
            try executeRunFixture(action)
        case "tapSegment":
            try executeTapSegment(action)
        case "execScript":
            try executeExecScript(action)
        case "screenshot":
            try executeScreenshot(action)
        default:
            XCTFail("Unknown action: \(action.action)")
        }
    }

    // MARK: - Element Resolution

    private func element(byId identifier: String) -> XCUIElement {
        // Tab bar: ALWAYS use tab bar buttons for tab-* identifiers.
        // The .accessibilityIdentifier on tab content (NavigationStack) only
        // works for the active tab and tapping it hits the content area
        // instead of the tab bar button.
        if identifier.hasPrefix("tab-") {
            if let label = tabIdToLabel[identifier] {
                let tabButton = app.tabBars.buttons[label]
                if tabButton.exists { return tabButton }
            }
            let tabButtons = app.tabBars.buttons
            for i in 0..<tabButtons.count {
                let button = tabButtons.element(boundBy: i)
                if button.identifier == identifier {
                    return button
                }
            }
            if let label = tabIdToLabel[identifier] {
                // iPad (iOS 18+): the root TabView renders tabs as a top bar of
                // plain buttons (identifier is the SF Symbol name, label is the
                // tab title) rather than under a tabBars element — match by label.
                let topTab = app.buttons[label].firstMatch
                if topTab.exists { return topTab }
                // Return label-based query (will resolve when tab bar appears)
                return app.tabBars.buttons[label]
            }
        }

        // Use firstMatch to handle SwiftUI toolbar items that create
        // duplicate accessibility elements (wrapper + button).
        let el = app.descendants(matching: .any).matching(identifier: identifier).firstMatch

        // If found immediately, return it.
        if el.exists { return el }

        // SwiftUI TextFields and TextEditors sometimes don't expose their
        // .accessibilityIdentifier via the generic descendants query when
        // a parent view also has an identifier. Try specific element types.
        let textField = app.textFields.matching(identifier: identifier).firstMatch
        if textField.exists { return textField }

        let textView = app.textViews.matching(identifier: identifier).firstMatch
        if textView.exists { return textView }

        let button = app.buttons.matching(identifier: identifier).firstMatch
        if button.exists { return button }

        let toggle = app.switches.matching(identifier: identifier).firstMatch
        if toggle.exists { return toggle }

        // Return the original element (may not exist yet — caller handles waiting)
        return el
    }

    /// Waits for an element by accessibility identifier using a single
    /// predicate-based descendants query.
    ///
    /// Previously this polled six separate type-specific queries per loop,
    /// which triggers a full accessibility-hierarchy snapshot on every miss.
    /// On iOS 26 the repeated snapshots hang XCTestRunner long enough for
    /// the watchdog to SIGKILL it, which shows up as the generic
    /// "Test crashed with signal kill." failure on every UI test.
    private func waitForAnyElement(byId identifier: String, timeout: TimeInterval) -> XCUIElement? {
        // Tab bar buttons: always check tab bar first for tab-* identifiers
        if identifier.hasPrefix("tab-") {
            if let label = tabIdToLabel[identifier] {
                let tabButton = app.tabBars.buttons[label]
                if tabButton.waitForExistence(timeout: UITestTiming.scaled(min(timeout, 3))) { return tabButton }
                // iPad (iOS 18+): tabs render as a top bar of plain buttons
                // matched by their title label, not under a tabBars element.
                let topTab = app.buttons[label].firstMatch
                if topTab.waitForExistence(timeout: UITestTiming.scaled(min(timeout, 3))) { return topTab }
            }
        }

        let predicate = NSPredicate(format: "identifier == %@", identifier)
        let el = app.descendants(matching: .any).matching(predicate).firstMatch
        if el.waitForExistence(timeout: UITestTiming.scaled(timeout)) { return el }
        return nil
    }

    /// Maps tab accessibility identifiers to their tab bar label text.
    /// Set by the test setup to enable tab navigation.
    var tabIdToLabel: [String: String] = [:]

    private func element(byText text: String) -> XCUIElement {
        let staticText = app.staticTexts[text]
        if staticText.exists { return staticText }
        // Also check alert buttons — SwiftUI alerts render buttons
        // that may not appear as static texts.
        let alertButton = app.alerts.buttons[text]
        if alertButton.exists { return alertButton }
        // Check regular buttons too
        let button = app.buttons[text]
        if button.exists { return button }
        // Fallback: check if text is contained within a combined accessibility label
        if let match = findElementContainingText(text) { return match }
        return staticText
    }

    /// Finds any element whose label contains the given text.
    /// This handles SwiftUI containers that combine child Text accessibility labels.
    /// Note: avoid descendants(matching: .any) with CONTAINS — it can crash
    /// when traversing elements with null attributes (SIGSEGV in strcmp).
    private func findElementContainingText(_ text: String) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let match = app.staticTexts.matching(predicate).firstMatch
        if match.exists { return match }
        let btnMatch = app.buttons.matching(predicate).firstMatch
        if btnMatch.exists { return btnMatch }
        let otherMatch = app.otherElements.matching(predicate).firstMatch
        if otherMatch.exists { return otherMatch }
        return nil
    }

    private func resolveElement(_ action: TestAction) throws -> XCUIElement {
        if let target = action.target {
            return element(byId: target)
        }
        if let text = action.text {
            return element(byText: text)
        }
        throw ActionError.missingSelector(action.action)
    }

    // MARK: - Fixture Loading

    func readFixture(_ name: String) throws -> String {
        let path = (fixturesPath as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ActionError.fixtureNotFound(name, path)
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Substitute `${VAR}` tokens with values from the test process
    /// environment. Credentials for the Layer-3 beta e2e are minted fresh per
    /// CI run, so static YAML references them as `${LMWF_E2E_EMAIL}` etc. An
    /// unset variable resolves to the empty string.
    /// See spec/services/ios-e2e-beta.md.
    func interpolateEnv(_ value: String) -> String {
        guard value.contains("${") else { return value }
        let env = ProcessInfo.processInfo.environment
        var result = ""
        var rest = Substring(value)
        while let open = rest.range(of: "${") {
            result += String(rest[rest.startIndex..<open.lowerBound])
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}") else {
                // Unterminated token — emit the remainder verbatim.
                result += String(rest[open.lowerBound...])
                return result
            }
            let name = String(afterOpen[afterOpen.startIndex..<close.lowerBound])
            result += env[name] ?? ""
            rest = afterOpen[close.upperBound...]
        }
        result += String(rest)
        return result
    }

    // MARK: - Action Implementations

    private func executeTap(_ action: TestAction) throws {
        if let target = action.target {
            if let el = waitForAnyElement(byId: target, timeout: 5) {
                scrollToHittable(el)
                el.tap()
                return
            }
            XCTFail("Element '\(target)' not found for tap")
        } else if let text = action.text {
            let el = element(byText: text)
            XCTAssertTrue(el.waitForExistence(timeout: UITestTiming.scaled(5)), "Text '\(text)' not found for tap")
            scrollToHittable(el)
            el.tap()
        } else {
            throw ActionError.missingSelector(action.action)
        }
    }

    /// Searches for an element by identifier with small corrective scrolls.
    /// Useful after a scenario's bulk scrolling lands just past the target:
    /// SwiftUI's `List` (backed by `UICollectionView`) lazy-unloads cells
    /// that are slightly outside the viewport, so an element that was the
    /// intended destination can disappear from the accessibility tree if the
    /// gesture overshoots by even ~60pt. Tries a few small swipes in each
    /// direction on the first visible scroll container, re-checking between.
    private func scrollSearchForElement(byId identifier: String) -> XCUIElement? {
        let container: XCUIElement = {
            let scroll = app.scrollViews.firstMatch
            if scroll.exists { return scroll }
            let coll = app.collectionViews.firstMatch
            if coll.exists { return coll }
            return app.otherElements.firstMatch
        }()
        guard container.exists else { return nil }

        for direction in [Direction.down, Direction.up] {
            for _ in 0..<3 {
                switch direction {
                case .down: container.swipeDown()
                case .up:   container.swipeUp()
                }
                if let el = waitForAnyElement(byId: identifier, timeout: 1) {
                    return el
                }
            }
        }
        return nil
    }

    private enum Direction { case up, down }

    /// Makes a target tappable: first waits out a *transient* non-hittable
    /// state (an on-screen element mid-animation/re-render — e.g. the Settings
    /// Account section just swapped to its signed-in branch and the inbox-status
    /// poll is re-laying it out, which briefly leaves `account-sign-out`
    /// present-but-not-hittable), then falls back to scrolling a genuinely
    /// off-screen element into view. The fast path (already hittable) is a
    /// no-op.
    private func scrollToHittable(_ element: XCUIElement, maxAttempts: Int = 5) {
        guard !element.isHittable else { return }
        // On-screen-but-settling: poll briefly before deciding it's off-screen.
        if waitForHittable(element, timeout: 4) { return }
        // A system "Save Password?" sheet (springboard) can cover an on-screen
        // control after a password login submit — e.g. `account-sign-out` in the
        // beta login round-trip. It's not an `app.alerts` alert and querying
        // springboard directly times out its huge snapshot, so it's handled by
        // a UI-interruption monitor (registered in the XCTestCase setUp). The
        // monitor only fires on an app interaction, so nudge it with a tap on a
        // safe, never-covered chrome element (the nav bar sits above the
        // mid-screen sheet), then re-check.
        if app.navigationBars.firstMatch.exists {
            app.navigationBars.firstMatch.tap()
        } else {
            app.tap()
        }
        if waitForHittable(element, timeout: 2) { return }
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.exists else { return }
        for _ in 0..<maxAttempts {
            scrollView.swipeUp()
            if element.isHittable { return }
        }
    }

    /// Polls `isHittable` until it's true or the (scaled) timeout elapses.
    /// `waitForExistence` only covers presence, not interactability, so an
    /// element animating in needs this extra settle before `tap()`.
    @discardableResult
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(UITestTiming.scaled(timeout))
        while Date() < deadline {
            if element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return element.isHittable
    }

    private func executeLongPress(_ action: TestAction) throws {
        guard let target = action.target else {
            throw ActionError.missingParam("target", "longPress")
        }
        guard let el = waitForAnyElement(byId: target, timeout: 5) else {
            XCTFail("Element '\(target)' not found for longPress")
            return
        }
        el.press(forDuration: 1.0)
    }

    private func executeTapText(_ action: TestAction) throws {
        guard let text = action.text else {
            throw ActionError.missingParam("text", "tapText")
        }
        // Try exact matches first with native waiter
        let alertButton = app.alerts.buttons[text].firstMatch
        if alertButton.waitForExistence(timeout: UITestTiming.scaled(2)) {
            alertButton.tap()
            return
        }

        let containsPredicate = NSPredicate(format: "label CONTAINS %@", text)
        let deadline = Date().addingTimeInterval(UITestTiming.scaled(5))
        while Date() < deadline {
            let staticTextByLabel = app.staticTexts[text].firstMatch
            if staticTextByLabel.exists {
                staticTextByLabel.tap()
                return
            }
            let button = app.buttons[text].firstMatch
            if button.exists {
                button.tap()
                return
            }
            let containsMatch = app.staticTexts.matching(containsPredicate).firstMatch
            if containsMatch.exists {
                containsMatch.tap()
                return
            }
            let btnContains = app.buttons.matching(containsPredicate).firstMatch
            if btnContains.exists {
                btnContains.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("Text '\(text)' not found for tapText")
    }

    private func executeTapIndex(_ action: TestAction) throws {
        guard let target = action.target else {
            throw ActionError.missingParam("target", "tapIndex")
        }
        let index = action.index ?? 0
        let elements = app.descendants(matching: .any).matching(identifier: target)
        let el = elements.element(boundBy: index)
        XCTAssertTrue(el.waitForExistence(timeout: UITestTiming.scaled(5)), "Element '\(target)' at index \(index) not found")
        el.tap()
    }

    private func executeTapSegment(_ action: TestAction) throws {
        guard let target = action.target else {
            throw ActionError.missingParam("target", "tapSegment")
        }
        guard let segment = action.segment else {
            throw ActionError.missingParam("segment", "tapSegment")
        }
        // Find the segmented control by accessibility identifier, then tap the button matching the segment label
        guard let picker = waitForAnyElement(byId: target, timeout: 5) else {
            XCTFail("Element '\(target)' not found for tapSegment")
            return
        }
        let segmentButton = picker.buttons[segment]
        XCTAssertTrue(segmentButton.waitForExistence(timeout: UITestTiming.scaled(3)),
                       "Segment '\(segment)' not found in '\(target)'")
        segmentButton.tap()
    }

    private func executeReplaceText(_ action: TestAction) throws {
        guard let target = action.target else {
            throw ActionError.missingParam("target", "replaceText")
        }
        guard let el = waitForAnyElement(byId: target, timeout: 5) else {
            XCTFail("Element '\(target)' not found for replaceText")
            return
        }

        // Resolve text value — from fixture or direct value. Direct values
        // support ${ENV_VAR} interpolation (e.g. per-run beta credentials).
        let textValue: String
        if let fixture = action.fixture {
            textValue = try readFixture(fixture)
        } else if let value = action.value {
            textValue = interpolateEnv(value)
        } else {
            throw ActionError.missingParam("value or fixture", "replaceText")
        }

        el.tap()
        // Use hardware-keyboard shortcuts rather than the UIKit edit menu.
        // On iOS 26 the "Select All" / "Paste" menu items don't reliably
        // appear on SwiftUI TextEditors via long-press, and the repeated
        // menu probes cascade into the accessibility-snapshot SIGKILL.
        el.typeKey("a", modifierFlags: .command)
        el.typeText(textValue)
    }

    private func executeTypeText(_ action: TestAction) throws {
        guard let target = action.target, let value = action.value else {
            throw ActionError.missingParam("target and value", "typeText")
        }
        guard let el = waitForAnyElement(byId: target, timeout: 5) else {
            XCTFail("Element '\(target)' not found for typeText")
            return
        }
        el.tap()
        el.typeText(interpolateEnv(value))
    }

    private func executeWaitFor(_ action: TestAction) throws {
        let timeout = TimeInterval(action.timeout ?? 5000) / 1000.0
        if let target = action.target {
            let el = waitForAnyElement(byId: target, timeout: timeout)
            if el == nil {
                XCTFail("Timed out waiting for '\(target)' to exist")
                return
            }
        } else if let text = action.text {
            let el = element(byText: text)
            XCTAssertTrue(el.waitForExistence(timeout: UITestTiming.scaled(timeout)), "Timed out waiting for text '\(text)' to exist")
        } else {
            throw ActionError.missingSelector(action.action)
        }
    }

    private func executeWaitForNot(_ action: TestAction) throws {
        let el = try resolveElement(action)
        let timeout = TimeInterval(action.timeout ?? 5000) / 1000.0

        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: el)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result, .completed,
            "Timed out waiting for '\(action.target ?? action.text ?? "")' to disappear"
        )
    }

    private func executeWaitForText(_ action: TestAction) throws {
        guard let text = action.text else {
            throw ActionError.missingParam("text", "waitForText")
        }
        let timeout = TimeInterval(action.timeout ?? 5000) / 1000.0

        // Try exact-match first with native waiter (most efficient)
        if app.staticTexts[text].waitForExistence(timeout: UITestTiming.scaled(min(timeout, 2))) { return }

        // Poll for text across alert buttons, regular buttons, text fields, and CONTAINS fallback
        let containsPredicate = NSPredicate(format: "label CONTAINS %@", text)
        let valuePredicate = NSPredicate(format: "value CONTAINS %@", text)
        let deadline = Date().addingTimeInterval(UITestTiming.scaled(timeout))
        while Date() < deadline {
            if app.staticTexts[text].exists { return }
            if app.alerts.buttons[text].exists { return }
            if app.buttons[text].exists { return }
            if app.textFields.matching(valuePredicate).firstMatch.exists { return }
            if app.staticTexts.matching(containsPredicate).firstMatch.exists { return }
            if app.buttons.matching(containsPredicate).firstMatch.exists { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("Timed out waiting for text '\(text)'")
    }

    private func executeExpect(_ action: TestAction) throws {
        guard let assertion = action.assertion else {
            throw ActionError.missingParam("assertion", "expect")
        }

        let desc = action.target ?? action.text ?? ""

        switch assertion {
        case "toBeVisible":
            if let target = action.target {
                guard let el = waitForAnyElement(byId: target, timeout: 5) else {
                    XCTFail("Expected '\(desc)' to be visible")
                    return
                }
                scrollToHittable(el)
                XCTAssertTrue(el.isHittable, "Expected '\(desc)' to be visible (hittable)")
            } else {
                let el = try resolveElement(action)
                let exists = el.waitForExistence(timeout: UITestTiming.scaled(5))
                if !exists {
                    XCTFail("Expected '\(desc)' to be visible but not found")
                    return
                }
                scrollToHittable(el)
                XCTAssertTrue(el.isHittable, "Expected '\(desc)' to be visible (hittable)")
            }

        case "toExist":
            if let target = action.target {
                if let el = waitForAnyElement(byId: target, timeout: 5) {
                    _ = el
                } else if let el = scrollSearchForElement(byId: target) {
                    _ = el
                } else {
                    XCTFail("Expected '\(desc)' to exist")
                }
            } else {
                let el = try resolveElement(action)
                XCTAssertTrue(el.waitForExistence(timeout: UITestTiming.scaled(5)), "Expected '\(desc)' to exist")
            }

        case "toHaveText":
            let el = try resolveElement(action)
            XCTAssertTrue(el.waitForExistence(timeout: UITestTiming.scaled(5)))
            let actual = (el.value as? String) ?? el.label
            XCTAssertEqual(actual, action.value, "Expected text '\(action.value ?? "")' but got '\(actual)'")

        case "notToBeVisible":
            let el = try resolveElement(action)
            if el.exists {
                XCTAssertFalse(el.isHittable, "Expected '\(desc)' not to be visible")
            }

        case "notToExist":
            let el = try resolveElement(action)
            XCTAssertFalse(el.exists, "Expected '\(desc)' not to exist")

        default:
            XCTFail("Unknown assertion: \(assertion)")
        }
    }

    private func executeScroll(_ action: TestAction) throws {
        guard let target = action.target else {
            throw ActionError.missingParam("target", "scroll")
        }
        guard let direction = action.direction else {
            throw ActionError.missingParam("direction", "scroll")
        }
        guard let el = waitForAnyElement(byId: target, timeout: 5) else {
            XCTFail("Element '\(target)' not found for scroll")
            return
        }

        // Optional `amount` (1-100): perform a precise coordinate drag covering
        // that percentage of the element's height/width, instead of a full-page
        // swipe. Useful for framing screenshots where a default swipe overshoots.
        if let amount = action.amount {
            let frac = max(0.05, min(1.0, CGFloat(amount) / 100.0)) / 2.0
            let center = el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let (sx, sy, ex, ey): (CGFloat, CGFloat, CGFloat, CGFloat)
            switch direction {
            // Drag content the opposite way to the scroll direction: scrolling
            // "up" reveals lower content, so the finger moves from low to high.
            case "up":    (sx, sy, ex, ey) = (0,  frac, 0, -frac)
            case "down":  (sx, sy, ex, ey) = (0, -frac, 0,  frac)
            case "left":  (sx, sy, ex, ey) = ( frac, 0, -frac, 0)
            case "right": (sx, sy, ex, ey) = (-frac, 0,  frac, 0)
            default:      XCTFail("Unknown scroll direction: \(direction)"); return
            }
            let size = el.frame.size
            let start = center.withOffset(CGVector(dx: sx * size.width, dy: sy * size.height))
            let end = center.withOffset(CGVector(dx: ex * size.width, dy: ey * size.height))
            start.press(forDuration: 0.05, thenDragTo: end)
            return
        }

        switch direction {
        case "up":    el.swipeUp()
        case "down":  el.swipeDown()
        case "left":  el.swipeLeft()
        case "right": el.swipeRight()
        default:      XCTFail("Unknown scroll direction: \(direction)")
        }
    }

    private func executeLaunchApp(_ action: TestAction) throws {
        if action.newInstance == true {
            app.terminate()
        }
        // Build launch arguments from scratch each time
        var args: [String] = []

        // Reset data on first launch of each scenario for test isolation
        if isFirstLaunch {
            args.append("--reset-data")
            isFirstLaunch = false
        }

        // Apply additional launch arguments from the YAML action. Values
        // support ${ENV_VAR} interpolation so e.g. the beta base URL can be
        // injected per CI run (--api-base-url=${LMWF_E2E_BASE_URL}).
        if case .array(let yamlArgs) = action.launchArgs {
            for arg in yamlArgs {
                if case .string(let value) = arg {
                    args.append(interpolateEnv(value))
                }
            }
        }

        app.launchArguments = args
        app.launch()

        // Auto-dismiss onboarding disclaimer on fresh launches. Once dismissed
        // in this process, skip the probe — the 5s accept-button check hits
        // a SwiftUI tree that never has the element, and the repeated
        // snapshots on iOS 26 are expensive enough to cascade into SIGKILL.
        if !args.contains("--show-onboarding") && !onboardingDismissed {
            let acceptButton = app.descendants(matching: .any)["onboarding-accept-button"]
            if acceptButton.waitForExistence(timeout: UITestTiming.scaled(5)) {
                acceptButton.tap()
                _ = app.descendants(matching: .any)["home-screen"].waitForExistence(timeout: UITestTiming.scaled(10))
            }
            onboardingDismissed = true
        }
    }

    private func executeOpenURL(_ action: TestAction) throws {
        guard var url = action.url else {
            throw ActionError.missingParam("url", "openURL")
        }

        // Replace {sharedFilePath} placeholder if present
        if let sharedPath = sharedFilePath {
            url = url.replacingOccurrences(of: "{sharedFilePath}", with: sharedPath)
        }

        // When we have shared file content, pass it directly as a base64-encoded
        // launch argument instead of a file URL. This avoids cross-process file
        // path issues where the test runner's temp directory differs from the
        // app's sandboxed container (which causes validateDeepLinkPath to reject
        // the path).
        app.terminate()
        if let content = sharedFileContent,
           url.contains("liftmark://") {
            let base64 = Data(content.utf8).base64EncodedString()
            app.launchArguments = ["--import-content", base64]
        } else {
            app.launchArguments = ["-url", url]
        }
        app.launch()

        if !onboardingDismissed {
            let acceptButton = app.descendants(matching: .any)["onboarding-accept-button"]
            if acceptButton.waitForExistence(timeout: UITestTiming.scaled(5)) {
                acceptButton.tap()
                _ = app.descendants(matching: .any)["home-screen"].waitForExistence(timeout: UITestTiming.scaled(10))
            }
            onboardingDismissed = true
        }
    }

    private func executeDismissAlert(_ action: TestAction) throws {
        guard let button = action.button else {
            throw ActionError.missingParam("button", "dismissAlert")
        }
        let alertButton = app.alerts.buttons[button]
        XCTAssertTrue(alertButton.waitForExistence(timeout: UITestTiming.scaled(5)), "Alert button '\(button)' not found")
        alertButton.tap()
    }

    private func executeDelay(_ action: TestAction) throws {
        let ms = action.ms ?? 1000
        Thread.sleep(forTimeInterval: TimeInterval(ms) / 1000.0)
    }

    private func executeTryCatch(_ action: TestAction) throws {
        guard let trySteps = action.trySteps else {
            throw ActionError.missingParam("try", "tryCatch")
        }

        // Use non-asserting execution for try block steps.
        // This avoids XCTAssert failures (which throw ObjC exceptions
        // with continueAfterFailure=false) that can't be caught by
        // Swift's do/catch.
        var trySucceeded = true
        for step in trySteps {
            if !tryExecuteStep(step) {
                trySucceeded = false
                break
            }
        }

        if !trySucceeded {
            let catchSteps = action.catchSteps ?? []
            for step in catchSteps {
                try execute(step)
            }
        }
    }

    /// Non-asserting execution of a step for use inside tryCatch try blocks.
    /// Returns true if the step succeeded, false otherwise.
    private func tryExecuteStep(_ action: TestAction) -> Bool {
        switch action.action {
        case "waitFor":
            let timeout = TimeInterval(action.timeout ?? 5000) / 1000.0
            if let target = action.target {
                return waitForAnyElement(byId: target, timeout: timeout) != nil
            }
            guard let el = try? resolveElement(action) else { return false }
            return el.waitForExistence(timeout: UITestTiming.scaled(timeout))

        case "waitForText":
            guard let text = action.text else { return false }
            let timeout = TimeInterval(action.timeout ?? 5000) / 1000.0
            // Try exact match first with native waiter
            if app.staticTexts[text].waitForExistence(timeout: UITestTiming.scaled(min(timeout, 2))) { return true }
            let containsPredicate = NSPredicate(format: "label CONTAINS %@", text)
            let textDeadline = Date().addingTimeInterval(UITestTiming.scaled(timeout))
            while Date() < textDeadline {
                if app.staticTexts[text].exists { return true }
                if app.alerts.buttons[text].exists { return true }
                if app.buttons[text].exists { return true }
                if app.staticTexts.matching(containsPredicate).firstMatch.exists { return true }
                if app.buttons.matching(containsPredicate).firstMatch.exists { return true }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return false

        case "waitForNot":
            guard let el = try? resolveElement(action) else { return true }
            let timeout = TimeInterval(action.timeout ?? 5000) / 1000.0
            let predicate = NSPredicate(format: "exists == false")
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: el)
            return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed

        case "expect":
            let assertion = action.assertion ?? ""
            if let target = action.target {
                let el = waitForAnyElement(byId: target, timeout: 5)
                switch assertion {
                case "toBeVisible":
                    return el != nil && el!.isHittable
                case "toExist":
                    return el != nil
                case "notToExist":
                    return el == nil || !el!.exists
                case "notToBeVisible":
                    return el == nil || !el!.isHittable
                default:
                    return false
                }
            }
            guard let el = try? resolveElement(action) else { return false }
            switch assertion {
            case "toBeVisible":
                return el.waitForExistence(timeout: UITestTiming.scaled(5)) && el.isHittable
            case "toExist":
                return el.waitForExistence(timeout: UITestTiming.scaled(5))
            case "notToExist":
                return !el.exists
            case "notToBeVisible":
                return !el.exists || !el.isHittable
            default:
                return false
            }

        case "tap":
            if let target = action.target {
                guard let el = waitForAnyElement(byId: target, timeout: 5) else { return false }
                el.tap()
                return true
            }
            guard let el = try? resolveElement(action) else { return false }
            guard el.waitForExistence(timeout: UITestTiming.scaled(5)) else { return false }
            el.tap()
            return true

        case "tapText":
            guard let text = action.text else { return false }
            // Try alert button first with short native wait
            let alertBtn = app.alerts.buttons[text]
            if alertBtn.waitForExistence(timeout: UITestTiming.scaled(1)) { alertBtn.tap(); return true }
            let containsPred = NSPredicate(format: "label CONTAINS %@", text)
            let tapDeadline = Date().addingTimeInterval(UITestTiming.scaled(3))
            while Date() < tapDeadline {
                let staticText = app.staticTexts[text]
                if staticText.exists { staticText.tap(); return true }
                let btn = app.buttons[text]
                if btn.exists { btn.tap(); return true }
                let containsMatch = app.staticTexts.matching(containsPred).firstMatch
                if containsMatch.exists { containsMatch.tap(); return true }
                let btnContains = app.buttons.matching(containsPred).firstMatch
                if btnContains.exists { btnContains.tap(); return true }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return false

        default:
            // For unhandled actions, try executing normally
            do {
                try execute(action)
                return true
            } catch {
                return false
            }
        }
    }

    private func executeRunFixture(_ action: TestAction) throws {
        guard let fixture = action.fixture else {
            throw ActionError.missingParam("fixture", "runFixture")
        }
        guard let expectedName = action.expectedName else {
            throw ActionError.missingParam("expectedName", "runFixture")
        }

        let content = try readFixture(fixture)

        // Navigate to home, open import, paste content, confirm
        let homeTab = element(byId: "tab-home")
        XCTAssertTrue(homeTab.waitForExistence(timeout: UITestTiming.scaled(5)))
        homeTab.tap()
        Thread.sleep(forTimeInterval: 0.5)

        guard let importButton = waitForAnyElement(byId: "button-import-workout", timeout: 5) else {
            XCTFail("button-import-workout not found for runFixture")
            return
        }
        scrollToHittable(importButton)
        importButton.tap()

        guard let inputMarkdown = waitForAnyElement(byId: "input-markdown", timeout: 10) else {
            XCTFail("input-markdown not found for runFixture")
            return
        }

        // Hardware-keyboard select-all + typeText. See executeReplaceText for why.
        inputMarkdown.tap()
        inputMarkdown.typeKey("a", modifierFlags: .command)
        inputMarkdown.typeText(content)

        guard let importBtn = waitForAnyElement(byId: "button-import", timeout: 5) else {
            XCTFail("button-import not found for runFixture")
            return
        }
        importBtn.tap()

        let okButton = app.alerts.buttons["OK"]
        XCTAssertTrue(okButton.waitForExistence(timeout: UITestTiming.scaled(10)), "OK button not found after import")
        okButton.tap()

        let workoutName = element(byText: expectedName)
        XCTAssertTrue(workoutName.waitForExistence(timeout: UITestTiming.scaled(10)), "Expected workout '\(expectedName)' not found after import")
    }

    private func executeScreenshot(_ action: TestAction) throws {
        guard let name = action.name, !name.isEmpty else {
            throw ActionError.missingParam("name", "screenshot")
        }
        // Wrap in XCTContext.runActivity so the attachment is owned by the
        // current test activity — keeps it in the .xcresult bundle without
        // needing a reference to the live XCTestCase.
        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    private func executeExecScript(_ action: TestAction) throws {
        guard let script = action.script else {
            throw ActionError.missingParam("script", "execScript")
        }

        switch script {
        case "writeSharedFile":
            try executeWriteSharedFile(action)
        default:
            XCTFail("Unknown execScript: \(script)")
        }
    }

    private func executeWriteSharedFile(_ action: TestAction) throws {
        guard let args = action.args else {
            throw ActionError.missingParam("args", "execScript/writeSharedFile")
        }

        let content: String
        if let fixtureName = args["fixture"]?.stringValue {
            content = try readFixture(fixtureName)
        } else if let textContent = args["content"]?.stringValue {
            content = textContent
        } else {
            throw ActionError.missingParam("fixture or content", "execScript/writeSharedFile")
        }

        let filename = args["filename"]?.stringValue ?? "test.md"

        // Store content so executeOpenURL can pass it directly as a launch
        // argument, bypassing cross-process file path sandbox issues.
        sharedFileContent = content

        // Also write to a temporary location for backward compatibility.
        let tempDir = NSTemporaryDirectory()
        let inboxDir = (tempDir as NSString).appendingPathComponent("TestInbox")
        try FileManager.default.createDirectory(atPath: inboxDir, withIntermediateDirectories: true)

        let filePath = (inboxDir as NSString).appendingPathComponent(filename)
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)

        // Store for openURL placeholder resolution
        sharedFilePath = filePath.replacingOccurrences(of: "^/", with: "", options: .regularExpression)
    }
}

// MARK: - Errors

enum ActionError: Error, LocalizedError {
    case missingSelector(String)
    case missingParam(String, String)
    case fixtureNotFound(String, String)

    var errorDescription: String? {
        switch self {
        case .missingSelector(let action):
            return "No element selector (target or text) in action: \(action)"
        case .missingParam(let param, let action):
            return "Missing required param '\(param)' in action: \(action)"
        case .fixtureNotFound(let name, let path):
            return "Fixture '\(name)' not found at: \(path)"
        }
    }
}
