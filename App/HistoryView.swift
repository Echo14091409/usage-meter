import SwiftUI

/// "on pace for 62%" / "full by Sat 14:20 at this pace"; nil when there is no projection.
func paceText(_ p: Pace.Projection?) -> String? {
    guard let p = p else { return nil }
    if let d = p.runsOut {
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
        return "full by \(f.string(from: d)) at this pace"
    }
    return "on pace for \(Int(p.atReset.rounded()))%"
}

extension Model {
    func pace(_ w: Window?, hours: Double) -> Pace.Projection? {
        guard let w = w, !stale else { return nil }
        return Pace.project(used: w.used_percentage, resetsAt: w.resets_at, window: hours * 3600)
    }
}

/// One line of the history chart: the value holds until the next reading, and drops to 0 at a reset.
struct Series: Identifiable {
    var name: String
    var color: Color
    var points: [(t: Double, v: Double)] = []
    var id: String { name }

    /// `value`/`reset` pick the figure out of a reading; readings without it are skipped.
    init(name: String, color: Color, readings: [Reading], until now: Double,
         value: (Reading) -> Double?, reset: (Reading) -> Double?) {
        self.name = name; self.color = color
        var lastReset: Double?
        for r in readings {
            guard let v = value(r) else { continue }
            if let lr = lastReset, lr < r.t, let nr = reset(r), abs(nr - lr) > 3600 { points.append((lr, 0)) }
            points.append((r.t, v))
            lastReset = reset(r)
        }
        if let lr = lastReset, lr < now { points.append((lr, 0)) }
    }
}

struct HistoryChart: View {
    let series: [Series]
    let from: Double, to: Double
    var body: some View {
        Canvas { ctx, size in
            let left: CGFloat = 30, bottom: CGFloat = 16, top: CGFloat = 4
            let w = size.width - left, h = size.height - bottom - top
            func x(_ t: Double) -> CGFloat { left + w * CGFloat((t - from) / (to - from)) }
            func y(_ v: Double) -> CGFloat { top + h * CGFloat(1 - min(max(v, 0), 100) / 100) }
            for g in [0.0, 25, 50, 75, 100] {
                var p = Path(); p.move(to: CGPoint(x: left, y: y(g))); p.addLine(to: CGPoint(x: size.width, y: y(g)))
                ctx.stroke(p, with: .color(.secondary.opacity(g == 0 ? 0.5 : 0.18)), lineWidth: 0.5)
                ctx.draw(Text("\(Int(g))%").font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: left - 4, y: y(g)), anchor: .trailing)
            }
            let f = DateFormatter(); f.dateFormat = to - from <= 86400 * 1.5 ? "HH:mm" : "EEE d"
            for i in 0...4 {
                let t = from + (to - from) * Double(i) / 4
                ctx.draw(Text(f.string(from: Date(timeIntervalSince1970: t))).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: x(t), y: size.height - 6), anchor: i == 0 ? .leading : i == 4 ? .trailing : .center)
            }
            ctx.clip(to: Path(CGRect(x: left, y: 0, width: w, height: size.height - bottom + 1)))
            for s in series {
                var p = Path(), started = false, last = 0.0
                for pt in s.points {
                    if !started { p.move(to: CGPoint(x: x(pt.t), y: y(pt.v))); started = true }
                    else { p.addLine(to: CGPoint(x: x(pt.t), y: y(last))); p.addLine(to: CGPoint(x: x(pt.t), y: y(pt.v))) }
                    last = pt.v
                }
                if started { p.addLine(to: CGPoint(x: x(to), y: y(last))) }
                ctx.stroke(p, with: .color(s.color), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
        }
    }
}

