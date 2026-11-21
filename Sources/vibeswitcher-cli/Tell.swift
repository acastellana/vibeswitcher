import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher tell FOLDER TEXT` (2026-11-19): tells the project's running lead something that isn't an answer, in
/// the user's voice after the command line's own typed code (EN-D5, as `lead`'s: no card). The server records it in
/// the host's vault, then delivers it to the lead as a message from the user, held until the lead can take it; refused
/// when no lead runs there. The text is shown inert before the code. The accepted request is written to the journal
/// (ids only: no text, no folder).
enum TellCommand {
    static let usage = "usage: vibeswitcher tell FOLDER TEXT"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2, !arguments[0].isEmpty, !arguments[0].hasPrefix("--"),
              !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Say.usage(usage) }
        let folder = CardCommand.absolute(arguments[0])
        let text = arguments[1]
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let action = UUID().uuidString.lowercased()
        let what = "This tells the lead of \(ConfigSeal.inert(folder, limit: 400)), as you (not an answer to a card): "
            + ConfigSeal.inert(text, limit: 400)
        let outcome = TypedWord.ask(approval: client.approvalRule, code: NodeIds.code(action: action), what: what)
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        switch client.request("tell", args: ["folder": .string(folder), "text": .string(text)], action: action, timeout: 120) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            // Accepted (the voice passed and the server recorded it): the engine's refusal (`refused`) comes after that.
            if reply.ok || reply.error?.code == NodeWire.Code.refused.rawValue {
                context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: "tell", epoch: client.hello.epoch))
            }
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            Say.out("told: the lead (session \(ConfigSeal.inert(result["session"]?.string ?? "?", limit: 80))) gets it at its next step, "
                    + "or once it can take it")
            return 0
        }
    }
}
