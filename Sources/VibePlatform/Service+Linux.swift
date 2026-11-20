#if os(Linux)
import Foundation

// Linux: the user's systemd and journald, by their fixed paths (the node's tools have always been run so).
extension Platform.Service {
    enum System {
        static let manager = Manager.systemd
        static let log = Log.journal
        static let systemctl: String? = "/usr/bin/systemctl"
        static let journalctl: String? = "/usr/bin/journalctl"
        static let launchctl: String? = nil
        static let unifiedLogTool: String? = nil
        static func runtimeFolder(uid: uid_t) -> String? { "/run/user/\(uid)" }
    }
}
#endif
