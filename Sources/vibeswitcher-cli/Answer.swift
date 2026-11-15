import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher answer CARD TEXT` and `vibeswitcher hold CARD` (the engine plan's E6): the user's answer to a lead's
/// question or approval, and a hold of a question's timer, each in the user's voice after the card's code is typed
/// (EN-D5). The server records it in the host's vault before the lead is told or a merge is approved.
enum AnswerCommand {
    static let usage = "usage: vibeswitcher answer CARD TEXT"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2, !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Say.usage(usage) }
        let text = arguments[1]
        return CardCommand.act("answer", card: arguments[0], args: { card in
            // Bound to the wording shown: a revision after it is said to the lead with the answer.
            ["text": .string(text), "version": card["question"]?["version"] ?? .null]
        }, what: { card in
            "This answers card \(ConfigSeal.inert(card["id"]?.string ?? "", limit: 80)) with: \(ConfigSeal.inert(text, limit: 400))"
        }) { result in
            let outcome = result["outcome"]?.string ?? "?"
            Say.out(outcome == "answered" ? "answered: the lead is told" : "not taken as an answer: \(ConfigSeal.inert(outcome, limit: 80))")
            if let notice = result["notice"]?.string { Say.out("  " + ConfigSeal.inert(notice, limit: .max)) }
        }
    }
}

enum HoldCommand {
    static let usage = "usage: vibeswitcher hold CARD"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1 else { return Say.usage(usage) }
        return CardCommand.act("hold", card: arguments[0], what: { card in
            "This holds card \(ConfigSeal.inert(card["id"]?.string ?? "", limit: 80))'s timer: the lead is told not to go ahead and to wait for your answer."
        }) { _ in Say.out("held: the lead waits for your answer") }
    }
}
