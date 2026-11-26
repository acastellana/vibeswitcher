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
/// (`NodePins`, root's to write; by its audit token's cdhash, hardened), the child in its session of the job's host as
/// `status` finds it (`MacAgent.runningHost`: launchd's whole word for the job, the host by its connection's audit token
/// and running code, a host that switched in place before its plist was rewritten taken too); else refused. The job's
/// program line chooses nothing (item 12): no text of `launchctl print` names the host.
enum ServerCheck {
    /// Why the server at the other end of `fd` isn't the node's, or nil when it passes.
    static func refusal(fd: Int32, context: NodeContext) -> String? {
        guard let pid = Platform.Sockets.peerPID(fd) else { return "the process listening on the server's socket can't be read" }
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
            case .none(let why), .other(let why): return "the node's record doesn't name its host (\(why)), so the server can't be checked against it"
            }
        }
        return NodeCheck.refusal(listener, mode: context.mode, expectedParent: expected, parentSession: expected.flatMap(session(of:)),
                                 codeIdentity: codeIdentity)
    }

    /// The Mac's node job's host, as `status` finds it (`MacAgent.runningHost(afterASwitch:)`: between a switch's
    /// handover and its follow-up the plist still names the build the host was started as): its pid; nil when the node
    /// doesn't run or its host isn't the node's (row 10: the host known by token and code, never by launchctl's text).
    static func macJob(_ context: NodeContext) -> NodeAgent.Printed? {
        guard let place = MacAgentCommand.place() else { return nil }
        let agent = MacAgent(place: place, steps: .system(place: place, pins: { NodePins.read() }, say: { _ in }, confirm: { _ in .success(()) },
                                                          serverStop: { _ in .none("no server is asked") }, job: MacAgentCommand.job))
        guard case .success(let host) = agent.runningHost(afterASwitch: true), host.pid > 0 else { return nil }
        return NodeAgent.Printed(pid: host.pid, program: nil)
    }

    /// `pid`'s POSIX session (`getsid`, which Linux answers for any process); nil when it can't be read.
    static func session(of pid: pid_t) -> pid_t? {
        let session = getsid(pid)
        return session > 0 ? session : nil
    }
}
