import Foundation
import VibeCore

/// One of the lead's decisions as a board shows it (decisions.md's, `LeadDecision`), with its AI summary when it is
/// long and one came (`TeamSummaryWatch`).
public struct BoardDecision: Equatable, Sendable {
    public var id: String
    public var at: Double
    public var text: String
    public var why: String
    public var summary: String?

    public init(id: String, at: Double, text: String, why: String, summary: String? = nil) {
        self.id = id
        self.at = at
        self.text = text
        self.why = why
        self.summary = summary
    }
}

/// A lead's board as the `boards` stream and `vibeswitcher board` carry it (the parity table's gap 4): one value per
/// project, its tasks as a person reads them at a glance. What each task is (its status as the board has it), the group
/// it is shown in, its state in the Mac's Team words ("Working", "Rework 1", "Ready to merge", "Blocked"…), the one dim
/// line under it (what it waits on, why it failed, its last checkpoint), and the facts behind them: its worker's
/// session (the page links to its chat), its review, times, attempts, budget, audit and merge.
///
/// **A board is the sessions' writing** (the lead's tool server writes it, and what a worker reports lands in it), so
/// every string here is inert text: controls, format characters and the like replaced (`text`), combining marks at most
/// `marksKept` a character, each string capped in bytes of UTF-8, a blocker at most `blockerLines` lines, and at most
/// `mostTasks` tasks and `mostBytes` encoded a board (the ones that need someone first: the rest are counted in
/// `more`). No path in it is read or followed: a worktree isn't sent, and a worker's id is sent only
/// as a session id when it is a host's UUID. A finished task is sent for a day after it finished (`doneFor`), so the
/// page can show what was done today; older ones are the board's history.
///
/// The groups (`group`), in the order shown:
/// - `attention`: blocked, failed (but one cleaned up without merging), a worker the witness saw stall, a worker waiting
///   on the lead's answer. What someone has to look at.
/// - `running`: a worker at it, or its review (in review, needs audit, ready to merge).
/// - `waiting`: planned (queued, or waiting on other tasks), kept back on purpose.
/// - `done`: merged, folded, abandoned or reverted.
public enum BoardValue {
    /// The most tasks a board's value carries.
    public static let mostTasks = 150
    /// How long a finished task is still sent, in seconds.
    public static let doneFor: TimeInterval = 24 * 3600
    /// A blocker's most lines, and bytes of UTF-8.
    public static let blockerLines = 40
    public static let blockerLimit = 4000
    /// The most bytes of UTF-8 a task's title, and its dim line or checkpoint, carry.
    public static let titleBytes = 400
    public static let lineBytes = 600
    /// The most combining marks kept on one base character (a Zalgo string is a few characters of thousands of marks).
    public static let marksKept = 4
    /// The most bytes a project's whole value takes, encoded: past it, the last tasks go to `more` until it fits. Under
    /// a snapshot part's room for one entry (`NodeWire.entryBytes`, with space for its id), so a board is never withheld.
    public static let mostBytes = 240 << 10
    /// The groups, in the order shown.
    public static let groups = ["attention", "running", "waiting", "done"]
    /// The most goals a board's value carries (a lead keeps 3 to 5, at most `LeadBoard.mostOpenGoals` open).
    public static let mostGoals = 50

