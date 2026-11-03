import XCTest
@testable import VfxCore

final class PacerTests: XCTestCase {
    private var now: Int64 = 1_800_000_000_000
    private let store = MapStore()
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Karachi")!; return c }
    private func pacer() -> Pacer { Pacer(store: store, clock: { [unowned self] in self.now }, calendar: { self.cal }) }
    private func pl(_ cap: Cap, _ f: VfxFormat = .interstitial, _ name: String = "lv") -> Placement {
        Placement(name: name, format: f, on: true, unit: "/1/u", preload: true, expiryMin: 55, refreshSec: 0, cap: cap, retry: Retry(), floors: Floors(), collapsible: "", template: "", autoShow: false)
    }
    private func cap(_ f: (inout Cap) -> Void) -> Cap { var c = Cap(); f(&c); return c }

    func testGraceAtTheStartOfASessionAndTheFirstSessions() {
        let p = pacer(); p.startSession(number: 1, at: now)
        XCTAssertEqual(p.check(pl(cap { $0.graceSessions = 1 }), fullGapSec: 0), "grace")
        p.startSession(number: 2, at: now)
        XCTAssertNil(p.check(pl(cap { $0.graceSessions = 1 }), fullGapSec: 0))
        XCTAssertEqual(p.check(pl(cap { $0.graceSec = 30 }), fullGapSec: 0), "grace")
        now += 31_000
        XCTAssertNil(p.check(pl(cap { $0.graceSec = 30 }), fullGapSec: 0))
    }

    func testAnIntervalPerPlacementAndAGapBetweenAnyTwo() {
        let p = pacer(); p.startSession(number: 3, at: now - 100_000)
        let a = pl(cap { $0.minIntervalSec = 60 })
        p.recordShow(a)
        now += 10_000
        XCTAssertEqual(p.check(pl(Cap(), .interstitial, "other"), fullGapSec: 30), "gap")
        XCTAssertNil(p.check(pl(Cap(), .rewarded, "rw"), fullGapSec: 30), "a rewarded ad is asked for by the user: no gap")
        now += 25_000
        XCTAssertEqual(p.check(a, fullGapSec: 30), "interval")
        now += 30_000
        XCTAssertNil(p.check(a, fullGapSec: 30))
    }

    func testPerSessionPerHourPerDay() {
        let p = pacer(); p.startSession(number: 5, at: now - 1_000_000)
        let s = pl(cap { $0.maxPerSession = 2 })
        p.recordShow(s); p.recordShow(s)
        XCTAssertEqual(p.check(s, fullGapSec: 0), "session")
        p.startSession(number: 6, at: now)
        XCTAssertNil(p.check(s, fullGapSec: 0))
        let h = pl(cap { $0.maxPerHour = 2 }, .interstitial, "h")
        p.recordShow(h); now += 60_000; p.recordShow(h)
        XCTAssertEqual(p.check(h, fullGapSec: 0), "hour")
        now += 3_600_000
        XCTAssertNil(p.check(h, fullGapSec: 0))
        let d = pl(cap { $0.maxPerDay = 1 }, .interstitial, "d")
        p.recordShow(d)
        XCTAssertEqual(p.check(d, fullGapSec: 0), "day")
        now += 86_400_000
        XCTAssertNil(p.check(d, fullGapSec: 0))
    }

    func testEveryNthEligibleCall() {
        let p = pacer(); p.startSession(number: 9, at: now - 1_000_000)
        let n = pl(cap { $0.everyNth = 3 })
        XCTAssertEqual((1...6).map { _ in p.check(n, fullGapSec: 0) }, ["nth", "nth", nil, "nth", "nth", nil])
    }

    func testTheLastShowSurvivesARestart() {
        let a = pl(cap { $0.minIntervalSec = 600 })
        let first = pacer(); first.startSession(number: 1, at: now); first.recordShow(a)
        now += 60_000
        let again = pacer(); again.startSession(number: 2, at: now)
        XCTAssertEqual(again.check(a, fullGapSec: 0), "interval")
    }
}
