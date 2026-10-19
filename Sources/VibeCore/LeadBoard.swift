import Darwin
import Foundation

/// What a worker is asked to do: the bounded contract it runs and the verifier checks.
public struct LeadContract: Codable, Equatable, Sendable {
    public var goal: String
    /// Checks the result must pass (commands to run, behaviors to see).
    public var acceptance: [String]
    /// What it must not touch or do.
    public var boundaries: [String]
    /// What it should know: files, decisions, earlier evidence.
    public var context: String

    public init(goal: String, acceptance: [String], boundaries: [String], context: String) {
        self.goal = goal
        self.acceptance = acceptance
        self.boundaries = boundaries
        self.context = context
    }
}

/// The verifier's report: what it found in the worker's branch, not what the worker said.
public struct LeadEvidence: Codable, Equatable, Sendable {
    public enum Completion: String, Codable, Sendable { case complete, incomplete, blocked }
    public enum Integrity: String, Codable, Sendable { case clean, suspect, violation }
    public var completion: Completion
    public var integrity: Integrity
    public var summary: String
    public var at: Double
    /// The branch's commit the verifier looked at: only that commit may be merged on this verdict.
    public var commit: String?

    public init(completion: Completion, integrity: Integrity, summary: String, commit: String? = nil, at: Double = Date().timeIntervalSince1970) {
        self.completion = completion
        self.integrity = integrity
        self.summary = summary
        self.commit = commit
        self.at = at
    }

    public var passes: Bool { completion == .complete && integrity == .clean }
}

/// A milestone a worker noted with its `progress` tool.
public struct LeadCheckpoint: Codable, Equatable, Sendable {
    public var text: String
    public var at: Double

    public init(text: String, at: Double = Date().timeIntervalSince1970) {
        self.text = text
        self.at = at
    }
}

/// Why a task last failed: an audit that didn't pass, or a merge that conflicted or failed its tests. Kept when the
/// task goes back to work, so what's being reworked stays in view.
public struct LeadSetback: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case review, merge }
    public var stage: Stage
    public var reason: String
    /// The verdict, when an audit failed it.
    public var evidence: LeadEvidence?
    public var at: Double

    public init(stage: Stage, reason: String, evidence: LeadEvidence? = nil, at: Double = Date().timeIntervalSince1970) {
        self.stage = stage
        self.reason = reason
        self.evidence = evidence
        self.at = at
    }
}

/// What a merge put on the lead's branch.
public struct LeadMergeRecord: Codable, Equatable, Sendable {
    public var commit: String
    /// The test command ran on it and passed (false: there was none, so nothing ran).
    public var tested: Bool
    public var at: Double

    public init(commit: String, tested: Bool, at: Double = Date().timeIntervalSince1970) {
        self.commit = commit
        self.tested = tested
        self.at = at
    }
}

public struct LeadTask: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// On the board, no worker yet.
        case planned
        /// A worker has it.
        case running
        /// The worker says it's done; the verifier checks.
        case review
        /// Verified and merged.
        case done
        /// Verified as not done (or the worker gave up); the lead decides what next.
        case failed
        /// Waiting on something (an answer, another task).
        case blocked
        /// Deliberately not merged (a decision, a note or the user holds it back, e.g. a prototype the user hasn't
        /// looked at): its work stays, merge refuses it, and nothing counts it as failed.
        case kept

        /// The order the board lists the states in: what needs the lead first. Holds every case (a test checks).
        public static let attentionOrder: [Status] = [.running, .review, .blocked, .failed, .kept, .planned, .done]
        /// Where the state sits in `attentionOrder`.
        public var attentionRank: Int { Self.attentionOrder.firstIndex(of: self) ?? Self.attentionOrder.count }
    }

    public var id: String
    public var slug: String
    public var title: String
    public var contract: LeadContract
    public var status: Status
    /// The session host's id of the worker running it.
    public var worker: String?
    public var verifier: String?
    /// The worker session the lead itself stopped (stop_worker): its end is no news to the lead.
    public var stopped: String?
    public var branch: String?
    public var worktree: String?
    /// The verdict on the commit its branch is at, as long as it's there: a report on that commit keeps it; a new
    /// commit's report moves it to `outdatedEvidence`.
    public var evidence: LeadEvidence?
    public var createdAt: Double
    // The fields below are optional: older boards have none of them.
    /// When it took its current status (`BoardStore.update` stamps every change).
    public var since: Double?
    /// When its first worker started.
    public var startedAt: Double?
    /// Rounds of work: 1 for the first worker, one more each time it goes back to work after failing (the lead
    /// messages its worker or starts a new one).
    public var attempts: Int?
    /// Why it last failed; kept through the rework.
    public var setback: LeadSetback?
    /// Why it's blocked (the worker's words, or the lead stopped it); cleared when it works again.
    public var blocker: String?
    /// The worker's milestones, oldest first.
    public var checkpoints: [LeadCheckpoint]?
    /// The worker's last "done" report.
    public var report: String?
    /// The last verdict once the worker reported on a newer commit: shown as for an older commit, never merged on;
    /// gone with the next verdict.
    public var outdatedEvidence: LeadEvidence?
    public var merged: LeadMergeRecord?
    /// When its worker asked the lead something (ask_lead) that the lead hasn't answered with a message yet.
    public var leadQuestionAt: Double?
    /// The witness's latest word that its worker stopped making progress (see `LeadStall`); cleared once it moves.
    public var stall: LeadStall?
    /// Why the lead keeps it unmerged (status kept).
    public var keptBecause: String?

    public static let keptCheckpoints = 40

    /// Rework rounds so far (0 on the first attempt).
    public var rework: Int { max(0, (attempts ?? 1) - 1) }

    public init(id: String = UUID().uuidString, slug: String, title: String, contract: LeadContract, status: Status = .planned) {
        self.id = id
        self.slug = slug
        self.title = title
        self.contract = contract
        self.status = status
        self.createdAt = Date().timeIntervalSince1970
    }
}

