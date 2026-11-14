import UIKit
#if canImport(VfxCore)
import VfxCore
#endif

/// The SDK's state, on the main thread: the settings (cached, refreshed when the app comes back after their
/// time is up), consent, the session, the slots, the events.
final class Sdk: SlotEnv {
    let key: String
    let options: VfxOptions
    let adEngine: AdEngine
    var engine: FullScreenEngine { adEngine }
    let store: KeyValueStore
    let pacer: Pacer
    private let clock: () -> Int64
    private let io: DispatchQueue
    private(set) var slots: [String: FullScreenSlot] = [:]
    let events: EventLog
    let installId: String
    private(set) var sessionId = ""
    private(set) var sessionNumber = 0
    private var cfg: Config?
    private(set) var configFrom = "none"
    private(set) var configAt: Int64 = 0
    private var engineStarted = false
    private var engineReady = false
    private var consentDone = false
    private var consentAsked = false
    private(set) var consentError: String?
    private var active = false
    private var backgroundAt: Int64 = 0
    private var listeners: [(VfxStatus) -> Void] = []
    private var readyAnnounced = false
    private var flushToken: AnyObject?
    private var skipNextAppOpen = false
    private let coldStartAt: Int64
    private var appKv: [String: String] = [:]
    private var sesSent = false
    private var fetching = false
    var fullScreenShowing = false
    var eventListener: ((VfxEvent) -> Void)?
    var revenueListener: ((VfxRevenue) -> Void)?

    static let kInstall = "vfx.install", kConfig = "vfx.config", kEtag = "vfx.config.etag", kAt = "vfx.config.at", kSessions = "vfx.sessions"

    init(key: String, options: VfxOptions, engine: AdEngine, store: KeyValueStore = DefaultsStore(), clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.key = key; self.options = options; self.adEngine = engine; self.store = store; self.clock = clock
        self.coldStartAt = clock()
        let q = DispatchQueue(label: "com.visionforgex.io", qos: .utility)
        self.io = q
        self.pacer = Pacer(store: store, clock: clock)
        VLog.level = options.logLevel ?? .warn
        Http.userAgent = "VisionForgeX-iOS/\(vfxVersion) (iOS \(UIDevice.current.systemVersion); \(Bundle.main.bundleIdentifier ?? ""))"
        if let id = store.getString(Sdk.kInstall) { installId = id } else { let id = UUID().uuidString; store.putString(Sdk.kInstall, id); installId = id }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("visionforgex")
        events = EventLog(dir: dir, clock: clock, io: { block in q.async(execute: block) })
        events.inSample = true
        if options.settingsForTesting == nil, let text = store.getString(Sdk.kConfig), let c = ConfigParser.parse(text) {
            cfg = c; configFrom = "cache"; configAt = store.getLong(Sdk.kAt, 0)
        }
        if let c = cfg { applyLog(c) }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func addListener(_ l: ((VfxStatus) -> Void)?) {
        guard let l = l else { return }
        if readyAnnounced { l(status()) } else { listeners.append(l) }
    }

    // MARK: the settings

    func fetchConfig(_ reason: String) {
        if fetching || options.settingsForTesting != nil { return }
        fetching = true
        let info = Bundle.main.infoDictionary
        let av = (info?["CFBundleShortVersionString"] as? String) ?? ""
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let url = options.baseUrl + "/sdk/v1/config.php?k=" + enc(key) + "&i=" + enc(installId) + "&sv=" + enc(vfxVersion) + "&p=ios&b=" + enc(bundle) + "&av=" + enc(av)
        let etag = cfg != nil ? store.getString(Sdk.kEtag) : nil
        VLog.d("Settings: asking (\(reason))")
        io.async { [weak self] in
            let r = Http.get(url, etag: etag)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fetching = false
                switch r.code {
                case 304:
                    self.configAt = self.clock(); self.store.putLong(Sdk.kAt, self.configAt); self.configFrom = "platform (unchanged)"
                case 200:
                    if let c = ConfigParser.parse(r.body) {
                        self.store.putString(Sdk.kConfig, r.body); self.store.putString(Sdk.kEtag, r.etag)
                        self.configAt = self.clock(); self.store.putLong(Sdk.kAt, self.configAt)
                        self.setConfig(c, "platform")
                    } else { VLog.w("Settings: not understood (is the SDK out of date?)") }
                case 404:
                    VLog.e("Settings: the platform does not know the key \"\(self.key)\" (VisionForgeX SDK panel on the app's page).")
                default:
                    VLog.w("Settings: the platform could not be reached (\(r.code)); \(self.cfg != nil ? "using the last ones" : "no ads until it can").")
                }
                self.proceed()
            }
        }
    }

