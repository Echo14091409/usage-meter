import Foundation

/// One model reply as recorded by Claude Code in ~/.claude/projects/**/*.jsonl.
struct Reply {
    let time: Date
    let model: String
    let input: Int, output: Int, cacheWrite: Int, cacheRead: Int
    var total: Int { input + output + cacheWrite + cacheRead }
    /// Rough relative cost (API list-price ratios), used only to split a known % across days.
    var weight: Double {
        let m = model.lowercased()
        let inRate = m.contains("haiku") ? 1.0 : m.contains("sonnet") ? 3.0 : 5.0
        return inRate * (Double(input) + 1.25 * Double(cacheWrite) + 0.1 * Double(cacheRead) + 5 * Double(output))
    }
}

struct Totals {
    var replies = 0, input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var total: Int { input + output + cacheWrite + cacheRead }
    mutating func add(_ r: Reply) {
        replies += 1; input += r.input; output += r.output; cacheWrite += r.cacheWrite; cacheRead += r.cacheRead
    }
}

struct UsageSummary {
    var last5h = Totals(), today = Totals(), last7d = Totals()
    var byModel7d: [(model: String, totals: Totals)] = []
    var byDay: [(day: Date, total: Int)] = []        // last 7 calendar days, oldest first
    var firstIn5h: Date?                              // oldest reply inside the 5-hour window
    var lastReply: Date?
    var files = 0
    var activity: [(time: Date, weight: Double)] = []   // every reply in the last 14 days, for estimates
}

/// Reads Claude Code's local session logs. Only the `usage` numbers, model and time are kept;
/// message text is never decoded into anything that is stored or shown.
final class UsageLog {
    let root: URL
    private var cache: [String: (mtime: Date, replies: [String: Reply])] = [:]

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Parses one file. Streaming writes the same reply several times, so replies are keyed by
    /// message id + request id and the last copy wins (it carries the final token counts).
    private func parse(_ url: URL) -> [String: Reply] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var out: [String: Reply] = [:]
        let needle = Data("\"usage\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: needle) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let time = Self.iso.date(from: ts) ?? Self.isoPlain.date(from: ts) else { continue }
            let model = msg["model"] as? String ?? "unknown"
            if model == "<synthetic>" { continue }
            let key = "\(msg["id"] as? String ?? "")|\(obj["requestId"] as? String ?? "")"
            func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
            out[key] = Reply(time: time, model: model, input: n("input_tokens"), output: n("output_tokens"),
                             cacheWrite: n("cache_creation_input_tokens"), cacheRead: n("cache_read_input_tokens"))
        }
        return out
    }

    /// Re-reads only files changed since the last scan.
    func summary(now: Date = Date()) -> UsageSummary {
        let fm = FileManager.default
        var seen = Set<String>()
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let path = url.path
                seen.insert(path)
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if let c = cache[path], c.mtime == mtime { continue }
                cache[path] = (mtime, parse(url))
            }
        }
        cache = cache.filter { seen.contains($0.key) }

        var all: [String: Reply] = [:]                 // the same reply can appear in a resumed session's file too
        for (_, c) in cache { all.merge(c.replies) { a, _ in a } }

        var s = UsageSummary()
        s.files = cache.count
        let cal = Calendar.current
        let start5h = now.addingTimeInterval(-5 * 3600)
        let start7d = now.addingTimeInterval(-7 * 86400)
        let startToday = cal.startOfDay(for: now)
        var models: [String: Totals] = [:]
        var days: [Date: Int] = [:]
        for r in all.values {
            if s.lastReply == nil || r.time > s.lastReply! { s.lastReply = r.time }
            if r.time >= start5h {
                s.last5h.add(r)
                if s.firstIn5h == nil || r.time < s.firstIn5h! { s.firstIn5h = r.time }
            }
            if r.time >= startToday { s.today.add(r) }
            if r.time >= start7d { s.last7d.add(r); models[r.model, default: Totals()].add(r) }
            if r.time >= now.addingTimeInterval(-14 * 86400) { s.activity.append((r.time, r.weight)) }
            let d = cal.startOfDay(for: r.time)
            if d > cal.date(byAdding: .day, value: -7, to: startToday)! { days[d, default: 0] += r.total }
        }
        s.byModel7d = models.map { ($0.key, $0.value) }.sorted { $0.totals.output > $1.totals.output }
        s.byDay = (0..<7).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: startToday)!
            return (d, days[d] ?? 0)
        }
        return s
    }
}

func short(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.1fk", d / 1e3) }
    return "\(n)"
}
