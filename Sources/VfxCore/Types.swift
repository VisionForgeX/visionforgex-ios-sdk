import Foundation

/// This SDK's version.
public let vfxVersion = "1.2.0"

/// The ad formats, as the platform names them.
public enum VfxFormat: String {
    case banner
    case interstitial
    case rewarded
    case rewardedInterstitial = "rewarded_interstitial"
    case appOpen = "app_open"
    case native

    public var wire: String { rawValue }
    public var isFullScreen: Bool { self != .banner && self != .native }
    public var isRewarded: Bool { self == .rewarded || self == .rewardedInterstitial }
    public static func fromWire(_ s: String) -> VfxFormat? { VfxFormat(rawValue: s) }
}

/// How much the SDK writes to the console (prefix "VisionForgeX").
public enum VfxLogLevel: Int, Comparable {
    case none = 0, error, warn, info, debug
    public static func < (a: VfxLogLevel, b: VfxLogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Every ad event as it happens. `type` is one of the protocol's: req, fill, nofill, show, click, close, fail, reward, paid, capped.
public struct VfxEvent {
    public let type: String
    public let placement: String
    public let format: VfxFormat
    /// The rest: tier, ms, err, why, src, and for "paid" v (micros), cur, prec.
    public let details: [String: Any]
    public let time: Int64
    public init(type: String, placement: String, format: VfxFormat, details: [String: Any], time: Int64) {
        self.type = type; self.placement = placement; self.format = format; self.details = details; self.time = time
    }
}

/// What one impression earned, as Google reported it (its paid event), for the app's own analytics.
public struct VfxRevenue {
    public let placement: String
    public let format: VfxFormat
    public let valueMicros: Int64
    public let currency: String
    public let precision: String
    public let source: String?
    public init(placement: String, format: VfxFormat, valueMicros: Int64, currency: String, precision: String, source: String?) {
        self.placement = placement; self.format = format; self.valueMicros = valueMicros; self.currency = currency; self.precision = precision; self.source = source
    }
}

/// What happened to one show() call. Every closure is optional.
public struct VfxShowCallbacks {
    public var onShown: (() -> Void)?
    public var onClicked: (() -> Void)?
    /// The ad was closed: carry on with the app.
    public var onDismissed: (() -> Void)?
    /// No ad was shown: carry on with the app. `reason`: "not_ready", "paused", "consent", "interval", "session",
    /// "hour", "day", "grace", "nth", "gap", "showing", "failed", "no_presenter", "unknown_placement".
    public var onNotShown: ((String) -> Void)?
    /// Rewarded formats: the user earned the reward (type, amount).
    public var onReward: ((String, Int) -> Void)?
    public init(onShown: (() -> Void)? = nil, onClicked: (() -> Void)? = nil, onDismissed: (() -> Void)? = nil,
                onNotShown: ((String) -> Void)? = nil, onReward: ((String, Int) -> Void)? = nil) {
        self.onShown = onShown; self.onClicked = onClicked; self.onDismissed = onDismissed; self.onNotShown = onNotShown; self.onReward = onReward
    }
}

/// Called once the SDK has its settings (or could not get any).
public struct VfxStatus {
    /// Ads may be shown: settings received, the app enabled, consent allows requests.
    public let ready: Bool
    /// Why not, when `ready` is false.
    public let reason: String
    /// Settings came from the cache (the platform was not reached).
    public let fromCache: Bool
    public init(ready: Bool, reason: String, fromCache: Bool) { self.ready = ready; self.reason = reason; self.fromCache = fromCache }
}
