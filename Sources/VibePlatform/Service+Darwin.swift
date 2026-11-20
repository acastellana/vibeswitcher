#if canImport(Darwin)
import Foundation

// The Mac: launchd and the unified log, by their fixed paths. No runtime folder (launchd is reached through its
// Mach port). Nothing here runs either tool: the node's start on the Mac isn't built yet (`NodeSystem`).
extension Platform.Service {
    enum System {
        static let manager = Manager.launchd
        static let log = Log.unifiedLog
        static let systemctl: String? = nil
        static let journalctl: String? = nil
        static let launchctl: String? = "/bin/launchctl"
        static let unifiedLogTool: String? = "/usr/bin/log"
        static func runtimeFolder(uid: uid_t) -> String? { nil }
        // Beside the app's `~/.vibeswitcher` (its host's lock, socket and log, its vault), never in its place.
        static let nodeRootFolder = ".vibeswitcher/v2/node"
    }
}
#endif