    /// `board`'s value for `project` (at `root`) at `now`; `refusal` instead when the board couldn't be read (it is too
    /// large, or isn't a board this build knows): the value then says so and has no tasks.
    /// `usageWaits`: the review rows waiting on the account's usage, by task id (`UsageWaits`): their state says so.
    /// `summaries`: the AI summaries' lines, by task id (`TeamSummaryWatch`): a task at work carries its own.
    /// `decisions`: the lead's latest decisions with their lines, as the engine read them (`LeadEngine.boardDecisions`):
    /// only their AI summaries are taken, for the decisions `records` holds. `records`: the lead's decisions and files
    /// under its root, read with no link followed (`BoardRecords`); the value's `decisions`, `scorecard`, `answered`,
    /// `files` and `recordsDir` are made from them and the board (2026-11-21).
    /// `workers`: how many the project runs at once (workflow.md's max_workers), what its queue's forecast runs on.
    public static func value(project: String, root: String, board: LeadBoard?, refusal: String? = nil, now: Date,
                             usageWaits: [String: ReviewUsageWait] = [:], summaries: [String: String] = [:],
                             decisions: [BoardDecision] = [], records: BoardRecords.Read = BoardRecords.Read(), workers: Int = 3) -> NodeWire.Value {
        var shown: [(group: Int, position: Int, value: NodeWire.Value)] = []
        var slugs: Set<String> = []
        // The forecast (`LeadForecast`, VibeCore's: the lead's tools say the same numbers), once a board.
        let forecast = board.map { LeadForecast.forecast($0, workers: workers, now: now.timeIntervalSince1970) }
        if let board {
            for (position, task) in board.tasks.enumerated() where slugs.insert(task.slug).inserted {
                guard let (group, value) = Self.task(task, position: position, board: board, now: now, usageWait: usageWaits[task.id],
                                                              summary: summaries[task.id], landing: forecast?.tasks[task.slug]) else { continue }
                shown.append((group, position, value))
            }
        }
        shown.sort { ($0.group, $0.position) < ($1.group, $1.position) }
        var kept = Array(shown.prefix(mostTasks))
        // The byte budget: the tasks' encoded sizes and the rest of the value's, the last tasks dropped till it fits.
        var extra = BoardRecords.fields(board: board, read: records, now: now, summaries: decisions)
        extra["goals"] = board.map { goals($0, landings: forecast?.goals ?? [:]) } ?? .array([])
        extra["score"] = forecast.map { score($0.score) } ?? .null
        var size = 2_048 + root.utf8.count + project.utf8.count + NodeWire.message(NodeWire.Value.object(extra)).count
            + kept.reduce(0) { $0 + NodeWire.message($1.value).count + 1 }
        while size > mostBytes, let last = kept.popLast() { size -= NodeWire.message(last.value).count + 1 }
        let more = shown.count - kept.count
        var counts: [String: NodeWire.Value] = [:]
        for (index, name) in groups.enumerated() { counts[name] = .int(kept.filter { $0.group == index }.count) }
        return .object([
            "project": .string(project), "root": .string(root),
            "baseBranch": board?.baseBranch.map { .string(text($0, limit: 200)) } ?? .null,
            "tasks": .array(kept.map(\.value)), "counts": .object(counts), "more": .int(more),
            "unreadable": refusal.map { .string(text($0, limit: 300)) } ?? .null,
            "allDone": board.flatMap { Self.allDone($0, now: now) } ?? .null,
        ].merging(extra) { old, _ in old })
    }

    /// One task's value and its group's place in `groups`; nil when it isn't shown (finished more than `doneFor` ago).
    /// `summary`: the AI summary's line of what its agent is doing, sent only while the task is at work (running, not
    /// waiting on a limit): what someone has to look at keeps its own line.
    static func task(_ task: LeadTask, position: Int, board: LeadBoard, now: Date, usageWait: ReviewUsageWait? = nil,
                     summary: String? = nil, landing: LeadLanding? = nil) -> (Int, NodeWire.Value)? {
        let shown = Shown(task, board: board, usageWait: usageWait)
        if shown.group == "done", now.timeIntervalSince1970 - finishedAt(task) > doneFor { return nil }
        var fields: [String: NodeWire.Value] = [
            "id": .string(text(task.id, limit: 80)), "slug": .string(text(task.slug, limit: 120)), "title": .string(text(task.title, limit: titleBytes)),
            "status": .string(task.status.rawValue), "group": .string(shown.group), "state": .string(shown.state),
            "line": shown.line.map { .string(line($0)) } ?? .null,
            "summary": summary.flatMap { shown.group == "running" && usageWait == nil ? .string(line($0)) : nil } ?? .null,
            "blocker": task.status == .blocked ? task.blocker.map { .string(text($0, limit: blockerLimit, lines: blockerLines)) } ?? .null : .null,
            "worker": session(task.worker), "verifier": session(task.verifier),
            "review": .string(task.reviewLevel.rawValue), "position": .int(position),
            "createdAt": date(task.createdAt), "since": date(task.since), "startedAt": date(task.startedAt),
            "attempts": .int(max(1, task.attempts ?? 1)),
            "budgetMin": task.budgetMin.flatMap { $0 > 0 ? .int($0) : nil } ?? .null, "overBudget": .bool(task.overBudget != nil),
            "branch": task.branch.map { .string(text($0, limit: 200)) } ?? .null,
            "after": .array((task.after ?? []).prefix(20).map { .string(text($0, limit: 120)) }),
            "goal": task.goalID.map { .string(text($0, limit: 120)) } ?? .null,
            // Estimates (the web design's): its newest as given, where it lands, its time blocked and (merged) its time
            // to merge, whole and without the time blocked.
            "estimate": task.estimates?.last.map { estimate in
                .object(["likelyMin": .int(estimate.likelyMin), "worstMin": .int(estimate.worstMin), "at": date(estimate.at), "by": .string(estimate.by.rawValue)])
            } ?? .null,
            "forecast": Self.landing(landing ?? LeadLanding(basis: .none)),
            "blockedMin": .int(LeadTime.int(task.blockedMinutes(from: task.startedAt ?? task.createdAt, to: task.merged?.at ?? now.timeIntervalSince1970)) ?? 0),
            "actualMin": task.actualMinutes.flatMap { minutes in
                LeadTime.int(minutes.total).map { total in .object(["total": .int(total), "unblocked": .int(LeadTime.int(minutes.unblocked) ?? 0)]) }
            } ?? .null,
        ]
        fields["checkpoint"] = task.checkpoints?.last.map { .object(["text": .string(line($0.text)), "at": date($0.at)]) } ?? .null
        fields["audit"] = audit(task)
        fields["merged"] = task.merged.map { merged in
            .object(["commit": .string(text(merged.commit, limit: 40)), "at": date(merged.at), "tested": .bool(merged.tested)])
        } ?? .null
        return (groups.firstIndex(of: shown.group) ?? groups.count, .object(fields))
    }

