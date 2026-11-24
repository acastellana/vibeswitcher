import Foundation
import VibeCore

/// `vibeswitcher approve` (the user's go-ahead, 2026-11-22): one typed code for a batch the user sees whole, of the things
/// a plain accept settles. The voice rule is as it was: the same terminal check, one typed code per user action; one
/// action now covers a listed batch.
///
/// - **`approve.list`** (the user's, no typed word: it changes nothing, as `config.held` and `base.show`): every held
///   config card (the account's home and every repository with a running lead or in the vault's roster, never the
///   accepted snapshot an agent could write; `config.held`'s card for each, those holding something) whose accept would
///   record no guard rail and no review floor (`ConfigHoldStore.wouldRecord`, of the card drawn; and again, the
///   guarantee, in the accept itself: `LeadEngine.configAccept(inBatch:)`), every base-move card from a head the vault vouches for to
///   another commit, and the hooks when out of date (`HooksRequest.outOfDate`: a program that isn't the build's, a
///   config without them; Claude's, and Codex's when its config is there) unless a config accept is in the batch. A card
///   with rails to record, a base moved from a head it can't vouch for, and hooks beside a config accept are the user's
///   own decision, each with its command (`own`); at most `approveMost` items, else refused. The list is kept as a batch,
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

        /// What an acting page names for it (`approve`'s `seen`): its card's `seen` as listed, or, with no card, the
        /// SHA-256 of what was listed of it.
        var seen: String {
            if let seen = card?["seen"]?.string { return seen }
            let listed = NodeWire.Value.object(["kind": .string(kind), "subject": .string(subject), "reasons": .array(reasons.map(NodeWire.Value.string))])
            return BuildInfo.sha256(of: NodeWire.line(listed))
        }
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

    /// The most items one code may cover: above it, the list is refused and each folder settled on its own, so nothing
    /// scrolls past before the code is asked.
    static let approveMost = 12

    /// What needs the user's own decision rather than a batch: a line to show and the command that settles it.
    struct ApproveOwn: Sendable {
        var text: String
        var command: String
    }

    /// `approve.list`, args `only` (some of `approveGroups`; all when absent).
    func approveList(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no cards"))) }
        let only: [String]
        switch request.typedArgs(WireKinds.ApproveList.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let typed): only = typed.only ?? Self.approveGroups
        }
        guard !only.isEmpty, only.allSatisfy(Self.approveGroups.contains) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "only names some of config, base and hooks")))
        }
        let (vault, home, queue, nodeRoot) = (link.vault, home, queue, self.nodeRoot ?? "")
        // The projects of the node: its running leads' and the vault's roster's (never a file an agent could write, as
        // the accepted snapshot is), each still a repository.
        let leadRoots = engine.leads.leads.values.filter { $0.session != nil }.map(\.root)
        let binaries = notes?.notes.binaries
        engine.reads.async({ _ -> (roots: [String], hooks: [String], agents: [Agent]) in
            let roster = (try? vault.roster(root: nil))?.map(\.root) ?? []
            var seen = Set<String>()
            let projects = (leadRoots + roster).sorted().filter { root in
                seen.insert(root).inserted && root != home && FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git"))
            }
            let roots = [home] + projects
            guard only.contains("hooks"), !nodeRoot.isEmpty else { return (roots, [], []) }
            var agents: [Agent] = [.claude]
            if FileManager.default.fileExists(atPath: HookInstaller.configURL(for: .codex, home: home).path) { agents.append(.codex) }
            let reasons = HooksRequest(nodeRoot: nodeRoot, home: home, binaries: binaries, vault: vault).outOfDate(agents: agents)
            return (roots, reasons, agents)
        }) { [weak self] found in
            guard let self else { return }
            var items: [ApproveItem] = []
            var own: [ApproveOwn] = []
            let configRoots = only.contains("config") ? found.roots : []
            let baseRoots = only.contains("base") ? found.roots.filter { $0 != home } : []
            func configs(_ left: [String], then: @escaping () -> Void) {
                guard let root = left.first else { return then() }
                engine.configHeld(root: root, diff: nil) { result in
                    queue.async {
                        // A card with something held: its own, or only what it leaves to the home's card, which the batch
                        // accepts first (the home is the first root), so this one's accept then ends its first look.
                        guard case .success(let held) = result, let card = held.card, let id = card["id"]?.string,
                              card["config"]?["items"]?.array?.isEmpty == false || card["config"]?["sharedHome"] != .null,
                              let shown = engine.cards.cards[id]?.config else {
                            return configs(Array(left.dropFirst()), then: then)
                        }
                        // Of the card actually drawn: what its accept would record besides its seals (as `accept` would).
                        engine.reads.async({ _ in try? ConfigHoldStore.wouldRecord(shown, root: root, vault: vault) }) { pending in
                            if pending?.isEmpty == true {
                                items.append(ApproveItem(kind: "config.accept", args: ["card": .string(id), "batch": .bool(true)], subject: root, card: card))
                            } else {
                                own.append(ApproveOwn(text: "held config in \(root), with guard rails or a review floor to record",
                                                      command: "vibeswitcher config held \(root)"))
                            }
                            configs(Array(left.dropFirst()), then: then)
                        }
                    }
                }
            }
            func bases(_ left: [String], then: @escaping () -> Void) {
                guard let root = left.first else { return then() }
                engine.baseShow(root: root, from: nil) { result in
                    queue.async {
                        // A base where the vault recorded it draws no card (`unmoved`): nothing to list.
                        if case .success(.card(let card)) = result, card.isOpen, let shown = card.base {
                            // Only a move the vault can vouch for: from a recorded (or given) head, to another commit.
                            if [.recorded, .given].contains(shown.fromIs), let from = shown.from, from != shown.to {
                                items.append(ApproveItem(kind: "base.accept", args: ["card": .string(card.id)], subject: root, card: card.value))
                            } else if shown.from != shown.to {
                                own.append(ApproveOwn(text: "the base of \(root) moved from a head the vault can't vouch for (\(shown.fromIs.rawValue))",
                                                      command: "vibeswitcher base show \(root)"))
                            }
                        }
                        bases(Array(left.dropFirst()), then: then)
                    }
                }
            }
            configs(configRoots) {
                bases(baseRoots) {
                    if !found.hooks.isEmpty {
                        let agents = found.agents.map(\.rawValue)
                        // Never beside a config accept: the hooks' write into the home's settings, sealed as written,
                        // stays a step of its own.
                        if items.contains(where: { $0.kind == "config.accept" }) {
                            own.append(ApproveOwn(text: "the hooks are out of date: " + found.hooks.joined(separator: "; "),
                                                  command: HooksRequest.installCommand))
                        } else {
                            items.append(ApproveItem(kind: "hooks.install", args: ["agents": .array(agents.map(NodeWire.Value.string))],
                                                     subject: agents.joined(separator: ","), reasons: found.hooks))
                        }
                    }
                    self.listed(request, items: items, own: own, engine: engine, reply: reply)
                }
            }
        }
    }

    /// The batch kept and its list replied, with what needs the user's own decision beside it. On `queue`.
    func listed(_ request: NodeWire.Request, items all: [ApproveItem], own: [ApproveOwn], engine: LeadEngine, reply: (NodeWire.Reply) -> Void) {
        // An acting page's list (`pageListMark`): what a page may not approve left out, and counted for the terminal.
        let fromPage = request.args?[Self.pageListMark]?.bool == true
        let items = fromPage ? all.filter(pageMayApprove) : all
        let terminalOnly = all.count - items.count
        guard items.count <= Self.approveMost else {
            return reply(.init(re: request.id, error: .init(.refused, "\(items.count) accepts wait, more than one code may cover (\(Self.approveMost)): "
                + "settle them per folder (vibeswitcher config held FOLDER, base show FOLDER, hooks install), or narrow with --only")))
        }
        let decide = engine.cards.list().filter { $0.isOpen && [.question, .approval, .plugin].contains($0.kind) }.map(\.value)
        let pushes = engine.leads.leads.values.compactMap { lead in lead.push.map { _ in NodeWire.Value.string(lead.root) } }
        var result = WireKinds.ApproveList.Result(
            items: items.map { .init(kind: $0.kind, subject: $0.subject, card: $0.card, reasons: $0.reasons, seen: $0.seen) }, decide: decide, pushes: pushes,
            own: own.map { .init(text: $0.text, command: $0.command) })
        if !items.isEmpty {
            let id = "local:approve:" + UUID().uuidString.lowercased()
            approveBatches.append(ApproveBatch(id: id, items: items, at: Platform.Clock.steadyDate()))
            if approveBatches.count > Self.approveKept { approveBatches.removeFirst(approveBatches.count - Self.approveKept) }
            result.batch = id
            result.code = NodeIds.code(card: id)
        }
        if terminalOnly > 0 { result.terminal = .init(count: terminalOnly, command: "vibeswitcher approve") }
        reply(.init(re: request.id, typed: result))
    }

    /// Why `approve` can't take its batch, or nil: no such batch, another code, or expired (gone with it). Asked before
    /// the request is recorded (`voiced`), as a card's code is, so a refused batch leaves no record; and again when it acts.
    func approveRefusal(_ request: NodeWire.Request) -> NodeWire.Reply? {
        guard let id = request.args?["batch"]?.string else { return .init(re: request.id, error: .init(.badArgs, "approve needs batch")) }
        guard let index = approveBatches.firstIndex(where: { $0.id == id }) else {
            return .init(re: request.id, error: .init(.gone, "no batch \(ConfigSeal.inert(id, limit: 80)) (it was taken, it expired, or the server restarted): run `vibeswitcher approve` again"))
        }
        guard request.args?["code"]?.string?.uppercased() == NodeIds.code(card: id) else {
            note("refused approve of \(id): the code typed isn't the batch's")
            return .init(re: request.id, error: .init(.voice, "code: the code typed isn't batch \(id)'s"))
        }
        guard Platform.Clock.steadyDate().timeIntervalSince(approveBatches[index].at) < Self.approveLife else {
            approveBatches.remove(at: index)
            return .init(re: request.id, error: .init(.gone, "batch \(id) expired (\(Int(Self.approveLife / 60)) minutes): run `vibeswitcher approve` again"))
        }
        return nil
    }

    /// `approve`, args `batch` and `code`, under the batch's own action (recorded already: `voiced`). On `queue`.
    func approve(_ request: NodeWire.Request, from facts: PeerFacts, reply: @escaping (NodeWire.Reply) -> Void) {
        if let refusal = approveRefusal(request) { return reply(refusal) }
        guard let id = request.args?["batch"]?.string, let action = request.action?.lowercased(),
              let index = approveBatches.firstIndex(where: { $0.id == id }) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "approve needs batch")))
        }
        let batch = approveBatches.remove(at: index)
        note("approve \(id): \(batch.items.count) item\(batch.items.count == 1 ? "" : "s") under action \(action)")
        var done: [WireKinds.Approve.Done] = []
        func next(_ at: Int) {
            guard at < batch.items.count else {
                return reply(.init(re: request.id, typed: WireKinds.Approve.Result(done: done, refused: nil, left: [])))
            }
            let item = batch.items[at]
            // Only a kind the table lets a batch hold (`KindSpec`'s `batch`): this server made the batch, so another is a bug.
            guard KindSpec.spec(item.kind)?.recorded?.batch == true else {
                return reply(.init(re: request.id, error: .init(.internal, "\(item.kind) can't be an item of a batch: nothing more was done")))
            }
            // An acting page's batch never holds an item a page may not act (its list left those out, `seenStands`
            // refused a batch with one): checked again here, where each item runs.
            if pageMarks[action] != nil, KindSpec.spec(item.kind)?.page != .acts {
                let left = batch.items.dropFirst(at + 1).map { WireKinds.Approve.Left(kind: $0.kind, subject: $0.subject) }
                return reply(.init(re: request.id, typed: WireKinds.Approve.Result(
                    done: done, refused: .init(kind: item.kind, subject: item.subject, action: Self.itemAction(action, at), code: "voice",
                                               message: "\(item.kind) is the terminal's: run `vibeswitcher approve` in a terminal"),
                    left: Array(left))))
            }
            var args = item.args
            // The batch's code stood for the card's: the card's own, checked against the card as `config accept` checks it.
            if let card = item.args["card"]?.string, let held = engine?.cards.resolve(card) { args["code"] = .string(held.code) }
            let itemAction = Self.itemAction(action, at)
            let itemRequest = NodeWire.Request(id: "\(request.id).\(at)", kind: item.kind, args: args, action: itemAction)
            // An acting page's batch: each item recorded with its mark too.
            voiced(itemRequest, from: facts, via: pageMarks[action]) { [weak self] answer in
                guard let self else { return }
                let shown = WireKinds.Approve.Done(kind: item.kind, subject: item.subject, action: itemAction, result: answer.result)
                guard answer.ok else {
                    let left = batch.items.dropFirst(at + 1).map { WireKinds.Approve.Left(kind: $0.kind, subject: $0.subject) }
                    self.note("approve \(id): stopped at \(item.kind) \(item.subject): \(answer.error?.message ?? "refused")")
                    return reply(.init(re: request.id, typed: WireKinds.Approve.Result(
                        done: done,
                        refused: .init(kind: item.kind, subject: item.subject, action: itemAction, code: answer.error?.code ?? "refused",
                                       message: answer.error?.message ?? ""),
                        left: Array(left))))
                }
                done.append(shown)
                next(at + 1)
            }
        }
        next(0)
    }
}
