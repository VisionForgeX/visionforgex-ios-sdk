import XCTest
@testable import VfxCore

/// The banner size ladder: from the largest down, only on "no fill" or "invalid request".
final class BannerLadderTests: XCTestCase {
    func testLargestFirstThenStandardThenSmall() {
        XCTAssertEqual(BannerLadder.tier(0, large: "L", standard: "S", small: "B"), ["L", "S", "B"])
        XCTAssertEqual(BannerLadder.tier(1, large: "L", standard: "S", small: "B"), ["S"])
        XCTAssertEqual(BannerLadder.tier(2, large: "L", standard: "S", small: "B"), ["B"])
    }
    func testStepsDownOnlyWhenASmallerSizeCouldHelp() {
        XCTAssertEqual(BannerLadder.next(0, code: 1), 1)   // GADErrorNoFill
        XCTAssertEqual(BannerLadder.next(1, code: 1), 2)
        XCTAssertNil(BannerLadder.next(2, code: 1), "320x50 was the last: report it")
        XCTAssertEqual(BannerLadder.next(0, code: 0), 1)   // GADErrorInvalidRequest
        XCTAssertNil(BannerLadder.next(0, code: 2), "a network error is not about the size")
    }
}
