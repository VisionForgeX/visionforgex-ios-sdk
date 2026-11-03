# Changelog

## 1.0.0 (not released)
First version for iOS, matching the Android SDK 1.0.x's protocol (docs/PROTOCOL.md version 1).
- Settings from the platform, cached, refreshed by their time; consent through Google's User Messaging Platform.
- Interstitial, rewarded, rewarded interstitial and app open ads: preloaded, expiring before Google's limits, floors asked highest first, retried after a growing wait, paced by the platform's caps.
- Anchored adaptive and collapsible banners, refreshed only while seen (never faster than 30 s).
- Events batched to the platform (a file keeps them over a restart), Google's paid event as live revenue, experiments, key-values.
- Not in 1.0.0: native ads (a placement of that format is ignored), the debug panel, gzip of event batches.
- Written against Google Mobile Ads 11.x. Not yet built on a Mac: the first run of the CI workflow is the first compile.
