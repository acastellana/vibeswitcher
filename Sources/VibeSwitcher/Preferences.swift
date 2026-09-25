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
    @Published private(set) var launchAtLogin: Bool

    init() {
        defaults.register(defaults: ["notifyNeedsInput": true, "notifyDone": true])
        notifyNeedsInput = defaults.bool(forKey: "notifyNeedsInput")
        notifyDone = defaults.bool(forKey: "notifyDone")
        launchAtLogin = SMAppService.mainApp.status == .enabled
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

/// Posts "needs your input" / "done" banners; clicking one focuses that session's tab.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let preferences: Preferences
    var onOpen: ((String) -> Void)?
    private var allowed = false

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("VibeSwitcher: notification authorization failed: \(error)") }
            DispatchQueue.main.async {
                self.allowed = granted
                AppStatus.extras["notificationsAllowed"] = granted
            }
        }
    }

    func post(for session: Session) {
        let needsInput = session.status == .needsInput
        guard needsInput ? preferences.notifyNeedsInput : preferences.notifyDone else { return }
        AppStatus.extras["lastAlert"] = "\(session.status.rawValue) \(session.tty) \(ISO8601DateFormatter().string(from: Date()))"
        // Without notification permission, at least make a sound when something is blocked on you.
        guard allowed else {
            if needsInput { NSSound(named: "Ping")?.play() }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = needsInput ? "\(session.agent.displayName) needs your input" : "\(session.agent.displayName) is done"
        content.subtitle = session.title
        if let detail = session.detail { content.body = detail }
        content.sound = needsInput ? .default : nil
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
