import Foundation
import VibeCore

/// What became of the user's answers and tells on their way to a lead (2026-11-24, the user on the page: they answered a
/// card, then had to type "actually no…" as a message), and taking one back before the lead has it.
///
/// - **Read marks.** Each answer and tell sent as the user's (`tellAsUser` with what it is about) is followed by its
///   action: the message it went as (held for the lead, or posted to its inbox), and when the lead took it, as
///   `retireTaken` finds the inbox's delivered record showing it and its line out of the inbox. The board's answered
///   questions carry `delivered` from it (`answerMarks`), the lead's value its tells (`told`). In memory: after a server
///   restart a mark is unknown (null), never a guess.
/// - **Taking one back** (`answer.replace`, `tell.retract`): only while the lead hasn't had it. Held for the lead (in the
///   engine's hold): replaced or dropped there. In its inbox: pulled out under the inbox's own lock, which the lead's
///   hook takes as it delivers (`SteerInbox.withdraw(id:tty:root:unless:)`), and only when no part of it was handed and
///   no wake-up prompt named it (`handedOver`, `wokenAt`): the lead taking it first leaves nothing to pull, which is
///   `delivered`, and nothing is replaced. A pulled `.user` message's seal is retired (`withdrawnUser`), so a copy put
///   back is nobody's. An approval's answer is never replaced: the vault may have recorded the approval.
public struct UserDelivery: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case answer(question: String, card: String)
        case tell
    }

    public var action: String
    public var root: String
    public var kind: Kind
    public var at: Date
    /// The message it went as: its id held for the lead or in its inbox.
    public var message: String?
    /// When the lead took it (its inbox's delivered record shows it).
    public var delivered: Date?
    /// Taken back: replaced by another action's answer, or retracted.
    public var withdrawn: String?
}

extension LeadEngine {
    /// How many of a root's tells the lead's value lists (the newest).
    static let toldKept = 20

    /// `action` (the user's, sent to `root`'s lead) followed as `kind`. On `queue`.
    func follow(_ action: String, root: String, kind: UserDelivery.Kind) {
        userDeliveries[action] = UserDelivery(action: action, root: root, kind: kind, at: Date())
        publishMarks(root: root)
    }

    /// The message `id` is what `action` went as (held or posted). On `queue`.
    func went(_ action: String, as id: String) {
        guard userDeliveries[action] != nil else { return }
        userDeliveries[action]?.message = id
    }

    /// The lead took the messages `ids` (`retireTaken`): each followed action they were is delivered now. On `queue`.
    func taken(_ ids: [String], at: Date = Date()) {
        let ids = Set(ids)
        var roots: Set<String> = []
        for (action, entry) in userDeliveries where entry.delivered == nil && entry.withdrawn == nil && entry.message.map(ids.contains) == true {
            userDeliveries[action]?.delivered = at
            roots.insert(entry.root)
        }
        roots.forEach { publishMarks(root: $0) }
    }

    /// The followed action of the answer to `question` in `root` that wasn't taken back, the newest.
    func answerDelivery(question: String, root: String) -> UserDelivery? {
        userDeliveries.values.filter { entry in
            guard entry.root == root, entry.withdrawn == nil, case .answer(let asked, _) = entry.kind else { return false }
            return asked == question
        }.max { $0.at < $1.at }
    }

    /// `root`'s marks as the board and the lead's value carry them: each answered question's `delivered` (by its id),
    /// and the tells, newest last.
    func marks(root: String) -> NodeWire.Value {
        let entries = userDeliveries.values.filter { $0.root == root && $0.withdrawn == nil }.sorted { ($0.at, $0.action) < ($1.at, $1.action) }
        // Each answer's mark, as `answer.replace` judges it: `replaceable` exactly when a replace would be taken (followed,
        // not taken back, not delivered, a question card's), so a page never offers what would be refused.
        var answers: [String: NodeWire.Value] = [:]
        for entry in entries {
            guard case .answer(let question, let card) = entry.kind else { continue }
            let replaceable = entry.delivered == nil && entry.message != nil && cards.cards[card]?.kind == .question
            answers[question] = .object(["delivered": entry.delivered.map(NodeWire.Value.date) ?? .null, "replaceable": .bool(replaceable),
                                         "card": .string(card)])
        }
        let told = entries.filter { $0.kind == .tell }.suffix(Self.toldKept).map { entry -> NodeWire.Value in
            .object(["action": .string(entry.action), "at": .date(entry.at), "delivered": entry.delivered.map(NodeWire.Value.date) ?? .null])
        }
        return .object(["answers": .object(answers), "told": .array(Array(told))])
    }

    func publishMarks(root: String) { deliveryMarks.send(root, marks(root: root)) }

    // MARK: Taking one back

    /// What `pull` found.
    enum Pulled: Equatable {
        /// Out of the hold or the inbox: the lead never had it.
        case pulled
        /// The lead has it (or part of it, or a prompt named it).
        case delivered
        /// Nothing is known of how it went (a server restart since, or never sent).
        case unknown
    }

