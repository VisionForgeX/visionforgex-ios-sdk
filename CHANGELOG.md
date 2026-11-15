# Changelog

## 1.3.0 (not released yet)
- **Ad revenue to AppsFlyer and Adjust** (off unless the platform's settings carry an `mmp` block): each impression's
  revenue from Google's paid event goes to AppsFlyer (6.15+, `logAdRevenue`, mediation network Google AdMob, with the
  serving network, ad unit, format and placement) and/or Adjust (`trackAdRevenue`, source `admob_sdk`, with the ad
  unit and placement). Found in the app by name (`NSClassFromString`): the SDK links neither, an app without them is
  unchanged, and one switched on but missing is said once in the log. Never in test mode, never a zero value.
  Same behaviour as Android 1.3.0 (docs/PROTOCOL.md).

## 1.2.0 (15 Nov 2026)
- **Google Mobile Ads 13.x** (was 11.x). Google deprecated 11.x on 4 Feb 2026 and stops serving it in Q2 2027; 13.x is
  supported until Q1 2028. Google's Swift names since 12.0 (`MobileAds.shared`, `AdManagerRequest`, `AdManagerBannerView`,
  `load(with:request:)`, `present(from:)`), the age treatment as one setting (CHILD or TEEN), paid events through the
  delegates. Google has no Next-Gen SDK for iOS: this is the iOS side of the same move. Needs Xcode 16.
- Banners ask for sizes from the largest down, as on Android: Google's large anchored adaptive size, the standard one
  and 320x50 in one request, then the standard alone, then 320x50, in the same load; the size that filled is kept.
- The request agent "VisionForgeX" on every request, as on Android.
- Events carry `eng` (`gma-ios-13`), the Google SDK under the app (docs/PROTOCOL.md).
- Includes 1.1.0.

## 1.1.0 (not released)
- Prebid for apps (off unless the platform's settings carry a `prebid` block): banners and interstitials first ask
  VisionForgeX's own Prebid Server for bids, waiting at most the settings' time, and give the winner's `hb_*` keys to
  Google's request; no bid or a slow server means Google alone, as before. Pauses itself after repeated failures,
  does not ask when GDPR applies without a consent string, sends no advertising ID or location. New event `pb`.
  Same behaviour as Android 1.1.0 (docs/PROTOCOL.md).
- Not yet built on a Mac: the first run of the CI workflow is the first compile.

## 1.0.0 (not released)
- Also as a CocoaPod (`VisionForgeX.podspec`), which the Flutter and React Native wrappers use.
First version for iOS, matching the Android SDK 1.0.x's protocol (docs/PROTOCOL.md version 1).
- Settings from the platform, cached, refreshed by their time; consent through Google's User Messaging Platform.
- Interstitial, rewarded, rewarded interstitial and app open ads: preloaded, expiring before Google's limits, floors asked highest first, retried after a growing wait, paced by the platform's caps.
- Anchored adaptive and collapsible banners, refreshed only while seen (never faster than 30 s).
- Events batched to the platform (a file keeps them over a restart), Google's paid event as live revenue, experiments, key-values.
- Not in 1.0.0: native ads (a placement of that format is ignored), the debug panel, gzip of event batches.
- Written against Google Mobile Ads 11.x. Not yet built on a Mac: the first run of the CI workflow is the first compile.