/// Something the lead asked you; the answer is steered back into it. The lead's questions are a queue it keeps up:
/// it can revise one (the question keeps its id, and its earlier wordings), withdraw one that no longer applies, and
/// say how much each matters.
public struct LeadQuestion: Codable, Equatable, Sendable, Identifiable {
    /// How much it matters: blocking holds up work (the Dock badge counts these), important is the default,
    /// whenever can wait.
    public enum Priority: String, Codable, Sendable, CaseIterable, Comparable {
        case blocking, important, whenever

        var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: Priority, b: Priority) -> Bool { a.rank < b.rank }
    }

    /// `autoDecided`: its timer ran out unanswered and the lead went ahead with its proposal.
    public enum State: String, Sendable { case open, answered, withdrawn, autoDecided }

    /// How long a proposal's timer runs when the lead doesn't say (minutes).
    public static let defaultDecideIn = 10

    /// A wording the question had before a revision, and why it changed.
    public struct Revision: Codable, Equatable, Sendable {
        /// The wording it replaced.
        public var text: String
        public var options: [String]
        /// Why the lead changed it.
        public var note: String
        /// When it changed.
        public var at: Double

        public init(text: String, options: [String], note: String, at: Double = Date().timeIntervalSince1970) {
            self.text = text
            self.options = options
            self.note = note
            self.at = at
        }
    }

    public var id: String
    /// The current wording.
    public var text: String
    public var options: [String]
    public var answer: String?
    public var askedAt: Double
    public var answeredAt: Double?
    // The fields below are optional: older boards have none of them.
    public var priority: Priority?
    /// Why the lead asks it now.
    public var whyNow: String?
    /// Its earlier wordings, oldest first: version n's wording is `revisions[n - 1]`, the current one is the last version.
    public var revisions: [Revision]?
    /// The version the user saw when answering.
    public var answeredVersion: Int?
    public var withdrawnAt: Double?
    public var withdrawReason: String?
    /// The answer the lead proposes (one of the options), with a timer: unless you answer or hold it by `decideBy`,
    /// the lead goes ahead with it.
    public var proposal: String?
    /// The timer's length in minutes, and when it runs out: an absolute time, so it survives a relaunch.
    public var decideIn: Int?
    public var decideBy: Double?
    /// You held it: the timer stopped, and it's an ordinary open question.
    public var heldAt: Double?
    /// When the timer ran out and the lead went ahead with its proposal.
    public var autoDecidedAt: Double?

    public init(id: String = UUID().uuidString, text: String, options: [String], priority: Priority? = nil, whyNow: String? = nil,
                proposal: String? = nil, decideIn: Int? = nil, at: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.text = text
        self.options = options
        self.priority = priority
        self.whyNow = whyNow
        self.askedAt = at
        if let proposal {
            self.proposal = proposal
            self.decideIn = decideIn ?? Self.defaultDecideIn
            decideBy = at + Double(self.decideIn!) * 60
        }
    }

    /// Old questions (no priority) count as important.
    public var rank: Priority { priority ?? .important }
    /// 1 for the first wording, one more for each revision.
    public var version: Int { (revisions?.count ?? 0) + 1 }
    /// The latest revision: when the current wording came, and why.
    public var lastRevision: Revision? { revisions?.last }
    /// A withdrawn question stays withdrawn, and an auto-decided one auto-decided, even if an answer came in late.
    public var state: State {
        withdrawnAt != nil ? .withdrawn : autoDecidedAt != nil ? .autoDecided : answer != nil ? .answered : .open
    }
    /// Its timer runs: it's open, with a proposal and a deadline, and you haven't held it.
    public var isCounting: Bool { isOpen && proposal != nil && decideBy != nil && heldAt == nil }
    /// "10 min": how long its timer ran (or runs).
    public var decideInText: String { "\(decideIn ?? Self.defaultDecideIn) min" }
    public var isOpen: Bool { state == .open }
    public var short: String { String(id.prefix(8)) }

    /// The wording of a version (1-based): an earlier one from the revisions, the latest the current text.
    public func wording(_ version: Int) -> (text: String, options: [String]) {
        if let revisions, version >= 1, version <= revisions.count { return (revisions[version - 1].text, revisions[version - 1].options) }
        return (text, options)
    }

    /// When it was last asked or reworded.
    public var updatedAt: Double { lastRevision?.at ?? askedAt }

    /// What the lead is told when the timer runs out: once, when the question turns auto-decided.
    public var autoDecisionMessage: String {
        "No answer in \(decideInText): going with your proposal ‘\(proposal ?? "")’\n"
            + "That's your question \(short) “\(text)”, now recorded as your decision. Go ahead with it; if the user answers "
            + "later you'll hear."
    }

    /// The decision recorded for it when its timer runs out.
    public var autoDecision: (decision: String, why: String) {
        ("\(text) → \(proposal ?? "")",
         "The lead proposed it with a \(decideInText) timer and the user didn't answer in time, so it went ahead (question \(short))."
            + (whyNow.map { " Why it was asked: \($0)" } ?? ""))
    }

    /// Why a question can't carry a timer, if it can't: a timer is for reversible choices only, never for one that
    /// holds up work (blocking), merges a sensitive path, deletes or discards work, or reaches outside the project
    /// (publishing, pushing, sending). The words of the question, its options and why-now are checked.
    public static func timerRefusal(text: String, options: [String], whyNow: String?, priority: Priority?) -> String? {
        if priority == .blocking {
            return "No timer on a blocking question: work waits on the user's say, so silence can't mean go. Ask it without proposal and decide_in."
        }
        let words = ([text, whyNow ?? ""] + options).joined(separator: "\n")
        func found(_ patterns: [String]) -> String? {
            for pattern in patterns {
                if let range = words.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { return String(words[range]) }
            }
            return nil
        }
        let advice = "Ask it without proposal and decide_in: only reversible choices go ahead on silence."
        if let word = found([#"\bdelet\w*"#, #"\bdiscard\w*"#, #"\babandon\w*"#, #"\bwip(e|es|ed|ing)\b"#, #"\beras\w*"#,
                             #"\bpurg\w*"#, #"\bdestroy\w*"#, #"\bthrow\w* (it |them |\w+ )?away\b"#, #"\boverwrit\w*"#,
                             #"\bforce[- ]?push\w*"#, #"\bpush\w* --force\b"#, #"\breset --hard\b"#, #"\brm -\w*r"#,
                             #"\bdrop\w* (the |this |that |its |their )?(branch|work|commits?|changes|worktree|stash|table|database)"#]) {
            return "No timer on this one: it's about deleting or discarding work (“\(word)”). \(advice)"
        }
        let sensitive = #"(\.claude\b|CLAUDE(\.local)?\.md|AGENTS\.md|\.mcp\.json|\.github|\.env\b|secret|credential|password|token|private key|"#
            + #"\bauth\w*|permission|entitlement|signing|keychain|hooks?\b|settings\.json|sensitive)"#
        if words.range(of: #"\bmerg\w*"#, options: [.regularExpression, .caseInsensitive]) != nil, let word = found([sensitive]) {
            return "No timer on this one: it's about merging a sensitive path (“\(word)”). \(advice)"
        }
        if let word = found([#"\bpublish\w*"#, #"\brelease[sd]?\b"#, #"\breleasing\b"#, #"\bdeploy\w*"#, #"\bproduction\b"#, #"\bprod\b"#,
                             #"\bgit push\b"#, #"\bpush\w* (it |them |this |the \w+ )?(to )?(origin|remote|upstream|github|main)\b"#,
                             #"\bpull request"#, #"\bopen\w* a PR\b"#, #"\bupload\w*"#, #"\bsubmit\w* (it |this )?to\b"#,
                             #"\be-?mail\w*"#, #"\bslack\b"#, #"\btweet\w*"#, #"\bannounc\w*"#, #"\bpost\w* (it |this )?(to|on)\b"#,
                             #"\bsend\w* (it |this |an? \w+ )?to (the )?(users?|customers?|clients?|team|list|everyone)\b"#,
                             #"\bcustomers?\b"#, #"\bapp store\b"#, #"\bnotar\w*"#, #"\binvit\w*"#]) {
            return "No timer on this one: it reaches outside the project (“\(word)”). \(advice)"
        }
        return nil
    }
}

/// What happened to an answer (see `LeadBoard.answer`).
public enum LeadAnswerOutcome: Equatable, Sendable {
    /// Recorded; `saw` is the version the user answered, which is older than the current one when the lead revised
    /// the question meanwhile.
    case answered(LeadQuestion, saw: Int)
    /// The lead had withdrawn it; the answer is kept on it, the question stays withdrawn.
    case withdrawn(LeadQuestion)
    /// Its timer had run out and the lead went ahead with its proposal; the answer is kept on it, as a note.
    case afterAutoDecision(LeadQuestion)
    /// It was answered already (another window, the phone).
    case alreadyAnswered(LeadQuestion)
    case missing

    /// The message for the lead, if any: the answer tied to the wording the user saw.
    public func message(given text: String) -> String? {
        func clock(_ at: Double) -> String { LeadBoard.clock(at) }
        switch self {
        case .answered(let question, let saw) where saw < question.version:
            let seen = question.wording(saw)
            return "Answer to your question \(question.short), version \(saw) of \(question.version) (the user saw “\(seen.text)”, "
                + "before your revision at \(clock(question.lastRevision?.at ?? question.askedAt)) to “\(question.text)”): \(text)\n"
                + "Check it still answers the current wording; ask again (ask_user) if it doesn't."
        case .answered(let question, _):
            return "Answer to your question \(question.short) “\(question.text)”: \(text)"
        case .withdrawn(let question):
            return "The user answered your withdrawn question \(question.short) “\(question.text)” (withdrawn: \(question.withdrawReason ?? "no reason")) anyway: \(text)\n"
                + "Take it as a note; nothing waits on it."
        case .afterAutoDecision(let question):
            let proposal = question.proposal ?? ""
            let went = "The user answered your question \(question.short) “\(question.text)” after its timer ran out (no answer in "
                + "\(question.decideInText)) and you went ahead with your proposal ‘\(proposal)’"
            if text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(proposal) == .orderedSame {
                return went + ": they agree (\(text)). Nothing to change."
            }
            return went + ". They would have chosen otherwise: \(text)\n"
                + "Take it as a note: weigh changing course (it was a reversible choice), and record_decision if you do."
        case .alreadyAnswered, .missing:
            return nil
        }
    }
}

/// A result the lead wants you to see.
public struct LeadUpdate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    /// Image files (screenshots) and a branch or diff to look at.
    public var images: [String]
    public var at: Double

    public init(id: String = UUID().uuidString, title: String, body: String, images: [String] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.images = images
        self.at = Date().timeIntervalSince1970
    }
}

