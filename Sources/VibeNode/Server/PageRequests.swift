import Foundation
import VibeCore

/// What an acting page's request passes before it is acted on as the user's (acting from the page, the web UI design's
/// step 2): the one confirmation seam. Today none (`NoPageVoice`: the user decided "for now trust the page
/// completely"); a passkey touch per request slots in here, with no change to the kinds or the page's requests. `done`
/// with nil when it passes, else why not; on any thread (`Requests` goes back to its queue).
public protocol PageVoice: Sendable {
    func confirm(_ request: NodeWire.Request, page: String, done: @escaping @Sendable (String?) -> Void)
}

/// No confirmation: the click is the user's.
public struct NoPageVoice: PageVoice {
    public init() {}
    public func confirm(_ request: NodeWire.Request, page: String, done: @escaping @Sendable (String?) -> Void) { done(nil) }
}

/// A request as an acting page's checks leave it: to go on (as `voiced` takes it), or refused.
enum PageShown {
    case go(NodeWire.Request)
    case refused(NodeWire.Reply)
}

extension Requests {
    /// Why an acting page may not make the `set` `request`, or nil: the setting `set` resolves (`setting(named:)`, the
    /// one resolution: its aliases, a plugin's), judged by its own `page` (every setting declares it), never by how the
    /// key is spelled. A key that resolves to nothing is `set`'s to refuse. On `queue`.
    func pageSetRefusal(_ request: NodeWire.Request) -> String? {
        guard request.kind == "set", let key = request.args?["key"]?.string, let setting = setting(named: key) else { return nil }
        switch setting.page {
        case .sets: return nil
        case .offOnly(let why): return ["off", "default"].contains(request.args?["value"]?.string ?? "") ? nil : "\(setting.key) is set from a terminal: \(why)"
        case .terminalOnly(let why): return "\(setting.key) is set from a terminal: \(why)"
        }
    }

    /// The argument a page's `approve.list` is marked with (`pageVoiced` puts it in, whatever the page sent): the list
    /// leaves out what a page may not approve (`ApproveRequest.listed`). A terminal sending it only narrows its own list.
    static let pageListMark = "fromPage"

    /// A user's request from an acting page (`Principal.Route.pageVoice`: the screen found its right, its kind's
    /// `KindSpec.page`, and its pairing still acting), with its page's credentials: the page's checks (`pageChecks`), then
    /// `pageVoice` (the one confirmation seam), then on the queue the page's checks again and whether it still acts (a
    /// confirmation may take seconds: what was approved is what is shown now, and an off or a revoke meanwhile counts),
    /// then `voiced` as a terminal's request, recorded as the user's with the page's mark. On `queue`.
    func pageVoiced(_ request: NodeWire.Request, credentials: PageCredentials, origin: String, reply: @escaping (NodeWire.Reply) -> Void) {
        let via = ActingPages.via(token: credentials.token, origin: origin)
        let refused = { [weak self] (refusal: NodeWire.Reply) in
            self?.note("refused \(request.kind) from \(via): \(refusal.error?.message ?? "")")
            reply(refusal)
        }
        guard case .go(let shown) = pageChecks(request) else {
            if case .refused(let refusal) = pageChecks(request) { refused(refusal) }
            return
        }
        pageVoice.confirm(shown, page: via) { [weak self] notConfirmed in
            guard let self else { return }
            self.queue.async {
                if let notConfirmed { return refused(.init(re: request.id, error: .init(.voice, "not confirmed: \(notConfirmed)"))) }
                guard self.actingPages?.acts(token: credentials.token, secret: credentials.act) == true else {
                    return refused(.init(re: request.id, error: .init(.voice, WebRequestScreen.notActing)))
                }
                switch self.pageChecks(request) {
                case .refused(let refusal): refused(refusal)
                case .go(let now): self.voiced(now, from: NodeLive.webPeer, via: via, reply: reply)
                }
            }
        }
    }

