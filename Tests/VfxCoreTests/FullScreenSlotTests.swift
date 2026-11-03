import XCTest
@testable import VfxCore

final class FullScreenSlotTests: XCTestCase {
    private var engine: FakeEngine!
    private var env: FakeEnv!
    private let presenter = NSObject()

    private func config(_ p: Placement, fullGap: Int = 0) -> Config {
        Config(ttlSec: 3600, enabled: true, test: false, reason: "", fullGapSec: fullGap, sessionTimeoutSec: 1800, log: "warn", ump: false, child: false, underAge: false, rating: "",
               eventsOn: true, eventsUrl: "https://x/e", sample: 1.0, batch: 20, flushSec: 30, kv: [:], ab: "", placements: [p.name: p])
    }
    private func pl(floors: [String] = [], cap: Cap = Cap(), retry: Retry = Retry(maxAttempts: 3, baseSec: 2, maxSec: 64), expiry: Int = 55) -> Placement {
        Placement(name: "lv", format: .interstitial, on: true, unit: "/1/int", preload: true, expiryMin: expiry, refreshSec: 0, cap: cap, retry: retry,
                  floors: Floors(key: "vfx_fl", tiers: floors, timeoutMs: 2500), collapsible: "", template: "", autoShow: false)
    }

    override func setUp() {
        engine = FakeEngine()
        env = FakeEnv(engine: engine, cfg: config(pl(floors: ["300", "150"])))
        env.pacer.startSession(number: 5, at: env.t - 3_600_000)
    }

    func testAsksTheFloorTiersHighestFirstThenWithoutAFloor() {
        let s = FullScreenSlot(name: "lv", env: env)
        s.load()
        XCTAssertEqual(engine.requests[0].kv, ["vfx_pl": "lv", "vfx_fl": "300"])
        engine.requests[0].cb(.failure(EngineError(code: 3, message: "no fill")))
        XCTAssertEqual(engine.requests[1].kv["vfx_fl"], "150", "300 had no fill: 150 next")
        env.advance(2600)   // 150 too slow: counted as no fill, the request without a floor goes out
        XCTAssertEqual(engine.requests.count, 3)
        XCTAssertNil(engine.requests[2].kv["vfx_fl"])
        engine.requests[1].cb(.success(engine.ad()))   // the slow one answers at last: thrown away
        XCTAssertEqual(engine.destroyed, 1)
        XCTAssertFalse(s.isReady())
        engine.requests[2].cb(.success(engine.ad()))
        XCTAssertTrue(s.isReady())
        XCTAssertEqual(env.types(), ["req", "nofill", "req", "nofill", "req", "fill"])
        XCTAssertEqual(env.events.map { $0.1["tier"] as? Int }, [1, 1, 2, 2, 0, 0])
    }

    func testShowsOnlyWhenThePacingAllowsAndLoadsTheNextAtOnce() {
        var c = Cap(); c.minIntervalSec = 60
        env.cfg = config(pl(cap: c))
        let s = FullScreenSlot(name: "lv", env: env)
        s.load(); engine.requests[0].cb(.success(engine.ad()))
        var said: [String] = []
        let cb = VfxShowCallbacks(onShown: { said.append("shown") }, onDismissed: { said.append("dismissed") }, onNotShown: { said.append($0) })
        s.show(presenter: presenter, callbacks: cb)
        engine.lastListener!.onShown()
        engine.lastListener!.onPaid(valueMicros: 4210, currency: "USD", precision: "PRECISE")
        engine.lastListener!.onDismissed()
        XCTAssertEqual(said, ["shown", "dismissed"])
        XCTAssertEqual(engine.requests.count, 2, "the next one is asked for as soon as it closes")
        engine.requests[1].cb(.success(engine.ad()))
        env.advance(10_000)
        s.show(presenter: presenter, callbacks: cb)
        XCTAssertEqual(said.last, "interval")
        XCTAssertTrue(s.isReady(), "…and still waiting")
        let paid = env.events.first { $0.0 == "paid" }!.1
        XCTAssertEqual(paid["v"] as? Int64, 4210); XCTAssertEqual(paid["cur"] as? String, "USD"); XCTAssertEqual(paid["prec"] as? String, "PRECISE")
        XCTAssertTrue(env.types().contains("capped"))
    }

    func testNotReadyLoadsAndSaysSo() {
        let s = FullScreenSlot(name: "lv", env: env)
        var why = ""
        s.show(presenter: presenter, callbacks: VfxShowCallbacks(onNotShown: { why = $0 }))
        XCTAssertEqual(why, "not_ready")
        XCTAssertEqual(engine.requests.count, 1)
    }

    func testAnOldAdIsThrownAwayBeforeGoogleExpiresIt() {
        env.cfg = config(pl(expiry: 55))
        let s = FullScreenSlot(name: "lv", env: env)
        s.load(); engine.requests[0].cb(.success(engine.ad()))
        env.advance(54 * 60_000); XCTAssertTrue(s.isReady())
        env.advance(2 * 60_000); XCTAssertFalse(s.isReady())
        XCTAssertEqual(engine.destroyed, 1)
    }

