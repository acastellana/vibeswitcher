import Foundation
import VibeCore

/// What a team member's window session is doing, as the Team view reads it.
struct MemberSeen: Equatable {
    /// Its session runs and so does its agent.
    var live: Bool
    var needsYou: Bool
    /// Mid-turn (or still starting).
    var working: Bool
    /// What it's doing now, while it works.
    var activity: String?
    /// What it asks, while it needs you.
    var detail: String?
    /// Since when it's in its current state (working, waiting).
    var since: Date?
    /// When its session (or agent) started.
    var startedAt: Date?
}

/// A task as one line of the Team view: a status mark, its title, and its state in words with how long it's been in
/// it ("Working 12m", "Rework 1 · 22m", "In review 3m", "Needs you", "Queued"), from the board and what its sessions
/// are doing now.
struct TeamRow: Identifiable, Equatable {
    /// The order rows are shown in.
    enum Group: Int, Comparable, CaseIterable {
        case needsYou, working, review, queued, finished

        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    /// The status mark: each has its own color and its own shape, so it reads without color too.
    enum Mark: CaseIterable {
        case needsYou, failed, blocked, stalled, ended, working, rework, review, merge, queued, merged, folded, kept, abandoned

        var symbol: String {
            switch self {
            case .needsYou: return "exclamationmark.triangle.fill"
            case .failed: return "xmark.octagon.fill"
            case .blocked: return "nosign"
            case .stalled: return "pause.circle.fill"
            case .ended: return "stop.circle.fill"
            case .working: return "circle.fill"
            case .rework: return "arrow.triangle.2.circlepath"
            case .review: return "diamond.fill"
            case .merge: return "checkmark.diamond.fill"
            case .queued: return "circle"
            case .merged: return "checkmark.circle.fill"
            case .folded: return "arrow.turn.down.right"
            case .kept: return "archivebox.fill"
            case .abandoned: return "minus.circle"
            }
        }

        var isRed: Bool { [.needsYou, .failed, .stalled, .ended].contains(self) }
    }

    var task: LeadTask
    var id: String { task.id }
    var group: Group
    var mark: Mark
    /// In words: "Working", "Rework 1", "In review", "Needs audit", "Ready to merge", "Needs you", "Failed", "Blocked",
    /// "Stalled", "Queued", "Merged", "Folded", "Abandoned".
    var state: String
    /// When the current stage began; nil when there's no clock to show (or nothing says when it began).
    var since: Date?
    /// The worker's latest checkpoint.
    var checkpoint: LeadCheckpoint?
    /// What the agent at work is doing now (its hooks' words).
    var activity: String?
    /// What it asks (needs you), why it's red, or, while reworked, why it last failed.
    var problem: String?
    /// The session whose agent is at work on it now: the worker, or the verifier in review.
    var agent: String?
    /// The task it's folded into (status folded): the row links to it. Nil when that task isn't on the board.
    var foldedInto: LeadTask?

    /// It has an agent at work: the line under it says what that agent is doing.
    var isLive: Bool { (group == .working || group == .review) && mark != .merge }

    /// "Folded into <title>": the dim line of a folded task, its target's title a link.
    var foldedText: String? {
        guard mark == .folded else { return nil }
        return "Folded into " + (foldedInto?.title ?? task.foldedInto ?? "another task")
    }

    /// "Working 12m", "Rework 1 · 22m", "In review 3m", "Needs you", "Queued".
    func stateText(now: Date) -> String {
        guard let since else { return state }
        let elapsed = Durations.short(now.timeIntervalSince(since))
        return mark == .rework ? "\(state) · \(elapsed)" : "\(state) \(elapsed)"
    }

    /// The dim line under the title: for a task at work, what its agent is doing (the plain-language summary, else
    /// the latest checkpoint, else the live activity); for a red one, what it asks or why.
    func line(summary: String?) -> String? {
        if mark.isRed || [.blocked, .kept, .abandoned].contains(mark) { return problem }
        if let foldedText { return foldedText }
        guard isLive else { return nil }
        return summary ?? checkpoint?.text ?? activity
    }