struct HourGrid: View {
    let rows: [History.HourRow]
    var body: some View {
        let peak = max(rows.flatMap { $0.hours.compactMap { $0 } }.max() ?? 0, 1)
        let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d"; return f }()
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 2) {
                    Text(f.string(from: rows[i].day)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let v = rows[i].hours[h]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(v == nil ? Color.clear : v == 0 ? Color.secondary.opacity(0.12)
                                  : Color.accentColor.opacity(0.25 + 0.75 * v! / peak))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(v == nil ? 0.15 : 0), lineWidth: 0.5))
                            .frame(height: 11).frame(maxWidth: .infinity)
                            .help(v.map { String(format: "%@ %02d:00 – %.0f%% of the weekly limit", f.string(from: rows[i].day), h, $0) }
                                  ?? "No data")
                    }
                }
            }
            HStack(spacing: 2) {
                Text("").frame(width: 40)
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 6 == 0 ? "\(h)" : "").font(.system(size: 9)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct HistoryContent: View {
    @ObservedObject var m: Model
    @State var days = 7.0

    static let colors: [Color] = [.purple, .pink, .teal]

    var body: some View {
        let now = Date().timeIntervalSince1970, from = now - days * 86400
        let shown = m.history.filter { $0.t >= from - 7 * 86400 }
        let names = Array(Set(shown.flatMap { $0.m.map { Array($0.keys) } ?? [] })).sorted()
        let series = [
            Series(name: "Weekly", color: .accentColor, readings: shown, until: now, value: { $0.s }, reset: { $0.r }),
            Series(name: "5-hour", color: .orange, readings: shown, until: now, value: { $0.f }, reset: { $0.fr }),
        ] + names.enumerated().map { i, n in
            Series(name: "\(n), weekly", color: Self.colors[i % Self.colors.count], readings: shown, until: now,
                   value: { $0.m?[n] }, reset: { $0.r })
        }
        let grid = History.hourly(m.history)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Limits over time").font(.headline)
                Spacer()
                Picker("", selection: $days) {
                    Text("24 hours").tag(1.0); Text("7 days").tag(7.0); Text("30 days").tag(30.0)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HistoryChart(series: series, from: from, to: now).frame(height: 170)
            HStack(spacing: 14) {
                ForEach(series) { s in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1).fill(s.color).frame(width: 12, height: 3)
                        Text(s.points.isEmpty ? "\(s.name): no readings yet" : s.name).font(.caption)
                    }
                }
            }
            Text("Each line holds its last reading until the next one and drops to 0 at a reset. Recorded since "
                 + (m.historySince.map { Self.dateFormat.string(from: $0) } ?? "–")
                 + ". Whole account, in 1% steps; use while this Mac was off shows as one step at the next check.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Pace").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                paceRow("5-hour window", m.limits?.five_hour, hours: 5)
                paceRow("Weekly", m.limits?.seven_day, hours: 168)
                ForEach(m.modelWeeks, id: \.name) { w in paceRow("Weekly, \(w.name) only", w.window, hours: 168) }
            }
            Text("If use carries on at the window's average rate so far. No figure in the first tenth of a window or when the numbers are out of date.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("When the weekly limit was used").font(.headline)
            HourGrid(rows: grid)
            ForEach(insights(grid), id: \.self) { Text($0).font(.caption) }
            Text("By hour of day, last 14 days. A rise counts in the hour of the reading that showed it, so with checks paused (Mac idle or asleep) it lands in the hour you came back.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !m.usage.byProject7d.isEmpty {
                Divider()
                Text("Claude Code by project, last 7 days").font(.headline)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(m.usage.byProject7d.prefix(8), id: \.project) { p in
                        HStack(spacing: 8) {
                            Text(p.project).font(.caption).lineLimit(1).frame(width: 150, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(2, g.size.width * CGFloat(p.share)))
                            }.frame(height: 6)
                            Text("\(Int((p.share * 100).rounded()))% · \(short(p.totals.output)) out · \(p.totals.replies) replies")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 190, alignment: .trailing)
                        }
                    }
                }
                Text("Share of a rough cost weight (API price ratios) from the local session logs on this Mac. Not the plan %: chats in the app, browser or phone are not in it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if !m.contributing.isEmpty {
                Divider()
                Text("What Claude Code says drives your use").font(.headline)
                Text(m.contributing).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text("Copied as it is from Claude Code's /usage report at the last check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 580)
    }

    static let dateFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; return f }()

    func paceRow(_ title: String, _ w: Window?, hours: Double) -> some View {
        let p = m.pace(w, hours: hours)
        return HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(paceText(p).map { "\(Int((w?.used_percentage ?? 0).rounded()))% now · \($0)" } ?? "no projection yet")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(p?.runsOut != nil ? Color.orange : p == nil ? Color.secondary : Color.primary)
        }
    }

    /// A few plain facts from the hour grid.
    func insights(_ grid: [History.HourRow]) -> [String] {
        var out: [String] = []
        let f = DateFormatter(); f.dateFormat = "EEEE d MMM"
        let perDay = grid.compactMap { r -> (Date, Double)? in
            let known = r.hours.compactMap { $0 }
            return known.isEmpty ? nil : (r.day, known.reduce(0, +))
        }
        if let top = perDay.max(by: { $0.1 < $1.1 }), top.1 > 0 {
            out.append(String(format: "Heaviest day: %@, %.0f%% of the weekly limit.", f.string(from: top.0), top.1))
        }
        if perDay.count > 1 {
            out.append(String(format: "Average: %.1f%% a day over the %d days with data (an even week would be 14.3%% a day).",
                              perDay.reduce(0) { $0 + $1.1 } / Double(perDay.count), perDay.count))
        }
        let byHour = (0..<24).map { h in grid.reduce(0.0) { $0 + ($1.hours[h] ?? 0) } }
        let total = byHour.reduce(0, +)
        if total > 0, let best = (0..<22).max(by: { byHour[$0...$0 + 2].reduce(0, +) < byHour[$1...$1 + 2].reduce(0, +) }) {
            out.append(String(format: "Heaviest three hours of the day: %02d:00–%02d:00, %.0f%% of the use recorded.",
                              best, best + 3, byHour[best...best + 2].reduce(0, +) / total * 100))
        }
        return out
    }
}