    private func setConfig(_ c: Config, _ from: String) {
        let old = cfg
        cfg = c; configFrom = from
        applyLog(c)
        events.inSample = Double(fnv1a(installId) % 10000) < c.sample * 10000
        // a placement whose unit or floors changed starts again
        for (n, s) in slots {
            let a = old?.placements[n], b = c.placements[n]
            if a == nil || b == nil || a!.unit != b!.unit || a!.floors != b!.floors || !b!.on { s.reset() }
        }
        if engineStarted { adEngine.apply(settings: engineSettings(c)) }
        if !sessionId.isEmpty && !sesSent { sendSession() }   // the first settings of an install arrive after its session began
        scheduleFlush()
    }

    private func applyLog(_ c: Config) {
        if options.logLevel != nil { return }
        switch c.log { case "debug": VLog.level = .debug; case "info": VLog.level = .info; case "error": VLog.level = .error; case "none": VLog.level = .none; default: VLog.level = .warn }
    }

    private func engineSettings(_ c: Config?) -> EngineSettings {
        EngineSettings(childDirected: c?.child ?? false, underAge: c?.underAge ?? false, maxRating: c?.rating ?? "", testDeviceIds: options.testDeviceIds)
    }

    /// After settings (or none): start the engine, ask for consent, preload, tell the app.
    private func proceed() {
        guard let c = cfg else { announce(); return }
        if !c.enabled { VLog.w("Ads are off for this app on the platform: \(c.reason)"); announce(); return }
        if !consentDone { askConsent(); if !consentDone { return } }
        if !engineStarted {
            engineStarted = true
            adEngine.initialize(settings: engineSettings(c)) { [weak self] in
                DispatchQueue.main.async { guard let self = self else { return }; self.engineReady = true; VLog.i("Engine \(self.adEngine.name) ready"); self.afterReady() }
            }
            return
        }
        if engineReady { afterReady() }
    }

    private func afterReady() { announce(); if options.autoPreload { preloadAll() } }

    func preloadAll() {
        guard let c = cfg else { return }
        for (n, p) in c.placements where p.on && p.preload && p.format.isFullScreen { slot(n).load() }
    }

