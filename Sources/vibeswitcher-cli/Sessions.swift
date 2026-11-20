import Foundation
import VibeCore
import VibeNode

/// Driving an ordinary session from the command line (the parity table's gaps 1, 3 and 6, 2026-11-20). Each command is
/// the user's voice, as `tell` is: what it does shown (anything an agent or the user wrote, inert), the command line's
/// own typed code (EN-D5: from the action id, no card), then the request; the server records it in the host's vault
/// before it acts. The accepted request is written to the journal (ids only: no text, no folder).
enum SessionCommand {
    /// `kind` with `args`, after `what` is shown and the code typed; `say` prints the result. Accepted (the voice passed
    /// and the server recorded it), a refusal of the server's (`refused`) comes after that, and is journaled too.
    static func act(_ kind: String, args: [String: NodeWire.Value], what: String, timeout: TimeInterval = 120,
                    say: (NodeWire.Value) -> Void) -> Int32 {
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let action = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(code: NodeIds.code(action: action), what: what)
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        switch client.request(kind, args: args, action: action, timeout: timeout) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            if reply.ok || reply.error?.code == NodeWire.Code.refused.rawValue {
                context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: kind, epoch: client.hello.epoch))
            }
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            say(result)
            return 0
        }
    }

    /// A session's id as the command line shows it: the first 8 characters of its host id.
    static func short(_ id: String?) -> String {
        let bare = (id ?? "?").replacingOccurrences(of: NodeIds.node + ":", with: "")
        return ConfigSeal.inert(String(bare.prefix(8)), limit: 8)
    }
}

/// `vibeswitcher send SESSION TEXT`: the user's words typed into a session the node's host runs, as the app's composer
/// types them (a working agent takes them after its turn). Refused for a session the host didn't start, a shell, and
/// one with a question or picker open on its screen.
enum SendCommand {
    static let usage = "usage: vibeswitcher send SESSION TEXT"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2, !arguments[0].isEmpty, !arguments[0].hasPrefix("--"),
              !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Say.usage(usage) }
        let (session, text) = (arguments[0], arguments[1])
        let what = "This types into session \(ConfigSeal.inert(session, limit: 80)), as you: " + ConfigSeal.inert(text, limit: 400)
        return SessionCommand.act("send", args: ["session": .string(session), "text": .string(text)], what: what, say: said)
    }

    static func said(_ result: NodeWire.Value) {
        let short = SessionCommand.short(result["session"]?.string)
        let characters = result["characters"]?.int ?? 0
        Say.out(result["working"]?.bool == true
            ? "sent: \(characters) characters typed into session \(short); it was working, so it takes them after its turn"
            : "sent: \(characters) characters typed into session \(short)")
    }
}
