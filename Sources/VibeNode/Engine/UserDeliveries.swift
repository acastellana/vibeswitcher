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
/// - **An answer is on the board too** (the review of a5a5da80, S1): the lead may read it there before its inbox line,
///   by its tool server or by Read. So an answer is replaceable only while the lead has taken no step since it reached
///   the board: the board's lead and its hooks' state file are read just before the board is written (`LeadStep`), and
///   any hook event since (the file rewritten) makes it the lead's (`stepped`). Its hooks said nothing (no state file),
///   or the board names another lead: it can't be told, so it isn't replaceable. A tell never touches the board.
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
    /// An answer's: the board's lead and its hooks' state just before the answer reached the board (nil: it can't be told).
    public var lead: LeadStep?
    /// When the lead was seen to have taken a step since the answer reached its board (so it may have read it there).
    public var stepped: Date?

    /// Whether `answer.replace` would take it now, as far as the engine knows without looking again.
    public var replaceable: Bool {
        guard case .answer = kind else { return false }
        return delivered == nil && stepped == nil && withdrawn == nil && message != nil && lead != nil
    }
}

/// The lead the board names and its hooks' state file as last written: any hook event of its rewrites the file (a tool
/// call, a turn's step: reading the board is one), so a different read means the lead took a step in between.
public struct LeadStep: Equatable, Sendable {
    public var session: String?
    public var tty: String
    public var state: HookState
    public var modified: Date?

    /// Read now, on `reads`: nil when the board names no lead or its hooks wrote nothing for it.
    static func read(root: String, stateFile: (String) -> URL) -> LeadStep? {
        guard let named = LeadHandover.named(BoardStore(root: root).load()) else { return nil }
        let file = stateFile(named.tty)
        guard let state = HookState.load(from: file) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        return LeadStep(session: named.session, tty: named.tty, state: state, modified: modified)
    }
}

extension LeadEngine {
    /// How many of a root's tells the lead's value lists (the newest).
    static let toldKept = 20

    /// `action` (the user's, sent to `root`'s lead) followed as `kind`. On `queue`.
    /// `lead`: an answer's lead as `LeadStep` read it just before the answer reached the board.
    func follow(_ action: String, root: String, kind: UserDelivery.Kind, lead: LeadStep? = nil) {
        userDeliveries[action] = UserDelivery(action: action, root: root, kind: kind, at: Date(), lead: lead)
        publishMarks(root: root)
    }

    /// The message `id` is what `action` went as (held or posted). On `queue`.
    func went(_ action: String, as id: String) {
        guard let root = userDeliveries[action]?.root else { return }
        userDeliveries[action]?.message = id
        publishMarks(root: root)
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
        // not taken back, not delivered, no step of the lead's seen since, a question card's), so a page never offers what
        // would be refused (a step taken since the last look is found by the replace itself).
        var answers: [String: NodeWire.Value] = [:]
        for entry in entries {
            guard case .answer(let question, let card) = entry.kind else { continue }
            let replaceable = entry.replaceable && cards.cards[card]?.kind == .question
            answers[question] = .object(["delivered": entry.delivered.map(NodeWire.Value.date) ?? .null, "replaceable": .bool(replaceable),
                                         "card": .string(card)])
        }
        let told = entries.filter { $0.kind == .tell }.suffix(Self.toldKept).map { entry -> NodeWire.Value in
            .object(["action": .string(entry.action), "at": .date(entry.at), "delivered": entry.delivered.map(NodeWire.Value.date) ?? .null])
        }
        return .object(["answers": .object(answers), "told": .array(Array(told))])
    }

    func publishMarks(root: String) { deliveryMarks.send(root, marks(root: root)) }

    /// At each look: every answer still replaceable whose lead took a step since (`LeadStep` reads otherwise) is marked
    /// `stepped`, so its mark stops offering a replace. On `queue`; the files read on `reads`.
    func lookLeadSteps() {
        let open = userDeliveries.values.filter(\.replaceable)
        guard !open.isEmpty else { return }
        let stateFile = observer.stateFile
        reads.async({ _ -> [String] in
            var now: [String: LeadStep?] = [:]
            return open.compactMap { entry in
                let read = now[entry.root] ?? LeadStep.read(root: entry.root, stateFile: stateFile)
                now[entry.root] = read
                return read == entry.lead ? nil : entry.action
            }
        }) { [weak self] stepped in
            guard let self, !stepped.isEmpty else { return }
            self.stepped(stepped)
        }
    }

    /// The lead took a step since each of `actions`' answers reached its board. On `queue`.
    func stepped(_ actions: [String], at: Date = Date()) {
        var roots: Set<String> = []
        for action in actions where userDeliveries[action]?.stepped == nil {
            userDeliveries[action]?.stepped = at
            userDeliveries[action].map { roots.insert($0.root) }
        }
        roots.forEach { publishMarks(root: $0) }
    }

