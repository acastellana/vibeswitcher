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
    static let approvalBusy = "another request is waiting for your approval at the Mac: answer or cancel that dialog first"

    func approvalVoice(_ request: NodeWire.Request, from facts: PeerFacts, token: Platform.PeerToken?,
                       reply: @escaping (NodeWire.Reply) -> Void) {
        approvalJudgment(request, from: facts, token: token) { [weak self] refused in
            if let refused { return reply(refused) }
            self?.voiced(request, from: facts, reply: reply)
        }
    }

    /// The Mac's voice on `request`: `done` on `queue` with nil when it is the user's (approved at the Mac for a state
    /// change), else the reply that refuses it. On `queue`.
    func approvalJudgment(_ request: NodeWire.Request, from facts: PeerFacts, token: Platform.PeerToken?,
                          done: @escaping (NodeWire.Reply?) -> Void) {
        let refuse = { [note] (why: String) in
            note("refused \(request.kind) from pid \(facts.pid): not the user's voice: \(why)")
            done(.init(re: request.id, error: .init(.voice, "not the user's voice: \(why)")))
        }
        guard let approval else { return refuse(Self.approvalUnset) }
        if Self.recorded.contains(request.kind), request.action.map({ UUID(uuidString: $0) != nil }) != true {
            return done(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs an action id (a UUID)")))
        }
        if Self.carded.contains(request.kind), let refusal = cardRefusal(request) { return done(refusal) }
        // A read asks nothing: judged here, at once, not behind a dialog.
        guard NodeWire.changesState(request.kind) else {
            if case .notUser(let why) = approval.judge(kind: request.kind, card: nil, peer: token, facts: facts, live: live, uid: rule.uid) {
                return refuse(why)
            }
            return done(nil)
        }
        if approvalsPending > 0 { return refuse(Self.approvalBusy) }
        let card = approvalCard(request)
        let (live, uid, queue) = (self.live, rule.uid, self.queue)
        approvalsPending += 1
        approvals.async { [weak self] in
            let voice = approval.judge(kind: request.kind, card: card, peer: token, facts: facts, live: live, uid: uid)
            queue.async {
                guard let self else { return }
                self.approvalsPending -= 1
                if case .notUser(let why) = voice { return refuse(why) }
                self.note("\(request.kind) from pid \(facts.pid): approved at the Mac")
                done(nil)
            }
        }
    }
}
