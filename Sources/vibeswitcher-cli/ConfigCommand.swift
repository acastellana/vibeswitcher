import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher config held [FOLDER] [--diff NAME]` and `vibeswitcher config accept CARD` (the engine plan's E6, E8;
/// S7): what the host's vault holds of the agents' config for a project, as a card bound to exactly the hashes it
/// shows, with the floor workflow.md proposes; then the user's accept of that card, which seals exactly those and then
/// records the floor (EN-D7). `config held` changes nothing and asks no code; `config accept` asks the card's.
/// `config held` is short (`CardText.lines(_:long:)`: a line per held thing and guard rail, a word they share said once);
/// `--long` says every word on every line.
enum ConfigCommand {
    static let usage = "usage: vibeswitcher config held [FOLDER] [--diff NAME] [--long] | config accept CARD | config startup"

    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "held": return held(Array(arguments.dropFirst()))
        case "startup":
            // The Windows Startup shortcuts as the known-startup list writes them (`StartupShortcuts`); reads, changes nothing.
            guard arguments.count == 1 else { return Say.usage(usage) }
            StartupShortcuts.report().forEach { Say.out(ConfigSeal.inert($0, limit: 1000)) }
            return 0
        case "accept":
            guard arguments.count == 2 else { return Say.usage(usage) }
            return CardCommand.act("config.accept", card: arguments[1], what: { card in
                "This accepts the agents' config card \(ConfigSeal.inert(card["id"]?.string ?? "", limit: 80)) showed, sealing exactly that, "
                    + "then records the floor and guard rails workflow.md proposes."
            }) { result in
                // One line per path sealed, so a long accept reads as a list.
                let sealed = result["sealed"]?.array?.compactMap(\.string) ?? []
                Say.out(sealed.isEmpty ? "accepted: nothing held" : "accepted \(sealed.count) held change\(sealed.count == 1 ? "" : "s"):")
                sealed.forEach { Say.out("  " + ConfigSeal.inert($0, limit: 200)) }
                Say.out(result["floorRecorded"]?.bool == true ? "  the review floor is recorded" : "  no review floor recorded")
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
        var args: [String: NodeWire.Value] = ["folder": .string(folder ?? FileManager.default.currentDirectoryPath)]
        if let diff { args["diff"] = .string(diff) }
        switch client.request("config.held", args: args, timeout: 60) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result, let card = result["card"] else { return Say.replyError(reply) }
            CardText.lines(card, long: long).forEach(Say.out)
            if let difference = result["difference"] {
                if let lines = difference.array { lines.compactMap(\.string).forEach { Say.out(ConfigSeal.inert($0, limit: .max)) } }
                else { Say.out(ConfigSeal.inert(difference.string ?? "", limit: .max)) }
            }
            Say.out("accept it with: vibeswitcher config accept \(ConfigSeal.inert(card["id"]?.string ?? "", limit: 80))")
            return 0
        }
    }
}
