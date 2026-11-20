import Foundation

// Run with: zsh build.sh test
var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failed += 1; print("FAIL (line \(line)): \(what)") }
}

let rome = TimeZone(identifier: "Europe/Rome")!
func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var c = Calendar(identifier: .gregorian); c.timeZone = rome
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

// What `claude -p "/usage" --output-format json` returned in `result` on 2026-11-20 (Max plan).
let real = """
You are currently using your subscription to power your Claude Code usage

Current session: 11% used · resets Nov 20 at 10:49am (Europe/Rome)
Current week (all models): 31% used · resets Nov 23 at 6:59am (Europe/Rome)
Current week (Fable): 29% used · resets Nov 23 at 6:59am (Europe/Rome)

What's contributing to your usage?
  79%  Start fresh when you switch tasks · run /clear
"""
let now = at(2026, 11, 20, 10, 33)
let weekReset = at(2026, 11, 23, 7, 0).timeIntervalSince1970

// 1. The real text: session, week and one model row. Known exact resets (from an earlier status line
//    report) one minute later replace the printed ones; `/usage` printed 10:49 for 10:50 and 6:59 for 7:00 here.
let fiveReset = at(2026, 11, 20, 10, 50).timeIntervalSince1970
var u = Limits.parseUsage(real, now: now, fiveReset: fiveReset, weekReset: weekReset)
check(u.five?.used_percentage == 11, "session 11 %, got \(u.five?.used_percentage ?? -1)")
check(u.five?.resets_at == fiveReset, "session reset snapped, got \(u.five?.resets_at ?? -1)")
check(u.seven?.used_percentage == 31, "week 31 %, got \(u.seven?.used_percentage ?? -1)")
check(u.seven?.resets_at == weekReset, "week reset snapped, got \(u.seven?.resets_at ?? -1)")
var m = u.models
check(m.count == 1, "one model-specific row, got \(m.count)")
check(m.first?.name == "Fable", "name Fable, got \(m.first?.name ?? "nil")")
check(m.first?.used_percentage == 29, "29 %, got \(m.first?.used_percentage ?? -1)")
check(m.first?.resets_at == weekReset, "model reset = week reset, got \(m.first?.resets_at ?? -1)")

// 2. Nothing known to snap to: resets are read from the text, in the zone it names.
u = Limits.parseUsage(real, now: now, fiveReset: nil, weekReset: nil)
check(u.five?.resets_at == at(2026, 11, 20, 10, 49).timeIntervalSince1970, "session reset Nov 20 10:49 Rome, got \(u.five?.resets_at ?? -1)")
check(u.seven?.resets_at == at(2026, 11, 23, 6, 59).timeIntervalSince1970, "week reset Nov 23 06:59 Rome, got \(u.seven?.resets_at ?? -1)")
check(u.models.first?.resets_at == at(2026, 11, 23, 6, 59).timeIntervalSince1970, "model reset Nov 23 06:59 Rome")
// A known reset that is far from the printed one (an old window) is not used.
u = Limits.parseUsage(real, now: now, fiveReset: fiveReset - 5 * 3600, weekReset: weekReset - 7 * 86400)
check(u.five?.resets_at == at(2026, 11, 20, 10, 49).timeIntervalSince1970, "old session reset ignored")
check(u.seven?.resets_at == at(2026, 11, 23, 6, 59).timeIntervalSince1970, "old week reset ignored")

// 3. A plan without a model-specific limit: no model rows (the panel then hides the row). "Current week:" also counts.
let plain = """
Current session: 11% used · resets Nov 20 at 10:49am (Europe/Rome)
Current week: 31% used · resets Nov 23 at 6:59am (Europe/Rome)
"""
u = Limits.parseUsage(plain, now: now, fiveReset: nil, weekReset: nil)
check(u.models.isEmpty, "no model row on a plan without one")
check(u.five?.used_percentage == 11 && u.seven?.used_percentage == 31, "session and week still read")
u = Limits.parseUsage("", now: now, fiveReset: nil, weekReset: nil)
check(u.five == nil && u.seven == nil && u.models.isEmpty, "empty text gives nothing")

// 4. A reset that lands in January when read in December belongs to next year.
let dec = "Current week (Fable): 4% used · resets Jan 2 at 7am (Europe/Rome)"
m = Limits.parseUsage(dec, now: at(2026, 12, 29, 12, 0), fiveReset: nil, weekReset: nil).models
check(m.first?.resets_at == at(2027, 1, 2, 7, 0).timeIntervalSince1970, "year rolls over, got \(m.first?.resets_at ?? -1)")
check(m.first?.used_percentage == 4, "4 %")

