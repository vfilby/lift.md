import SwiftUI
import XCTest
@testable import LiftMark

/// Unit tests for `EnlargedTypeSize` — the Dynamic Type size used by the
/// long-press enlarged reading view. See spec/screens/history-detail.md →
/// "Enlarged Exercise View (long press) — GH #432".
final class EnlargedTypeSizeTests: XCTestCase {

    func testDefaultSizeEnlargesToAccessibility2() {
        XCTAssertEqual(EnlargedTypeSize.size(for: .large), .accessibility2)
    }

    func testSmallSizesAreFlooredAtAccessibility2() {
        XCTAssertEqual(EnlargedTypeSize.size(for: .xSmall), .accessibility2)
        XCTAssertEqual(EnlargedTypeSize.size(for: .medium), .accessibility2)
        XCTAssertEqual(EnlargedTypeSize.size(for: .xxLarge), .accessibility2)
    }

    func testLargerUserSettingsGrowThreeSteps() {
        XCTAssertEqual(EnlargedTypeSize.size(for: .xxxLarge), .accessibility3)
        XCTAssertEqual(EnlargedTypeSize.size(for: .accessibility1), .accessibility4)
        XCTAssertEqual(EnlargedTypeSize.size(for: .accessibility2), .accessibility5)
    }

    func testCapsAtPlatformMaximum() {
        XCTAssertEqual(EnlargedTypeSize.size(for: .accessibility3), .accessibility5)
        XCTAssertEqual(EnlargedTypeSize.size(for: .accessibility5), .accessibility5)
    }

    func testEveryInputMapsWithinBoundsAndNeverShrinks() {
        for size in DynamicTypeSize.allCases {
            let enlarged = EnlargedTypeSize.size(for: size)
            XCTAssertGreaterThanOrEqual(enlarged, .accessibility2, "\(size)")
            XCTAssertLessThanOrEqual(enlarged, .accessibility5, "\(size)")
            XCTAssertGreaterThanOrEqual(enlarged, size, "enlarged view must never be smaller than \(size)")
        }
    }

    func testMappingIsMonotonic() {
        let mapped = DynamicTypeSize.allCases.map(EnlargedTypeSize.size(for:))
        XCTAssertEqual(mapped, mapped.sorted())
    }
}
