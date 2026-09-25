import AppKit
import Foundation
import ServiceManagement
import UserNotifications
import VibeCore

/// User-facing toggles, persisted in UserDefaults.
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var notifyNeedsInput: Bool { didSet { defaults.set(notifyNeedsInput, forKey: "notifyNeedsInput") } }
    @Published var notifyDone: Bool { didSet { defaults.set(notifyDone, forKey: "notifyDone") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    /// What "New session" runs, e.g. `claude` or `claude --model opus`.
    @Published var claudeCommand: String { didSet { defaults.set(claudeCommand, forKey: "claudeCommand") } }
    @Published var codexCommand: String { didSet { defaults.set(codexCommand, forKey: "codexCommand") } }
    @Published private(set) var launchAtLogin: Bool
    /// Mirrors the system permission, for the popover banner.
    @Published var notificationsAllowed = true
    @Published var floatingPanel: FloatingPanelMode {
        didSet { defaults.set(floatingPanel.rawValue, forKey: "floatingPanel") }
    }

    init() {
        defaults.register(defaults: ["notifyNeedsInput": true, "notifyDone": true, "playSound": true,
                                     "claudeCommand": "claude", "codexCommand": "codex"])
        notifyNeedsInput = defaults.bool(forKey: "notifyNeedsInput")
        notifyDone = defaults.bool(forKey: "notifyDone")
        playSound = defaults.bool(forKey: "playSound")
        claudeCommand = defaults.string(forKey: "claudeCommand") ?? "claude"
        codexCommand = defaults.string(forKey: "codexCommand") ?? "codex"
        launchAtLogin = SMAppService.mainApp.status == .enabled
        floatingPanel = FloatingPanelMode(rawValue: defaults.string(forKey: "floatingPanel") ?? "") ?? .automatic
    }

    func command(for agent: Agent) -> String {
        let command = (agent == .claude ? claudeCommand : codexCommand).trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? agent.rawValue : command
    }

    /// Registers the login item once, on first launch from an app bundle; after that the toggle decides.
    func setUpLoginItemOnFirstLaunch() {
        guard Bundle.main.bundlePath.hasSuffix(".app"), !defaults.bool(forKey: "didSetUpLoginItem") else { return }
        defaults.set(true, forKey: "didSetUpLoginItem")
        setLaunchAtLogin(true)
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
