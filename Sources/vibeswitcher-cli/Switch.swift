import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher switch COMMIT` and `vibeswitcher rollback` (the start plan's S8c; ST-D3, ST-D14, ST-D23, ST-D24): the
/// node's host hands over to another installed build, keeping every session.
///
/// 1. On the user's node, the command line must run from an installed build (ST-D3) before anything is asked: the
///    follow-up writes the unit and moves `current`. A scratch node's command line isn't held to it (it writes neither).
/// 2. `status`: the host's pid and build, and `builds` (the install root's builds and the rollback's target, ST-D14).
/// 3. The confirmation (`NodeTexts.switch`, or `NodeTexts.rollback` with the target's `installs` line), the typed code
///    (EN-D5), then `build.switch` in the user's voice; the accepted request is written to the journal (ids only). The
///    server's reply comes before it is replaced (S8b's review), so it is waited for `SwitchRequest.longestWait`.
/// 4. The follow-up (`SwitchFollowUp`), once the host handed over, or when it runs the target already and the unit or
///    `current` lag behind it (a follow-up a failure left unfinished: `vs switch <target>` again finishes it): on a node
///    under systemd `apply` (the unit's `ExecStart`, `daemon-reload`, `current`); on a node started detached
///    `applyDetached` (`current` only: its `start` starts the build `vs` runs from). Each checks the host first through
///    a fresh, checked connection (`hostCheck`). A scratch node has no unit: "scratch node: no unit to rewrite".
/// 5. The host's start line from the journal (ST-D24, `NodeJournal.events`), read back and shown.
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
        let status: NodeWire.Value
        switch client.request("status") {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            status = result
        }
        let hostPid = status["host"]?["pid"]?.int.map { pid_t($0) }
        let running = status["host"]?["notes"]?["build"]?.string
        let from = running ?? "unknown (the host's notes name no build)"
        let target: String
        let what: String
        if rollback {
            guard let back = status["builds"]?["rollback"], let commit = back["commit"]?.string, NodeUnit.isCommit(commit),
                  let line = back["line"]?.string else {
                let record = status["builds"]?["installRoot"]?.string.map { "\(ConfigSeal.inert($0, limit: .max))/installs" } ?? "the installs record"
                return Say.refused("no build to roll back to: \(record) names no other commit installed before \(ConfigSeal.inert(from, limit: 64))")
            }
            target = commit
            what = NodeTexts.rollback(from: from, to: commit, line: line)
        } else {
            target = arguments[0]
            what = NodeTexts.switch(from: from, to: target)
        }

        let action = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(code: NodeIds.code(action: action), what: what)
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        let kind = "build.switch"
        let result: NodeWire.Value
        switch client.request(kind, args: ["commit": .string(target)], action: action, timeout: SwitchRequest.longestWait + 30) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            // Accepted (the voice passed and the server recorded it): its own refusal (`refused`) comes after that.
            if reply.ok || reply.error?.code == NodeWire.Code.refused.rawValue {
                context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: kind, epoch: client.hello.epoch))
            }
            guard reply.ok, let value = reply.result else { return Say.replyError(reply) }
            result = value
        }
        Say.out(ConfigSeal.inert(result["said"]?.string ?? "switched", limit: 400))
        let handedOver = result["outcome"]?.string == "handed-over"
        guard handedOver || result["outcome"]?.string == "already" else {
            Say.err("vibeswitcher: the server's reply names no outcome: \(ConfigSeal.inert(result["outcome"]?.string ?? "none", limit: 64))")
            return 1
        }
        if let refused = followUp(context, prefix: prefix, accountHome: home, commit: target, handedOver: handedOver, hostPid: hostPid) {
            Say.err("vibeswitcher: \(ConfigSeal.inert(refused.text, limit: .max))")
            return refused.exitCode
        }
        Say.out(startLine(context, commit: target))
        return 0
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
        let deadline = Date().addingTimeInterval(hostCheckPatience)
        var why = "no server answered"
        while true {
            switch NodeClient.connect(context) {
            case .failure(.refused(let refusal)): return .failure(StartRefusal(refusal, exitCode: 77))
            case .failure(let failure): why = failure.message
            case .success(let client):
                switch client.request("status") {
                case .failure(let failure): why = failure.message
                case .success(let reply):
                    guard reply.ok, let host = reply.result?["host"] else {
                        return .failure(StartRefusal("\(reply.error?.code ?? "internal"): \(reply.error?.message ?? "no reason")", exitCode: 1))
                    }
                    guard let pid = host["pid"]?.int else { why = "the server's status names no host pid yet"; break }
                    return .success(SwitchFollowUp.Host(pid: pid_t(pid), build: host["notes"]?["build"]?.string))
                }
            }
            guard Date() < deadline else { return .failure(StartRefusal(why, exitCode: 1)) }
            usleep(500_000)
        }
    }

    /// How long the journal is read again for the new build's start line (journald writes it a moment after the host).
    static let startLinePatience: TimeInterval = 10

    /// The host's start line, from the journal (ST-D24): taken only from the unit's main pid, the user and the unit, and
    /// its start on (`NodeJournal.events`). A handover keeps the pid, so the newest is the build that runs now; it is
    /// waited for, a little, until it names `commit`.
    static func startLine(_ context: NodeContext, commit: String) -> String {
        let deadline = Date().addingTimeInterval(startLinePatience)
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
            guard Date() < deadline else {
                return "journal: the host's start line doesn't name \(commit) yet: "
                    + (start.detail.map { ConfigSeal.inert($0, limit: 400) } ?? "none from the unit's main pid since its start")
            }
            usleep(250_000)
        }
    }
}
