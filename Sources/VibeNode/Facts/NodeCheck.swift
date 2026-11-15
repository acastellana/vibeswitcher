import Foundation
import VibeCore

/// The command line's check of the server it reached (the engine plan's EN-D8, the security architecture document's
/// S3), as pure rules; `vibeswitcher-cli`'s `ServerCheck` reads the facts. Two forms:
/// - **The user's node**: the listener is non-dumpable, in the node unit's cgroup, and a child of the unit's `MainPID`.
/// - **A scratch node** (`VIBESWITCHER_HOME` set, resolving to a folder other than the account's own
///   `~/.vibeswitcher`, the home from `getpwuid`): non-dumpable, and a child of the process holding
///   `<root>/scratch-host.lock` (`Platform.Processes.lockHolder(path:)`). Every command then says "scratch node at
///   <root>" on stderr.
/// `VIBESWITCHER_HOME` naming the account's own folder gets the user's node's check. No flag or pid is passed.
public enum NodeCheck {
    public enum Mode: Equatable, Sendable {
        case node
        case scratch(root: String)
    }

    /// A scratch host's lock in its root (`ScratchNode`'s `--lock`).
    public static let scratchLock = "scratch-host.lock"

    /// Which check: a scratch node when `vibeswitcherHome` is an absolute folder other than `accountHome`'s
    /// `.vibeswitcher` (however spelled, links resolved), the user's node otherwise.
    public static func mode(vibeswitcherHome: String?, accountHome: String) -> Mode {
        guard let home = vibeswitcherHome, home.hasPrefix("/") else { return .node }
        let root = URL(fileURLWithPath: home, isDirectory: true)
        return VibePaths.isAccountRoot(root, accountHome: accountHome) ? .node : .scratch(root: root.standardizedFileURL.path)
    }

    /// The listening process as the command line read it.
    public struct Listener: Equatable, Sendable {
        public var pid: pid_t
        /// nil: can't be told.
        public var dumpable: Bool?
        public var parent: pid_t?
        /// Its cgroup lines; nil when unreadable.
        public var cgroup: [String]?

        public init(pid: pid_t, dumpable: Bool?, parent: pid_t?, cgroup: [String]?) {
            self.pid = pid
            self.dumpable = dumpable
            self.parent = parent
            self.cgroup = cgroup
        }
    }

    /// Why the listener isn't the node's server, or nil when it passes. `expectedParent`: the unit's `MainPID` (the
    /// user's node) or the scratch lock's holder; nil when it couldn't be read, which fails.
    public static func refusal(_ listener: Listener, mode: Mode, expectedParent: pid_t?) -> String? {
        switch listener.dumpable {
        case true?: return "the process listening on the server's socket (pid \(listener.pid)) is dumpable: not the node's server"
        case nil: return "whether the process listening on the server's socket (pid \(listener.pid)) is dumpable can't be told"
        case false?: break
        }
        if mode == .node {
            let path = listener.cgroup.flatMap { PeerFacts.unifiedPath($0) ?? PeerFacts.systemdPath($0) }
            guard let path, path.split(separator: "/").last.map(String.init) == VoiceRule.nodeUnit else {
                return "the process listening on the server's socket (pid \(listener.pid)) isn't in \(VoiceRule.nodeUnit) (its cgroup is \(path ?? "unreadable"))"
            }
        }
        guard let expectedParent else {
            return mode == .node ? "the node's unit has no main process to check the server against"
                : "no process holds the scratch node's lock, so the server can't be checked against its host"
        }
        guard let parent = listener.parent, parent == expectedParent else {
            return "the process listening on the server's socket (pid \(listener.pid)) isn't a child of the node's host (pid \(expectedParent))"
        }
        return nil
    }
}
