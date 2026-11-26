import Foundation
import VibeCore
import VibeNode

/// The command line's check of the server it reached (the engine plan's EN-D8, the security architecture document's
/// S3): the facts read here, the rules in `NodeCheck`. The listener is the process at the other end (`SO_PEERCRED`,
/// fixed when it accepted): non-dumpable, and the child of the node's host in its session, which for the user's node is the unit's
/// `MainPID` (read with `/usr/bin/systemctl` by its absolute path, never from PATH; the cgroup from `/proc`), for a
/// node started detached the host its record names, checked (`NodeCheck.recordedHost`, the start plan's S3: holding
/// the account's host lock among the rest), and for a
/// scratch node the holder of `<root>/scratch-host.lock` (`/proc/locks`, by the file's inode).
/// The Mac (dumpable can't be told there): the user's node only, its listener running a server the node's record pins
/// (`NodePins`, root's to write; by its audit token's cdhash, hardened), the LaunchAgent job's child in its session; else
/// refused. The job's program line chooses nothing (item 12): only its pid is taken from `launchctl print`.
enum ServerCheck {
    /// Why the server at the other end of `fd` isn't the node's, or nil when it passes.
    static func refusal(fd: Int32, context: NodeContext) -> String? { verdict(fd: fd, context: context)?.text }

    /// A refusal, and whether it may be a server on its way out (`NodeCheck.unsettled`: gone, or a fact unreadable).
    struct Refusal {
        var text: String
        var unsettled: Bool
    }

    /// Why the server at the other end of `fd` isn't the node's, and whether that may be a server on its way out; nil
    /// when it passes.
    static func verdict(fd: Int32, context: NodeContext) -> Refusal? {
        guard let pid = Platform.Sockets.peerPID(fd) else { return Refusal(text: "the process listening on the server's socket can't be read", unsettled: true) }
        // The Mac (the review of 2026-11-21): no dumpable state to read, so the listener's code instead, before anything
        // it says (its hello's rule) is trusted: the server of the build the job runs; the parent, the session and the
        // code all bound to the one audit token the socket gave (`NodeCheck.macListener`).
        let codeIdentity = Platform.CodeIdentity.isAvailable
        let job = codeIdentity && context.mode == .node ? macJob(context) : nil
        var codeWhy: String?
        var listener = codeIdentity
            ? NodeCheck.macListener(pid: pid, token: Platform.Sockets.peerToken(fd), code: { token in
                guard let job else { return nil }
                // The node's record of its builds, root's to write: the listener's code must be a server it pins.
                let answer = NodeCheck.macServerCode(token: token, job: job, prefix: nil, pins: NodePins.read())
                codeWhy = answer.why
                return answer.told
            })
            : NodeCheck.listener(pid: pid)
        listener.codeWhy = codeWhy
        let expected: pid_t?
        switch context.mode {
        case .scratch(let root):
            // Looked at again for a moment when no holder shows: one look at /proc/locks can miss a held lock.
            expected = Platform.Processes.lockHolder(path: (root as NSString).appendingPathComponent(NodeCheck.scratchLock),
                                                     patience: NodeCheck.lockPatience)
        case .node where codeIdentity:
            // The Mac's node runs as its LaunchAgent: the job's pid, as launchd says it (`NodeAgent.printed`).
            expected = job?.pid
        case .node:
            expected = context.systemctl.flatMap { context.runTool($0, ["--user", "show", "-p", "MainPID", "--value", VoiceRule.nodeUnit]) }
                .flatMap { $0.status == 0 ? pid_t($0.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil }
                .flatMap { $0 > 0 ? $0 : nil }
        case .detached(let record):
            let prefix = NodeFolders.defaultPrefix(accountHome: VibePaths.accountHome)
            let lock = NodeFolders.hostLock(root: NodeFolders.nodeRoot(accountHome: VibePaths.accountHome))
            switch NodeCheck.recordedHost(record, isHost: { NodeCheck.isInstalledHost($0, prefix: prefix) }, lock: lock) {
            case .host(let host): expected = host
            case .none(let why), .other(let why):
                return Refusal(text: "the node's record doesn't name its host (\(why)), so the server can't be checked against it", unsettled: false)
            }
        }
        guard let text = NodeCheck.refusal(listener, mode: context.mode, expectedParent: expected, parentSession: expected.flatMap(session(of:)),
                                           codeIdentity: codeIdentity) else { return nil }
        let alive = kill(pid, 0) == 0 || errno == EPERM
        return Refusal(text: text, unsettled: NodeCheck.unsettled(listener, alive: alive, mode: context.mode, codeIdentity: codeIdentity))
    }

    /// The Mac's node job as launchd prints it (`launchctl print gui/<uid>/<label>`, by its absolute path): its pid
    /// and program, the installed host; nil when it isn't running or can't be read.
    static func macJob(_ context: NodeContext) -> NodeAgent.Printed? {
        guard let launchctl = Platform.Service.launchctl,
              let run = context.runTool(launchctl, ["print", NodeAgent.target(uid: getuid())]), run.status == 0 else { return nil }
        let printed = NodeAgent.printed(run.output)
        // Only the pid is taken (item 12): the program line chooses nothing, so its absence refuses nothing.
        return printed.pid.map { $0 > 0 } == true ? printed : nil
    }

    /// `pid`'s POSIX session (`getsid`, which Linux answers for any process); nil when it can't be read.
    static func session(of pid: pid_t) -> pid_t? {
        let session = getsid(pid)
        return session > 0 ? session : nil
    }
}
