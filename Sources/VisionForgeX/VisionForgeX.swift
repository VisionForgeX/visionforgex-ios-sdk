import UIKit
#if canImport(VfxCore)
@_exported import VfxCore
#endif

/// The VisionForgeX SDK. Start it once, as early as you can (application(_:didFinishLaunchingWithOptions:) or your App's init):
///
///     VisionForgeX.initialize(appKey: "vfx_…your app key…")
///
/// Then show ads by placement name, as set on apps.visionforgex.com:
///
///     VisionForgeX.interstitial("level_complete").show(from: self)
///     VisionForgeX.rewarded("extra_life").show(from: self) { type, amount in giveReward() }
///
/// Everything else — what each placement requests, how often, when it may show, its floors, consent,
/// experiments — is decided by the platform and arrives as the app's settings.
public enum VisionForgeX {
    /// This SDK's version.
    public static let version = vfxVersion

    static var sdk: Sdk?
    private static var ready = false
    private static var waiting: [() -> Void] = []

    /// Starts the SDK: its settings are fetched (and the last ones used meanwhile), consent asked where the law
    /// needs it (Google's form), and the placements that preload begin loading. Call it once, on the main thread.
    public static func initialize(appKey: String, options: VfxOptions = VfxOptions(), completion: ((VfxStatus) -> Void)? = nil) {
        if let s = sdk { s.addListener(completion); return }
        let s = Sdk(key: appKey.trimmingCharacters(in: .whitespacesAndNewlines), options: options, engine: GmaEngine())
        sdk = s
        s.addListener { st in
            if st.ready { markReady() }
            completion?(st)
        }
        s.start()
    }

    /// True once the SDK has settings that allow ads and consent allows requests.
    public static var isReady: Bool { sdk?.canRequest() == true }

    /// An interstitial placement.
    public static func interstitial(_ placement: String) -> VfxFullScreen { VfxFullScreen(placement, .interstitial) }
    /// A rewarded placement.
    public static func rewarded(_ placement: String) -> VfxFullScreen { VfxFullScreen(placement, .rewarded) }
    /// A rewarded interstitial placement.
    public static func rewardedInterstitial(_ placement: String) -> VfxFullScreen { VfxFullScreen(placement, .rewardedInterstitial) }
    /// An app open placement (shown by itself when the platform turns that on; or call show()).
    public static func appOpen(_ placement: String) -> VfxFullScreen { VfxFullScreen(placement, .appOpen) }

    /// Loads every placement that preloads (only needed with `autoPreload = false`).
    public static func preloadAll() { sdk?.preloadAll() }

    /// A key-value of the app's own added to every request (e.g. "level" → "12"), for targeting and reports in
    /// Ad Manager. Keys: lowercase letters, digits and _, at most 20; "vfx_" is ours. Nil removes it.
    public static func setKeyValue(_ key: String, _ value: String?) {
        if key.range(of: "^[a-z0-9_]{1,20}$", options: .regularExpression) == nil || key.hasPrefix("vfx_") {
            VLog.w("Key-value \"\(key)\" not used: lowercase letters, digits and _, at most 20, not starting with vfx_."); return
        }
        sdk?.setAppKeyValue(key, value.map { String($0.prefix(40)) })
    }

    /// Whether the app must offer a "Privacy options" button (users in the EEA, UK, Switzerland, some US states).
    public static var isPrivacyOptionsRequired: Bool { sdk?.adEngine.consent.privacyOptionsRequired() == true }

    /// Opens Google's privacy options form, from the app's "Privacy options" button.
    public static func showPrivacyOptions(from viewController: UIViewController, completion: ((String?) -> Void)? = nil) {
        guard let c = sdk?.adEngine.consent else { completion?("no consent engine"); return }
        c.showPrivacyOptions(from: viewController) { err in DispatchQueue.main.async { completion?(err) } }
    }

    /// Mutes video ads (the app's own sound setting).
    public static func setMuted(_ muted: Bool) { sdk?.adEngine.setMuted(muted) }

    /// Google's ad inspector, for checking a live build.
    public static func openAdInspector(from viewController: UIViewController) { sdk?.adEngine.openInspector(from: viewController) }

    /// Every ad event as it happens (nil stops it). Called on the main thread.
    public static var eventListener: ((VfxEvent) -> Void)? {
        get { sdk?.eventListener }
        set { sdk?.eventListener = newValue }
    }

    /// What each impression earned, for the app's own analytics: Firebase, AppsFlyer, Adjust (nil stops it).
    public static var revenueListener: ((VfxRevenue) -> Void)? {
        get { sdk?.revenueListener }
        set { sdk?.revenueListener = newValue }
    }

    /// Where the settings came from: "platform", "cache", "testing", or "none".
    public static func settingsSource() -> String { sdk?.configFrom ?? "none" }

    /// Sends the events waiting now (they are sent by themselves too).
    public static func flush() { sdk?.flushNow() }

    // MARK: inside

    static func whenReady(_ f: @escaping () -> Void) { DispatchQueue.main.async { if ready { f() } else { waiting.append(f) } } }
    private static func markReady() { DispatchQueue.main.async { ready = true; let w = waiting; waiting = []; w.forEach { $0() } } }
}

/// One full-screen placement: `VisionForgeX.interstitial("level_complete")`.
public final class VfxFullScreen {
    public let placement: String
    public let format: VfxFormat
    init(_ placement: String, _ format: VfxFormat) { self.placement = placement; self.format = format }

    /// An ad is loaded and fresh, so show() will show it (if the pacing allows).
    public func isReady() -> Bool { VisionForgeX.sdk?.slot(placement).isReady() == true }

    /// Loads one if none is waiting (placements that preload do this by themselves).
    public func load() { VisionForgeX.sdk?.slot(placement).load(fresh: true) }

    /// Shows it if one is ready and the pacing allows; otherwise `callbacks.onNotShown` says why, and the app
    /// carries on. Safe to call at every opportunity: the platform's pacing decides.
    public func show(from viewController: UIViewController? = nil, callbacks: VfxShowCallbacks = VfxShowCallbacks()) {
        guard let s = VisionForgeX.sdk else { callbacks.onNotShown?("not_ready"); return }
        if let p = s.config()?.placements[placement], p.format != format {
            VLog.w("\"\(placement)\" is a \(p.format.wire) placement on the platform, not \(format.wire).")
        }
        s.slot(placement).show(presenter: viewController ?? Presenter.top(), callbacks: callbacks)
    }

    /// Rewarded formats: `show(from: self) { type, amount in … }`.
    public func show(from viewController: UIViewController? = nil, onReward: @escaping (String, Int) -> Void) {
        show(from: viewController, callbacks: VfxShowCallbacks(onReward: onReward))
    }
}
