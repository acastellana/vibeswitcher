import Foundation
import VibeCore

/// What an acting page's request passes before it is acted on as the user's (acting from the page, the web UI design's
/// step 2): the one confirmation seam. Today none (`NoPageVoice`: the user decided "for now trust the page
/// completely"); a passkey touch per request slots in here, with no change to the kinds or the page's requests. `done`
/// with nil when it passes, else why not; on any thread (`Requests` goes back to its queue).
public protocol PageVoice: Sendable {
    /// `done` with nil when it passes, else the refusal (its code and why).
    func confirm(_ request: NodeWire.Request, page: PageAct, done: @escaping @Sendable (NodeWire.Failure?) -> Void)
}

/// The page an acting request came from: its mark (`via`) and its credentials (the token a challenge was bound to, the
/// origin its assertion must name).
public struct PageAct: Sendable {
    public var via: String
    public var credentials: PageCredentials
    public init(via: String, credentials: PageCredentials) {
        self.via = via
        self.credentials = credentials
    }
}

/// No confirmation: the click is the user's (the level `trust`).
public struct NoPageVoice: PageVoice {
    public init() {}
    public func confirm(_ request: NodeWire.Request, page: PageAct, done: @escaping @Sendable (NodeWire.Failure?) -> Void) { done(nil) }
}

/// The level `confirm`'s check: the request's passkey assertion, for a challenge this node issued for exactly it
/// (`Requests.passkeyCheck`).
public final class PasskeyVoice: PageVoice, @unchecked Sendable {
    weak var requests: Requests?
    public init(requests: Requests? = nil) { self.requests = requests }
    public func confirm(_ request: NodeWire.Request, page: PageAct, done: @escaping @Sendable (NodeWire.Failure?) -> Void) {
        guard let requests else { return done(.init(.passkey, "this server checks no passkey")) }
        requests.queue.async { requests.passkeyCheck(request, page: page, done: done) }
    }
}