    /// The key its summary is cached under: the task and the agent it's about (a new worker is a new summary).
    var summaryKey: String? { agent.map { "task|\(task.id)|\($0)" } }

    /// What VoiceOver reads: "<title>: Working, 12 minutes, <line>".
    func spoken(now: Date, summary: String?) -> String {
        var parts = [state]
        if let since { parts.append(Self.spokenDuration(now.timeIntervalSince(since))) }
        if let line = line(summary: summary) { parts.append(line) }
        return "\(task.title): " + parts.joined(separator: ", ")
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        (seconds < 60 ? secondsFormatter : longerFormatter).string(from: max(0, seconds)) ?? ""
    }

    /// Made once: every row of the Team view says its time on each draw.
    private static let secondsFormatter = durationFormatter([.second])
    private static let longerFormatter = durationFormatter([.day, .hour, .minute])

    private static func durationFormatter(_ units: NSCalendar.Unit) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = units
        return formatter
    }
}

enum TeamRows {
    /// What the team's sessions are doing, by host id (the board's `worker` and `verifier`).
    static func seen(_ rows: [WindowRow], now: Date) -> [String: MemberSeen] {
        var seen: [String: MemberSeen] = [:]
        for row in rows {
            guard let id = row.hostID?.uuidString else { continue }
            let state = row.state(now: now)
            let live = LeadTeams.isLive(row)
            // A window session whose agent hasn't shown up yet is being briefed.
            let activity = row.session?.activity ?? (row.session == nil && live && state.group == .working ? "Starting…" : nil)
            let started: Date
            switch row.content {
            case .agent(let session): started = session.startedAt
            case .hosted(let info): started = info.startedAt
            }
            seen[id] = MemberSeen(live: live, needsYou: live && state.group == .needsYou, working: live && state.group == .working,
                                  activity: activity, detail: row.session?.detail, since: state.since, startedAt: started)
        }
        return seen
    }

    /// The board's tasks as rows, in the order shown: needing you (what asks you first), at work, in review, queued
    /// (in the board's planned order), finished (latest first).
    /// The host's sessions are known once any is seen (the lead's own, at least): a worker or verifier missing from
    /// them then is gone (a replaced host takes its sessions with it).
    static func rows(_ board: LeadBoard, seen: [String: MemberSeen]) -> [TeamRow] {
        let position = Dictionary(board.tasks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return board.tasks.map { row($0, seen: seen, listed: !seen.isEmpty, board: board) }.sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            switch a.group {
            case .needsYou:
                if (a.mark == .needsYou) != (b.mark == .needsYou) { return a.mark == .needsYou }
                return position[a.id, default: 0] < position[b.id, default: 0]
            case .working: return (a.task.startedAt ?? a.task.createdAt, position[a.id, default: 0]) < (b.task.startedAt ?? b.task.createdAt, position[b.id, default: 0])
            case .review: return (a.since ?? .distantFuture, position[a.id, default: 0]) < (b.since ?? .distantFuture, position[b.id, default: 0])
            case .queued: return position[a.id, default: 0] < position[b.id, default: 0]
            case .finished: return finishedAt(a.task) > finishedAt(b.task)
            }
        }
    }

    private static func finishedAt(_ task: LeadTask) -> Double { task.merged?.at ?? task.since ?? task.createdAt }

    /// When the current stage began: the board's stamp of its status, else the start of the session at work on it
    /// (the worker, the verifier), else unknown. Never when the task was made: an old board without stamps would
    /// read hours for everything.
    static func stageStart(_ task: LeadTask, session: MemberSeen?) -> Date? {
        if let since = task.since { return Date(timeIntervalSince1970: since) }
        return session?.startedAt
    }

