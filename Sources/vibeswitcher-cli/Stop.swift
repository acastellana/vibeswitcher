import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher stop` (the engine plan's EN-D6): through the server, which stops taking requests, ends the leads and
/// then every other session, and asks the host to shut down. The typed code (the command line's own, from the action
/// id) first; the accepted request is written to the journal (ids only).
enum StopCommand {
    static let usage = "usage: vibeswitcher stop"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.isEmpty else { return Say.usage(usage) }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let action = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(code: NodeIds.code(action: action),
                                    what: "This ends every session on the node (the leads first), then stops its host.")
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        let record = { context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: "stop", epoch: client.hello.epoch)) }
        switch client.request("stop", action: action, timeout: Requests.stopWait + 30) {
        case .failure(.broken(let why)):
            // The host ends the server a moment after it accepts the shutdown: a reply that didn't get out in time
            // leaves the connection closed with none. The node gone is the answer then; anything else is a failure.
            guard case .failure(.notRunning) = NodeClient.connect(context, timeout: 5) else { return Say.failed(.broken(why)) }
            record()
            Say.out("the node stopped (its server ended before it answered)")
            return 0
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok else { return Say.replyError(reply) }
            record()
            Say.out("\(reply.result?["sessionsEnded"]?.int ?? 0) sessions ended; the host accepted to shut down")
            return 0
        }
    }
}
