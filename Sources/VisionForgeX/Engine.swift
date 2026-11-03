import UIKit
import VfxCore

/// What the Sdk needs from the ad engine beyond full-screen ads. Only the Google engine exists; the
/// protocol keeps a second engine (Google's next SDK) from touching the rest.
protocol AdEngine: FullScreenEngine {
    var name: String { get }
    func initialize(settings: EngineSettings, done: @escaping () -> Void)
    func apply(settings: EngineSettings)
    func newBanner(unit: String, width: CGFloat, root: UIViewController?, listener: BannerListener) -> EngineBanner
    func setMuted(_ muted: Bool)
    func openInspector(from vc: UIViewController)
    var consent: ConsentEngine { get }
}

struct EngineSettings {
    var childDirected: Bool
    var underAge: Bool
    var maxRating: String
    var testDeviceIds: [String]
}

protocol EngineBanner: AnyObject {
    var view: UIView { get }
    /// The size Google chose for the last ad (zero before the first).
    var adSize: CGSize { get }
    func load(_ request: EngineRequest)
    func destroy()
}

protocol BannerListener: AnyObject {
    func onLoaded(source: String?)
    func onFailed(code: Int, message: String)
    func onImpression()
    func onClicked()
    func onPaid(valueMicros: Int64, currency: String, precision: String)
}

protocol ConsentEngine: AnyObject {
    /// Asks for consent where the law needs it (shows Google's form when required), then answers.
    func gather(from vc: UIViewController, underAge: Bool, debugEea: Bool, hashedIds: [String], done: @escaping (_ canRequestAds: Bool, _ error: String?) -> Void)
    func canRequestAds() -> Bool
    func privacyOptionsRequired() -> Bool
    func showPrivacyOptions(from vc: UIViewController, done: @escaping (String?) -> Void)
    func reset()
}

enum Presenter {
    /// The screen in front: the key window's top-most presented view controller.
    static func top() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let pool = active.isEmpty ? scenes : active
        let window = pool.flatMap { $0.windows }.first { $0.isKeyWindow } ?? pool.first?.windows.first
        var vc = window?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}
