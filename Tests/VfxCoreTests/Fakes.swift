import Foundation
@testable import VfxCore

/// A stand-in engine: every request is kept, and the test answers it.
final class FakeEngine: FullScreenEngine {
    struct Req { let unit: String; let kv: [String: String]; let cb: (Result<EngineFullScreenAd, EngineError>) -> Void }
    var requests: [Req] = []
    var lastListener: FullScreenListener?
    var destroyed = 0
    func loadFullScreen(format: VfxFormat, unit: String, request: EngineRequest, completion: @escaping (Result<EngineFullScreenAd, EngineError>) -> Void) {
        requests.append(Req(unit: unit, kv: request.keyValues, cb: completion))
    }
    func ad(_ src: String = "Google AdMob") -> FakeAd { FakeAd(engine: self, source: src) }
}

final class FakeAd: EngineFullScreenAd {
    unowned let engine: FakeEngine
    let source: String?
    init(engine: FakeEngine, source: String) { self.engine = engine; self.source = source }
    func show(presenter: AnyObject, listener: FullScreenListener) { engine.lastListener = listener }
    func destroy() { engine.destroyed += 1 }
}

/// A stand-in SDK: time moves only when the test says, and delayed work runs then.
final class FakeEnv: SlotEnv {
    final class Tok { let at: Int64; let block: () -> Void; init(_ at: Int64, _ b: @escaping () -> Void) { self.at = at; block = b } }
    let fake: FakeEngine
    var engine: FullScreenEngine { fake }
    var cfg: Config?
    var t: Int64 = 1_800_000_000_000
    private var queue: [Tok] = []
    var events: [(String, [String: Any?])] = []
    let pacer: Pacer
    var can = true
    var fullScreenShowing = false
    private var running = false

    init(engine: FakeEngine, cfg: Config?) {
        self.fake = engine; self.cfg = cfg
        var now: Int64 = 0
        let box = Box()
        self.pacer = Pacer(store: MapStore(), clock: { box.env?.t ?? now })
        now = 0
        box.env = self
    }
    private final class Box { weak var env: FakeEnv? }

    func now() -> Int64 { t }
    func post(delayMs: Int64, _ block: @escaping () -> Void) -> AnyObject {
        let tok = Tok(t + delayMs, block)
        queue.append(tok)
        if delayMs == 0 { runDue() }
        return tok
    }
    func cancel(_ token: AnyObject) { queue.removeAll { $0 === token } }
    func config() -> Config? { cfg }
    func canRequest() -> Bool { can }
    func keyValues(_ placement: Placement) -> [String: String] { ["vfx_pl": placement.name] }
    func event(_ type: String, _ p: Placement, _ fields: [String: Any?]) { events.append((type, fields)) }
    func onFullScreenClosed() {}
    /// Prebid: the test answers when it likes (nil: not bid for).
    var prebidAsk: ((Placement, @escaping ([String: String]) -> Void) -> Void)?
    func prebid(_ placement: Placement, _ done: @escaping ([String: String]) -> Void) {
        if let ask = prebidAsk { ask(placement, done) } else { done([:]) }
    }
    func advance(_ ms: Int64) { t += ms; runDue() }
    private func runDue() {
        if running { return }
        running = true
        while let due = queue.filter({ $0.at <= t }).min(by: { $0.at < $1.at }) {
            queue.removeAll { $0 === due }
            due.block()
        }
        running = false
    }
    func types() -> [String] { events.map { $0.0 } }
}
