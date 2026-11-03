import Foundation

/// An error from an ad engine: Google's error code and message.
public struct EngineError: Error {
    public let code: Int
    public let message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }
}

/// One request: the key-values, and banner-only extras.
public struct EngineRequest {
    public var keyValues: [String: String]
    public var collapsible: String
    public init(keyValues: [String: String], collapsible: String = "") { self.keyValues = keyValues; self.collapsible = collapsible }
}

/// What the SDK needs from an ad engine for full-screen ads. The one that talks to Google Mobile Ads lives in
/// the VisionForgeX target. The SDK decides what to request and when; the engine only requests, shows and reports.
public protocol FullScreenEngine: AnyObject {
    /// Loads one ad. The completion runs once, on any thread.
    func loadFullScreen(format: VfxFormat, unit: String, request: EngineRequest, completion: @escaping (Result<EngineFullScreenAd, EngineError>) -> Void)
}

/// A loaded full-screen ad.
public protocol EngineFullScreenAd: AnyObject {
    /// Which network filled it (Google's ad source name), when known.
    var source: String? { get }
    /// `presenter` is the screen to show from (a UIViewController, on iOS).
    func show(presenter: AnyObject, listener: FullScreenListener)
    func destroy()
}

public protocol FullScreenListener: AnyObject {
    func onShown()
    func onClicked()
    func onDismissed()
    func onFailedToShow(code: Int, message: String)
    func onReward(type: String, amount: Int)
    func onPaid(valueMicros: Int64, currency: String, precision: String)
}