/// Something a worker or verifier told the lead (done, blocked, a question, a verdict), kept so the lead's status lists
/// what came in even if the message itself never reached it.
public struct LeadReport: Codable, Equatable, Sendable {
    /// Who it's from ("worker add-b", "verifier add-b").
    public var about: String
    public var text: String
    public var at: Double

    public init(about: String, text: String, at: Double = Date().timeIntervalSince1970) {
        self.about = about
        self.text = text
        self.at = at
    }

    /// The task it's about: the slug after "worker " or "verifier ".
    public var task: String? {
        let parts = about.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, ["worker", "verifier"].contains(parts[0]) else { return nil }
        return String(parts[1])
    }
}

public struct LeadBoard: Codable, Equatable, Sendable {
    /// The lead's session (host id) and agent pid, so answers and events can be steered into it.
    public var leadSession: String?
    public var leadPid: Int32?
    public var leadTTY: String?
    /// The branch the lead builds on and merges into: the one checked out when it first started here.
    public var baseBranch: String?
    public var tasks: [LeadTask] = []
    public var questions: [LeadQuestion] = []
    public var updates: [LeadUpdate] = []
    /// The latest reports for the lead, oldest first, and when its status last listed them. Optional: older boards
    /// have neither.
    public var reports: [LeadReport]?
    public var reportsSeenAt: Double?

