import Foundation

/// Decides which notifications a limit reading calls for. Pure logic: nothing here shows anything.
/// Every kind of notification fires at most once per limit window.
enum Alerts {
    struct Rules: Equatable {
        var level: Double      // warn when a limit passes this %; 0 = no such warning ("reached" still fires at 100 %)
        var pace: Bool         // warn when a limit is on pace to run out before it resets
        var reset: Bool        // say when a limit that had a warning has reset
    }

    /// What has already been said about one limit's current window.
    struct Entry: Codable {
        var r: Double                  // the window's reset time
        var level = false, full = false, pace = false
        var warned: Bool { level || full || pace }
    }

    struct State: Codable { var limits: [String: Entry] = [:] }

    struct Event { var key: String; var title: String; var body: String }

    /// Pace warnings wait until this much is used, so a short burst early in a window does not raise one.
    static let paceFloor = 30.0
    /// Numbers older than this raise no new warnings (resets are still announced: they go by the clock).
    static let staleAfter: TimeInterval = 20 * 60

    static var file: URL { Paths.support.appendingPathComponent("alerts.json") }
    static func load() -> State {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }
    static func save(_ s: State) {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: file, options: .atomic) }
    }

    /// `account` keys the memory; `label` (an account name) goes in front of the title when there are several accounts.
    static func evaluate(_ snap: LimitSnapshot?, account: String, label: String?, rules: Rules, state: inout State,
                         now: Date = Date()) -> [Event] {
        guard let snap = snap else { return [] }
        var limits: [(key: String, name: String, window: Window, hours: Double)] = []
        if let w = snap.five_hour { limits.append(("five", "5-hour limit", w, 5)) }
        if let w = snap.seven_day { limits.append(("week", "Weekly limit", w, 168)) }
        for m in snap.models ?? [] { limits.append(("model:\(m.name)", "Weekly \(m.name) limit", m.window, 168)) }
        let fresh = now.timeIntervalSince(snap.asOf) <= staleAfter
        let prefix = label.map { "\($0): " } ?? ""
        var out: [Event] = []
        for l in limits {
            let key = "\(account)|\(l.key)", w = l.window
            // A window we warned about is over: its time has come, or the reading belongs to a later window.
            if let e = state.limits[key], now.timeIntervalSince1970 >= e.r || w.resets_at - e.r > 3600 {
                if e.warned, rules.reset {
                    out.append(Event(key: key + "|reset", title: "\(prefix)\(l.name) has reset", body: "You have the full allowance again."))
                }
                state.limits[key] = nil
            }
            guard fresh, w.resetDate > now else { continue }
            var e = state.limits[key] ?? Entry(r: w.resets_at)
            e.r = w.resets_at
            let used = w.used_percentage, pct = Int(used.rounded())
            if used >= 100 {
                if !e.full {
                    out.append(Event(key: key + "|full", title: "\(prefix)\(l.name) reached", body: resetText(w.resetDate, now: now)))
                }
                e.full = true; e.level = true; e.pace = true
            } else {
                if rules.level > 0, used >= rules.level, !e.level {
                    out.append(Event(key: key + "|level", title: "\(prefix)\(l.name) at \(pct)%", body: resetText(w.resetDate, now: now)))
                    e.level = true
                }
                if rules.pace, !e.pace, used >= paceFloor,
                   let full = Pace.project(used: used, resetsAt: w.resets_at, window: l.hours * 3600, now: now)?.runsOut {
                    out.append(Event(key: key + "|pace", title: "\(prefix)\(l.name) on pace to run out",
                                     body: "At \(pct)% now; full by \(clock(full, now: now)) at this pace. \(resetText(w.resetDate, now: now))"))
                    e.pace = true
                }
            }
            if e.warned || state.limits[key] != nil { state.limits[key] = e }
        }
        return out
    }

    static func clock(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }

    static func resetText(_ d: Date, now: Date) -> String {
        let s = Int(d.timeIntervalSince(now))
        if s < 3600 { return "Resets in \(max(1, s / 60)) min." }
        if s < 86400 { return "Resets in \(s / 3600) h \((s % 3600) / 60) min." }
        return "Resets \(clock(d, now: now))."
    }
}
