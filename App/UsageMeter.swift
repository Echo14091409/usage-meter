import SwiftUI
import Combine
import ServiceManagement
import CoreGraphics

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

@MainActor
final class Model: ObservableObject {
    @Published var limits: LimitSnapshot?
    @Published var usage = UsageSummary()
    @Published var hook: Limits.Hook = .none
    @Published var message = ""
    @Published var launchAtLogin = false
    @Published var checking = false
    /// % of the weekly limit used per day, last 7 days (whole account).
    @Published var daily: [History.Day] = []
    @Published var historySince: Date?
    /// Every saved reading, for the History window.
    @Published var history: [Reading] = []
    /// The "What's contributing" part of the last `/usage` report.
    @Published var contributing = ""
    /// Opens the History window (set by the app delegate).
    var onHistory: () -> Void = {}
    /// Minutes between automatic live checks; 0 = off.
    @Published var autoMinutes = UserDefaults.standard.object(forKey: "autoMinutes") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(autoMinutes, forKey: "autoMinutes") }
    }
    /// Automatic checks pause after this long without keyboard or mouse input.
    static let idlePause: TimeInterval = 10 * 60
    @Published var showInBar = UserDefaults.standard.object(forKey: "showInBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInBar, forKey: "showInBar") }
    }
    /// The logins shown; the main one first.
    @Published var accounts: [Account] = Accounts.load()
    /// Which account the panel, the menu bar and the History window show.
    @Published var selected = UserDefaults.standard.string(forKey: "selectedAccount") ?? Accounts.mainID {
        didSet {
            guard selected != oldValue else { return }
            UserDefaults.standard.set(selected, forKey: "selectedAccount")
            usage = UsageSummary(); message = ""
            refresh()
        }
    }
    /// The other accounts' last readings, for the one-line summaries.
    @Published var others: [(account: Account, limits: LimitSnapshot?)] = []
    /// An added account whose sign-in in Terminal the app is waiting for.
    @Published var waitingFor: String?
    private var logs: [String: UsageLog] = [:]
    /// The selected account's session logs (an added account has its own folder of them).
    var log: UsageLog {
        if let l = logs[selected] { return l }
        let l = Accounts.configDir(selected).map { UsageLog(root: $0.appendingPathComponent("projects")) } ?? UsageLog()
        logs[selected] = l
        return l
    }
    var isMain: Bool { selected == Accounts.mainID }
    var selectedName: String { accounts.first { $0.id == selected }?.name ?? "" }
    private var timer: Timer?
    private var scanning = false

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.autoCheckIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.autoCheckIfDue() }
    }

    func refresh() {
        accounts = Accounts.load()
        if !accounts.contains(where: { $0.id == selected }) { selected = Accounts.mainID; return }
        let dir = Accounts.dataDir(selected)
        limits = Limits.load(in: dir)
        others = accounts.filter { $0.id != selected }.map { ($0, Limits.load(in: Accounts.dataDir($0.id))) }
        let h = History.load(in: dir)
        history = h
        contributing = (try? String(contentsOf: dir.appendingPathComponent("contributing.txt"), encoding: .utf8)) ?? ""
        historySince = h.first.map { Date(timeIntervalSince1970: $0.t) }
        daily = History.daily(h, activity: usage.activity)
        hook = Limits.hookState()
        if #available(macOS 13.0, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }
        guard !scanning else { return }
        scanning = true
        let log = self.log, id = selected
        Task.detached {
            let s = log.summary()
            await MainActor.run {
                self.scanning = false
                guard id == self.selected else { self.refresh(); return }     // the account was switched meanwhile
                self.usage = s
                self.daily = History.daily(History.load(in: Accounts.dataDir(id)), activity: s.activity)
            }
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
    /// Model-specific weekly limits (Fable); empty when the plan has none, so no row is drawn.
    var modelWeeks: [ModelWindow] { limits?.models ?? [] }
    func stale(_ w: ModelWindow) -> Bool { stale || Date().timeIntervalSince(w.asOf) > Model.staleAfter }

    var barText: String {
        guard showInBar, !stale, let p = fiveHour else { return "" }
        return " \(Int(p.rounded()))%"
    }

    /// Seconds since the last keyboard, mouse or trackpad input anywhere on the Mac.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    var autoPausedForIdle: Bool { autoMinutes > 0 && Model.idleSeconds > Model.idlePause }

    /// Runs a live check when automatic checks are on, the numbers are older than the interval,
    /// and someone has used the Mac in the last 10 minutes.
    func autoCheckIfDue() {
        guard autoMinutes > 0, !checking, !autoPausedForIdle else { return }
        let age = limits.map { Date().timeIntervalSince($0.asOf) } ?? .infinity
        if age >= Double(autoMinutes * 60) - 15 { checkLive() }
    }

    /// Refresh button: re-read everything, then ask Claude Code for live limits (its `/usage` report, no tokens).
    func checkLive() {
        guard !checking else { return }
        checking = true
        message = ""
        refresh()
        let all = accounts, shown = selected
        Task.detached {
            var problem: String?
            for a in all {
                do {
                    _ = try Limits.fetchLive(account: a.id)
                    // An added account is called by its email once Claude Code knows it.
                    if a.id != Accounts.mainID, a.name.hasPrefix("Account "), let e = Accounts.status(a.id).email {
                        Accounts.rename(a.id, to: e)
                    }
                } catch { if a.id == shown { problem = error.localizedDescription } }
            }
            let failed = problem
            await MainActor.run {
                self.checking = false
                if let p = failed, shown == self.selected { self.message = p }
                self.refresh()
            }
        }
    }

    /// "Add account": makes the account's folders, then opens Terminal on Claude Code's own sign-in for it.
    func addAccount() {
        let a = Accounts.add()
        accounts = Accounts.load()
        selected = a.id
        signIn(a.id)
    }

    /// Opens Terminal with `claude auth login` for an added account and waits (up to 10 minutes) for it to succeed.
    func signIn(_ id: String) {
        guard let claude = Limits.claudePath() else { message = "Claude Code (the claude command) was not found."; return }
        do { NSWorkspace.shared.open(try Accounts.writeSignInCommand(for: id, claude: claude)) }
        catch { message = "Could not start the sign-in: \(error.localizedDescription)"; return }
        waitingFor = id
        message = "Terminal opened: sign in there with the account to add. This panel updates by itself."
        Task.detached {
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard await MainActor.run(body: { self.waitingFor == id }) else { return }
                let s = Accounts.status(id)
                if s.loggedIn {
                    if let e = s.email { Accounts.rename(id, to: e) }
                    await MainActor.run { self.waitingFor = nil; self.message = ""; self.refresh(); self.checkLive() }
                    return
                }
            }
            await MainActor.run { if self.waitingFor == id { self.waitingFor = nil; self.message = "No sign-in seen. Click Sign in to try again." } }
        }
    }

    /// Asks first, then signs the selected added account out and moves its folder to the Trash.
    func removeSelected() {
        guard !isMain else { return }
        let id = selected, alert = NSAlert()
        alert.messageText = "Remove \(selectedName) from Usage Meter?"
        alert.informativeText = "This signs that account out of the extra Claude Code login Usage Meter made for it and moves its saved history to the Trash. Your main Claude Code login and the account itself are not affected."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if waitingFor == id { waitingFor = nil }
        logs[id] = nil
        selected = Accounts.mainID
        Task.detached {
            Accounts.signOutAndRemove(id)
            await MainActor.run { self.refresh() }
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
    var pace: Pace.Projection? = nil
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
            if let w = window {
                HStack(spacing: 0) {
                    Text(until(w.resetDate)).foregroundStyle(.secondary)
                    if let t = paceText(pace) {
                        Text(" · \(t)").foregroundStyle(pace?.runsOut != nil ? Color.orange : Color.secondary)
                    }
                }.font(.caption)
            }
        }
    }
    var color: Color {
        guard let u = used, !stale else { return .secondary }
        return u >= 90 ? .red : u >= 70 ? .orange : .accentColor
    }
}

