import XCTest
@testable import VfxCore

final class PrebidTests: XCTestCase {
    private let settings = PrebidSettings(url: "https://pbs.example.com/openrtb2/auction", request: "vfx-a1", timeoutMs: 800, breakerFailures: 3, breakerPauseSec: 600)
    private let device = Prebid.Device(os: "ios", osv: "17.4", make: "Apple", model: "iPhone15,2", tablet: false, language: "en", w: 1179, h: 2556, pxratio: 3.0, ua: "VisionForgeX-iOS/1.1.0")
    private let noSignals = Prebid.Signals(gdprApplies: nil, tcString: "", usPrivacy: "", gpp: "", gppSid: "")

    // MARK: the settings

    private let base = """
    {"v":1,"ttl":3600,"app":{"enabled":true},"placements":{
      "ban":{"format":"banner","on":true,"unit":"/1/b","prebid":{"imp":"vfx-a1-banner"}},
      "int":{"format":"interstitial","on":true,"unit":"/1/i","prebid":{"imp":"vfx-a1-interstitial"}},
      "rew":{"format":"rewarded","on":true,"unit":"/1/r","prebid":{"imp":"vfx-a1-rewarded"}},
      "plain":{"format":"banner","on":true,"unit":"/1/p"}}
    """

    func testTheBlockAndTheEntriesAreRead() {
        let c = ConfigParser.parse(base + ",\"prebid\":{\"url\":\"https://pbs.example.com/openrtb2/auction\",\"request\":\"vfx-a1\",\"timeoutMs\":900,\"breaker\":{\"failures\":4,\"pauseSec\":300}}}")!
        XCTAssertEqual(c.prebid, PrebidSettings(url: "https://pbs.example.com/openrtb2/auction", request: "vfx-a1", timeoutMs: 900, breakerFailures: 4, breakerPauseSec: 300))
        XCTAssertEqual(c.placements["ban"]!.prebidImp, "vfx-a1-banner")
        XCTAssertEqual(c.placements["int"]!.prebidImp, "vfx-a1-interstitial")
        XCTAssertEqual(c.placements["rew"]!.prebidImp, "", "formats Prebid does not bid for are never given an imp")
        XCTAssertEqual(c.placements["plain"]!.prebidImp, "")
    }

    func testSettingsWithoutTheBlockAreExactlyAsBefore() {
        XCTAssertNil(ConfigParser.parse(base + "}")!.prebid)
    }

    func testAnUnusableBlockMeansNothingIsBidFor() {
        XCTAssertNil(ConfigParser.parse(base + ",\"prebid\":{\"url\":\"ftp://x\",\"request\":\"vfx-a1\"}}")!.prebid)
        XCTAssertNil(ConfigParser.parse(base + ",\"prebid\":{\"url\":\"https://x/y\",\"request\":\"has space\"}}")!.prebid)
        XCTAssertNil(ConfigParser.parse(base + ",\"prebid\":{\"url\":\"https://x/y\"}}")!.prebid)
        XCTAssertNil(ConfigParser.parse(base + ",\"prebid\":\"yes\"}")!.prebid)
    }

    func testTheWaitAndTheBreakerStayWithinBounds() {
        let a = ConfigParser.parse(base + ",\"prebid\":{\"url\":\"https://x/y\",\"request\":\"r\",\"timeoutMs\":999999,\"breaker\":{\"failures\":0,\"pauseSec\":1}}}")!.prebid!
        XCTAssertEqual(a.timeoutMs, 3000); XCTAssertEqual(a.breakerFailures, 1); XCTAssertEqual(a.breakerPauseSec, 30)
        XCTAssertEqual(ConfigParser.parse(base + ",\"prebid\":{\"url\":\"https://x/y\",\"request\":\"r\",\"timeoutMs\":1}}")!.prebid!.timeoutMs, 100)
    }

    func testAnImpThatIsNotAStoredIdIsDropped() {
        let c = ConfigParser.parse("{\"v\":1,\"placements\":{\"ban\":{\"format\":\"banner\",\"on\":true,\"unit\":\"/1/b\",\"prebid\":{\"imp\":\"a b\"}}}}")!
        XCTAssertEqual(c.placements["ban"]!.prebidImp, "")
    }

