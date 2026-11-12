import SwiftUI
import Combine
import ServiceManagement

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

@MainActor
final class Model: ObservableObject {
    @Published var limits: LimitSnapshot?
    @Published var usage = UsageSummary()
    @Published var hook: Limits.Hook = .none
    @Published var message = ""
    @Published var launchAtLogin = false
    @Published var checking = false
    @Published var showInBar = UserDefaults.standard.object(forKey: "showInBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInBar, forKey: "showInBar") }
    }
    let log = UsageLog()
    private var timer: Timer?
    private var scanning = false

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        limits = Limits.load()
        hook = Limits.hookState()
        if #available(macOS 13.0, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }
        guard !scanning else { return }
        scanning = true
        let log = self.log
        Task.detached {
            let s = log.summary()
            await MainActor.run { self.usage = s; self.scanning = false }
        }
    }

    /// Used % of a window, or 0 if the window has reset since the snapshot was taken.
    func used(_ w: Window?) -> Double? {
        guard let w = w else { return nil }
        return w.resetDate < Date() ? 0 : w.used_percentage
    }
    /// Numbers older than this are shown greyed out and not put in the menu bar.
    static let staleAfter: TimeInterval = 20 * 60
    var stale: Bool { limits.map { Date().timeIntervalSince($0.asOf) > Model.staleAfter } ?? false }
    var fiveHour: Double? { used(limits?.five_hour) }
    var sevenDay: Double? { used(limits?.seven_day) }

    var barText: String {
        guard showInBar, !stale, let p = fiveHour else { return "" }
        return " \(Int(p.rounded()))%"
    }

    /// Refresh button: re-read everything, then ask Claude Code for live limits (one tiny Haiku message).
    func checkLive() {
        guard !checking else { return }
        checking = true
        message = ""
        refresh()
        Task.detached {
            let result = Result { try Limits.fetchLive() }
            await MainActor.run {
                self.checking = false
                if case .failure(let e) = result { self.message = e.localizedDescription }
                self.refresh()
            }
        }
    }

    func setHook(_ on: Bool) {
        do { try Limits.setHook(on); message = on ? "Connected. Limits appear after your next Claude Code reply in a terminal." : "Disconnected." }
        catch { message = error.localizedDescription }
        refresh()
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { message = "Open at login: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

func ago(_ d: Date) -> String {
    if d.timeIntervalSince1970 < 1 { return "an unknown time" }
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60) min ago" }
    if s < 86400 { return "\(s / 3600) h ago" }
    return "\(s / 86400) d ago"
}

func until(_ d: Date) -> String {
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "reset" }
    if s < 60 { return "resets in under 1 min" }
    if s < 3600 { return "resets in \(s / 60) min" }
    if s < 86400 { return "resets in \(s / 3600) h \((s % 3600) / 60) min" }
    let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
    return "resets \(f.string(from: d))"
}

struct Meter: View {
    let title: String
    let used: Double?
    let window: Window?
    var stale = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(used.map { (stale ? "~" : "") + "\(Int($0.rounded()))% used" } ?? "not reported")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(used == nil || stale ? Color.secondary : Color.primary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(color).frame(width: g.size.width * CGFloat(min(max((used ?? 0) / 100, 0), 1)))
                }
            }
            .frame(height: 8)
            if let w = window { Text(until(w.resetDate)).font(.caption).foregroundStyle(.secondary) }
        }
    }
    var color: Color {
        guard let u = used, !stale else { return .secondary }
        return u >= 90 ? .red : u >= 70 ? .orange : .accentColor
    }
}

struct DayBars: View {
    let days: [(day: Date, total: Int)]
    var body: some View {
        let peak = max(days.map(\.total).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days.indices, id: \.self) { i in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == days.count - 1 ? Color.accentColor : Color.secondary.opacity(0.45))
                        .frame(height: max(2, 44 * CGFloat(days[i].total) / CGFloat(peak)))
                    Text(Self.label(days[i].day)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(short(days[i].total)) tokens")
            }
        }
        .frame(height: 60, alignment: .bottom)
    }
    static func label(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "EEEEE"; return f.string(from: d) }
}

