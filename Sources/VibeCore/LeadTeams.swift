import Foundation

extension WindowRow {
    public var session: Session? {
        if case .agent(let session) = content { return session }
        return nil
    }

    public var hosted: HostSession? {
        if case .hosted(let session) = content { return session }
        return nil
    }

    public var cwd: String? { session?.cwd ?? hosted?.cwd }
}

/// A project lead and its team in the session list: workers and verifiers fold under their lead.
public enum LeadTeams {
    /// From the window session's label, as the lead's tools name them.
    public static func role(label: String?) -> LeadLaunch.Role? {
        guard let label else { return nil }
        if label.hasPrefix("Lead · ") { return .lead }
        if label.hasPrefix("Worker: ") { return .worker }
        if label.hasPrefix("Verifier: ") { return .verifier }
        return nil
    }

    /// The repository a worker's worktree belongs to.
    public static func root(ofWorktree path: String) -> String? {
        guard let range = path.range(of: "/.vibeswitcher/worktrees/") else { return nil }
        return String(path[..<range.lowerBound])
    }

    /// The task a worker's or verifier's worktree is for (its folder is the task's slug).
    public static func task(ofWorktree path: String) -> String? {
        guard let range = path.range(of: "/.vibeswitcher/worktrees/") else { return nil }
        return path[range.upperBound...].split(separator: "/").first.map(String.init)
    }

    /// Merged, folded into another task, abandoned, reverted, or cleaned up without merging: nothing more happens on the task.
    public static func isFinished(_ task: LeadTask) -> Bool {
        [.done, .folded, .abandoned, .reverted].contains(task.status) || (task.status == .failed && task.worktree == nil)
    }

    /// When a finished task finished: when it took its status (stamped on every change), else when it merged.
    public static func finishedAt(_ task: LeadTask) -> Double { task.since ?? task.merged?.at ?? task.createdAt }

    /// The ended workers and verifiers of `root`'s finished tasks: the lead's history, not the list's, so the app
    /// has the host forget them. Ended sessions of tasks still under way stay (why one died is worth a look).
    public static func finished(_ sessions: [HostSession], root: String, board: LeadBoard) -> [UUID] {
        let root = (root as NSString).standardizingPath
        return sessions.filter { session in
            guard !session.isLive, let role = role(label: session.label), role != .lead,
                  let owner = self.root(ofWorktree: session.cwd), (owner as NSString).standardizingPath == root,
                  let slug = task(ofWorktree: session.cwd), let task = board.task(slug) else { return false }
            return isFinished(task)
        }.map(\.id)
    }

    /// A worker or verifier of the vault's roster (see `LeadVault.RosterEntry`) whose session the host still runs:
    /// its task, and whether that task is finished (`isFinished`).
    public struct RoleSession: Equatable, Sendable {
        public var entry: LeadVault.RosterEntry
        public var session: HostSession
        public var task: LeadTask

        /// worker or verifier: what the roster says it held, or (a former one an older vault kept without it) its label.
        public var role: LeadLaunch.Role {
            entry.task == nil ? (LeadTeams.role(label: session.label) ?? entry.role) : entry.role
        }

        /// The project's folder name: "genswap".
        public var project: String { (entry.root as NSString).lastPathComponent }
        public var finishedAt: Double { LeadTeams.finishedAt(task) }
    }

