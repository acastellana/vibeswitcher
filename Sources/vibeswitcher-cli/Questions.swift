import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher questions [FOLDER] [--all | --wait] [--json]` (the engine plan's E6): the open cards the server holds
/// (the lead's questions and approvals, held config, base moves), closed ones too with `--all`. With `--wait`, it
/// blocks until a card needs the user (at once when one does), prints the open ones and exits. A read: anyone of the uid,
/// no code. Every field a worker or the lead wrote is printed inert (`CardText`); under `--json`, what `inert` would
/// replace is escaped (`NodeWire.printable`).
enum QuestionsCommand {
    static let usage = "usage: vibeswitcher questions [FOLDER] [--all | --wait] [--json]"

    /// What `--all` says of the closed cards it left out (the server lists the newest, `Requests.closedListed`).
    static func moreLine(_ more: Int) -> String {
        "\(more) more closed card\(more == 1 ? "" : "s") not shown (the newest are; a card's whole id or its prefix finds any: vibeswitcher answer CARD)"
    }

    static func run(_ arguments: [String]) -> Int32 {
        var folder: String?
        var all = false, json = false, wait = false
        for word in arguments {
            switch word {
            case "--all": all = true
            case "--json": json = true
            case "--wait": wait = true
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
        guard !(all && wait) else { return Say.usage(usage) }
        var args: [String: NodeWire.Value] = ["all": .bool(all)]
        if let folder { args["folder"] = .string(folder) }
        if wait { args["wait"] = .bool(true) }
        // A wait the server ends with no card (`Requests.cardWait`) is asked again: until a card needs the user.
        var answer = client.request("questions", args: args, timeout: wait ? Requests.cardWait + 30 : 30)
        while wait, case .success(let reply) = answer, reply.ok, reply.result?["waited"]?.bool == true {
            answer = client.request("questions", args: args, timeout: Requests.cardWait + 30)
        }
        switch answer {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let cards = reply.result?["cards"]?.array else { return Say.replyError(reply) }
            if json {
                Say.out(String(decoding: NodeWire.printable(NodeWire.line(reply.result ?? .null)).dropLast(), as: UTF8.self))
                return 0
            }
            if cards.isEmpty { Say.out(all ? "no cards" : "no open cards") }
            for card in cards { CardText.lines(card).forEach(Say.out) }
            if let more = reply.result?["more"]?.int, more > 0 { Say.out(moreLine(more)) }
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
    /// has. The server is asked for that card alone (`questions` with `card`), so however many it holds the reply is one
    /// card (2026-11-19: 329 cards, 1.4 MB, past a line's limit, and no card could be answered). A server from before
    /// `card` lists its open cards for it (it ignores the field), then all of them, and the match is made here.
    static func find(_ wanted: String, client: NodeClient) -> Result<NodeWire.Value, NodeClient.Failure> {
        if case .success(let card) = find(wanted, client: client, args: ["card": .string(wanted)]) { return .success(card) }
        if case .success(let card) = find(wanted, client: client, args: nil) { return .success(card) }
        return find(wanted, client: client, args: ["all": .bool(true)])
    }

    private static func find(_ wanted: String, client: NodeClient, args: [String: NodeWire.Value]?) -> Result<NodeWire.Value, NodeClient.Failure> {
        switch client.request("questions", args: args) {
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
    /// `refuse`, given the card found, says the exit status when the request can't go on (nil: it can), before the card
    /// is printed or the code asked.
    static func act(_ kind: String, card wanted: String, refuse: (NodeWire.Value) -> Int32? = { _ in nil },
                    args extra: (NodeWire.Value) -> [String: NodeWire.Value] = { _ in [:] },
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
        if let status = refuse(card) { return status }
        CardText.lines(card).forEach(Say.out)
        let code = NodeIds.code(card: id)
        let action = UUID().uuidString.lowercased()
        // Under the Mac's rule the dialog carries this request's word (its action id's), not the card's code.
        let said = TypedWord.said(approval: client.approvalRule, action: action, code: code, what: what(card))
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        var args = extra(card)
        args["card"] = .string(id)
        args["code"] = .string(code)
        switch client.change(kind, args: args, action: action, typed: typed, timeout: 120) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            say(result)
            return 0
        }
    }
}
