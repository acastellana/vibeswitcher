import AppKit
import SwiftUI
import UserNotifications
import VibeCore

/// macOS's notification permission, as setup shows it.
enum NotificationAccess: Equatable { case allowed, off, notAsked }

/// Whether to open the welcome window: only on a Mac VibeSwitcher has never run on.
enum FirstRun {
    static let shownKey = "welcomeShown"
    /// Set by versions before the welcome window, on their first launch from the app bundle.
    static let legacyLaunchedKey = "didSetUpLoginItem"

    /// Checked before `~/.vibeswitcher/state` is created at launch: a Mac with that folder, or with our hooks in
    /// either agent's config, has run VibeSwitcher before.
    static func shouldWelcome(defaults: UserDefaults, stateDirExists: Bool, hooksInstalled: [Agent: Bool]) -> Bool {
        guard !defaults.bool(forKey: shownKey), !defaults.bool(forKey: legacyLaunchedKey) else { return false }
        return !stateDirExists && !hooksInstalled.values.contains(true)
    }
}

/// What setup reads and changes outside the app: hooks, permissions. `live` in the app; renders pass fixed answers.
struct SetupSystem {
    var hooksInstalled: () -> [Agent: Bool]
    /// Blocking. Returns problems, empty on success.
    var installHooks: () -> [String]
    /// Blocking. Returns a problem, nil on success.
    var uninstallHooks: (Agent) -> String?
    /// Blocking. How many hooks were newly trusted.
    var trustCodex: () -> Result<Int, Error>
    /// Blocking when `ask`: macOS's "control Terminal" dialog waits for an answer.
    var terminalAccess: (_ ask: Bool) -> AutomationAccess
    var notificationAccess: (@escaping (NotificationAccess) -> Void) -> Void
    /// macOS's prompt, or System Settings once it has been answered.
    var allowNotifications: () -> Void
    var tabOrderAllowed: () -> Bool
    var requestTabOrder: () -> Void
    var open: (URL) -> Void

    static func live(notifier: Notifier?) -> SetupSystem {
        SetupSystem(
            hooksInstalled: { Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, HookInstaller.isInstalled(agent: $0)) }) },
            installHooks: { HookSetup.installAll() },
            uninstallHooks: { agent in
                do { try HookInstaller.uninstall(agent: agent); return nil } catch {
                    return "\(agent.displayName): \(error.localizedDescription)"
                }
            },
            trustCodex: { Result { try CodexTrust.trustOurHooks() } },
            terminalAccess: { TerminalControl.access(ask: $0) },
            notificationAccess: { done in
                guard let notifier else { return done(.off) }
                notifier.readAccess(done)
            },
            allowNotifications: { notifier.map { $0.askOrOpenSettings() } ?? Notifier.openSettings() },
            tabOrderAllowed: { TabOrder.isTrusted },
            requestTabOrder: { TabOrder.requestTrust() },
            open: { NSWorkspace.shared.open($0) })
    }

    static func fixed(hooks: [Agent: Bool], terminal: AutomationAccess, notifications: NotificationAccess) -> SetupSystem {
        SetupSystem(hooksInstalled: { hooks }, installHooks: { [] }, uninstallHooks: { _ in nil }, trustCodex: { .success(0) },
                    terminalAccess: { _ in terminal }, notificationAccess: { $0(notifications) }, allowNotifications: {},
                    tabOrderAllowed: { false }, requestTabOrder: {}, open: { _ in })
    }
}

/// Asking for, and reading, permission to send Terminal the Apple Events that read tab titles and select tabs.
enum TerminalControl {
    /// With `ask`, macOS shows its dialog if it hasn't been answered yet, opening Terminal first if needed (macOS
    /// can only ask about a running app). Blocks until the user answers: call it off the main thread.
    static func access(ask: Bool) -> AutomationAccess {
        if ask, !TerminalBridge.isRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalBridge.bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            for _ in 0..<50 where !TerminalBridge.isRunning { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalBridge.bundleID).first
        else { return .appNotRunning }
        var pid = terminal.processIdentifier
        var target = AEAddressDesc()
        let created = AECreateDesc(DescType(typeKernelProcessID), &pid, MemoryLayout<pid_t>.size, &target)
        guard created == noErr else { return .unknown(Int32(created)) }
        defer { AEDisposeDesc(&target) }
        // Reading tab properties: "get data" of the core suite, like the tab scan.
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), ask)
        return AutomationAccess(status: status)
    }

    /// Privacy & Security › Automation.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}

/// The live state of each setup piece and the actions that change it: shared by the welcome window and Settings.
final class SetupModel: ObservableObject {
    enum Work: Equatable { case installing, uninstalling, trusting, askingTerminal }