// 5. No reset in a line. Model row: falls back to the weekly reset, dropped with neither (no made-up time).
let bare = "Current week (Fable): 0% used"
check(Limits.parseUsage(bare, now: now, fiveReset: nil, weekReset: weekReset).models.first?.resets_at == weekReset, "falls back to weekly reset")
check(Limits.parseUsage(bare, now: now, fiveReset: nil, weekReset: nil).models.isEmpty, "dropped without any reset time")
//    Session at 0 % with no reset (no window running): shown as 0 %, already reset.
u = Limits.parseUsage("Current session: 0% used", now: now, fiveReset: nil, weekReset: nil)
check(u.five?.used_percentage == 0 && u.five?.resets_at == now.timeIntervalSince1970, "idle session = 0 %, reset now")
//    A used session with no reset and nothing known: not reported rather than guessed.
check(Limits.parseUsage("Current session: 40% used", now: now, fiveReset: nil, weekReset: nil).five == nil, "no guess for a used session")
check(Limits.parseUsage("Current session: 40% used", now: now, fiveReset: fiveReset, weekReset: nil).five?.resets_at == fiveReset, "known reset used when the line has none")

// 6. Storing: a report without model rows (status line) keeps the stored ones; an empty report clears them.
let home = FileManager.default.temporaryDirectory.appendingPathComponent("um-test-\(UUID().uuidString)")
setenv("UM_HOME", home.path, 1)
let t0 = Date()
let future = t0.timeIntervalSince1970 + 86400
let seven = Window(used_percentage: 31, resets_at: future)
let fable = ModelWindow(name: "Fable", used_percentage: 29, resets_at: future, as_of: t0.timeIntervalSince1970)
var s = Limits.store(five: nil, seven: seven, models: [fable], asOf: t0)
check(s.models?.first?.used_percentage == 29, "model row stored")
s = Limits.store(five: nil, seven: seven, models: nil, asOf: t0.addingTimeInterval(5))
check(s.models?.first?.name == "Fable", "kept when a report carries no model rows")
check(Limits.load()?.models?.first?.used_percentage == 29, "kept on disk")
s = Limits.store(five: nil, seven: seven, models: [], asOf: t0.addingTimeInterval(10))
check((s.models ?? []).isEmpty, "cleared when /usage reports no model limit")
// Old snapshot files (before 0.7.0) have no `models` key and must still load.
try? Data(#"{"seven_day":{"used_percentage":31,"resets_at":\#(future)},"updated_at":1,"as_of":1}"#.utf8).write(to: Paths.snapshot)
check(Limits.load()?.seven_day?.used_percentage == 31, "old snapshot without models still loads")

// 7. Pace: where a window ends up if use carries on at the window's average rate so far.
let wk = 7 * 86400.0
let r7 = at(2026, 11, 23, 7, 0)                       // weekly reset; the window began Mon 16 Nov 07:00
//    Half-way through at 30 %: on pace for 60 %, does not run out.
var pr = Pace.project(used: 30, resetsAt: r7.timeIntervalSince1970, window: wk, now: at(2026, 11, 19, 19, 0))
check(pr != nil && abs(pr!.atReset - 60) < 0.01 && pr!.runsOut == nil, "30 % at half-time = 60 % at reset, got \(String(describing: pr))")
//    Half-way through at 80 %: on pace for 160 %; runs out when 100/80 of the elapsed time has passed.
pr = Pace.project(used: 80, resetsAt: r7.timeIntervalSince1970, window: wk, now: at(2026, 11, 19, 19, 0))
check(pr != nil && abs(pr!.atReset - 160) < 0.01, "80 % at half-time = 160 %")
check(pr?.runsOut.map { abs($0.timeIntervalSince(at(2026, 11, 20, 16, 0))) < 1 } == true, "runs out Fri 20 Nov 16:00, got \(String(describing: pr?.runsOut))")
//    Too early to say (under a tenth of the window gone), nothing used, already full, or already reset: no projection.
check(Pace.project(used: 5, resetsAt: r7.timeIntervalSince1970, window: wk, now: at(2026, 11, 16, 12, 0)) == nil, "too early")
check(Pace.project(used: 0, resetsAt: r7.timeIntervalSince1970, window: wk, now: at(2026, 11, 19, 19, 0)) == nil, "nothing used")
check(Pace.project(used: 100, resetsAt: r7.timeIntervalSince1970, window: wk, now: at(2026, 11, 19, 19, 0))?.runsOut == nil, "already full: no run-out time")
check(Pace.project(used: 50, resetsAt: r7.timeIntervalSince1970, window: wk, now: at(2026, 11, 23, 8, 0)) == nil, "window already reset")

// 8. History keeps the 5-hour and model figures next to the weekly one; old entries without them still load.
try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
try? Data(#"[{"t":\#(Date().timeIntervalSince1970 - 3600),"s":10,"r":\#(future)}]"#.utf8).write(to: History.file)
check(History.load().first?.s == 10 && History.load().first?.f == nil, "old history entry loads")
let h0 = Date()
func fab(_ p: Double) -> [ModelWindow] { [ModelWindow(name: "Fable", used_percentage: p, resets_at: future, as_of: 0)] }
History.record(five: Window(used_percentage: 3, resets_at: future), seven: Window(used_percentage: 12, resets_at: future), models: fab(9), at: h0)
var hist = History.load()
check(hist.count == 2 && hist.last?.f == 3 && hist.last?.m?["Fable"] == 9, "5-hour and Fable recorded, got \(hist.count)")
//    Nothing changed a minute later: not stored again. Only the 5-hour figure moved: stored.
History.record(five: Window(used_percentage: 3, resets_at: future), seven: Window(used_percentage: 12, resets_at: future), models: fab(9), at: h0.addingTimeInterval(60))
check(History.load().count == 2, "unchanged reading skipped")
History.record(five: Window(used_percentage: 4, resets_at: future), seven: Window(used_percentage: 12, resets_at: future), models: fab(9), at: h0.addingTimeInterval(120))
check(History.load().count == 3, "5-hour change stored")
//    A status line report has no model figures: the entry simply has none (the chart skips it for that line).
History.record(five: Window(used_percentage: 5, resets_at: future), seven: Window(used_percentage: 12, resets_at: future), models: nil, at: h0.addingTimeInterval(180))
check(History.load().last?.m == nil && History.load().last?.f == 5, "entry without model figures")

// 9. Hour grid: the weekly % rise between two readings lands in the later reading's hour.
let wkR = at(2026, 11, 23, 7, 0).timeIntervalSince1970
func rd(_ d: Int, _ h: Int, _ mi: Int, _ s: Double) -> Reading { Reading(t: at(2026, 11, d, h, mi).timeIntervalSince1970, s: s, r: wkR) }
var cal = Calendar(identifier: .gregorian); cal.timeZone = rome
let grid = History.hourly([rd(18, 9, 10, 10), rd(18, 9, 50, 12), rd(18, 14, 5, 15), rd(19, 23, 30, 16), rd(20, 0, 10, 18)],
                          days: 3, now: at(2026, 11, 20, 10, 0), calendar: cal)
check(grid.count == 3 && grid.allSatisfy { $0.hours.count == 24 }, "3 days × 24 hours")
check(grid[0].hours[9] == 2 && grid[0].hours[14] == 3, "18 Nov: 2 % at 09h, 3 % at 14h, got \(grid[0].hours)")
check(grid[0].hours[8] == nil, "before the first reading: unknown")
check(grid[0].hours[10] == 0, "quiet hour after the first reading: 0")
check(grid[1].hours[23] == 1 && grid[2].hours[0] == 2, "19 Nov 23h 1 %, 20 Nov 00h 2 %")
check(grid[2].hours[11] == nil, "hours still to come: unknown")

// 10. Claude Code logs: tokens per project folder (the `cwd` each reply was made in).
let logs = home.appendingPathComponent("projects/-x-y")
try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
let iso = ISO8601DateFormatter()
func reply(_ id: String, _ cwd: String, _ out: Int) -> String {
    #"{"type":"assistant","timestamp":"\#(iso.string(from: Date().addingTimeInterval(-3600)))","cwd":"\#(cwd)","requestId":"r\#(id)","message":{"id":"\#(id)","model":"claude-fable-5-2","usage":{"input_tokens":10,"output_tokens":\#(out),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
}
try? Data([reply("a", "/Users/me/repos/alpha", 100), reply("b", "/Users/me/repos/alpha", 100), reply("c", "/Users/me/repos/beta", 1000)]
    .joined(separator: "\n").utf8).write(to: logs.appendingPathComponent("s.jsonl"))
let byProject = UsageLog(root: home.appendingPathComponent("projects")).summary().byProject7d
check(byProject.map(\.project) == ["beta", "alpha"], "projects by weight, got \(byProject.map(\.project))")
check(byProject.first?.totals.output == 1000 && byProject.last?.totals.replies == 2, "project totals")
check(abs(byProject.reduce(0) { $0 + $1.share } - 1) < 0.001, "shares add up to 1")


// 11. Accounts: the main one always exists; added ones get their own folders, kept apart from the main data.
var accts = Accounts.load()
check(accts.map(\.id) == [Accounts.mainID], "only the main account at first, got \(accts.map(\.id))")
check(Accounts.dataDir(Accounts.mainID) == Paths.support && Accounts.configDir(Accounts.mainID) == nil, "main account uses the normal places")
let a2 = Accounts.add(), a3 = Accounts.add()
accts = Accounts.load()
check(accts.count == 3 && a2.id != a3.id && accts.map(\.id) == [Accounts.mainID, a2.id, a3.id], "two accounts added and saved")
check(a2.name == "Account 2" && a3.name == "Account 3", "default names, got \(a2.name), \(a3.name)")
let cfg2 = Accounts.configDir(a2.id)!
var isDir: ObjCBool = false
check(FileManager.default.fileExists(atPath: cfg2.path, isDirectory: &isDir) && isDir.boolValue, "login folder created for the user")
check(cfg2.path.hasPrefix(Paths.support.path) && cfg2 != Accounts.configDir(a3.id)!, "each account has its own login folder under the app's data")
Accounts.rename(a2.id, to: "work@example.com")
check(Accounts.load()[1].name == "work@example.com", "renamed")
//    Limits and history of an added account do not touch the main account's files.
let mainBefore = try? Data(contentsOf: Paths.snapshot)
Limits.store(five: nil, seven: Window(used_percentage: 77, resets_at: future), models: [], asOf: Date(), in: Accounts.dataDir(a2.id))
check(Limits.load(in: Accounts.dataDir(a2.id))?.seven_day?.used_percentage == 77, "added account's limits stored in its folder")
check((try? Data(contentsOf: Paths.snapshot)) == mainBefore, "main snapshot untouched")
check(History.load(in: Accounts.dataDir(a2.id)).last?.s == 77 && History.load().last?.s != 77, "history kept per account")
//    The sign-in script sets the login folder and starts Claude Code's own sign-in; paths are quoted for the shell.
let script = Accounts.signInScript(for: a2.id, claude: "/tmp/it's here/claude")
check(script.contains("export CLAUDE_CONFIG_DIR='\(cfg2.path)'"), "script sets the login folder")
check(script.contains(#"'/tmp/it'\''s here/claude' auth login"#), "script runs claude auth login, quoted: \(script)")
//    The script file is written executable and is valid zsh (syntax check only; it is not run).
let cmd = try? Accounts.writeSignInCommand(for: a2.id, claude: "/tmp/it's here/claude")
check(cmd.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true, "sign-in file is executable")
check(cmd.map { Limits.runProcess("/bin/zsh", ["-n", $0.path], timeout: 10).code } == 0, "sign-in file is valid zsh")
//    Reading the sign-in state Claude Code prints.
var st = Accounts.parseStatus(#"{"loggedIn":true,"authMethod":"claude.ai","email":"work@example.com","subscriptionType":"max"}"#)
check(st.loggedIn && st.email == "work@example.com" && st.plan == "max", "signed-in status read")
st = Accounts.parseStatus(#"{"loggedIn":false,"authMethod":"none"}"#)
check(!st.loggedIn && st.email == nil, "signed-out status read")
check(!Accounts.parseStatus("not json").loggedIn, "garbage = not signed in")
//    Removing: gone from the list, folder gone, main never removable.
Accounts.remove(a2.id)
check(Accounts.load().map(\.id) == [Accounts.mainID, a3.id], "removed from the list")
check(!FileManager.default.fileExists(atPath: Accounts.dataDir(a2.id).path), "its folder is gone")
Accounts.remove(Accounts.mainID)
check(Accounts.load().first?.id == Accounts.mainID, "main account cannot be removed")

try? FileManager.default.removeItem(at: home)

print(failed == 0 ? "all tests passed" : "\(failed) failed")
exit(failed == 0 ? 0 : 1)
