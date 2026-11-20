import Foundation

/// Every weekly-limit reading the app gets, saved so it can show how much of the weekly limit each day used.
/// Covers the whole account (chat, apps, phone, any computer), because the readings come from Anthropic's servers.
struct Reading: Codable {
    var t: Double      // when the numbers were current (Unix seconds)
    var s: Double      // weekly used %
    var r: Double      // weekly resets_at (Unix seconds)
    // Since 0.9.0 (missing in older entries, and `m` in status line reports, which carry no model figures):
    var f: Double? = nil            // 5-hour used %
    var fr: Double? = nil           // 5-hour resets_at
    var m: [String: Double]? = nil  // model-specific weekly used %, by model name
}

enum History {
    static var file: URL { Paths.support.appendingPathComponent("history.json") }
    static let keepDays = 60.0

    static func load() -> [Reading] {
        guard let d = try? Data(contentsOf: file),
              let a = try? JSONDecoder().decode([Reading].self, from: d) else { return [] }
        return a.sorted { $0.t < $1.t }
    }

    /// Adds a fresh reading. Unchanged readings are kept at most every 30 minutes so the file stays small.
    static func record(five: Window?, seven w: Window, models: [ModelWindow]?, at t: Date) {
        var a = load()
        let now = t.timeIntervalSince1970
        let five = five.flatMap { $0.resets_at > now ? $0 : nil }      // a window that has reset says nothing
        let x = Reading(t: now, s: w.used_percentage, r: w.resets_at, f: five?.used_percentage, fr: five?.resets_at,
                        m: models.map { Dictionary($0.map { ($0.name, $0.used_percentage) }) { a, _ in a } })
        if let last = a.last {
            if x.t <= last.t { return }
            // A report without 5-hour or model figures does not count as a change to them.
            let same = x.s == last.s && (x.f == nil || x.f == last.f) && (x.m == nil || x.m == last.m)
            if same, sameWeek(x, last), x.t - last.t < 30 * 60 { return }
        }
        a.append(x)
        let cutoff = Date().timeIntervalSince1970 - keepDays * 86400
        a.removeAll { $0.t < cutoff }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(a) { try? d.write(to: file, options: .atomic) }
    }

    /// Reset times can wobble by a few seconds between reports.
    static func sameWeek(_ a: Reading, _ b: Reading) -> Bool { abs(a.r - b.r) < 3600 }

    struct Day { var day: Date; var pct: Double?; var estimated = false }

    /// % of the weekly limit used on each of the last `days` calendar days, oldest first.
    /// `pct == nil`: nothing known about that day. A rise between two readings counts on the later reading's day;
    /// after a weekly reset, the new week's % counts as used since the reset.
    /// Before the first reading, the % its week had already used is split across that week's days in proportion
    /// to Claude Code activity on this Mac (`estimated`), since no earlier readings exist.
    static func daily(_ a: [Reading], activity: [(time: Date, weight: Double)] = [], days: Int = 7,
                      now: Date = Date()) -> [Day] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var sums: [Date: Double] = [:], est: [Date: Double] = [:]
        var known = Set<Date>()
        for (i, b) in a.enumerated() where i > 0 {
            let p = a[i - 1]
            let delta = sameWeek(p, b) ? max(0, b.s - p.s) : (b.r > p.r ? b.s : 0)
            sums[cal.startOfDay(for: Date(timeIntervalSince1970: b.t)), default: 0] += delta
        }
        var knownFrom: Date?                                // real data covers everything after this moment
        if let f = a.first {
            let firstT = Date(timeIntervalSince1970: f.t)
            let weekStart = Date(timeIntervalSince1970: f.r - 7 * 86400)
            knownFrom = firstT
            let inWeek = activity.filter { $0.time >= weekStart && $0.time <= firstT }
            let total = inWeek.reduce(0) { $0 + $1.weight }
            if total > 0 {
                for x in inWeek { est[cal.startOfDay(for: x.time), default: 0] += f.s * x.weight / total }
                knownFrom = weekStart
            }
            var d = cal.startOfDay(for: knownFrom!)
            while d <= today { known.insert(d); d = cal.date(byAdding: .day, value: 1, to: d)! }
        }
        return (0..<days).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            guard known.contains(d) else { return Day(day: d, pct: nil) }
            return Day(day: d, pct: (sums[d] ?? 0) + (est[d] ?? 0), estimated: (est[d] ?? 0) > 0.05)
        }
    }

    struct HourRow { var day: Date; var hours: [Double?] }

    /// % of the weekly limit used in each hour of the last `days` calendar days, oldest day first.
    /// Same rule as `daily`: a rise counts in the later reading's hour. nil = before the first reading or still to come.
    static func hourly(_ a: [Reading], days: Int = 14, now: Date = Date(), calendar cal: Calendar = .current) -> [HourRow] {
        func hour(_ t: Double) -> Date {
            let d = Date(timeIntervalSince1970: t)
            return cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: d)) ?? d
        }
        var sums: [Date: Double] = [:]
        for (i, b) in a.enumerated() where i > 0 {
            let p = a[i - 1]
            sums[hour(b.t), default: 0] += sameWeek(p, b) ? max(0, b.s - p.s) : (b.r > p.r ? b.s : 0)
        }
        let first = a.first.map { hour($0.t) }, last = hour(now.timeIntervalSince1970)
        let today = cal.startOfDay(for: now)
        return (0..<days).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            return HourRow(day: d, hours: (0..<24).map { h in
                guard let t = cal.date(byAdding: .hour, value: h, to: d), let f = first, t >= f, t <= last else { return nil }
                return sums[t] ?? 0
            })
        }
    }
}

/// Where a limit window ends up if use carries on at the window's average rate so far.
enum Pace {
    struct Projection {
        var atReset: Double        // projected % used when the window resets
        var runsOut: Date?         // when it reaches 100 %, if that is before the reset
    }

    /// nil when there is nothing sensible to say: under a tenth of the window has passed, nothing is used yet,
    /// or the window has already reset.
    static func project(used: Double, resetsAt: Double, window: TimeInterval, now: Date = Date()) -> Projection? {
        let start = resetsAt - window, t = now.timeIntervalSince1970
        let elapsed = t - start
        guard t < resetsAt, elapsed >= window / 10, used > 0 else { return nil }
        let atReset = used * window / elapsed
        let full = start + elapsed * 100 / used
        return Projection(atReset: atReset, runsOut: used < 100 && full < resetsAt ? Date(timeIntervalSince1970: full) : nil)
    }
}