    public static let keptReports = 50

    public init() {}

    public func task(_ id: String) -> LeadTask? { tasks.first { $0.id == id || $0.slug == id } }

    /// Keeps the witness's stalls (by task id) on the tasks, and clears the rest: a stall already noted for the same
    /// episode keeps when it was first noticed. Returns whether anything changed.
    @discardableResult
    public mutating func noteStalls(_ found: [String: LeadStall]) -> Bool {
        var changed = false
        for index in tasks.indices {
            let old = tasks[index].stall
            var new = found[tasks[index].id]
            if let old, let fresh = new, old.reason == fresh.reason, old.lastActivity == fresh.lastActivity,
               old.waitingSince == fresh.waitingSince {
                new = old
            }
            if new != old {
                tasks[index].stall = new
                changed = true
            }
        }
        return changed
    }

    /// The tasks whose workers are stalled now, the longest quiet first.
    public var stalled: [LeadTask] {
        tasks.filter { $0.stall != nil && $0.status == .running }.sorted { $0.stall!.lastActivity < $1.stall!.lastActivity }
    }
    public func taskIndex(_ id: String) -> Int? { tasks.firstIndex { $0.id == id || $0.slug == id } }

    // MARK: Questions

    /// An open question older than this (since asked or last revised) is flagged for the lead to re-check.
    public static let staleQuestion: Double = 3_600

