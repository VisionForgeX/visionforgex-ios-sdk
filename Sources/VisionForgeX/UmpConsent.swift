import UIKit
import UserMessagingPlatform

/// Google's consent flow (User Messaging Platform).
final class UmpConsent: ConsentEngine {
    func gather(from vc: UIViewController, underAge: Bool, debugEea: Bool, hashedIds: [String], done: @escaping (Bool, String?) -> Void) {
        let params = UMPRequestParameters()
        params.tagForUnderAgeOfConsent = underAge
        if debugEea {
            let d = UMPDebugSettings()
            d.testDeviceIdentifiers = hashedIds
            d.geography = .EEA
            params.debugSettings = d
        }
        UMPConsentInformation.sharedInstance.requestConsentInfoUpdate(with: params) { err in
            if let err = err { done(UMPConsentInformation.sharedInstance.canRequestAds, err.localizedDescription); return }
            UMPConsentForm.loadAndPresentIfRequired(from: vc) { err2 in
                done(UMPConsentInformation.sharedInstance.canRequestAds, err2?.localizedDescription)
            }
        }
    }
    func canRequestAds() -> Bool { UMPConsentInformation.sharedInstance.canRequestAds }
    func privacyOptionsRequired() -> Bool { UMPConsentInformation.sharedInstance.privacyOptionsRequirementStatus == .required }
    func showPrivacyOptions(from vc: UIViewController, done: @escaping (String?) -> Void) {
        UMPConsentForm.presentPrivacyOptionsForm(from: vc) { err in done(err?.localizedDescription) }
    }
    func reset() { UMPConsentInformation.sharedInstance.reset() }
}
