import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher switch COMMIT` and `vibeswitcher rollback` (the start plan's S8c; ST-D3, ST-D14, ST-D23, ST-D24): the
/// node's host hands over to another installed build, keeping every session.
///
/// 1. On the user's node, the command line must run from an installed build (ST-D3) before anything is asked: the
///    follow-up writes the unit and moves `current`. A scratch node's command line isn't held to it (it writes neither).
/// 2. `status`: the host's pid and build, and `builds` (the install root's builds and the rollback's target, ST-D14).
///    Where the follow-up checks the host (under systemd, or detached), a pid `status` doesn't name yet is asked again
///    (`SwitchFollowUp.hostBefore`), or the switch is refused with nothing switched (the review of S8c).
/// 3. The target checked as an installed build (`SwitchFollowUp.targetRefusal`, the review of S8c), then the
///    confirmation (`NodeTexts.switch`, or `NodeTexts.rollback` with the target's `installs` line), saying what this
///    node's follow-up writes (`rewrites`), the typed code (EN-D5), then `build.switch` in the user's voice; the
///    accepted request is written to the journal (ids only). The server's reply comes before it is replaced (S8b's
///    review), so it is waited for `SwitchRequest.longestWait`. A reply lost all the same is followed by a fresh look at
///    the host (`SwitchFollowUp.afterLostReply`): on the target with its pid unchanged it is handed over; otherwise the
///    refusal says the host may have switched and how to finish.
/// 4. The follow-up (`SwitchFollowUp`), once the host handed over, or when it runs the target already and the unit or
///    `current` lag behind it (a follow-up a failure left unfinished: `vs switch <target>` again finishes it): on a node
///    under systemd `apply` (the unit's `ExecStart`, `daemon-reload`, `current`); on a node started detached
///    `applyDetached` (`current` only: its `start` starts the build `vs` runs from). Each checks the host first through
///    a fresh, checked connection (`hostCheck`). A scratch node has no unit: "scratch node: no unit to rewrite".
/// 5. The host's start line (ST-D24), read back and shown: from the journal (`NodeJournal.events`), or on a node
///    started detached from the host's log (`NodeJournal.hostLogStart`).
enum SwitchCommand {
    static let usage = "usage: vibeswitcher switch COMMIT | rollback"

    static func run(_ arguments: [String], rollback: Bool) -> Int32 {
        let command = rollback ? "rollback" : "switch"
        guard rollback ? arguments.isEmpty : arguments.count == 1 else { return Say.usage(usage) }
        if !rollback, !NodeUnit.isCommit(arguments[0]) {
            Say.err("vibeswitcher: switch takes a commit: 40 lowercase hex digits")
            return Say.usage(usage)
        }
        let context = NodeContext.current()
        context.sayScratch()
        let home = VibePaths.accountHome
        let prefix = NodeFolders.defaultPrefix(accountHome: home)
        // ST-D3: the user's node's follow-up writes; nothing is asked before this check.
        if !context.isScratch, !Platform.CodeIdentity.isAvailable,
           case .failure(let refused) = NodeFolders.installedBuild(executable: "/proc/self/exe", prefix: prefix) {
            return Say.refused("\(command): \(refused.text)")
        }
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let status: WireKinds.Status.Result
        switch client.read(WireKinds.Status.self, WireNoArgs()) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _): status = result
        }
        var hostPid = status.host?.pid.map { pid_t($0) }
        var running = status.host?.notes?.build
        // The review of S8c: where the follow-up checks the host, its pid before the switch is known before the code
        // is asked (`status` names none until the server's link is welcomed), or nothing is switched.
        let checksHost: Bool
        if case .nothing = rewrites(context) { checksHost = false } else { checksHost = true }
        if checksHost, hostPid == nil {
            switch SwitchFollowUp.hostBefore(pid: hostPid, build: running, hostCheck: { hostCheck(context) }) {
            case .failure(let refused):
                Say.err("vibeswitcher: refused: \(command): \(ConfigSeal.inert(refused.text, limit: .max))")
                return refused.exitCode
            case .success(let host): (hostPid, running) = (host.pid, host.build)
            }
        }
        let from = running ?? "unknown (the host's notes name no build)"
        let target: String
        if rollback {
            guard let back = status.builds?.rollback, let commit = back.commit, NodeUnit.isCommit(commit), back.line != nil else {
                let record = status.builds?.installRoot.map { "\(ConfigSeal.inert($0, limit: .max))/installs" } ?? "the installs record"
                return Say.refused("no build to roll back to: \(record) names no other commit installed before \(ConfigSeal.inert(from, limit: 64))")
            }
            target = commit
        } else {
            target = arguments[0]
        }
        // The review of S8c: the target an installed build before anything is asked (the host checks only its own and
        // its server's images at the handover). The user's node's prefix; a scratch node's (or the Mac's) the server's.
        if let root = buildsRoot(context, prefix: prefix, status: status), let refused = SwitchFollowUp.targetRefusal(prefix: root, commit: target) {
            return Say.refused("\(command): \(ConfigSeal.inert(refused.text, limit: .max))")
        }
        // Whether it can run now, before any code is asked: the rule on switches refuses it while a worker or verifier
        // runs (the server and the host both hold it), so a confirmation that reads as if it would go ahead is never shown.
        let blockers = (status.switchBlockers ?? []).map { ConfigSeal.inert($0, limit: 120) }
        // The idle workers the switch parks first (`SwitchPark`): said in the confirmation, never a refusal.
        let parks = (status.switchParks ?? []).map { ConfigSeal.inert($0, limit: 120) }
        if !blockers.isEmpty {
            return Say.refused("\(command) can't run now: " + SwitchRequest.blockedText(blockers) + ". Nothing was asked or switched.")
        }
        let what = (rollback
            ? NodeTexts.rollback(from: from, to: target, line: status.builds?.rollback?.line ?? "", rewrites: rewrites(context))
            : NodeTexts.switch(from: from, to: target, rewrites: rewrites(context)))
            + (parks.isEmpty
                ? "\n  it can run now: no worker or verifier runs (a change the seal holds under the builds or the unit's folder would still stop it: `vs config held`)"
                : "\n  it parks first the workers that only wait on their lead (idle since their last report; their worktrees and commits stay, "
                    + "start_worker continues there, and their leads are told): " + parks.joined(separator: ", ")
                    + "\n  then it runs, unless one of them has begun a turn meanwhile (a change the seal holds under the builds or the unit's folder would still stop it: `vs config held`)")

        let action = UUID().uuidString.lowercased()
        let said = TypedWord.said(approval: client.approvalRule, action: action, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        let kind = "build.switch"
        let handedOver: Bool
        switch client.change(kind, args: ["commit": .string(target)], action: action, typed: typed, timeout: SwitchRequest.longestWait + 30) {
        case .failure(let failure):
            // The review of S8c: the reply may be lost after the host handed over (the server a switch replaces may end
            // first): the host, as a fresh connection sees it, says whether it did.
            switch SwitchFollowUp.afterLostReply(failure.message, commit: target, hostPid: hostPid, hostCheck: { hostCheck(context) }) {
            case .failure(let refused):
                Say.err("vibeswitcher: \(ConfigSeal.inert(refused.text, limit: .max))")
                return refused.exitCode
            case .success:
                client.journal(kind, action: action, typed: typed)
                Say.out("the switch's reply was lost (\(ConfigSeal.inert(failure.message, limit: 400))), but the host runs \(target) now, its pid unchanged: handed over")
                handedOver = true
            }
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            let parked = (result["parked"]?.array ?? []).compactMap(\.string).map { ConfigSeal.inert($0, limit: 120) }
            if !parked.isEmpty { Say.out("parked first (idle since their last report; their leads were told): " + parked.joined(separator: ", ")) }
            Say.out(ConfigSeal.inert(result["said"]?.string ?? "switched", limit: 400))
            guard result["outcome"]?.string == "handed-over" || result["outcome"]?.string == "already" else {
                Say.err("vibeswitcher: the server's reply names no outcome: \(ConfigSeal.inert(result["outcome"]?.string ?? "none", limit: 64))")
                return 1
            }
            handedOver = result["outcome"]?.string == "handed-over"
        }
        if let refused = followUp(context, prefix: prefix, accountHome: home, commit: target, handedOver: handedOver, hostPid: hostPid) {
            Say.err("vibeswitcher: \(ConfigSeal.inert(refused.text, limit: .max))")
            return refused.exitCode
        }
        Say.out(startLine(context, commit: target, hostPid: hostPid))
        return 0
    }

    /// What the follow-up writes on this node (`NodeTexts.SwitchRewrites`), for the confirmation.
    static func rewrites(_ context: NodeContext) -> NodeTexts.SwitchRewrites {
        switch context.mode {
        case .scratch: return .nothing("a scratch node: no unit to rewrite")
        case .node where Platform.CodeIdentity.isAvailable: return .nothing("the Mac: no unit to rewrite")
        case .node: return .unitAndCurrent
        case .detached: return .currentOnly
        }
    }

    /// The builds folder the target is checked in before the code: the user's node's prefix on Linux (the follow-up's);
    /// otherwise the server's install root (`status`'s `builds.installRoot`), or none when it names none (a host not
    /// installed refuses `build.switch` itself).
    static func buildsRoot(_ context: NodeContext, prefix: String, status: WireKinds.Status.Result) -> String? {
        if case .nothing = rewrites(context) { return status.builds?.installRoot }
        return prefix
    }

    /// The follow-up for the node's mode (the type's comment, 4); nil when it is done, or there is none to do.
    static func followUp(_ context: NodeContext, prefix: String, accountHome: String, commit: String, handedOver: Bool,
                         hostPid: pid_t?) -> StartRefusal? {
        let check = { hostCheck(context) }
        switch context.mode {
        case .scratch:
            Say.out("scratch node: no unit to rewrite")
            return nil
        case .node where Platform.CodeIdentity.isAvailable:
            Say.out("the Mac: no unit to rewrite")
            return nil
        case .node:
            let tools = NodeStarter.node(accountHome: accountHome, uid: getuid())
            if !handedOver, SwitchFollowUp.isDone(tools: tools, prefix: prefix, commit: commit) { return nil }
            guard let hostPid else { return unknownPid(commit) }
            if case .failure(let refused) = SwitchFollowUp.apply(tools: tools, prefix: prefix, accountHome: accountHome, commit: commit,
                                                                 hostPid: hostPid, hostCheck: check) { return refused }
            Say.out("the unit's ExecStart names \(commit) and `current` names it: the next start runs it")
        case .detached:
            if !handedOver, SwitchFollowUp.isCurrent(prefix: prefix, commit: commit) { return nil }
            guard let hostPid else { return unknownPid(commit) }
            if case .failure(let refused) = SwitchFollowUp.applyDetached(prefix: prefix, commit: commit, hostPid: hostPid, hostCheck: check) {
                return refused
            }
            Say.out("no systemd: `current` names \(commit), so the next `vs start` runs it")
        }
        Say.out("the seal holds every team until `vs config accept` (`vs config held` shows what changed)")
        return nil
    }

    static func unknownPid(_ commit: String) -> StartRefusal {
        StartRefusal("the host's pid before the switch isn't known (`status` named none), so the follow-up can't check the host: nothing was rewritten; `vs switch \(commit)` again finishes this", exitCode: 1)
    }

    /// How long `hostCheck` asks again while no server answers: the server a switch replaces is started again from the
    /// new build (`ServerChild`), and answers within this.
    static let hostCheckPatience: TimeInterval = 60

    /// The host as a freshly connected and checked server (`ServerCheck`) sees it: its pid (the welcome's) and the build
    /// its notes name (`status`'s `host`). A server that isn't the node's fails it at once.
    static func hostCheck(_ context: NodeContext) -> Result<SwitchFollowUp.Host, StartRefusal> {
        let deadline = Platform.Clock.steadyDate().addingTimeInterval(hostCheckPatience)
        var why = "no server answered"
        while true {
            switch NodeClient.connect(context) {
            case .failure(.refused(let refusal)): return .failure(StartRefusal(refusal, exitCode: 77))
            case .failure(let failure): why = failure.message
            case .success(let client):
                switch client.read(WireKinds.Status.self, WireNoArgs()) {
                case .failure(let failure): why = failure.message
                case .refused(let reply):
                    return .failure(StartRefusal("\(reply.error?.code ?? "internal"): \(reply.error?.message ?? "no reason")", exitCode: 1))
                case .success(let status, _):
                    guard let host = status.host else {
                        return .failure(StartRefusal("internal: the server's status names no host", exitCode: 1))
                    }
                    guard let pid = host.pid else { why = "the server's status names no host pid yet"; break }
                    return .success(SwitchFollowUp.Host(pid: pid_t(pid), build: host.notes?.build))
                }
            }
            guard Platform.Clock.steadyDate() < deadline else { return .failure(StartRefusal(why, exitCode: 1)) }
            usleep(500_000)
        }
    }

    /// How long the journal (or a detached host's log) is read again for the new build's start line (journald writes it
    /// a moment after the host).
    static let startLinePatience: TimeInterval = 10

    /// The host's start line (ST-D24), waited for, a little, until it names `commit`. Under systemd from the journal:
    /// taken only from the unit's main pid, the user and the unit, and its start on (`NodeJournal.events`); a handover
    /// keeps the pid, so the newest is the build that runs now. On a node started detached from the host's log
    /// (`NodeStarter.hostLog`, where its stderr goes: the review of S8c), the newest line of the host's pid, which
    /// nothing vouches for. The Mac's host writes none.
    static func startLine(_ context: NodeContext, commit: String, hostPid: pid_t?) -> String {
        switch context.mode {
        case .node where Platform.CodeIdentity.isAvailable: return "the Mac: the host writes no start line"
        case .detached: return logStartLine(commit: commit, hostPid: hostPid)
        case .node, .scratch: return journalStartLine(context, commit: commit)
        }
    }

    static func journalStartLine(_ context: NodeContext, commit: String) -> String {
        let deadline = Platform.Clock.steadyDate().addingTimeInterval(startLinePatience)
        while true {
            let entries: [JournalEntry]
            switch context.journalEntries() {
            case .failure(let failure): return "journal: the host's start line can't be read (\(failure.reason))"
            case .success(let read): entries = read
            }
            let events = NodeJournal.events(entries, mainPID: context.unitState()?.execMainPID, uid: context.journalRule.uid)
            guard let start = events.last(where: { $0.kind == .start }) else {
                return "journal: no start of the node's unit to read the host's start line from"
            }
            if let detail = start.detail, detail.contains(" build \(commit) ") {
                return "journal: the host's start line: \(ConfigSeal.inert(detail, limit: 400))"
            }
            guard Platform.Clock.steadyDate() < deadline else {
                return "journal: the host's start line doesn't name \(commit) yet: "
                    + (start.detail.map { ConfigSeal.inert($0, limit: 400) } ?? "none from the unit's main pid since its start")
            }
            usleep(250_000)
        }
    }

    /// How much of a detached host's log's end is read for its start line.
    static let logTail = 256 * 1024

    static func logStartLine(commit: String, hostPid: pid_t?) -> String {
        let log = NodeStarter.hostLog(root: NodeFolders.nodeRoot(accountHome: VibePaths.accountHome))
        let shown = ConfigSeal.inert(log, limit: .max)
        guard let hostPid else { return "\(shown): the host's pid isn't known, so its start line isn't read" }
        let deadline = Platform.Clock.steadyDate().addingTimeInterval(startLinePatience)
        while true {
            let line = readTail(log).flatMap { NodeJournal.hostLogStart($0, pid: hostPid) }
            if let line, line.contains(" build \(commit) ") {
                return "\(shown) (any worker can write it): the host's start line: \(ConfigSeal.inert(line, limit: 400))"
            }
            guard Platform.Clock.steadyDate() < deadline else {
                return "\(shown) (any worker can write it): the host's start line doesn't name \(commit) yet: "
                    + (line.map { ConfigSeal.inert($0, limit: 400) } ?? "none from pid \(hostPid)")
            }
            usleep(250_000)
        }
    }

    /// The last `logTail` bytes of `path` (a regular file, opened without following a link), as text; nil when it
    /// can't be read.
    static func readTail(_ path: String) -> String? {
        let fd = Sys.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let size = Int(info.st_size), start = max(0, size - logTail)
        guard lseek(fd, off_t(start), SEEK_SET) >= 0 else { return nil }
        let total = size - start
        var bytes = [UInt8](repeating: 0, count: total)
        var got = 0
        while got < total {
            let count = bytes.withUnsafeMutableBytes { Sys.read(fd, $0.baseAddress! + got, total - got) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            got += count
        }
        return String(decoding: bytes[0..<got], as: UTF8.self)
    }
}
