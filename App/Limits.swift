import Foundation

/// Plan limits as Claude Code reports them to a status line command (documented `rate_limits` field):
/// https://code.claude.com/docs/en/statusline
struct Window: Codable {
    var used_percentage: Double
    var resets_at: Double              // Unix seconds
    var resetDate: Date { Date(timeIntervalSince1970: resets_at) }
}

struct LimitSnapshot: Codable {
    var five_hour: Window?
    var seven_day: Window?
    var updated_at: Double            // when the status line last ran
    var as_of: Double?                // when the session behind it last got a reply = how fresh the numbers are
    var updated: Date { Date(timeIntervalSince1970: updated_at) }
    /// 0 / missing = age unknown (shown as out of date).
    var asOf: Date { Date(timeIntervalSince1970: as_of ?? 0) }
}

enum Paths {
    /// UM_HOME redirects every path, for tests.
    static let home = ProcessInfo.processInfo.environment["UM_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/Usage Meter")
    static let snapshot = support.appendingPathComponent("limits.json")
    static let claudeSettings = home.appendingPathComponent(".claude/settings.json")
}

enum Limits {
    static func load() -> LimitSnapshot? {
        guard let d = try? Data(contentsOf: Paths.snapshot) else { return nil }
        return try? JSONDecoder().decode(LimitSnapshot.self, from: d)
    }

    /// Time of the last model reply in a session transcript (read from the end of the file only).
    static func lastReply(in path: String) -> Date? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: Data("\"assistant\"".utf8)) != nil,
                  let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  o["type"] as? String == "assistant", let t = o["timestamp"] as? String,
                  let d = iso.date(from: t) ?? ISO8601DateFormatter().date(from: t) else { continue }
            return d
        }
        return nil
    }

    /// `UsageMeter --statusline`: Claude Code pipes its status JSON in. Save the limits, print one short line.
    static func statusLineMain() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        var parts: [String] = []
        if let model = (obj["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
        if let rl = obj["rate_limits"] as? [String: Any] {
            func window(_ k: String) -> Window? {
                guard let w = rl[k] as? [String: Any],
                      let p = (w["used_percentage"] as? NSNumber)?.doubleValue,
                      let r = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
                return Window(used_percentage: p, resets_at: r)
            }
            // Status lines also re-render in idle sessions, which still carry the limits from their last reply.
            // Date the numbers by that reply, and never let an older session overwrite fresher numbers.
            let now = Date()
            let prev = load()
            let asOf = (obj["transcript_path"] as? String).flatMap(lastReply(in:)) ?? Date(timeIntervalSince1970: 0)
            func keep(_ w: Window?) -> Window? { w.flatMap { $0.resetDate > now ? $0 : nil } }
            let newer = prev == nil || asOf >= prev!.asOf.addingTimeInterval(-1)
            let snap = newer
                ? LimitSnapshot(five_hour: window("five_hour") ?? keep(prev?.five_hour),
                                seven_day: window("seven_day") ?? keep(prev?.seven_day),
                                updated_at: now.timeIntervalSince1970, as_of: asOf.timeIntervalSince1970)
                : prev!
            if newer && (snap.five_hour != nil || snap.seven_day != nil) {
                try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
                if let d = try? JSONEncoder().encode(snap) { try? d.write(to: Paths.snapshot, options: .atomic) }
            }
            if let w = snap.five_hour { parts.append("5h \(Int(w.used_percentage.rounded()))%") }
            if let w = snap.seven_day { parts.append("7d \(Int(w.used_percentage.rounded()))%") }
        }
        print(parts.joined(separator: " · "))
    }

    // MARK: hooking into Claude Code's settings.json

    static var command: String { "\"\(Bundle.main.executablePath ?? "")\" --statusline" }

    enum Hook { case none, ours, other(String), unreadable }

    static func hookState() -> Hook {
        guard let d = try? Data(contentsOf: Paths.claudeSettings) else { return .none }
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .unreadable }
        guard let sl = j["statusLine"] as? [String: Any] else { return .none }
        let cmd = sl["command"] as? String ?? ""
        return cmd.contains("--statusline") && cmd.contains("UsageMeter") ? .ours : .other(cmd)
    }

    /// Adds or removes our status line. Keeps a backup and never replaces someone else's status line.
    static func setHook(_ on: Bool) throws {
        let fm = FileManager.default
        var j: [String: Any] = [:]
        if let d = try? Data(contentsOf: Paths.claudeSettings) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                throw Problem("~/.claude/settings.json is not valid JSON; not touching it.")
            }
            j = parsed
            let backup = Paths.claudeSettings.deletingLastPathComponent().appendingPathComponent("settings.json.bak-usage-meter")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: Paths.claudeSettings, to: backup)
        }
        switch (on, hookState()) {
        case (true, .other(let cmd)):
            throw Problem("Claude Code already has a status line (\(cmd)). Remove it first to use Usage Meter's.")
        case (true, _):
            j["statusLine"] = ["type": "command", "command": command, "padding": 0]
        case (false, .ours):
            j.removeValue(forKey: "statusLine")
        case (false, _):
            return
        }
        try fm.createDirectory(at: Paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: Paths.claudeSettings, options: .atomic)
    }
}

struct Problem: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
