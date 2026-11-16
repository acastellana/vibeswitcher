import Foundation
import VibeCore

/// The vault's record of the user's actions as the check a held `.user` message passes after a restart (EN-D9, E5's
/// `UserActions`): it holds the action as a message with its digest for that project, unspent (`LeadVaultV2Client.vouches`).
/// Nil when the host can't be asked.
public struct VaultUserActions: UserActions {
    let client: LeadVaultV2Client
    public init(client: LeadVaultV2Client) { self.client = client }
    public func vouches(action: String, digest: String, project: String) -> Bool? {
        try? client.vouches(action: action, digest: digest, subject: project)
    }
}

/// A `.user` message the server posted into a lead's inbox (`LeadEngine.postedUser`): the terminal, its text's digest
/// and the agent it is for, as posted.
struct PostedUser: Equatable, Sendable {
    var tty: String
    var digest: String
    var agentPid: Int32

    /// Whether `line`, read from the inbox under the posted id, is still the message the server posted: the user's, for
    /// the same agent, with the same text (the security follow-ups' item 16: only that line's seal is renewed).
    func isPosted(_ line: SteerMessage) -> Bool {
        line.from == .user && line.agentPid == agentPid && LeadVaultV2.digest(line.text) == digest
    }

    /// How many looks a posted id is out of a readable inbox (and out of its delivered record) before it's taken as gone
    /// another way and retired (`LeadEngine.retireTaken`).
    static let goneLooks = 2
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
        let taken = op == .revise ? Self.revision(question, of: existing?.question) : question
        card.question = Self.keepingTheUsers(taken, from: existing?.question)
        card.closed = Self.closed(card.question ?? taken)
        // The commit the options approve now: a revision that names another commit (or adds or drops "Approve") makes
        // the card show that one's facts, built anew, never the earlier commit's beside the new wording.
        let commit = Self.approvalCommit(taken)
        let rebuild = commit != nil && commit != card.approval?.commit
        card.kind = commit == nil ? .question : .approval
        if commit == nil { card.approval = nil } else if rebuild, let commit { card.approval = CardStore.ApprovalFacts(commit: commit) }
        cards.put(card)
        cardsChanged()
        if rebuild, let commit { buildApproval(card: card.id, commit: commit, root: root) }
        return card
    }

    /// The card's question `card` reworded as the revision `posted` says: its text, its options and its revisions (so its
    /// version) alone. A revision's post is built from the board, which any session can write, so its proposal, minutes,
    /// deadline, reason, priority and task are the board's, never taken (S3: only a posted question's timer runs out, as
    /// posted): the card keeps its own. Its timer, when it runs, starts again from `now` (its own minutes), as
    /// `LeadBoard.revise` does, and stops when its proposal is no longer an option or the new wording is one no timer may
    /// carry (`timerRefusal`). `posted` itself when there's no card question.
    static func revision(_ posted: LeadQuestion, of card: LeadQuestion?, now: Double = Date().timeIntervalSince1970) -> LeadQuestion {
        guard var question = card else { return posted }
        question.text = posted.text
        question.options = posted.options
        question.revisions = posted.revisions
        if question.isCounting {
            if let proposal = question.proposal, question.options.contains(proposal),
               LeadQuestion.timerRefusal(text: question.text, options: question.options, whyNow: question.whyNow, priority: question.priority) == nil {
                question.decideBy = now + Double(question.decideIn ?? LeadQuestion.defaultDecideIn) * 60
            } else {
                question.proposal = nil
                question.decideBy = nil
            }
        }
        return question
    }

    /// `posted` as the card keeps it: what the user did on the card (a hold, an answer) and what its timer decided stand,
    /// whatever the post says (a revision's post is built from the board, which any session can write, so a hold or an
    /// answer cleared there would otherwise come back to the card, and a timer the user stopped would run again).
    static func keepingTheUsers(_ posted: LeadQuestion, from card: LeadQuestion?) -> LeadQuestion {
        guard let card else { return posted }
        var question = posted
        if question.heldAt == nil { question.heldAt = card.heldAt }
        if question.answer == nil, card.answer != nil {
            question.answer = card.answer
            question.answeredAt = card.answeredAt
            question.answeredVersion = card.answeredVersion
            question.answeredFrom = card.answeredFrom
        }
        if question.autoDecidedAt == nil { question.autoDecidedAt = card.autoDecidedAt }
        return question
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
        let subject = Git.run(["log", "-1", "--format=%s", commit], in: root)
        if subject.ok { facts.subject = subject.output } else { facts.problems.append("\(commit.prefix(8)) isn't a commit of the repository") }
        let workflow = LeadWorkflow.load(from: ConfigHoldStore.workflowPath(root: root))
        let record = (try? vault.guardedRecord(root: root)) ?? nil
        switch Self.acceptedBase(workflow: workflow, record: record, root: root, vault: vault) {
        case .failure(let why):
            facts.problems.append(why.description)
        case .success(let base):
            facts.base = base.branch
            if let problem = base.problem { facts.problems.append(problem) }
            let files = Git.run(["diff", "--name-only", "--end-of-options", "\(base.head)...\(commit)"], in: root)
            if files.ok { facts.files = files.output.split(whereSeparator: \.isNewline).map(String.init) }
            let stat = Git.run(["diff", "--shortstat", "--end-of-options", "\(base.head)...\(commit)"], in: root)
            if stat.ok { facts.diffstat = stat.output.trimmingCharacters(in: .whitespaces) }
        }
        for task in facts.tasks {
            if let verdict = vault.verdict(root: root, task: task) {
                facts.verdicts[task] = "\(verdict.completion.rawValue), \(verdict.integrity.rawValue) at \(verdict.commit.prefix(8))"
                    + (verdict.commit.lowercased() == commit ? "" : " (not this commit)")
            }
        }
        if let recorded = record?["sensitive_paths"], recorded == LeadVault.hash(LeadVault.guardedValue("sensitive_paths", in: workflow)) {
            facts.sensitive = facts.files.filter { path in workflow.sensitiveGlobs.contains { LeadWorkflow.matches(path, glob: $0) } }
        } else {
            facts.problems.append("workflow.md's sensitive_paths isn't what the vault records, so the sensitive files aren't named")
        }
        return facts
    }

    /// The base an approval card's files and diffstat are taken against (the security follow-ups' item 14): workflow.md's
    /// `base_branch` only while its hash is the one the user's `config accept` recorded (`ConfigHoldStore.baseBranchKey`,
    /// `BaseMoveStore.show`'s gate), never the board's (a worker can write both files; the vault's record it can't); when
    /// it names none, the branch the lead merges into (`leadBranch`). Taken at the head the vault records for that branch
    /// (where the lead last left it), never where `refs/heads/<branch>` points now, which any session can move through
    /// the shared .git (the close-out review): a move since is said (`problem`), and with no head recorded the branch's
    /// commit now is taken, saying so. The branch must be one (`refs/heads/<branch>`: a name is never read as an
    /// option). Else why not, said on the card.
    static func acceptedBase(workflow: LeadWorkflow, record: [String: String]?, root: String,
                             vault: LeadVault) -> Result<(branch: String, head: String, problem: String?), Refused> {
        let named = workflow.baseBranch ?? ""
        guard let recorded = record?[ConfigHoldStore.baseBranchKey] else {
            return .failure(Refused("workflow.md's base branch isn't accepted yet (`vibeswitcher config held`, then `config accept`), so the files "
                + "and diffstat aren't shown"))
        }
        guard recorded == LeadVault.hash(named) else {
            return .failure(Refused("workflow.md's base_branch isn't the one the user accepted (`config held`, then `config accept` again), so the "
                + "files and diffstat aren't shown"))
        }
        let branch = named.isEmpty ? leadBranch(root: root, vault: vault) : named
        let head = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"], in: root)
        guard head.ok, !head.output.isEmpty else {
            return .failure(Refused("the base branch \(ConfigSeal.inert(branch, limit: 80)) isn't a branch of the repository, so the files and "
                + "diffstat aren't shown"))
        }
        let shown = ConfigSeal.inert(branch, limit: 80)
        let leftAt: String?
        do { leftAt = try vault.head(root: root, branch: branch) } catch {
            return .success((branch, head.output, "the vault can't be asked where the lead left \(shown) (\(error)), so the files and diffstat "
                + "are taken against where it points now (\(head.output.prefix(8))), which any session can move"))
        }
        guard let leftAt, Git.run(["rev-parse", "--verify", "--quiet", "\(leftAt)^{commit}"], in: root).ok else {
            return .success((branch, head.output, "the vault records no head for \(shown), so the files and diffstat are taken against where it "
                + "points now (\(head.output.prefix(8))), which any session can move"))
        }
        guard leftAt.lowercased() != head.output.lowercased() else { return .success((branch, leftAt, nil)) }
        return .success((branch, leftAt, "\(shown) moved since the lead last left it at \(leftAt.prefix(8)) (it points at "
            + "\(head.output.prefix(8)) now, not through the lead's merges): the files and diffstat are taken against \(leftAt.prefix(8)); "
            + "`vibeswitcher base show` lists what moved"))
    }

    /// The branch the lead merges into when workflow.md names none (the close-out review): the board's `baseBranch`, the
    /// branch checked out when the lead first started (as `LeadStart` and the lead's tools take it), only while the vault
    /// records a head for it (the lead's start recorded it; the board alone is any session's to write); else the main
    /// branch.
    static func leadBranch(root: String, vault: LeadVault) -> String {
        if let started = BoardStore(root: root).load().baseBranch, !started.isEmpty, (try? vault.head(root: root, branch: started)) != nil {
            return started
        }
        return Worktrees.mainBranch(root: root)
    }

    // MARK: answer, hold, timers

    /// The user's answer to the card `id` (`LeadController.answer`): bound to the card and the version it showed; what
    /// kind of answer it is and what the lead is told are the card's, the question as the lead's tool server posted it
    /// (S3: never the board's, which any session can write: `LeadBoard.answer` run on the card's question alone). Then on
    /// the board for the lead's record, an approval recorded in the vault (`recordApproval`), and the lead told as the
    /// user's, its message's digest recorded under `action` first. `then` hears on `queue` the outcome and its notice.
    /// From any thread.
    /// `version`: the wording the user was shown (the card's now when nil): a revision after it is said to the lead.
    public func answer(card id: String, text: String, version: Int? = nil, action: String?,
                       then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], card.kind == .question || card.kind == .approval, let question = card.question else {
                return then(.failure(.gone("no question card \(id)")))
            }
            if let why = Self.approvalRefusal(text, card: card) { return then(.failure(.refused(why))) }
            let (root, vault, seen, note) = (card.root, cardVault, min(version ?? question.version, question.version), self.note)
            var shown = LeadBoard()
            shown.questions = [question]
            let outcome = shown.answer(question.id, with: text, saw: seen)
            // The card takes it now: a second answer meanwhile finds it answered.
            let recorded: LeadQuestion? = {
                switch outcome {
                case .answered(let q, _), .withdrawn(let q), .afterAutoDecision(let q): return q
                case .alreadyAnswered, .notOpen, .missing: return nil
                }
            }()
            if let recorded {
                cards.change(id) { card in
                    card.question = recorded
                    card.closed = Self.closed(recorded) ?? card.closed
                }
            }
            reads.async({ _ -> String? in
                guard recorded != nil else { return nil }
                // The board is the lead's record of it, as before; what it holds is neither shown nor sent.
                do { _ = try BoardStore(root: root).update { board in board.answer(question.id, with: text, saw: seen) } } catch {
                    note("lead: the user's answer to question \(question.short) wasn't written to the board of \(LeadMail.project(of: root)) (\(error)); the lead is told it")
                }
                guard case .answered(let answered, _) = outcome else { return nil }
                do {
                    guard let tasks = try vault.recordApproval(text, of: answered, root: root) else { return nil }
                    return tasks.isEmpty ? "No task's branch is at that commit now, so the approval wasn't recorded: merge won't take it." : nil
                } catch {
                    return "Your approval wasn't recorded, so merge won't take it: \(error)"
                }
            }) { [weak self] approval in
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

    /// The user holds the card `id`'s question with a timer (`LeadController.hold`): the card's timer stops, it waits
    /// for an answer like any other, and the lead is told not to go ahead, as the user's, with the question and the
    /// proposal the card showed (never the board's). The board records the hold for the lead's record. From any thread.
    public func hold(card id: String, action: String?, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], let question = card.question else { return then(.failure(.gone("no question card \(id)"))) }
            let refusal = question.isOpen
                ? question.isCounting ? nil : "Question \(question.short) has no timer running."
                : "Question \(question.short) is closed (\(Self.closed(question) ?? "")): there's nothing to hold."
            if let refusal {
                cards.change(id) { $0.notice = refusal }
                return then(.failure(.refused(refusal)))
            }
            let (root, note) = (card.root, self.note)
            var held = question
            held.heldAt = Date().timeIntervalSince1970
            cards.change(id) {
                $0.question = held
                $0.notice = nil
            }
            tellAsUser("The user is holding your question \(held.short) “\(held.text)”: its timer is off, so don't go ahead with "
                       + "‘\(held.proposal ?? "")’; wait for their answer.", root: root, action: action)
            // Answered once the board has it too (the lead's record), as `answer` is.
            reads.async({ _ -> Void in
                do { try BoardStore(root: root).update { board in _ = try board.hold(question.id) } } catch {
                    note("lead: the user's hold of question \(question.short) wasn't written to the board of \(LeadMail.project(of: root)) (\(error)); the lead is told it")
                }
            }) { [weak self] _ in
                guard let self else { return }
                then(.success(.object(["held": .bool(true), "card": self.cards.cards[id]?.value ?? .null])))
                self.refresh()
            }
        }
    }

    /// Runs out the timers of the questions the lead's tool server posted (on `queue`, from each card's question as the
    /// post left it: never the board's, where any session can write a question, a deadline or a proposal): the lead is
    /// told to go ahead with each proposal no one answered, once, as VibeSwitcher's timer, and the card says it was
    /// decided; the board records it for the lead's record (`recordTimer`, on `reads`). From any thread (E7's refresh
    /// calls `fireTimers` on the engine's queue).
    public func runTimers(now: Double = Date().timeIntervalSince1970) {
        queue.async { [self] in fireTimers(now: now) }
    }

    /// The roots whose boards a refresh keeps read: every lead's, and every root a question card was posted for. On
    /// `queue`.
    var timerRoots: Set<String> {
        Set(leads.leads.values.map(\.root)).union(cards.list().filter { $0.question != nil }.map(\.root))
    }

    /// Each open question or approval card whose question's timer ran out by `now`: decided on the card, recorded on its
    /// board, and the lead told (`tell(timers:)`). On `queue`.
    func fireTimers(now: Double) {
        var fired: [String: [(question: LeadQuestion, message: String)]] = [:]
        for card in cards.list() where card.closed == nil && (card.kind == .question || card.kind == .approval) {
            guard var question = card.question, question.isCounting, (question.decideBy ?? .infinity) <= now else { continue }
            question.autoDecidedAt = now
            fired[card.root, default: []].append((question, question.autoDecisionMessage))
        }
        guard !fired.isEmpty else { return }
        let note = self.note
        reads.async { _ in
            for (root, decided) in fired { Self.recordTimer(decided.map(\.question), root: root, now: now, note: note) }
        }
        tell(timers: fired)
    }

    /// The board's record of questions their timer decided (as `BoardStore.runTimers` writes it): each question marked
    /// decided there while it's open, the decision appended to decisions.md, and the lead's reports. On `reads`.
    static func recordTimer(_ decided: [LeadQuestion], root: String, now: Double, note: (String) -> Void) {
        let store = BoardStore(root: root)
        do {
            try store.update { board in
                for question in decided {
                    if let index = board.questions.firstIndex(where: { $0.id == question.id }), board.questions[index].isOpen {
                        board.questions[index].autoDecidedAt = now
                    }
                    board.reports = Array(((board.reports ?? []) + [LeadReport(about: "timer", text: question.autoDecisionMessage, at: now)])
                        .suffix(LeadBoard.keptReports))
                }
            }
            for question in decided { try store.appendDecision(question.autoDecision.decision, why: question.autoDecision.why) }
        } catch {
            note("lead: the timer's decision wasn't written to the board of \(LeadMail.project(of: root)) (\(error)); the lead is told it")
        }
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
            do { try client.recordUserAction(action, kind: LeadVaultV2.messageKind, subject: project, digest: LeadVaultV2.digest(text)) } catch {
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

    /// A `.user` message posted to a lead's inbox: retired once its delivered record shows it, or once it's gone from
    /// the inbox another way. On `queue`.
    func postedAsUser(_ id: String, tty: String, text: String, agentPid: Int32) {
        postedUser[id] = PostedUser(tty: tty, digest: LeadVaultV2.digest(text), agentPid: agentPid)
    }

    /// Retires in the vault each `.user` message the lead took (its inbox's delivered record shows it, and the line is out
    /// of the inbox): its seal verifies false from then on, so a copy put back in the inbox arrives as unverified (T41).
    /// Each one still waiting in the inbox has its seal renewed (`renewUserSeals`: its life counts from now), so an answer
    /// that waits while the lead's tool call runs long (a merge's tests) is still the user's when the lead takes it; the vault renews none a check
    /// has passed nor any past `LeadVaultV2.renewedLifeCap` from its first seal, and the server none it no longer sees
    /// waiting as it posted it (`PostedUser.isPosted`: the inbox is a file any process of the user's can rewrite, and a
    /// line rewritten under a posted id keeps no seal alive). One a lead start's handover withdrew (`withdrawnUser`: it
    /// holds it for the new lead under a new id) is retired by name. One otherwise neither waiting nor in the delivered
    /// record left the inbox another way: retired too, and no longer looked for, but only once it was out of the inbox
    /// at `PostedUser.goneLooks` looks that read lines from it (`goneUser`). The inbox isn't read under its lock, and each
    /// rewriter of it (a hook's delivery, a withdrawal, a wake) truncates it before writing the rest back, so one read can
    /// see it empty or cut short; an empty or unreadable inbox says nothing either way. On `queue`, at each `look`.
    func retireTaken() {
        guard !postedUser.isEmpty, !retiring else { return }
        retiring = true
        let (posted, withdrawn, inbox, client, note) = (postedUser, withdrawnUser, root, link.vaultV2, self.note)
        reads.async({ _ -> (taken: [String], waiting: [String], gone: [String], seen: [String]) in
            var taken: [String] = [], waiting: [String] = [], gone: [String] = [], seen: [String] = []
            for (tty, entries) in Dictionary(grouping: posted, by: \.value.tty) {
                let delivered = SteerInbox.delivered(tty: tty, root: inbox)
                let lines = SteerInbox.pending(tty: tty, root: inbox)
                let pending = Dictionary(lines.map { ($0.id, $0) }) { first, _ in first }
                // Taken: in the delivered record and out of the inbox, as the lead's hook leaves it (the record alone is any
                // process's to write: an id put there while the line waits doesn't retire its seal).
                for (id, was) in entries.sorted(by: { $0.key < $1.key }) {
                    if withdrawn.contains(id) {
                        taken.append(id)
                    } else if let line = pending[id] {
                        seen.append(id)
                        if was.isPosted(line) { waiting.append(id) }
                    } else if delivered.contains(id) {
                        taken.append(id)
                    } else if !lines.isEmpty {
                        gone.append(id)
                    }
                }
            }
            return (taken, waiting, gone, seen)
        }) { [weak self] found in
            guard let self else { return }
            found.seen.forEach { self.goneUser[$0] = nil }
            var taken = found.taken
            for id in found.gone {
                let looks = (self.goneUser[id] ?? 0) + 1
                self.goneUser[id] = looks
                if looks >= PostedUser.goneLooks { taken.append(id) }
            }
            guard !taken.isEmpty || !found.waiting.isEmpty else {
                self.retiring = false
                return
            }
            self.work.async {
                if (try? client.renewUserSeals(found.waiting)) == nil {
                    note("lead: \(found.waiting.count) waiting message(s) of the user's not renewed in the vault: tried again at the next look")
                }
                let retired = taken.isEmpty || (try? client.retireUserSeals(taken)) != nil
                if !retired { note("lead: \(taken.count) taken or withdrawn message(s) of the user's not retired in the vault yet: tried again") }
                self.queue.async {
                    if retired {
                        for id in taken {
                            self.postedUser[id] = nil
                            self.withdrawnUser.remove(id)
                            self.goneUser[id] = nil
                        }
                    }
                    self.retiring = false
                }
            }
        }
    }

    /// A lead start's handover took `ids` out of the replaced lead's inbox (`LeadHandover.takeWaiting`), to hold them for
    /// the new lead under new ids: those of the user's this server posted are retired by name at once (`retireTaken`). On
    /// `queue`.
    func withdrewFromInbox(_ ids: [String]) {
        let posted = ids.filter { postedUser[$0] != nil }
        guard !posted.isEmpty else { return }
        withdrawnUser.formUnion(posted)
        retireTaken()
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