    private func askConsent() {
        guard let c = cfg else { return }
        if !c.ump { consentDone = true; return }
        if consentAsked || !active { return }   // asked when the app is in front
        guard let vc = Presenter.top() else { return }
        consentAsked = true
        adEngine.consent.gather(from: vc, underAge: c.underAge, debugEea: options.consentDebugEea, hashedIds: options.consentTestDeviceHashedIds) { [weak self] can, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.consentDone = true; self.consentError = err
                if let e = err { VLog.w("Consent: \(e)") }
                VLog.i("Consent: ads \(can ? "may" : "may not") be requested")
                self.proceed()
            }
        }
    }

    private func status() -> VfxStatus {
        let ready = cfg != nil && cfg!.enabled && engineReady && canRequest()
        let why: String
        if cfg == nil { why = "no settings yet" }
        else if !cfg!.enabled { why = cfg!.reason.isEmpty ? "off on the platform" : cfg!.reason }
        else if !consentDone { why = "waiting for consent" }
        else if !canRequest() { why = "consent does not allow ads" }
        else if !engineReady { why = "starting" }
        else { why = "" }
        return VfxStatus(ready: ready, reason: why, fromCache: configFrom == "cache")
    }

    /// Tells the app once: ready, or why not (it never waits forever).
    private func announce() {
        if readyAnnounced { return }
        readyAnnounced = true
        let st = status()
        let l = listeners; listeners = []
        l.forEach { $0(st) }
    }

    // MARK: SlotEnv

    func now() -> Int64 { clock() }
    func post(delayMs: Int64, _ block: @escaping () -> Void) -> AnyObject {
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
        return item
    }
    func cancel(_ token: AnyObject) { (token as? DispatchWorkItem)?.cancel() }
    func config() -> Config? { cfg }
    func canRequest() -> Bool {
        guard let c = cfg, c.enabled, engineReady else { return false }
        return !c.ump || adEngine.consent.canRequestAds()
    }
    func keyValues(_ placement: Placement) -> [String: String] {
        var m = appKv
        if let kv = cfg?.kv { m.merge(kv) { _, new in new } }
        m["vfx_pl"] = placement.name
        if let ab = cfg?.ab, !ab.isEmpty { m["vfx_ab"] = ab.replacingOccurrences(of: ":", with: "_") }
        return m
    }
    func event(_ type: String, _ p: Placement, _ fields: [String: Any?]) {
        var clean: [String: Any] = [:]
        for (k, v) in fields { if let v = v { clean[k] = v } }
        eventListener?(VfxEvent(type: type, placement: p.name, format: p.format, details: clean, time: clock()))
        if type == "paid" {
            revenueListener?(VfxRevenue(placement: p.name, format: p.format, valueMicros: (clean["v"] as? Int64) ?? 0, currency: (clean["cur"] as? String) ?? "", precision: (clean["prec"] as? String) ?? "", source: clean["src"] as? String))
        }
        guard let c = cfg, c.eventsOn else { return }
        var f: [String: Any?] = ["pl": p.name, "f": p.format.wire]
        for (k, v) in clean { f[k] = v }
        events.add(type, f)
        if events.size() >= c.batch { flushNow() }
    }
    func onFullScreenClosed() { skipNextAppOpen = false }

    // MARK: Prebid (bids before Google; PROTOCOL.md, "prebid")

    private lazy var prebidRunner = PrebidRunner(
        post: { [unowned self] d, b in self.post(delayMs: d, b) }, cancel: { [unowned self] t in self.cancel(t) }, now: { [unowned self] in self.clock() },
        io: { [unowned self] b in self.io.async(execute: b) },
        send: { u, body, tmo in Http.postJsonFast(u, body, timeoutMs: tmo) },
        device: { Sdk.prebidDevice() }, signals: { Sdk.prebidSignals() },
        appVersion: { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "" }, sdkVersion: vfxVersion,
        event: { [unowned self] p, r, why in
            var f: [String: Any?] = ["r": r.result, "ms": r.ms]
            if r.result == "bid" { f["v"] = r.valueMicros }
            if !why.isEmpty { f["why"] = why }
            self.event("pb", p, f)
        })

    func prebid(_ placement: Placement, _ done: @escaping ([String: String]) -> Void) {
        if let c = cfg { prebidRunner.run(c, placement, done) } else { done([:]) }
    }

    private static func prebidDevice() -> Prebid.Device {
        var sys = utsname(); uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        let scale = UIScreen.main.scale, size = UIScreen.main.bounds.size
        return Prebid.Device(os: "ios", osv: UIDevice.current.systemVersion, make: "Apple", model: String(machine.prefix(40)),
                             tablet: UIDevice.current.userInterfaceIdiom == .pad, language: Locale.current.languageCode ?? "en",
                             w: Int(size.width * scale), h: Int(size.height * scale), pxratio: Double(scale), ua: Http.userAgent)
    }

    /// What Google's consent form left in the app's UserDefaults under the IAB's standard keys.
    private static func prebidSignals() -> Prebid.Signals {
        let d = UserDefaults.standard
        let gdpr = d.object(forKey: "IABTCF_gdprApplies") as? NSNumber
        return Prebid.Signals(gdprApplies: gdpr.map { $0.intValue == 1 }, tcString: d.string(forKey: "IABTCF_TCString") ?? "",
                              usPrivacy: d.string(forKey: "IABUSPrivacy_String") ?? "", gpp: d.string(forKey: "IABGPP_HDR_GppString") ?? "",
                              gppSid: d.string(forKey: "IABGPP_GppSID") ?? "")
    }

    func slot(_ name: String) -> FullScreenSlot {
        if let s = slots[name] { return s }
        let s = FullScreenSlot(name: name, env: self); slots[name] = s; return s
    }

    func setAppKeyValue(_ k: String, _ v: String?) { if let v = v { appKv[k] = v } else { appKv.removeValue(forKey: k) } }

    // MARK: events

    private func header() -> EventLog.Header {
        let info = Bundle.main.infoDictionary
        var sys = utsname(); uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        let country = String((Locale.current.regionCode ?? "").prefix(2))
        return EventLog.Header(key: key, install: installId, session: sessionId, sdk: vfxVersion, appVersion: (info?["CFBundleShortVersionString"] as? String) ?? "",
                               os: UIDevice.current.systemVersion, device: String(machine.prefix(60)), country: country, ab: cfg?.ab ?? "", sample: cfg?.sample ?? 1.0, engine: adEngine.name)
    }

    func flushNow() {
        guard let c = cfg, c.eventsOn else { return }
        events.flush(url: c.eventsUrl, header: header())
    }

    private func scheduleFlush() {
        if let t = flushToken { cancel(t) }; flushToken = nil
        guard let c = cfg, c.eventsOn else { return }
        flushToken = post(delayMs: Int64(c.flushSec) * 1000) { [weak self] in self?.flushToken = nil; self?.flushNow(); self?.scheduleFlush() }
    }

    // MARK: the app in front, or not

    @objc private func didBecomeActive() {
        if active { return }
        active = true
        onForeground()
        if !consentDone, cfg != nil { proceed() }
        if !coldHandled { coldHandled = true; maybeAppOpen(cold: true) }
    }
    private var coldHandled = false

    @objc private func didEnterBackground() {
        active = false
        backgroundAt = clock()
        if fullScreenShowing { skipNextAppOpen = true }   // the user left from an ad (a click): no app open ad on the way back
        flushNow()
        if let t = flushToken { cancel(t) }; flushToken = nil
    }

    private func onForeground() {
        let now = clock()
        let timeout = Int64(cfg?.sessionTimeoutSec ?? 1800) * 1000
        if sessionId.isEmpty || (backgroundAt > 0 && now - backgroundAt > timeout) { startSession() }
        if options.settingsForTesting == nil, cfg == nil || now - configAt > Int64(cfg!.ttlSec) * 1000 { fetchConfig("foreground") }
        // after a while away, give up on giving up: load again
        slots.values.forEach { $0.load(fresh: $0.state == "gave up") }
        if backgroundAt > 0 { maybeAppOpen(cold: false) }
        scheduleFlush()
    }

    private func startSession() {
        sessionNumber = Int(store.getLong(Sdk.kSessions, 0)) + 1
        store.putLong(Sdk.kSessions, Int64(sessionNumber))
        sessionId = UUID().uuidString
        pacer.startSession(number: sessionNumber, at: clock())
        sesSent = false
        if cfg?.eventsOn == true { sendSession() }
    }
    private func sendSession() { sesSent = true; events.add("ses", ["n": sessionNumber, "first": sessionNumber == 1]) }

    /// App open ads: on a return to the app, or at a cold start when one is ready soon enough.
    func maybeAppOpen(cold: Bool) {
        guard let c = cfg else { return }
        if skipNextAppOpen { skipNextAppOpen = false; return }
        guard let p = c.placements.values.first(where: { $0.format == .appOpen && $0.on && $0.autoShow }), active, let vc = Presenter.top() else { return }
        if fullScreenShowing { return }
        let s = slot(p.name)
        if s.isReady() { s.show(presenter: vc, callbacks: VfxShowCallbacks()) }
        else if cold && clock() - coldStartAt < 4000 { _ = post(delayMs: 800) { [weak self] in if let self = self, self.clock() - self.coldStartAt < 4000 { self.maybeAppOpen(cold: true) } } }
        else { s.load() }
    }

    /// The first screen may already be in front when the app initializes late.
    func start() {
        if UIApplication.shared.applicationState == .active && !active { didBecomeActive() }
        if let testing = options.settingsForTesting {   // a demo or a test: these settings, nothing fetched, nothing kept
            guard let c = ConfigParser.parse(testing) else { VLog.e("settingsForTesting: not settings this SDK understands."); announce(); return }
            VLog.w("Using settings given by the app (testing only), not the platform's.")
            configAt = clock()
            setConfig(c, "testing")
            proceed()
            return
        }
        if cfg != nil { proceed() }
        if configFrom != "platform" { fetchConfig("start") }
    }

    func resetConsent() { adEngine.consent.reset(); consentDone = false; consentAsked = false }
    func isEngineReady() -> Bool { engineReady }

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? "" }
}
