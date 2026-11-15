import Foundation
import VibeCore

/// The vault's record of the user's actions as the check a held `.user` message passes after a restart (EN-D9, E5's
/// `UserActions`): it holds the action with the message's digest. Nil when the host can't be asked.
public struct VaultUserActions: UserActions {
    let client: LeadVaultV2Client
    public init(client: LeadVaultV2Client) { self.client = client }
    public func holds(action: String, digest: String) -> Bool? { try? client.holds(action: action, digest: digest) }
}

/// Questions, answers, cards and holds (the engine plan's E6; the app's `LeadController.answer`, `hold`, `runTimers` and
/// `tell(timers:)`, 1118-1201, with `ConfigHolds` and `BaseMoves` as stores): every card is made by the engine (a
/// question from the lead's tool server's post, an approval's facts from git and the vault, held config from the vault,
/// a base move from git and the vault), and the user's answer is bound to the card's id and the version it showed. The
/// server records each user's-voice request in the vault before it gets here (`Requests.handle`); an answer's `.user`
/// message is recorded there too (its digest under the same action) before it is posted to the lead. The board, git
/// and the vault are read on `reads` or `work`, never the engine's queue.
extension LeadEngine {
    public enum CardFailure: Error, Equatable {
        /// The card or what it is about is no longer there.
        case gone(String)
        case refused(String)
        case badArgs(String)
    }

    /// What `answer` says of each outcome that isn't simply taken (the app's `answerNotices`).
    static func notice(_ outcome: LeadAnswerOutcome) -> String? {
        switch outcome {
        case .answered: return nil
        case .withdrawn(let withdrawn):
            return "Withdrawn before your answer: \(withdrawn.withdrawReason ?? "no reason given"). The lead got your answer as a note."
        case .afterAutoDecision(let decided):
            return "The timer had run out: the lead went ahead with ‘\(decided.proposal ?? "")’. Your answer reached it as a note."
        case .alreadyAnswered(let answered):
            return "Already answered: \(answered.answer ?? answered.proposal ?? ""). Your new answer wasn't sent."
        case .missing:
            return "That question is no longer on the board. Your answer wasn't sent."
        case .notOpen:
            return "That question isn't open any more. Your answer wasn't sent."
        }
    }

    /// A word for each outcome, as `answer`'s reply gives it.
    static func word(_ outcome: LeadAnswerOutcome) -> String {
        switch outcome {
        case .answered: return "answered"
        case .withdrawn: return "withdrawn"
        case .afterAutoDecision: return "afterAutoDecision"
        case .alreadyAnswered: return "alreadyAnswered"
        case .notOpen: return "notOpen"
        case .missing: return "missing"
        }
    }

    /// What closed a question's card, when it closed.
    static func closed(_ question: LeadQuestion) -> String? {
        switch question.state {
        case .open: return nil
        case .answered: return "answered: \(question.answer ?? "")"
        case .withdrawn: return "withdrawn: \(question.withdrawReason ?? "no reason given")"
        case .autoDecided: return "decided by its timer: \(question.proposal ?? "")"
        }
    }

    /// The commit an option of `question` approves ("Approve <commit>"), when one does: its card is an approval.
    static func approvalCommit(_ question: LeadQuestion) -> String? {
        question.options.lazy.compactMap { LeadVault.approvedCommit(in: $0) }.first
    }

    /// The roots with a question or approval open: their leads ask (`Session.leadAsks`).
    func cardsChanged() {
        sessions?.leadsAsking = cards.asking
    }

    // MARK: The lead's questions