    @Published var hooks: [Agent: Bool] = [:]
    @Published var terminal: AutomationAccess?
    @Published var notifications: NotificationAccess?
    @Published var tabOrderAllowed = false
    @Published private(set) var working: Work?
    /// The last hook or trust action's outcome, and whether it went wrong.
    @Published private(set) var outcome: (text: String, failed: Bool)?
    let preferences: Preferences
    private let system: SetupSystem
    /// After hooks change (the popover's banner and rows follow them).
    var onHooksChanged: () -> Void = {}
    private var timer: Timer?
    private var watchers = 0

    init(preferences: Preferences, system: SetupSystem) {
        self.preferences = preferences
        self.system = system
    }

    var allHooksInstalled: Bool { Agent.allCases.allSatisfy { hooks[$0] == true } }
    var anyHooksInstalled: Bool { hooks.values.contains(true) }

    /// While a window shows the state, it's re-read every second: permissions change in System Settings.
    func watch() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let system = system
        DispatchQueue.global(qos: .userInitiated).async {
            let hooks = system.hooksInstalled()
            let terminal = system.terminalAccess(false)
            let tabOrder = system.tabOrderAllowed()
            DispatchQueue.main.async {
                if self.hooks != hooks { self.hooks = hooks }
                // An ask in flight has the fresher answer coming.
                if self.working != .askingTerminal, self.terminal != terminal { self.terminal = terminal }
                if self.tabOrderAllowed != tabOrder { self.tabOrderAllowed = tabOrder }
            }
        }
        system.notificationAccess { access in
            DispatchQueue.main.async { if self.notifications != access { self.notifications = access } }
        }
    }

    func installHooks() {
        run(.installing) { system in
            let problems = system.installHooks()
            return problems.isEmpty
                ? ("Installed. Running Claude Code sessions pick them up now; restart Codex sessions started before.", false)
                : (problems.joined(separator: "\n"), true)
        }
    }

    func uninstallHooks() {
        run(.uninstalling) { system in
            let problems = Agent.allCases.compactMap(system.uninstallHooks)
            return problems.isEmpty ? ("Removed. Sessions show as Unknown until hooks are installed again.", false)
                                    : (problems.joined(separator: "\n"), true)
        }
    }

    func trustCodex() {
        run(.trusting) { system in
            switch system.trustCodex() {
            case .success(let count):
                return (count == 0 ? "Codex already trusts VibeSwitcher's hooks." : "Codex now trusts VibeSwitcher's hooks.", false)
            case .failure(let error):
                return ("Couldn't trust them (\(error.localizedDescription)). Run /hooks in Codex and trust the vibeswitcher-hook entries.", true)
            }
        }
    }

    private func run(_ work: Work, _ body: @escaping (SetupSystem) -> (String, Bool)) {
        guard working == nil else { return }
        working = work
        outcome = nil
        let system = system
        DispatchQueue.global(qos: .userInitiated).async {
            let (text, failed) = body(system)
            DispatchQueue.main.async {
                self.working = nil
                self.outcome = (text, failed)
                self.onHooksChanged()
                self.refresh()
            }
        }
    }

    /// Shows macOS's "control Terminal" dialog, or System Settings once it has been answered no.
    func allowTerminal() {
        if terminal == .denied { return system.open(TerminalControl.settingsURL) }
        guard working == nil else { return }
        working = .askingTerminal
        let system = system
        DispatchQueue.global(qos: .userInitiated).async {
            let access = system.terminalAccess(true)
            DispatchQueue.main.async {
                self.working = nil
                self.terminal = access
            }
        }
    }

    func allowNotifications() { system.allowNotifications() }

    func allowTabOrder() { system.requestTabOrder() }

    // MARK: Words

    var terminalStatus: SetupStatus {
        switch terminal {
        case .allowed?: return .ok("Allowed")
        case .denied?: return .problem("Not allowed. Turn on Terminal under VibeSwitcher in System Settings › Privacy & Security › Automation.")
        case .notAsked?: return .pending("Not asked yet")
        case .appNotRunning?: return .pending("Terminal isn't open. Allow… opens it so macOS can ask.")
        case .unknown(let code)?: return .problem("Couldn't check (error \(code))")
        case nil: return .pending("Checking…")
        }
    }

    var terminalButton: String { terminal == .denied ? "Open System Settings…" : "Allow…" }

    var notificationStatus: SetupStatus {
        switch notifications {
        case .allowed?: return .ok("Allowed")
        case .off?: return .problem("Off. Turn them on in System Settings › Notifications › VibeSwitcher.")
        case .notAsked?: return .pending("Not asked yet")
        case nil: return .pending("Checking…")
        }
    }

    var notificationButton: String { notifications == .notAsked ? "Allow Notifications…" : "Open System Settings…" }

    func hookStatus(_ agent: Agent) -> SetupStatus {
        switch hooks[agent] {
        case true?: return .ok("Installed")
        case false?: return .pending("Not installed")
        case nil: return .pending("Checking…")
        }
    }
}

