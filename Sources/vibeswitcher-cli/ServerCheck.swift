import Foundation
import VibeCore
import VibeNode

/// The command line's check of the server it reached (the engine plan's EN-D8, the security architecture document's
/// S3): the facts read here, the rules in `NodeCheck`. The listener is the process at the other end (`SO_PEERCRED`,
/// fixed when it accepted): non-dumpable, and the child of the node's host in its session, which for the user's node is the unit's
/// `MainPID` (read with `/usr/bin/systemctl` by its absolute path, never from PATH; the cgroup from `/proc`) and for a
/// scratch node the holder of `<root>/scratch-host.lock` (`/proc/locks`, by the file's inode).
enum ServerCheck {
    /// Why the server at the other end of `fd` isn't the node's, or nil when it passes.
    static func refusal(fd: Int32, context: NodeContext) -> String? {
        guard let pid = Platform.Sockets.peerPID(fd) else { return "the process listening on the server's socket can't be read" }
        let listener = NodeCheck.Listener(pid: pid, dumpable: Platform.Processes.isDumpable(pid),
                                          parent: Platform.Processes.link(pid)?.parent, cgroup: Platform.Processes.cgroup(pid),
                                          session: session(of: pid))
        let expected: pid_t?
        switch context.mode {
        case .scratch(let root):
            expected = Platform.Processes.lockHolder(path: (root as NSString).appendingPathComponent(NodeCheck.scratchLock))
        case .node:
            expected = context.systemctl.flatMap { context.runTool($0, ["--user", "show", "-p", "MainPID", "--value", VoiceRule.nodeUnit]) }
                .flatMap { $0.status == 0 ? pid_t($0.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil }
                .flatMap { $0 > 0 ? $0 : nil }
        }
        return NodeCheck.refusal(listener, mode: context.mode, expectedParent: expected, parentSession: expected.flatMap(session(of:)))
    }

    /// `pid`'s POSIX session (`getsid`, which Linux answers for any process); nil when it can't be read.
    static func session(of pid: pid_t) -> pid_t? {
        let session = getsid(pid)
        return session > 0 ? session : nil
    }
}
