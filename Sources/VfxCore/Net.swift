import Foundation

public enum VLog {
    public static var level: VfxLogLevel = .warn
    private static func out(_ l: String, _ m: String) { print("[VisionForgeX] \(l): \(m)") }
    public static func e(_ m: String) { if level >= .error { out("E", m) } }
    public static func w(_ m: String) { if level >= .warn { out("W", m) } }
    public static func i(_ m: String) { if level >= .info { out("I", m) } }
    public static func d(_ m: String) { if level >= .debug { out("D", m) } }
}

public struct HttpResult {
    public let code: Int
    public let body: String
    public let etag: String?
    public init(code: Int, body: String, etag: String?) { self.code = code; self.body = body; self.etag = etag }
}

/// Plain URLSession, no library added to the app. The calls block: make them from a background queue.
public enum Http {
    public static var userAgent = "VisionForgeX-iOS/\(vfxVersion)"

    public static func get(_ url: String, etag: String?) -> HttpResult { request(url, method: "GET", body: nil, etag: etag) }
    public static func postJson(_ url: String, _ json: String) -> HttpResult { request(url, method: "POST", body: json.data(using: .utf8), etag: nil) }

    private static func request(_ url: String, method: String, body: Data?, etag: String?) -> HttpResult {
        guard let u = URL(string: url) else { return HttpResult(code: 0, body: "", etag: nil) }
        var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.httpMethod = method
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let e = etag { r.setValue(e, forHTTPHeaderField: "If-None-Match") }
        if let b = body { r.httpBody = b; r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        let sem = DispatchSemaphore(value: 0)
        var result = HttpResult(code: 0, body: "", etag: nil)
        let task = URLSession.shared.dataTask(with: r) { data, resp, err in
            if let h = resp as? HTTPURLResponse {
                result = HttpResult(code: h.statusCode, body: data.flatMap { String(data: $0, encoding: .utf8) } ?? "", etag: h.value(forHTTPHeaderField: "ETag"))
            } else { VLog.d("\(method) \(url) failed: \(err?.localizedDescription ?? "no answer")") }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 15) == .timedOut { task.cancel() }
        return result
    }
}