    /// The project's goals, in their order, at most `mostGoals`: each its id, title and what done means (inert, capped:
    /// the lead wrote them), open or done, and how many of the board's tasks it has to go and finished.
    static func goals(_ board: LeadBoard, landings: [String: LeadLanding] = [:]) -> NodeWire.Value {
        .array((board.goals ?? []).prefix(mostGoals).map { goal in
            let mine = board.tasks.filter { $0.goalID == goal.id }
            return .object(["id": .string(text(goal.id, limit: 120)), "title": .string(text(goal.title, limit: titleBytes)),
                            "done": .string(text(goal.done, limit: lineBytes)), "state": .string(goal.state.rawValue),
                            "toGo": .int(mine.filter(\.unfinished).count), "finished": .int(mine.filter { !$0.unfinished }.count),
                            "forecast": landing(landings[goal.id] ?? LeadLanding(basis: .none))])
        })
    }

    /// A landing (`LeadLanding`, all estimates): likely and worst dates, its basis, on whom a blocked one waits, how far
    /// past its worst case an overdue one is, whether it is over its likely estimate, a goal's undated tasks.
    static func landing(_ landing: LeadLanding) -> NodeWire.Value {
        .object(["likely": landing.likely.map(date) ?? .null, "worst": landing.worst.map(date) ?? .null, "basis": .string(landing.basis.rawValue),
                 "waitsOn": landing.waitsOn.map { .string(text($0, limit: titleBytes)) } ?? .null,
                 "overdueMin": landing.overdueMinutes.map { .int($0) } ?? .null, "over": .bool(landing.over), "undated": .int(landing.undated)])
    }

    /// The project's estimating score (`LeadScore`): how many merges it is over, the median ratio, the share inside the
    /// worst case and the correction (each in hundredths: 180 is 1.8×, 70 is 70%), whether it was clamped, the median
    /// time to merge, and the line said.
    static func score(_ score: LeadScore) -> NodeWire.Value {
        func pct(_ value: Double) -> NodeWire.Value { LeadTime.int(value * 100).map { .int($0) } ?? .null }
        return .object(["estimated": .int(score.estimated), "ratioPct": score.ratio.map(pct) ?? .null,
                 "insideWorstPct": score.insideWorst.map(pct) ?? .null, "enough": .bool(score.isEnough),
                 "correctionPct": .int(LeadTime.int(score.correction * 100) ?? 100), "clamped": .bool(score.clamped),
                 "medianMin": score.medianMinutes.flatMap { LeadTime.int($0) }.map { .int($0) } ?? .null, "line": .string(score.line)])
    }

    /// The decisions as a board carries them: at most `LeadEngine.decisionsShown`, each its text and why (inert,
    /// capped: the lead wrote them), when it was taken, and its AI summary when a long one has one (null otherwise).
    static func decisions(_ list: [BoardDecision], limit: Int = LeadEngine.decisionsShown) -> NodeWire.Value {
        .array(list.prefix(limit).map { decision in
            .object(["id": .string(text(decision.id, limit: 300)), "at": date(decision.at), "text": .string(text(decision.text, limit: decisionBytes)),
                     "why": decision.why.isEmpty ? .null : .string(text(decision.why, limit: decisionBytes)),
                     "summary": decision.summary.map { .string(line($0)) } ?? .null])
        })
    }

