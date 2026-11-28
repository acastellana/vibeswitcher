#if os(Linux)
import Foundation
import VibeKeep

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
        // No app here: the node's root is the account's `~/.vibeswitcher`, as it has always been.
        static let nodeRootFolder = ".vibeswitcher"
        // No such record on Linux: its checks are the unit's cgroup and the sealed copies (unchanged). The keeper's
        // package's (Keeper/Sources/VibeKeep/Service+Linux.swift).
        static func nodePinsRecord(uid: uid_t) -> [String]? { Keep.Service.nodePinsRecord(uid: uid) }
    }
}
#endif