    func testRetriesAfterAGrowingWaitThenGivesUpUntilAskedAgain() {
        env.cfg = config(pl(retry: Retry(maxAttempts: 3, baseSec: 2, maxSec: 64)))
        let s = FullScreenSlot(name: "lv", env: env)
        let fail = { self.engine.requests.last!.cb(.failure(EngineError(code: 3, message: "no fill"))) }
        s.load(); fail()
        env.advance(1999); XCTAssertEqual(engine.requests.count, 1)
        env.advance(1); XCTAssertEqual(engine.requests.count, 2, "after 2 s")
        fail()
        env.advance(4000); XCTAssertEqual(engine.requests.count, 3, "after 4 s more")
        fail()
        env.advance(8000); XCTAssertEqual(engine.requests.count, 4, "after 8 s more")
        fail()
        env.advance(600_000); XCTAssertEqual(engine.requests.count, 4, "given up")
        XCTAssertEqual(s.state, "gave up")
        s.load(fresh: true); XCTAssertEqual(engine.requests.count, 5, "a show() or a return starts again")
    }

    func testNothingWithoutConsentOrWhilePaused() {
        env.can = false
        let s = FullScreenSlot(name: "lv", env: env)
        s.load(); XCTAssertEqual(engine.requests.count, 0)
        var why = ""
        s.show(presenter: presenter, callbacks: VfxShowCallbacks(onNotShown: { why = $0 }))
        XCTAssertEqual(why, "consent")
        env.can = true
        env.cfg?.enabled = false
        s.show(presenter: presenter, callbacks: VfxShowCallbacks(onNotShown: { why = $0 }))
        XCTAssertEqual(why, "paused")
    }

    func testNeverTwoAtOnce() {
        let s = FullScreenSlot(name: "lv", env: env)
        env.cfg = config(pl())
        s.load(); engine.requests[0].cb(.success(engine.ad()))
        env.fullScreenShowing = true
        var why = ""
        s.show(presenter: presenter, callbacks: VfxShowCallbacks(onNotShown: { why = $0 }))
        XCTAssertEqual(why, "showing")
    }

    func testNoPresenterMeansNotShown() {
        let s = FullScreenSlot(name: "lv", env: env)
        s.load(); engine.requests[0].cb(.success(engine.ad()))
        var why = ""
        s.show(presenter: nil, callbacks: VfxShowCallbacks(onNotShown: { why = $0 }))
        XCTAssertEqual(why, "no_presenter")
    }

    private func plBid(floors: [String] = []) -> Placement {
        var p = pl(floors: floors); p.prebidImp = "imp-lv"; return p
    }

    func testBidsAreAskedForFirstAndTheWinnerGoesToGoogleOnEveryTier() {
        env.cfg = config(plBid(floors: ["300", "150"]))
        var answer: (([String: String]) -> Void)?
        env.prebidAsk = { _, done in answer = done }
        let s = FullScreenSlot(name: "lv", env: env)
        s.load()
        XCTAssertEqual(engine.requests.count, 0, "Google is not asked while the bids are awaited")
        XCTAssertEqual(s.state, "bidding")
        s.load()   // a second load() meanwhile asks for nothing more
        answer!(["hb_pb": "1.20", "hb_bidder": "appnexus"])
        XCTAssertEqual(engine.requests[0].kv, ["vfx_pl": "lv", "vfx_fl": "300", "hb_pb": "1.20", "hb_bidder": "appnexus"])
        engine.requests[0].cb(.failure(EngineError(code: 3, message: "no fill")))
        XCTAssertEqual(engine.requests[1].kv["hb_pb"], "1.20", "the next floor tier carries the bid too")
        XCTAssertEqual(engine.requests[1].kv["vfx_fl"], "150")
        env.advance(2600)
        XCTAssertEqual(engine.requests[2].kv["hb_pb"], "1.20", "…and so does the request without a floor")
        XCTAssertNil(engine.requests[2].kv["vfx_fl"])
    }

    func testNoBidsMeansGoogleAloneAsBefore() {
        env.cfg = config(plBid())
        env.prebidAsk = { _, done in done([:]) }
        FullScreenSlot(name: "lv", env: env).load()
        XCTAssertEqual(engine.requests[0].kv, ["vfx_pl": "lv"])
    }

    func testAPlacementNotBidForNeverAsksPrebid() {
        var asked = 0
        env.prebidAsk = { _, done in asked += 1; done([:]) }
        FullScreenSlot(name: "lv", env: env).load()   // setUp's placement has no prebidImp
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(engine.requests.count, 1)
    }

    func testAResetWhileBiddingDropsTheLateAnswer() {
        env.cfg = config(plBid())
        var answer: (([String: String]) -> Void)?
        env.prebidAsk = { _, done in answer = done }
        let s = FullScreenSlot(name: "lv", env: env)
        s.load(); s.reset()
        answer!(["hb_pb": "9.90"])
        XCTAssertEqual(engine.requests.count, 0, "settings changed meanwhile: the old auction is forgotten")
        XCTAssertEqual(s.state, "idle")
        s.load(); answer!(["hb_pb": "1.00"])
        XCTAssertEqual(engine.requests[0].kv["hb_pb"], "1.00", "a new load works")
    }
}
