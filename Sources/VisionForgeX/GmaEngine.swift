import UIKit
import GoogleMobileAds
#if canImport(VfxCore)
import VfxCore
#endif

/// The engine on Google Mobile Ads (iOS 11.x API, Ad Manager requests). Apps never touch it.
final class GmaEngine: NSObject, AdEngine {
    let name = "gma-ios-11"
    let consent: ConsentEngine = UmpConsent()

    func initialize(settings: EngineSettings, done: @escaping () -> Void) {
        apply(settings: settings)
        GADMobileAds.sharedInstance().start { _ in done() }
    }

    func apply(settings: EngineSettings) {
        let rc = GADMobileAds.sharedInstance().requestConfiguration
        rc.tagForChildDirectedTreatment = settings.childDirected ? NSNumber(value: true) : nil
        rc.tagForUnderAgeOfConsent = settings.underAge ? NSNumber(value: true) : nil
        switch settings.maxRating {
        case "G": rc.maxAdContentRating = GADMaxAdContentRating.general
        case "PG": rc.maxAdContentRating = GADMaxAdContentRating.parentalGuidance
        case "T": rc.maxAdContentRating = GADMaxAdContentRating.teen
        case "MA": rc.maxAdContentRating = GADMaxAdContentRating.matureAudience
        default: break
        }
        rc.testDeviceIdentifiers = settings.testDeviceIds
    }

    func setMuted(_ muted: Bool) { GADMobileAds.sharedInstance().applicationMuted = muted }

    func openInspector(from vc: UIViewController) { GADMobileAds.sharedInstance().presentAdInspector(from: vc) { _ in } }

    static func request(_ r: EngineRequest) -> GAMRequest {
        let q = GAMRequest()
        q.customTargeting = r.keyValues
        if !r.collapsible.isEmpty {
            let extras = GADExtras()
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
                GAMInterstitialAd.load(withAdManagerAdUnitID: unit, request: req) { ad, error in
                    if let ad = ad { completion(.success(GmaFullScreen.interstitial(ad))) } else { completion(fail(error)) }
                }
            case .rewarded:
                GADRewardedAd.load(withAdUnitID: unit, request: req) { ad, error in
                    if let ad = ad { completion(.success(GmaFullScreen.rewarded(ad))) } else { completion(fail(error)) }
                }
            case .rewardedInterstitial:
                GADRewardedInterstitialAd.load(withAdUnitID: unit, request: req) { ad, error in
                    if let ad = ad { completion(.success(GmaFullScreen.rewardedInterstitial(ad))) } else { completion(fail(error)) }
                }
            case .appOpen:
                GADAppOpenAd.load(withAdUnitID: unit, request: req) { ad, error in
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

func gmaSource(_ info: GADResponseInfo?) -> String? { info?.loadedAdNetworkResponseInfo?.adSourceName }

func gmaPaid(_ v: GADAdValue) -> (Int64, String, String) {
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
/// (Google holds its delegate weakly); destroy() lets go.
final class GmaFullScreen: NSObject, GADFullScreenContentDelegate, EngineFullScreenAd {
    let source: String?
    private var listener: FullScreenListener?
    private var presentBlock: ((UIViewController, GmaFullScreen) -> Void)?

    private init(source: String?) { self.source = source }

    static func interstitial(_ ad: GAMInterstitialAd) -> GmaFullScreen {
        let w = GmaFullScreen(source: gmaSource(ad.responseInfo))
        ad.fullScreenContentDelegate = w
        ad.paidEventHandler = { [weak w] v in w?.paid(v) }
        w.presentBlock = { vc, _ in ad.present(fromRootViewController: vc) }
        return w
    }
    static func appOpen(_ ad: GADAppOpenAd) -> GmaFullScreen {
        let w = GmaFullScreen(source: gmaSource(ad.responseInfo))
        ad.fullScreenContentDelegate = w
        ad.paidEventHandler = { [weak w] v in w?.paid(v) }
        w.presentBlock = { vc, _ in ad.present(fromRootViewController: vc) }
        return w
    }
    static func rewarded(_ ad: GADRewardedAd) -> GmaFullScreen {
        let w = GmaFullScreen(source: gmaSource(ad.responseInfo))
        ad.fullScreenContentDelegate = w
        ad.paidEventHandler = { [weak w] v in w?.paid(v) }
        w.presentBlock = { vc, me in ad.present(fromRootViewController: vc) { let r = ad.adReward; me.listener?.onReward(type: r.type, amount: r.amount.intValue) } }
        return w
    }
    static func rewardedInterstitial(_ ad: GADRewardedInterstitialAd) -> GmaFullScreen {
        let w = GmaFullScreen(source: gmaSource(ad.responseInfo))
        ad.fullScreenContentDelegate = w
        ad.paidEventHandler = { [weak w] v in w?.paid(v) }
        w.presentBlock = { vc, me in ad.present(fromRootViewController: vc) { let r = ad.adReward; me.listener?.onReward(type: r.type, amount: r.amount.intValue) } }
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

    func destroy() { listener = nil; presentBlock = nil }

    private func paid(_ v: GADAdValue) { let p = gmaPaid(v); listener?.onPaid(valueMicros: p.0, currency: p.1, precision: p.2) }

    // GADFullScreenContentDelegate
    func adWillPresentFullScreenContent(_ ad: GADFullScreenPresentingAd) { listener?.onShown() }
    func adDidRecordClick(_ ad: GADFullScreenPresentingAd) { listener?.onClicked() }
    func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) { listener?.onDismissed() }
    func ad(_ ad: GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        let ns = error as NSError
        listener?.onFailedToShow(code: ns.code, message: ns.localizedDescription)
    }
}

/// A banner: Google's anchored adaptive size for the width given.
final class GmaBanner: NSObject, EngineBanner, GADBannerViewDelegate {
    private let banner: GAMBannerView
    private weak var listener: BannerListener?
    var view: UIView { banner }
    var adSize: CGSize { banner.adSize.size }

    init(unit: String, width: CGFloat, root: UIViewController?, listener: BannerListener) {
        banner = GAMBannerView(adSize: GADCurrentOrientationAnchoredAdaptiveBannerAdSizeWithWidth(width))
        self.listener = listener
        super.init()
        banner.adUnitID = unit
        banner.rootViewController = root
        banner.delegate = self
        banner.paidEventHandler = { [weak self] v in let p = gmaPaid(v); self?.listener?.onPaid(valueMicros: p.0, currency: p.1, precision: p.2) }
    }

    func load(_ request: EngineRequest) { banner.load(GmaEngine.request(request)) }
    func destroy() { banner.delegate = nil; banner.paidEventHandler = nil; banner.removeFromSuperview() }

    func bannerViewDidReceiveAd(_ bannerView: GADBannerView) { listener?.onLoaded(source: gmaSource(bannerView.responseInfo)) }
    func bannerView(_ bannerView: GADBannerView, didFailToReceiveAdWithError error: Error) {
        let ns = error as NSError
        listener?.onFailed(code: ns.code, message: ns.localizedDescription)
    }
    func bannerViewDidRecordImpression(_ bannerView: GADBannerView) { listener?.onImpression() }
    func bannerViewDidRecordClick(_ bannerView: GADBannerView) { listener?.onClicked() }
}
