import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher start [--interop-is-on] [--at-login] [--node-version vX.Y.Z]` (the engine plan's E1; the start plan's
/// S2). It only wires `StartSequence`, which holds the order (ST-D5): the installed-build check on the user's node, the
/// facts and the interop refusal, the manager's environment, then a running node's answer, or, for a stopped node,
/// S11's acknowledgment, the build, the confirmation, the typed code, the journal entry and `NodeStarter`'s start of
/// the unit. On the user's node every tool and folder is a constant or comes from `getpwuid` (`NodeStarter.node`); a
/// scratch node is never started here (69: its harness starts it), and its command line never builds those tools: its
/// starter refuses at the wiring too, and it reads no unit (the review of S2). On a machine without systemd the node is
/// started detached (S3, `NodeStarter.startDetached` with `NodeUnit.execStart`), its record and log in
/// `<getpwuid home>/.vibeswitcher/v2/`, then waited for as the unit is.
enum StartCommand {
    static func run(_ arguments: [String]) -> Int32 {
        guard let parsed = StartArguments.parse(arguments) else { return Say.usage(StartArguments.usage) }
        let context = NodeContext.current()
        context.sayScratch()
        let home = VibePaths.accountHome
        let prefix = NodeFolders.defaultPrefix(accountHome: home)
        let tools: NodeStarter.Tools? = context.isScratch ? nil : NodeStarter.node(accountHome: home, uid: getuid())
        let manager = Once { context.managerEnvironment() }
        let steps = StartSequence.Steps(
            home: home, prefix: prefix,
            kind: { tools.map { .node(NodeFolders.mode(runtimeFolder: $0.runtimeFolder)) } ?? .scratch },
            installedBuild: { NodeFolders.installedBuild(executable: "/proc/self/exe", prefix: prefix) },
            facts: { context.facts(managerEnvironment: manager.value) },
            managerEnvironment: { manager.value },
            managerConfig: { NodeFolders.managerConfigRefusal(accountHome: home) },
            serverAnswers: { serverAnswers(context) },
            acknowledged: { acknowledged(context) },
            showList: { Say.out(NotPromised.text) },
            typed: { code, what in TypedWord.ask(code: code, what: what) },
            say: { Say.out($0) },
            journal: { context.writeJournal($0) },
            existingUnit: {
                guard let tools, let data = FileManager.default.contents(atPath: (tools.unitFolder as NSString).appendingPathComponent(NodeUnit.fileName)) else { return nil }
                return String(decoding: data, as: UTF8.self)
            },
            unitBuild: { NodeFolders.unitBuild(unitText: $0, prefix: prefix) },
            current: { currentCommit(prefix: prefix) },
            enabledBy: { tools.map { NodeStarter.enabledBy(unitFolder: $0.unitFolder) } ?? [] },
            toolFolders: { NodeFolders.toolFolders(accountHome: home, nodeVersion: $0, existingUnit: $1) },
            preflight: { StartPreflight(claudeLink: NodePreflight.claudeLink(root: context.root, accountHome: home), swiftBin: $0, nodeBin: $1).check() },
            starter: { unit, atLogin, beforeStart in
                guard let tools else { return .failure(StartRefusal(StartSequence.scratchNotStarted, exitCode: 69)) }
                return NodeStarter(tools: tools, listen: { probe(context, tools: tools) }).startUnit(unit, atLogin: atLogin, beforeStart: beforeStart)
            },
            detached: { unit, beforeStart in
                guard let tools else { return .failure(StartRefusal(StartSequence.scratchNotStarted, exitCode: 69)) }
                if let refused = beforeStart() { return .failure(refused) }
                let root = NodeFolders.nodeRoot(accountHome: home)
                let record: NodeRecord
                switch NodeStarter.startDetached(host: NodeUnit.execStart(prefix: unit.prefix, commit: unit.commit), home: unit.home,
                                                 path: NodeUnit.path(swiftBin: unit.swiftBin, nodeBin: unit.nodeBin), root: root,
                                                 lock: NodeFolders.hostLock(root: root), isHost: { NodeCheck.isInstalledHost($0, prefix: prefix) }) {
                case .failure(let refused): return .failure(refused)
                case .success(let written): record = written
                }
                let log = NodeStarter.hostLog(root: root)
                if let refused = NodeStarter(tools: tools, listen: { detachedProbe(record) }).awaitListening(detachedLog: log) {
                    return .failure(refused)
                }
                return .success(NodeStarter.Started(commit: unit.commit, enabledAtLogin: false))
            })
        switch StartSequence(steps: steps).run(parsed) {
        case .success: return 0
        case .failure(let refused) where refused.exitCode == 77: return Say.refused(refused.text)
        case .failure(let refused):
            Say.err("vibeswitcher: \(ConfigSeal.inert(refused.text, limit: .max))")
            return refused.exitCode
        }
    }

    /// The server asked for `start`: connected, checked (`ServerCheck`), asked, the request journaled and "the node
    /// runs" said.
    static func serverAnswers(_ context: NodeContext) -> StartSequence.ServerAnswer {
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(.notRunning(let why)): return .notRunning(why)
        case .failure(.refused(let why)): return .refusedByCheck(why)
        case .failure(let failure): return .failed(StartRefusal(failure.message, exitCode: failure.exitCode))
        case .success(let connected): client = connected
        }
        let action = UUID().uuidString.lowercased()
        switch client.request("start", action: action) {
        case .failure(let failure): return .failed(StartRefusal(failure.message, exitCode: failure.exitCode))
        case .success(let reply):
            guard reply.ok, let result = reply.result else {
                let code = reply.error?.code ?? "internal"
                return .failed(StartRefusal("\(code): \(ConfigSeal.inert(reply.error?.message ?? "no reason", limit: .max))", exitCode: Say.exitCode(replyCode: code)))
            }
            context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: "start", epoch: client.hello.epoch))
            Say.out("the node runs: its server since \(ConfigSeal.inert(result["serverStartedAt"]?.string ?? "?", limit: 64)), its host since \(ConfigSeal.inert(result["hostStartedAt"]?.string ?? "?", limit: 64))")
            return .running
        }
    }

    /// Whether the journal holds a `not-promised-ack` entry that passes the rule.
    static func acknowledged(_ context: NodeContext) -> Result<Bool, NodeFacts.Failure> {
        context.journalEntries().map { entries in
            entries.contains { $0.identifier == NodeJournal.identifier && $0.event == NotPromised.ackEvent && NodeJournal.passes($0, rule: context.journalRule) }
        }
    }

    /// The commit `<prefix>/current` names (a link to a commit's folder), nil when none.
    static func currentCommit(prefix: String) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: (prefix as NSString).appendingPathComponent("current")) else { return nil }
        let name = (target as NSString).lastPathComponent
        return name.utf8.count == 40 && name.allSatisfy { $0.isHexDigit } ? name : nil
    }

    /// The probe `NodeStarter` waits on: the server connected and checked gives `.listening` (or `.refusedByCheck`);
    /// with nothing listening, the unit's `ActiveState` `failed` or `inactive` gives `.unitEnded` with its `Result`;
    /// anything else is `.notYet`. `show` without `--value`, read by name: the plan's `--value` prints values with no
    /// names, in an order this doesn't rely on (2026-11-16).
    static func probe(_ context: NodeContext, tools: NodeStarter.Tools) -> NodeStarter.Probe {
        switch NodeClient.connect(context, timeout: 5) {
        case .success: return .listening
        case .failure(.refused(let why)): return .refusedByCheck(why)
        case .failure(.broken): return .notYet
        case .failure(.notRunning): break
        }
        guard let ran = NodeStarter.run(tools.systemctl, ["--user", "show", "-p", "ActiveState,Result", NodeStarter.unitName],
                                        environment: NodeStarter.environment(runtimeFolder: tools.runtimeFolder), timeout: 30),
              ran.status == 0 else { return .notYet }
        var values: [String: String] = [:]
        for line in ran.output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        guard let active = values["ActiveState"], ["failed", "inactive"].contains(active) else { return .notYet }
        return .unitEnded(result: values["Result"] ?? active)
    }
}

extension StartCommand {
    /// The probe a detached start waits on (S3): the server connected and checked against the host this start spawned
    /// (`record`, held here: `node.pid` isn't read again, so a record another process writes meanwhile can't point the
    /// check at another host; the review of S3) gives `.listening` (or `.refusedByCheck`); with nothing listening, that
    /// host ended (collected, being this process's child) gives `.hostEnded`; anything else is `.notYet`.
    static func detachedProbe(_ record: NodeRecord) -> NodeStarter.Probe {
        let root = URL(fileURLWithPath: NodeFolders.nodeRoot(accountHome: VibePaths.accountHome), isDirectory: true)
        switch NodeClient.connect(NodeContext(root: root, mode: .detached(record: record)), timeout: 5) {
        case .success: return .listening
        case .failure(.refused(let why)): return .refusedByCheck(why)
        case .failure(.broken): return .notYet
        case .failure(.notRunning): break
        }
        return record.hasEnded() ? .hostEnded("pid \(record.pid)") : .notYet
    }
}

/// A value read once, when first asked for.
final class Once<Value> {
    private let make: () -> Value
    private var made: Value?

    init(_ make: @escaping () -> Value) { self.make = make }

    var value: Value {
        if let made { return made }
        let value = make()
        made = value
        return value
    }
}

/// What the command line prints, and its exit codes: 0, 64 usage, 65 bad input, 69 no node, 77 refused, 1 other.
enum Say {
    static func out(_ line: String) { try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8)) }
    static func err(_ line: String) { try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8)) }
    static func usage(_ text: String) -> Int32 { err(text); return 64 }
    static func refused(_ why: String) -> Int32 { err("vibeswitcher: refused: \(why)"); return 77 }
    /// A failure's message, inert as a whole too (each untrusted field in it already is): a refusal can carry what
    /// the listener chose.
    static func failed(_ failure: NodeClient.Failure) -> Int32 {
        err("vibeswitcher: \(ConfigSeal.inert(failure.message, limit: .max))")
        return failure.exitCode
    }

    /// A reply with an error: `voice`, `refused` and `stopping` exit 77, `bad-args` 65, the rest 1.
    static func replyError(_ reply: NodeWire.Reply) -> Int32 {
        let code = reply.error?.code ?? "internal"
        err("vibeswitcher: \(code): \(ConfigSeal.inert(reply.error?.message ?? "no reason", limit: .max))")
        return exitCode(replyCode: code)
    }

    /// The exit code for a reply's error code.
    static func exitCode(replyCode code: String) -> Int32 {
        switch code {
        case NodeWire.Code.voice.rawValue, NodeWire.Code.refused.rawValue, NodeWire.Code.stopping.rawValue: return 77
        case NodeWire.Code.badArgs.rawValue: return 65
        default: return 1
        }
    }
}

extension NodeContext {
    /// "scratch node at <root>" on stderr, for a scratch node (EN-D8).
    func sayScratch() {
        if case .scratch(let root) = mode { Say.err("scratch node at \(root)") }
    }
}
