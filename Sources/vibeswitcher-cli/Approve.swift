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
        for (number, item) in items.enumerated() {
            Say.out("\(number + 1). " + heading(item))
            lines(item).forEach { Say.out("   " + $0) }
        }
        sayDecide(listed)
        guard !items.isEmpty, let batch = listed["batch"]?.string, let code = listed["code"]?.string else {
            Say.out("Nothing a plain accept settles is waiting on you.")
            return 0
        }
        let action = UUID().uuidString.lowercased()
        let what = "This does the \(items.count) accept\(items.count == 1 ? "" : "s") listed above, in that order (config, base, hooks), each "
            + "recorded as its own action, and stops at the first refusal."
        let outcome = TypedWord.ask(approval: client.approvalRule, code: code, what: what, word: NodeIds.code(action: action))
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        let result: NodeWire.Value
        switch client.request("approve", args: ["batch": .string(batch), "code": .string(code)], action: action, timeout: 600) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            if reply.ok || reply.error?.code == NodeWire.Code.refused.rawValue { journal(context, action: action, kind: "approve", client: client) }
            guard reply.ok, let given = reply.result else { return Say.replyError(reply) }
            result = given
        }
        // Each item recorded in the vault as its own action: each journaled, so `status` finds them all accounted for.
        for done in result["done"]?.array ?? [] {
            if let itemAction = done["action"]?.string { journal(context, action: itemAction, kind: done["kind"]?.string ?? "", client: client) }
            Say.out("done: " + summary(done))
        }
        guard let refused = result["refused"], refused != .null else {
            Say.out("all \(items.count) done")
            return 0
        }
        if refused["code"]?.string == NodeWire.Code.refused.rawValue, let itemAction = refused["action"]?.string {
            journal(context, action: itemAction, kind: refused["kind"]?.string ?? "", client: client)
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

    /// What needs your own decision: each card with its own answer line, and a push asked for.
    static func sayDecide(_ listed: NodeWire.Value) {
        let decide = listed["decide"]?.array ?? []
        let pushes = (listed["pushes"]?.array ?? []).compactMap(\.string)
        guard !decide.isEmpty || !pushes.isEmpty else { return }
        Say.out("Waiting on your own decision (not in the batch; each answered with its own line and code):")
        for card in decide { CardText.lines(card).forEach { Say.out("   " + $0) } }
        for root in pushes { Say.out("   a push asked for in \(inert(root)): vibeswitcher push \(inert(root)) | decline-push \(inert(root))") }
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

    static func journal(_ context: NodeContext, action: String, kind: String, client: NodeClient) {
        context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: kind, epoch: client.hello.epoch))
    }

    static func inert(_ text: String?) -> String { ConfigSeal.inert(text ?? "?", limit: 400) }
}
