import Foundation

/// Header bidding through a Prebid Server (PROTOCOL.md, "prebid"). The SDK decides nothing here: where to ask, with which stored
/// request and imp, how long to wait and when to stop asking after failures all come from the settings. What it does by itself is
/// what the law and plain safety need: it never asks without the consent signals the app already holds, and a failing server
/// costs an app at most a few waits (the breaker).
///
/// What goes out: the stored ids, the device's kind, system, language and screen, the consent strings Google's consent form
/// left in the app's preferences (IAB TCF, US Privacy, GPP), and a random ID for the auction. No advertising ID, no location.
/// What comes back that is used: the winning bid's targeting keys (hb_pb, hb_bidder, hb_cache_id …), added to the Google request.
public enum Prebid {
    /// The consent signals the app holds in its preferences (the IAB's standard keys, written by Google's consent form).
    public struct Signals {
        public var gdprApplies: Bool?
        public var tcString: String, usPrivacy: String, gpp: String, gppSid: String
        public init(gdprApplies: Bool?, tcString: String, usPrivacy: String, gpp: String, gppSid: String) {
            self.gdprApplies = gdprApplies; self.tcString = tcString; self.usPrivacy = usPrivacy; self.gpp = gpp; self.gppSid = gppSid
        }
    }

    /// What the device says about itself.
    public struct Device {
        public var os: String, osv: String, make: String, model: String
        public var tablet: Bool
        public var language: String
        public var w: Int, h: Int
        public var pxratio: Double
        public var ua: String
        public init(os: String, osv: String, make: String, model: String, tablet: Bool, language: String, w: Int, h: Int, pxratio: Double, ua: String) {
            self.os = os; self.osv = osv; self.make = make; self.model = model; self.tablet = tablet; self.language = language; self.w = w; self.h = h; self.pxratio = pxratio; self.ua = ua
        }
    }

    /// The outcome of one auction. `result`: bid, nobid, timeout, error, skip.
    public struct Outcome {
        public var result: String
        public var keys: [String: String]
        public var valueMicros: Int64
        public var ms: Int64
        public init(_ result: String, _ keys: [String: String] = [:], _ valueMicros: Int64 = 0, _ ms: Int64 = 0) {
            self.result = result; self.keys = keys; self.valueMicros = valueMicros; self.ms = ms
        }
        public static func skip() -> Outcome { Outcome("skip") }
    }

    /// Why not to ask at all, or nil. GDPR applies and no consent string is held: the signal Prebid Server needs is missing.
    public static func mustSkip(_ s: Signals) -> String? {
        s.gdprApplies == true && s.tcString.trimmingCharacters(in: .whitespaces).isEmpty ? "consent" : nil
    }

