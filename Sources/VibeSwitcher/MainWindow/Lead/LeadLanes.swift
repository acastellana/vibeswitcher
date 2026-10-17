import Foundation
import VibeCore

/// What a team member's window session is doing, as the lanes read it.
struct LaneSeen: Equatable {
    /// Its session runs and so does its agent.
    var live: Bool
    var needsYou: Bool
    /// Mid-turn (or still starting).
    var working: Bool
    /// What it's doing now, while it works.
    var activity: String?
    /// What it asks, while it needs you.
    var detail: String?
    var since: Date?
}

/// A task as a pipeline lane, Plan → Work → Review → Merge: where it is now (what its sessions are doing, not only
/// the board's last word), how long it's been there and what it last did.
struct LeadLane: Identifiable, Equatable {
    enum Stage: Int, CaseIterable {
        case plan, work, review, merge

        var name: String {
            switch self {
            case .plan: return "Plan"
            case .work: return "Work"
            case .review: return "Review"
            case .merge: return "Merge"
            }
        }
    }

    enum Node: Equatable {
        case done, live, todo, failed
    }

    /// The order rows are shown in.
    enum Group: Int, Comparable, CaseIterable {
        case needsYou, live, review, queued, finished

        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    var task: LeadTask
    var id: String { task.id }
    /// One per stage, in order.
    var nodes: [Node]
    var group: Group
    /// The stage it's at (live or failed); nil when queued or finished.
    var stage: Stage?
    /// In words: "Work", "Rework 2 · Work", "Review", "Merge", "Needs you", "Failed", "Blocked", "Merged ✓", "Queued #1".
    var state: String
    /// Since when it's been in that state; nil when there's no clock to show (queued, finished).
    var since: Date?
    /// The worker's latest checkpoint.
    var checkpoint: LeadCheckpoint?
    /// What the session at the live stage is doing now.
    var activity: String?
    /// Why it's red (failed, needs you), or, while it's reworked, why it last failed.
    var problem: String?

    var isRed: Bool { nodes.contains(.failed) }

    func node(_ stage: Stage) -> Node { nodes[stage.rawValue] }

    /// The session behind a stage: the worker for Work, the verifier for Review.
    func session(for stage: Stage) -> String? {
        switch stage {
        case .work: return task.worker
        case .review: return task.verifier
        case .plan, .merge: return nil
        }
    }

    /// "Work 42m", "Rework 2 · Work 12m", "Merged ✓", "Queued #1".
    func stateText(now: Date) -> String {
        guard let since else { return state }
        return "\(state) \(Durations.compact(now.timeIntervalSince(since)))"
    }

    /// What VoiceOver reads: "<title>: Work, 42 minutes, <checkpoint>".
    func spoken(now: Date) -> String {
        var parts = [state.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: " ✓", with: "")]
        if let since { parts.append(Self.spokenDuration(now.timeIntervalSince(since))) }
        if let line = checkpoint?.text ?? activity { parts.append(line) }
        if let problem { parts.append(problem) }
        return "\(task.title): " + parts.joined(separator: ", ")
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = seconds < 60 ? [.second] : [.day, .hour, .minute]
        return formatter.string(from: max(0, seconds)) ?? ""
    }
}

enum LeadLanes {
    /// How the live stage's ring moves: it pulses, or with Reduce Motion it's a still ring.
    enum LiveRing: Equatable { case pulsing, still }

    static func liveRing(reduceMotion: Bool) -> LiveRing { reduceMotion ? .still : .pulsing }

    /// What the team's sessions are doing, by host id (the board's `worker` and `verifier`).
    static func seen(_ rows: [WindowRow], now: Date) -> [String: LaneSeen] {
        var seen: [String: LaneSeen] = [:]
        for row in rows {
            guard let id = row.hostID?.uuidString else { continue }
            let state = row.state(now: now)
            let live = LeadTeams.isLive(row, now: now)
            // A window session whose agent hasn't shown up yet is being briefed.
            let activity = row.session?.activity ?? (row.session == nil && live && state.group == .working ? "Starting…" : nil)
            seen[id] = LaneSeen(live: live, needsYou: live && state.group == .needsYou, working: live && state.group == .working,
                                activity: activity, detail: row.session?.detail, since: state.since)
        }
        return seen
    }

