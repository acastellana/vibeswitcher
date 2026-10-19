import AppKit
import Foundation
import ServiceManagement
import UserNotifications
import VibeCore

/// User-facing toggles, persisted in UserDefaults. Every one is in Settings; the ⚙︎ menu repeats a few.
final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    private let presetsFile: URL

    @Published var notifyNeedsInput: Bool { didSet { defaults.set(notifyNeedsInput, forKey: "notifyNeedsInput") } }
    @Published var notifyDone: Bool { didSet { defaults.set(notifyDone, forKey: "notifyDone") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    /// One reminder when a session has waited on you 10+ min, or shown no progress for 15+ min.
    @Published var notifyReminders: Bool { didSet { defaults.set(notifyReminders, forKey: "notifyReminders") } }
    /// Pausing a session minimizes its window (when it's the only tab there); resuming restores it.
    @Published var minimizeOnPause: Bool { didSet { defaults.set(minimizeOnPause, forKey: "minimizeOnPause") } }
    /// Docked session list on the right; picking a session shows only its window, on this desktop.
    @Published var sidebarMode: Bool { didSet { defaults.set(sidebarMode, forKey: "sidebarMode") } }
    /// Sidebar slides in at the right screen edge instead of staying docked.
    @Published var sidebarAutoHide: Bool { didSet { defaults.set(sidebarAutoHide, forKey: "sidebarAutoHide") } }
    @Published var sessionOrder: SessionOrder {
        didSet { defaults.set(sessionOrder.rawValue, forKey: "sessionOrder") }
    }
    /// What "New session" runs, e.g. `claude` or `claude --model opus`.
    @Published var claudeCommand: String { didSet { defaults.set(claudeCommand, forKey: "claudeCommand") } }
    @Published var codexCommand: String { didSet { defaults.set(codexCommand, forKey: "codexCommand") } }
    @Published private(set) var launchAtLogin: Bool
    /// Mirrors the system permission, for the popover banner.
    @Published var notificationsAllowed = true
    @Published var floatingPanel: FloatingPanelMode {
        didSet { defaults.set(floatingPanel.rawValue, forKey: "floatingPanel") }
    }
    /// Launch presets, in ~/.vibeswitcher/presets.json (the first load migrates the two launch commands).
    @Published var presets: LaunchPresets {
        didSet { if presetsCanSave { try? presets.save(to: presetsFile) } }
    }
    /// What couldn't be read from presets.json at launch, for the one notice that says so (nil: it read fine).
    let presetsNotice: String?
    /// False when presets.json couldn't be read and couldn't be copied aside: saving would lose it.
    private let presetsCanSave: Bool
    @Published var appearance: TerminalAppearance {
        didSet { defaults.set(try? JSONEncoder().encode(appearance), forKey: "terminalAppearance") }
    }
    /// Show the window when VibeSwitcher starts.
    @Published var openWindowAtLaunch: Bool { didSet { defaults.set(openWindowAtLaunch, forKey: "openWindowAtLaunch") } }
    /// The Team view says what each agent is doing in plain words, written by a small model (headless `claude -p`).
    @Published var aiSummaries: Bool { didSet { defaults.set(aiSummaries, forKey: "aiSummaries") } }
    /// Keep the Mac from idle sleep while a lead's team works (see `KeepAwake`).
    @Published var keepAwake: KeepAwakeMode { didSet { defaults.set(keepAwake.rawValue, forKey: "keepAwake") } }

    /// `defaults` and `presetsFile` are for tests and offscreen renders; the app uses the standard ones.
    init(defaults: UserDefaults = .standard, presetsFile: URL = VibePaths.presetsFile) {
        self.defaults = defaults
        self.presetsFile = presetsFile
        defaults.register(defaults: ["notifyNeedsInput": true, "notifyDone": true, "playSound": true, "notifyReminders": true, "minimizeOnPause": true, "sidebarAutoHide": true, "aiSummaries": true,
                                     "claudeCommand": "claude", "codexCommand": "codex"])
        notifyNeedsInput = defaults.bool(forKey: "notifyNeedsInput")
        notifyDone = defaults.bool(forKey: "notifyDone")
        playSound = defaults.bool(forKey: "playSound")
        notifyReminders = defaults.bool(forKey: "notifyReminders")
        minimizeOnPause = defaults.bool(forKey: "minimizeOnPause")
        claudeCommand = defaults.string(forKey: "claudeCommand") ?? "claude"
        sidebarMode = defaults.bool(forKey: "sidebarMode")
        sidebarAutoHide = defaults.bool(forKey: "sidebarAutoHide")
        sessionOrder = SessionOrder(rawValue: defaults.string(forKey: "sessionOrder") ?? "") ?? .screen
        codexCommand = defaults.string(forKey: "codexCommand") ?? "codex"
        launchAtLogin = SMAppService.mainApp.status == .enabled
        floatingPanel = FloatingPanelMode(rawValue: defaults.string(forKey: "floatingPanel") ?? "") ?? .automatic
        // Locals, not the @Published properties: those can't be read before init finishes.
        let loaded = LaunchPresets.loadChecked(from: presetsFile,
                                               claudeCommand: defaults.string(forKey: "claudeCommand") ?? "claude",
                                               codexCommand: defaults.string(forKey: "codexCommand") ?? "codex")
        presets = loaded.presets
        presetsNotice = loaded.notice
        presetsCanSave = loaded.canSave
        appearance = defaults.data(forKey: "terminalAppearance")
            .flatMap { try? JSONDecoder().decode(TerminalAppearance.self, from: $0) } ?? TerminalAppearance()
        openWindowAtLaunch = defaults.bool(forKey: "openWindowAtLaunch")
        aiSummaries = defaults.bool(forKey: "aiSummaries")
        keepAwake = KeepAwakeMode(rawValue: defaults.string(forKey: "keepAwake") ?? "") ?? .onPower
    }

    func command(for agent: Agent) -> String {
        let kind: LaunchPreset.Kind = agent == .claude ? .claude : .codex
        return presets.global.first { $0.kind == kind }.flatMap(LaunchPlan.command(for:)) ?? agent.rawValue
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("VibeSwitcher: login item change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

enum FloatingPanelMode: String, CaseIterable {
    /// Only when the menu bar icon is hidden (crowded menu bar / notch).
    case automatic
    case always
    case never

    var label: String {
        switch self {
        case .automatic: return "When the menu bar icon is hidden"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

/// Posts "needs your input" / "done" banners; clicking one focuses that session's tab.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let preferences: Preferences
    var onOpen: ((String) -> Void)?
    /// Every alert that passed the notification settings (title, text, tty), whether or not the Mac
    /// may show banners: Phone Access mirrors them.
    var onAlert: ((String, String, String) -> Void)?
    /// nil until the first check, so a permission that is already on doesn't trigger the test banner.
    private var allowed: Bool?

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("VibeSwitcher: notification authorization failed: \(error)") }
            self.refreshAuthorization()
        }
    }

    /// Re-reads the permission (it only changes in System Settings, while we're running), and confirms
    /// with a test banner the moment it gets switched on.
    func refreshAuthorization() {
        center.getNotificationSettings { settings in
            let allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
                && settings.alertSetting != .disabled
            DispatchQueue.main.async {
                let wasAllowed = self.allowed
                self.allowed = allowed
                self.preferences.notificationsAllowed = allowed
                AppStatus.extras["notificationsAllowed"] = allowed
                if allowed, wasAllowed == false { self.postTest() }
            }
        }
    }

    /// The permission as setup shows it: allowed, turned off, or never asked. Doesn't ask.
    func readAccess(_ done: @escaping (NotificationAccess) -> Void) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined: done(.notAsked)
            case .authorized, .provisional, .ephemeral: done(settings.alertSetting == .disabled ? .off : .allowed)
            default: done(.off)
            }
        }
    }

    /// macOS's prompt if it hasn't asked yet (System Settings doesn't list the app before that), else System Settings.
    func askOrOpenSettings() {
        readAccess { access in
            DispatchQueue.main.async { access == .notAsked ? self.requestAuthorization() : Self.openSettings() }
        }
    }

    /// Opens System Settings › Notifications › VibeSwitcher.
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.vibeswitcher.VibeSwitcher"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func postTest() {
        let content = UNMutableNotificationContent()
        content.title = "VibeSwitcher notifications are on"
        content.body = "You'll get a banner when a session needs your input or finishes. Click one to jump to it."
        center.add(UNNotificationRequest(identifier: "vibeswitcher-test", content: content, trigger: nil))
        AppStatus.extras["lastAlert"] = "test \(ISO8601DateFormatter().string(from: Date()))"
    }

    func post(for session: Session) {
        let needsInput = session.status == .needsInput
        guard needsInput ? preferences.notifyNeedsInput : preferences.notifyDone else { return }
        AppStatus.extras["lastAlert"] = "\(session.status.rawValue) \(session.tty) \(ISO8601DateFormatter().string(from: Date()))"
        let title = needsInput ? "\(session.displayName) needs your input" : "\(session.displayName) is done"
        onAlert?(title, [session.task, session.detail].compactMap { $0 }.joined(separator: "\n"), session.tty)
        // Without notification permission, at least make a sound when something is blocked on you.
        guard allowed == true else {
            if needsInput, preferences.playSound { NSSound(named: "Ping")?.play() }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = needsInput ? "\(session.displayName) needs your input" : "\(session.displayName) is done"
        content.subtitle = session.task ?? session.agent.displayName
        if let detail = session.detail { content.body = detail }
        content.sound = needsInput && preferences.playSound ? .default : nil
        content.userInfo = ["tty": session.tty]
        // One notification per terminal: a newer state replaces the older banner.
        center.add(UNNotificationRequest(identifier: session.tty, content: content, trigger: nil))
    }

    func post(_ nudge: Nudge, for session: Session) {
        guard preferences.notifyReminders else { return }
        AppStatus.extras["lastAlert"] = "reminder \(session.tty) \(ISO8601DateFormatter().string(from: Date()))"
        defer { onAlert?(nudgeTitle(nudge, session), session.activity ?? session.detail ?? "", session.tty) }
        guard allowed == true else { return }
        let content = UNMutableNotificationContent()
        let task = session.task.map { " · \($0)" } ?? ""
        switch nudge {
        case .stillWaiting(let minutes):
            content.title = "\(session.displayName) is still waiting for you"
            content.subtitle = "For \(minutes) min" + task
            content.body = session.detail ?? ""
            content.sound = preferences.playSound ? .default : nil
        case .stalled(let minutes):
            if let activity = session.activity {
                // A long command may be legitimate (a build, a test suite): say what, and let you judge.
                content.title = "\(session.displayName): one command running for \(minutes) min"
                content.subtitle = activity
                content.body = "No other progress since it started. Check it isn't stuck."
            } else {
                content.title = "\(session.displayName) may be stuck"
                content.subtitle = "No progress for \(minutes) min" + task
            }
        }
        content.userInfo = ["tty": session.tty]
        center.add(UNNotificationRequest(identifier: session.tty, content: content, trigger: nil))
    }

    private func nudgeTitle(_ nudge: Nudge, _ session: Session) -> String {
        switch nudge {
        case .stillWaiting(let minutes): return "\(session.displayName) is still waiting for you (\(minutes) min)"
        case .stalled(let minutes):
            return session.activity != nil ? "\(session.displayName): one command running for \(minutes) min"
                                           : "\(session.displayName) may be stuck (\(minutes) min)"
        }
    }

    /// A plain informational banner (pairings, remote input).
    func postInfo(title: String, body: String) {
        guard allowed == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func clear(tty: String) {
        center.removeDeliveredNotifications(withIdentifiers: [tty])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let tty = response.notification.request.content.userInfo["tty"] as? String {
            DispatchQueue.main.async { self.onOpen?(tty) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