    // MARK: Taking one back

    /// What `pull` found.
    enum Pulled: Equatable {
        /// Out of the hold or the inbox: the lead never had it.
        case pulled
        /// The lead has it (or part of it, or a prompt named it).
        case delivered
        /// An answer the lead may have read on its board: it took a step since the answer got there, or whether it did
        /// can't be told (its hooks said nothing, another lead is named).
        case maybeRead(String)
        /// Nothing is known of how it went (a server restart since, or never sent).
        case unknown
    }

    /// `entry`'s message taken back before the lead has it: out of the engine's hold, or out of the lead's inbox under its
    /// lock unless any part of it was handed or a wake-up prompt named it; an answer only while its lead took no step since
    /// it reached the board (`LeadStep`). `then` on `queue`. On `queue`.
    func pull(_ entry: UserDelivery, then: @escaping (Pulled) -> Void) {
        guard entry.delivered == nil else { return then(.delivered) }
        guard let id = entry.message else { return then(.unknown) }
        guard case .answer = entry.kind else { return take(entry, id: id, then: then) }
        guard entry.stepped == nil else { return then(.maybeRead(Self.steppedWhy)) }
        guard let lead = entry.lead else {
            return then(.maybeRead("whether the lead read your answer on its board can't be told here (its hooks said nothing of it then)"))
        }
        let (root, stateFile) = (entry.root, observer.stateFile)
        reads.async({ _ in LeadStep.read(root: root, stateFile: stateFile) == lead }) { [weak self] quiet in
            guard let self else { return }
            guard quiet else {
                self.stepped([entry.action])
                return then(.maybeRead(Self.steppedWhy))
            }
            // Its hold or its inbox line looked at again now: what happened meanwhile counts.
            guard let entry = self.userDeliveries[entry.action], entry.delivered == nil, entry.withdrawn == nil else { return then(.delivered) }
            self.take(entry, id: id, then: then)
        }
    }

    static let steppedWhy = "the lead took a step since your answer reached its board, so it may have read it there"

    /// `pull`'s taking: out of the hold, or out of the inbox under its lock. On `queue`.
    private func take(_ entry: UserDelivery, id: String, then: @escaping (Pulled) -> Void) {
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
                case .maybeRead(let why): return then(.failure(.delivered("\(why): nothing was replaced (tell it instead)")))
                case .unknown: return then(.failure(.refused("how your answer went isn't known here (the server restarted since): nothing was replaced (tell the lead instead)")))
                case .pulled: break
                }
                self.userDeliveries[first.action]?.withdrawn = "replaced by \(action ?? "an answer")"
                let (root, note, client, stateFile, firstLead) = (card.root, self.note, self.link.vaultV2, self.observer.stateFile, first.lead)
                var answered = question
                answered.answer = text
                self.cards.change(id) { card in
                    card.question = answered
                    card.notice = "your answer was replaced before the lead had it"
                }
                self.reads.async({ _ -> (lead: LeadStep?, mayHaveRead: Bool) in
                    // The new answer's lead, read before it reaches the board (as an answer's is).
                    let before = LeadStep.read(root: root, stateFile: stateFile)
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
                    // A step of the lead's between `pull`'s look and the board's write may have read the first answer.
                    let after = LeadStep.read(root: root, stateFile: stateFile)
                    return (before, before != firstLead || after != firstLead)
                }) { [weak self] read in
                    guard let self else { return }
                    let message = Self.replacedText(question, text: text, mayHaveRead: read.mayHaveRead)
                    self.tellAsUser(message, root: root, action: action, about: .answer(question: question.id, card: id), lead: read.lead)
                    self.cardsChanged()
                    then(.success(WireKinds.AnswerReplace.Result(outcome: "replaced", card: self.cards.cards[id]?.value)))
                }
            }
        }
    }

    /// The vault's record kind that marks an action as replacing an earlier answer (its subject the earlier action).
    static let replacesKind = "answer.replaces"

    /// What the lead reads in place of the answer it never had. `mayHaveRead`: a step of the lead's came while it was
    /// replaced, so the board may have shown it the first one.
    static func replacedText(_ question: LeadQuestion, text: String, mayHaveRead: Bool = false) -> String {
        "The user answered your question \(question.short) (“\(ConfigSeal.inert(question.text, limit: 300))”): \(text)\n"
            + (mayHaveRead ? "(This replaces an earlier answer of theirs; if the board showed it to you, this one stands.)"
                           : "(This replaces an earlier answer of theirs that you weren't given.)")
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
                case .delivered, .maybeRead: return then(.failure(.delivered("the lead has that message already: it wasn't taken back")))
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
