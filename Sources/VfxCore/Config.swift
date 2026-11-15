import Foundation

/// Full-screen pacing (PROTOCOL.md: cap).
public struct Cap: Equatable {
    public var minIntervalSec = 0, maxPerSession = 0, maxPerHour = 0, maxPerDay = 0, graceSec = 0, graceSessions = 0, everyNth = 1
    public init() {}
}

public struct Retry: Equatable {
    public var maxAttempts = 6, baseSec = 2, maxSec = 64
    public init(maxAttempts: Int = 6, baseSec: Int = 2, maxSec: Int = 64) { self.maxAttempts = maxAttempts; self.baseSec = baseSec; self.maxSec = maxSec }
}

public struct Floors: Equatable {
    public var key = "vfx_fl"
    public var tiers: [String] = []
    public var timeoutMs: Int64 = 2500
    public init(key: String = "vfx_fl", tiers: [String] = [], timeoutMs: Int64 = 2500) { self.key = key; self.tiers = tiers; self.timeoutMs = timeoutMs }
}

public struct Placement {
    public var name: String
    public var format: VfxFormat
    public var on: Bool
    public var unit: String
    public var preload: Bool
    public var expiryMin: Int
    public var refreshSec: Int
    public var cap: Cap
    public var retry: Retry
    public var floors: Floors
    public var collapsible: String
    public var template: String
    public var autoShow: Bool
    /// The stored imp to ask a Prebid Server for bids with before Google is asked; empty: not bid for (PROTOCOL.md, "prebid").
    public var prebidImp: String = ""
}

/// Where and how to ask for bids (PROTOCOL.md, "prebid"); absent unless the platform turned it on for this app.
public struct PrebidSettings: Equatable {
    public var url: String, request: String
    public var timeoutMs: Int64
    public var breakerFailures: Int, breakerPauseSec: Int
    public init(url: String, request: String, timeoutMs: Int64, breakerFailures: Int, breakerPauseSec: Int) {
        self.url = url; self.request = request; self.timeoutMs = timeoutMs; self.breakerFailures = breakerFailures; self.breakerPauseSec = breakerPauseSec
    }
}

/// The settings from the platform (PROTOCOL.md section 1), checked and kept within safe bounds.
public struct Config {
    public var ttlSec: Int
    public var enabled: Bool
    public var test: Bool
    public var reason: String
    public var fullGapSec: Int
    public var sessionTimeoutSec: Int
    public var log: String
    public var ump: Bool
    public var child: Bool
    public var underAge: Bool
    public var rating: String
    public var eventsOn: Bool
    public var eventsUrl: String
    public var sample: Double
    public var batch: Int
    public var flushSec: Int
    public var kv: [String: String]
    public var ab: String
    public var placements: [String: Placement]
    public var prebid: PrebidSettings? = nil
    /// Attribution tools each impression's revenue also goes to (PROTOCOL.md, "mmp"); none unless the platform says so.
    public var mmp: Mmp = Mmp()
}

private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
private func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

private extension Dictionary where Key == String, Value == Any {
    func int(_ k: String, _ d: Int) -> Int { (self[k] as? NSNumber)?.intValue ?? d }
    func int64(_ k: String, _ d: Int64) -> Int64 { (self[k] as? NSNumber)?.int64Value ?? d }
    func bool(_ k: String, _ d: Bool) -> Bool { (self[k] as? NSNumber)?.boolValue ?? d }
    func double(_ k: String, _ d: Double) -> Double { (self[k] as? NSNumber)?.doubleValue ?? d }
    func str(_ k: String, _ d: String = "") -> String { (self[k] as? String) ?? d }
    func obj(_ k: String) -> [String: Any] { (self[k] as? [String: Any]) ?? [:] }
}

public enum ConfigParser {
    /// The settings, or nil when the text is not settings this SDK understands.
    public static func parse(_ text: String) -> Config? {
        guard let data = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o.int("v", 0) == 1 else { return nil }
        let app = o.obj("app"), global = o.obj("global"), consent = o.obj("consent"), events = o.obj("events")
        var kv: [String: String] = [:]
        for (k, v) in o.obj("kv") where matches(k, "^[a-z0-9_]{1,20}$") { kv[k] = String(((v as? String) ?? "\(v)").prefix(40)) }
        var pls: [String: Placement] = [:]
        for (name, any) in o.obj("placements") {
            guard let p = any as? [String: Any], let f = VfxFormat.fromWire(p.str("format")), matches(name, "^[a-z0-9_]{1,40}$") else { continue }
            pls[name] = placement(name, f, p)
        }
        let url = events.str("url")
        let rating = consent.str("rating")
        let ab = o.str("ab")
        let sample = events.double("sample", 1.0)
        return Config(
            ttlSec: clamp(o.int("ttl", 3600), 60, 86400),
            enabled: app.bool("enabled", false),
            test: app.bool("test", false),
            reason: app.str("reason"),
            fullGapSec: clamp(global.int("fullGapSec", 30), 0, 3600),
            sessionTimeoutSec: clamp(global.int("sessionTimeoutSec", 1800), 30, 86400),
            log: global.str("log", "warn"),
            ump: consent.bool("ump", true),
            child: consent.bool("child", false),
            underAge: consent.bool("underAge", false),
            rating: ["G", "PG", "T", "MA"].contains(rating) ? rating : "",
            eventsOn: events.bool("on", false) && (url.hasPrefix("https://") || url.hasPrefix("http://")),
            eventsUrl: url,
            sample: sample.isNaN ? 1.0 : min(max(sample, 0), 1),
            batch: clamp(events.int("batch", 20), 1, 500),
            flushSec: clamp(events.int("flushSec", 30), 5, 3600),
            kv: kv,
            ab: matches(ab, "^e[0-9]{1,4}:[ab]$") ? ab : "",
            placements: pls,
            prebid: prebid(o["prebid"] as? [String: Any]),
            mmp: Mmp(appsflyer: o.obj("mmp").bool("appsflyer", false), adjust: o.obj("mmp").bool("adjust", false)))
    }