    /// The lead's tool server posted `question` (the server checked its seal, its session and its runner): a new card
    /// for a post, the card brought up to date for a revision or a withdrawal. Nil for a revision or withdrawal of a
    /// question never posted (one written to the board alone is never shown). On `queue`.
    @discardableResult
    func questionPosted(_ op: NodeQuestionPost.Op, question: LeadQuestion, root: String) -> CardStore.Card? {
        let root = (root as NSString).standardizingPath
        leads.lead(root: root)
        let existing = cards.card(question: question.id, root: root)
        guard existing != nil || op == .post else { return nil }
        var card = existing ?? CardStore.Card(root: root, kind: .question)
        card.question = question
        card.closed = Self.closed(question)
        // The commit the options approve now: a revision that names another commit (or adds or drops "Approve") makes
        // the card show that one's facts, built anew, never the earlier commit's beside the new wording.
        let commit = Self.approvalCommit(question)
        let rebuild = commit != nil && commit != card.approval?.commit
        card.kind = commit == nil ? .question : .approval
        if commit == nil { card.approval = nil } else if rebuild, let commit { card.approval = CardStore.ApprovalFacts(commit: commit) }
        cards.put(card)
        cardsChanged()
        if rebuild, let commit { buildApproval(card: card.id, commit: commit, root: root) }
        return card
    }

    /// An approval card's facts, from git and the vault (S3): the tasks whose branch points at `commit`, the files and
    /// diffstat of `<base>...<commit>`, its subject, each task's verdict, and the sensitive paths it touches (read from
    /// workflow.md only while `sensitive_paths`' hash is the one the vault records). Kept only while the card still
    /// approves `commit` (a revision meanwhile builds its own).
    func buildApproval(card id: String, commit: String, root: String) {
        let vault = cardVault
        work.async { [weak self] in
            let facts = Self.approvalFacts(commit: commit, root: root, vault: vault)
            guard let self else { return }
            self.queue.async {
                self.cards.change(id) { card in
                    if card.approval?.commit == commit { card.approval = facts }
                }
            }
        }
    }

    /// Why `text` can't answer `card`: it approves a commit ("Approve <commit>") the card doesn't show the facts of (an
    /// approval card of another commit, or a question card), so the user would approve what they weren't shown.
    static func approvalRefusal(_ text: String, card: CardStore.Card) -> String? {
        guard let approved = LeadVault.approvedCommit(in: text), approved != card.approval?.commit.lowercased() else { return nil }
        if let shown = card.approval?.commit {
            return "This card shows the facts of commit \(shown), not \(approved): nothing was answered. Approve the commit the card shows, "
                + "or list the questions again (the lead may have revised it)."
        }
        return "This card shows no commit's facts, so it can't approve \(approved): nothing was answered."
    }

    /// The facts of an approval of `commit` in `root`, as the card shows them. Reads git and the vault.
    public static func approvalFacts(commit: String, root: String, vault: LeadVault) -> CardStore.ApprovalFacts {
        var facts = CardStore.ApprovalFacts(commit: commit)
        let refs = Git.run(["for-each-ref", "--points-at", commit, "--format=%(refname:short)", "refs/heads/agent/"], in: root)
        if refs.ok {
            facts.tasks = refs.output.split(whereSeparator: \.isNewline).map { String($0.dropFirst("agent/".count)) }.filter { !$0.isEmpty }
        } else {
            facts.problems.append("which task's branch is at \(commit.prefix(8)) couldn't be read")
        }
        let base = BaseMoveStore.base(root: root)
        facts.base = base
        let subject = Git.run(["log", "-1", "--format=%s", commit], in: root)
        if subject.ok { facts.subject = subject.output } else { facts.problems.append("\(commit.prefix(8)) isn't a commit of the repository") }
        let files = Git.run(["diff", "--name-only", "\(base)...\(commit)"], in: root)
        if files.ok { facts.files = files.output.split(whereSeparator: \.isNewline).map(String.init) }
        let stat = Git.run(["diff", "--shortstat", "\(base)...\(commit)"], in: root)
        if stat.ok { facts.diffstat = stat.output.trimmingCharacters(in: .whitespaces) }
        for task in facts.tasks {
            if let verdict = vault.verdict(root: root, task: task) {
                facts.verdicts[task] = "\(verdict.completion.rawValue), \(verdict.integrity.rawValue) at \(verdict.commit.prefix(8))"
                    + (verdict.commit.lowercased() == commit ? "" : " (not this commit)")
            }
        }
        let workflow = LeadWorkflow.load(from: ConfigHoldStore.workflowPath(root: root))
        let recorded = (try? vault.guardedRecord(root: root))??["sensitive_paths"]
        if let recorded, recorded == LeadVault.hash(LeadVault.guardedValue("sensitive_paths", in: workflow)) {
            facts.sensitive = facts.files.filter { path in workflow.sensitiveGlobs.contains { LeadWorkflow.matches(path, glob: $0) } }
        } else {
            facts.problems.append("workflow.md's sensitive_paths isn't what the vault records, so the sensitive files aren't named")
        }
        return facts
    }

