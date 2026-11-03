import XCTest
@testable import VfxCore

final class ConfigParserTests: XCTestCase {
    private let sample = """
    {"v":1,"ttl":3600,"app":{"enabled":true,"test":false,"reason":""},"global":{"fullGapSec":30,"sessionTimeoutSec":1800,"log":"warn"},
     "consent":{"ump":true,"child":false,"underAge":true,"rating":"T"},
     "events":{"on":true,"url":"https://apps.visionforgex.com/sdk/v1/events.php","sample":0.5,"batch":20,"flushSec":30},
     "kv":{"vfx_app":"com.example.game","Bad Key":"x"},"ab":"e1:b",
     "placements":{
       "level_complete":{"format":"interstitial","on":true,"unit":"/1,2/u-int","preload":true,"expiryMin":55,"refreshSec":0,
          "cap":{"minIntervalSec":60,"maxPerSession":0,"maxPerHour":4,"maxPerDay":0,"graceSec":30,"graceSessions":0,"everyNth":2},
          "retry":{"maxAttempts":6,"baseSec":2,"maxSec":64},"floors":{"key":"vfx_fl","tiers":["300","150"],"timeoutMs":2500},"collapsible":"","template":"","autoShow":false},
       "home":{"format":"banner","on":true,"unit":"/1/u-ban","refreshSec":10,"collapsible":"bottom"},
       "open":{"format":"app_open","on":true,"unit":"/1/u-ao","expiryMin":600,"autoShow":true},
       "weird":{"format":"video","on":true,"unit":"/1/x"},
       "Bad Name":{"format":"banner","on":true,"unit":"/1/x"}
     }}
    """

    func testReadsTheProtocolSample() throws {
        let c = try XCTUnwrap(ConfigParser.parse(sample))
        XCTAssertTrue(c.enabled); XCTAssertTrue(c.ump); XCTAssertTrue(c.underAge); XCTAssertEqual(c.rating, "T")
        XCTAssertEqual(c.sample, 0.5); XCTAssertEqual(c.ab, "e1:b")
        XCTAssertEqual(c.kv, ["vfx_app": "com.example.game"])
        let p = try XCTUnwrap(c.placements["level_complete"])
        XCTAssertEqual(p.format, .interstitial)
        XCTAssertEqual(p.floors.tiers, ["300", "150"])
        XCTAssertEqual(p.cap.minIntervalSec, 60); XCTAssertEqual(p.cap.maxPerHour, 4); XCTAssertEqual(p.cap.everyNth, 2); XCTAssertEqual(p.cap.graceSec, 30)
        XCTAssertEqual(Set(c.placements.keys), ["level_complete", "home", "open"])   // an unknown format and a bad name are left out
    }

    func testKeepsGooglesLimitsWhateverTheServerSays() throws {
        let c = try XCTUnwrap(ConfigParser.parse(sample))
        XCTAssertEqual(c.placements["home"]?.refreshSec, 30, "a banner never refreshes faster than 30 s")
        XCTAssertEqual(c.placements["home"]?.collapsible, "bottom")
        XCTAssertEqual(c.placements["open"]?.expiryMin, 239, "an app open ad is thrown away before Google's 4 hours")
        XCTAssertEqual(c.placements["open"]?.autoShow, true)
        let c2 = try XCTUnwrap(ConfigParser.parse(sample.replacingOccurrences(of: "\"expiryMin\":55", with: "\"expiryMin\":500")))
        XCTAssertEqual(c2.placements["level_complete"]?.expiryMin, 59, "other ads before Google's hour")
    }

    func testRefusesWhatItDoesNotUnderstand() {
        XCTAssertNil(ConfigParser.parse("not json"))
        XCTAssertNil(ConfigParser.parse("{\"v\":2}"))
        XCTAssertEqual(ConfigParser.parse("{\"v\":1,\"events\":{\"on\":true,\"url\":\"ftp://x\"}}")?.eventsOn, false)
        XCTAssertEqual(ConfigParser.parse("{\"v\":1,\"ab\":\"drop table\"}")?.ab, "")
        XCTAssertEqual(ConfigParser.parse("{\"v\":1}")?.enabled, false, "off unless the platform says on")
    }

    func testBackoffDoublesUpToItsCeiling() {
        let r = Retry(maxAttempts: 6, baseSec: 2, maxSec: 64)
        XCTAssertEqual((1...7).map { backoffMs($0, r) }, [2000, 4000, 8000, 16000, 32000, 64000, 64000])
    }

    func testTheHashIsThePlatformsOwn() {
        // the same test vectors as the platform's va_sdk_hash (tests/slice6.php) and the Android SDK's tests
        XCTAssertEqual(fnv1a(""), 0x811c9dc5)
        XCTAssertEqual(fnv1a("a"), 0xe40c292c)
        XCTAssertEqual(fnv1a("foobar"), 0xbf9cf968)
    }
}