    /// The board's newest all-done mark (`LeadAllDone`, the app's card) while it is a day old at most (`doneFor`): when
    /// it cleared, its summary (a headline and bullets, by the model or written), its tasks and how each ended, how
    /// many merged, its receipts summed in words (`LeadReceiptTotals.text`) and the prices they're estimated at, and
    /// whether the user has seen it (`seen`). Null for none.
    static func allDone(_ board: LeadBoard, now: Date) -> NodeWire.Value? {
        guard let mark = board.allDone?.last, now.timeIntervalSince1970 - mark.at <= doneFor else { return nil }
        return .object(allDoneFields(mark).merging(["id": .string(text(mark.id, limit: 80)), "at": .date(Date(timeIntervalSince1970: mark.at))]) { $1 })
    }

    /// An all-done mark's card as the board and the lead's chat carry it (`allDone`, `ChatValue`'s `allDone` item):
    /// its summary, tasks and how each ended, how many merged, its receipts in words and their prices' date, and
    /// whether it was seen; every string the batch's (the sessions') writing, inert and capped.
    static func allDoneFields(_ mark: LeadAllDone) -> [String: NodeWire.Value] {
        [
            "summary": mark.summary.map { summary in
                .object(["headline": .string(text(summary.headline, limit: lineBytes)),
                         "bullets": .array(summary.bullets.prefix(8).map { .string(text($0, limit: lineBytes)) }), "byModel": .bool(summary.byModel)])
            } ?? .null,
            "tasks": .array(mark.tasks.prefix(50).map { .object(["title": .string(text($0.title, limit: titleBytes)), "outcome": .string($0.outcome.rawValue)]) }),
            "merged": .int(mark.merged),
            "receipts": mark.receipts.map { .string(text($0.text, limit: lineBytes)) } ?? .null,
            "pricesAsOf": mark.receipts.map { .string(text($0.pricesAsOf, limit: 40)) } ?? .null,
            "seen": .bool(mark.seenAt != nil),
        ]
    }

    /// The most bytes of UTF-8 a decision's text, and its why, carry.
    public static let decisionBytes = 1_200

    /// Its audit as the board shows it: the last verdict (`passed`, `failed`; null while none came), its open and all
    /// findings, and its rounds. Null for a task never audited.
    static func audit(_ task: LeadTask) -> NodeWire.Value {
        let ledger = task.audits
        guard ledger != nil || task.evidence != nil else { return .null }
        let verdict: NodeWire.Value
        if let evidence = task.evidence { verdict = .string(evidence.passes ? "passed" : "failed") } else {
            verdict = ledger?.passed.map { .string($0 ? "passed" : "failed") } ?? .null
        }
        return .object(["verdict": verdict, "open": .int(ledger?.open.count ?? 0), "findings": .int(ledger?.findings.count ?? 0),
                        "rounds": .int(ledger?.rounds ?? 0)])
    }

    /// What a task's row says, from the board alone (the Mac's `TeamRow.row`, less what its sessions are doing now),
    /// and a review row's wait on the account's usage (`usageWait`, the engine's account watch).
    struct Shown {
        var group = "waiting"
        var state = "Queued"
        var line: String?

