import Foundation

/// What a slot needs from the SDK. Everything is called on the main thread.
public protocol SlotEnv: AnyObject {
    var engine: FullScreenEngine { get }
    var pacer: Pacer { get }
    func now() -> Int64
    /// Runs `block` after `delayMs`; the returned token can be cancelled.
    func post(delayMs: Int64, _ block: @escaping () -> Void) -> AnyObject
    func cancel(_ token: AnyObject)
    func config() -> Config?
    /// Settings arrived, the app enabled, consent allows requests.
    func canRequest() -> Bool
    func keyValues(_ placement: Placement) -> [String: String]
    func event(_ type: String, _ p: Placement, _ fields: [String: Any?])
    var fullScreenShowing: Bool { get set }
    func onFullScreenClosed()
    /// Asks for bids (Prebid) before Google is asked; `done` gets the winner's key-values, or none. Answers exactly once.
    func prebid(_ placement: Placement, _ done: @escaping ([String: String]) -> Void)
}

public extension SlotEnv {
    func prebid(_ placement: Placement, _ done: @escaping ([String: String]) -> Void) { done([:]) }
}

/// One full-screen placement: keeps one ad loaded (when the platform says preload), asks through the floor
/// tiers highest first, retries a failed load after a growing wait, throws away an ad before Google's
/// expiry, and shows only when the pacing allows.
public final class FullScreenSlot {
    public let name: String
    private unowned let env: SlotEnv
    private var ad: EngineFullScreenAd?
    private var loadedAt: Int64 = 0
    private var source: String?
    private var loading = false
    private var loadId = 0
    private var attempt = 0
    private var retryToken: AnyObject?
    private var timeoutToken: AnyObject?
    public private(set) var lastError = ""
    public private(set) var state = "idle"

    public init(name: String, env: SlotEnv) { self.name = name; self.env = env }

    public func placement() -> Placement? { env.config()?.placements[name] }

    public func isReady() -> Bool {
        guard let p = placement(), let a = ad else { return false }
        if env.now() - loadedAt > Int64(p.expiryMin) * 60_000 { a.destroy(); ad = nil; state = "expired"; return false }
        return true
    }

    /// Loads one, unless one is loaded, loading, or waiting to retry. `fresh`: a new start after giving up.
    public func load(fresh: Bool = false) {
        guard let p = placement() else { return }
        if !p.on || !env.canRequest() || p.unit.trimmingCharacters(in: .whitespaces).isEmpty { return }
        if isReady() || loading { return }
        if retryToken != nil && !fresh { return }
        if fresh { if let t = retryToken { env.cancel(t) }; retryToken = nil; attempt = 0 }
        if attempt > p.retry.maxAttempts { return }
        loadId += 1
        let id = loadId
        if p.prebidImp.isEmpty { loadTier(p, 0, id, [:]); return }
        loading = true
        state = "bidding"
        env.prebid(p) { [weak self] bid in
            guard let self = self, id == self.loadId else { return }   // reset meanwhile: the old auction is forgotten
            self.loadTier(p, 0, id, bid)
        }
    }

    private func loadTier(_ p: Placement, _ tier: Int, _ id: Int, _ bid: [String: String]) {
        let tiers = p.floors.tiers
        var kv = env.keyValues(p)
        for (k, v) in bid { kv[k] = v }
        if tier < tiers.count { kv[p.floors.key] = tiers[tier] }
        loading = true
        state = "loading"
        let started = env.now()
        let tierNo = tier < tiers.count ? tier + 1 : 0   // 0: the request without a floor
        env.event("req", p, ["tier": tierNo])
        var answered = false
        if tier < tiers.count {   // a floored tier that is slow counts as no fill: the next, lower one is asked
            timeoutToken = env.post(delayMs: p.floors.timeoutMs) { [weak self] in
                guard let self = self, !answered, id == self.loadId else { return }
                answered = true
                self.env.event("nofill", p, ["tier": tierNo, "ms": self.env.now() - started, "err": "timeout"])
                self.loadTier(p, tier + 1, id, bid)
            }
        }
        env.engine.loadFullScreen(format: p.format, unit: p.unit, request: EngineRequest(keyValues: kv)) { [weak self] result in
            guard let self = self else { return }
            _ = self.env.post(delayMs: 0) { [weak self] in
                guard let self = self else { return }
                switch result {
                case .success(let loadedAd):
                    if answered || id != self.loadId { loadedAd.destroy(); return }   // too late: a lower tier was already asked
                    answered = true
                    if let t = self.timeoutToken { self.env.cancel(t) }; self.timeoutToken = nil
                    self.loading = false
                    self.attempt = 0
                    self.ad = loadedAd
                    self.loadedAt = self.env.now()
                    self.source = loadedAd.source
                    self.state = "ready"
                    self.lastError = ""
                    self.env.event("fill", p, ["tier": tierNo, "ms": self.env.now() - started, "src": loadedAd.source])
                case .failure(let err):
                    if answered || id != self.loadId { return }
                    answered = true
                    if let t = self.timeoutToken { self.env.cancel(t) }; self.timeoutToken = nil
                    self.lastError = "\(err.code) \(err.message)"
                    self.env.event("nofill", p, ["tier": tierNo, "ms": self.env.now() - started, "err": String(err.code)])
                    if tier < tiers.count { self.loadTier(p, tier + 1, id, bid); return }
                    self.loading = false
                    self.scheduleRetry(p)
                }
            }
        }
    }

