import Foundation
import VibeCore

/// Mirrors what the running app sees into `~/.vibeswitcher/app-status.json`, for debugging from a shell
/// (`cat ~/.vibeswitcher/app-status.json`) without needing to open the popover.
enum AppStatus {
    static var url: URL { VibePaths.root.appendingPathComponent("app-status.json") }
    /// Sticky fields included in every write (e.g. whether the hotkey registered).
    static var extras: [String: Any] = [:]
    static let toggleNotification = Notification.Name("dev.vibeswitcher.toggle")
    static let openNotification = Notification.Name("dev.vibeswitcher.open")

    static func write(sessions: [Session], terminalAccess: TerminalAccess, extra: [String: Any] = [:]) {
        var object: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "terminalAccess": "\(terminalAccess)",
            "sessions": sessions.map { ["tty": $0.tty, "agent": $0.agent.rawValue, "status": $0.status.rawValue,
                                        "title": $0.title, "hooks": $0.hasHooks] },
        ]
        object.merge(extras) { $1 }
        object.merge(extra) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
