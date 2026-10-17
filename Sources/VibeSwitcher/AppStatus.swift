import Foundation
import VibeCore

/// Mirrors what the running app sees into `~/.vibeswitcher/app-status.json`, for debugging from a shell
/// (`cat ~/.vibeswitcher/app-status.json`) without needing to open the popover.
enum AppStatus {
    static var url: URL { VibePaths.root.appendingPathComponent("app-status.json") }
    /// Sticky fields included in every write (e.g. whether the hotkey registered).
    static var extras: [String: Any] = [:]
    /// Off for command-line runs (e.g. `--snapshot`), so they don't overwrite what the running app reports.
    static var enabled = true
    static let toggleNotification = Notification.Name("dev.vibeswitcher.toggle")
    static let openNotification = Notification.Name("dev.vibeswitcher.open")
    static let windowNotification = Notification.Name("dev.vibeswitcher.window")
    static let leadNotification = Notification.Name("dev.vibeswitcher.lead")
    static let screenNotification = Notification.Name("dev.vibeswitcher.screen")
    static let captureNotification = Notification.Name("dev.vibeswitcher.capture-window")
    static let settingsNotification = Notification.Name("dev.vibeswitcher.settings")
    static let newSessionNotification = Notification.Name("dev.vibeswitcher.new")

    /// Writes go out in order, off the main thread: the tab bars are Accessibility calls into Terminal, which wait
    /// for it (seconds when it's busy or hung).
    private static let queue = DispatchQueue(label: "vibeswitcher.app-status", qos: .utility)

    /// Called on the main thread; it only takes a copy of what's shown there.
    static func write(sessions: [Session], terminalAccess: TerminalAccess, extra: [String: Any] = [:]) {
        guard enabled else { return }
        var object: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "terminalAccess": "\(terminalAccess)",
            "sessions": sessions.map { ["tty": $0.tty, "agent": $0.agent.rawValue, "status": $0.status.rawValue,
                                        "title": $0.title, "hooks": $0.hasHooks,
                                        "desktop": $0.screenPosition?.desktop ?? 0, "tab": $0.screenPosition?.tabIndex ?? 0,
                                        "paused": $0.isPaused] },
        ]
        object.merge(extras) { $1 }
        object.merge(extra) { $1 }
        guard JSONSerialization.isValidJSONObject(object) else { return }
        let snapshot = Snapshot(object: object)
        let url = self.url
        queue.async {
            var object = snapshot.object
            object["accessibilityTrusted"] = TabOrder.isTrusted
            object["tabBars"] = TabOrder.tabBars()
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Plain JSON values only (checked above), so it can cross to the writer's queue.
    private struct Snapshot: @unchecked Sendable { let object: [String: Any] }
}