    // MARK: answer, hold, timers

    /// The user's answer to the card `id` (`LeadController.answer`): bound to the card and the version it showed; on the
    /// board for the lead's record (`LeadBoard.answer`), an approval recorded in the vault (`recordApproval`), and the
    /// lead told as the user's, its message's digest recorded under `action` first. `then` hears on `queue` the outcome
    /// and its notice. From any thread.
    /// `version`: the wording the user was shown (the card's now when nil): a revision after it is said to the lead.
    public func answer(card id: String, text: String, version: Int? = nil, action: String?,
                       then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], card.kind == .question || card.kind == .approval, let question = card.question else {
                return then(.failure(.gone("no question card \(id)")))
            }
            if let why = Self.approvalRefusal(text, card: card) { return then(.failure(.refused(why))) }
            let (root, vault, seen) = (card.root, cardVault, min(version ?? question.version, question.version))
            reads.async({ _ -> (LeadAnswerOutcome, String?) in
                let outcome = (try? BoardStore(root: root).update { board in board.answer(question.id, with: text, saw: seen) }) ?? .missing
                guard case .answered(let answered, _) = outcome else { return (outcome, nil) }
                do {
                    guard let tasks = try vault.recordApproval(text, of: answered, root: root) else { return (outcome, nil) }
                    return (outcome, tasks.isEmpty ? "No task's branch is at that commit now, so the approval wasn't recorded: merge won't take it." : nil)
                } catch {
                    return (outcome, "Your approval wasn't recorded, so merge won't take it: \(error)")
                }
            }) { [weak self] outcome, approval in
                guard let self else { return }
                let notice = approval ?? Self.notice(outcome)
                self.cards.change(id) { card in
                    switch outcome {
                    case .answered(let q, _), .withdrawn(let q), .afterAutoDecision(let q), .alreadyAnswered(let q), .notOpen(let q):
                        card.question = q
                        card.closed = Self.closed(q) ?? card.closed
                    case .missing:
                        card.closed = "gone from the board"
                    }
                    card.notice = notice
                }
                self.cardsChanged()
                if let message = outcome.message(given: text) { self.tellAsUser(message, root: root, action: action) }
                then(.success(.object(["outcome": .string(Self.word(outcome)), "notice": notice.map(NodeWire.Value.string) ?? .null,
                                       "card": self.cards.cards[id]?.value ?? .null])))
                // The app refreshes after each answer (`LeadController.refresh`): the board as answered, its timers.
                self.refresh()
            }
        }
    }

    /// The user holds the card `id`'s question with a timer (`LeadController.hold`): the timer stops, it waits for an
    /// answer like any other, and the lead is told not to go ahead, as the user's. From any thread.
    public func hold(card id: String, action: String?, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], let question = card.question else { return then(.failure(.gone("no question card \(id)"))) }
            let root = card.root
            reads.async({ _ in Result { try BoardStore(root: root).update { board in try board.hold(question.id) } } }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let held):
                    self.cards.change(id) {
                        $0.question = held
                        $0.notice = nil
                    }
                    self.tellAsUser("The user is holding your question \(held.short) “\(held.text)”: its timer is off, so don't go ahead with "
                                    + "‘\(held.proposal ?? "")’; wait for their answer.", root: root, action: action)
                    then(.success(.object(["held": .bool(true), "card": self.cards.cards[id]?.value ?? .null])))
                    self.refresh()
                case .failure(let error):
                    self.cards.change(id) { $0.notice = "\(error)" }
                    then(.failure(.refused("\(error)")))
                }
            }
        }
    }

    /// Runs out the timers of the leads' questions (`BoardStore.runTimers`, on `reads`): the lead is told to go ahead
    /// with each proposal no one answered, once, and the card says it was decided. From any thread (E7's refresh runs
    /// the same read in its own, `fireTimers`, and tells them with `tell(timers:)`).
    public func runTimers(now: Double = Date().timeIntervalSince1970) {
        queue.async { [self] in
            let roots = timerRoots
            reads.async({ files in Self.fireTimers(roots, files: &files, now: now) }) { [weak self] fired in self?.tell(timers: fired) }
        }
    }

    /// The roots whose boards' timers run: every lead's, and every root a question card was posted for. On `queue`.
    var timerRoots: Set<String> {
        Set(leads.leads.values.map(\.root)).union(cards.list().filter { $0.question != nil }.map(\.root))
    }

    /// The questions whose timer ran out on `roots`' boards, each decided on its board now, with what the lead is told
    /// (`BoardStore.runTimers`). On `reads`.
    static func fireTimers(_ roots: Set<String>, files: inout BoardFiles, now: Double) -> [String: [(question: LeadQuestion, message: String)]] {
        var fired: [String: [(question: LeadQuestion, message: String)]] = [:]
        for root in roots where files.board(root).hasExpired(now: now) {
            if let expired = try? BoardStore(root: root).runTimers(now: now), !expired.isEmpty { fired[root] = expired }
        }
        return fired
    }

    /// The lead told of each question its timer decided (`tell(timers:)`, `LeadController` 1187-1201), once, and its
    /// card closed saying so. On `queue`.
    func tell(timers fired: [String: [(question: LeadQuestion, message: String)]]) {
        for (root, expired) in fired {
            for (question, message) in expired {
                if let card = cards.card(question: question.id, root: root) {
                    cards.change(card.id) {
                        $0.question = question
                        $0.closed = Self.closed(question)
                    }
                }
                deliver(built: { message }, from: .system("timer"), root: root, action: nil)
            }
        }
        if !fired.isEmpty { cardsChanged() }
    }

    /// `text` to `root`'s lead as the user's: its digest recorded in the vault under `action` (kind `message`), so after
    /// a restart a held copy is vouched for (EN-D9), then delivered (or held). Its place among what's sent to that lead
    /// is taken now: what's sent while it's recorded waits behind it (`recordingUser`). On `queue`.
    func tellAsUser(_ text: String, root: String, action: String?) {
        guard let action else { return deliver(built: { text }, from: .user, root: root, action: nil) }
        let (client, project, note, order) = (link.vaultV2, NodeIds.project(root: root), self.note, leads.next())
        recordingUser[root, default: 0] += 1
        work.async { [weak self] in
            do { try client.recordUserAction(action, kind: "message", subject: project, digest: LeadVaultV2.digest(text)) } catch {
                note("lead: the user's message for \(LeadMail.project(of: root)) wasn't recorded in the vault (\(error)): after a restart it isn't vouched for")
            }
            guard let self else { return }
            self.queue.async {
                let left = (self.recordingUser[root] ?? 1) - 1
                self.recordingUser[root] = left > 0 ? left : nil
                // Held behind what's held or recorded still, and what waited behind it goes after it.
                self.deliver(built: { text }, from: .user, root: root, action: action, order: order)
            }
        }
    }

    /// A `.user` message posted to a lead's inbox: retired once its delivered record shows it. On `queue`.
    func postedAsUser(_ id: String, tty: String) {
        postedUser[id] = tty
    }

    /// Retires in the vault each `.user` message the lead took (its inbox's delivered record shows it): its seal verifies
    /// false from then on, so a copy put back in the inbox arrives as unverified (T41). Each one still waiting in the
    /// inbox has its seal renewed (`renewUserSeals`: its life counts from now), so an answer that waits while the lead's
    /// tool call runs long (a merge's tests) is still the user's when the lead takes it; the vault renews none a check
    /// has passed, and the server none it no longer sees waiting. On `queue`, at each `look`.
    func retireTaken() {
        guard !postedUser.isEmpty, !retiring else { return }
        retiring = true
        let (posted, inbox, client, note) = (postedUser, root, link.vaultV2, self.note)
        reads.async({ _ -> (taken: [String], waiting: [String]) in
            var taken: [String] = [], waiting: [String] = []
            for (tty, entries) in Dictionary(grouping: posted, by: \.value) {
                let delivered = SteerInbox.delivered(tty: tty, root: inbox)
                let pending = Set(SteerInbox.pending(tty: tty, root: inbox).map(\.id))
                for id in entries.map(\.key).sorted() {
                    if delivered.contains(id) { taken.append(id) } else if pending.contains(id) { waiting.append(id) }
                }
            }
            return (taken, waiting)
        }) { [weak self] found in
            guard let self else { return }
            let taken = found.taken
            guard !taken.isEmpty || !found.waiting.isEmpty else {
                self.retiring = false
                return
            }
            self.work.async {
                if (try? client.renewUserSeals(found.waiting)) == nil {
                    note("lead: \(found.waiting.count) waiting message(s) of the user's not renewed in the vault: tried again at the next look")
                }
                let retired = (try? client.retireUserSeals(taken)) != nil
                if !retired { note("lead: \(taken.count) delivered message(s) of the user's not retired in the vault yet: tried again") }
                self.queue.async {
                    if retired { taken.forEach { self.postedUser[$0] = nil } }
                    self.retiring = false
                }
            }
        }
    }

    // MARK: Held config

    /// `config held FOLDER [--diff NAME]`: what the vault holds for the project, as a card bound to exactly the hashes
    /// it shows (any earlier open one of the project closed), with the floor and rails workflow.md proposes; `diff`,
    /// that held thing's difference too. From any thread.
    public func configHeld(root: String, diff: String?, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        let (vault, home, node) = (cardVault, self.home, self.root)
        work.async { [weak self] in
            // The last accept the snapshot knows (E8): each held thing said the same, changed or new since.
            let held = ConfigHoldStore.held(root: root, vault: vault, home: home, snapshot: AcceptedSnapshot.load(root: node).projects[root])
            let difference: [String]? = { if case .success(let shown) = held, let diff { return ConfigHoldStore.difference(shown, name: diff, home: home) } else { return nil } }()
            guard let self else { return }
            self.queue.async {
                switch held {
                case .failure(let error): then(.failure(.refused("the vault can't be asked what it holds for \(root): \(error)")))
                case .success(let shown):
                    let project = NodeIds.project(root: root)
                    for old in self.cards.list(project: project) where old.kind == .configHeld { self.cards.change(old.id) { $0.closed = "superseded by a newer card" } }
                    var card = CardStore.Card(root: root, kind: .configHeld)
                    card.config = shown
                    self.cards.put(card)
                    var result: [String: NodeWire.Value] = ["card": card.value]
                    if let diff { result["difference"] = difference.map { .array($0.map(NodeWire.Value.string)) } ?? .string("nothing held is named \(diff)") }
                    then(.success(.object(result)))
                }
            }
        }
    }

    /// What the vault holds for each project with a lead running, looked at (the app's refresh calling
    /// `ConfigHolds.look`, `LeadController` 671-677): the record read only (`ConfigHoldStore.held(look: false)`, never a
    /// look that could seal), and something held that no open card shows as it's held now becomes a card (an earlier
    /// open one closed), so `status` counts it and `questions` lists it. On `queue`, at each `look` (E7's refresh).
    func lookAtConfig() {
        let roots = Set(leads.leads.values.filter { $0.session != nil }.map(\.root))
        guard !roots.isEmpty, !lookingAtConfig else { return }
        lookingAtConfig = true
        let (vault, home, node) = (cardVault, self.home, self.root)
        work.async { [weak self] in
            let snapshot = AcceptedSnapshot.load(root: node)
            let found = roots.sorted().reduce(into: [String: ConfigHoldStore.Shown]()) { found, root in
                if case .success(let shown) = ConfigHoldStore.held(root: root, vault: vault, home: home, look: false,
                                                                   snapshot: snapshot.projects[root]) { found[root] = shown }
            }
            guard let self else { return }
            self.queue.async {
                self.lookingAtConfig = false
                for (root, shown) in found.sorted(by: { $0.key < $1.key }) { self.configLooked(shown, root: root) }
            }
        }
    }

    /// A look found `shown` held for `root`: a card when something is held that no open held-config card shows with
    /// these hashes. On `queue`.
    func configLooked(_ shown: ConfigHoldStore.Shown, root: String) {
        let project = NodeIds.project(root: root)
        let open = cards.list(project: project).filter { $0.kind == .configHeld }
        guard !shown.items.isEmpty, !open.contains(where: { $0.config?.hashes == shown.hashes }) else { return }
        for old in open { cards.change(old.id) { $0.closed = "superseded by a newer card" } }
        var card = CardStore.Card(root: root, kind: .configHeld)
        card.config = shown
        cards.put(card)
        note("lead: the vault holds \(shown.items.map { ConfigSeal.inert($0.name, limit: 80) }.joined(separator: ", ")) for "
             + "\(LeadMail.project(of: root)): card \(card.id) (config held, config accept)")
    }

    /// `config accept CARD`: the seal of what the card showed, then the rails and the floor it proposed (EN-D7), and the
    /// lead told. When the config moved past the card, nothing is sealed and the card says so. From any thread.
    public func configAccept(card id: String, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], let shown = card.config else { return then(.failure(.gone("no held-config card \(id)"))) }
            let (root, vault, node) = (card.root, cardVault, self.root)
            work.async { [weak self] in
                let accepted = ConfigHoldStore.accept(shown, root: root, vault: vault, snapshotRoot: node)
                guard let self else { return }
                self.queue.async {
                    switch accepted {
                    case .failure(let error): then(.failure(.refused("the vault didn't take the accept: \(error)")))
                    case .success(.changedSince(let held)):
                        let why = "This changed again after the card was drawn: nothing was accepted. Look at it again (config held) before you accept."
                        self.cards.change(id) {
                            $0.notice = why
                            $0.closed = "nothing accepted: it changed since"
                        }
                        then(.failure(.refused(why + " Held now: " + held.map { ConfigSeal.inert($0, limit: 200) }.joined(separator: ", "))))
                    case .success(.sealed(let names, let floor)):
                        self.cards.change(id) { $0.closed = "accepted" }
                        if self.leads.leads[card.project] != nil, !names.isEmpty {
                            self.deliver(built: { "The user accepted the change to \(names.joined(separator: ", ")) at the command line: it's sealed as it is, "
                                + "and workers, verifiers and merges go ahead again." }, from: .system("the user, at the command line"), root: root, action: nil)
                        }
                        then(.success(.object(["sealed": .array(names.map(NodeWire.Value.string)),
                                               "floorRecorded": .bool(floor != nil), "card": self.cards.cards[id]?.value ?? .null])))
                    }
                }
            }
        }
    }

    // MARK: Base moves

    func makeBaseMoves() -> BaseMoveStore {
        let moves = BaseMoveStore(vault: cardVault, reads: reads, background: { [work] body in work.async(execute: body) },
                                  main: { [queue] body in queue.async(execute: body) })
        moves.log = { [note] in note($0) }
        moves.onAsk = { [weak self] root, move in
            guard let self else { return }
            for old in self.cards.list(project: NodeIds.project(root: root)) where old.kind == .baseMove {
                self.cards.change(old.id) { $0.closed = "superseded by a newer move" }
            }
            var card = CardStore.Card(root: root, kind: .baseMove)
            card.base = BaseMoveStore.Shown(move)
            self.cards.put(card)
        }
        moves.onTaken = { [weak self] root, move, taker in
            guard let self else { return }
            for old in self.cards.list(project: NodeIds.project(root: root)) where old.kind == .baseMove {
                self.cards.change(old.id) { $0.closed = taker == .you ? "accepted" : "taken by the vault as the user's" }
            }
            guard taker == .you, self.leads.leads[NodeIds.project(root: root)] != nil else { return }
            self.deliver(built: { "The user accepted \(move.count) on \(move.branch) at the command line (\(move.from.prefix(8)) → \(move.to.prefix(8))): "
                + "your merges go ahead again." }, from: .system("the user, at the command line"), root: root, action: nil)
        }
        return moves
    }

    /// The leads' bases, looked at (each every 30 s, or when its reflog or workflow.md changed). On `queue`.
    func lookAtBases() {
        let roots = Set(leads.leads.values.filter { $0.session != nil }.map(\.root))
        guard !roots.isEmpty else { return }
        baseMoves.look(roots)
    }

    /// `base show FOLDER [--from COMMIT]`: a base-move card made on demand, also with no lead running. From any thread.
    public func baseShow(root: String, from: String?, then: @escaping (Result<CardStore.Card, CardFailure>) -> Void) {
        let (vault, node) = (cardVault, self.root)
        work.async { [weak self] in
            // After a host restart the vault lost the head: the snapshot's, marked unverified (E8).
            let shown = BaseMoveStore.show(root: root, from: from, vault: vault, snapshotHeads: AcceptedSnapshot.load(root: node).projects[root]?.heads ?? [:])
            guard let self else { return }
            self.queue.async {
                switch shown {
                case .failure(let refusal): then(.failure(.refused(refusal.description)))
                case .success(let shown):
                    for old in self.cards.list(project: NodeIds.project(root: root)) where old.kind == .baseMove && old.base?.move == nil {
                        self.cards.change(old.id) { $0.closed = "superseded by a newer card" }
                    }
                    var card = CardStore.Card(root: root, kind: .baseMove)
                    card.base = shown
                    self.cards.put(card)
                    then(.success(card))
                }
            }
        }
    }

    /// `base accept CARD`: the head the vault records is where the card showed the base (`setHead`, the commits shown and
    /// no further). From any thread.
    public func baseAccept(card id: String, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], let shown = card.base else { return then(.failure(.gone("no base card \(id)"))) }
            let root = card.root
            let node = self.root
            if let move = shown.move {
                return baseMoves.accept(root, move: move) { [weak self] failure in
                    guard let self else { return }
                    if let failure { return then(.failure(.refused("the vault didn't take it: \(failure)"))) }
                    self.work.async { Self.snapshotHead(move.to, branch: move.branch, root: root, node: node) }
                    then(.success(.object(["head": .string(move.to), "branch": .string(move.branch), "card": self.cards.cards[id]?.value ?? .null])))
                }
            }
            let vault = cardVault
            work.async { [weak self] in
                let set = Result { try vault.setHead(shown.to, root: root, branch: shown.branch) }
                if case .success = set {
                    LeadVault.BaseMoveNote.clear(root: root)
                    LeadVault.BaseMoveRefusal.clear(root: root)
                    Self.snapshotHead(shown.to, branch: shown.branch, root: root, node: node)
                }
                guard let self else { return }
                self.queue.async {
                    if case .failure(let error) = set { return then(.failure(.refused("the vault didn't take it: \(error)"))) }
                    self.cards.change(id) { $0.closed = "accepted" }
                    self.note("lead: the user recorded \(shown.branch) of \(LeadMail.project(of: root)) at \(shown.to.prefix(8))")
                    then(.success(.object(["head": .string(shown.to), "branch": .string(shown.branch), "card": self.cards.cards[id]?.value ?? .null])))
                }
            }
        }
    }

    /// The head `base accept` recorded, kept in the snapshot (E8): after a host restart `base show` takes it as "from",
    /// marked unverified. Off the engine's queue.
    static func snapshotHead(_ head: String, branch: String, root: String, node: URL) {
        try? AcceptedSnapshot.update(root: node, project: root) { project in
            project.heads[branch] = head
            project.headsAt = Date().timeIntervalSince1970
        }
    }

    /// `base keep CARD`: the lead's merges stay refused, and this move isn't asked about again until the base moves
    /// again. From any thread.
    public func baseKeep(card id: String, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], let shown = card.base else { return then(.failure(.gone("no base card \(id)"))) }
            if let move = shown.move { baseMoves.keepRefused(card.root, move: move) }
            cards.change(id) { $0.closed = "kept refused" }
            then(.success(.object(["kept": .bool(true), "card": cards.cards[id]?.value ?? .null])))
        }
    }
}