    private func scheduleRetry(_ p: Placement) {
        attempt += 1
        if attempt > p.retry.maxAttempts { state = "gave up"; return }   // until the next show() or the app's next return
        let wait = backoffMs(attempt, p.retry)
        state = "retry in \(wait / 1000) s"
        retryToken = env.post(delayMs: wait) { [weak self] in self?.retryToken = nil; self?.load() }
    }

    /// Shows it if one is ready and the pacing allows; otherwise the callbacks' onNotShown says why.
    public func show(presenter: AnyObject?, callbacks: VfxShowCallbacks) {
        guard let p = placement() else { callbacks.onNotShown?("unknown_placement"); return }
        let cfg = env.config()
        func notShown(_ why: String) { env.event("capped", p, ["why": why]); callbacks.onNotShown?(why) }
        guard let c = cfg, c.enabled, p.on else { callbacks.onNotShown?("paused"); return }
        if !env.canRequest() { callbacks.onNotShown?("consent"); return }
        if env.fullScreenShowing { callbacks.onNotShown?("showing"); return }
        guard let presenter = presenter else { callbacks.onNotShown?("no_presenter"); return }
        if let why = env.pacer.check(p, fullGapSec: c.fullGapSec) { notShown(why); return }
        guard let a = ad, isReady() else {
            callbacks.onNotShown?("not_ready")
            load(fresh: state == "gave up")
            return
        }
        ad = nil
        state = "showing"
        env.fullScreenShowing = true
        let src = source
        let listener = SlotListener(slot: self, env: env, p: p, ad: a, src: src, callbacks: callbacks)
        a.show(presenter: presenter, listener: OnMain(env: env, inner: listener))
    }

    fileprivate func dismissed(_ p: Placement, _ a: EngineFullScreenAd) {
        env.fullScreenShowing = false
        env.onFullScreenClosed()
        env.event("close", p, [:])
        state = "idle"
        a.destroy()
    }
    fileprivate func failedToShow(_ p: Placement, _ a: EngineFullScreenAd, _ code: Int, _ message: String) {
        env.fullScreenShowing = false
        state = "idle"
        lastError = "\(code) \(message)"
        env.event("fail", p, ["err": String(code)])
        a.destroy()
    }

    /// The settings changed or the SDK stops: forget the loaded ad when its placement changed.
    public func reset() {
        loadId += 1
        if let t = retryToken { env.cancel(t) }; retryToken = nil
        if let t = timeoutToken { env.cancel(t) }; timeoutToken = nil
        loading = false; attempt = 0
        ad?.destroy(); ad = nil
        state = "idle"
    }

    public func describe() -> String { "\(state)\(source.map { " · \($0)" } ?? "")\(lastError.isEmpty ? "" : " · last error \(lastError)")" }
}

private final class SlotListener: FullScreenListener {
    unowned let slot: FullScreenSlot
    unowned let env: SlotEnv
    let p: Placement
    let ad: EngineFullScreenAd
    let src: String?
    let callbacks: VfxShowCallbacks
    init(slot: FullScreenSlot, env: SlotEnv, p: Placement, ad: EngineFullScreenAd, src: String?, callbacks: VfxShowCallbacks) {
        self.slot = slot; self.env = env; self.p = p; self.ad = ad; self.src = src; self.callbacks = callbacks
    }
    func onShown() { env.pacer.recordShow(p); env.event("show", p, ["src": src]); callbacks.onShown?() }
    func onClicked() { env.event("click", p, [:]); callbacks.onClicked?() }
    func onDismissed() {
        slot.dismissed(p, ad)
        callbacks.onDismissed?()
        if p.preload { slot.load(fresh: true) }
    }
    func onFailedToShow(code: Int, message: String) {
        slot.failedToShow(p, ad, code, message)
        callbacks.onNotShown?("failed")
        slot.load(fresh: true)
    }
    func onReward(type: String, amount: Int) { env.event("reward", p, ["amount": amount]); callbacks.onReward?(type, amount) }
    func onPaid(valueMicros: Int64, currency: String, precision: String) {
        env.event("paid", p, ["v": valueMicros, "cur": currency, "prec": precision, "src": src])
    }
}

/// Moves an engine's show callbacks to the main thread (and keeps the listener alive while the ad is on screen).
private final class OnMain: FullScreenListener {
    unowned let env: SlotEnv
    let inner: FullScreenListener
    init(env: SlotEnv, inner: FullScreenListener) { self.env = env; self.inner = inner }
    private func run(_ f: @escaping () -> Void) { _ = env.post(delayMs: 0, f) }
    func onShown() { run { [inner] in inner.onShown() } }
    func onClicked() { run { [inner] in inner.onClicked() } }
    func onDismissed() { run { [inner] in inner.onDismissed() } }
    func onFailedToShow(code: Int, message: String) { run { [inner] in inner.onFailedToShow(code: code, message: message) } }
    func onReward(type: String, amount: Int) { run { [inner] in inner.onReward(type: type, amount: amount) } }
    func onPaid(valueMicros: Int64, currency: String, precision: String) { run { [inner] in inner.onPaid(valueMicros: valueMicros, currency: currency, precision: precision) } }
}
