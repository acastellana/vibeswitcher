import Foundation

/// The moment a lead's board went from open work to none, with at least one merge since the last such moment: the
/// batch of tasks that finished since, and its plain-words summary once written. Kept on the board
/// (`LeadBoard.allDone`), so a relaunch neither repeats nor loses it; the lead's chat shows it as a card.
public struct LeadAllDone: Codable, Equatable, Sendable, Identifiable {
    /// A task of the batch: its title, and how it ended.
    public struct Task: Codable, Equatable, Sendable {
        public enum Outcome: String, Codable, Sendable { case merged, folded, abandoned, reverted }
        public var slug: String
        public var title: String
        public var outcome: Outcome

        public init(slug: String, title: String, outcome: Outcome) {
            self.slug = slug
            self.title = title
            self.outcome = outcome
        }
    }

    /// What the batch did, in plain words: a headline and a few short bullets.
    public struct Summary: Codable, Equatable, Sendable {
        public var headline: String
        public var bullets: [String]
        /// Written by Claude; false: the written fallback (`BatchSummary.fallback`).
        public var byModel: Bool

        public init(headline: String, bullets: [String], byModel: Bool) {
            self.headline = headline
            self.bullets = bullets
            self.byModel = byModel
        }
    }

    public var id: String
    /// When the board cleared.
    public var at: Double
    /// From when the batch counts: the mark before it, or the last time the board was clear.
    public var since: Double
    public var tasks: [Task]
    /// nil until it's written (once, off the main thread).
    public var summary: Summary?
    /// When the user opened the lead after it (the sidebar's check goes then).
    public var seenAt: Double?
    /// Its tasks' receipts summed (`LeadReceiptTotals`); nil when none has one (marks from before receipts).
    public var receipts: LeadReceiptTotals?

    public var merged: Int { tasks.filter { $0.outcome == .merged }.count }

    public init(id: String = UUID().uuidString, at: Double, since: Double, tasks: [Task]) {
        self.id = id
        self.at = at
        self.since = since
        self.tasks = tasks
    }
}

extension LeadBoard {
    /// Some all-done card the user hasn't opened the lead since.
    public var hasUnseenAllDone: Bool { allDone?.contains { $0.seenAt == nil } == true }

    /// The user opened the lead: every all-done card is seen. Returns whether anything changed.
    @discardableResult
    public mutating func seeAllDone(at: Double = Date().timeIntervalSince1970) -> Bool {
        guard var marks = allDone, hasUnseenAllDone else { return false }
        for index in marks.indices where marks[index].seenAt == nil { marks[index].seenAt = at }
        allDone = marks
        return true
    }

    /// Stores the summary of the mark `id`, when it has none yet. Returns whether it did.
    @discardableResult
    public mutating func setAllDoneSummary(_ summary: LeadAllDone.Summary, for id: String) -> Bool {
        guard let index = allDone?.firstIndex(where: { $0.id == id }), allDone?[index].summary == nil else { return false }
        allDone?[index].summary = summary
        return true
    }
}

/// When a lead's board clears, and what the batch did in plain words: detection is pure (two board snapshots and the
/// last mark); the summary is written by headless Claude from a bounded, redacted input, or by `fallback`.
public enum BatchSummary {
    /// The marks a board keeps, the newest.
    public static let keptMarks = 30

    // MARK: Detection

    /// Finished: done, folded, abandoned or reverted (a failed task cleaned up counts as abandoned, as the board reads it). The
    /// rest (planned, running, review, blocked, kept, failed) is open work.
    public static func isClosed(_ task: LeadTask) -> Bool {
        switch task.status {
        case .done, .folded, .abandoned, .reverted: return true
        case .failed: return task.isAbandoned
        case .planned, .running, .review, .blocked, .kept: return false
        }
    }

    public static func hasOpenWork(_ board: LeadBoard) -> Bool { board.tasks.contains { !isClosed($0) } }

    /// When it took its closed state (`BoardStore.update` stamps every change).
    static func closedAt(_ task: LeadTask) -> Double { task.since ?? task.createdAt }

    static func outcome(_ task: LeadTask) -> LeadAllDone.Task.Outcome {
        switch task.status {
        case .done: return .merged
        case .folded: return .folded
        case .reverted: return .reverted
        default: return .abandoned
        }
    }

    /// From when the next batch counts: the last mark; with none yet, the last time the board was clear (the start of
    /// the last run of overlapping task lifetimes), so the first card isn't the board's whole history.
    static func batchStart(_ board: LeadBoard) -> Double {
        if let last = board.allDone?.last { return last.at }
        var start = -Double.infinity, end = -Double.infinity
        for span in board.tasks.filter(isClosed).map({ (from: min($0.createdAt, closedAt($0)), to: closedAt($0)) }).sorted(by: { $0.from < $1.from }) {
            if span.from > end { start = span.from }
            end = max(end, span.to)
        }
        return start
    }

