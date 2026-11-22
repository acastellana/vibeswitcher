import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher close-shells [FOLDER]` (the stability lane, 2026-11-20; the app's Close Finished Shells…): the node's
/// shell sessions back at their prompt (in FOLDER or below, when given) listed, then, after the typed code, ended with
/// whatever they left running (`session.close-shells`, the user's voice). A shell still running something is left.
enum CloseShellsCommand {
    static let usage = "usage: vibeswitcher close-shells [FOLDER]"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count <= 1, arguments.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("--") }) else { return Say.usage(usage) }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let finished: [WireKinds.Shells.Shell]
        switch client.read(WireKinds.Shells.self, .init(folder: arguments.first.map { CardCommand.absolute($0) })) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _):
            let shells = result.shells ?? []
            finished = shells.filter { $0.finished == true }
            let busy = shells.count - finished.count
            if finished.isEmpty {
                Say.out("no finished shell to close" + (busy > 0 ? " (\(busy) still running something)" : ""))
                return 0
            }
            if busy > 0 { Say.out("\(busy) shell\(busy == 1 ? "" : "s") still running something: left open") }
        }
        let lines = finished.map { shell in
            "  \(SessionCommand.short(shell.session)) on \(ConfigSeal.inert(shell.terminal ?? "?", limit: 20)) in "
                + ConfigSeal.inert(shell.folder ?? "?", limit: .max)
        }
        let action = UUID().uuidString.lowercased()
        let said = TypedWord.said(approval: client.approvalRule, action: action, what: "This ends \(finished.count) shell\(finished.count == 1 ? "" : "s") "
            + "back at its prompt, with anything it left running:\n" + lines.joined(separator: "\n"))
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        switch client.change("session.close-shells", args: ["sessions": .array(finished.compactMap { $0.session.map(NodeWire.Value.string) })], action: action, typed: typed) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            let ended = result["ended"]?.array ?? [], left = result["left"]?.array ?? []
            Say.out("closed: \(ended.count) shell\(ended.count == 1 ? "" : "s")"
                + (left.isEmpty ? "" : "; \(left.count) left open (busy again, or gone)"))
            return 0
        }
    }
}
