import Foundation
import VibeCore

/// The Mac's rule on the server (`VoiceRule.Mode.approval`; `ApprovalVoice`): a user's-voice request's caller checked
/// (its uid, the installed command line's code by its audit token, the guard rails), then a state change put to the
/// person at the Mac, Touch ID or the login password, the dialog naming what the server built of the request
/// (`approvalCard`), never the command line's words. Only then does it go on as on Linux (`voiced`: the action id, the
/// card's code, the vault's record, the act).
///
/// - Cheap and silent first: an action id that isn't one, or a card refused (its code, its kind, gone), is answered
///   before any dialog; a request whose caller fails is refused by `ApprovalVoice` before it asks.
/// - Off the server's queue: the dialog waits for a person (up to `ApprovalVoice.System`'s timeout), on `approvals`, a
///   queue of its own; the live sessions and the card are read on `queue` first.
/// - One at a time: while one approval waits at the Mac, another state change is refused, saying so, rather than
///   stacking dialogs (a process that passes the caller checks could otherwise queue them faster than a person reads).
extension Requests {
    static let approvalUnset = "the Mac's rule has no authenticator on this server"
    /// While another request's dialog is open at the Mac: this one isn't asked. Never "answer it": the open one may be
    /// another process's, and its word tells.
    static let approvalBusy = "another request's dialog is open at the Mac right now, so this one wasn't asked: run it again once that "
        + "dialog is gone. That dialog starts with its own word: if your terminal didn't print it, it isn't yours, cancel it"
    /// How long after a declined, cancelled, timed-out or unavailable dialog no other is shown.
    static let approvalCooldown: TimeInterval = 10

    func approvalVoice(_ request: NodeWire.Request, from facts: PeerFacts, token: Platform.PeerToken?,
                       reply: @escaping (NodeWire.Reply) -> Void) {
        approvalJudgment(request, from: facts, token: token) { [weak self] refused in
            if let refused { return reply(refused) }
            self?.voiced(request, from: facts, reply: reply)
        }
    }

    /// The Mac's voice on `request`: `done` on `queue` with nil when it is the user's (approved at the Mac for a state
    /// change), else the reply to give (a refusal, or a replayed action's first answer). Silent checks first, in this
    /// order, none of them asking: the action id; a replayed action id (answered as it was, `replies`); a card's code;
    /// the caller (`ApprovalVoice.callerRefusal`: uid, the command line's code, the Hardened Runtime, the guard rails);
    /// a read then passes. A state change then: stopping and the host's welcome; the cooldown after a dialog that came
    /// to nothing; one dialog at a time; its text (`approvalCard`: refused when the decisive part can't fit). Only then
    /// is a dialog shown. On `queue`.
    func approvalJudgment(_ request: NodeWire.Request, from facts: PeerFacts, token: Platform.PeerToken?,
                          done: @escaping (NodeWire.Reply?) -> Void) {
        let refuse = { [note] (why: String) in
            note("refused \(request.kind) from pid \(facts.pid): not the user's voice: \(why)")
            done(.init(re: request.id, error: .init(.voice, "not the user's voice: \(why)")))
        }
        guard let approval else { return refuse(Self.approvalUnset) }
        let action = request.action?.lowercased()
        if Self.recorded.contains(request.kind), action.map({ UUID(uuidString: $0) != nil }) != true {
            return done(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs an action id (a UUID)")))
        }
        // An action this server answered already: its answer again, no dialog (`voiced` would answer it so after one).
        if let action, var again = replies[action] {
            again.re = request.id
            return done(again)
        }
        if Self.carded.contains(request.kind), let refusal = cardRefusal(request) { return done(refusal) }
        if let why = approval.callerRefusal(peer: token, facts: facts, live: live, uid: rule.uid) { return refuse(why) }
        guard NodeWire.changesState(request.kind) else { return done(nil) }
        // What `voiced` would answer after the dialog, answered before it: no dialog for a request that can't go on (and
        // a `not-yet` the command line asks again would ask the person twice).
        guard !stopping else { return done(.init(re: request.id, error: .init(.stopping, "the node is stopping"))) }
        guard approvalLinkWelcomed?() ?? (link.state == .connected) else {
            return done(.init(re: request.id, error: .init(.notYet, "the server's link to its host isn't welcomed yet: retry")))
        }
        if let until = approvalQuietUntil, approvalNow() < until {
            return refuse("a dialog came to nothing a moment ago (declined, cancelled, timed out or not shown), so none is shown for \(Int(Self.approvalCooldown)) s: run it again then")
        }
        if approvalsPending > 0 { return refuse(Self.approvalBusy) }
        let card: String
        switch approvalCard(request) {
        case .failure(let refusal):
            note("refused \(request.kind) from pid \(facts.pid): \(refusal.why)")
            return done(.init(re: request.id, error: .init(.refused, refusal.why)))
        case .success(let text): card = text
        }
        let (live, uid, queue) = (self.live, rule.uid, self.queue)
        approvalsPending += 1
        approvals.async { [weak self] in
            let voice = approval.judge(kind: request.kind, card: card, peer: token, facts: facts, live: live, uid: uid)
            queue.async {
                guard let self else { return }
                self.approvalsPending -= 1
                if case .notUser(let why) = voice {
                    self.approvalQuietUntil = self.approvalNow().addingTimeInterval(Self.approvalCooldown)
                    return refuse(why)
                }
                self.note("\(request.kind) from pid \(facts.pid): approved at the Mac")
                done(nil)
            }
        }
    }
}