    /// The open questions, most important first, then oldest first.
    public var openQuestions: [LeadQuestion] {
        questions.filter(\.isOpen).sorted { ($0.rank, $0.askedAt) < ($1.rank, $1.askedAt) }
    }

    /// How long a withdrawn or auto-decided question stays in the stack, collapsed, so you see it went and why.
    public static let withdrawnShown: Double = 30 * 60

    /// The "Questions for you" stack: the open questions in order, then the ones withdrawn or auto-decided lately
    /// (newest first) as collapsed lines.
    public func questionStack(now: Double = Date().timeIntervalSince1970) -> [LeadQuestion] {
        func closed(_ question: LeadQuestion) -> Double? {
            switch question.state {
            case .withdrawn: return question.withdrawnAt
            case .autoDecided: return question.autoDecidedAt
            case .open, .answered: return nil
            }
        }
        let lately = questions.filter { closed($0).map { now - $0 < Self.withdrawnShown } ?? false }
        return openQuestions + lately.sorted { (closed($0) ?? 0) > (closed($1) ?? 0) }
    }

    /// Open questions that hold up work: what the Dock badge counts.
    public var blockingQuestions: Int { questions.filter { $0.isOpen && $0.rank == .blocking }.count }

    /// The question with this id, or the one id it begins with (the lead is shown the first 8 characters).
    public func questionIndex(_ id: String) throws -> Int {
        let wanted = id.trimmingCharacters(in: .whitespaces).uppercased()
        if let exact = questions.firstIndex(where: { $0.id.uppercased() == wanted }) { return exact }
        let matches = questions.indices.filter { !wanted.isEmpty && questions[$0].id.uppercased().hasPrefix(wanted) }
        guard matches.count == 1, let index = matches.first else {
            throw BoardError(text: matches.isEmpty ? "No question \(id) on the board. The questions tool lists them."
                                                  : "\(id) begins \(matches.count) questions' ids; give more of it.")
        }
        return index
    }

    /// A `proposal` starts its timer: `decideIn` minutes (10 when nil) from `at`.
    @discardableResult
    public mutating func ask(_ text: String, options: [String], priority: LeadQuestion.Priority?, whyNow: String?,
                             proposal: String? = nil, decideIn: Int? = nil, at: Double = Date().timeIntervalSince1970) -> LeadQuestion {
        let question = LeadQuestion(text: text, options: options, priority: priority, whyNow: whyNow, proposal: proposal, decideIn: decideIn, at: at)
        questions.append(question)
        return question
    }

