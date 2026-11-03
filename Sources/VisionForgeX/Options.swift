import Foundation
#if canImport(VfxCore)
@_exported import VfxCore
#endif

/// Options for `VisionForgeX.initialize`. Everything that decides revenue comes from the platform;
/// these are only for building and testing the app.
public struct VfxOptions {
    /// Google test devices: their ads are test ads (the console prints the ID on the first request).
    public var testDeviceIds: [String] = []
    /// Console output; nil: as the platform says (warnings, or everything in test mode).
    public var logLevel: VfxLogLevel?
    /// Show the consent form as if the device were in the EEA (testing only).
    public var consentDebugEea = false
    /// Hashed device IDs for the consent debug settings (the console prints yours).
    public var consentTestDeviceHashedIds: [String] = []
    /// The platform's address; only for testing against another server.
    public var baseUrl = VfxOptions.defaultBaseUrl
    /// Start loading as soon as the settings arrive (true), or only when asked.
    public var autoPreload = true
    /// Settings given by the app instead of fetched (PROTOCOL.md section 1), for testing only. Nil in a real app.
    public var settingsForTesting: String?

    public init() {}

    public static let defaultBaseUrl = "https://apps.visionforgex.com"

    /// Testing only: every format on Google's own demo ad units, which always answer with a test ad. Proves the
    /// SDK and Google Mobile Ads work in the app, with no account and no platform. Nothing is sent anywhere.
    public static func googleDemoAds() -> VfxOptions {
        var o = VfxOptions(); o.settingsForTesting = googleDemoSettings; return o
    }

    /// Google's demo ad units for Ad Manager (they always fill with test ads), as settings. Native is not on iOS yet.
    public static let googleDemoSettings = """
    {"v":1,"ttl":86400,"app":{"enabled":true,"test":true,"reason":""},
     "global":{"fullGapSec":10,"sessionTimeoutSec":1800,"log":"debug"},
     "consent":{"ump":false,"child":false,"underAge":false,"rating":""},
     "events":{"on":false,"url":"","sample":1.0,"batch":20,"flushSec":30},
     "kv":{},"ab":"",
     "placements":{
      "banner":{"format":"banner","on":true,"unit":"/21775744923/example/adaptive-banner","preload":false,"expiryMin":55,"refreshSec":30,"collapsible":""},
      "collapsible_banner":{"format":"banner","on":true,"unit":"/21775744923/example/adaptive-banner","preload":false,"expiryMin":55,"refreshSec":0,"collapsible":"bottom"},
      "interstitial":{"format":"interstitial","on":true,"unit":"/21775744923/example/interstitial","preload":true,"expiryMin":55,"cap":{"minIntervalSec":15}},
      "rewarded":{"format":"rewarded","on":true,"unit":"/21775744923/example/rewarded","preload":true,"expiryMin":55},
      "rewarded_interstitial":{"format":"rewarded_interstitial","on":true,"unit":"/21775744923/example/rewarded-interstitial","preload":true,"expiryMin":55,"cap":{"minIntervalSec":15}},
      "app_open":{"format":"app_open","on":true,"unit":"/21775744923/example/app-open","preload":true,"expiryMin":235,"autoShow":true,"cap":{"minIntervalSec":60}}
     }}
    """
}
