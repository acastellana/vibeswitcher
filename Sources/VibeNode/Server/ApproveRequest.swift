import Foundation
import VibeCore

/// `vibeswitcher approve` (the user's go-ahead, 2026-11-22): one typed code for a batch the user sees whole, of the things
/// a plain accept settles. The voice rule is as it was: the same terminal check, one typed code per user action; one
/// action now covers a listed batch.
///
/// - **`approve.list`** (the user's, no typed word: it changes nothing, as `config.held` and `base.show`): every held
///   config card (the account's home and every project folder with a lead, in the vault's roster or in the accepted
///   snapshot: `config.held`'s card for each, those holding something), every base-move card (`base.show`'s, for each
///   project folder whose base moved), and the hooks when out of date (`HooksRequest.outOfDate`: a program that isn't
///   the build's, a config without them; Claude's, and Codex's when its config is there). The list is kept as a batch,
///   its code the batch id's (`NodeIds.code(card:)`, as a card's), for `approveLife`; each item is returned with its
///   card as `config held` and `base show` show it. What needs the user's own decision (questions, approvals, shell
///   requests, a push) is returned beside it, only to be listed with its own answer lines: never in a batch.
/// - **`approve`** (the user's voice, recorded: the batch's action), with the batch and its code: the batch's items in
///   their order (config, base, hooks), each as its own request through the user's-voice path (`voiced`), so each is
///   recorded in the vault as its own action (`itemAction`: derived from the batch's, so a retry of the batch meets its
///   items' records and does nothing twice), its card's code checked against the card (the batch's code stood for it),
///   and done as `config accept`, `base accept` and `hooks install` do it. It stops at the first refusal, saying what was
///   done, what refused and what's left. A batch is taken once, and only before it expires.
///
/// The batch is the list the user saw: its items can't be changed between the list and the code (the server holds it),
/// and a card that changed since (closed, superseded) refuses its item, which stops the batch.
extension Requests {
    /// One thing a batch settles: the request it is, what it names, and its card when it has one.
    struct ApproveItem: Sendable {
        var kind: String
        var args: [String: NodeWire.Value]
        var subject: String
        var card: NodeWire.Value?
        var reasons: [String] = []
    }

    struct ApproveBatch: Sendable {
        var id: String
        var items: [ApproveItem]
        var at: Date
    }

    /// How long a listed batch can be approved.
    static let approveLife: TimeInterval = 15 * 60
    /// The groups a batch can hold, in the order it settles them.
    static let approveGroups = ["config", "base", "hooks"]
    /// How many listed batches are kept.
    static let approveKept = 8

    /// The action an item of the batch `action` is recorded under: a UUID made from the batch's action and its place.
    static func itemAction(_ action: String, _ index: Int) -> String {
        let hex = Array(BuildInfo.sha256(of: Data("vibeswitcher approve|\(action.lowercased())|\(index)".utf8)).prefix(32))
        var digits = hex
        digits[12] = "5"
        digits[16] = Array("89ab")[Int(String(digits[16]), radix: 16)! % 4]
        let text = String(digits)
        let parts = [text.prefix(8), text.dropFirst(8).prefix(4), text.dropFirst(12).prefix(4), text.dropFirst(16).prefix(4), text.dropFirst(20)]
        return parts.joined(separator: "-")
    }