struct DayBars: View {
    let days: [History.Day]
    var body: some View {
        let peak = max(days.compactMap(\.pct).max() ?? 0, 5)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days.indices, id: \.self) { i in
                let d = days[i]
                VStack(spacing: 3) {
                    Text(d.pct.map { (d.estimated ? "≈" : "") + "\(Int($0.rounded()))%" } ?? "–")
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(d.pct == nil ? Color.secondary.opacity(0.12)
                              : (i == days.count - 1 ? Color.accentColor : Color.secondary)
                                .opacity(d.estimated ? 0.45 : (i == days.count - 1 ? 1 : 0.6)))
                        .frame(height: d.pct.map { max(2, 40 * CGFloat($0 / peak)) } ?? 2)
                    Text(Self.label(d.day)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help(d.pct.map { String(format: "%@%.1f%% of the weekly limit", d.estimated ? "about " : "", $0) }
                      ?? "Before this week's data: not known")
            }
        }
        .frame(height: 72, alignment: .bottom)
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
                if m.accounts.count > 1 {
                    Spacer()
                    Picker("", selection: $m.selected) {
                        ForEach(m.accounts) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(maxWidth: 150)
                    .help("Which account this panel, the menu bar and History show.")
                }
            }
            if m.limits != nil {
                Meter(title: "Current 5-hour window", used: m.fiveHour, window: m.limits?.five_hour, stale: m.stale,
                      pace: m.pace(m.limits?.five_hour, hours: 5))
                Meter(title: "Weekly (7 days)", used: m.sevenDay, window: m.limits?.seven_day, stale: m.stale,
                      pace: m.pace(m.limits?.seven_day, hours: 168))
                ForEach(m.modelWeeks, id: \.name) { w in
                    Meter(title: "Weekly, \(w.name) only", used: m.used(w.window), window: w.window, stale: m.stale(w),
                          pace: m.stale(w) ? nil : m.pace(w.window, hours: 168))
                }
                ForEach(m.others, id: \.account.id) { o in
                    Button { m.selected = o.account.id } label: {
                        HStack {
                            Text(o.account.name).lineLimit(1)
                            Spacer()
                            Text(Self.summary(o.limits)).monospacedDigit().foregroundStyle(.secondary)
                        }.font(.caption).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Show this account")
                }
                Text(m.stale
                     ? (m.autoPausedForIdle ? "Out of date while you were away; it updates once you use the Mac again, or click Refresh."
                                            : "Out of date: use since then (desktop app, browser, phone) is not included. Click Refresh to check now.")
                     : "Live as of the time above. Each check reads Claude Code's own /usage report: no message to a model, no tokens. Replies in a terminal Claude Code session update it in between.")
                    .font(.caption).foregroundStyle(m.stale ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Weekly limit used per day").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("History…") { m.onHistory() }.controlSize(.small)
                        .help("Charts of the limits over time, pace, hours of the day and Claude Code projects.")
                }.padding(.top, 2)
                DayBars(days: m.daily)
                Text("Whole account: chat, apps, phone and Claude Code, in 1% steps."
                     + (m.daily.contains { $0.estimated } ? m.historySince.map {
                        " ≈ before \(Self.timeFormat.string(from: $0)): the week's % at that time, split by when Claude Code ran on this Mac." } ?? "" : "")
                     + (m.daily.contains { $0.pct == nil } ? " – = before this week, no data." : ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if m.isMain {
                Text("Click Refresh to check your 5-hour and weekly limits now (reads Claude Code's own /usage report; uses no tokens).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(m.waitingFor == m.selected
                     ? "Waiting for you to sign in to this account in the Terminal window that opened."
                     : "This account is not signed in yet.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Sign in…") { m.signIn(m.selected) }
            }

            if m.isMain || m.usage.last7d.replies > 0 { tokens }

            Divider()

            if m.isMain {
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
            }
            HStack {
                Text("Accounts")
                Spacer()
                if !m.isMain { Button("Remove this one…") { m.removeSelected() } }
                Button("Add account…") { m.addAccount() }
                    .help("Adds another Claude login just for this app. Terminal opens and Claude Code asks you to sign in in the browser; your main Claude Code login is not touched.")
            }
            if !m.message.isEmpty {
                Text(m.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            settings
        }
        .padding(14)
        .frame(width: 340)
    }

    /// "5h 12% · week 40%" for another account's line.
    static func summary(_ l: LimitSnapshot?) -> String {
        guard let l = l else { return "not signed in yet" }
        func pct(_ w: Window?) -> String { w.map { "\(Int(($0.resetDate < Date() ? 0 : $0.used_percentage).rounded()))%" } ?? "–" }
        let old = Date().timeIntervalSince(l.asOf) > Model.staleAfter
        return (old ? "~" : "") + "5h \(pct(l.five_hour)) · week \(pct(l.seven_day))"
    }

    @ViewBuilder var tokens: some View {
            Divider()

            Text("Claude Code tokens on this Mac").font(.headline)
            HStack {
                stat("Last 5 h", m.usage.last5h.total)
                stat("Today", m.usage.today.total)
                stat("7 days", m.usage.last7d.total)
            }
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
    }

    @ViewBuilder var settings: some View {
            HStack {
                Text("Check limits automatically")
                Spacer()
                Picker("", selection: $m.autoMinutes) {
                    Text("Off").tag(0)
                    Text("Every 2 min").tag(2)
                    Text("Every 5 min").tag(5)
                    Text("Every 15 min").tag(15)
                    Text("Every 30 min").tag(30)
                }
                .labelsHidden()
                .fixedSize()
            }
            Text(m.autoMinutes == 0
                 ? "Only when you click Refresh."
                 : "Uses no tokens. Pauses after 10 minutes without keyboard or mouse use\(m.autoPausedForIdle ? " (paused now)" : "").")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    .help("Re-reads the logs and asks Claude Code for your live limits (no tokens).")
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
    }

    var hookHint: String {
        switch m.hook {
        case .ours: return "Connected. Run any prompt in Claude Code in a terminal and the 5-hour and weekly limits appear here."
        case .other(let c): return "Claude Code already runs another status line (\(c)), so Usage Meter cannot receive limits."
        default: return "Connect to Claude Code below. It then reports your 5-hour and weekly plan limits here after each reply (Pro, Max and Ultra plans)."
        }
    }

    static let timeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f }()

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
    var historyWindow: NSWindow?

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
        model.onHistory = { [weak self] in self?.showHistory() }
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

    func showHistory() {
        popover.performClose(nil)
        if historyWindow == nil {
            let host = NSHostingController(rootView: ScrollView { HistoryContent(m: model) })
            let w = NSWindow(contentViewController: host)
            w.title = "Usage Meter History"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            let h = min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 60)
            w.setContentSize(NSSize(width: 580, height: h))
            w.contentMinSize = NSSize(width: 580, height: 300)
            w.contentMaxSize = NSSize(width: 580, height: 4000)
            w.center()
            historyWindow = w
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
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
func screenshot(to path: String, dark: Bool, history: Bool = false) -> Bool {
    let m = Model()
    let dir = Accounts.dataDir(m.selected)
    m.limits = Limits.load(in: dir)
    m.others = m.accounts.filter { $0.id != m.selected }.map { ($0, Limits.load(in: Accounts.dataDir($0.id))) }
    let h = History.load(in: dir)
    m.history = h
    m.contributing = (try? String(contentsOf: dir.appendingPathComponent("contributing.txt"), encoding: .utf8)) ?? ""
    m.daily = History.daily(h)
    m.historySince = h.first.map { Date(timeIntervalSince1970: $0.t) }
    m.hook = Limits.hookState()
    m.usage = m.log.summary()
    m.daily = History.daily(h, activity: m.usage.activity)
    let host = NSHostingView(rootView: (history ? AnyView(HistoryContent(m: m)) : AnyView(Panel(m: m)))
        .background(Color(NSColor.windowBackgroundColor)))
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
            var failed = false
            let all = Accounts.load()
            for a in all {
                let label = all.count > 1 ? "\(a.name): " : ""
                do {
                    let s = try Limits.fetchLive(account: a.id)
                    print(label + "5h \(s.five_hour.map { "\($0.used_percentage)%" } ?? "-") · 7d \(s.seven_day.map { "\($0.used_percentage)%" } ?? "-")"
                          + (s.models ?? []).map { " · 7d \($0.name) \($0.used_percentage)%" }.joined())
                } catch { print(label + error.localizedDescription); if a.id == Accounts.mainID { failed = true } }
            }
            if failed { exit(1) }
            return
        }
        if let i = args.firstIndex(of: "--set-hook"), i + 1 < args.count {
            do { try Limits.setHook(args[i + 1] == "on"); print("ok") } catch { print(error.localizedDescription); exit(1) }
            return
        }
        let app = NSApplication.shared
        if let i = args.firstIndex(of: "--screenshot-history"), i + 1 < args.count {
            exit(screenshot(to: args[i + 1], dark: args.contains("dark"), history: true) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            exit(screenshot(to: args[i + 1], dark: args.contains("dark")) ? 0 : 1)
        }
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(d) { app.run() }
    }
}