    /// The board's tasks as lanes, in the order shown: needs you, live, in review, queued (in start order), finished.
    static func lanes(_ board: LeadBoard, seen: [String: LaneSeen]) -> [LeadLane] {
        let queue = board.tasks.filter { $0.status == .planned }.sorted { $0.createdAt < $1.createdAt }.map(\.id)
        let lanes = board.tasks.map { task in
            lane(task, queued: queue.firstIndex(of: task.id).map { $0 + 1 }, seen: seen)
        }
        return lanes.sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            switch a.group {
            case .queued, .live: return order(a.task) < order(b.task)
            case .finished: return (a.task.since ?? a.task.createdAt) > (b.task.since ?? b.task.createdAt)
            case .needsYou, .review: return (a.since ?? .distantFuture) < (b.since ?? .distantFuture)
            }
        }
    }

    private static func order(_ task: LeadTask) -> Double { task.startedAt ?? task.createdAt }

    /// One task's lane. `queued`: its place in the queue, when it waits for a worker.
    static func lane(_ task: LeadTask, queued: Int?, seen: [String: LaneSeen]) -> LeadLane {
        let worker = task.worker.flatMap { seen[$0] }
        let verifier = task.verifier.flatMap { seen[$0] }
        let since = Date(timeIntervalSince1970: task.since ?? task.startedAt ?? task.createdAt)
        var lane = LeadLane(task: task, nodes: [.done, .todo, .todo, .todo], group: .queued, stage: nil, state: "Queued",
                            since: nil, checkpoint: task.checkpoints?.last, activity: nil, problem: nil)

        func at(_ stage: LeadLane.Stage, _ node: LeadLane.Node) {
            lane.stage = stage
            lane.nodes = LeadLane.Stage.allCases.map { $0.rawValue < stage.rawValue ? .done : $0 == stage ? node : .todo }
        }

        func red(_ stage: LeadLane.Stage, _ state: String, _ problem: String, since: Date?) {
            at(stage, .failed)
            lane.group = .needsYou
            lane.state = state
            lane.problem = problem
            lane.since = since
        }

        // A session waiting on an answer needs you, whatever the board says.
        if task.status != .done, let worker, worker.needsYou {
            red(.work, "Needs you", worker.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The worker is waiting for an answer.", since: worker.since ?? since)
            return lane
        }
        if task.status == .review, let verifier, verifier.needsYou {
            red(.review, "Needs you", verifier.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The verifier is waiting for an answer.", since: verifier.since ?? since)
            return lane
        }

        // A failed or blocked task whose worker is at work again is in Work: what's happening now, not the last verdict.
        let working = worker.map { $0.live && $0.working } ?? false
        let status: LeadTask.Status = [.failed, .blocked].contains(task.status) && working && task.worktree != nil ? .running : task.status
        // Back at work on its own (the user told it, say): the board's round count hasn't caught up yet.
        let rework = task.rework + (task.status == .failed && status == .running ? 1 : 0)

        switch status {
        case .done:
            lane.nodes = Array(repeating: .done, count: 4)
            lane.group = .finished
            lane.state = "Merged ✓"
        case .failed where task.worktree == nil && task.worker != nil:
            // Cleaned up without merging.
            lane.group = .finished
            lane.state = "Abandoned"
        case .planned:
            lane.group = .queued
            lane.state = queued.map { "Queued #\($0)" } ?? "Queued"
        case .running:
            if let worker, !worker.live {
                red(.work, "Stalled", "The worker ended without reporting.", since: worker.since ?? since)
                return lane
            }
            at(.work, .live)
            lane.group = .live
            lane.state = rework > 0 ? "Rework \(rework) · Work" : "Work"
            lane.since = since
            lane.activity = working ? worker?.activity : nil
            if rework > 0 { lane.problem = task.setback?.reason }
        case .review:
            lane.group = .review
            lane.since = since
            if task.evidence?.passes == true {
                at(.merge, .live)
                lane.state = "Merge"
                lane.activity = "Audit passed: ready to merge."
            } else if let verifier, !verifier.live, task.evidence == nil {
                red(.review, "Stalled", "The verifier ended without a verdict.", since: verifier.since ?? since)
            } else {
                at(.review, .live)
                lane.state = "Review"
                lane.activity = verifier.flatMap { $0.working ? ($0.activity ?? "Checking the branch") : nil }
                    ?? (task.verifier == nil ? "Waiting for the audit" : nil)
            }
        case .failed:
            let stage: LeadLane.Stage = task.setback?.stage == .merge ? .merge : task.setback?.stage == .review || task.evidence != nil ? .review : .work
            red(stage, "Failed", task.setback?.reason ?? task.evidence?.summary ?? "It failed; the lead decides what next.", since: since)
        case .blocked:
            red(.work, "Blocked", task.blocker ?? "Blocked: waiting on something.", since: since)
        }
        return lane
    }

    /// An ended worker or verifier of a merged or abandoned task: the lead's history, not the list's. The host is
    /// told to forget these (see `LeadController`); until it has, the team folding leaves them out.
    static func isHistory(_ row: WindowRow, boards: [String: LeadBoard], now: Date) -> Bool {
        guard let cwd = row.cwd, !LeadTeams.isLive(row, now: now), let root = LeadTeams.root(ofWorktree: cwd),
              let slug = LeadTeams.task(ofWorktree: cwd), let task = boards[(root as NSString).standardizingPath]?.task(slug) else { return false }
        return LeadTeams.isFinished(task)
    }

    /// The lead row's "team: 1 needs you · 2 working · 1 in review · 3 queued", from the board's tasks as their lanes
    /// read them (a worker that hasn't begun is queued or starting, never idle).
    static func summary(_ lanes: [LeadLane]) -> String {
        var counts: [LeadLane.Group: Int] = [:]
        for lane in lanes { counts[lane.group, default: 0] += 1 }
        var parts: [String] = []
        if let count = counts[.needsYou] { parts.append(count == 1 ? "1 needs you" : "\(count) need you") }
        if let count = counts[.live] { parts.append("\(count) working") }
        if let count = counts[.review] { parts.append("\(count) in review") }
        if let count = counts[.queued] { parts.append("\(count) queued") }
        return parts.isEmpty ? "team: none running" : "team: " + parts.joined(separator: " · ")
    }
}
