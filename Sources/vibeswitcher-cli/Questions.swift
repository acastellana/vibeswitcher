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
        let args = WireKinds.Questions.Args(folder: folder, all: all, wait: wait ? true : nil)
        // A wait the server ends with no card (`Requests.cardWait`) is asked again: until a card needs the user.
        var answer = client.read(WireKinds.Questions.self, args, timeout: wait ? Requests.cardWait + 30 : 30)
        while wait, case .success(let result, _) = answer, result.waited == true {
            answer = client.read(WireKinds.Questions.self, args, timeout: Requests.cardWait + 30)
        }
        switch answer {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, let raw):
            let cards = result.cards ?? []
            if json {
                Say.out(String(decoding: NodeWire.printable(NodeWire.line(raw)).dropLast(), as: UTF8.self))
                return 0
            }
            if cards.isEmpty { Say.out(all ? "no cards" : "no open cards") }
            for card in cards { CardText.lines(card).forEach(Say.out) }
            if let more = result.more, more > 0 { Say.out(moreLine(more)) }
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
        if case .success(let card) = find(wanted, client: client, args: .init(card: wanted)) { return .success(card) }
        if case .success(let card) = find(wanted, client: client, args: .init()) { return .success(card) }
        return find(wanted, client: client, args: .init(all: true))
    }

    private static func find(_ wanted: String, client: NodeClient, args: WireKinds.Questions.Args) -> Result<NodeWire.Value, NodeClient.Failure> {
        switch client.read(WireKinds.Questions.self, args) {
        case .failure(let failure): return .failure(failure)
        case .refused(let reply): return .failure(.broken(reply.error.map { "\($0.code): \($0.message)" } ?? "the server answered no cards"))
        case .success(let result, _):
            guard let cards = result.cards else { return .failure(.broken("the server answered no cards")) }
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
    /// `args`: the request's, from the card found, its id and its code.
    /// `detail`: how the card is shown (`CardText.Detail`: a held-config card plain unless `--long`).
    static func act<K: WireChangeKind>(_ kind: K.Type, card wanted: String, detail: CardText.Detail = .plain, refuse: (NodeWire.Value) -> Int32? = { _ in nil },
                                       args: (_ card: NodeWire.Value, _ id: String, _ code: String) -> K.Args,
                                       what: (NodeWire.Value) -> String,
                                       say: (K.Result) -> Void) -> Int32 {
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
        CardText.lines(card, detail: detail).forEach(Say.out)
        let code = NodeIds.code(card: id)
        let action = UUID().uuidString.lowercased()
        // Under the Mac's rule the dialog carries this request's word (its action id's), not the card's code.
        let said = TypedWord.said(approval: client.approvalRule, action: action, code: code, what: what(card))
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        switch client.change(K.self, args(card, id, code), action: action, typed: typed, timeout: 120) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _):
            say(result)
            return 0
        }
    }
}