        init(_ task: LeadTask, board: LeadBoard, usageWait: ReviewUsageWait? = nil) {
            switch task.status {
            case .done:
                (group, state) = ("done", "Merged")
            case .folded:
                (group, state) = ("done", "Folded")
                line = "Folded into " + (task.foldedInto.map { board.task($0)?.title ?? $0 } ?? "another task")
            case .abandoned:
                (group, state, line) = ("done", "Abandoned", task.abandonedBecause)
            case .reverted:
                (group, state, line) = ("done", "Reverted", task.merged?.revertReason)
            case .failed where task.worktree == nil && task.worker != nil:
                (group, state) = ("done", "Abandoned")
            case .planned:
                (group, state, line) = ("waiting", "Queued", BoardValue.waitsOn(task, board: board))
            case .kept:
                (group, state, line) = ("waiting", "Kept", task.keptBecause)
            case .running:
                if let stall = task.stall, stall.showsAsStalled {
                    (group, state, line) = ("attention", "Stalled", stall.why())
                } else if task.leadQuestionAt != nil {
                    (group, state, line) = ("attention", "Waits on lead", "The worker asked the lead something.")
                } else {
                    group = "running"
                    state = task.rework > 0 ? "Rework \(task.rework)" : "Working"
                    line = task.checkpoints?.last?.text ?? (task.rework > 0 ? task.setback?.reason : nil)
                }
            case .review:
                group = "running"
                if task.evidence?.passes == true {
                    state = "Ready to merge"
                } else if task.evidence == nil, let usageWait {
                    (state, line) = (usageWait.state, usageWait.line)
                } else if task.verifier == nil, task.evidence == nil, let why = task.auditNeeded ?? task.riskRaised.map({ "Raised to audit: \($0.reason)" }) {
                    (state, line) = ("Needs audit", why)
                } else if task.reviewLevel == .none, task.verifier == nil, task.evidence == nil {
                    state = "Ready to merge"
                } else {
                    state = "In review"
                    line = task.panel.flatMap { task.evidence == nil ? $0.progress : nil } ?? (task.verifier == nil ? "Waiting for the audit" : "Checking the work")
                }
            case .failed:
                group = "attention"
                if let audits = task.audits, audits.reconsider {
                    (state, line) = ("Reconsider", "Reconsider the approach: \(audits.reconsiderCause)")
                } else {
                    (state, line) = ("Failed", task.setback?.reason ?? task.evidence?.summary ?? "It failed; the lead decides what next.")
                }
            case .blocked:
                group = "attention"
                state = "Blocked"
                line = BoardValue.waitsOn(task, board: board) ?? task.blocker
            }
        }
    }

    /// "Waits on <title>, <title>": the tasks it comes after that aren't merged yet; nil when none is left.
    static func waitsOn(_ task: LeadTask, board: LeadBoard) -> String? {
        guard let after = task.after, !after.isEmpty else { return nil }
        let open = after.prefix(20).compactMap { slug -> String? in
            guard let other = board.task(slug), other.status != .done, other.status != .folded else { return nil }
            return other.title
        }
        return open.isEmpty ? nil : "Waits on " + open.joined(separator: ", ")
    }

    static func finishedAt(_ task: LeadTask) -> Double { task.merged?.at ?? task.since ?? task.createdAt }

    /// A worker's or verifier's id as the page's session id: only a host's UUID, never anything else a board says.
    static func session(_ id: String?) -> NodeWire.Value {
        guard let id, id.count == 36, let uuid = UUID(uuidString: id) else { return .null }
        return .string(NodeIds.session(host: uuid))
    }

    /// A board's time as a date; null when it is none (not a number, before 2001, past 2100).
    static func date(_ seconds: Double?) -> NodeWire.Value {
        guard let seconds, seconds.isFinite, seconds > 978_307_200, seconds < 4_102_444_800 else { return .null }
        return .date(Date(timeIntervalSince1970: seconds))
    }

    /// The first line of `text`, inert, at most `lineBytes` bytes.
    static func line(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Self.text(first.map(String.init) ?? "", limit: lineBytes)
    }

    /// `text` as inert text: newlines kept (at most `lines` of them), a tab a space, any other control, format,
    /// separator, private-use or unassigned scalar replaced, at most `marksKept` combining marks after one base, and at
    /// most `limit` bytes of UTF-8 (cut between scalars, "…" where it was). Capped by bytes, not characters: one
    /// character can be a base with thousands of marks on it.
    static func text(_ text: String, limit: Int, lines: Int = 1) -> String {
        var kept = String.UnicodeScalarView()
        var bytes = 0
        var count = 0
        var marks = 0
        var cut = false
        func keep(_ scalar: Unicode.Scalar) -> Bool {
            let size = scalar.utf8.count
            guard bytes + size <= limit else { return false }
            bytes += size
            kept.append(scalar)
            return true
        }
        scalars: for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            var taken = scalar
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                marks += 1
                if marks > marksKept {
                    cut = true
                    continue scalars
                }
            case .control where scalar == "\n":
                marks = 0
                guard lines > 1 else {
                    taken = " "
                    break
                }
                count += 1
                if count >= lines {
                    cut = true
                    break scalars
                }
            case .control where scalar == "\t" || scalar == "\r":
                marks = 0
                taken = " "
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                marks = 0
                taken = "\u{FFFD}"
            default:
                marks = 0
            }
            guard keep(taken) else {
                cut = true
                break
            }
        }
        return cut ? String(kept) + "…" : String(kept)
    }
}
