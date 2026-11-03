import Foundation

/// A small key-value store (UserDefaults in the app, a dictionary in tests).
public protocol KeyValueStore: AnyObject {
    func getString(_ key: String) -> String?
    func putString(_ key: String, _ value: String?)
}

public extension KeyValueStore {
    func getLong(_ key: String, _ def: Int64) -> Int64 { getString(key).flatMap { Int64($0) } ?? def }
    func putLong(_ key: String, _ value: Int64) { putString(key, String(value)) }
}

public final class MapStore: KeyValueStore {
    public var map: [String: String] = [:]
    public init() {}
    public func getString(_ key: String) -> String? { map[key] }
    public func putString(_ key: String, _ value: String?) { if let v = value { map[key] = v } else { map.removeValue(forKey: key) } }
}

public final class DefaultsStore: KeyValueStore {
    private let d: UserDefaults
    public init(_ d: UserDefaults = UserDefaults(suiteName: "com.visionforgex.sdk") ?? .standard) { self.d = d }
    public func getString(_ key: String) -> String? { d.string(forKey: key) }
    public func putString(_ key: String, _ value: String?) { if let v = value { d.set(v, forKey: key) } else { d.removeObject(forKey: key) } }
}

/// Whether a full-screen ad may be shown now, by the placement's cap and the app's gap between full-screen ads.
/// What must survive a restart (when each placement last showed, its shows in the last day, the last
/// full-screen ad) is kept in the store; the session's counts are not.
public final class Pacer {
    private let store: KeyValueStore
    private let clock: () -> Int64
    private let calendar: () -> Calendar
    private var sessionStart: Int64 = 0
    private var sessionNumber = 0
    private var perSession: [String: Int] = [:]
    private var eligibleCalls: [String: Int] = [:]

    public static let last = "vfx.p.last."
    public static let times = "vfx.p.ts."
    public static let lastFull = "vfx.p.lastFull"

    public init(store: KeyValueStore, clock: @escaping () -> Int64, calendar: @escaping () -> Calendar = { Calendar.current }) {
        self.store = store; self.clock = clock; self.calendar = calendar
    }

    public func startSession(number: Int, at: Int64) {
        sessionNumber = number; sessionStart = at
        perSession.removeAll(); eligibleCalls.removeAll()
    }

    /// Nil when it may show; otherwise why not (PROTOCOL.md "capped" reasons). A pass counts as one eligible call for everyNth.
    public func check(_ p: Placement, fullGapSec: Int) -> String? {
        let now = clock()
        let c = p.cap
        if c.graceSessions > 0 && sessionNumber <= c.graceSessions { return "grace" }
        if c.graceSec > 0 && now - sessionStart < Int64(c.graceSec) * 1000 { return "grace" }
        if !p.format.isRewarded && fullGapSec > 0 && now - store.getLong(Pacer.lastFull, 0) < Int64(fullGapSec) * 1000 { return "gap" }
        if c.minIntervalSec > 0 && now - store.getLong(Pacer.last + p.name, 0) < Int64(c.minIntervalSec) * 1000 { return "interval" }
        if c.maxPerSession > 0 && (perSession[p.name] ?? 0) >= c.maxPerSession { return "session" }
        if c.maxPerHour > 0 || c.maxPerDay > 0 {
            let ts = timesOf(p.name)
            if c.maxPerHour > 0 && ts.filter({ $0 > now - 3_600_000 }).count >= c.maxPerHour { return "hour" }
            if c.maxPerDay > 0 { let day = dayOf(now); if ts.filter({ dayOf($0) == day }).count >= c.maxPerDay { return "day" } }
        }
        if c.everyNth > 1 {
            let n = (eligibleCalls[p.name] ?? 0) + 1
            eligibleCalls[p.name] = n
            if n % c.everyNth != 0 { return "nth" }
        }
        return nil
    }

    public func recordShow(_ p: Placement) {
        let now = clock()
        store.putLong(Pacer.last + p.name, now)
        if !p.format.isRewarded && p.format.isFullScreen { store.putLong(Pacer.lastFull, now) }
        perSession[p.name] = (perSession[p.name] ?? 0) + 1
        var ts = timesOf(p.name).filter { $0 > now - 2 * 86_400_000 }
        ts = Array(ts.suffix(499)) + [now]
        store.putString(Pacer.times + p.name, ts.map { String($0) }.joined(separator: ","))
    }

    /// Forget every count (a debug screen).
    public func reset(_ names: [String]) {
        store.putString(Pacer.lastFull, nil)
        for n in names { store.putString(Pacer.last + n, nil); store.putString(Pacer.times + n, nil) }
        perSession.removeAll(); eligibleCalls.removeAll()
    }

    public func shownThisSession(_ name: String) -> Int { perSession[name] ?? 0 }
    public func lastShown(_ name: String) -> Int64 { store.getLong(Pacer.last + name, 0) }

    private func timesOf(_ name: String) -> [Int64] {
        (store.getString(Pacer.times + name) ?? "").split(separator: ",").compactMap { Int64($0) }
    }
    private func dayOf(_ t: Int64) -> Int {
        let c = calendar()
        let d = Date(timeIntervalSince1970: Double(t) / 1000)
        return c.component(.year, from: d) * 1000 + (c.ordinality(of: .day, in: .year, for: d) ?? 0)
    }
}
