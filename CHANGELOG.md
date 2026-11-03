# Changelog

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
