import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher start [--interop-is-on]` (the engine plan's E1; the bootstrap path's step 8 starts a stopped node and
/// calls the same print). Before anything it reads the machine (`NodeFacts`): with WSL interop on it refuses unless
/// told; it says automount, a `kernel=` line and the manager's environment. Then, to a running node, it asks the
/// server (the user's voice) and prints when the node started; and until the journal holds a `not-promised-ack` entry
/// the voice rule passes, it prints S11's list in short (`NotPromised`), asks for the typed code and writes that entry.
enum StartCommand {
    static let usage = "usage: vibeswitcher start [--interop-is-on]"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.isEmpty || arguments == ["--interop-is-on"] else { return Say.usage(usage) }
        let context = NodeContext.current()
        context.sayScratch()
        let facts = context.facts()
        if let refusal = StartCheck.refusal(facts: facts, interopIsOn: arguments == ["--interop-is-on"]) {
            return Say.refused(refusal)
        }
        for line in facts.lines { Say.out(line) }
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let action = UUID().uuidString.lowercased()
        switch client.request("start", action: action) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: "start", epoch: client.hello.epoch))
            Say.out("the node runs: its server since \(ConfigSeal.inert(result["serverStartedAt"]?.string ?? "?", limit: 64)), its host since \(ConfigSeal.inert(result["hostStartedAt"]?.string ?? "?", limit: 64))")
        }
        return acknowledgeNotPromised(context)
    }

    /// S11's list, once: printed and acknowledged by the typed code (a journal entry), unless an entry that passes the
    /// rule is there already.
    static func acknowledgeNotPromised(_ context: NodeContext) -> Int32 {
        let entries: [JournalEntry]
        switch context.journalEntries() {
        case .failure(let failure):
            Say.out(NotPromised.text)
            Say.out("(\(failure.reason): the acknowledgment can't be recorded)")
            return 0
        case .success(let read): entries = read
        }
        let rule = context.journalRule
        if entries.contains(where: { $0.identifier == NodeJournal.identifier && $0.event == NotPromised.ackEvent && NodeJournal.passes($0, rule: rule) }) {
            return 0
        }
        Say.out(NotPromised.text)
        let action = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(code: NodeIds.code(action: action), what: "This records that you read the list above (a journal entry).")
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        guard context.writeJournal(NodeJournal.entry(event: NotPromised.ackEvent, action: action)) else {
            Say.err("vibeswitcher: the acknowledgment couldn't be written to the journal")
            return 1
        }
        Say.out("recorded: you read what plain mode doesn't promise")
        return 0
    }
}

/// What the command line prints, and its exit codes: 0, 64 usage, 65 bad input, 69 no node, 77 refused, 1 other.
enum Say {
    static func out(_ line: String) { try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8)) }
    static func err(_ line: String) { try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8)) }
    static func usage(_ text: String) -> Int32 { err(text); return 64 }
    static func refused(_ why: String) -> Int32 { err("vibeswitcher: refused: \(why)"); return 77 }
    static func failed(_ failure: NodeClient.Failure) -> Int32 {
        err("vibeswitcher: \(failure.message)")
        return failure.exitCode
    }

    /// A reply with an error: `voice` and `refused` exit 77, `bad-args` 65, the rest 1.
    static func replyError(_ reply: NodeWire.Reply) -> Int32 {
        let code = reply.error?.code ?? "internal"
        err("vibeswitcher: \(code): \(ConfigSeal.inert(reply.error?.message ?? "no reason", limit: .max))")
        switch code {
        case NodeWire.Code.voice.rawValue, NodeWire.Code.refused.rawValue: return 77
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