    /// The live sessions of the vault's `roster` whose task, on its root's board in `boards` (by the vault's root), is
    /// finished: merged, folded, abandoned or cleaned up. Only what the vault binds to a worker's or verifier's role
    /// (now, or a `former` one) in that team, never a lead, nor a session the roster doesn't name (the user's own, or
    /// another project's): the app ends these (see `LeadController`). A former session an older vault kept without
    /// its task is matched by its worktree, in that team's repository, and its label (a worker's or a verifier's).
    public static func finishedRoles(_ roster: [LeadVault.RosterEntry], hosted: [HostSession], boards: [String: LeadBoard]) -> [RoleSession] {
        let byID = Dictionary(hosted.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return roster.compactMap { entry in
            guard entry.role != .lead, seen.insert(entry.session).inserted, let session = byID[entry.session], session.isLive,
                  let board = boards[entry.root] ?? boards[(entry.root as NSString).standardizingPath] else { return nil }
            // Whatever the roster says, never a session that runs as a lead (its label), nor the board's lead.
            guard role(label: session.label) != .lead, board.leadSession != entry.session else { return nil }
            let slug: String
            if let task = entry.task {
                slug = task
            } else {
                guard [.worker, .verifier].contains(role(label: session.label)),
                      let owner = root(ofWorktree: session.cwd), (owner as NSString).standardizingPath == (entry.root as NSString).standardizingPath,
                      let task = task(ofWorktree: session.cwd) else { return nil }
                slug = task
            }
            guard let task = board.task(slug), isFinished(task) else { return nil }
            return RoleSession(entry: entry, session: session, task: task)
        }
    }

    /// A role session of a finished task still running, idle over `strandedAfter` (see `LeadWitness.strandedText`).
    public struct Stranded: Equatable, Sendable {
        public var role: LeadLaunch.Role
        public var task: String
        public var project: String
        public var session: String
        public var idle: TimeInterval
        public var pid: Int32?
        /// Its agent's resident memory, in bytes.
        public var memory: Int64?
        public var finishedAt: Double

        public init(role: LeadLaunch.Role, task: String, project: String, session: String, idle: TimeInterval, pid: Int32?, memory: Int64?, finishedAt: Double) {
            self.role = role
            self.task = task
            self.project = project
            self.session = session
            self.idle = idle
            self.pid = pid
            self.memory = memory
            self.finishedAt = finishedAt
        }

        /// "verifier on contract-plan-task-8 (genswap): idle 14.7 h, pid 51234, 412 MB, task finished 15.0 h ago".
        public func line(now: Date) -> String {
            var parts = ["idle \(LeadTeams.hours(idle))"]
            if let pid { parts.append("pid \(pid)") }
            if let memory { parts.append(DiskSpace.text(memory)) }
            parts.append("task finished \(LeadTeams.hours(now.timeIntervalSince1970 - finishedAt)) ago")
            return "\(role.rawValue) on \(task) (\(project)): " + parts.joined(separator: ", ")
        }
    }

    /// How long a role session of a finished task may sit idle before the witness names it.
    public static let strandedAfter: TimeInterval = 3600

    /// The `finished` role sessions idle over `strandedAfter`: `idleSince` says since when each (by host session id)
    /// has been idle, nil while it's working or not known; `agent` its agent's pid and resident memory.
    public static func stranded(_ finished: [RoleSession], idleSince: (HostSession) -> Double?, agent: (HostSession) -> (pid: Int32?, memory: Int64?),
                                now: Date = Date()) -> [Stranded] {
        finished.compactMap { role in
            guard let since = idleSince(role.session), now.timeIntervalSince1970 - since >= strandedAfter else { return nil }
            let process = agent(role.session)
            return Stranded(role: role.role, task: role.task.slug, project: role.project, session: role.entry.session,
                            idle: now.timeIntervalSince1970 - since, pid: process.pid, memory: process.memory, finishedAt: role.finishedAt)
        }.sorted { ($0.project, $0.task, $0.session) < ($1.project, $1.task, $1.session) }
    }

    /// 52_920 s → "14.7 h".
    public static func hours(_ seconds: TimeInterval) -> String { String(format: "%.1f h", max(0, seconds) / 3600) }

    /// A team member is still at it: its session runs and so does its agent (or the agent is still starting, or not
    /// known to have quit: see `WindowRow.agentQuit`).
    public static func isLive(_ row: WindowRow) -> Bool {
        guard let hosted = row.hosted else { return true }
        return hosted.isLive && !row.agentQuit
    }

    /// What a worker's or verifier's row says while it waits on input: its lead answers it. "Needs you" is only ever
    /// you (a lead's question, a prompt in the lead's terminal).
    public static let waitsOnLead = "waits on lead"
    public static let waitsOnLeadLabel = "Waits on lead"

    /// "Waits on lead" where a session's state is said on its own (a pill, the popover's row), else its status's label.
    public static func label(of session: Session) -> String { session.waitsOnLead ? waitsOnLeadLabel : session.shownStatus.label }

    /// "waits on lead" where a session's state is read out on its own (VoiceOver), else its shown status's word.
    public static func word(of session: Session) -> String { session.waitsOnLead ? waitsOnLead : session.shownStatus.word.text }

    /// The roots (standardized) of the boards in `boards` with a question for the user open: their leads need you
    /// (`Session.leadAsks`).
    public static func asking(_ boards: [String: LeadBoard]) -> Set<String> {
        Set(boards.filter { !$0.value.openQuestions.isEmpty }.map { ($0.key as NSString).standardizingPath })
    }

    /// Whether `session` is the lead of one of the `asking` roots: a lead whose folder is that root.
    public static func asks(_ session: Session, asking: Set<String>) -> Bool {
        guard session.teamRole == .lead, let cwd = session.cwd, !asking.isEmpty else { return false }
        return asking.contains((cwd as NSString).standardizingPath)
    }

    /// "1 waits on lead", "2 wait on lead".
    public static func waitsOnLead(_ count: Int) -> String { count == 1 ? "1 waits on lead" : "\(count) wait on lead" }

    /// What a team member's row says: as any row, so a normal end (exit 0, or the hangup or terminate that ending a
    /// session sends: 129, 143) reads "finished" or "ended", not as an exit code (see `SessionEnd`).
    public static func state(of row: WindowRow, now: Date) -> RowState {
        row.state(now: now)
    }

    /// "team: 1 waits on lead · 2 working · 1 in review": the live members' tasks (a worker and its verifier are one
    /// task), with the board's word where it has one. Ended members aren't counted.
    public static func summary(_ team: [WindowRow], label: (WindowRow) -> String?, board: LeadBoard?, now: Date) -> String {
        var order: [String] = []
        var tasks: [String: [WindowRow]] = [:]
        for row in team where isLive(row) {
            let key = row.cwd.flatMap(task(ofWorktree:)) ?? row.id
            if tasks[key] == nil { order.append(key) }
            tasks[key, default: []].append(row)
        }
        guard !order.isEmpty else { return "team: none running" }
        // The glossary's words (`StateWord`), the board's "in review" (nil here), and a member asking its lead
        // (`waits`: never "needs you", which is only ever you).
        var counts: [StateWord?: Int] = [:]
        var waits = 0
        for key in order {
            let rows = tasks[key] ?? []
            let groups = rows.map { $0.state(now: now).group }
            let status = board?.task(key)?.status
            let word: StateWord?
            if groups.contains(.needsYou) || rows.contains(where: { $0.session?.status == .needsInput }) {
                waits += 1
                continue
            } else if status == .done {
                word = .done
            } else if status == .review || rows.contains(where: { role(label: label($0)) == .verifier }) {
                word = nil
            } else if groups.contains(.working) {
                word = .working
            } else if rows.contains(where: { $0.session?.status == .unknown || $0.state(now: now).text == StateWord.unknown.text }) {
                // Nothing to read its state from (no hook state, or no process table read since its agent should
                // have shown up): not known to be idle.
                word = .unknown
            } else {
                word = .idle
            }
            counts[word, default: 0] += 1
        }
        let parts = (waits > 0 ? [waitsOnLead(waits)] : []) + ([.working, nil, .done, .idle, .unknown] as [StateWord?]).compactMap { word -> String? in
            guard let count = counts[word] else { return nil }
            return word?.counted(count) ?? "\(count) in review"
        }
        return "team: " + parts.joined(separator: " · ")
    }

    public struct Arranged: Equatable, Sendable {
        public var sections: [WindowSection]
        /// Each lead's team, by the lead row's id.
        public var teams: [String: [WindowRow]]
        /// Team rows shown (under an unfolded lead).
        public var nested: Set<String>
    }

    /// Moves each team out of the list and under its lead (shown when the lead is in `expanded`). A team whose
    /// lead isn't listed stays where it was.
    public static func arrange(_ sections: [WindowSection], label: (WindowRow) -> String?, expanded: Set<String>) -> Arranged {
        let rows = sections.flatMap(\.rows)
        var leadByRoot: [String: String] = [:]
        for row in rows where role(label: label(row)) == .lead {
            if let cwd = row.cwd { leadByRoot[(cwd as NSString).standardizingPath] = row.id }
        }
        var teams: [String: [WindowRow]] = [:]
        var moved = Set<String>()
        for row in rows {
            guard let role = role(label: label(row)), role != .lead, let cwd = row.cwd, let root = root(ofWorktree: cwd),
                  let lead = leadByRoot[(root as NSString).standardizingPath] else { continue }
            teams[lead, default: []].append(row)
            moved.insert(row.id)
        }
        var nested = Set<String>()
        let arranged = sections.compactMap { section -> WindowSection? in
            var kept: [WindowRow] = []
            for row in section.rows where !moved.contains(row.id) {
                kept.append(row)
                if expanded.contains(row.id), let team = teams[row.id] {
                    kept += team
                    nested.formUnion(team.map(\.id))
                }
            }
            return kept.isEmpty ? nil : WindowSection(project: section.project, rows: kept)
        }
        return Arranged(sections: arranged, teams: teams, nested: nested)
    }
}