    /// Rewords an open question (text, options, or both), keeping its id and the wording it replaces.
    @discardableResult
    public mutating func revise(_ id: String, text: String?, options: [String]?, note: String,
                                at: Double = Date().timeIntervalSince1970) throws -> LeadQuestion {
        let index = try questionIndex(id)
        var question = questions[index]
        guard question.isOpen else { throw BoardError(text: Self.closed(question)) }
        let newText = text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? question.text
        let newOptions = options ?? question.options
        guard newText != question.text || newOptions != question.options else {
            throw BoardError(text: "That's the wording it has already; nothing changed.")
        }
        question.revisions = (question.revisions ?? []) + [LeadQuestion.Revision(text: question.text, options: question.options, note: note, at: at)]
        question.text = newText
        question.options = newOptions
        // A running timer starts again, so the new wording gets its full time; when the proposal is no longer an
        // option, or the new wording is one no timer may carry (`timerRefusal`), it becomes an ordinary question.
        if question.isCounting {
            if let proposal = question.proposal, newOptions.contains(proposal),
               LeadQuestion.timerRefusal(text: newText, options: newOptions, whyNow: question.whyNow, priority: question.priority) == nil {
                question.decideBy = at + Double(question.decideIn ?? LeadQuestion.defaultDecideIn) * 60
            } else {
                question.proposal = nil
                question.decideBy = nil
            }
        }
        questions[index] = question
        return question
    }

    /// You hold a question with a timer: the timer stops and it waits for your answer like any other.
    @discardableResult
    public mutating func hold(_ id: String, at: Double = Date().timeIntervalSince1970) throws -> LeadQuestion {
        let index = try questionIndex(id)
        guard questions[index].isOpen else { throw BoardError(text: Self.closed(questions[index])) }
        guard questions[index].isCounting else { throw BoardError(text: "Question \(questions[index].short) has no timer running.") }
        questions[index].heldAt = at
        return questions[index]
    }

    /// The questions whose timer runs out by `now`, now auto-decided: the lead goes ahead with each proposal.
    /// Each turns auto-decided once; a later call finds nothing more to do for it.
    public mutating func expire(now: Double = Date().timeIntervalSince1970) -> [LeadQuestion] {
        var expired: [LeadQuestion] = []
        for index in questions.indices where questions[index].isCounting && (questions[index].decideBy ?? .infinity) <= now {
            questions[index].autoDecidedAt = now
            expired.append(questions[index])
        }
        return expired
    }

    /// Some timer has run out by `now` (`expire` would change the board).
    public func hasExpired(now: Double = Date().timeIntervalSince1970) -> Bool {
        questions.contains { $0.isCounting && ($0.decideBy ?? .infinity) <= now }
    }

    @discardableResult
    public mutating func withdraw(_ id: String, reason: String, at: Double = Date().timeIntervalSince1970) throws -> LeadQuestion {
        let index = try questionIndex(id)
        guard questions[index].isOpen else { throw BoardError(text: Self.closed(questions[index])) }
        questions[index].withdrawnAt = at
        questions[index].withdrawReason = reason
        return questions[index]
    }

    /// The user's answer to the version of the question they saw. It's tied to that version, so when the lead
    /// revised it meanwhile the lead learns which wording was answered; a withdrawn question keeps the answer but
    /// stays withdrawn.
    public mutating func answer(_ id: String, with text: String, saw version: Int, at: Double = Date().timeIntervalSince1970) -> LeadAnswerOutcome {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return .missing }
        switch questions[index].state {
        case .answered: return .alreadyAnswered(questions[index])
        case .autoDecided where questions[index].answer != nil: return .alreadyAnswered(questions[index])
        case .open, .withdrawn, .autoDecided: break
        }
        let saw = min(max(version, 1), questions[index].version)
        questions[index].answer = text
        questions[index].answeredAt = at
        questions[index].answeredVersion = saw
        switch questions[index].state {
        case .withdrawn: return .withdrawn(questions[index])
        case .autoDecided: return .afterAutoDecision(questions[index])
        case .open, .answered: return .answered(questions[index], saw: saw)
        }
    }

    private static func closed(_ question: LeadQuestion) -> String {
        switch question.state {
        case .withdrawn: return "Question \(question.short) is withdrawn already (\(question.withdrawReason ?? "no reason"))."
        case .answered: return "The user answered question \(question.short) already: \(question.answer ?? ""). Ask a new one if you need more."
        case .autoDecided: return "Question \(question.short) is decided already: its timer ran out and you went ahead with ‘\(question.proposal ?? "")’."
        case .open: return ""
        }
    }

    /// "17:42": the local time of day.
    public static func clock(_ at: Double) -> String {
        clockFormatter.string(from: Date(timeIntervalSince1970: at))
    }

    /// Made once: the Team view draws a time on every row it shows, and making a formatter costs more than using one.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

public struct BoardError: Error, CustomStringConvertible {
    public var text: String
    public var description: String { text }
}

