import XCTest
@testable import VfxCore

final class EventLogTests: XCTestCase {
    private var now: Int64 = 1_800_000_000_000
    private var sent: [(String, [String: Any])] = []
    private var code = 200
    private var dir: URL!
    private let header = EventLog.Header(key: "vfx_k", install: "inst", session: "sess", sdk: "1.0.0", appVersion: "2.3.1", os: "17.5", device: "iPhone15,2", country: "PK", ab: "e1:b", sample: 1.0)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vfx-ev-" + UUID().uuidString)
        sent = []; code = 200
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func log(file: Bool = true) -> EventLog {
        EventLog(dir: file ? dir : nil, clock: { [unowned self] in self.now }, io: { $0() }, send: { [unowned self] _, json in
            if let o = (try? JSONSerialization.jsonObject(with: json.data(using: .utf8)!)) as? [String: Any] { self.sent.append(("", o)) }
            return HttpResult(code: self.code, body: "{\"ok\":true}", etag: nil)
        })
    }

    func testSendsABatchWithTheHeader() {
        let l = log()
        l.add("ses", ["n": 3, "first": false])
        l.add("req", ["pl": "level_complete", "f": "interstitial", "tier": 1])
        var accepted = -1
        l.flush(url: "https://x/e", header: header) { accepted = $0 }
        XCTAssertEqual(accepted, 2)
        let b = sent[0].1
        XCTAssertEqual(b["k"] as? String, "vfx_k"); XCTAssertEqual(b["p"] as? String, "ios"); XCTAssertEqual(b["c"] as? String, "PK"); XCTAssertEqual(b["ab"] as? String, "e1:b")
        let e = b["e"] as! [[String: Any]]
        XCTAssertEqual(e.map { $0["t"] as? String }, ["ses", "req"])
        XCTAssertEqual(l.size(), 0)
    }

    func testOutOfTheSampleOnlySessionsAndRevenueGo() {
        let l = log(); l.inSample = false
        l.add("req", [:]); l.add("fill", [:]); l.add("ses", [:]); l.add("paid", ["v": 10])
        XCTAssertEqual(l.size(), 2)
    }

    func testNothingIsLostWhenTheAppStopsOrThePlatformIsDown() {
        let l = log()
        l.add("show", ["pl": "a"]); l.add("paid", ["pl": "a", "v": 5])
        code = 503
        l.flush(url: "https://x/e", header: header)
        XCTAssertEqual(l.size(), 2, "a 5xx keeps them")
        let again = log()   // the app was closed and opened again
        XCTAssertEqual(again.size(), 2, "…and they survive a restart")
        code = 200
        again.flush(url: "https://x/e", header: header)
        XCTAssertEqual(again.size(), 0)
        code = 400
        again.add("show", [:])
        again.flush(url: "https://x/e", header: header)
        XCTAssertEqual(again.size(), 0, "a 4xx drops the batch: it would fail again")
    }

    func testAtMost500AtATime() {
        let l = log(file: false)
        for i in 0..<1200 { now += 1; l.add("req", ["i": i]) }
        l.flush(url: "https://x/e", header: header)
        XCTAssertEqual((sent[0].1["e"] as! [Any]).count, 500)
        XCTAssertEqual(l.size(), 700)
    }
}
