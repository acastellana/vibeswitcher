import Foundation

/// Your own sessions apart from the workers and verifiers the project leads started: the menu bar's dots, the pill
/// and the counts are yours (a lead included); each lead's team is listed after them, under its project.
public enum SessionTeams {
    /// One project's workers and verifiers.
    public struct Team: Equatable, Sendable {
        /// The repository's folder name: "acme".
        public var project: String
        public var members: [Session]
    }

    public struct Split: Equatable, Sendable {
        /// Your own sessions, leads included, in list order.
        public var own: [Session]
        /// The teams, in the order their first member is listed.
        public var teams: [Team]

        /// `own`, then each team's members: the popover's order, what its numbers and arrow keys follow.
        public var listed: [Session] { own + teams.flatMap(\.members) }
        public var teamCount: Int { teams.reduce(0) { $0 + $1.members.count } }
    }

    /// Splits `sessions`, keeping their order within each part.
    public static func split(_ sessions: [Session]) -> Split {
        var own: [Session] = []
        var teams: [Team] = []
        for session in sessions {
            guard session.isTeamMember else {
                own.append(session)
                continue
            }
            let project = project(of: session)
            if let index = teams.firstIndex(where: { $0.project == project }) {
                teams[index].members.append(session)
            } else {
                teams.append(Team(project: project, members: [session]))
            }
        }
        return Split(own: own, teams: teams)
    }

    /// The folder a team member is told from: where its window session was started (its worktree), else the agent's
    /// cwd. Not `cwd` alone: a worker that ran `cd` into a scratch folder would lose its repository and task.
    public static func folder(of session: Session) -> String? { session.startFolder ?? session.cwd }

    /// The repository a team member works for, by its worktree ("acme" for …/acme/.vibeswitcher/worktrees/k), else
    /// its own project.
    public static func project(of session: Session) -> String {
        folder(of: session).flatMap(LeadTeams.root(ofWorktree:)).map { ($0 as NSString).lastPathComponent } ?? session.project
    }

    /// The task a team member's worktree is for ("fix-login"), nil outside a worktree.
    public static func task(of session: Session) -> String? { folder(of: session).flatMap(LeadTeams.task(ofWorktree:)) }

    /// "acme · worker fix-login": what an alert calls a team member (its worktree's task), nil for your own sessions.
    public static func name(of session: Session) -> String? {
        guard session.isTeamMember, let role = session.teamRole else { return nil }
        return "\(project(of: session)) · \(role.rawValue)" + (task(of: session).map { " \($0)" } ?? "")
    }
}
