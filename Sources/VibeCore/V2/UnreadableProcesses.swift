import Foundation

/// What a reader of another process's /proc entries makes of a process it can't read (the stage 2 plan's S2-D5 and
/// Task 9a, the security architecture document's S6). On Linux any process may make itself non-dumpable
/// (`PR_SET_DUMPABLE 0` needs no privilege), and then its program, folder, environment and descriptors are root's to
/// read; its `stat`, `status` and `cmdline` stay readable. So "unreadable" is nobody in particular: it is never "gone"
/// (it runs; `Platform.Processes.record` still reads it), and it is the session host, a parser of the host's or the
/// host's server child only when the host itself says so by token, its pid and start ticks (`isOurs`, set by the host).
/// Anything else unreadable is `unknown`: still running, whose it is not known.
///
/// Every reader in `VibeCore`, `VibeHost` and the executables already takes an unreadable field as unknown, never as
/// gone (the list, with the process each runs in, is `HostHardening`'s, in Sources/VibeHost/V2/HostHardening.swift);
/// the one that asks whose an unreadable process is, `SessionStrays.of(session:started:)`, asks `reading(_:)`.
///
/// The Mac: `isOurs` is never set, `Platform.Processes.isDumpable` is nil there, and every process the Mac lets a
/// reader see reads as `readable` or `gone`: today's reading.
public enum UnreadableProcesses {
    /// What a process is to a reader that can't, or can, read its entries.
    public enum Reading: Equatable, Sendable {
        /// No such process now, or it has ended (a zombie, or on its way out).
        case gone
        /// Its entries read as any program's of the user's do (or it can't be told: the Mac, another user's).
        case readable
        /// Non-dumpable, and the session host this runs in names it as itself, a parser of its or its server child.
        case ours
        /// Non-dumpable, and nothing says whose it is: still running, and neither the host nor gone.
        case unknown
    }

    /// Set by the session host on Linux to `HostHardening.isOurs`: whether a token is the host's own, a parser's of its
    /// or its server child's. Nil in every other process and on the Mac, where no unreadable process is the host's.
    nonisolated(unsafe) public static var isOurs: (@Sendable (Platform.PeerToken) -> Bool)?

    /// What `pid` is now (see `Reading`).
    public static func reading(_ pid: pid_t) -> Reading {
        guard pid > 0 else { return .gone }
        switch Platform.Processes.record(pid) {
        case .gone: return .gone
        case .record(let record) where record.state == .zombie || record.exiting: return .gone
        case .record, .partial, .unreadable: break
        }
        guard Platform.Processes.isDumpable(pid) == false else { return .readable }
        guard let token = Platform.Processes.token(pid) else { return .unknown }
        return isOurs?(token) == true ? .ours : .unknown
    }
}
