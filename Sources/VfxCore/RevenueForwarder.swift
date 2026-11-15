import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

/// Which attribution tools get each impression's revenue (PROTOCOL.md, "mmp"); both off unless the platform says so.
public struct Mmp: Equatable {
    public var appsflyer: Bool
    public var adjust: Bool
    public init(appsflyer: Bool = false, adjust: Bool = false) { self.appsflyer = appsflyer; self.adjust = adjust }
    public var any: Bool { appsflyer || adjust }
}

#if canImport(ObjectiveC)
// The few messages sent to AppsFlyer and Adjust, by the Objective-C names their headers declare. The SDK links neither:
// each class is found by name when the app has it, and told it answers these (class_addProtocol), so the calls are
// ordinary Objective-C messages with ARC's usual ownership.
@objc private protocol VfxAFRevenueData {
    @objc(initWithMonetizationNetwork:mediationNetwork:currencyIso4217Code:eventRevenue:)
    init(monetizationNetwork: String, mediationNetwork: UInt, currencyIso4217Code: String, eventRevenue: NSNumber)
}
@objc private protocol VfxAFLib {
    @objc(shared) static func vfxShared() -> AnyObject
    @objc(logAdRevenue:additionalParameters:) func vfxLogAdRevenue(_ data: AnyObject, additionalParameters: [String: Any]?)
}
@objc private protocol VfxADJAdRevenue {
    @objc(initWithSource:) init?(source: String)
    @objc(setRevenue:currency:) func vfxSetRevenue(_ amount: Double, currency: String)
    @objc(setAdRevenueUnit:) optional func vfxSetAdRevenueUnit(_ unit: String)
    @objc(setAdRevenuePlacement:) optional func vfxSetAdRevenuePlacement(_ placement: String)
}
@objc private protocol VfxADJ {
    @objc(trackAdRevenue:) static func vfxTrackAdRevenue(_ adRevenue: AnyObject)
}
#endif

/// Sends Google's paid event (what one impression earned) to the attribution tool the app already runs: AppsFlyer
/// (6.15 or newer: `logAdRevenue`) and/or Adjust (`trackAdRevenue`, source `admob_sdk`). Whether to is the platform's
/// setting; this only carries it out. A tool switched on but not in the app is said once in the log, never thrown.
public final class RevenueForwarder {
    /// AppsFlyer's `AppsFlyerAdRevenueMediationNetworkTypeGoogleAdMob` (its header: 1).
    static let appsFlyerGoogleAdMob: UInt = 1
    private let find: (String) -> AnyClass?
    private var said = Set<String>()

    public init(find: @escaping (String) -> AnyClass? = { NSClassFromString($0) }) { self.find = find }

    /// The tools the revenue reached (empty when none was on, or none is in the app).
    @discardableResult
    public func forward(_ mmp: Mmp, placement: String, format: VfxFormat, unit: String, micros: Int64, currency: String, source: String?) -> [String] {
        guard mmp.any, micros > 0, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { return [] }
        let value = Double(micros) / 1_000_000
        var out: [String] = []
        if mmp.appsflyer, note("AppsFlyer", "AppsFlyer 6.15 or newer", appsFlyer(placement, format, unit, value, currency, source)) { out.append("AppsFlyer") }
        if mmp.adjust, note("Adjust", "Adjust", adjust(placement, unit, value, currency)) { out.append("Adjust") }
        return out
    }

    private func note(_ name: String, _ what: String, _ ok: Bool) -> Bool {
        if ok { if said.insert("\(name)-ok").inserted { VLog.i("Ad revenue goes to \(name) too") } }
        else if said.insert("\(name)-missing").inserted { VLog.w("The platform sends ad revenue to \(name), but \(what) is not in the app: nothing is sent to it.") }
        return ok
    }

    /// The network that served the ad, as AppsFlyer names networks: Google's own is "googleadmob"; a partner, its name in lower case.
    public static func monetizationNetwork(_ source: String?) -> String {
        let s = (source ?? "").trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.range(of: "google|admob|ad ?manager|ad ?exchange", options: [.regularExpression, .caseInsensitive]) != nil { return "googleadmob" }
        let n = String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
        return n.isEmpty ? "googleadmob" : String(n.prefix(40))
    }

    #if canImport(ObjectiveC)
    /// The class by that name, told it answers `proto`, when it has every required selector (instance and class ones).
    private func adopt(_ name: String, _ proto: Protocol, instance: [String], classMethods: [String] = []) -> AnyClass? {
        guard let cls = find(name), let meta = object_getClass(cls) else { return nil }
        for s in instance where !class_respondsToSelector(cls, NSSelectorFromString(s)) { return nil }
        for s in classMethods where !class_respondsToSelector(meta, NSSelectorFromString(s)) { return nil }
        if !class_conformsToProtocol(cls, proto) { class_addProtocol(cls, proto) }
        return cls
    }

    private func appsFlyer(_ placement: String, _ format: VfxFormat, _ unit: String, _ value: Double, _ currency: String, _ source: String?) -> Bool {
        guard let dataCls = adopt("AFAdRevenueData", VfxAFRevenueData.self, instance: ["initWithMonetizationNetwork:mediationNetwork:currencyIso4217Code:eventRevenue:"]),
              let libCls = adopt("AppsFlyerLib", VfxAFLib.self, instance: ["logAdRevenue:additionalParameters:"], classMethods: ["shared"]),
              let dataType = dataCls as? VfxAFRevenueData.Type, let libType = libCls as? VfxAFLib.Type else { return false }
        let data = dataType.init(monetizationNetwork: RevenueForwarder.monetizationNetwork(source), mediationNetwork: RevenueForwarder.appsFlyerGoogleAdMob,
                                 currencyIso4217Code: currency, eventRevenue: NSNumber(value: value))
        guard let lib = libType.vfxShared() as? VfxAFLib else { return false }
        lib.vfxLogAdRevenue(data, additionalParameters: ["ad_unit": unit, "ad_type": format.wire, "placement": placement])
        return true
    }

    private func adjust(_ placement: String, _ unit: String, _ value: Double, _ currency: String) -> Bool {
        guard let revCls = adopt("ADJAdRevenue", VfxADJAdRevenue.self, instance: ["initWithSource:", "setRevenue:currency:"]),
              let adjCls = adopt("Adjust", VfxADJ.self, instance: [], classMethods: ["trackAdRevenue:"]),
              let revType = revCls as? VfxADJAdRevenue.Type, let adjType = adjCls as? VfxADJ.Type,
              let rev = revType.init(source: "admob_sdk") else { return false }
        rev.vfxSetRevenue(value, currency: currency)
        rev.vfxSetAdRevenueUnit?(unit)
        rev.vfxSetAdRevenuePlacement?(placement)
        adjType.vfxTrackAdRevenue(rev)
        return true
    }
    #else
    private func appsFlyer(_ placement: String, _ format: VfxFormat, _ unit: String, _ value: Double, _ currency: String, _ source: String?) -> Bool { false }
    private func adjust(_ placement: String, _ unit: String, _ value: Double, _ currency: String) -> Bool { false }
    #endif
}
