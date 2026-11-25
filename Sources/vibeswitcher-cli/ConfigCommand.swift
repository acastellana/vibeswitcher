import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher config held [FOLDER] [--diff NAME]` and `vibeswitcher config accept CARD` (the engine plan's E6, E8;
/// S7): what the host's vault holds of the agents' config for a project, as a card bound to exactly the hashes it
/// shows, with the floor workflow.md proposes; then the user's accept of that card, which seals exactly those and then
/// records the floor (EN-D7). `config held` changes nothing and asks no code; `config accept` asks the card's.
/// `config held` and `config accept` are plain (`CardText.plainConfig`: what changed, whom it holds, the rules that
/// changed; 2026-11-25); `--long` says every path, hash and rule, every word on every line.
enum ConfigCommand {
    static let usage = "usage: vibeswitcher config held [FOLDER] [--diff NAME] [--long] | config accept CARD [--long] | config startup"

    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "held": return held(Array(arguments.dropFirst()))
        case "startup":
            // The Windows Startup shortcuts as the known-startup list writes them (`StartupShortcuts`); reads, changes nothing.
            guard arguments.count == 1 else { return Say.usage(usage) }
            StartupShortcuts.report().forEach { Say.out(ConfigSeal.inert($0, limit: 1000)) }
            return 0
        case "accept":
            let long = arguments.contains("--long")
            let rest = arguments.filter { $0 != "--long" }
            guard rest.count == 2 else { return Say.usage(usage) }
            var shown: NodeWire.Value?
            return CardCommand.act(WireKinds.ConfigAccept.self, card: rest[1], detail: long ? .long : .plain, args: { _, id, code in .init(card: id, code: code) }, what: { card in
                shown = card
                return long ? "This accepts the agents' config card \(ConfigSeal.inert(card["id"]?.string ?? "", limit: 80)) showed, sealing exactly that, "
                    + "then records the floor and guard rails workflow.md proposes."
                    : "This accepts what the card above shows (the same code accepts exactly that; --long shows every path and rule)."
            }) { result in
                guard long else {
                    // Plain (2026-11-25): one receipt line, what it was and whom it no longer holds.
                    let waits = !(result.homeWaits ?? []).isEmpty
                    Say.out((result.sealed ?? []).isEmpty && !waits ? "accepted: nothing held" : CardText.acceptedLine(shown, count: result.sealed?.count, waits: waits))
                    if result.floorRecorded == true { Say.out("its review rules are recorded") }
                    if waits {
                        let folder = ConfigSeal.inert(result.homeFolder ?? "~", limit: 300)
                        Say.out("next: accept \(folder)'s card (`vibeswitcher config held \(folder)`), then this folder's again")
                    }
                    return
                }
                // One line per path sealed, so a long accept reads as a list.
                let sealed = result.sealed ?? []
                Say.out(sealed.isEmpty ? "accepted: nothing held" : "accepted \(sealed.count) held change\(sealed.count == 1 ? "" : "s"):")
                sealed.forEach { Say.out("  " + ConfigSeal.inert($0, limit: 200)) }
                Say.out(result.floorRecorded == true ? "  the review floor is recorded" : "  no review floor recorded")
                if let waits = result.homeWaits, !waits.isEmpty {
                    let folder = ConfigSeal.inert(result.homeFolder ?? "~", limit: 300)
                    Say.out("  still held: \(waits.count) of your home folder's config: accept \(folder)'s card (`vibeswitcher config held \(folder)`), "
                        + "then this folder's card again (`vibeswitcher config held FOLDER`): its guard rails and review floor are recorded then")
                }
            }
        default: return Say.usage(usage)
        }
    }

    static func held(_ arguments: [String]) -> Int32 {
        var folder: String?
        var diff: String?
        var long = false
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word == "--diff" {
                guard index + 1 < arguments.count else { return Say.usage(usage) }
                index += 1
                diff = arguments[index]
            } else if word == "--long" {
                long = true
            } else {
                guard folder == nil, !word.hasPrefix("--") else { return Say.usage(usage) }
                folder = CardCommand.absolute(word)
            }
            index += 1
        }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        switch client.read(WireKinds.ConfigHeld.self, .init(folder: folder ?? FileManager.default.currentDirectoryPath, diff: diff), timeout: 60) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _):
            guard let card = result.card else { return Say.failed(.broken("the node's server answered config.held with no card")) }
            // Plain by default (what changed, whom it holds, the rules that changed); `--long` every path, hash and rule.
            CardText.lines(card, detail: long ? .long : .plain).forEach(Say.out)
            if let difference = result.difference {
                if let lines = difference.array { lines.compactMap(\.string).forEach { Say.out(ConfigSeal.inert($0, limit: .max)) } }
                else { Say.out(ConfigSeal.inert(difference.string ?? "", limit: .max)) }
            }
            // Nothing held and nothing to record: shown, not kept (no card to accept).
            guard card["open"]?.bool != false else {
                Say.out("Nothing is held and nothing waits to be recorded: nothing to accept.")
                return 0
            }
            Say.out("accept it with: vibeswitcher config accept \(ConfigSeal.inert(card["id"]?.string ?? "", limit: 80))")
            return 0
        }
    }
}
