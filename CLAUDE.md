# Working on the VisionForgeX SDK for iOS

The SDK iOS apps add to be monetized with VisionForgeX (apps.visionforgex.com). This repository is
**public**: it holds only what runs inside an app. Every decision (what to request, refresh, pacing, floors,
consent tags, experiments) is made by the platform, in the private repository `VisionForgeX/visionforgex-apps`,
and arrives as settings. Never put a decision, a threshold chosen for revenue, a key, an account or a
customer's name here.

## Read before writing code
1. `docs/PROTOCOL.md` — everything the SDK and the platform say to each other (identical to the Android SDK's).
   A change here is a change there too (`site/public_html/admin/sdk-lib.php` in visionforgex-apps) and in
   `VisionForgeX/visionforgex-android-sdk`, in the same piece of work.
2. `CHANGELOG.md`.

## Standing rules
- **Push after every change**, with a CHANGELOG line; tag releases (`1.0.0`): Swift Package Manager builds from the tag.
- **Never break an app in production.** Keep the public API (`VisionForgeX`, `VfxFullScreen`, `VfxBannerView`,
  `VfxOptions`, `VfxShowCallbacks`) compatible within a major version.
- **Google's limits are kept in the SDK whatever the settings say**: banners never refresh faster than 30 s; ads are
  thrown away before Google's expiry (1 h, app open 4 h); never two full-screen ads at once.
- `VfxCore` has no ad SDK and no UIKit in it (so its tests run on a Mac without a simulator); the Google engine is in
  `VisionForgeX`.
- **Test what you change.** CI (`.github/workflows/ci.yml`) runs `VfxCoreTests` and builds for iOS on GitHub's Macs.
  Never report a pass you did not watch: Claude's workspace has no Swift compiler, so code written there is
  "not compiled" until the CI run is green.
- Publisher-facing wording says VisionForgeX and support@visionforgex.com.
