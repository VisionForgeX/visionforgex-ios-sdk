import UIKit
import GoogleMobileAds
#if canImport(VfxCore)
import VfxCore
#endif

/// The engine on Google Mobile Ads for iOS 13.x (Ad Manager requests). Apps never touch it.
///
/// Google has no Next-Gen SDK for iOS: its iOS SDK keeps one line with a major version each February. 11.x was
/// deprecated on 4 Feb 2026 and stops serving in Q2 2027; 12.x is supported until Q1 2027 (sunset Q2 2028); 13.x
/// until Q1 2028 (sunset Q2 2029). SDK 1.2.0 moved from 11.x to 13.x (Google's Swift names since 12.0).
final class GmaEngine: NSObject, AdEngine {
    let name = "gma-ios-13"
    let consent: ConsentEngine = UmpConsent()

    func initialize(settings: EngineSettings, done: @escaping () -> Void) {
        apply(settings: settings)
        MobileAds.shared.start { _ in done() }
    }

    func apply(settings: EngineSettings) {
        let rc = MobileAds.shared.requestConfiguration
        // one setting since 11.x: CHILD for an app directed at children (COPPA), TEEN under the age of consent (GDPR)
        rc.ageRestrictedTreatment = settings.childDirected ? .child : (settings.underAge ? .teen : .unspecified)
        switch settings.maxRating {
        case "G": rc.maxAdContentRating = GADMaxAdContentRating.general
        case "PG": rc.maxAdContentRating = GADMaxAdContentRating.parentalGuidance
        case "T": rc.maxAdContentRating = GADMaxAdContentRating.teen
        case "MA": rc.maxAdContentRating = GADMaxAdContentRating.matureAudience
        default: rc.maxAdContentRating = nil
        }
        rc.testDeviceIdentifiers = settings.testDeviceIds
    }

    func setMuted(_ muted: Bool) { MobileAds.shared.isApplicationMuted = muted }

    func openInspector(from vc: UIViewController) { MobileAds.shared.presentAdInspector(from: vc) { _ in } }

    static func request(_ r: EngineRequest) -> AdManagerRequest {
        let q = AdManagerRequest()
        q.customTargeting = r.keyValues
        q.requestAgent = "VisionForgeX"
        if !r.collapsible.isEmpty {
            let extras = Extras()
            extras.additionalParameters = ["collapsible": r.collapsible]
            q.register(extras)
        }
        return q
    }

    func loadFullScreen(format: VfxFormat, unit: String, request: EngineRequest, completion: @escaping (Result<EngineFullScreenAd, EngineError>) -> Void) {
        let req = GmaEngine.request(request)
        func fail(_ e: Error?) -> Result<EngineFullScreenAd, EngineError> {
            let ns = e as NSError?
            return .failure(EngineError(code: ns?.code ?? -1, message: ns?.localizedDescription ?? "no ad"))
        }
        DispatchQueue.main.async {
            switch format {
            case .interstitial:
                AdManagerInterstitialAd.load(with: unit, request: req) { ad, error in
                    if let ad = ad { completion(.success(GmaFullScreen.interstitial(ad))) } else { completion(fail(error)) }
                }
            case .rewarded:
                RewardedAd.load(with: unit, request: req) { ad, error in
                    if let ad = ad { completion(.success(GmaFullScreen.rewarded(ad))) } else { completion(fail(error)) }
                }
            case .rewardedInterstitial:
                RewardedInterstitialAd.load(with: unit, request: req) { ad, error in
                    if let ad = ad { completion(.success(GmaFullScreen.rewardedInterstitial(ad))) } else { completion(fail(error)) }
                }
            case .appOpen:
                AppOpenAd.load(with: unit, request: req) { ad, error in
                    if let ad = ad { completion(.success(GmaFullScreen.appOpen(ad))) } else { completion(fail(error)) }
                }
            case .banner, .native:
                completion(.failure(EngineError(code: -1, message: "not a full-screen format")))
            }
        }
    }

    func newBanner(unit: String, width: CGFloat, root: UIViewController?, listener: BannerListener) -> EngineBanner {
        GmaBanner(unit: unit, width: width, root: root, listener: listener)
    }
}

func gmaSource(_ info: ResponseInfo?) -> String? { info?.loadedAdNetworkResponseInfo?.adSourceName }

func gmaPaid(_ v: AdValue) -> (Int64, String, String) {
    let micros = v.value.multiplying(by: NSDecimalNumber(value: 1_000_000)).int64Value
    let prec: String
    switch v.precision {
    case .precise: prec = "PRECISE"
    case .publisherProvided: prec = "PUBLISHER_PROVIDED"
    case .estimated: prec = "ESTIMATED"
    default: prec = "UNKNOWN"
    }
    return (micros, v.currencyCode, prec)
}

/// A loaded full-screen ad of any of the four formats. It keeps itself alive from show() until the ad closes
/// (Google holds its delegate weakly); destroy() lets go. The paid event arrives through the delegate (13.x).
final class GmaFullScreen: NSObject, FullScreenContentDelegate, EngineFullScreenAd {
    let source: String?
    private var listener: FullScreenListener?
    private var presentBlock: ((UIViewController, GmaFullScreen) -> Void)?
    private var ad: AnyObject?     // Google's ad, held until it closes