    /// `approve.list`, args `only` (some of `approveGroups`; all when absent).
    func approveList(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no cards"))) }
        let only = request.args?["only"]?.array?.compactMap(\.string) ?? Self.approveGroups
        guard !only.isEmpty, only.allSatisfy(Self.approveGroups.contains) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "only names some of config, base and hooks")))
        }
        let (vault, home, queue, nodeRoot) = (link.vault, home, queue, self.nodeRoot ?? "")
        let leadRoots = engine.leads.leads.values.map(\.root)
        let snapshot = engine.root
        let binaries = notes?.notes.binaries
        engine.reads.async({ _ -> (roots: [String], hooks: [String], agents: [Agent]) in
            let roster = (try? vault.roster(root: nil))?.map(\.root) ?? []
            let accepted = Array(AcceptedSnapshot.load(root: snapshot).projects.keys)
            var seen = Set<String>()
            let roots = ([home] + (leadRoots + roster + accepted).sorted()).filter { seen.insert($0).inserted }
            guard only.contains("hooks"), !nodeRoot.isEmpty else { return (roots, [], []) }
            var agents: [Agent] = [.claude]
            if FileManager.default.fileExists(atPath: HookInstaller.configURL(for: .codex, home: home).path) { agents.append(.codex) }
            let reasons = HooksRequest(nodeRoot: nodeRoot, home: home, binaries: binaries, vault: vault).outOfDate(agents: agents)
            return (roots, reasons, agents)
        }) { [weak self] found in
            guard let self else { return }
            var items: [ApproveItem] = []
            let configRoots = only.contains("config") ? found.roots : []
            let baseRoots = only.contains("base") ? found.roots.filter { $0 != home } : []
            func configs(_ left: [String], then: @escaping () -> Void) {
                guard let root = left.first else { return then() }
                engine.configHeld(root: root, diff: nil) { result in
                    queue.async {
                        if case .success(let value) = result, let card = value["card"], let id = card["id"]?.string,
                           (card["config"]?["items"]?.array?.isEmpty == false) {
                            items.append(ApproveItem(kind: "config.accept", args: ["card": .string(id)], subject: root, card: card))
                        }
                        configs(Array(left.dropFirst()), then: then)
                    }
                }
            }
            func bases(_ left: [String], then: @escaping () -> Void) {
                guard let root = left.first else { return then() }
                engine.baseShow(root: root, from: nil) { result in
                    queue.async {
                        if case .success(let card) = result, card.isOpen {
                            items.append(ApproveItem(kind: "base.accept", args: ["card": .string(card.id)], subject: root, card: card.value))
                        }
                        bases(Array(left.dropFirst()), then: then)
                    }
                }
            }
            configs(configRoots) {
                bases(baseRoots) {
                    if !found.hooks.isEmpty {
                        items.append(ApproveItem(kind: "hooks.install", args: ["agents": .array(found.agents.map { .string($0.rawValue) })],
                                                 subject: found.agents.map(\.rawValue).joined(separator: ","), reasons: found.hooks))
                    }
                    self.listed(request, items: items, engine: engine, reply: reply)
                }
            }
        }
    }

    /// The batch kept and its list replied, with what needs the user's own decision beside it. On `queue`.
    private func listed(_ request: NodeWire.Request, items: [ApproveItem], engine: LeadEngine, reply: (NodeWire.Reply) -> Void) {
        let decide = engine.cards.list().filter { $0.isOpen && [.question, .approval, .shell].contains($0.kind) }.map(\.value)
        let pushes = engine.leads.leads.values.compactMap { lead in lead.push.map { _ in NodeWire.Value.string(lead.root) } }
        var result: [String: NodeWire.Value] = ["items": .array(items.map { item in
            .object(["kind": .string(item.kind), "subject": .string(item.subject), "card": item.card ?? .null,
                     "reasons": .array(item.reasons.map(NodeWire.Value.string))])
        }), "decide": .array(decide), "pushes": .array(pushes)]
        if !items.isEmpty {
            let id = "local:approve:" + UUID().uuidString.lowercased()
            approveBatches.append(ApproveBatch(id: id, items: items, at: Date()))
            if approveBatches.count > Self.approveKept { approveBatches.removeFirst(approveBatches.count - Self.approveKept) }
            result["batch"] = .string(id)
            result["code"] = .string(NodeIds.code(card: id))
        }
        reply(.init(re: request.id, result: .object(result)))
    }

    /// `approve`, args `batch` and `code`, under the batch's own action (recorded already: `voiced`). On `queue`.
    func approve(_ request: NodeWire.Request, from facts: PeerFacts, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let id = request.args?["batch"]?.string, let action = request.action?.lowercased() else {
            return reply(.init(re: request.id, error: .init(.badArgs, "approve needs batch")))
        }
        guard let index = approveBatches.firstIndex(where: { $0.id == id }) else {
            return reply(.init(re: request.id, error: .init(.gone, "no batch \(ConfigSeal.inert(id, limit: 80)) (it was taken, it expired, or the server restarted): run `vibeswitcher approve` again")))
        }
        let batch = approveBatches[index]
        guard request.args?["code"]?.string?.uppercased() == NodeIds.code(card: id) else {
            note("refused approve of \(id): the code typed isn't the batch's")
            return reply(.init(re: request.id, error: .init(.voice, "code: the code typed isn't batch \(id)'s")))
        }
        approveBatches.remove(at: index)
        guard Date().timeIntervalSince(batch.at) < Self.approveLife else {
            return reply(.init(re: request.id, error: .init(.gone, "batch \(id) expired (\(Int(Self.approveLife / 60)) minutes): run `vibeswitcher approve` again")))
        }
        note("approve \(id): \(batch.items.count) item\(batch.items.count == 1 ? "" : "s") under action \(action)")
        var done: [NodeWire.Value] = []
        func next(_ at: Int) {
            guard at < batch.items.count else {
                return reply(.init(re: request.id, result: .object(["done": .array(done), "refused": .null, "left": .array([])])))
            }
            let item = batch.items[at]
            var args = item.args
            // The batch's code stood for the card's: the card's own, checked against the card as `config accept` checks it.
            if let card = item.args["card"]?.string, let held = engine?.cards.resolve(card) { args["code"] = .string(held.code) }
            let itemAction = Self.itemAction(action, at)
            let itemRequest = NodeWire.Request(id: "\(request.id).\(at)", kind: item.kind, args: args, action: itemAction)
            voiced(itemRequest, from: facts) { [weak self] answer in
                guard let self else { return }
                let shown: NodeWire.Value = .object(["kind": .string(item.kind), "subject": .string(item.subject), "action": .string(itemAction),
                                                     "result": answer.result ?? .null])
                guard answer.ok else {
                    let left = batch.items.dropFirst(at + 1).map { NodeWire.Value.object(["kind": .string($0.kind), "subject": .string($0.subject)]) }
                    self.note("approve \(id): stopped at \(item.kind) \(item.subject): \(answer.error?.message ?? "refused")")
                    return reply(.init(re: request.id, result: .object([
                        "done": .array(done),
                        "refused": .object(["kind": .string(item.kind), "subject": .string(item.subject), "action": .string(itemAction),
                                            "code": .string(answer.error?.code ?? "refused"), "message": .string(answer.error?.message ?? "")]),
                        "left": .array(Array(left)),
                    ])))
                }
                done.append(shown)
                next(at + 1)
            }
        }
        next(0)
    }
}
