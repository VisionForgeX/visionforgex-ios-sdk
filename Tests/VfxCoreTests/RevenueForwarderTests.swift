import XCTest
@testable import VfxCore

// Stand-ins with the Objective-C names and selectors of AppsFlyer's and Adjust's classes, as their headers declare them.
@objc(AFAdRevenueData) final class FakeAFAdRevenueData: NSObject {
    let monetizationNetwork: String, mediationNetwork: UInt, currency: String, revenue: NSNumber
    @objc(initWithMonetizationNetwork:mediationNetwork:currencyIso4217Code:eventRevenue:)
    init(monetizationNetwork: String, mediationNetwork: UInt, currencyIso4217Code: String, eventRevenue: NSNumber) {
        self.monetizationNetwork = monetizationNetwork; self.mediationNetwork = mediationNetwork; self.currency = currencyIso4217Code; self.revenue = eventRevenue
        super.init()
    }
}
@objc(AppsFlyerLib) final class FakeAppsFlyerLib: NSObject {
    static let instance = FakeAppsFlyerLib()
    var logged: [(FakeAFAdRevenueData, [String: Any]?)] = []
    @objc static func shared() -> FakeAppsFlyerLib { instance }
    @objc(logAdRevenue:additionalParameters:) func logAdRevenue(_ data: FakeAFAdRevenueData, additionalParameters: [String: Any]?) { logged.append((data, additionalParameters)) }
}
@objc(ADJAdRevenue) final class FakeADJAdRevenue: NSObject {
    let source: String
    var amount = 0.0, currency = "", unit = "", placement = ""
    @objc(initWithSource:) init?(source: String) { self.source = source; super.init() }
    @objc(setRevenue:currency:) func setRevenue(_ amount: Double, currency: String) { self.amount = amount; self.currency = currency }
    @objc(setAdRevenueUnit:) func setAdRevenueUnit(_ unit: String) { self.unit = unit }
    @objc(setAdRevenuePlacement:) func setAdRevenuePlacement(_ placement: String) { self.placement = placement }
}
@objc(Adjust) final class FakeAdjust: NSObject {
    static var tracked: [FakeADJAdRevenue] = []
    @objc(trackAdRevenue:) static func trackAdRevenue(_ r: FakeADJAdRevenue) { tracked.append(r) }
}

final class RevenueForwarderTests: XCTestCase {
    override func setUp() { FakeAppsFlyerLib.instance.logged.removeAll(); FakeAdjust.tracked.removeAll() }

    func testNothingUnlessThePlatformSaysSo() {
        XCTAssertEqual(RevenueForwarder().forward(Mmp(), placement: "home", format: .banner, unit: "/1/u", micros: 4210, currency: "USD", source: nil), [])
        XCTAssertTrue(FakeAppsFlyerLib.instance.logged.isEmpty && FakeAdjust.tracked.isEmpty)
        XCTAssertEqual(ConfigParser.parse("{\"v\":1}")?.mmp, Mmp())
        XCTAssertEqual(ConfigParser.parse("{\"v\":1,\"mmp\":{\"adjust\":true}}")?.mmp, Mmp(appsflyer: false, adjust: true))
    }

    func testAppsFlyerGetsEachImpressionAsGoogleAdMobMediation() throws {
        let sent = RevenueForwarder().forward(Mmp(appsflyer: true), placement: "level_complete", format: .interstitial, unit: "/1,2/u-int", micros: 4210, currency: "USD", source: "AppLovin")
        XCTAssertEqual(sent, ["AppsFlyer"])
        let (d, extra) = try XCTUnwrap(FakeAppsFlyerLib.instance.logged.first)
        XCTAssertEqual(d.monetizationNetwork, "applovin"); XCTAssertEqual(d.mediationNetwork, 1); XCTAssertEqual(d.currency, "USD")
        XCTAssertEqual(d.revenue.doubleValue, 0.00421, accuracy: 1e-12)
        XCTAssertEqual(extra?["ad_unit"] as? String, "/1,2/u-int"); XCTAssertEqual(extra?["ad_type"] as? String, "interstitial"); XCTAssertEqual(extra?["placement"] as? String, "level_complete")
    }

    func testAdjustGetsItAsAdMobRevenue() throws {
        XCTAssertEqual(RevenueForwarder().forward(Mmp(adjust: true), placement: "home", format: .banner, unit: "/1/u-ban", micros: 900, currency: "EUR", source: nil), ["Adjust"])
        let r = try XCTUnwrap(FakeAdjust.tracked.first)
        XCTAssertEqual(r.source, "admob_sdk"); XCTAssertEqual(r.amount, 0.0009, accuracy: 1e-12); XCTAssertEqual(r.currency, "EUR"); XCTAssertEqual(r.unit, "/1/u-ban"); XCTAssertEqual(r.placement, "home")
    }

    func testNeverAWorthlessOrUnreadableOne_andAMissingToolIsLeftAlone() {
        let f = RevenueForwarder()
        XCTAssertEqual(f.forward(Mmp(appsflyer: true, adjust: true), placement: "home", format: .banner, unit: "/1/u", micros: 0, currency: "USD", source: nil), [])
        XCTAssertEqual(f.forward(Mmp(appsflyer: true, adjust: true), placement: "home", format: .banner, unit: "/1/u", micros: 5, currency: "usd", source: nil), [])
        XCTAssertEqual(RevenueForwarder(find: { _ in nil }).forward(Mmp(appsflyer: true, adjust: true), placement: "home", format: .banner, unit: "/1/u", micros: 4210, currency: "USD", source: nil), [])
        // a class of that name without the method: skipped, the other still sent
        let odd = RevenueForwarder(find: { $0 == "AppsFlyerLib" ? NSObject.self : NSClassFromString($0) })
        XCTAssertEqual(odd.forward(Mmp(appsflyer: true, adjust: true), placement: "home", format: .banner, unit: "/1/u", micros: 4210, currency: "USD", source: nil), ["Adjust"])
        XCTAssertTrue(FakeAppsFlyerLib.instance.logged.isEmpty)
    }

    func testNetworkNames() {
        XCTAssertEqual(RevenueForwarder.monetizationNetwork(nil), "googleadmob")
        XCTAssertEqual(RevenueForwarder.monetizationNetwork("Google AdMob Network"), "googleadmob")
        XCTAssertEqual(RevenueForwarder.monetizationNetwork("Unity Ads"), "unityads")
    }
}
