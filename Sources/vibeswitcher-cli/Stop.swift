import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher stop` (the engine plan's EN-D6; the start plan's S3). It only wires `StopSequence`, which holds the
/// order (ST-D7): through the server when it answers (asked `status` first, so the confirmation says how many sessions
/// end, `NodeTexts.stop(live:)`: the host's live sessions, `host.liveSessions`), which stops taking requests, ends the
/// leads and then every other session, and asks the host to shut down; the typed code (the command line's own, from the action id) first, and the accepted request
/// written to the journal (ids only). On the user's node, when no server answers, or what listens sends no hello or
/// fails `ServerCheck`, it stops without the server: from an installed build only, after the typed code and the
/// journal entry, the unit through `/usr/bin/systemctl --user stop`, or, without systemd, the host the record names,
/// once checked (`NodeStopper`). A scratch node is never stopped that way (69 with no server, as before), nor is the
/// Mac's, where no node runs detached (`StopSequence.kind`).
enum StopCommand {
    static let usage = "usage: vibeswitcher stop"

    /// The connection the server's answer was had on, kept for its stop.
    final class Connection {
        var client: NodeClient?
    }

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.isEmpty else { return Say.usage(usage) }
        let context = NodeContext.current()
        if let unbuilt = context.usersNodeRefusal { return Say.unbuilt(unbuilt) }
        context.sayScratch()
        let home = VibePaths.accountHome
        let prefix = NodeFolders.defaultPrefix(accountHome: home)
        let root = NodeFolders.nodeRoot(accountHome: home)
        let runtime = NodeFolders.runtimeFolder(uid: getuid())
        let connection = Connection()
        let isHost: ([String]) -> Bool = { NodeCheck.isInstalledHost($0, prefix: prefix) }
        let lock = NodeFolders.hostLock(root: root)
        // The record the fallback showed for the code: the stopper ends only that one (the step 8 sweep).
        let shown = Shown()
        let steps = StopSequence.Steps(
            kind: { StopSequence.kind(isScratch: context.isScratch, onTheMac: Platform.Service.manager == .launchd,
                                      mode: { NodeFolders.mode(runtimeFolder: runtime) }) },
            installedBuild: { NodeFolders.installedBuild(executable: "/proc/self/exe", prefix: prefix) },
            server: { server(context, connection) },
            typed: { code, what in TypedWord.ask(code: code, what: what) },
            say: { Say.out($0) },
            journal: { context.writeJournal($0) },
            throughServer: { action in
                guard let client = connection.client else { return .failure(StartRefusal("the node's server went", exitCode: 1)) }
                return throughServer(context, client, action: action)
            },
            fallback: { mode in
                // The scratch node never gets here (`StopSequence` refuses it first); its command line builds no
                // fallback either.
                guard !context.isScratch else { return .failure(StartRefusal(NodeContext.noStandIn, exitCode: 69)) }
                switch mode {
                case .noSystemd:
                    return NodeStopper.detachedHost(root: root, lock: lock, isHost: isHost).map { found in
                        shown.record = found.record
                        return NodeTexts.stopDetached(pid: found.record.pid, arguments: found.arguments)
                    }
                case .systemd, .socketMissing:
                    return unitRuns(runtimeFolder: runtime).map { NodeTexts.stopUnit }
                }
            },
            stopper: { mode in
                guard !context.isScratch else { return .failure(StartRefusal(NodeContext.noStandIn, exitCode: 69)) }
                switch mode {
                case .noSystemd: return NodeStopper.stopDetached(root: root, lock: lock, isHost: isHost, shown: shown.record)
                case .systemd, .socketMissing: return NodeStopper.stopUnit(systemctl: "/usr/bin/systemctl", runtimeFolder: runtime)
                }
            })
        switch StopSequence(steps: steps).run() {
        case .success: return 0
        case .failure(let refused) where refused.exitCode == 77: return Say.refused(refused.text)
        case .failure(let refused):
            Say.err("vibeswitcher: \(ConfigSeal.inert(refused.text, limit: .max))")
            return refused.exitCode
        }
    }

    /// The server asked: connected, checked, its hello read, then `status` for how many sessions live.
    static func server(_ context: NodeContext, _ connection: Connection) -> StopSequence.ServerAnswer {
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(.notRunning(let why)): return .notRunning(why)
        case .failure(.refused(let why)): return .refusedByCheck(why)
        case .failure(.broken(let why)): return .noHello(why)
        case .success(let connected): client = connected
        }
        switch client.request("status") {
        case .failure(let failure): return .noHello("\(failure.message) (asked for status)")
        case .success(let reply):
            guard reply.ok, let result = reply.result else {
                let code = reply.error?.code ?? "internal"
                return .failed(StartRefusal("\(code): \(ConfigSeal.inert(reply.error?.message ?? "no reason", limit: .max))", exitCode: Say.exitCode(replyCode: code)))
            }
            connection.client = client
            // What the server's stop ends: the host's live sessions (`host.liveSessions`), not `sessions`, which lists
            // every agent on a terminal, hosted or not, and no plain program the host runs (the review of S3).
            return .answered(live: result["host"]?["liveSessions"]?.int ?? 0)
        }
    }

    /// The server's stop for `action` (the code typed): its reply, the request's journal entry, and what it did.
    static func throughServer(_ context: NodeContext, _ client: NodeClient, action: String) -> Result<Void, StartRefusal> {
        let record = { context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: "stop", epoch: client.hello.epoch)) }
        switch client.request("stop", action: action, timeout: Requests.stopWait + 30) {
        case .failure(.broken(let why)):
            // The host ends the server a moment after it accepts the shutdown: a reply that didn't get out in time
            // leaves the connection closed with none. The node gone is the answer then; anything else is a failure.
            guard case .failure(.notRunning) = NodeClient.connect(context, timeout: 5) else { return .failure(StartRefusal(why, exitCode: 1)) }
            record()
            Say.out("the node stopped (its server ended before it answered)")
            return .success(())
        case .failure(let failure): return .failure(StartRefusal(failure.message, exitCode: failure.exitCode))
        case .success(let reply):
            guard reply.ok else {
                let code = reply.error?.code ?? "internal"
                return .failure(StartRefusal("\(code): \(ConfigSeal.inert(reply.error?.message ?? "no reason", limit: .max))", exitCode: Say.exitCode(replyCode: code)))
            }
            record()
            Say.out("\(reply.result?["sessionsEnded"]?.int ?? 0) sessions ended; the host accepted to shut down")
            return .success(())
        }
    }

    /// Whether the node's unit runs (`systemctl --user show -p ActiveState`, read by name): the unit's stop is
    /// offered only then; `inactive` or `failed` is "the node isn't running" (69), and a state that can't be read refuses.
    static func unitRuns(runtimeFolder: String) -> Result<Void, StartRefusal> {
        guard let ran = NodeStarter.run("/usr/bin/systemctl", ["--user", "show", "-p", "ActiveState", NodeStarter.unitName],
                                        environment: NodeStarter.environment(runtimeFolder: runtimeFolder), timeout: 30),
              ran.status == 0 else {
            return .failure(StartRefusal("the node's unit's state can't be read (systemctl --user show didn't answer): nothing was stopped", exitCode: 1))
        }
        let state = ran.output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("ActiveState=") }.map { String($0.dropFirst("ActiveState=".count)) } ?? ""
        guard !NodeStarter.stoppedStates.contains(state) else {
            return .failure(StartRefusal("the node isn't running: its unit \(NodeStarter.unitName) is \(ConfigSeal.inert(state, limit: 64))", exitCode: 69))
        }
        return .success(())
    }
}

/// The record `stop`'s fallback showed (`NodeStopper.detachedHost`), for its stopper.
private final class Shown {
    var record: NodeRecord?
}