    /// One task's row. `listed`: `seen` holds every session the host has, so a worker or verifier missing from it is
    /// gone (false: nothing is known of the missing ones). `board`: where a folded task's target is found.
    static func row(_ task: LeadTask, seen: [String: MemberSeen], listed: Bool = false, board: LeadBoard? = nil) -> TeamRow {
        let worker = task.worker.flatMap { seen[$0] }
        // With several finders, the first that hasn't submitted (one that has may end while the others work).
        let awaited = task.awaitedVerifier { seen[$0].map { !$0.live } ?? listed }
        let verifier = awaited.flatMap { seen[$0] }
        let workerGone = listed && task.worker != nil && worker == nil
        let verifierGone = listed && awaited != nil && verifier == nil
        var row = TeamRow(task: task, group: .queued, mark: .queued, state: "Queued", since: nil,
                          checkpoint: task.checkpoints?.last, activity: nil, problem: nil, agent: nil)

        func red(_ mark: TeamRow.Mark, _ state: String, _ problem: String, since: Date?) {
            row.group = .needsYou
            row.mark = mark
            row.state = state
            row.problem = problem
            row.since = since
        }

        // A session waiting on an answer needs you, whatever the board says (a finished task's is history).
        if ![.done, .folded, .abandoned].contains(task.status), let worker, worker.needsYou {
            red(.needsYou, StateWord.needsYou.label, worker.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The worker is waiting for an answer.", since: nil)
            row.agent = task.worker
            return row
        }
        if task.status == .review, let verifier, verifier.needsYou {
            red(.needsYou, StateWord.needsYou.label, verifier.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The verifier is waiting for an answer.", since: nil)
            row.agent = task.verifier
            return row
        }

        // A failed or blocked task whose worker is at work again is being reworked: what's happening now, not the
        // last verdict.
        let working = worker.map { $0.live && $0.working } ?? false
        let status: LeadTask.Status = [.failed, .blocked].contains(task.status) && working && task.worktree != nil ? .running : task.status
        // Back at work on its own (the user told it, say): the board's round count hasn't caught up yet.
        let rework = task.rework + (task.status == .failed && status == .running ? 1 : 0)

        switch status {
        case .done:
            row.group = .finished
            row.mark = .merged
            row.state = "Merged"
        case .folded:
            // Its work merges with the task it's folded into: finished with the merged ones, never failed.
            row.group = .finished
            row.mark = .folded
            row.state = "Folded"
            row.foldedInto = task.foldedInto.flatMap { board?.task($0) }
        case .abandoned:
            // Given up by the lead: finished, apart from the merged ones, never failed.
            row.group = .finished
            row.mark = .abandoned
            row.state = "Abandoned"
            row.problem = task.abandonedBecause
        case .failed where task.worktree == nil && task.worker != nil:
            // Cleaned up without merging.
            row.group = .finished
            row.mark = .abandoned
            row.state = "Abandoned"
        case .planned:
            break
        case .running:
            if let worker, !worker.live {
                red(.ended, "Worker ended", "The worker ended without reporting.", since: nil)
                return row
            }
            if workerGone {
                red(.ended, "Worker ended", "Its session is gone (the session host was replaced); the lead can start it again in its worktree.", since: nil)
                return row
            }
            // The witness saw it stop making progress, whatever its screen says: "Stalled 2h", since it last did something.
            if let stall = task.stall, worker?.live ?? false {
                let why = stall.why()
                red(.stalled, "Stalled", why.prefix(1).uppercased() + why.dropFirst() + ".", since: Date(timeIntervalSince1970: stall.lastActivity))
                row.agent = task.worker
                return row
            }
            row.group = .working
            row.mark = rework > 0 ? .rework : .working
            row.state = rework > 0 ? "Rework \(rework)" : StateWord.working.label
            row.since = stageStart(task, session: worker)
            row.activity = working ? worker?.activity : nil
            row.agent = task.worker
            if rework > 0 { row.problem = task.setback?.reason }
        case .review:
            row.group = .review
            row.since = stageStart(task, session: verifier)
            if task.evidence?.passes == true {
                row.mark = .merge
                row.state = "Ready to merge"
            } else if task.reviewLevel == .none, task.verifier == nil, task.evidence == nil, let why = task.auditNeeded {
                // Review none, but its branch touches sensitive_paths (say): merge refuses it until an audit passes.
                row.mark = .review
                row.state = "Needs audit"
                row.activity = why
            } else if task.reviewLevel == .none, task.verifier == nil, task.evidence == nil {
                // Review none: its worker's done report is what merge takes, with the merge's own test run.
                row.mark = .merge
                row.state = "Ready to merge"
            } else if let verifier, !verifier.live, task.evidence == nil {
                red(.ended, "Verifier ended", "The verifier ended without a verdict.", since: nil)
            } else if verifierGone, task.evidence == nil {
                red(.ended, "Verifier ended", "Its session is gone with no verdict (the session host was replaced); the lead audits again.", since: nil)
            } else {
                row.mark = .review
                row.state = "In review"
                row.agent = task.verifier
                row.activity = verifier.flatMap { $0.working ? ($0.activity ?? "Checking the work") : nil }
                    ?? (task.verifier == nil ? "Waiting for the audit" : nil)
                // Several finders: how many have submitted, before what one of them does.
                if let panel = task.panel, task.evidence == nil {
                    row.activity = panel.progress + (row.activity.map { " · \($0)" } ?? "")
                }
            }
        case .failed:
            if let audits = task.audits, audits.reconsider {
                // Rounds of fixes aren't landing: the lead re-plans it or asks you, rather than another round.
                red(.failed, "Reconsider", "Reconsider the approach: \(audits.reconsiderCause); the lead re-plans it or asks you.",
                    since: task.since.map(Date.init(timeIntervalSince1970:)))
            } else {
                red(.failed, "Failed", task.setback?.reason ?? task.evidence?.summary ?? "It failed; the lead decides what next.",
                    since: task.since.map(Date.init(timeIntervalSince1970:)))
            }
        case .blocked:
            red(.blocked, "Blocked", task.blocker ?? "Waiting on something.", since: task.since.map(Date.init(timeIntervalSince1970:)))
        case .kept:
            // Held back on purpose: finished for now, not failed.
            row.group = .finished
            row.mark = .kept
            row.state = "Kept"
            row.problem = task.keptBecause
        }
        return row
    }

    /// An ended worker or verifier of a finished task (merged, folded, abandoned): the lead's history, not the list's. The host is
    /// told to forget these (see `LeadController`); until it has, the team folding leaves them out.
    static func isHistory(_ row: WindowRow, boards: [String: LeadBoard], now: Date) -> Bool {
        guard let cwd = row.cwd, !LeadTeams.isLive(row), let root = LeadTeams.root(ofWorktree: cwd),
              let slug = LeadTeams.task(ofWorktree: cwd), let task = boards[(root as NSString).standardizingPath]?.task(slug) else { return false }
        return LeadTeams.isFinished(task)
    }

    /// The lead row's "team: 1 needs you · 2 working · 1 in review · 3 queued", from the board's tasks as their rows
    /// read them (a worker that hasn't begun is queued or starting, never idle).
    static func summary(_ rows: [TeamRow]) -> String {
        var counts: [TeamRow.Group: Int] = [:]
        for row in rows { counts[row.group, default: 0] += 1 }
        var parts: [String] = []
        if let count = counts[.needsYou] { parts.append(StateWord.needsYou.counted(count)) }
        if let count = counts[.working] { parts.append(StateWord.working.counted(count)) }
        if let count = counts[.review] { parts.append("\(count) in review") }
        if let count = counts[.queued] { parts.append("\(count) queued") }
        return parts.isEmpty ? "team: none running" : "team: " + parts.joined(separator: " · ")
    }

    /// "Merged (4)", "Merged (44, 3 folded) · Kept (1) · Abandoned (1)": a task folded into another counts with the
    /// merged ones (its work merges there), the number saying how many of them were folded.
    static func finishedTitle(_ finished: [TeamRow]) -> String {
        let merged = finished.filter { $0.mark == .merged }.count
        let folded = finished.filter { $0.mark == .folded }.count
        let kept = finished.filter { $0.mark == .kept }.count
        let abandoned = finished.count - merged - folded - kept
        return "Merged (\(merged + folded)\(folded > 0 ? ", \(folded) folded" : ""))" + (kept > 0 ? " · Kept (\(kept))" : "")
            + (abandoned > 0 ? " · Abandoned (\(abandoned))" : "")
    }
}

/// The lead's own decisions as the Team view shows them: a new one in full view for a couple of minutes, then fading
/// and blurring for a minute, then folded into "Earlier decisions (n)".
enum DecisionFeed {
    /// How long a new decision stays in full view, then how long it takes to fade (seconds).
    static let shown: Double = 120
    static let fade: Double = 60
    /// A decision longer than this gets a plain one-line summary.
    static let long = 80

    enum Phase: Equatable {
        case fresh
        /// Fading out: 0 just begun, 1 gone.
        case fading(Double)
        case folded
    }

    /// Where a decision is in its fade. With Reduce Motion there's no fade: it folds when its time in view is up.
    static func phase(_ decision: LeadDecision, now: Double, reduceMotion: Bool) -> Phase {
        let age = now - decision.at
        if age < shown { return .fresh }
        if reduceMotion || age >= shown + fade { return .folded }
        return .fading((age - shown) / fade)
    }

    /// How a fading decision looks: its opacity and blur radius.
    static func look(_ phase: Phase) -> (opacity: Double, blur: Double) {
        switch phase {
        case .fresh: return (1, 0)
        case .fading(let progress): return (1 - 0.8 * progress, 3 * progress)
        case .folded: return (0, 3)
        }
    }

    /// The recent decisions (newest first, with their phase) and the earlier ones (newest first).
    static func split(_ decisions: [LeadDecision], now: Double, reduceMotion: Bool) -> (recent: [(decision: LeadDecision, phase: Phase)], earlier: [LeadDecision]) {
        var recent: [(LeadDecision, Phase)] = []
        var earlier: [LeadDecision] = []
        for decision in decisions.sorted(by: { $0.at > $1.at }) {
            let phase = phase(decision, now: now, reduceMotion: reduceMotion)
            if phase == .folded { earlier.append(decision) } else { recent.append((decision, phase)) }
        }
        return (recent, earlier)
    }

    /// When the view next changes by itself: every second while one fades, else when the next one starts fading.
    static func tick(_ decisions: [LeadDecision], now: Double, reduceMotion: Bool) -> Double {
        let recent = split(decisions, now: now, reduceMotion: reduceMotion).recent
        if recent.contains(where: { if case .fading = $0.phase { return true } else { return false } }) { return 1 }
        return recent.isEmpty ? 30 : 5
    }

    static func needsSummary(_ decision: LeadDecision) -> Bool { decision.text.count > long }

    static func summaryKey(_ decision: LeadDecision) -> String { "decision|\(decision.id)" }

    /// "Decided: run overlapping tasks in parallel": the plain summary of a long one, else the decision itself.
    static func line(_ decision: LeadDecision, summary: String?) -> String {
        let text = needsSummary(decision) ? summary ?? decision.text : decision.text
        return "Decided: " + lowercasedFirst(text)
    }

    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        // "API" or "VibeSwitcher" stay as they are.
        if text.prefix { $0 != " " }.dropFirst().contains(where: \.isUppercase) { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// The Team view's Mac-wide line: the load and every project's team sessions the host lists, against this lead's
/// limits, so a lead's refusal to start workers (see `MacLoad`) is something the user can see.
struct MacLine: Equatable {
    /// "Mac: load 12.3, 5 team sessions across 2 projects".
    let text: String
    /// What VoiceOver reads: the numbers in words, who holds the sessions, and which limit holds the lead back.
    let spoken: String
    /// At or over a limit: the lead's start_worker and audit refuse now.
    let isOver: Bool

    static func make(_ sessions: [HostSession], load: Double?, workflow: LeadWorkflow) -> MacLine {
        let mac = MacLoad.count(sessions.map { ($0.label, $0.cwd, $0.isLive) }, load: load)
        return MacLine(text: mac.line, spoken: mac.spoken(threshold: workflow.loadLimit, max: workflow.macMaxSessions),
                       isOver: mac.isBusy(threshold: workflow.loadLimit) || mac.isFull(max: workflow.macMaxSessions))
    }
}
