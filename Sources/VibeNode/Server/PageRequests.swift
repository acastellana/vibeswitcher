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
    /// The settings a page never sets, even acting: they widen what a page or a worker may do (`web_acts` on: a page
    /// would turn on its own acting; the floors and the policy: a worker's token would lower what holds its own merge).
    static func pageSetRefusal(_ request: NodeWire.Request) -> String? {
        guard request.kind == "set", let key = request.args?["key"]?.string else { return nil }
        if key == "web_acts" { return request.args?["value"]?.string == "off" ? nil : "web_acts is turned on from a terminal" }
        if key == "policy" || key.hasPrefix("floor_") { return "\(ConfigSeal.inert(key, limit: 80)) is set from a terminal" }
        return nil
    }

    /// A user's request from an acting page (`Principal.Route.pageVoice`: the screen found its right and its kind's
    /// `KindSpec.page`), `token` its page's: the settings a page never sets refused; on a card or a batch, what the page
    /// drew (`seen`) checked against the card or the batch as it is now, and refused (`changed`) when it changed, which
    /// stands for the code a terminal types (the user's decision: from an acting page the click is the answer); then
    /// `pageVoice`, then `voiced` as a terminal's request, recorded as the user's with the page's mark. On `queue`.
    func pageVoiced(_ request: NodeWire.Request, token: String, origin: String, reply: @escaping (NodeWire.Reply) -> Void) {
        let via = ActingPages.via(token: token, origin: origin)
        if let why = Self.pageSetRefusal(request) {
            note("refused \(request.kind) from \(via): \(why)")
            return reply(.init(re: request.id, error: .init(.voice, why)))
        }
        let shown: NodeWire.Request
        switch seenStands(request) {
        case .refused(let refusal):
            note("refused \(request.kind) from \(via): \(refusal.error?.message ?? "")")
            return reply(refusal)
        case .go(let request): shown = request
        }
        pageVoice.confirm(shown, page: via) { [weak self] refused in
            guard let self else { return }
            self.queue.async {
                if let refused {
                    self.note("refused \(shown.kind) from \(via): the page's confirmation: \(refused)")
                    return reply(.init(re: shown.id, error: .init(.voice, "not confirmed: \(refused)")))
                }
                self.voiced(shown, from: NodeLive.webPeer, via: via, reply: reply)
            }
        }
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