    public static func request(_ settings: PrebidSettings, imp: String, appVersion: String, sdkVersion: String, device d: Device, signals s: Signals, auctionId: String = UUID().uuidString) -> String {
        let device: [String: Any] = ["os": d.os, "osv": d.osv, "make": d.make, "model": d.model, "devicetype": d.tablet ? 5 : 4,
                                     "language": d.language, "w": d.w, "h": d.h, "pxratio": d.pxratio, "ua": d.ua]
        var regsExt: [String: Any] = [:]
        if let g = s.gdprApplies { regsExt["gdpr"] = g ? 1 : 0 }
        if !s.usPrivacy.isEmpty { regsExt["us_privacy"] = s.usPrivacy }
        var regs: [String: Any] = ["ext": regsExt]
        if !s.gpp.isEmpty { regs["gpp"] = s.gpp; if let ids = gppSids(s.gppSid) { regs["gpp_sid"] = ids } }
        let impObj: [String: Any] = ["id": "1", "displaymanager": "VisionForgeX", "displaymanagerver": sdkVersion,
                                     "ext": ["prebid": ["storedrequest": ["id": imp]]]]
        var body: [String: Any] = ["id": auctionId, "imp": [impObj], "app": ["ver": appVersion], "device": device, "regs": regs,
                                   "ext": ["prebid": ["storedrequest": ["id": settings.request]]]]
        if !s.tcString.isEmpty { body["user"] = ["ext": ["consent": s.tcString]] }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func gppSids(_ text: String) -> [Int]? {
        let ids = text.split(whereSeparator: { $0 == "," || $0 == "_" }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return ids.isEmpty ? nil : ids
    }

    private static func fits(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    /// The result of an answer: HTTP 204 or no winner is "nobid"; anything that is not a Prebid Server answer is "error".
    public static func response(code: Int, body: String, ms: Int64) -> Outcome {
        if code == 204 { return Outcome("nobid", [:], 0, ms) }
        if code != 200 { return Outcome("error", [:], 0, ms) }
        guard let data = body.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Outcome("error", [:], 0, ms) }
        guard let seats = o["seatbid"] as? [Any] else { return Outcome("nobid", [:], 0, ms) }
        for seat in seats {
            guard let bids = (seat as? [String: Any])?["bid"] as? [Any] else { continue }
            for any in bids {
                guard let b = any as? [String: Any],
                      let t = (((b["ext"] as? [String: Any])?["prebid"] as? [String: Any])?["targeting"]) as? [String: Any] else { continue }   // only the winner carries the keys
                var keys: [String: String] = [:]
                for (k, v) in t where fits(k, "^hb_[a-z0-9_]{1,30}\\z") {
                    if let s = v as? String, fits(s, "^[A-Za-z0-9._:/=+-]{1,100}\\z") { keys[k] = s }
                }
                if keys["hb_pb"] == nil { continue }   // without a price bucket no line item can match: not a usable bid
                let price = min(max((b["price"] as? NSNumber)?.doubleValue ?? 0, 0), 100)
                return Outcome("bid", keys, Int64(price * 1_000_000), ms)
            }
        }
        return Outcome("nobid", [:], 0, ms)
    }

    /// After `failures` failures in a row (a timeout or an error) the server is left alone for `pauseSec`; any answer ends the run.
    public final class Breaker {
        private var run = 0
        private var pausedUntil: Int64 = 0
        public init() {}
        public func isOpen(_ now: Int64) -> Bool { now < pausedUntil }
        public func record(_ r: Outcome, _ now: Int64, _ settings: PrebidSettings) {
            if r.result == "timeout" || r.result == "error" {
                run += 1
                if run >= settings.breakerFailures { pausedUntil = now + Int64(settings.breakerPauseSec) * 1000; run = 0 }
            } else if r.result != "skip" { run = 0 }
        }
    }
}

/// One auction at a time per call, on the main thread: `run` answers exactly once, with the winning bid's targeting keys or with
/// nothing, and never later than the settings' wait (plus a short grace). Everything it needs from the SDK is passed in, so it
/// is tested with a clock that moves only when the test says.
public final class PrebidRunner {
    private let post: (Int64, @escaping () -> Void) -> AnyObject
    private let cancel: (AnyObject) -> Void
    private let now: () -> Int64
    private let io: (@escaping () -> Void) -> Void
    private let send: (_ url: String, _ body: String, _ timeoutMs: Int) -> HttpResult
    private let device: () -> Prebid.Device
    private let signals: () -> Prebid.Signals
    private let appVersion: () -> String
    private let sdkVersion: String
    private let event: (Placement, Prebid.Outcome, String) -> Void
    public let breaker = Prebid.Breaker()

    public init(post: @escaping (Int64, @escaping () -> Void) -> AnyObject, cancel: @escaping (AnyObject) -> Void, now: @escaping () -> Int64,
                io: @escaping (@escaping () -> Void) -> Void, send: @escaping (String, String, Int) -> HttpResult,
                device: @escaping () -> Prebid.Device, signals: @escaping () -> Prebid.Signals, appVersion: @escaping () -> String,
                sdkVersion: String, event: @escaping (Placement, Prebid.Outcome, String) -> Void) {
        self.post = post; self.cancel = cancel; self.now = now; self.io = io; self.send = send; self.device = device
        self.signals = signals; self.appVersion = appVersion; self.sdkVersion = sdkVersion; self.event = event
    }

    public func run(_ cfg: Config, _ p: Placement, _ done: @escaping ([String: String]) -> Void) {
        // not bid for: not an event, nothing changes. (The platform never sends the block for these apps; this is a second lock.)
        guard let s = cfg.prebid, !p.prebidImp.isEmpty, !cfg.test, !cfg.child, !cfg.underAge else { done([:]); return }
        let sig = signals()
        let why = Prebid.mustSkip(sig) ?? (breaker.isOpen(now()) ? "breaker" : nil)
        if let why = why { event(p, .skip(), why); done([:]); return }
        let started = now()
        var answered = false
        let body = Prebid.request(s, imp: p.prebidImp, appVersion: appVersion(), sdkVersion: sdkVersion, device: device(), signals: sig)
        func finish(_ r: Prebid.Outcome) {
            breaker.record(r, now(), s)
            event(p, r, "")
            done(r.result == "bid" ? r.keys : [:])
        }
        let timer = post(s.timeoutMs + 100) {
            if answered { return }
            answered = true
            finish(Prebid.Outcome("timeout", [:], 0, self.now() - started))
        }
        io { [self] in
            let r = self.send(s.url, body, Int(s.timeoutMs))
            _ = self.post(0) {
                if answered { return }   // too late: the app was already told "no bids"
                answered = true
                self.cancel(timer)
                let ms = self.now() - started
                finish(r.code == 0 ? Prebid.Outcome(ms >= s.timeoutMs - 50 ? "timeout" : "error", [:], 0, ms) : Prebid.response(code: r.code, body: r.body, ms: ms))
            }
        }
    }
}