/// One setup piece's state in words, with a symbol so it doesn't rely on colour.
enum SetupStatus: Equatable {
    case ok(String), pending(String), problem(String)

    var isOK: Bool { if case .ok = self { return true } else { return false } }
}

struct SetupStatusLabel: View {
    let status: SetupStatus

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout)
    }

    private var text: String {
        switch status { case .ok(let t), .pending(let t), .problem(let t): return t }
    }
    private var symbol: String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .pending: return "circle.dashed"
        case .problem: return "exclamationmark.circle.fill"
        }
    }
    private var color: Color {
        switch status {
        case .ok: return .green
        case .pending: return .secondary
        case .problem: return .orange
        }
    }
}

// MARK: - Welcome window

enum OnboardingStep: Int, CaseIterable {
    case welcome, hooks, terminal, notifications, login

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .hooks: return "Live status"
        case .terminal: return "Terminal"
        case .notifications: return "Notifications"
        case .login: return "Open at login"
        }
    }
}

/// Where the welcome window is, and what the user chose on the way.
final class OnboardingFlow: ObservableObject {
    @Published var step: OnboardingStep = .welcome
    @Published var skipped: Set<OnboardingStep> = []
    /// The login step's switch: on by default the first time, and only applied when the user leaves the step with Done.
    @Published var openAtLogin: Bool

    init(openAtLogin: Bool) { self.openAtLogin = openAtLogin }
}

/// Shown on first launch, and again from Settings › General › Show Welcome…
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let flow: OnboardingFlow
    private let setup: SetupModel
    private var watching = false

    init(setup: SetupModel, firstRun: Bool) {
        self.setup = setup
        flow = OnboardingFlow(openAtLogin: firstRun || setup.preferences.launchAtLogin)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: OnboardingView.size.width, height: OnboardingView.size.height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to VibeSwitcher"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(setup: setup, flow: flow) { [weak self] in self?.finish() })
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        flow.step = .welcome
        flow.skipped = []
        flow.openAtLogin = flow.openAtLogin || setup.preferences.launchAtLogin
        if !watching { setup.watch(); watching = true }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate()
    }

    /// Done on the last step: the login item follows the switch.
    private func finish() {
        if flow.openAtLogin != setup.preferences.launchAtLogin { setup.preferences.setLaunchAtLogin(flow.openAtLogin) }
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if watching { setup.unwatch(); watching = false }
    }
}

struct OnboardingView: View {
    static let size = CGSize(width: 640, height: 440)
    @ObservedObject var setup: SetupModel
    @ObservedObject var flow: OnboardingFlow
    @ObservedObject private var preferences: Preferences
    let finish: () -> Void