/// An exclusive lock on a file, across processes, taken only if free.
public final class FileLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static func attempt(_ path: String) -> FileLock? {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return FileLock(fd: fd)
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// The board on disk: `<repo>/.vibeswitcher/board.json`, with the progress log and decisions next to it.
public final class BoardStore: @unchecked Sendable {
    public let root: String
    public var folder: String { (root as NSString).appendingPathComponent(".vibeswitcher") }
    var file: String { (folder as NSString).appendingPathComponent("board.json") }
    private let local = NSLock()

    public init(root: String) { self.root = root }

    /// The board, or an empty one when there's none or it can't be read (for showing it).
    public func load() -> LeadBoard { (try? read()) ?? LeadBoard() }

    /// Only the lead the board names (`leadPid`, `leadTTY`, `leadSession`), the rest left out: what the app checks on
    /// the main thread (whom to deliver to) decodes three fields, not most of a MB of tasks and reports. A board that
    /// can't be read names none, as `load()` gives.
    public func loadLead() -> LeadBoard {
        var board = LeadBoard()
        guard let data = FileManager.default.contents(atPath: file),
              let named = try? JSONDecoder().decode(NamedLead.self, from: data) else { return board }
        board.leadPid = named.leadPid
        board.leadTTY = named.leadTTY
        board.leadSession = named.leadSession
        return board
    }

    private struct NamedLead: Decodable {
        var leadPid: Int32?
        var leadTTY: String?
        var leadSession: String?
    }

    /// The board; throws when the file is there but doesn't read (a hand edit, a newer version), so nothing
    /// writes an empty board over it.
    public func read() throws -> LeadBoard {
        if Thread.isMainThread { Self.noteReadOnMainThread() }
        guard let data = FileManager.default.contents(atPath: file) else { return LeadBoard() }
        do {
            return try JSONDecoder().decode(LeadBoard.self, from: data)
        } catch {
            throw BoardError(text: "\(file) doesn't read as a board (\(error)); fix or move it, nothing was changed.")
        }
    }

    /// How many times a board was read on the main thread, in this process. The app reads none there: a day's board
    /// is most of a MB of JSON, and decoding it there froze the window (`--board-bench` checks).
    public static var readsOnMainThread: Int {
        counter.lock()
        defer { counter.unlock() }
        return mainThreadReads
    }

    private static let counter = NSLock()
    nonisolated(unsafe) private static var mainThreadReads = 0

    private static func noteReadOnMainThread() {
        counter.lock()
        mainThreadReads += 1
        counter.unlock()
    }