/// The loopback screen's side of a pairing's confirmation (`NodeLive` wires it): whether the connection that took a
/// code is open, and its confirmation (the secret given, the rights raised).
public struct PairingSeat: Sendable {
    public var holds: @Sendable (String) -> Bool
    public var confirm: @Sendable (String, String, LiveRights) -> Bool
    /// One message to every confirmed pairing's connection on the origin a passkey works on: how many.
    public var toPasskeyPages: @Sendable (Data) -> Int
    /// One message to the confirmed page at localhost whose pairing shows `phrase`: its token's digest, or nil for none.
    public var toPasskeyPage: @Sendable (String, Data) -> String?
    public init(holds: @escaping @Sendable (String) -> Bool, confirm: @escaping @Sendable (String, String, LiveRights) -> Bool,
                toPasskeyPages: @escaping @Sendable (Data) -> Int = { _ in 0 }, toPasskeyPage: @escaping @Sendable (String, Data) -> String? = { _, _ in nil }) {
        self.holds = holds
        self.confirm = confirm
        self.toPasskeyPages = toPasskeyPages
        self.toPasskeyPage = toPasskeyPage
    }
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
        case .lowersOnly(let why):
            // Only below what it is now (`default` is the lowest): raising it is the terminal's.
            let given = request.args?["value"]?.string ?? ""
            let asked = given == "default" ? 0 : setting.choices.firstIndex(of: given)
            let now = setting.choices.firstIndex(of: actingPages?.level ?? "off") ?? 0
            guard let asked, asked < now || asked == 0 else { return "\(setting.key) is raised from a terminal: \(why)" }
            return nil
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
        // An action id this server knows (answered, or being done) is only this page's very same request again: else
        // refused here at `trust` (another page's action, a terminal's, another kind or other arguments); at `confirm` it
        // needs its passkey's assertion like any act (`passkeyCheck`), and `kept` refuses other arguments after it.
        if actingPages?.level != "confirm", let action = request.action?.lowercased(), replies[action] != nil || doing[action] != nil,
           !isPageRepeat(request, token: credentials.token) {
            return refused(.init(re: request.id, error: .init(.voice, "that action id is another request's: send it with a new one")))
        }
        guard case .go(let shown) = pageChecks(request) else {
            if case .refused(let refusal) = pageChecks(request) { refused(refusal) }
            return
        }
        // The level chooses the check: `trust` none, `confirm` a passkey per request.
        let level = actingPages?.level
        let voice = level == "trust" ? pageVoice : confirmVoice
        // The request as the page sent it (a passkey's challenge was bound to exactly that).
        voice.confirm(request, page: PageAct(via: via, credentials: credentials)) { [weak self] notConfirmed in
            guard let self else { return }
            self.queue.async {
                let approved = request.action.flatMap { self.approvedLines.removeValue(forKey: $0.lowercased()) }
                if let notConfirmed { return refused(.init(re: request.id, error: notConfirmed)) }
                guard self.actingPages?.acts(token: credentials.token, secret: credentials.act, origin: credentials.origin) == true else {
                    return refused(.init(re: request.id, error: .init(.actsEnded, WebRequestScreen.notActing)))
                }
                // Passed at `trust` while the level rose to `confirm`: it needs its passkey now (the review's Low).
                if level == "trust", self.actingPages?.level != "trust" {
                    return refused(.init(re: request.id, error: .init(.assertionNeeded, "web_acts is confirm now: send it again with your passkey")))
                }
                switch self.pageChecks(request) {
                case .refused(let refusal): refused(refusal)
                case .go(let now):
                    // At `confirm`, recorded with what the passkey approved, and that line given back.
                    // The vault keeps a mark of 200 bytes at most: cut there, at a character's end (the line's quotes
                    // and words may be more than one byte each).
                    let mark = approved.map { Self.cut(via + "; passkey approved: " + $0, bytes: 200) } ?? via
                    self.notePageAction(request, token: credentials.token)
                    self.voiced(now, from: NodeLive.webPeer, via: mark) { answer in
                        var answer = answer
                        if answer.ok, let approved { answer.recorded = approved }
                        reply(answer)
                    }
                }
            }
        }
    }

    /// `text` cut to at most `bytes` of UTF-8, at a character's end.
    static func cut(_ text: String, bytes: Int) -> String {
        var kept = ""
        for character in text {
            guard kept.utf8.count + character.utf8.count <= bytes else { break }
            kept.append(character)
        }
        return kept
    }

    /// Whether `request` repeats an action this page made: the same page's token, kind and arguments (as it sent them).
    func isPageRepeat(_ request: NodeWire.Request, token: String) -> Bool {
        guard let action = request.action?.lowercased(), Self.recorded.contains(request.kind),
              let first = actionPages.last(where: { $0.action == action }) else { return false }
        return first.token == ActingPages.digest(token) && first.kind == request.kind && first.args == Self.argumentsDigest(request.args ?? [:])
    }

    /// An acting page's action, kept for its repeats (`isPageRepeat`).
    func notePageAction(_ request: NodeWire.Request, token: String) {
        guard let action = request.action?.lowercased(), !actionPages.contains(where: { $0.action == action }) else { return }
        actionPages.append((action, ActingPages.digest(token), request.kind, Self.argumentsDigest(request.args ?? [:])))
        if actionPages.count > Self.actionPagesKept { actionPages.removeFirst(actionPages.count - Self.actionPagesKept) }
    }

    /// An acting page's request as `voiced` takes it, or why not: a setting a page never sets; on a card or a batch,
    /// what the page drew against now (`seenStands`); `approve.list` marked as the page's (`pageListMark`). On `queue`.
    func pageChecks(_ request: NodeWire.Request) -> PageShown {
        if let why = pageSetRefusal(request) { return .refused(.init(re: request.id, error: .init(.voice, why))) }
        // A held config whose floor or guard rails aren't known to be the recorded ones: the terminal's (the vault is
        // asked again when it acts: `LeadEngine.configAccept(fromPage:)`).
        if request.kind == "config.accept", let id = request.args?["card"]?.string, let shown = engine?.cards.resolve(id)?.config {
            let changed = ConfigHoldStore.pageNotSame(shown)
            if !changed.isEmpty { return .refused(.init(re: request.id, error: .init(.voice, ConfigHoldStore.pageRefusalWords(changed)))) }
        }
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
            // Never an item a page may not act (hooks.install: the terminal's; a held config whose floor or rails aren't
            // known to be the recorded ones), whoever listed the batch.
            let terminal = held.items.filter { !pageMayApprove($0) }
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

    // MARK: A pairing confirmed in the terminal

    /// `web.pairing` `{code}` (the user's, from the terminal that ran `vibeswitcher web`): whether a page took the code,
    /// and if so its phrase, and whether the code was tried again after (`contested`). On `queue`.
    func webPairing(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let web, let code = request.args?["code"]?.string else { return reply(.init(re: request.id, error: .init(.badArgs, "web.pairing needs code"))) }
        let result: WireKinds.WebPairing.Result
        switch web.pairing(code: code) {
        case .waiting: result = .init(state: "waiting", phrase: nil, contested: nil)
        case .taken(let phrase, let contested):
            result = .init(state: pairings?.holds(code) == false ? "gone" : "taken", phrase: phrase, contested: contested)
        }
        reply(.init(re: request.id, typed: result))
    }

    /// `web.confirm` `{code, phrase}` (the user's voice, recorded first): the page that took `code`, showing `phrase`,
    /// confirmed: its connection given its pairing secret, watching, and acting while the level is above off. Refused
    /// when no page took the code, it was tried again by another (`contested`), the phrase isn't that page's, or its
    /// connection is gone. On `queue`.
    func webConfirm(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let refuse = { (code: NodeWire.Code, why: String) in reply(.init(re: request.id, error: .init(code, why))) }
        guard let web, let acting = actingPages, let seat = pairings else { return refuse(.refused, "this server pairs no page") }
        guard let code = request.args?["code"]?.string, let phrase = request.args?["phrase"]?.string else {
            return refuse(.badArgs, "web.confirm needs code and phrase")
        }
        guard case .taken(let shown, let contested) = web.pairing(code: code) else {
            return refuse(.gone, "no page took that address yet, or it waited too long: run `vibeswitcher web` again")
        }
        guard !contested else {
            _ = web.takePairing(code: code)
            return refuse(.voice, "this address was used by another page too: not confirmed. If that wasn't you, run `vibeswitcher web --revoke`")
        }
        // The words the user typed from their own page: a page that won the race shows other words (or the user's
        // browser shows none), and nothing is confirmed. A wrong try ends the pairing: no second guess.
        let typed = phrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard shown == typed else {
            _ = web.takePairing(code: code)
            return refuse(.voice, "those aren't the words the page that took the address shows: not confirmed, and that page only reads and drafts. "
                + "If your browser said it wasn't admitted, run `vibeswitcher web --revoke`")
        }
        guard seat.holds(code), let pairing = web.takePairing(code: code) else {
            return refuse(.gone, "the page that took the address closed before it was confirmed: run `vibeswitcher web` again")
        }
        let secret = acting.confirmed(token: pairing.token, tokenEnds: pairing.tokenEnds)
        var rights = WebAccess.rights.union(.watch)
        if acting.level != "off" { rights.insert(.act) }
        guard seat.confirm(code, secret, rights) else {
            acting.dropPairing(key: ActingPages.key(token: pairing.token, secret: secret))
            return refuse(.gone, "the page that took the address closed before it was confirmed: run `vibeswitcher web` again")
        }
        note("web.confirm: the page showing its phrase is paired: it watches\(rights.contains(.act) ? " and acts" : "")")
        reply(.init(re: request.id, typed: WireKinds.WebConfirm.Result(confirmed: true, rights: WebAccess.names(rights), level: acting.level)))
    }

    /// Whether an acting page may approve `item` in a batch: its kind is a page's, and a held config's floor and rails
    /// are known to be the recorded ones (`ConfigHoldStore.pageNotSame`). On `queue`.
    func pageMayApprove(_ item: ApproveItem) -> Bool {
        guard KindSpec.spec(item.kind)?.page == .acts else { return false }
        guard item.kind == "config.accept" else { return true }
        guard let id = item.args["card"]?.string ?? item.card?["id"]?.string, let shown = engine?.cards.resolve(id)?.config else { return false }
        return ConfigHoldStore.pageNotSame(shown).isEmpty
    }
}
