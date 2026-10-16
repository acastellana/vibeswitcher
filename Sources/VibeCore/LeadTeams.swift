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