    /// An acting page's request as `voiced` takes it, or why not: a setting a page never sets; on a card or a batch,
    /// what the page drew against now (`seenStands`); `approve.list` marked as the page's (`pageListMark`). On `queue`.
    func pageChecks(_ request: NodeWire.Request) -> PageShown {
        if let why = pageSetRefusal(request) { return .refused(.init(re: request.id, error: .init(.voice, why))) }
        if request.kind == "approve.list" {
            var marked = request
            var args = request.args ?? [:]
            args[Self.pageListMark] = .bool(true)
            marked.args = args
            return .go(marked)
        }
        return seenStands(request)
    }

    /// `request` as `voiced` takes it from an acting page: on a card, `seen` the card's now (else refused `changed`), and
    /// the card's code put where a terminal types it; `approve`, one `seen` per item of the batch as listed, each card's
    /// still the card's now, and the batch's code put in. `seen` is taken out (`voiced`'s arguments are a terminal's). A
    /// retry of an action this server answered already goes on as it is (`voiced` answers it as before).
    func seenStands(_ request: NodeWire.Request) -> PageShown {
        let refuse = { (code: NodeWire.Code, why: String) in PageShown.refused(.init(re: request.id, error: .init(code, why))) }
        let carded = Self.carded.contains(request.kind), batch = request.kind == "approve"
        guard carded || batch else { return .go(request) }
        var args = request.args ?? [:]
        let seen = args.removeValue(forKey: "seen")
        guard args["code"] == nil else { return refuse(.badArgs, "a page sends seen, never a code") }
        // A retry of an action this server answered already: answered as before by `voiced` (nothing is done again).
        // (Or being done now: `voiced` says so.) Either way `kept` answers only the same arguments, and refuses others.
        let known = request.action.map { replies[$0.lowercased()] != nil || doing[$0.lowercased()] != nil } ?? false
        if carded {
            // No card named, or none such: `voiced`'s `cardRefusal` says so (before any code is looked at).
            guard let wanted = args["card"]?.string, let card = engine?.cards.resolve(wanted) else { return .go(request) }
            if !known {
                guard let seen = seen?.string else { return refuse(.badArgs, "\(request.kind) from a page needs seen: the card as the page drew it") }
                guard seen == card.seen else { return refuse(.changed, "card \(card.id) changed since the page drew it: look again") }
            }
            args["code"] = .string(card.code)
        } else {
            // No batch named, or none such: `approveRefusal` says so.
            guard let id = args["batch"]?.string, let held = approveBatches.first(where: { $0.id == id }) else {
                if known { args["code"] = args["batch"]?.string.map { .string(NodeIds.code(card: $0)) } }
                var asked = request
                asked.args = args
                return .go(asked)
            }
            // Never an item a page may not act (hooks.install: the terminal's), whoever listed the batch.
            let terminal = held.items.filter { KindSpec.spec($0.kind)?.page != .acts }
            guard terminal.isEmpty else {
                return refuse(.voice, "batch \(id) holds \(terminal.count) item\(terminal.count == 1 ? "" : "s") a page may not approve: run `vibeswitcher approve` in a terminal")
            }
            if !known {
                guard let seen = seen?.array?.compactMap(\.string) else { return refuse(.badArgs, "approve from a page needs seen: one per item, as listed") }
                guard seen == held.items.map(\.seen) else { return refuse(.changed, "batch \(id) isn't the list the page drew: look again") }
                // Each card the batch names is still what was listed.
                for item in held.items {
                    guard let card = item.card?["id"]?.string, let listed = item.card?["seen"]?.string else { continue }
                    guard engine?.cards.resolve(card)?.seen == listed else { return refuse(.changed, "card \(card) changed since the page drew it: look again") }
                }
            }
            args["code"] = .string(NodeIds.code(card: id))
        }
        var shown = request
        shown.args = args
        return .go(shown)
    }
}
