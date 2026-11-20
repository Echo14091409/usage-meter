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
try? FileManager.default.removeItem(at: home)

print(failed == 0 ? "all tests passed" : "\(failed) failed")
exit(failed == 0 ? 0 : 1)
