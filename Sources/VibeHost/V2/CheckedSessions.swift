import Foundation
import VibeCore

/// What a checked Mac node's sessions are given back of a user's environment (the node on the Mac's design, "The
/// LaunchAgent", "Sessions' environment"): the checked start resets the host's own environment to a fixed list, umask
/// 077 and no core files, so its sessions would lose what a Terminal session has from launchd. The session's own login
/// shell (`$SHELL -l -i`) builds `PATH` and what the user's startup files export; the host gives each session's spawn,
/// and not its server child, what launchd gives a Terminal and no shell sets, from launchd and the user's files, never
/// from its starter.
public struct CheckedSessions: Equatable, Sendable {
    /// Added to each session's environment on its spawn.
    public var environment: [String: String]
    /// The session's program's umask, set by its launcher.
    public var umask: mode_t

    public init(environment: [String: String], umask: mode_t) {
        self.environment = environment
        self.umask = umask
    }

    // MARK: A scratch host shaped as a checked node (tests)

    /// A scratch host's test flag: it resets itself as a checked node does (`HostImages.checkedNodeEnvironment`,
    /// `Platform.NodeReset.processState`), `HOME` the folder after it in place of the user database's, and its sessions
    /// are given what a checked node's are. Refused for the user's host, a `--node` host and a host on the node's lock;
    /// not in a checked node's grammar.
    public static let testShapeFlag = "--test-checked-shape"

    /// `main`'s step for `testShapeFlag` in `arguments`, before it reads its environment: nil without the flag (nothing
    /// done); else the scratch home it reset itself for, or why it may not start. `lock` is the host's `--lock`, which
    /// must be given and be neither the user's host's (`usersLock`) nor the node's (`HostImages.isNodeLock`).
    public static func takeTestShape(arguments: [String], isMacNode: Bool, lock: String?, usersLock: String) -> Result<String, HostImages.Refused>? {
        guard let index = arguments.firstIndex(of: testShapeFlag) else { return nil }
        guard Platform.CodeIdentity.isAvailable, !isMacNode else { return .failure(HostImages.Refused("\(testShapeFlag) is a Mac scratch host's only")) }
        guard arguments.indices.contains(index + 1), case let home = arguments[index + 1], home.hasPrefix("/") else {
            return .failure(HostImages.Refused("\(testShapeFlag) needs an absolute scratch home after it"))
        }
        guard let lock, lock != usersLock, !HostImages.isNodeLock(lock, accountHome: HostImages.accountHome) else {
            return .failure(HostImages.Refused("\(testShapeFlag) is a scratch host's only: give it its own --lock"))
        }
        let given = ProcessInfo.processInfo.environment
        let wanted = HostImages.checkedNodeEnvironment(HostImages.nodeEnvironment(given, accountHome: home, accountName: HostImages.accountName,
                                                                                  shell: HostImages.accountShell))
        for name in Set(given.keys).union(wanted.keys) where given[name] != wanted[name] {
            if let value = wanted[name] { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let why = Platform.NodeReset.processState(keeping: []) { return .failure(HostImages.Refused(why)) }
        return .success(home)
    }

    /// What a checked node's sessions are given, read at the host's start.
    public static func read(uid: uid_t, accountHome: String) -> CheckedSessions? { nil }
}
