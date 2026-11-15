import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher questions [FOLDER] [--all] [--json]` (the engine plan's E6): the open cards the server holds (the
/// lead's questions and approvals, held config, base moves), closed ones too with `--all`. A read: anyone of the uid,
/// no code. Every field a worker or the lead wrote is printed inert (`CardText`).
enum QuestionsCommand {
    static let usage = "usage: vibeswitcher questions [FOLDER] [--all] [--json]"

    static func run(_ arguments: [String]) -> Int32 {
        var folder: String?
        var all = false, json = false
        for word in arguments {
            switch word {
            case "--all": all = true
            case "--json": json = true
            default:
                guard folder == nil, !word.hasPrefix("--") else { return Say.usage(usage) }
                folder = CardCommand.absolute(word)
            }
        }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        var args: [String: NodeWire.Value] = ["all": .bool(all)]
        if let folder { args["folder"] = .string(folder) }
        switch client.request("questions", args: args) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let cards = reply.result?["cards"]?.array else { return Say.replyError(reply) }
            if json {
                Say.out(String(decoding: NodeWire.line(reply.result ?? .null).dropLast(), as: UTF8.self))
                return 0
            }
            if cards.isEmpty { Say.out(all ? "no cards" : "no open cards") }
            for card in cards { CardText.lines(card).forEach(Say.out) }
            return 0
        }
    }
}

/// What the commands on a card share: finding it, showing it, its code typed, the request, and its journal entry.
enum CardCommand {
    /// `path` made absolute against the working folder.
    static func absolute(_ path: String, cwd: String = FileManager.default.currentDirectoryPath) -> String {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
    }

    /// The card `wanted` names among every card the server holds: its whole id, or a prefix of its UUID that only one
    /// has.
    static func find(_ wanted: String, client: NodeClient) -> Result<NodeWire.Value, NodeClient.Failure> {
        switch client.request("questions", args: ["all": .bool(true)]) {
        case .failure(let failure): return .failure(failure)
        case .success(let reply):
            guard reply.ok, let cards = reply.result?["cards"]?.array else {
                return .failure(.broken(reply.error.map { "\($0.code): \($0.message)" } ?? "the server answered no cards"))
            }
            let wanted = wanted.lowercased()
            let prefix = "\(NodeIds.node):card:"
            let part = wanted.hasPrefix(prefix) ? String(wanted.dropFirst(prefix.count)) : wanted
            let matches = cards.filter { card in
                guard let id = card["id"]?.string else { return false }
                return id == wanted || (part.count >= 4 && id.dropFirst(prefix.count).hasPrefix(part))
            }
            guard matches.count == 1, let card = matches.first else {
                return .failure(.refused(matches.isEmpty ? "no card \(ConfigSeal.inert(wanted, limit: 80)) (vibeswitcher questions --all lists them)"
                                                        : "\(ConfigSeal.inert(wanted, limit: 80)) begins \(matches.count) cards' ids: give more of it"))
            }
            return .success(card)
        }
    }

    /// `kind` on the card `wanted` (`answer`, `hold`, `config.accept`, `base.accept`, `base.keep`): the card shown, what
    /// the request does said, the card's code typed (EN-D5; checked again by the server), then the request with a new
    /// action id; the accepted request journaled (ids only). `say` prints the result.
    static func act(_ kind: String, card wanted: String, args extra: (NodeWire.Value) -> [String: NodeWire.Value] = { _ in [:] },
                    what: (NodeWire.Value) -> String,
                    say: (NodeWire.Value) -> Void) -> Int32 {
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let card: NodeWire.Value
        switch find(wanted, client: client) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let found): card = found
        }
        guard let id = card["id"]?.string else { return Say.refused("the server's card has no id") }
        CardText.lines(card).forEach(Say.out)
        let code = NodeIds.code(card: id)
        let outcome = TypedWord.ask(code: code, what: what(card))
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        let action = UUID().uuidString.lowercased()
        var args = extra(card)
        args["card"] = .string(id)
        args["code"] = .string(code)
        switch client.request(kind, args: args, action: action, timeout: 120) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            // Recorded by the server (the voice and the code passed): an engine's refusal comes after that.
            if reply.ok || reply.error?.code == NodeWire.Code.refused.rawValue {
                context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: kind, epoch: client.hello.epoch))
            }
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            say(result)
            return 0
        }
    }
}
