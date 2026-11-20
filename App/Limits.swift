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
    static let contributing = support.appendingPathComponent("contributing.txt")
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
        if let w = seven, w.resetDate > now { History.record(five: five, seven: w, models: models, at: asOf) }
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

    /// Asks Claude Code for its own `/usage` report (your own subscription, no settings, no MCP, nothing
    /// saved). `/usage` is a local command: no message goes to a model and it uses no tokens.
    static func fetchLive() throws -> LimitSnapshot {
        guard let claude = claudePath() else { throw Problem("Claude Code (the claude command) was not found.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-meter-check")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = runProcess(claude, ["-p", "/usage", "--output-format", "json", "--strict-mcp-config",
                                    "--setting-sources", "", "--no-session-persistence"], cwd: dir, timeout: 60)
        let o = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
        let text = o?["result"] as? String ?? ""
        // Exact reset times from the last report (the status line gives them to the second) to snap to.
        let now = Date(), prev = load()
        func known(_ w: Window?) -> Double? { w.flatMap { $0.resetDate > now ? $0.resets_at : nil } }
        let u = parseUsage(text, now: now, fiveReset: known(prev?.five_hour), weekReset: known(prev?.seven_day))
        guard o?["is_error"] as? Bool != true, u.five != nil || u.seven != nil else {
            if r.timedOut { throw Problem("Claude Code did not answer within 60 seconds.") }
            if o?["is_error"] as? Bool == true || r.code != 0 {
                let hint = r.err.split(separator: "\n").last.map(String.init) ?? "exit code \(r.code)"
                throw Problem("Claude Code failed: \(hint)")
            }
            throw Problem("Claude Code answered but reported no plan limits (API-key login, or a changed format).")
        }
        // The rest of the report says what drives the use (skills, MCP servers, subagents); kept for the History window.
        if let i = text.range(of: "What's contributing") {
            try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try? Data(text[i.lowerBound...].utf8).write(to: Paths.contributing, options: .atomic)
        }
        return store(five: u.five, seven: u.seven, models: u.models, asOf: now)
    }

    // MARK: reading the `/usage` text

    struct UsageReport { var five: Window?; var seven: Window?; var models: [ModelWindow] = [] }

    /// Reads these lines (the text is not a documented format):
    ///   `Current session: 11% used · resets Nov 20 at 10:49am (Europe/Rome)`   → 5-hour window
    ///   `Current week (all models): 31% used · resets Nov 23 at 6:59am (…)`     → weekly limit
    ///   `Current week (Fable): 29% used · resets Nov 23 at 6:59am (…)`          → a model-specific weekly limit
    /// `/usage` prints a reset only to the minute and sometimes a minute early (6:59 for 7:00), so a known exact
    /// reset (`fiveReset`, `weekReset`, from an earlier report) within two minutes of the printed one is used
    /// instead. A line with no readable reset uses the known one; a model line uses the weekly one. With
    /// nothing to go on the line is dropped rather than given a made-up time, except a session at 0 %,
    /// which is a window that is not running.
    static func parseUsage(_ text: String, now: Date, fiveReset: Double?, weekReset: Double?) -> UsageReport {
        let line = try! NSRegularExpression(
            pattern: #"^\s*Current (session|week)(?: \(([^)]+)\))?:\s*(\d+(?:\.\d+)?)\s*% used(?:\s*·\s*resets\s+(.+?))?\s*$"#,
            options: [.anchorsMatchLines])
        let ns = text as NSString
        func resolve(_ printed: Double?, _ known: Double?) -> Double? {
            guard let p = printed else { return known }
            if let k = known, abs(p - k) <= 120 { return k }
            return p
        }
        var out = UsageReport()
        var modelLines: [(name: String, pct: Double, reset: Double?)] = []
        for m in line.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let pct = g(3).flatMap({ Double($0) }) else { continue }
            let printed = g(4).flatMap { parseReset($0, now: now)?.timeIntervalSince1970 }
            let name = g(2)?.trimmingCharacters(in: .whitespaces)
            if g(1) == "session" {
                if let r = resolve(printed, fiveReset) ?? (pct == 0 ? now.timeIntervalSince1970 : nil) {
                    out.five = Window(used_percentage: pct, resets_at: r)
                }
            } else if name == nil || name!.lowercased() == "all models" {
                if let r = resolve(printed, weekReset) { out.seven = Window(used_percentage: pct, resets_at: r) }
            } else {
                modelLines.append((name!, pct, printed))
            }
        }
        let week = out.seven?.resets_at ?? weekReset
        for l in modelLines {
            guard let r = resolve(l.reset, week) else { continue }
            out.models.append(ModelWindow(name: l.name, used_percentage: l.pct, resets_at: r, as_of: now.timeIntervalSince1970))
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
