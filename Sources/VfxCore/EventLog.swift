import Foundation

/// Events (PROTOCOL.md section 2): kept in memory and in a file, so a crash or a closed app loses none,
/// and sent in batches. "ses" and "paid" are always sent; the rest only when the install is in the
/// sample. A 4xx answer drops the batch (it would fail again); no answer or a 5xx keeps it.
public final class EventLog {
    public struct Header {
        public var key, install, session, sdk, appVersion, os, device, country, ab: String
        public var sample: Double
        public init(key: String, install: String, session: String, sdk: String, appVersion: String, os: String, device: String, country: String, ab: String, sample: Double) {
            self.key = key; self.install = install; self.session = session; self.sdk = sdk; self.appVersion = appVersion; self.os = os; self.device = device; self.country = country; self.ab = ab; self.sample = sample
        }
    }

    private let fileURL: URL?
    private let clock: () -> Int64
    private let io: (@escaping () -> Void) -> Void
    private let send: (String, String) -> HttpResult
    private let platform: String
    private let lock = NSLock()
    private struct Ev { let id: Int; let json: [String: Any] }
    private var pending: [Ev] = []
    private var nextId = 0
    private var sending = false
    public var inSample = true
    /// The last events, newest first, for a debug screen.
    public private(set) var recent: [String] = []
    public static let maxKept = 2000

    public init(dir: URL?, platform: String = "ios", clock: @escaping () -> Int64, io: @escaping (@escaping () -> Void) -> Void,
                send: @escaping (String, String) -> HttpResult = { Http.postJson($0, $1) }) {
        self.fileURL = dir?.appendingPathComponent("events.jsonl")
        self.platform = platform; self.clock = clock; self.io = io; self.send = send
        // what a previous run did not send
        if let f = fileURL, let text = try? String(contentsOf: f, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let d = line.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { nextId += 1; pending.append(Ev(id: nextId, json: o)) }
            }
        }
    }

    public func add(_ type: String, _ fields: [String: Any?]) {
        if !inSample && type != "ses" && type != "paid" { return }
        var e: [String: Any] = ["t": type, "ts": clock()]
        for (k, v) in fields { if let v = v { e[k] = v } }
        lock.lock()
        nextId += 1
        pending.append(Ev(id: nextId, json: e))
        if pending.count > EventLog.maxKept { pending.removeFirst(pending.count - EventLog.maxKept) }
        if let d = try? JSONSerialization.data(withJSONObject: e), let s = String(data: d, encoding: .utf8) {
            recent.insert(s, at: 0)
            if recent.count > 40 { recent.removeLast() }
        }
        lock.unlock()
        io { [weak self] in self?.persist() }
    }

    public func size() -> Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    /// Sends what is waiting, in batches of at most 500. `done` gets how many were accepted.
    public func flush(url: String, header: Header, done: ((Int) -> Void)? = nil) {
        lock.lock()
        if sending || pending.isEmpty { lock.unlock(); done?(0); return }
        sending = true
        let batchEv = Array(pending.prefix(500))
        let batch = batchEv.map { $0.json }
        let sentIds = Set(batchEv.map { $0.id })
        lock.unlock()
        io { [weak self] in
            guard let self = self else { return }
            var accepted = 0
            let body: [String: Any] = ["k": header.key, "i": header.install, "s": header.session, "sv": header.sdk, "p": self.platform,
                "av": header.appVersion, "os": header.os, "dev": header.device, "c": header.country, "ab": header.ab, "sr": header.sample, "e": batch]
            if let d = try? JSONSerialization.data(withJSONObject: body), let json = String(data: d, encoding: .utf8) {
                let r = self.send(url, json)
                if r.code >= 200 && r.code <= 499 {
                    self.lock.lock()
                    self.pending.removeAll { sentIds.contains($0.id) }
                    self.lock.unlock()
                    if r.code < 300 { accepted = batch.count } else { VLog.w("Events refused (\(r.code)): \(r.body.prefix(200))") }
                    self.persist()
                }
            }
            self.lock.lock(); self.sending = false; self.lock.unlock()
            done?(accepted)
        }
    }

    private func persist() {
        guard let f = fileURL else { return }
        lock.lock()
        let lines = pending.compactMap { e -> String? in (try? JSONSerialization.data(withJSONObject: e.json)).flatMap { String(data: $0, encoding: .utf8) } }
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
        } catch { /* kept in memory; the next write may work */ }
    }
}
