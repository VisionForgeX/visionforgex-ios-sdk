import UIKit
import VfxCore

/// A banner for one placement: adaptive to the width it is given (Google's anchored adaptive size), refreshed as the
/// platform says only while at least half of it is on screen and the app is in front, collapsible when the platform
/// says so (first load only), retried after a growing wait.
///
///     let banner = VfxBannerView(placement: "home_banner")   // add it to your layout; it loads by itself once on screen
public final class VfxBannerView: UIView, BannerListener {
    /// The placement's name, as on the platform.
    public var placement: String { didSet { if window != nil { start() } } }

    private var banner: EngineBanner?
    private var loadedOnce = false
    private var attempt = 0
    private var started = false
    private var lastWidth: CGFloat = 0
    private var refreshItem: DispatchWorkItem?
    private var retryItem: DispatchWorkItem?
    private var requestedAt: Int64 = 0

    public init(placement: String = "") {
        self.placement = placement
        super.init(frame: .zero)
        clipsToBounds = true
    }
    public required init?(coder: NSCoder) {
        self.placement = ""
        super.init(coder: coder)
        clipsToBounds = true
    }

    public override var intrinsicContentSize: CGSize {
        if let s = banner?.adSize, s.height > 0 { return CGSize(width: UIView.noIntrinsicMetric, height: s.height) }
        return CGSize(width: UIView.noIntrinsicMetric, height: 50)
    }

    private func sdk() -> Sdk? { VisionForgeX.sdk }
    private func p() -> Placement? { sdk()?.config()?.placements[placement].flatMap { $0.format == .banner ? $0 : nil } }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    private func start() {
        if started || placement.isEmpty { return }
        started = true
        VisionForgeX.whenReady { [weak self] in if let self = self, self.window != nil { self.load() } }
    }

    private func stop() {
        refreshItem?.cancel(); retryItem?.cancel()
        banner?.destroy(); banner = nil
        started = false; loadedOnce = false; attempt = 0
    }

    /// Loads (or reloads) now. Usually not needed: it loads by itself.
    public func load() {
        guard let s = sdk() else { return }
        guard let p = p() else { VLog.w("Banner \"\(placement)\": no such banner placement in the settings."); return }
        if !p.on || p.unit.isEmpty || !s.canRequest() { return }
        let width = max(1, (bounds.width > 0 ? bounds.width : (window?.bounds.width ?? UIScreen.main.bounds.width)))
        if banner == nil || width != lastWidth {
            banner?.destroy()
            lastWidth = width
            let b = s.adEngine.newBanner(unit: p.unit, width: width, root: Presenter.top(), listener: self)
            banner = b
            b.view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b.view)
            NSLayoutConstraint.activate([b.view.centerXAnchor.constraint(equalTo: centerXAnchor), b.view.topAnchor.constraint(equalTo: topAnchor)])
        }
        requestedAt = s.now()
        s.event("req", p, ["tier": 0])
        banner?.load(EngineRequest(keyValues: s.keyValues(p), collapsible: loadedOnce ? "" : p.collapsible))
    }

    // MARK: BannerListener (Google's callbacks arrive on the main thread)

    func onLoaded(source: String?) {
        guard let s = sdk(), let p = p() else { return }
        loadedOnce = true; attempt = 0
        s.event("fill", p, ["tier": 0, "ms": s.now() - requestedAt, "src": source])
        invalidateIntrinsicContentSize()
        schedule(p)
    }
    func onFailed(code: Int, message: String) {
        guard let s = sdk(), let p = p() else { return }
        s.event("nofill", p, ["tier": 0, "ms": s.now() - requestedAt, "err": String(code), "msg": String(message.prefix(100))])
        attempt += 1
        if attempt <= p.retry.maxAttempts {
            let item = DispatchWorkItem { [weak self] in self?.load() }
            retryItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(backoffMs(attempt, p.retry))), execute: item)
        } else if loadedOnce { schedule(p) }
    }
    func onImpression() { if let s = sdk(), let p = p() { s.event("show", p, [:]) } }
    func onClicked() { if let s = sdk(), let p = p() { s.event("click", p, [:]) } }
    func onPaid(valueMicros: Int64, currency: String, precision: String) {
        if let s = sdk(), let p = p() { s.event("paid", p, ["v": valueMicros, "cur": currency, "prec": precision]) }
    }

    private func schedule(_ p: Placement) {
        refreshItem?.cancel()
        guard p.refreshSec > 0 else { return }
        let item = DispatchWorkItem { [weak self] in self?.tick() }
        refreshItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(p.refreshSec), execute: item)
    }

    /// A refresh is due: only if enough of the banner is seen, else wait until it is.
    private func tick() {
        guard p() != nil else { return }
        if !visibleEnough() {
            let item = DispatchWorkItem { [weak self] in self?.tick() }
            refreshItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
            return
        }
        load()
    }

    private func visibleEnough() -> Bool {
        guard let w = window, !isHidden, alpha > 0.01, UIApplication.shared.applicationState == .active else { return false }
        let r = convert(bounds, to: w).intersection(w.bounds)
        if r.isNull || bounds.width <= 0 || bounds.height <= 0 { return false }
        return r.width * r.height * 2 >= bounds.width * bounds.height
    }
}