    /// The tasks that reached a closed state since `batchStart`, in the order they did. Records the lead removed
    /// (made by mistake, never ran) are left out, as everywhere else.
    public static func batch(_ board: LeadBoard) -> [LeadTask] {
        let start = batchStart(board)
        // After the last mark; with none, from the start of the last run on (its first task's own close included).
        let after: (Double) -> Bool = board.allDone?.last == nil ? { $0 >= start } : { $0 > start }
        return board.tasks.filter { isClosed($0) && after(closedAt($0)) }.sorted { closedAt($0) < closedAt($1) }
    }

    /// The mark to make at `now`, when the board went from open work (`previous`) to none (`current`) and at least one
    /// task merged since the last mark; nil otherwise. No previous snapshot (the app just launched, relaunched or took
    /// over from an install) is no clear: the board was already as it is.
    public static func detect(previous: LeadBoard?, current: LeadBoard, now: Double, id: String = UUID().uuidString) -> LeadAllDone? {
        guard let previous, hasOpenWork(previous), !hasOpenWork(current) else { return nil }
        let tasks = batch(current)
        guard tasks.contains(where: { $0.status == .done }) else { return nil }
        var mark = LeadAllDone(id: id, at: now, since: batchStart(current),
                               tasks: tasks.map { .init(slug: $0.slug, title: $0.title, outcome: outcome($0)) })
        mark.receipts = LeadReceiptTotals(tasks)
        return mark
    }

    /// Makes the mark on `board` (the one read under the board's lock: another writer may have marked it already, and
    /// then the batch is empty) when `detect` says so. Returns it.
    @discardableResult
    public static func mark(_ board: inout LeadBoard, previous: LeadBoard?, now: Double, id: String = UUID().uuidString) -> LeadAllDone? {
        guard let mark = detect(previous: previous, current: board, now: now, id: id) else { return nil }
        board.allDone = Array(((board.allDone ?? []) + [mark]).suffix(keptMarks))
        return mark
    }

    // MARK: The summary's input

    /// The longest a title, a goal or a posted result is in the input, how many of each, and the whole input.
    public static let titleLimit = 160
    public static let goalLimit = 400
    public static let updateLimit = 500
    public static let tasksShown = 30
    public static let updatesShown = 12
    public static let inputLimit = 8_000

    /// What the summary is written from: the batch's tasks (title, goal, how it ended) and the results the lead posted
    /// since the batch began, redacted, on one line each and bounded.
    public struct Input: Equatable, Sendable {
        public struct Item: Equatable, Sendable {
            public var title: String
            public var goal: String
            public var outcome: LeadAllDone.Task.Outcome
        }

        public var project: String
        public var tasks: [Item]
        public var taskCount: Int
        public var merged: Int
        public var updates: [String]

        public var lines: [String] {
            var lines = ["Project: \(project). \(taskCount) task\(taskCount == 1 ? "" : "s") finished, \(merged) merged."]
            for task in tasks {
                let ended = task.outcome == .merged ? "" : task.outcome == .folded ? " (folded into another task)" : " (set aside, not merged)"
                lines.append("- Task: \(task.title)\(ended)" + (task.goal.isEmpty ? "" : ". Goal: \(task.goal)"))
            }
            if taskCount > tasks.count { lines.append("- (and \(taskCount - tasks.count) more tasks)") }
            if !updates.isEmpty {
                lines.append("Results the team lead posted:")
                lines += updates.map { "- \($0)" }
            }
            return lines
        }

        public var text: String { Summarizer.clip(lines.joined(separator: "\n"), BatchSummary.inputLimit) }
    }

    /// The input for `mark`: its tasks' titles and goals from `board`, and the lead's posted results since the batch
    /// began. Everything is redacted here (`Redaction.secrets`, as the briefing's input), before any model sees it.
    public static func input(_ mark: LeadAllDone, board: LeadBoard, project: String) -> Input {
        let goals = Dictionary(board.tasks.map { ($0.slug, $0.contract.goal) }, uniquingKeysWith: { first, _ in first })
        let tasks = mark.tasks.prefix(tasksShown).map { task in
            Input.Item(title: clean(task.title, titleLimit), goal: clean(goals[task.slug] ?? "", goalLimit), outcome: task.outcome)
        }
        let updates = board.updates.filter { $0.at > mark.since && $0.at <= mark.at + 60 }.suffix(updatesShown).map { update in
            clean(update.title, titleLimit) + (update.body.isEmpty ? "" : ": " + clean(update.body, updateLimit))
        }
        return Input(project: clean(project, titleLimit), tasks: Array(tasks), taskCount: mark.tasks.count, merged: mark.merged,
                     updates: Array(updates))
    }