    /// `entry`'s message taken back before the lead has it: out of the engine's hold, or out of the lead's inbox under its
    /// lock unless any part of it was handed or a wake-up prompt named it. `then` on `queue`. On `queue`.
    func pull(_ entry: UserDelivery, then: @escaping (Pulled) -> Void) {
        guard entry.delivered == nil else { return then(.delivered) }
        guard let id = entry.message else { return then(.unknown) }
        let project = NodeIds.project(root: entry.root)
        if leads.held[project]?.contains(where: { $0.id == id }) == true {
            leads.drop(project: project, id: id)
            return then(.pulled)
        }
        guard let posted = postedUser[id] else { return then(.unknown) }
        let inbox = root
        reads.async({ _ in
            SteerInbox.withdraw(id: id, tty: posted.tty, root: inbox, unless: { $0.handedOver != nil || $0.wokenAt != nil })
        }) { [weak self] withdrawn in
            guard let self else { return }
            guard withdrawn != nil else {
                // The lead took it first (or is taking part of it): delivered, nothing pulled.
                let already = self.userDeliveries[entry.action]?.delivered
                self.userDeliveries[entry.action]?.delivered = already ?? Date()
                self.publishMarks(root: entry.root)
                return then(.delivered)
            }
            // Its seal retired at the next look: a copy put back is nobody's.
            self.withdrawnUser.insert(id)
            then(.pulled)
        }
    }

    /// `answer.replace`: the user's answer on `card` taken back before its lead had it, and `text` sent in its place as
    /// the user's under `action` (the board and the card say the new answer; the vault records `action` as replacing
    /// the first). From any thread.
    public func replaceAnswer(card id: String, text: String, action: String?,
                              then: @escaping (Result<WireKinds.AnswerReplace.Result, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], card.kind == .question || card.kind == .approval, let question = card.question else {
                return then(.failure(.gone("no question card \(id)")))
            }
            guard card.kind == .question else {
                return then(.failure(.refused("an approval's answer isn't replaced (the vault may have recorded the approval): tell the lead instead")))
            }
            guard question.state == .answered, let first = answerDelivery(question: question.id, root: card.root) else {
                return then(.failure(.refused("no answer of yours to question \(question.short) is on its way: nothing to replace")))
            }
            pull(first) { [weak self] pulled in
                guard let self else { return }
                switch pulled {
                case .delivered: return then(.failure(.delivered("the lead has your answer already: nothing was replaced (tell it instead)")))
                case .unknown: return then(.failure(.refused("how your answer went isn't known here (the server restarted since): nothing was replaced (tell the lead instead)")))
                case .pulled: break
                }
                self.userDeliveries[first.action]?.withdrawn = "replaced by \(action ?? "an answer")"
                let (root, note, client) = (card.root, self.note, self.link.vaultV2)
                var answered = question
                answered.answer = text
                self.cards.change(id) { card in
                    card.question = answered
                    card.notice = "your answer was replaced before the lead had it"
                }
                self.reads.async({ _ -> Void in
                    do {
                        _ = try BoardStore(root: root).update { board in
                            if let index = board.questions.firstIndex(where: { $0.id == question.id }) { board.questions[index].answer = text }
                        }
                    } catch {
                        note("lead: the replaced answer to question \(question.short) wasn't written to the board of \(LeadMail.project(of: root)) (\(error))")
                    }
                    if let action {
                        _ = try? client.recordUserAction(action, kind: Self.replacesKind, subject: first.action, digest: LeadVaultV2.digest(text))
                    }
                }) { [weak self] _ in
                    guard let self else { return }
                    let message = Self.replacedText(question, text: text)
                    self.tellAsUser(message, root: root, action: action, about: .answer(question: question.id, card: id))
                    self.cardsChanged()
                    then(.success(WireKinds.AnswerReplace.Result(outcome: "replaced", card: self.cards.cards[id]?.value)))
                }
            }
        }
    }

    /// The vault's record kind that marks an action as replacing an earlier answer (its subject the earlier action).
    static let replacesKind = "answer.replaces"

    /// What the lead reads in place of the answer it never had.
    static func replacedText(_ question: LeadQuestion, text: String) -> String {
        "The user answered your question \(question.short) (“\(ConfigSeal.inert(question.text, limit: 300))”): \(text)\n"
            + "(This replaces an earlier answer of theirs that you weren't given; if the board showed it to you, this one stands.)"
    }

    /// `tell.retract`: the user's tell under `action` taken back before its lead had it. From any thread.
    public func retractTell(action: String, then: @escaping (Result<WireKinds.TellRetract.Result, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let entry = userDeliveries[action.lowercased()], entry.kind == .tell, entry.withdrawn == nil else {
                return then(.failure(.gone("no tell of yours under action \(action) is on its way")))
            }
            pull(entry) { [weak self] pulled in
                guard let self else { return }
                switch pulled {
                case .delivered: return then(.failure(.delivered("the lead has that message already: it wasn't taken back")))
                case .unknown: return then(.failure(.refused("how that message went isn't known here (the server restarted since): it wasn't taken back")))
                case .pulled:
                    self.userDeliveries[entry.action]?.withdrawn = "retracted"
                    self.publishMarks(root: entry.root)
                    then(.success(WireKinds.TellRetract.Result(retracted: true)))
                }
            }
        }
    }
}
