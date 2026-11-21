import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher answer CARD TEXT` and `vibeswitcher hold CARD` (the engine plan's E6): the user's answer to a lead's
/// question or approval (or `run`/`decline` on a shell request's card, `ShellCards.swift`), and a hold of a question's timer, each in the user's voice after the card's code is typed
/// (EN-D5). The server records it in the host's vault before the lead is told or a merge is approved.
///
/// `vibeswitcher answer CARD` with no text takes the answer a web page drafted on the card (the live plan's F3, LW-D6):
/// the card as the engine built it and the draft are printed, whole and inert, then the code is asked and `answer` is
/// sent with the draft's text and the version it was drafted for. What is sent is what was shown: the server answers
/// with the request's text, never with whatever the card holds by then. A page only leaves the draft; this is the
/// user's voice, as every answer is.
enum AnswerCommand {
    static let usage = "usage: vibeswitcher answer CARD [TEXT]  (no TEXT: the answer drafted on the card's web page; a shell request's card: run or decline)"

    static func run(_ arguments: [String]) -> Int32 {
        if arguments.count == 1 { return takeDraft(arguments[0]) }
        guard arguments.count == 2, !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Say.usage(usage) }
        let text = arguments[1]
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CardCommand.act("answer", card: arguments[0], refuse: { card in
            // A shell request (`vs-shell run`): run or decline, nothing else.
            guard card["kind"]?.string == "shell", !["run", "decline"].contains(word) else { return nil }
            return Say.usage("usage: vibeswitcher answer CARD run|decline  (a shell request's card)")
        }, args: { card in
            // Bound to the wording shown: a revision after it is said to the lead with the answer.
            ["text": .string(card["kind"]?.string == "shell" ? word : text), "version": card["question"]?["version"] ?? .null]
        }, what: { card in
            let id = ConfigSeal.inert(card["id"]?.string ?? "", limit: 80)
            guard card["kind"]?.string == "shell" else { return "This answers card \(id) with: \(ConfigSeal.inert(text, limit: 400))" }
            let folder = ConfigSeal.inert(card["shell"]?["cwd"]?.string ?? "?", limit: .max)
            return word == "run"
                ? "This runs the command above, exactly as shown, in a new shell session in \(folder), as you: it runs with everything your account can do."
                : "This declines card \(id)'s shell request: nothing runs, and the asking session is told."
        }, say: said)
    }

    /// The card's draft, if it has one: its text and the question's version it was drafted for.
    static func draft(of card: NodeWire.Value) -> (text: String, version: NodeWire.Value)? {
        guard let text = card["draft"]?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, card["draft"]?["version"] ?? .null)
    }

    private static func takeDraft(_ wanted: String) -> Int32 {
        CardCommand.act("answer", card: wanted, refuse: { card in
            guard draft(of: card) == nil else { return nil }
            let id = ConfigSeal.inert(card["id"]?.string ?? wanted, limit: 80)
            return Say.usage("\(usage)\ncard \(id) has no draft: pick an answer on its web page, or give TEXT")
        }, args: { card in
            let taken = draft(of: card)
            return ["text": .string(taken?.text ?? ""), "version": taken?.version ?? .null]
        }, what: { card in
            // Whole: this is what the lead will be told as the user's.
            "This answers card \(ConfigSeal.inert(card["id"]?.string ?? "", limit: 80)) with the answer drafted on its web page: "
                + ConfigSeal.inert(draft(of: card)?.text ?? "", limit: .max)
        }, say: said)
    }

    private static func said(_ result: NodeWire.Value) {
        let outcome = result["outcome"]?.string ?? "?"
        switch outcome {
        case "answered": Say.out("answered: the lead is told")
        case "started":
            Say.out("started: a new shell session on \(ConfigSeal.inert(result["terminal"]?.string ?? "?", limit: 80)) "
                    + "(\(ConfigSeal.inert(result["session"]?.string ?? "?", limit: 120))); the asking session is told")
        case "declined": Say.out("declined: nothing ran; the asking session is told")
        default: Say.out("not taken as an answer: \(ConfigSeal.inert(outcome, limit: 80))")
        }
        if let notice = result["notice"]?.string { Say.out("  " + ConfigSeal.inert(notice, limit: .max)) }
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