    /// Redacted, commit hashes gone, on one line, at most `limit` characters.
    static func clean(_ text: String, _ limit: Int) -> String {
        let line = Redaction.secrets(in: text).split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacing(#/\b[0-9a-f]{7,40}\b/#, with: "").replacing(#/ {2,}/#, with: " ")
        return Summarizer.clip(line.trimmingCharacters(in: .whitespaces), limit)
    }

    // MARK: Writing it

    /// The most bullets a summary shows, and the most characters a line is.
    public static let bulletLimit = 6
    public static let lineLimit = 240

    /// The summary of `input`: Claude's (through `generate`, blocking: call it off the main thread) when `enabled`
    /// (the Team view's AI summaries), else, or when Claude gives nothing usable, `fallback`.
    public static func write(_ input: Input, tasks: [LeadAllDone.Task], enabled: Bool, generate: (String) -> String?) -> LeadAllDone.Summary {
        if enabled, let answer = generate(BatchSummaryPrompts.prompt(input)).flatMap(parse) { return answer }
        return fallback(tasks)
    }

    /// The model's answer as a headline and bullets: markdown, numbering and code marks dropped; nil without a
    /// headline and at least one bullet.
    public static func parse(_ text: String) -> LeadAllDone.Summary? {
        var headline: String?
        var bullets: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            let bullet = line.wholeMatch(of: #/(?:[-*•]|\d+[.)])\s+(.+)/#).map { String($0.1) }
            if let bullet { line = bullet }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .replacing(#/^#+\s*/#, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ").union(.whitespaces))
            guard !line.isEmpty else { continue }
            line = Summarizer.clip(line, lineLimit)
            if headline == nil { headline = line } else { bullets.append(line) }
        }
        guard let headline, !bullets.isEmpty else { return nil }
        return .init(headline: headline, bullets: Array(bullets.prefix(bulletLimit)), byModel: true)
    }

    /// The summary without a model: how many finished and merged, then the tasks' titles in plain sentences.
    public static func fallback(_ tasks: [LeadAllDone.Task]) -> LeadAllDone.Summary {
        let merged = tasks.filter { $0.outcome == .merged }.count
        let headline = tasks.count == 1 ? "The last task is finished and merged."
            : "All \(tasks.count) tasks are finished; \(merged == tasks.count ? "every one" : "\(merged)") of them merged."
        func sentence(_ task: LeadAllDone.Task) -> String {
            let title = clean(task.title, titleLimit).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            switch task.outcome {
            case .merged: return "Done: \(title)."
            case .folded: return "Done as part of another task: \(title)."
            case .abandoned: return "Set aside: \(title)."
            case .reverted: return "Merged, then reverted: \(title)."
            }
        }
        let shown = tasks.count > bulletLimit ? bulletLimit - 1 : bulletLimit
        var bullets = tasks.prefix(shown).map(sentence)
        if tasks.count > shown { bullets.append("And \(tasks.count - shown) more, listed below.") }
        return .init(headline: headline, bullets: bullets, byModel: false)
    }

    // MARK: The chat

    /// `items` with each mark placed where its board cleared: before the first item that came after it (see
    /// `ChatTimeline.place`).
    public static func place(_ marks: [LeadAllDone], in items: [ChatItem]) -> [ChatItem] {
        ChatTimeline.place(marks.map { ($0.at, .allDone($0)) }, in: items)
    }
}

/// The prompt an all-done summary is written from.
public enum BatchSummaryPrompts {
    /// The system prompt: for someone who doesn't read code.
    public static let system = """
        You tell a busy person, who doesn't read code, what their software project's AI team just finished. Use \
        simple everyday words, as you would to a friend. Never mention file names, function or class names, commit \
        ids, task ids, branch names, code, tests or technical jargon. Talk about what the person can now do or see \
        differently, and why it matters to them.
        """

    public static func prompt(_ input: BatchSummary.Input) -> String {
        """
        Every task on the board is finished. Write a short recap of the whole batch below. Answer with exactly this \
        shape and nothing else: one headline sentence on the first line, then 3 to 6 lines that each start with \
        "- " and are one short sentence on what now works differently for the user and why it matters. No heading, \
        no greeting, no other markdown.

        The work, oldest first:
        \(Redaction.secrets(in: input.text))
        """
    }
}

extension ClaudeHeadless {
    /// The all-done summary for `prompt` (see `BatchSummaryPrompts`), through the same headless Claude as the
    /// briefing, with its own system prompt and the briefing's time; nil when Claude isn't there, fails or takes too
    /// long. Blocks.
    public static func allDone(_ prompt: String) -> String? {
        let command = command(prompt: prompt, system: BatchSummaryPrompts.system)
        return run(executable: command.executable, args: command.args, timeout: briefingTimeout)
    }
}