    // MARK: the request

    private func json(_ s: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any] }

    func testTheRequestCarriesOnlyIdsAndWhatTheDeviceSays() {
        let j = json(Prebid.request(settings, imp: "vfx-a1-banner", appVersion: "2.3", sdkVersion: "1.1.0", device: device, signals: noSignals, auctionId: "auction-1"))
        XCTAssertEqual(j["id"] as? String, "auction-1")
        let imp = (j["imp"] as! [[String: Any]])[0]
        XCTAssertEqual((((imp["ext"] as! [String: Any])["prebid"] as! [String: Any])["storedrequest"] as! [String: Any])["id"] as? String, "vfx-a1-banner")
        XCTAssertEqual((((j["ext"] as! [String: Any])["prebid"] as! [String: Any])["storedrequest"] as! [String: Any])["id"] as? String, "vfx-a1")
        XCTAssertEqual(imp["displaymanager"] as? String, "VisionForgeX")
        XCTAssertEqual((j["app"] as! [String: Any])["ver"] as? String, "2.3")
        let d = j["device"] as! [String: Any]
        XCTAssertEqual(d["os"] as? String, "ios"); XCTAssertEqual(d["devicetype"] as? Int, 4); XCTAssertEqual(d["w"] as? Int, 1179)
        XCTAssertNil(d["ifa"], "no advertising ID"); XCTAssertNil(d["geo"], "no location")
        XCTAssertNil(j["site"]); XCTAssertNil((j["app"] as! [String: Any])["bundle"]); XCTAssertNil(imp["banner"])
        XCTAssertNil(j["user"], "no consent: no user object")
        XCTAssertEqual(((j["regs"] as! [String: Any])["ext"] as! [String: Any]).count, 0)
    }

    func testATabletSaysSo() {
        var t = device; t.tablet = true
        let j = json(Prebid.request(settings, imp: "i", appVersion: "1", sdkVersion: "1", device: t, signals: noSignals))
        XCTAssertEqual((j["device"] as! [String: Any])["devicetype"] as? Int, 5)
    }

    func testConsentSignalsGoAsTheIabHasThem() {
        let s = Prebid.Signals(gdprApplies: true, tcString: "CPtc-string", usPrivacy: "1YNN", gpp: "DBABM~BVQqAAAAAgA.QA", gppSid: "2_7")
        let j = json(Prebid.request(settings, imp: "i", appVersion: "1", sdkVersion: "1", device: device, signals: s))
        let regs = j["regs"] as! [String: Any], ext = regs["ext"] as! [String: Any]
        XCTAssertEqual(ext["gdpr"] as? Int, 1); XCTAssertEqual(ext["us_privacy"] as? String, "1YNN")
        XCTAssertEqual(regs["gpp"] as? String, "DBABM~BVQqAAAAAgA.QA"); XCTAssertEqual(regs["gpp_sid"] as? [Int], [2, 7])
        XCTAssertEqual((((j["user"] as! [String: Any])["ext"]) as! [String: Any])["consent"] as? String, "CPtc-string")
        let no = json(Prebid.request(settings, imp: "i", appVersion: "1", sdkVersion: "1", device: device, signals: Prebid.Signals(gdprApplies: false, tcString: "", usPrivacy: "", gpp: "", gppSid: "")))
        XCTAssertEqual((((no["regs"] as! [String: Any])["ext"]) as! [String: Any])["gdpr"] as? Int, 0, "GDPR not applying is said too")
    }

    func testGdprThatAppliesWithoutAConsentStringMeansNoAuction() {
        XCTAssertEqual(Prebid.mustSkip(Prebid.Signals(gdprApplies: true, tcString: "", usPrivacy: "", gpp: "", gppSid: "")), "consent")
        XCTAssertNil(Prebid.mustSkip(Prebid.Signals(gdprApplies: true, tcString: "CPtc", usPrivacy: "", gpp: "", gppSid: "")))
        XCTAssertNil(Prebid.mustSkip(Prebid.Signals(gdprApplies: false, tcString: "", usPrivacy: "", gpp: "", gppSid: "")))
        XCTAssertNil(Prebid.mustSkip(noSignals))
    }

    // MARK: the answer

    private func answer(_ bids: String...) -> String { "{\"id\":\"x\",\"cur\":\"USD\",\"seatbid\":[{\"seat\":\"appnexus\",\"bid\":[\(bids.joined(separator: ","))]}]}" }
    private let winner = "{\"id\":\"b1\",\"impid\":\"1\",\"price\":1.23,\"ext\":{\"prebid\":{\"targeting\":{\"hb_pb\":\"1.20\",\"hb_bidder\":\"appnexus\",\"hb_size\":\"320x50\",\"hb_cache_id\":\"abc-123\",\"hb_cache_host\":\"pbs.example.com\",\"hb_cache_path\":\"/cache\"}}}}"
    private let loser = "{\"id\":\"b2\",\"impid\":\"1\",\"price\":0.5}"

    func testTheWinnersKeysAreTaken() {
        let r = Prebid.response(code: 200, body: answer(loser, winner), ms: 120)
        XCTAssertEqual(r.result, "bid"); XCTAssertEqual(r.valueMicros, 1_230_000); XCTAssertEqual(r.ms, 120)
        XCTAssertEqual(r.keys["hb_pb"], "1.20"); XCTAssertEqual(r.keys["hb_bidder"], "appnexus"); XCTAssertEqual(r.keys["hb_cache_path"], "/cache")
    }

    func testOnlyHbKeysWithSafeValuesAreKept() {
        let w = "{\"price\":2,\"ext\":{\"prebid\":{\"targeting\":{\"hb_pb\":\"2.00\",\"evil\":\"x\",\"hb_x\":\"<script>\",\"vfx_pl\":\"hijack\",\"hb_ok\":\"fine_1\",\"hb_nl\":\"a\\nb\"}}}}"
        XCTAssertEqual(Set(Prebid.response(code: 200, body: answer(w), ms: 1).keys.keys), Set(["hb_pb", "hb_ok"]))
    }

    func testNoBidsAreNotAnError() {
        XCTAssertEqual(Prebid.response(code: 204, body: "", ms: 5).result, "nobid")
        XCTAssertEqual(Prebid.response(code: 200, body: "{\"id\":\"x\",\"seatbid\":[]}", ms: 5).result, "nobid")
        XCTAssertEqual(Prebid.response(code: 200, body: answer(loser), ms: 5).result, "nobid")
        XCTAssertEqual(Prebid.response(code: 200, body: answer("{\"price\":1,\"ext\":{\"prebid\":{\"targeting\":{\"hb_bidder\":\"x\"}}}}"), ms: 5).result, "nobid", "no price bucket: no line item can match")
    }

    func testAnythingElseIsAnError() {
        XCTAssertEqual(Prebid.response(code: 500, body: "down", ms: 5).result, "error")
        XCTAssertEqual(Prebid.response(code: 400, body: "Invalid request", ms: 5).result, "error")
        XCTAssertEqual(Prebid.response(code: 200, body: "<html>", ms: 5).result, "error")
    }

    func testABidIsNeverWorthMoreThanAHundredForOneImpression() {
        XCTAssertEqual(Prebid.response(code: 200, body: answer("{\"price\":5000000,\"ext\":{\"prebid\":{\"targeting\":{\"hb_pb\":\"20.00\"}}}}"), ms: 1).valueMicros, 100_000_000)
    }

    // MARK: the breaker

    private func fail(_ r: String = "error") -> Prebid.Outcome { Prebid.Outcome(r, [:], 0, 10) }

    func testThreeFailuresInARowPauseTheAskingThenItResumes() {
        let b = Prebid.Breaker()
        b.record(fail(), 1000, settings); b.record(fail("timeout"), 1100, settings)
        XCTAssertFalse(b.isOpen(1200))
        b.record(fail(), 1200, settings)
        XCTAssertTrue(b.isOpen(1300)); XCTAssertTrue(b.isOpen(1200 + 599_000))
        XCTAssertFalse(b.isOpen(1200 + 600_000), "after the pause")
    }

    func testAnAnswerEndsTheRunAndSkipsDoNotCount() {
        let b = Prebid.Breaker()
        b.record(fail(), 0, settings); b.record(fail(), 0, settings)
        b.record(Prebid.Outcome("nobid", [:], 0, 5), 0, settings)   // the server is alive
        b.record(fail(), 0, settings); b.record(fail(), 0, settings)
        b.record(.skip(), 0, settings)
        XCTAssertFalse(b.isOpen(1))
    }

    // MARK: the runner, on a clock that moves when the test says

    private final class Rig {
        var t: Int64 = 1_000_000
        var timers: [(Int64, () -> Void, AnyObject)] = []
        var io: [() -> Void] = []
        var events: [(String, Prebid.Outcome, String)] = []
        var sent: [(String, String, Int)] = []
        var answers: [[String: String]] = []
        var runner: PrebidRunner!
        final class Tok {}
        init(sig: Prebid.Signals, http: @escaping (String, String, Int) -> HttpResult) {
            runner = PrebidRunner(
                post: { [unowned self] d, b in let k = Tok(); self.timers.append((self.t + d, b, k)); return k },
                cancel: { [unowned self] x in self.timers.removeAll { $0.2 === x } },
                now: { [unowned self] in self.t }, io: { [unowned self] b in self.io.append(b) },
                send: { [unowned self] u, b, tmo in self.sent.append((u, b, tmo)); return http(u, b, tmo) },
                device: { Prebid.Device(os: "ios", osv: "17", make: "Apple", model: "P", tablet: false, language: "en", w: 1, h: 1, pxratio: 1, ua: "") },
                signals: { sig }, appVersion: { "1.0" }, sdkVersion: "1.1.0",
                event: { [unowned self] p, r, why in self.events.append((p.name, r, why)) })
        }
        func pump() {
            while let due = timers.filter({ $0.0 <= t }).min(by: { $0.0 < $1.0 }) {
                timers.removeAll { $0.2 === due.2 }
                due.1()
            }
        }
        func advance(_ ms: Int64) { t += ms; pump() }
        func runIo() { let l = io; io = []; l.forEach { $0() }; pump() }
    }

    private func cfg(_ c: String? = nil) -> Config { ConfigParser.parse(c ?? base + ",\"prebid\":{\"url\":\"https://pbs.example.com/openrtb2/auction\",\"request\":\"vfx-a1\"}}")! }
    private func ban(_ c: Config) -> Placement { c.placements["ban"]! }
    private func ok(_ body: String) -> (String, String, Int) -> HttpResult { { _, _, _ in HttpResult(code: 200, body: body, etag: nil) } }

    func testAWinningBidGivesItsKeysAndIsReported() {
        let rig = Rig(sig: noSignals, http: ok(answer(winner)))
        let c = cfg()
        rig.runner.run(c, ban(c)) { rig.answers.append($0) }
        XCTAssertEqual(rig.answers.count, 0, "nothing is answered before the server has")
        rig.t += 150; rig.runIo()
        XCTAssertEqual(rig.answers.count, 1); XCTAssertEqual(rig.answers[0]["hb_pb"], "1.20")
        XCTAssertEqual(rig.events.count, 1)
        XCTAssertEqual(rig.events[0].1.result, "bid"); XCTAssertEqual(rig.events[0].1.ms, 150); XCTAssertEqual(rig.events[0].1.valueMicros, 1_230_000)
        XCTAssertEqual(rig.sent[0].0, "https://pbs.example.com/openrtb2/auction"); XCTAssertEqual(rig.sent[0].2, 800)
        XCTAssertTrue(rig.timers.isEmpty, "the wait timer is gone once answered")
    }

    func testASlowServerCostsAtMostTheWaitAndTheLateAnswerIsDropped() {
        let rig = Rig(sig: noSignals, http: ok(answer(winner)))
        let c = cfg()
        rig.runner.run(c, ban(c)) { rig.answers.append($0) }
        rig.advance(899)
        XCTAssertEqual(rig.answers.count, 0)
        rig.advance(1)
        XCTAssertEqual(rig.answers, [[:]], "answered with no bids at the wait (800) plus a short grace (100)")
        XCTAssertEqual(rig.events[0].1.result, "timeout")
        rig.runIo()
        XCTAssertEqual(rig.answers.count, 1, "the late answer changes nothing")
        XCTAssertEqual(rig.events.count, 1, "…and is not counted twice")
    }

    func testAServerThatCannotBeReachedIsAnErrorWhenItFailsAtOnce() {
        let rig = Rig(sig: noSignals, http: { _, _, _ in HttpResult(code: 0, body: "", etag: nil) })
        let c = cfg()
        rig.runner.run(c, ban(c)) { rig.answers.append($0) }
        rig.t += 20; rig.runIo()
        XCTAssertEqual(rig.events[0].1.result, "error")
        XCTAssertEqual(rig.answers, [[:]])
    }

    func testAfterThreeFailuresItDoesNotAskAndSaysWhy() {
        let rig = Rig(sig: noSignals, http: { _, _, _ in HttpResult(code: 500, body: "down", etag: nil) })
        let c = cfg()
        for _ in 0..<3 { rig.runner.run(c, ban(c)) { rig.answers.append($0) }; rig.t += 30; rig.runIo() }
        XCTAssertEqual(rig.sent.count, 3)
        rig.runner.run(c, ban(c)) { rig.answers.append($0) }
        XCTAssertEqual(rig.sent.count, 3, "left alone: no request, answered at once")
        XCTAssertEqual(rig.answers.count, 4)
        XCTAssertEqual(rig.events.last!.1.result, "skip"); XCTAssertEqual(rig.events.last!.2, "breaker")
        rig.t += 601_000
        rig.runner.run(c, ban(c)) { rig.answers.append($0) }
        rig.runIo()
        XCTAssertEqual(rig.sent.count, 4, "after the pause it asks again")
    }

    func testGdprWithoutAConsentStringNeverLeavesTheApp() {
        let rig = Rig(sig: Prebid.Signals(gdprApplies: true, tcString: "", usPrivacy: "", gpp: "", gppSid: ""), http: ok(answer(winner)))
        let c = cfg()
        rig.runner.run(c, ban(c)) { rig.answers.append($0) }
        XCTAssertEqual(rig.sent.count, 0)
        XCTAssertEqual(rig.answers, [[:]])
        XCTAssertEqual(rig.events[0].1.result, "skip"); XCTAssertEqual(rig.events[0].2, "consent")
    }

    func testNothingIsAskedWhenTheSettingsDoNotSayToOrTheAppIsForChildrenOrTesting() {
        let rig = Rig(sig: noSignals, http: ok(answer(winner)))
        let block = ",\"prebid\":{\"url\":\"https://x/y\",\"request\":\"r\"}}"
        let noBlock = cfg(base + "}")
        rig.runner.run(noBlock, ban(noBlock)) { rig.answers.append($0) }
        let plain = cfg(); rig.runner.run(plain, plain.placements["plain"]!) { rig.answers.append($0) }
        let child = cfg(base.replacingOccurrences(of: "\"app\":{\"enabled\":true}", with: "\"app\":{\"enabled\":true},\"consent\":{\"child\":true}") + block)
        rig.runner.run(child, ban(child)) { rig.answers.append($0) }
        let test = cfg(base.replacingOccurrences(of: "\"app\":{\"enabled\":true}", with: "\"app\":{\"enabled\":true,\"test\":true}") + block)
        rig.runner.run(test, ban(test)) { rig.answers.append($0) }
        XCTAssertEqual(rig.answers.count, 4, "every one answered at once, with nothing")
        XCTAssertEqual(rig.sent.count, 0); XCTAssertEqual(rig.events.count, 0, "…and none is an event")
    }

    func testTwoAuctionsAtOnceDoNotMixTheirAnswers() {
        var n = 0
        let rig = Rig(sig: noSignals, http: { _, _, _ in n += 1; return HttpResult(code: 200, body: self.answer(self.winner.replacingOccurrences(of: "1.20", with: "1.2\(n - 1)")), etag: nil) })
        let c = cfg()
        rig.runner.run(c, ban(c)) { rig.answers.append($0) }
        rig.runner.run(c, c.placements["int"]!) { rig.answers.append($0) }
        rig.t += 10; rig.runIo()
        XCTAssertEqual(rig.answers.map { $0["hb_pb"] }, ["1.20", "1.21"])
        XCTAssertEqual(rig.events.count, 2)
    }
}
