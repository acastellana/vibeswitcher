import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher base show FOLDER [--from COMMIT]`, `base accept CARD`, `base keep CARD` (the engine plan's E6, E8;
/// S7): a project's base as a card (the move a look found, or one `show` makes on demand, also with no lead running),
/// the user's accept of it (the vault's head recorded where the card showed the base) and keeping a move refused.
/// `show` changes nothing and asks no code; `accept` and `keep` ask the card's.
enum BaseCommand {
    static let usage = "usage: vibeswitcher base show FOLDER [--from COMMIT] | base accept CARD | base keep CARD"

    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "show": return show(Array(arguments.dropFirst()))
        case "accept":
            guard arguments.count == 2 else { return Say.usage(usage) }
            return CardCommand.act("base.accept", card: arguments[1], what: { card in
                "This records \(ConfigSeal.inert(card["base"]?["branch"]?.string ?? "the base", limit: 80)) at "
                    + "\(ConfigSeal.inert(card["base"]?["to"]?.string ?? "?", limit: 80)) as the lead's base, the commits shown and no further."
            }) { result in
                Say.out("recorded: \(ConfigSeal.inert(result["branch"]?.string ?? "", limit: 80)) at \(ConfigSeal.inert(result["head"]?.string ?? "", limit: 80))")
            }
        case "keep":
            guard arguments.count == 2 else { return Say.usage(usage) }
            return CardCommand.act("base.keep", card: arguments[1], what: { _ in
                "This keeps the lead's merges refused for this move: you aren't asked again until the base moves again."
            }) { _ in Say.out("kept refused") }
        default: return Say.usage(usage)
        }
    }

    static func show(_ arguments: [String]) -> Int32 {
        var folder: String?
        var from: String?
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word == "--from" {
                guard index + 1 < arguments.count else { return Say.usage(usage) }
                index += 1
                from = arguments[index]
            } else {
                guard folder == nil, !word.hasPrefix("--") else { return Say.usage(usage) }
                folder = CardCommand.absolute(word)
            }
            index += 1
        }
        guard let folder else { return Say.usage(usage) }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        switch client.read(WireKinds.BaseShow.self, .init(folder: folder, from: from), timeout: 60) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _):
            guard let card = result.card else { return Say.failed(.broken("the node's server answered base.show with no card")) }
            CardText.lines(card).forEach(Say.out)
            Say.out("accept it with: vibeswitcher base accept \(ConfigSeal.inert(card["id"]?.string ?? "", limit: 80))")
            return 0
        }
    }
}