    init(setup: SetupModel, flow: OnboardingFlow, finish: @escaping () -> Void) {
        self.setup = setup
        self.flow = flow
        preferences = setup.preferences
        self.finish = finish
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Button { flow.step = step } label: {
                    HStack(spacing: 8) {
                        railSymbol(step)
                        Text(step.title).fontWeight(step == flow.step ? .semibold : .regular)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(step == flow.step ? Color.primary.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(step.title), \(railState(step))")
            }
            Spacer()
            Text("Everything here is also in Settings (⌘,).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
        }
        .padding(.top, 44).padding(.bottom, 20).padding(.horizontal, 10)
        .frame(width: 180)
        .background(Color.primary.opacity(0.03))
    }

    private func isDone(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome: return flow.step != .welcome
        case .hooks: return setup.allHooksInstalled
        case .terminal: return setup.terminal == .allowed
        case .notifications: return setup.notifications == .allowed
        case .login: return preferences.launchAtLogin
        }
    }

    private func railState(_ step: OnboardingStep) -> String {
        isDone(step) ? "done" : flow.skipped.contains(step) ? "skipped" : step == flow.step ? "current" : "to do"
    }

    @ViewBuilder private func railSymbol(_ step: OnboardingStep) -> some View {
        if isDone(step) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if flow.skipped.contains(step) {
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        } else if step == flow.step {
            Image(systemName: "circle.circle.fill").foregroundStyle(Color.accentColor)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch flow.step {
        case .welcome: welcome
        case .hooks: hooks
        case .terminal: terminal
        case .notifications: notifications
        case .login: login
        }
    }

    private func header(_ symbol: String, _ title: String, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(Color.accentColor)
            Text(title).font(.title2.weight(.semibold))
            Text(why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("circle.grid.2x2.fill", "Welcome to VibeSwitcher",
                   "See every Claude Code and Codex session at a glance, and jump to the one that needs you.")
            VStack(alignment: .leading, spacing: 8) {
                Text("It lives in the menu bar, one dot per session:").font(.callout)
                HStack(spacing: 16) {
                    ForEach([SessionStatus.needsInput, .working, .done, .idle], id: \.self) { status in
                        HStack(spacing: 6) {
                            Circle().fill(status.color).frame(width: 10, height: 10)
                            Text(status == .needsInput ? "Needs you" : status.label).font(.callout)
                        }
                    }
                }
                Text("Click a dot to jump to its tab. ⌃⌥V opens the list from anywhere.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Four quick steps set it up. Each one is optional and can be changed later in Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hooks: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("waveform.path.ecg", "Live status from hooks",
                   "Claude Code and Codex tell VibeSwitcher what they're doing through hooks: a small command they run when "
                   + "you send a prompt, a tool runs, or a session waits for you or finishes. Without them, every session shows as Unknown.")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Agent.allCases, id: \.self) { agent in
                    HStack(alignment: .firstTextBaseline) {
                        Text(agent.displayName).frame(width: 96, alignment: .leading)
                        SetupStatusLabel(status: setup.hookStatus(agent))
                    }
                }
            }
            Text("Adds VibeSwitcher's entries beside yours in ~/.claude/settings.json and ~/.codex/hooks.json, and marks "
                 + "them trusted in ~/.codex/config.toml. The first install keeps a copy of each file as …vibeswitcher-backup. "
                 + "Uninstall any time in Settings › Agents.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                action(setup.allHooksInstalled ? "Reinstall Hooks" : "Install Hooks", done: setup.allHooksInstalled,
                       busy: setup.working == .installing) { setup.installHooks() }
                if let outcome = setup.outcome {
                    Text(outcome.text).font(.caption).foregroundStyle(outcome.failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("terminal", "Control Terminal",
                   "For sessions in Terminal, VibeSwitcher reads each tab's title and brings the right tab to the front "
                   + "when you click its dot. macOS asks you once to allow it.")
            SetupStatusLabel(status: setup.terminalStatus)
            action(setup.terminalButton, done: setup.terminal == .allowed, busy: setup.working == .askingTerminal) {
                setup.allowTerminal()
            }
            Text("Sessions you start in VibeSwitcher's own window don't need this.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("bell.badge", "Notifications",
                   "A banner when a session needs your input or finishes, saying what it's asking. Click it to jump "
                   + "there. Without them you still hear a sound when a session needs you.")
            SetupStatusLabel(status: setup.notificationStatus)
            action(setup.notificationButton, done: setup.notifications == .allowed, busy: false) { setup.allowNotifications() }
            Text("Choose which ones you get, and reminders about waiting or stuck sessions, in Settings › General.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var login: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("power", "Open at login",
                   "VibeSwitcher only sees sessions while it's running. Opening it at login keeps the dots there whenever an agent is.")
            Toggle("Open VibeSwitcher when I log in", isOn: $flow.openAtLogin).toggleStyle(.switch)
            Text("Applied when you click Done. Change it any time in Settings › General.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer().frame(height: 6)
            Label("Find VibeSwitcher in the menu bar, near the clock. Press ⌘, there for Settings.", systemImage: "menubar.arrow.up.rectangle")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The step's one action: prominent until it's done.
    @ViewBuilder private func action(_ title: String, done: Bool, busy: Bool, _ perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if done {
                Button(title, action: perform).disabled(busy)
            } else {
                Button(title, action: perform).buttonStyle(.borderedProminent).disabled(busy)
            }
            if busy { ProgressView().controlSize(.small) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if flow.step != .welcome {
                Button("Back") { move(-1) }
            }
            Spacer()
            switch flow.step {
            case .welcome:
                Button("Get Started") { move(1) }.keyboardShortcut(.defaultAction)
            case .login:
                Button("Skip") { flow.skipped.insert(.login); finishSkippingLogin() }
                Button("Done", action: finish).keyboardShortcut(.defaultAction)
            default:
                if isDone(flow.step) {
                    Button("Continue") { move(1) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip") {
                        flow.skipped.insert(flow.step)
                        move(1)
                    }
                }
            }
        }
    }

    /// Skip on the last step closes without touching the login item.
    private func finishSkippingLogin() {
        flow.openAtLogin = preferences.launchAtLogin
        finish()
    }

    private func move(_ delta: Int) {
        if let next = OnboardingStep(rawValue: flow.step.rawValue + delta) { flow.step = next }
    }
}
