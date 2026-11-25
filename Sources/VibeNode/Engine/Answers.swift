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
        /// The lead has it already: nothing was taken back (`answer.replace`, `tell.retract`).
        case delivered(String)
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
    /// for a post, the card brought up to date for a withdrawal (a revision is `questionRevised`). Nil for a withdrawal
    /// of a question never posted (one written to the board alone is never shown), or for a revision posted this way. On
    /// `queue`.
    @discardableResult
    func questionPosted(_ op: NodeQuestionPost.Op, question: LeadQuestion, root: String) -> CardStore.Card? {
        guard op != .revise else { return nil }
        let root = (root as NSString).standardizingPath
        leads.lead(root: root)
        let existing = cards.card(question: question.id, root: root)
        guard existing != nil || op == .post else { return nil }
        return show(Self.keepingTheUsers(question, from: existing?.question), on: existing ?? CardStore.Card(root: root, kind: .question), root: root)
    }

    /// The lead's tool server posted its revision of a question (`NodeQuestionPost.Revision`: what the lead gave, the
    /// server having checked its seal, its session and its runner): the card's own question reworded with it
    /// (`revision`). Nil when no card shows that question. On `queue`.
    @discardableResult
    func questionRevised(_ revision: NodeQuestionPost.Revision, root: String, now: Double = Date().timeIntervalSince1970) -> CardStore.Card? {
        let root = (root as NSString).standardizingPath
        leads.lead(root: root)
        guard let card = cards.card(question: revision.id, root: root), let question = card.question else { return nil }
        guard let reworded = Self.revision(revision, of: question, now: now) else { return card }
        return show(reworded, on: card, root: root)
    }

    /// `card` showing `question` now: closed as the question is, and an approval card of the commit its options approve,
    /// whose facts are built anew when that commit changed. On `queue`.
    private func show(_ question: LeadQuestion, on card: CardStore.Card, root: String) -> CardStore.Card {
        var card = card
        card.question = question
        card.closed = Self.closed(question)
        // The commit the options approve now: a revision that names another commit (or adds or drops "Approve") makes
        // the card show that one's facts, built anew, never the earlier commit's beside the new wording.
        let commit = Self.approvalCommit(question)
        let rebuild = commit != nil && commit != card.approval?.commit
        card.kind = commit == nil ? .question : .approval
        if commit == nil { card.approval = nil } else if rebuild, let commit { card.approval = CardStore.ApprovalFacts(commit: commit) }
        // A revision that drops the options allowing a model drops the vault's facts with them.
        if !Self.mayAskAuditModel(question) { card.facts = nil }
        cards.put(card)
        cardsChanged()
        if rebuild, let commit { buildApproval(card: card.id, commit: commit, root: root) }
        if Self.mayAskAuditModel(question) { buildAuditFacts(card: card.id, question: question, root: root) }
        return card
    }

    /// A question whose options allow a model to audit a task (`LeadVault.auditGrant`): its facts come from the vault.
    static func mayAskAuditModel(_ question: LeadQuestion) -> Bool {
        question.task != nil && question.options.contains { LeadVault.auditGrant(in: $0) != nil }
    }

    /// The vault's facts for `question` (`auditFacts`), put on its card.
    func buildAuditFacts(card id: String, question: LeadQuestion, root: String) {
        let vault = cardVault
        work.async { [weak self] in
            let facts = Self.auditFacts(question: question, root: root, vault: vault)
            guard let self else { return }
            self.queue.async { self.cards.change(id) { card in card.facts = facts } }
        }
    }

    /// What the vault and git say of a question allowing a model to audit a task, beside the lead's words: whether the
    /// lead's audit asked it (the vault's `AuditOffer`), at which commit and where the branch is now, the workers' model
    /// the floor keeps audits off (worker_model, else Claude Code's default) and the families the host recorded for the
    /// task's launches. Reads the vault and git.
    public static func auditFacts(question: LeadQuestion, root: String, vault: LeadVault) -> [String] {
        guard let task = question.task else { return [] }
        guard let offer = vault.auditOffer(root: root, question: question.id) else {
            return ["no audit of \(task) asked this question (the vault has no record of it): an answer to it allows no model"]
        }
        var facts = ["the audit of \(task) at \(offer.commit.prefix(12)) asked it: an answer allows that model for that commit only, once"]
        let head = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/" + Worktrees.branch(task)], in: root)
        if head.ok, !head.output.hasPrefix(offer.commit) { facts.append("the branch has moved since: it's at \(head.output.prefix(12)) now, so an allowance wouldn't be used") }
        let floor = (try? vault.reviewFloor(root: root)) ?? nil
        if let model = floor?.workerModel {
            facts.append("workers' model: \(model), by your review floor")
        } else {
            let model = WorkerLaunch.settings(in: VibePaths.accountHome, [".claude", "settings.json"]).object?["model"] as? String
            facts.append("workers' model: Claude Code's default, \(model ?? "not set (counted as opus)")")
        }
        let launched = vault.launchedFamilies(root: root, task: task) ?? []
        facts.append("its workers were launched on: " + (launched.isEmpty ? "nothing recorded" : launched.joined(separator: ", ")) + " (the host's record)")
        if vault.settingsUnread(root: root, task: task) { facts.append("a project settings file wasn't read when a worker was bound (what it names isn't recorded)") }
        // What the vault's record leaves free (the workers' model and the launches): none means it agrees no model is left.
        let workers = floor?.workerModel ?? (WorkerLaunch.settings(in: VibePaths.accountHome, [".claude", "settings.json"]).object?["model"] as? String)
        let excluded = Set(launched + [LeadReviewFloor.workersModel(workers)].compactMap(WorkerLaunch.family(of:)))
        let free = ["fable", "opus", "sonnet", "mythos"].filter { !excluded.contains($0) }
        facts.append("models the vault's record leaves free: " + (free.isEmpty ? "none" : free.joined(separator: ", ")))
        return facts
    }

    /// The card's question `card` reworded as the lead's revision `change` says, as `LeadBoard.revise` rewords the
    /// board's: the new text (when given and not blank) and the new options (when given), the card's own text and options
    /// kept as the revision's earlier wording with the lead's note (so its version). Everything else is the card's: a
    /// revision's post carries what the lead gave, never the board's question (any session writes `board.json`: S3, T38;
    /// only a posted question's timer runs out, as posted). Its timer, when it runs, starts again from `now` (its own
    /// minutes), and stops when its proposal is no longer an option or the new wording is one no timer may carry
    /// (`timerRefusal`). Nil when it changes nothing.
    static func revision(_ change: NodeQuestionPost.Revision, of card: LeadQuestion, now: Double = Date().timeIntervalSince1970) -> LeadQuestion? {
        let text = change.text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? card.text
        let options = change.options ?? card.options
        guard text != card.text || options != card.options else { return nil }
        var question = card
        question.revisions = (card.revisions ?? []) + [LeadQuestion.Revision(text: card.text, options: card.options, note: change.note, at: now)]
        question.text = text
        question.options = options
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
                       then: @escaping (Result<WireKinds.Answer.Result, CardFailure>) -> Void) {
        queue.async { [self] in
            // A feature plugin's card: its words (`PluginEngine.swift`), its result its own.
            if let card = cards.cards[id], card.kind == .plugin {
                return answerPlugin(card, text: text) { then($0.map { WireKinds.Answer.Result(fields: $0.object ?? [:]) }) }
            }
            guard let card = cards.cards[id], card.kind == .question || card.kind == .approval, let question = card.question else {
                return then(.failure(.gone("no question card \(id)")))
            }
            if let why = Self.approvalRefusal(text, card: card) { return then(.failure(.refused(why))) }
            // An answer allowing a model waits for the vault's facts on the card: the user answers what they were shown.
            if Self.mayAskAuditModel(question), LeadVault.auditGrant(in: text) != nil, card.facts == nil {
                return then(.failure(.refused("This card's facts from the vault aren't on it yet: nothing was answered. Answer again in a moment.")))
            }
            let (root, vault, seen, note, stateFile) = (card.root, cardVault, min(version ?? question.version, question.version), self.note, observer.stateFile)
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
            reads.async({ _ -> (approval: String?, lead: LeadStep?) in
                guard recorded != nil else { return (nil, nil) }
                // The board's lead and its hooks' state just before the answer reaches the board: any step it takes after
                // may read it there (`answer.replace` takes it back only before one, `UserDeliveries.swift`).
                let lead = LeadStep.read(root: root, stateFile: stateFile)
                // The board is the lead's record of it, as before; what it holds is neither shown nor sent.
                do { _ = try BoardStore(root: root).update { board in board.answer(question.id, with: text, saw: seen) } } catch {
                    note("lead: the user's answer to question \(question.short) wasn't written to the board of \(LeadMail.project(of: root)) (\(error)); the lead is told it")
                }
                guard case .answered(let answered, _) = outcome else { return (nil, lead) }
                // A model allowed to audit a task at a commit (the lead's audit asked): what was recorded, said.
                if let recorded = vault.recordAuditGrant(text, of: answered, root: root) { return (recorded, lead) }
                do {
                    guard let tasks = try vault.recordApproval(text, of: answered, root: root) else { return (nil, lead) }
                    return (tasks.isEmpty ? "No task's branch is at that commit now, so the approval wasn't recorded: merge won't take it." : nil, lead)
                } catch {
                    return ("Your approval wasn't recorded, so merge won't take it: \(error)", lead)
                }
            }) { [weak self] read in
                let (approval, lead) = read
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
                if let message = outcome.message(given: text) {
                    self.tellAsUser(message, root: root, action: action, about: .answer(question: question.id, card: id), lead: lead)
                }
                then(.success(WireKinds.Answer.Result(outcome: Self.word(outcome), notice: notice, card: self.cards.cards[id]?.value)))
                // The app refreshes after each answer (`LeadController.refresh`): the board as answered, its timers.
                self.refresh()
            }
        }
    }

    /// The user holds the card `id`'s question with a timer (`LeadController.hold`): the card's timer stops, it waits
    /// for an answer like any other, and the lead is told not to go ahead, as the user's, with the question and the
    /// proposal the card showed (never the board's). The board records the hold for the lead's record. From any thread.
    public func hold(card id: String, action: String?, then: @escaping (Result<WireKinds.Hold.Result, CardFailure>) -> Void) {
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
            // The app's words (`LeadAnswerOutcome.holdMessage`, main's 121ef5aa), which the setup scorecard counts by.
            tellAsUser(LeadAnswerOutcome.holdMessage(held), root: root, action: action)
            // Answered once the board has it too (the lead's record), as `answer` is.
            reads.async({ _ -> Void in
                do { try BoardStore(root: root).update { board in _ = try board.hold(question.id) } } catch {
                    note("lead: the user's hold of question \(question.short) wasn't written to the board of \(LeadMail.project(of: root)) (\(error)); the lead is told it")
                }
            }) { [weak self] _ in
                guard let self else { return }
                then(.success(WireKinds.Hold.Result(held: true, card: self.cards.cards[id]?.value)))
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
    /// `about`: an answer or a tell, followed to the lead for its read mark (`UserDeliveries.swift`).
    /// `lead`: an answer's, the board's lead as `LeadStep` read it just before the answer reached the board.
    func tellAsUser(_ text: String, root: String, action: String?, about: UserDelivery.Kind? = nil, lead: LeadStep? = nil) {
        guard let action else { return deliver(built: { text }, from: .user, root: root, action: nil) }
        if let about { follow(action, root: root, kind: about, lead: lead) }
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
        reads.async({ _ -> (taken: [String], waiting: [String], gone: [String], seen: [String], delivered: [String]) in
            var taken: [String] = [], waiting: [String] = [], gone: [String] = [], seen: [String] = [], took: [String] = []
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
                        // Partly handed, or a wake-up prompt named it: the lead has it (`answer.replace` refuses it so).
                        if line.handedOver != nil || line.wokenAt != nil { took.append(id) }
                    } else if delivered.contains(id) {
                        taken.append(id)
                        took.append(id)
                    } else if !lines.isEmpty {
                        gone.append(id)
                    }
                }
            }
            return (taken, waiting, gone, seen, took)
        }) { [weak self] found in
            guard let self else { return }
            found.seen.forEach { self.goneUser[$0] = nil }
            // The read marks: what the lead's hook took (`UserDeliveries.swift`).
            if !found.delivered.isEmpty { self.taken(found.delivered) }
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
    /// that held thing's difference too. Asked again with nothing changed, the same open card (its id and code). From
    /// any thread.
    public func configHeld(root: String, diff: String?, then: @escaping (Result<WireKinds.ConfigHeld.Result, CardFailure>) -> Void) {
        let (vault, home, node) = (cardVault, self.home, self.root)
        work.async { [weak self] in
            // The last accept the snapshot knows (E8): each held thing said the same, changed or new since.
            let snapshot = AcceptedSnapshot.load(root: node)
            let held = ConfigHoldStore.held(root: root, vault: vault, home: home, snapshot: snapshot.projects[root])
                .map { SessionPresets.withPresetsToAccept($0, vault: vault, home: home, nodeRoot: node) }
            // The home folder's watched things' names (the Mac-wide seal's): what another root's open card may show too.
            let homeNames = Set(ConfigSeal.homeWatched(home: home).map(\.name))
            // With nothing held: whether accepting would record anything (guard rails or a floor workflow.md proposes that
            // the vault doesn't hold), and whether the last accept's snapshot is one this host's vault sealed (none: the
            // vault's first look is owed, a host restart since, or the project never accepted). Nothing owed: the card is
            // shown, never kept open (the real node, 2026-11-25, drew one with nothing held, shown as blocking, that a
            // page couldn't accept).
            // Whether its accept records the project's rules (`approve` sets such a card aside): `status` says so.
            let recordsRules: Bool = {
                guard case .success(let shown) = held else { return false }
                return !((try? ConfigHoldStore.wouldRecord(shown, root: root, vault: vault)) ?? []).isEmpty
            }()
            let owed: (record: Bool, firstLook: Bool)? = {
                guard case .success(let shown) = held, shown.items.isEmpty else { return nil }
                let pending = (try? ConfigHoldStore.wouldRecord(shown, root: root, vault: vault)) ?? ["?"]
                let record = (try? vault.guardedRecord(root: root)) ?? nil
                let sealed = AcceptedSnapshot.vouch(snapshot.projects[root], root: root, vault: vault, record: record).sealed
                return (!pending.isEmpty || !sealed, !sealed)
            }()
            let difference: [String]? = {
                guard case .success(let shown) = held, let diff else { return nil }
                // The presets file: what changed in presets since the user's accept, not its text (`SessionPresets.difference`).
                if diff == SessionPresets.sealName, shown.items.contains(where: { $0.name == diff }) { return SessionPresets.difference(vault: vault, nodeRoot: node) }
                return ConfigHoldStore.difference(shown, name: diff, home: home)
            }()
            guard let self else { return }
            self.queue.async {
                switch held {
                case .failure(let error): then(.failure(.refused("the node couldn't say what it holds for \(root): try again (\(error))")))
                case .success(let held):
                    var shown = self.sharingHome(held, root: root, homeNames: homeNames)
                    shown.recordsRules = recordsRules ? true : nil
                    let project = NodeIds.project(root: root)
                    let open = self.cards.list(project: project).filter { $0.kind == .configHeld }
                    if let owed, shown.sharedHome == nil {
                        // A root whose accept left its rails and floor to the home's card (`secondAccepts`) owes one.
                        guard owed.record || self.secondAccepts[root] != nil else {
                            for old in open { self.cards.change(old.id) { $0.closed = "nothing held any more" } }
                            // What `config held` shows of the rails, on a card no one needs to accept: not kept, not open.
                            var shownOnly = CardStore.Card(root: root, kind: .configHeld)
                            shownOnly.config = shown
                            shownOnly.closed = "nothing to accept"
                            var result = WireKinds.ConfigHeld.Result(card: shownOnly.value)
                            if let diff { result.difference = .string("nothing held is named \(diff)") }
                            return then(.success(result))
                        }
                        shown.firstLook = owed.firstLook ? true : nil
                    }
                    // Nothing changed since an open card was drawn: that card again, so a `config held` and a `config
                    // accept` from two separate calls meet (2026-11-20, the node's frictions). Only a card showing all
                    // the same (every field of `Shown`) is kept; anything else closes the open ones and draws anew.
                    let card: CardStore.Card
                    if let same = open.last(where: { $0.config == shown }) {
                        for old in open where old.id != same.id { self.cards.change(old.id) { $0.closed = "superseded by a newer card" } }
                        card = same
                    } else {
                        for old in open { self.cards.change(old.id) { $0.closed = "superseded by a newer card" } }
                        var drawn = CardStore.Card(root: root, kind: .configHeld)
                        drawn.config = shown
                        self.cards.put(drawn)
                        card = drawn
                    }
                    var result = WireKinds.ConfigHeld.Result(card: card.value)
                    if let diff { result.difference = difference.map { .array($0.map(NodeWire.Value.string)) } ?? .string("nothing held is named \(diff)") }
                    then(.success(result))
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
            let homeNames = Set(ConfigSeal.homeWatched(home: home).map(\.name))
            let found = roots.sorted().reduce(into: [String: ConfigHoldStore.Shown]()) { found, root in
                if case .success(var shown) = ConfigHoldStore.held(root: root, vault: vault, home: home, look: false,
                                                                   snapshot: snapshot.projects[root]) {
                    shown.recordsRules = ((try? ConfigHoldStore.wouldRecord(shown, root: root, vault: vault)) ?? []).isEmpty ? nil : true
                    found[root] = shown
                }
            }
            guard let self else { return }
            self.queue.async {
                self.lookingAtConfig = false
                for (root, shown) in found.sorted(by: { $0.key < $1.key }) { self.configLooked(shown, root: root, homeNames: homeNames) }
            }
        }
    }

    /// `shown` with what another root's open held-config card already lists with the same hashes, of the home folder's
    /// things (`homeNames`, the Mac-wide seal's: one accept seals them for every root), left to that card
    /// (`ConfigHoldStore.SharedHome`): neither listed nor sealed by this one, said in one line. The home's own card is
    /// the one taken when it is open, else the one listing the most of them. A card drawn alone lists everything, as
    /// before. On `queue`.
    func sharingHome(_ shown: ConfigHoldStore.Shown, root: String, homeNames: Set<String>) -> ConfigHoldStore.Shown {
        // The home's own card lists all of its own.
        let mine = shown.items.filter { homeNames.contains($0.name) }
        guard root != home, !mine.isEmpty else { return shown }
        let others = cards.list().filter { $0.kind == .configHeld && $0.root != root && $0.config != nil }
        let matches = others.map { card -> (card: CardStore.Card, names: [String]) in
            let listed = Dictionary((card.config?.items ?? []).map { ($0.name, $0.hash) }) { first, _ in first }
            return (card, mine.filter { listed[$0.name] == $0.hash }.map(\.name))
        }.filter { !$0.names.isEmpty }
        guard let best = matches.first(where: { $0.card.root == home }) ?? matches.max(by: { ($0.names.count, $1.card.at) < ($1.names.count, $0.card.at) }) else {
            return shown
        }
        let left = Set(best.names)
        var marked = shown
        marked.items.removeAll { left.contains($0.name) }
        marked.hashes = marked.hashes.filter { !left.contains(ConfigSeal.name(ofKey: $0.key)) }
        marked.sharedHome = ConfigHoldStore.SharedHome(names: best.names, card: best.card.id, folder: best.card.root)
        // Its plain line says what is its own (the rest is said as the home folder's).
        marked.summary = HeldWhat.summary(items: marked.items)
        return marked
    }

    /// A look found `shown` held for `root`: a card when something is held that no open held-config card shows with
    /// these hashes. On `queue`.
    func configLooked(_ held: ConfigHoldStore.Shown, root: String, homeNames: Set<String> = []) {
        let project = NodeIds.project(root: root)
        let open = cards.list(project: project).filter { $0.kind == .configHeld }
        guard !held.items.isEmpty else { return }
        // As it would be drawn (what another root's open card lists left to it), compared with the open ones so.
        let shown = sharingHome(held, root: root, homeNames: homeNames)
        guard !open.contains(where: { $0.config?.hashes == shown.hashes && $0.config?.sharedHome == shown.sharedHome }) else { return }
        for old in open { cards.change(old.id) { $0.closed = "superseded by a newer card" } }
        var card = CardStore.Card(root: root, kind: .configHeld)
        card.config = shown
        cards.put(card)
        note("lead: the vault holds \(shown.items.map { ConfigSeal.inert($0.name, limit: 80) }.joined(separator: ", ")) for "
             + "\(LeadMail.project(of: root)): card \(card.id) (config held, config accept)")
    }

    /// `config accept CARD`: the seal of what the card showed, then the rails and the floor it proposed (EN-D7), and the
    /// lead told. When the config moved past the card, nothing is sealed and the card says so. From any thread.
    /// `inBatch`: an item of `vibeswitcher approve`'s batch, refused when the card would record any guard rail or a review
    /// floor (`ConfigHoldStore.wouldRecord`, asked in the same turn of `work` as the accept, of the card the accept would
    /// record): nothing accepted, the card left open for the folder's own `config held` and `config accept`.
    /// `fromPage`: an acting page's accept (single, or an item of its batch), refused when the floor or a guard rail
    /// isn't known to be the recorded one (`ConfigHoldStore.pageRefusal`): accepted from a terminal only.
    public func configAccept(card id: String, inBatch: Bool = false, fromPage: Bool = false,
                             then: @escaping (Result<WireKinds.ConfigAccept.Result, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], let shown = card.config else { return then(.failure(.gone("no held-config card \(id)"))) }
            let (root, vault, node, queue) = (card.root, cardVault, self.root, self.queue)
            work.async { [weak self] in
                if fromPage {
                    let changed: [String]
                    do { changed = try ConfigHoldStore.pageRefusal(shown, root: root, vault: vault) } catch {
                        return queue.async { then(.failure(.refused("the vault can't say what this accept would record (\(error)): nothing was accepted"))) }
                    }
                    if !changed.isEmpty {
                        let why = ConfigHoldStore.pageRefusalWords(changed)
                        self?.note("config accept of \(id) from a page refused: \(why)")
                        return queue.async { then(.failure(.refused(why))) }
                    }
                }
                if inBatch {
                    // Answered on `queue`, as every other outcome (`Requests.offQueueReplies` found these from `work`).
                    let pending: [String]
                    do { pending = try ConfigHoldStore.wouldRecord(shown, root: root, vault: vault) } catch {
                        return queue.async { then(.failure(.refused("the vault can't say what this accept would record (\(error)): nothing was accepted"))) }
                    }
                    if !pending.isEmpty {
                        let why = "this accept would record " + pending.map { ConfigSeal.inert($0, limit: 80) }.joined(separator: ", ")
                            + ", which a batch never does: nothing was accepted; accept it on its own: vibeswitcher config held \(root)"
                        self?.note("config accept of \(id) in a batch refused: \(why)")
                        return queue.async { then(.failure(.refused(why))) }
                    }
                }
                let accepted = ConfigHoldStore.accept(shown, root: root, vault: vault, snapshotRoot: node)
                // The user's explicit accept of the presets file: the hash it sealed, recorded where a preset's start
                // asks (`Requests.presetsBaselineRefusal`) before the accept is answered; a look alone records none.
                var markFailed: Error?
                if case .success(.sealed) = accepted { markFailed = SessionPresets.markAccepted(shown, vault: vault, nodeRoot: node) }
                guard let self else { return }
                if let markFailed { self.note("config accept: the presets file's accept couldn't be recorded: \(markFailed)") }
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
                    case .success(.sealed(let names, let floor, let homeWaits)):
                        self.cards.change(id) { $0.closed = homeWaits.isEmpty ? "accepted" : "accepted; the home folder's \(homeWaits.count) still held" }
                        // A root left waiting on the home's card: noted until its card is accepted with nothing waiting.
                        if homeWaits.isEmpty { self.secondAccepts[root] = nil } else { self.secondAccepts[root] = (homeWaits, false) }
                        // What this accept sealed that another root's card left waiting: that root's lead goes ahead (its
                        // rails and floor still wait for its own card's next accept, as `status` says).
                        let sealed = Set(names)
                        for (other, entry) in self.secondAccepts.sorted(by: { $0.key < $1.key })
                        where other != root && !entry.told && !sealed.isDisjoint(with: entry.waits) {
                            self.secondAccepts[other]?.told = true
                            guard self.leads.leads[NodeIds.project(root: other)] != nil else { continue }
                            let cleared = entry.waits.filter(sealed.contains)
                            self.deliver(built: { "The user accepted the change to \(cleared.joined(separator: ", ")) at the command line (your home folder's): "
                                + "it's sealed as it is, and workers, verifiers and merges go ahead again." },
                                         from: .system("the user, at the command line"), root: other, action: nil)
                        }

                        if self.leads.leads[card.project] != nil, !names.isEmpty, homeWaits.isEmpty {
                            self.deliver(built: { "The user accepted the change to \(names.joined(separator: ", ")) at the command line: it's sealed as it is, "
                                + "and workers, verifiers and merges go ahead again." }, from: .system("the user, at the command line"), root: root, action: nil)
                        }
                        var result = WireKinds.ConfigAccept.Result(sealed: names, floorRecorded: floor != nil, card: self.cards.cards[id]?.value)
                        if !homeWaits.isEmpty {
                            result.homeWaits = homeWaits
                            result.homeCard = shown.sharedHome?.card
                            result.homeFolder = shown.sharedHome?.folder
                        }
                        then(.success(result))
                    }
                }
            }
        }
    }

    /// `status`'s and the brief's words for each root whose guard rails and review floor wait for its card's next
    /// accept (`secondAccepts`), with the one command. On `queue`.
    var secondAcceptNotices: [String] {
        secondAccepts.sorted { $0.key < $1.key }.map { root, entry in
            "\(LeadMail.project(of: root)): workflow.md's guard rails and review floor aren't recorded yet: its card was accepted before your home "
                + "folder's; " + (entry.told ? "that one is accepted now, so accept this folder's again" : "once that one is accepted, accept this folder's again")
                + ": vibeswitcher config held \(root)"
        }
    }

    // MARK: Base moves

    func makeBaseMoves() -> BaseMoveStore {
        let moves = BaseMoveStore(vault: cardVault, reads: reads, background: { [work] body in work.async(execute: body) },
                                  main: { [queue] body in queue.async(execute: body) })
        moves.log = { [note] in note($0) }
        moves.onAsk = { [weak self] root, move in
            guard let self else { return }
            let open = self.cards.list(project: NodeIds.project(root: root)).filter { $0.kind == .baseMove }
            // A card open already for this very move (the user's `base show` of a moment ago, the acceptance run's A16
            // flake: the look found the commit just shown and closed the card the user was accepting) is the move's
            // card: kept, and no second drawn. Accepting it records the head where the move went.
            if open.contains(where: { $0.base?.branch == move.branch && $0.base?.to == move.to }) { return }
            for old in open {
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

    /// `base show FOLDER [--from COMMIT]`: a base-move card made on demand, also with no lead running; none when the base
    /// is where the vault recorded it (`Shown.unmoved`): `.unmoved` with its head, and the open on-demand cards of the
    /// folder closed (each showed a move that is no longer to accept). The same move shown again is its open card.
    /// From any thread.
    public enum BaseShown {
        case card(CardStore.Card)
        case unmoved(branch: String, head: String)
    }

    public func baseShow(root: String, from: String?, then: @escaping (Result<BaseShown, CardFailure>) -> Void) {
        let (vault, node) = (cardVault, self.root)
        work.async { [weak self] in
            // After a host restart the vault lost the head: the snapshot's, marked unverified (E8).
            let shown = BaseMoveStore.show(root: root, from: from, vault: vault, snapshotHeads: AcceptedSnapshot.load(root: node).projects[root]?.heads ?? [:])
            guard let self else { return }
            self.queue.async {
                switch shown {
                case .failure(let refusal): then(.failure(.refused(refusal.description)))
                case .success(let shown):
                    let unmoved = shown.unmoved
                    // The same move shown again (each `approve` asks, and so does a second `base show`): its open card,
                    // not another one closing it (cards don't pile up, the 1.4 MB incident's class).
                    if !unmoved, let same = self.cards.list(project: NodeIds.project(root: root)).first(where: {
                        $0.isOpen && $0.kind == .baseMove && $0.base?.branch == shown.branch && $0.base?.to == shown.to && $0.base?.from == shown.from
                    }) {
                        return then(.success(.card(same)))
                    }
                    // A base where the vault recorded it settles every open base card of the folder (a look's too: its
                    // move ended where the head is recorded now); a new card supersedes the shown ones.
                    for old in self.cards.list(project: NodeIds.project(root: root)) where old.kind == .baseMove && (unmoved || old.base?.move == nil) {
                        self.cards.change(old.id) { $0.closed = unmoved ? "the base is where the vault recorded it" : "superseded by a newer card" }
                    }
                    if unmoved { return then(.success(.unmoved(branch: shown.branch, head: shown.to))) }
                    var card = CardStore.Card(root: root, kind: .baseMove)
                    card.base = shown
                    self.cards.put(card)
                    then(.success(.card(card)))
                }
            }
        }
    }

    /// `base accept CARD`: the head the vault records is where the card showed the base (`setHead`, the commits shown and
    /// no further). From any thread.
    public func baseAccept(card id: String, then: @escaping (Result<WireKinds.BaseAccept.Result, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], let shown = card.base else { return then(.failure(.gone("no base card \(id)"))) }
            let root = card.root
            let node = self.root
            if let move = shown.move {
                return baseMoves.accept(root, move: move) { [weak self] failure in
                    guard let self else { return }
                    if let failure { return then(.failure(.refused("the vault didn't take it: \(failure)"))) }
                    self.work.async { Self.snapshotHead(move.to, branch: move.branch, root: root, node: node) }
                    then(.success(WireKinds.BaseAccept.Result(head: move.to, branch: move.branch, card: self.cards.cards[id]?.value)))
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
                    // The look's own card for this very move, if it drew one, is settled with it.
                    for other in self.cards.list(project: NodeIds.project(root: root))
                    where other.kind == .baseMove && other.base?.branch == shown.branch && other.base?.to == shown.to {
                        self.cards.change(other.id) { $0.closed = "accepted" }
                    }
                    self.note("lead: the user recorded \(shown.branch) of \(LeadMail.project(of: root)) at \(shown.to.prefix(8))")
                    then(.success(WireKinds.BaseAccept.Result(head: shown.to, branch: shown.branch, card: self.cards.cards[id]?.value)))
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
    public func baseKeep(card id: String, then: @escaping (Result<WireKinds.BaseKeep.Result, CardFailure>) -> Void) {
        queue.async { [self] in
            guard let card = cards.cards[id], let shown = card.base else { return then(.failure(.gone("no base card \(id)"))) }
            if let move = shown.move { baseMoves.keepRefused(card.root, move: move) }
            cards.change(id) { $0.closed = "kept refused" }
            then(.success(WireKinds.BaseKeep.Result(kept: true, card: cards.cards[id]?.value)))
        }
    }
}
