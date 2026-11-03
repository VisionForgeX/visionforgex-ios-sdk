# VisionForgeX SDK for iOS

The SDK for iOS apps monetized with [VisionForgeX](https://apps.visionforgex.com): Google Ad Manager demand
(Google Ad Exchange) through the app's VisionForgeX account, with every decision made on the platform, not in the app.

- **One line to start.** The app's settings come from the platform, are cached, and change without an app update:
  what each placement requests, banner refresh, pacing and caps, preloading, price floors, consent, experiments.
- **Formats.** Anchored adaptive and collapsible banners, interstitial, rewarded, rewarded interstitial and app open.
  (Native ads: not yet on iOS.)
- **More shown, less waiting.** Full-screen ads are loaded in advance and replaced before Google's expiry; a failed
  load is retried after a growing wait; banners refresh only while seen.
- **Floors**, **pacing**, **consent** (Google's User Messaging Platform), **live revenue** (Google's paid event) and
  **experiments**, as on Android.

[docs/PROTOCOL.md](docs/PROTOCOL.md) describes everything the SDK and the platform say to each other.

## Add it

Xcode → File → Add Package Dependencies → `https://github.com/VisionForgeX/visionforgex-ios-sdk` → add the
**VisionForgeX** library to your app target. It brings Google Mobile Ads 11 and Google's consent SDK; remove your own
Google Mobile Ads package if you have one.

`Info.plist`: the App ID shown on your app's page on VisionForgeX, and Google's SKAdNetwork identifiers (list on
Google's site).

```xml
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-…~…</string>
```

## Start it

```swift
import VisionForgeX

@main struct MyApp: App {
    init() { VisionForgeX.initialize(appKey: "vfx_…your app key…") }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

UIKit: call it in `application(_:didFinishLaunchingWithOptions:)`. The key is on your app's page on VisionForgeX
(VisionForgeX SDK panel).

## Show ads, by placement name

```swift
// at a natural pause: call at every one; the platform decides whether an ad shows now
VisionForgeX.interstitial("level_complete").show(from: self)

// rewarded
VisionForgeX.rewarded("extra_life").show(from: self) { type, amount in giveReward() }

// know what happened
VisionForgeX.interstitial("level_complete").show(from: self, callbacks: VfxShowCallbacks(
    onDismissed: { goOn() }, onNotShown: { reason in goOn() }))

// a banner (UIKit; in SwiftUI wrap it in a UIViewRepresentable)
let banner = VfxBannerView(placement: "home_banner")
```

App open ads show by themselves on return to the app when the platform turns that on.

## Test before you have an account

```swift
VisionForgeX.initialize(appKey: "demo", options: .googleDemoAds())   // Google's demo units; nothing is sent anywhere
```

Placements: `banner`, `collapsible_banner`, `interstitial`, `rewarded`, `rewarded_interstitial`, `app_open`.

## Privacy options and revenue

```swift
if VisionForgeX.isPrivacyOptionsRequired { VisionForgeX.showPrivacyOptions(from: self) }
VisionForgeX.revenueListener = { r in /* r.valueMicros, r.currency, r.precision → your analytics */ }
```

## Status

Version 1.0.0 is written against Google Mobile Ads 11.x and has not yet been through its first CI build.
What stays private is the platform; this repository holds only what runs in the app.