    private init(source: String?) { self.source = source }

    static func interstitial(_ ad: AdManagerInterstitialAd) -> GmaFullScreen {
        let w = GmaFullScreen(source: gmaSource(ad.responseInfo))
        w.ad = ad
        ad.fullScreenContentDelegate = w
        w.presentBlock = { vc, _ in ad.present(from: vc) }
        return w
    }
    static func appOpen(_ ad: AppOpenAd) -> GmaFullScreen {
        let w = GmaFullScreen(source: gmaSource(ad.responseInfo))
        w.ad = ad
        ad.fullScreenContentDelegate = w
        w.presentBlock = { vc, _ in ad.present(from: vc) }
        return w
    }
    static func rewarded(_ ad: RewardedAd) -> GmaFullScreen {
        let w = GmaFullScreen(source: gmaSource(ad.responseInfo))
        w.ad = ad
        ad.fullScreenContentDelegate = w
        w.presentBlock = { vc, me in ad.present(from: vc) { let r = ad.adReward; me.listener?.onReward(type: r.type, amount: r.amount.intValue) } }
        return w
    }
    static func rewardedInterstitial(_ ad: RewardedInterstitialAd) -> GmaFullScreen {
        let w = GmaFullScreen(source: gmaSource(ad.responseInfo))
        w.ad = ad
        ad.fullScreenContentDelegate = w
        w.presentBlock = { vc, me in ad.present(from: vc) { let r = ad.adReward; me.listener?.onReward(type: r.type, amount: r.amount.intValue) } }
        return w
    }

    func show(presenter: AnyObject, listener: FullScreenListener) {
        guard let vc = presenter as? UIViewController, let present = presentBlock else {
            listener.onFailedToShow(code: -1, message: "no screen to show from")
            return
        }
        self.listener = listener
        present(vc, self)
    }

    func destroy() { listener = nil; presentBlock = nil; ad = nil }

    // FullScreenContentDelegate
    func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) { listener?.onShown() }
    func adDidRecordClick(_ ad: FullScreenPresentingAd) { listener?.onClicked() }
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) { listener?.onDismissed() }
    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        let ns = error as NSError
        listener?.onFailedToShow(code: ns.code, message: ns.localizedDescription)
    }
    func ad(_ ad: FullScreenPresentingAd, didRecordPaidEventWith value: AdValue) {
        let p = gmaPaid(value); listener?.onPaid(valueMicros: p.0, currency: p.1, precision: p.2)
    }
}

/// A banner, asked for in sizes from the largest down (BannerLadder, as on Android): Google's large anchored adaptive
/// size, the standard anchored adaptive one and 320x50 in one request; on "no fill" the standard size alone, then
/// 320x50 alone, in the same load. The size that filled is kept for the banner's refreshes.
final class GmaBanner: NSObject, EngineBanner, BannerViewDelegate {
    private let banner: AdManagerBannerView
    private weak var listener: BannerListener?
    private let width: CGFloat
    private var tier = 0
    private var good = -1
    private var request: EngineRequest?
    var view: UIView { banner }
    var adSize: CGSize { banner.adSize.size }

    init(unit: String, width: CGFloat, root: UIViewController?, listener: BannerListener) {
        self.width = width
        banner = AdManagerBannerView(adSize: largeAnchoredAdaptiveBanner(width: width))
        self.listener = listener
        super.init()
        banner.adUnitID = unit
        banner.rootViewController = root
        banner.delegate = self
    }

    private func sizes(_ t: Int) -> [AdSize] {
        BannerLadder.tier(t, large: largeAnchoredAdaptiveBanner(width: width), standard: currentOrientationAnchoredAdaptiveBanner(width: width), small: AdSizeBanner)
    }

    private func ask() {
        guard let r = request else { return }
        let s = sizes(tier)
        banner.adSize = s[0]
        banner.validAdSizes = s.map { nsValue(for: $0) }
        banner.load(GmaEngine.request(r))
    }

    func load(_ request: EngineRequest) {
        self.request = request
        tier = good >= 0 ? good : 0
        ask()
    }
    func destroy() { banner.delegate = nil; request = nil; banner.removeFromSuperview() }

    // BannerViewDelegate
    func bannerViewDidReceiveAd(_ bannerView: BannerView) { good = tier; listener?.onLoaded(source: gmaSource(bannerView.responseInfo)) }
    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        let ns = error as NSError
        if let next = BannerLadder.next(tier, code: ns.code), request != nil { tier = next; ask(); return }   // a smaller size, at once
        good = -1
        listener?.onFailed(code: ns.code, message: ns.localizedDescription)
    }
    func bannerViewDidRecordImpression(_ bannerView: BannerView) { listener?.onImpression() }
    func bannerViewDidRecordClick(_ bannerView: BannerView) { listener?.onClicked() }
    func bannerView(_ bannerView: BannerView, didRecordPaidEventWith value: AdValue) {
        let p = gmaPaid(value); listener?.onPaid(valueMicros: p.0, currency: p.1, precision: p.2)
    }
}