    private static let storedId = "^[A-Za-z0-9_.-]{1,80}\\z"
    /// The Prebid block, or nil when it is absent or not usable (no address, no stored request): then nothing is bid for.
    private static func prebid(_ b: [String: Any]?) -> PrebidSettings? {
        guard let b = b else { return nil }
        let url = b.str("url"), request = b.str("request")
        guard url.hasPrefix("https://") || url.hasPrefix("http://"), matches(request, storedId) else { return nil }
        let br = b.obj("breaker")
        return PrebidSettings(url: url, request: request, timeoutMs: Int64(clamp(Int(b.int64("timeoutMs", 800)), 100, 3000)),
                              breakerFailures: clamp(br.int("failures", 3), 1, 20), breakerPauseSec: clamp(br.int("pauseSec", 600), 30, 3600))
    }

    private static func placement(_ name: String, _ f: VfxFormat, _ p: [String: Any]) -> Placement {
        let c = p.obj("cap"), r = p.obj("retry"), fl = p.obj("floors")
        var tiers: [String] = []
        for t in ((fl["tiers"] as? [Any]) ?? []).prefix(5) {
            let s = (t as? String) ?? "\(t)"
            if matches(s, "^[0-9a-z_]{1,10}$") { tiers.append(s) }
        }
        var refresh = 0
        if f == .banner { let v = p.int("refreshSec", 0); refresh = v <= 0 ? 0 : clamp(v, 30, 3600) }   // never faster than Google allows
        let maxExpiry = f == .appOpen ? 239 : 59
        var cap = Cap()
        cap.minIntervalSec = clamp(c.int("minIntervalSec", 0), 0, 86400)
        cap.maxPerSession = clamp(c.int("maxPerSession", 0), 0, 1000)
        cap.maxPerHour = clamp(c.int("maxPerHour", 0), 0, 1000)
        cap.maxPerDay = clamp(c.int("maxPerDay", 0), 0, 10000)
        cap.graceSec = clamp(c.int("graceSec", 0), 0, 3600)
        cap.graceSessions = clamp(c.int("graceSessions", 0), 0, 100)
        cap.everyNth = clamp(c.int("everyNth", 1), 1, 100)
        let key = fl.str("key", "vfx_fl")
        let col = p.str("collapsible")
        return Placement(
            name: name, format: f, on: p.bool("on", false), unit: p.str("unit"),
            preload: p.bool("preload", f != .banner),
            expiryMin: clamp(p.int("expiryMin", maxExpiry), 1, maxExpiry),
            refreshSec: refresh, cap: cap,
            retry: Retry(maxAttempts: clamp(r.int("maxAttempts", 6), 0, 20), baseSec: clamp(r.int("baseSec", 2), 1, 60), maxSec: clamp(r.int("maxSec", 64), 1, 3600)),
            floors: Floors(key: key.trimmingCharacters(in: .whitespaces).isEmpty ? "vfx_fl" : key, tiers: tiers, timeoutMs: Int64(clamp(Int(fl.int64("timeoutMs", 2500)), 500, 10000))),
            collapsible: (col == "top" || col == "bottom") ? col : "",
            template: p.str("template") == "small" ? "small" : "medium",
            autoShow: f == .appOpen && p.bool("autoShow", false),
            prebidImp: (f == .banner || f == .interstitial) && matches(p.obj("prebid").str("imp"), storedId) ? p.obj("prebid").str("imp") : "")
    }
}

/// The wait before retry number `attempt` (1 = the first retry), in milliseconds.
public func backoffMs(_ attempt: Int, _ r: Retry) -> Int64 {
    let shift = min(max(attempt - 1, 0), 20)
    let exp = Int64(r.baseSec) << Int64(shift)
    return min(Int64(r.maxSec), exp) * 1000
}

/// FNV-1a, 32 bits: the same as the platform's va_sdk_hash.
public func fnv1a(_ s: String) -> UInt32 {
    var h: UInt32 = 0x811c9dc5
    for b in s.utf8 { h ^= UInt32(b); h = h &* 0x01000193 }
    return h
}