    /// Reads, changes and writes the board under a lock (other processes too), atomically.
    @discardableResult
    public func update<T>(_ change: (inout LeadBoard) throws -> T) throws -> T {
        try ensureFolder()
        local.lock()
        defer { local.unlock() }
        let fd = open(file + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        var board = try read()
        let before = Dictionary(board.tasks.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        let result = try change(&board)
        // Each status change is stamped, whoever made it: how long a task has been where it is.
        let now = Date().timeIntervalSince1970
        for index in board.tasks.indices where before[board.tasks[index].id] != board.tasks[index].status {
            board.tasks[index].since = before[board.tasks[index].id] == nil ? board.tasks[index].createdAt : now
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(board).write(to: URL(fileURLWithPath: file), options: .atomic)
        return result
    }

    public func appendProgress(_ line: String) throws {
        try append("- \(Self.stamp()) \(line)\n", to: "progress.md", header: "# Progress\n\n")
    }

    /// Runs out the timers due by `now`. Each such question turns auto-decided, is recorded as the lead's decision
    /// (`appendDecision`, as record_decision writes it) and goes into the lead's reports (its status lists it even if
    /// the message never reaches it), all under the board's lock: it happens once, however many windows watch the
    /// board and across relaunches. Returns each one with the message for the lead.
    public func runTimers(now: Double = Date().timeIntervalSince1970) throws -> [(question: LeadQuestion, message: String)] {
        // Checked first without writing: this runs every few seconds.
        guard load().hasExpired(now: now) else { return [] }
        return try update { board in
            let expired = board.expire(now: now)
            for question in expired {
                try appendDecision(question.autoDecision.decision, why: question.autoDecision.why)
                board.reports = ((board.reports ?? []) + [LeadReport(about: "timer", text: question.autoDecisionMessage, at: now)])
                    .suffix(LeadBoard.keptReports)
            }
            return expired.map { ($0, $0.autoDecisionMessage) }
        }
    }

    /// A decision under a `## <date and time> <decision>` heading (one line), its reason below.
    public func appendDecision(_ decision: String, why: String) throws {
        let heading = decision.split(whereSeparator: \.isNewline).joined(separator: " ")
        try append("## \(LeadDecision.stamp(Date())) \(heading)\n\n\(why)\n\n", to: "decisions.md", header: "# Decisions\n\n")
    }

    /// The lead's decisions, oldest first. Everything that shows them reads them here, so where they're kept can
    /// change in this one place.
    public func decisions() -> [LeadDecision] {
        let path = (folder as NSString).appendingPathComponent("decisions.md")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return LeadDecision.parse(text)
    }

    /// Sets a repository up for a lead: the `.vibeswitcher` folder, kept out of git, with the workflow notes (a
    /// template the first time; yours are never overwritten). Returns the workflow file's path.
    @discardableResult
    public func prepare() throws -> String {
        try ensureFolder()
        try ensureExcluded()
        // The lead's branch: what you're on now, kept for the next leads here (switching branches later doesn't
        // move it; `base_branch:` in the workflow does).
        if try read().baseBranch == nil {
            let branch = Worktrees.currentBranch(root: root) ?? Worktrees.mainBranch(root: root)
            try update { if $0.baseBranch == nil { $0.baseBranch = branch } }
        }
        let workflow = (folder as NSString).appendingPathComponent("workflow.md")
        if !FileManager.default.fileExists(atPath: workflow) {
            try LeadWorkflow.template.write(toFile: workflow, atomically: true, encoding: .utf8)
        }
        return workflow
    }

    /// `.vibeswitcher/` in `.git/info/exclude`: ignored without changing the repo's own files.
    public func ensureExcluded() throws {
        // Where git keeps it: `.git/info/exclude`, or the main repository's when `.git` is a file (a worktree).
        let asked = Git.run(["rev-parse", "--git-path", "info/exclude"], in: root)
        let exclude = asked.ok && !asked.output.isEmpty
            ? (asked.output.hasPrefix("/") ? asked.output : (root as NSString).appendingPathComponent(asked.output))
            : (root as NSString).appendingPathComponent(".git/info/exclude")
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        guard !current.components(separatedBy: "\n").contains("/.vibeswitcher/") else { return }
        try FileManager.default.createDirectory(atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let line = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + "/.vibeswitcher/\n"
        try (current + line).write(toFile: exclude, atomically: true, encoding: .utf8)
    }

    private func ensureFolder() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private func append(_ text: String, to name: String, header: String) throws {
        try ensureFolder()
        let path = (folder as NSString).appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: path) { try header.write(toFile: path, atomically: true, encoding: .utf8) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

/// A decision the lead recorded (`record_decision`), as `decisions.md` has it.
public struct LeadDecision: Equatable, Sendable, Identifiable {
    public var at: Double
    public var text: String
    public var why: String
    public var id: String { "\(at)|\(text)" }

    public init(at: Double, text: String, why: String) {
        self.at = at
        self.text = text
        self.why = why
    }

    /// "2026-10-17 21:27:05", local time (older entries have no seconds).
    static func stamp(_ date: Date) -> String { formatter("yyyy-MM-dd HH:mm:ss").string(from: date) }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// The decisions in a `decisions.md`: each `## <stamp> <decision>` heading and the text under it.
    public static func parse(_ markdown: String) -> [LeadDecision] {
        let seconds = formatter("yyyy-MM-dd HH:mm:ss"), minutes = formatter("yyyy-MM-dd HH:mm")
        var decisions: [LeadDecision] = []
        var why: [Substring] = []
        func close() {
            guard !decisions.isEmpty else { return }
            decisions[decisions.count - 1].why = why.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            why = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("## ") else {
                why.append(line)
                continue
            }
            let words = line.dropFirst(3).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard words.count >= 2 else { continue }
            let time = String(words[1])
            guard let date = seconds.date(from: "\(words[0]) \(time)") ?? minutes.date(from: "\(words[0]) \(time)") else { continue }
            close()
            why = []
            let text = words.count > 2 ? String(words[2]).trimmingCharacters(in: .whitespaces) : ""
            decisions.append(LeadDecision(at: date.timeIntervalSince1970, text: text, why: ""))
        }
        close()
        return decisions
    }
}

/// Branch- and folder-safe names for tasks.
public enum Slug {
    public static func make(_ title: String, taken: Set<String>) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        var base = ""
        // The first few words, short enough for a branch name.
        for (index, word) in words.enumerated() {
            let next = base.isEmpty ? String(word.prefix(24)) : base + "-" + word
            guard index < 4, next.count <= 24 else { break }
            base = next
        }
        if base.isEmpty { base = "task" }
        var slug = base
        var number = 2
        while taken.contains(slug) {
            slug = "\(base)-\(number)"
            number += 1
        }
        return slug
    }
}
