import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher approve [--only config,base,hooks]` (2026-11-22, the user's go-ahead): everything waiting on you that a
/// plain accept settles (held config cards, base-move cards, the hooks when out of date), each shown as its own command
/// shows it (`config held`, `base show`), then ONE code for the batch, then each done in order (config, base, hooks),
/// each reported, stopping at the first refusal with what's left. Each is recorded in the vault as its own action under
/// the one voiced request (`Requests.approve`). What needs your own decision (questions, merge approvals, shell
/// requests, a push) is listed only, with its own answer lines, never in the batch.
enum ApproveCommand {
    static let usage = "usage: vibeswitcher approve [--only config,base,hooks]"

    static func run(_ arguments: [String]) -> Int32 {
        var only: [String]?
        var index = 0
        while index < arguments.count {
            guard arguments[index] == "--only", index + 1 < arguments.count else { return Say.usage(usage) }
            let groups = arguments[index + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !groups.isEmpty, groups.allSatisfy(["config", "base", "hooks"].contains) else { return Say.usage(usage) }
            only = groups
            index += 2
        }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let listed: NodeWire.Value
        switch client.request("approve.list", args: only.map { ["only": .array($0.map(NodeWire.Value.string))] }, timeout: 120) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            listed = result
        }
        let items = listed["items"]?.array ?? []
        // What needs your own decision first: never in the batch, and never scrolled past by it.
        sayDecide(listed)
        for (number, item) in items.enumerated() {
            Say.out("\(number + 1). " + heading(item))
            lines(item).forEach { Say.out("   " + $0) }
        }
        guard !items.isEmpty, let batch = listed["batch"]?.string, let code = listed["code"]?.string else {
            Say.out("Nothing a plain accept settles is waiting on you.")
            return 0
        }
        let action = UUID().uuidString.lowercased()
        // Directly above the code: one line per item, what it does.
        let recap = items.enumerated().map { "  \($0.offset + 1). " + recapLine($0.element) }.joined(separator: "\n")
        let what = "The batch, in this order (each recorded as its own action; it stops at the first refusal):\n" + recap
        let said = TypedWord.said(approval: client.approvalRule, action: action, code: code, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        let result: NodeWire.Value
        switch client.change("approve", args: ["batch": .string(batch), "code": .string(code)], action: action, typed: typed, timeout: 600) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let given = reply.result else { return Say.replyError(reply) }
            result = given
        }
        // Each item recorded in the vault as its own action: each journaled, so `status` finds them all accounted for.
        for done in result["done"]?.array ?? [] {
            if let itemAction = done["action"]?.string { client.journal(done["kind"]?.string ?? "", action: itemAction, typed: typed) }
            Say.out("done: " + summary(done))
        }
        guard let refused = result["refused"], refused != .null else {
            Say.out("all \(items.count) done")
            return 0
        }
        if refused["code"]?.string == NodeWire.Code.refused.rawValue, let itemAction = refused["action"]?.string {
            client.journal(refused["kind"]?.string ?? "", action: itemAction, typed: typed)
        }
        Say.err("vibeswitcher: stopped at \(inert(refused["kind"]?.string)) \(inert(refused["subject"]?.string)): \(inert(refused["message"]?.string))")
        let left = result["left"]?.array ?? []
        if !left.isEmpty {
            Say.err("not done: " + left.map { "\(inert($0["kind"]?.string)) \(inert($0["subject"]?.string))" }.joined(separator: "; ")
                    + " (run `vibeswitcher approve` again once that is settled)")
        }
        return 77
    }

    static func heading(_ item: NodeWire.Value) -> String {
        switch item["kind"]?.string {
        case "config.accept": return "Held config, \(inert(item["subject"]?.string)) (config accept):"
        case "base.accept": return "The base moved, \(inert(item["subject"]?.string)) (base accept):"
        case "hooks.install": return "The hooks are out of date (hooks install --agent \(inert(item["subject"]?.string))):"
        default: return inert(item["kind"]?.string)
        }
    }

    /// The item as its own command shows it: its card (`config held`, `base show`), or why the hooks are out of date.
    static func lines(_ item: NodeWire.Value) -> [String] {
        if let card = item["card"], card != .null { return CardText.lines(card) }
        return (item["reasons"]?.array ?? []).compactMap(\.string).map { inert($0) }
    }

    /// What needs your own decision, counted, each with the command that settles it: questions, merge approvals and shell
    /// requests (`vibeswitcher questions` shows them), a push asked for, and what the batch leaves to you (a config card
    /// with guard rails or a review floor to record, a base moved from a head the vault can't vouch for, the hooks beside
    /// a config accept).
    static func sayDecide(_ listed: NodeWire.Value) {
        let decide = listed["decide"]?.array ?? []
        let pushes = (listed["pushes"]?.array ?? []).compactMap(\.string)
        let own = listed["own"]?.array ?? []
        guard !decide.isEmpty || !pushes.isEmpty || !own.isEmpty else { return }
        Say.out("Waiting on your own decision (not in the batch; each with its own command and code):")
        let count = { (kind: String) in decide.filter { $0["kind"]?.string == kind }.count }
        // A feature plugin's cards, counted by what one is called (`PluginCard.noun`).
        var nouns: [String] = []
        for card in decide { if let noun = card["plugin"]?["noun"]?.string, !nouns.contains(noun) { nouns.append(noun) } }
        let plugins = nouns.map { noun in (inert(noun), decide.filter { $0["plugin"]?["noun"]?.string == noun }.count) }
        let cards = ([("question", count("question")), ("merge approval", count("approval"))] + plugins)
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)\($0.1 == 1 ? "" : "s")" }
        if !cards.isEmpty { Say.out("   " + cards.joined(separator: ", ") + ": see vibeswitcher questions (each answered with vibeswitcher answer CARD)") }
        for root in pushes { Say.out("   a push asked for in \(inert(root)): vibeswitcher push \(inert(root)) | decline-push \(inert(root))") }
        for entry in own { Say.out("   \(inert(entry["text"]?.string)): \(inert(entry["command"]?.string))") }
    }

    /// One line for an item: what it is, where, what it seals or moves.
    static func recapLine(_ item: NodeWire.Value) -> String {
        let folder = inert(item["subject"]?.string)
        switch item["kind"]?.string {
        case "config.accept":
            let names = (item["card"]?["config"]?["items"]?.array ?? []).compactMap { $0["name"]?.string }.map { inert($0) }
            let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
            return "config accept, \(folder): seals \(names.count) (\(shown))"
        case "base.accept":
            let base = item["card"]?["base"]
            let from = String((base?["from"]?.string ?? "?").prefix(8)), to = String((base?["to"]?.string ?? "?").prefix(8))
            return "base accept, \(folder): \(inert(base?["branch"]?.string)) from \(from) to \(to)"
        case "hooks.install": return "hooks install: \(folder)"
        default: return "\(inert(item["kind"]?.string)), \(folder)"
        }
    }

    static func summary(_ done: NodeWire.Value) -> String {
        let kind = done["kind"]?.string ?? ""
        let subject = inert(done["subject"]?.string)
        switch kind {
        case "config.accept":
            let sealed = done["result"]?["sealed"]?.array?.count ?? 0
            return "config accepted, \(subject)" + (sealed > 0 ? " (\(sealed) path\(sealed == 1 ? "" : "s") sealed)" : "")
        case "base.accept": return "base accepted, \(subject)"
        case "hooks.install": return "hooks installed (\(subject))"
        default: return "\(inert(kind)) \(subject)"
        }
    }

    static func inert(_ text: String?) -> String { ConfigSeal.inert(text ?? "?", limit: 400) }
}
