import Foundation

/// Plan limits as Claude Code reports them to a status line command (documented `rate_limits` field):
/// https://code.claude.com/docs/en/statusline
struct Window: Codable {
    var used_percentage: Double
    var resets_at: Double              // Unix seconds
    var resetDate: Date { Date(timeIntervalSince1970: resets_at) }
}

/// A weekly limit that counts one model only (for example Fable), as `/usage` in Claude Code reports it.
struct ModelWindow: Codable {
    var name: String
    var used_percentage: Double
    var resets_at: Double              // Unix seconds
    var as_of: Double                  // when this figure was read
    var window: Window { Window(used_percentage: used_percentage, resets_at: resets_at) }
    var asOf: Date { Date(timeIntervalSince1970: as_of) }
}

struct LimitSnapshot: Codable {
    var five_hour: Window?
    var seven_day: Window?
    /// Model-specific weekly limits; missing or empty when the plan has none.
    var models: [ModelWindow]?
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

    /// Saves new numbers unless the stored ones are fresher. A window missing from the new report is kept
    /// from the old snapshot until it resets. `models` nil = this report says nothing about model limits
    /// (keep the stored ones until they reset); an empty list = the plan has none. Returns what is stored afterwards.
    @discardableResult
    static func store(five: Window?, seven: Window?, models: [ModelWindow]? = nil, asOf: Date) -> LimitSnapshot {
        let now = Date()
        let prev = load()
        func keep(_ w: Window?) -> Window? { w.flatMap { $0.resetDate > now ? $0 : nil } }
        guard prev == nil || asOf >= prev!.asOf.addingTimeInterval(-1) else { return prev! }
        let snap = LimitSnapshot(five_hour: five ?? keep(prev?.five_hour), seven_day: seven ?? keep(prev?.seven_day),
                                 models: models ?? prev?.models?.filter { $0.window.resetDate > now },
                                 updated_at: now.timeIntervalSince1970, as_of: asOf.timeIntervalSince1970)
        if snap.five_hour != nil || snap.seven_day != nil {
            try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snap) { try? d.write(to: Paths.snapshot, options: .atomic) }
        }
        if let w = seven, w.resetDate > now { History.record(w, at: asOf) }
        return snap
    }

    // MARK: live check through Claude Code itself

    /// Where the `claude` command lives. GUI apps do not get the shell's PATH, so try the usual places,
    /// then ask a login shell.
    static func claudePath() -> String? {
        let home = Paths.home.path
        let fm = FileManager.default
        for p in ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                  "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude"] where fm.isExecutableFile(atPath: p) {
            return p
        }
        let r = runProcess("/bin/zsh", ["-lc", "command -v claude"], timeout: 10)
        let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: p) ? p : nil
    }

    /// Sends one tiny message to the smallest model through Claude Code (your own subscription, no tools,
    /// no MCP, no settings, nothing saved) and reads the `rate_limit_event` Claude Code prints in
    /// stream-json mode. Costs about 1,000 tokens of your 5-hour allowance.
    static func fetchLive() throws -> LimitSnapshot {
        guard let claude = claudePath() else { throw Problem("Claude Code (the claude command) was not found.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-meter-check")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prompt = "Reply with the single word ok."
        let r = runProcess(claude, ["-p", prompt, "--model", "haiku", "--output-format", "stream-json", "--verbose",
                                    "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                                    "--no-session-persistence", "--system-prompt", prompt],
                           cwd: dir, timeout: 90)
        var five: Window?, seven: Window?
        for line in r.out.split(separator: "\n") where line.contains("rate_limit_event") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let info = o["rate_limit_info"] as? [String: Any],
                  let wins = info["unifiedWindows"] as? [String: Any] else { continue }
            func w(_ k: String) -> Window? {
                guard let x = wins[k] as? [String: Any],
                      let u = (x["utilization"] as? NSNumber)?.doubleValue,
                      let t = (x["resetsAt"] as? NSNumber)?.doubleValue else { return nil }
                return Window(used_percentage: u * 100, resets_at: t)
            }
            five = w("five_hour") ?? five
            seven = w("seven_day") ?? seven
        }
        guard five != nil || seven != nil else {
            if r.timedOut { throw Problem("Claude Code did not answer within 90 seconds.") }
            if r.out.contains("\"is_error\":true") || r.code != 0 {
                let hint = r.err.split(separator: "\n").last.map(String.init) ?? "exit code \(r.code)"
                throw Problem("Claude Code failed: \(hint)")
            }
            throw Problem("Claude Code answered but reported no plan limits (API-key login, or a changed format).")
        }
        return store(five: five, seven: seven, models: fetchModelWeeks(claude, cwd: dir, weekReset: seven?.resets_at),
                     asOf: Date())
    }

    // MARK: model-specific weekly limits (Fable) from `/usage`

    /// The `rate_limit_event` above carries no model-specific window, so these come from Claude Code's own
    /// `/usage` command: a local command, no message to any model, 0 tokens. nil = the call failed
    /// (keep what is stored); an empty list = it worked and the plan has no model-specific limit.
    static func fetchModelWeeks(_ claude: String, cwd: URL, weekReset: Double?) -> [ModelWindow]? {
        let r = runProcess(claude, ["-p", "/usage", "--output-format", "json", "--strict-mcp-config",
                                    "--setting-sources", "", "--no-session-persistence"], cwd: cwd, timeout: 30)
        guard let o = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
              o["is_error"] as? Bool != true, let text = o["result"] as? String,
              // Only trust "no model rows" when the text is the usage report we know.
              text.contains("Current week") else { return nil }
        return parseModelWeeks(text, now: Date(), weekReset: weekReset)
    }

    /// Reads lines like `Current week (Fable): 29% used · resets Nov 23 at 6:59am (Europe/Rome)`.
    /// "all models" is the ordinary weekly limit and is skipped. The text is not a documented format.
    /// `/usage` prints the reset a minute early (6:59 for 7:00), so a reset within two minutes of the
    /// weekly one is taken to be the weekly one. A line with no readable reset uses the weekly reset;
    /// with neither, the line is dropped rather than given a made-up time.
    static func parseModelWeeks(_ text: String, now: Date, weekReset: Double?) -> [ModelWindow] {
        let line = try! NSRegularExpression(
            pattern: #"^\s*Current week \(([^)]+)\):\s*(\d+(?:\.\d+)?)\s*% used(?:\s*·\s*resets\s+(.+?))?\s*$"#,
            options: [.anchorsMatchLines])
        let ns = text as NSString
        var out: [ModelWindow] = []
        for m in line.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard name.lowercased() != "all models", let pct = Double(ns.substring(with: m.range(at: 2))) else { continue }
            var reset = m.range(at: 3).location == NSNotFound ? nil
                : parseReset(ns.substring(with: m.range(at: 3)), now: now)?.timeIntervalSince1970
            if let w = weekReset, reset == nil || abs(reset! - w) <= 120 { reset = w }
            guard let r = reset else { continue }
            out.append(ModelWindow(name: name, used_percentage: pct, resets_at: r, as_of: now.timeIntervalSince1970))
        }
        return out
    }

    /// `Nov 23 at 6:59am (Europe/Rome)`, `Jan 2 at 7am`, or just `10:49am`: the next such moment from `now`.
    static func parseReset(_ s: String, now: Date) -> Date? {
        let re = try! NSRegularExpression(
            pattern: #"^(?:([A-Za-z]{3})[A-Za-z]*\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([AaPp][Mm])?(?:\s*\(([^)]+)\))?\s*$"#)
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = g(6).flatMap { TimeZone(identifier: $0) } ?? .current
        guard var hour = g(3).flatMap({ Int($0) }) else { return nil }
        if let ap = g(5)?.lowercased() { hour = hour % 12 + (ap == "pm" ? 12 : 0) }
        var c = DateComponents(hour: hour, minute: g(4).flatMap { Int($0) } ?? 0)
        guard let month = g(1), let day = g(2).flatMap({ Int($0) }) else {
            // Time only: the next time the clock shows it.
            return cal.nextDate(after: now.addingTimeInterval(-60), matching: c, matchingPolicy: .nextTime)
        }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let mi = months.firstIndex(of: month.lowercased()) else { return nil }
        c.month = mi + 1; c.day = day; c.year = cal.component(.year, from: now)
        guard let d = cal.date(from: c) else { return nil }
        // No year in the text: a date more than a day in the past means next year.
        if d < now.addingTimeInterval(-86400) { c.year! += 1; return cal.date(from: c) }
        return d
    }

    struct ProcResult { var out = "", err = "", code: Int32 = -1, timedOut = false }

    static func runProcess(_ path: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval) -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd = cwd { p.currentDirectoryURL = cwd }
        p.standardInput = FileHandle.nullDevice
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        var res = ProcResult()
        do { try p.run() } catch { res.err = error.localizedDescription; return res }
        let deadline = DispatchTime.now() + timeout
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: deadline)
        timer.setEventHandler { if p.isRunning { res.timedOut = true; p.terminate() } }
        timer.resume()
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        res.out = String(data: od, encoding: .utf8) ?? ""
        res.err = String(data: ed, encoding: .utf8) ?? ""
        res.code = p.terminationStatus
        return res
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
            let asOf = (obj["transcript_path"] as? String).flatMap(lastReply(in:)) ?? Date(timeIntervalSince1970: 0)
            let snap = store(five: window("five_hour"), seven: window("seven_day"), asOf: asOf)
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
