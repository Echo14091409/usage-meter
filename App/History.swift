import Foundation

/// Every weekly-limit reading the app gets, saved so it can show how much of the weekly limit each day used.
/// Covers the whole account (chat, apps, phone, any computer), because the readings come from Anthropic's servers.
struct Reading: Codable {
    var t: Double      // when the numbers were current (Unix seconds)
    var s: Double      // weekly used %
    var r: Double      // weekly resets_at (Unix seconds)
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
    static func record(_ w: Window, at t: Date) {
        var a = load()
        let x = Reading(t: t.timeIntervalSince1970, s: w.used_percentage, r: w.resets_at)
        if let last = a.last {
            if x.t <= last.t { return }
            if x.s == last.s, sameWeek(x, last), x.t - last.t < 30 * 60 { return }
        }
        a.append(x)
        let cutoff = Date().timeIntervalSince1970 - keepDays * 86400
        a.removeAll { $0.t < cutoff }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(a) { try? d.write(to: file, options: .atomic) }
    }

    /// Reset times can wobble by a few seconds between reports.
    static func sameWeek(_ a: Reading, _ b: Reading) -> Bool { abs(a.r - b.r) < 3600 }

    /// % of the weekly limit used on each of the last `days` calendar days, oldest first.
    /// `nil` = no readings cover that day yet. A rise between two readings counts on the later reading's day;
    /// after a weekly reset, the new week's % counts as used since the reset.
    static func daily(_ a: [Reading], days: Int = 7, now: Date = Date()) -> [(day: Date, pct: Double?)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var sums: [Date: Double] = [:]
        var seen = Set<Date>()
        for (i, b) in a.enumerated() {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: b.t))
            seen.insert(day)
            guard i > 0 else { continue }
            let p = a[i - 1]
            let delta = sameWeek(p, b) ? max(0, b.s - p.s) : (b.r > p.r ? b.s : 0)
            sums[day, default: 0] += delta
        }
        let first = a.first.map { cal.startOfDay(for: Date(timeIntervalSince1970: $0.t)) }
        return (0..<days).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            let covered = first.map { d >= $0 } ?? false
            return (d, covered ? (sums[d] ?? 0) : (seen.contains(d) ? 0 : nil))
        }
    }
}