struct Panel: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: gaugeIcon(fraction: m.fiveHour.map { $0 / 100 }, size: 28))
                    .renderingMode(.template).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Plan limits").font(.headline)
                    Text(m.limits.map { "As of \(ago($0.asOf)) · from Claude Code" } ?? "No limit data yet")
                        .font(.caption).foregroundStyle(m.stale ? Color.orange : Color.secondary)
                }
            }
            if m.limits != nil {
                Meter(title: "Current 5-hour window", used: m.fiveHour, window: m.limits?.five_hour, stale: m.stale)
                Meter(title: "Weekly (7 days)", used: m.sevenDay, window: m.limits?.seven_day, stale: m.stale)
                Text(m.stale
                     ? "Out of date: use since then (desktop app, browser, phone) is not included. Click Refresh to check now."
                     : "Live as of the time above. Refresh sends one tiny message to Haiku through Claude Code to check.")
                    .font(.caption).foregroundStyle(m.stale ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Click Refresh to check your 5-hour and weekly limits now (sends one tiny message to Haiku through Claude Code).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Claude Code tokens on this Mac").font(.headline)
            HStack {
                stat("Last 5 h", m.usage.last5h.total)
                stat("Today", m.usage.today.total)
                stat("7 days", m.usage.last7d.total)
            }
            DayBars(days: m.usage.byDay)
            if !m.usage.byModel7d.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(m.usage.byModel7d.prefix(4), id: \.model) { row in
                        HStack {
                            Text(row.model).font(.caption)
                            Spacer()
                            Text("\(short(row.totals.output)) out · \(row.totals.replies) replies")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Counted from Claude Code's local session logs; includes cached input. Claude chats in the app or browser are not counted.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                switch m.hook {
                case .ours:
                    Label("Connected to Claude Code", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(Color.green)
                    Spacer()
                    Button("Disconnect") { m.setHook(false) }
                case .other:
                    Text("Claude Code uses another status line").font(.caption).foregroundStyle(.secondary)
                case .none, .unreadable:
                    Button("Connect to Claude Code") { m.setHook(true) }
                }
            }
            if !m.message.isEmpty {
                Text(m.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Show 5-hour % in the menu bar", isOn: $m.showInBar)
            if #available(macOS 13.0, *) {
                Toggle("Open at login", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
            }

            Divider()
            HStack {
                Text("Usage Meter \(appVersion)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if m.checking { ProgressView().controlSize(.small) }
                Button(m.checking ? "Checking…" : "Refresh") { m.checkLive() }
                    .disabled(m.checking)
                    .help("Re-reads the logs and asks Claude Code for your live limits (about 1,000 Haiku tokens).")
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    var hookHint: String {
        switch m.hook {
        case .ours: return "Connected. Run any prompt in Claude Code in a terminal and the 5-hour and weekly limits appear here."
        case .other(let c): return "Claude Code already runs another status line (\(c)), so Usage Meter cannot receive limits."
        default: return "Connect to Claude Code below. It then reports your 5-hour and weekly plan limits here after each reply (Pro, Max and Ultra plans)."
        }
    }

    func stat(_ t: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(short(n)).font(.title3.monospacedDigit().weight(.semibold))
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let popover = NSPopover()
    var item: NSStatusItem!
    var hosting: NSHostingController<Panel>!
    var watcher: AnyCancellable?

    /// True when macOS started the app as a login item; then it stays quietly in the menu bar.
    var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = ev?.eventID == kAEOpenApplication
            && ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Opening the app again (Spotlight, Finder, Dock, `open`) while it runs shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hosting = NSHostingController(rootView: Panel(m: model))
        popover.contentViewController = hosting
        popover.behavior = .transient
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        watcher = model.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.sync() } }
        model.start()
        sync()
        if !launchedAtLogin && !ProcessInfo.processInfo.arguments.contains("--background") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showPanel() }
        }
    }

    func sync() {
        item.button?.image = gaugeIcon(fraction: model.stale ? nil : model.fiveHour.map { $0 / 100 }, size: 18)
        item.button?.title = model.barText
        item.button?.toolTip = model.limits.map { "Usage Meter · limits as of \(ago($0.asOf))" } ?? "Usage Meter"
        if popover.isShown { popover.contentSize = hosting.view.fittingSize }
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    func showPanel() {
        guard let b = item.button, !popover.isShown else { return }
        model.refresh()
        popover.contentSize = hosting.view.fittingSize
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        hosting.view.window?.makeKey()
    }
}

@MainActor
func screenshot(to path: String, dark: Bool) -> Bool {
    let m = Model()
    m.limits = Limits.load()
    m.hook = Limits.hookState()
    m.usage = m.log.summary()
    let host = NSHostingView(rootView: Panel(m: m).background(Color(NSColor.windowBackgroundColor)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = host.fittingSize
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    return (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
}

@main
enum Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--statusline") { Limits.statusLineMain(); return }
        if args.contains("--version") { print(appVersion); return }
        if args.contains("--fetch-limits") {
            do {
                let s = try Limits.fetchLive()
                print("5h \(s.five_hour.map { "\($0.used_percentage)%" } ?? "-") · 7d \(s.seven_day.map { "\($0.used_percentage)%" } ?? "-")")
            } catch { print(error.localizedDescription); exit(1) }
            return
        }
        if let i = args.firstIndex(of: "--set-hook"), i + 1 < args.count {
            do { try Limits.setHook(args[i + 1] == "on"); print("ok") } catch { print(error.localizedDescription); exit(1) }
            return
        }
        let app = NSApplication.shared
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            exit(screenshot(to: args[i + 1], dark: args.contains("dark")) ? 0 : 1)
        }
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(d) { app.run() }
    }
}
