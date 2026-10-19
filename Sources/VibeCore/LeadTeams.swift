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

    /// Merged, folded into another task, abandoned, or cleaned up without merging: nothing more happens on the task.
    public static func isFinished(_ task: LeadTask) -> Bool {
        [.done, .folded, .abandoned].contains(task.status) || (task.status == .failed && task.worktree == nil)
    }

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

    /// A team member is still at it: its session runs and so does its agent (or the agent is still starting, or not
    /// known to have quit: see `WindowRow.agentQuit`).
    public static func isLive(_ row: WindowRow) -> Bool {
        guard let hosted = row.hosted else { return true }
        return hosted.isLive && !row.agentQuit
    }

    /// What a team member's row says: as any row, so a normal end (exit 0, or the hangup or terminate that ending a
    /// session sends: 129, 143) reads "finished" or "ended", not as an exit code (see `SessionEnd`).
    public static func state(of row: WindowRow, now: Date) -> RowState {
        row.state(now: now)
    }

    /// "team: 1 needs you · 2 working · 1 in review": the live members' tasks (a worker and its verifier are one
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
        // The glossary's words (`StateWord`), and the board's "in review" (nil here).
        var counts: [StateWord?: Int] = [:]
        for key in order {
            let rows = tasks[key] ?? []
            let groups = rows.map { $0.state(now: now).group }
            let status = board?.task(key)?.status
            let word: StateWord?
            if groups.contains(.needsYou) {
                word = .needsYou
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
        let parts = ([.needsYou, .working, nil, .done, .idle, .unknown] as [StateWord?]).compactMap { word -> String? in
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
