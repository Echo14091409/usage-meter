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

// 1. The real text: one model row, Fable 29 %, reset snapped to the weekly reset one minute later.
var m = Limits.parseModelWeeks(real, now: now, weekReset: weekReset)
check(m.count == 1, "one model-specific row, got \(m.count)")
check(m.first?.name == "Fable", "name Fable, got \(m.first?.name ?? "nil")")
check(m.first?.used_percentage == 29, "29 %, got \(m.first?.used_percentage ?? -1)")
check(m.first?.resets_at == weekReset, "reset snapped to weekly reset, got \(m.first?.resets_at ?? -1)")

// 2. Without a weekly reset to snap to, the reset is read from the text, in the zone it names.
m = Limits.parseModelWeeks(real, now: now, weekReset: nil)
check(m.first?.resets_at == at(2026, 11, 23, 6, 59).timeIntervalSince1970, "reset parsed as Nov 23 06:59 Rome, got \(m.first?.resets_at ?? -1)")

// 3. A plan without a model-specific limit: no rows (the panel then hides the row).
let plain = """
Current session: 11% used · resets Nov 20 at 10:49am (Europe/Rome)
Current week (all models): 31% used · resets Nov 23 at 6:59am (Europe/Rome)
"""
check(Limits.parseModelWeeks(plain, now: now, weekReset: weekReset).isEmpty, "no model row on a plan without one")
check(Limits.parseModelWeeks("", now: now, weekReset: weekReset).isEmpty, "empty text gives no rows")

// 4. A reset that lands in January when read in December belongs to next year.
let dec = "Current week (Fable): 4% used · resets Jan 2 at 7am (Europe/Rome)"
m = Limits.parseModelWeeks(dec, now: at(2026, 12, 29, 12, 0), weekReset: nil)
check(m.first?.resets_at == at(2027, 1, 2, 7, 0).timeIntervalSince1970, "year rolls over, got \(m.first?.resets_at ?? -1)")
check(m.first?.used_percentage == 4, "4 %")

// 5. No reset in the line: fall back to the weekly reset; with neither, the row is dropped (no made-up time).
let bare = "Current week (Fable): 0% used"
check(Limits.parseModelWeeks(bare, now: now, weekReset: weekReset).first?.resets_at == weekReset, "falls back to weekly reset")
check(Limits.parseModelWeeks(bare, now: now, weekReset: nil).isEmpty, "dropped without any reset time")

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
