import Foundation

/// One member of a team task (`LeadTask.team`; see docs/process/reviews/team-on-one-task-design.md, "The unit"): a
/// named part of the task's one contract, worked by its own worker in its own worktree on its own branch. Member 1 is
/// the integrator: it works in the task's usual worktree on `agent/<slug>` and takes the others' parts into it.
public struct LeadTeamMember: Codable, Equatable, Sendable {
    /// Its name in the team, as posts address it (`@name`) and its branch and folder carry it (`LeadTeam.nameProblem`).
    public var name: String
    /// Its part of the task: what it owns (its files, its piece of the contract), in the lead's words.
    public var part: String
    /// The session host's id of the worker running it; nil until one is started (or after it ended).
    public var worker: String?
    /// Its branch: `agent/<slug>` for the integrator, `agent/<slug>--<name>` for the others (`LeadTeam.branch`).
    public var branch: String
    /// Its worktree: the task's own for the integrator, `.vibeswitcher/worktrees/<slug>--<name>` for the others
    /// (`LeadTeam.worktree`).
    public var worktree: String
    /// How many of the team wall's posts it has been delivered (its cursor on the wall); nil: none yet.
    public var wallSeen: Int?
    /// The tests its worker was last told the base is red on, as `LeadTask.mainRedTold` is for a plain task's worker;
    /// nil: told it's green again, or never told.
    public var mainRedTold: [String]?

    public init(name: String, part: String, worker: String? = nil, branch: String, worktree: String,
                wallSeen: Int? = nil, mainRedTold: [String]? = nil) {
        self.name = name
        self.part = part
        self.worker = worker
        self.branch = branch
        self.worktree = worktree
        self.wallSeen = wallSeen
        self.mainRedTold = mainRedTold
    }
}

/// The team-task model's rules: how many members, which names, and each member's branch and worktree. Model only:
/// nothing here starts a member or makes a worktree.
public enum LeadTeam {
    /// A team has 2 to 4 members: one is a plain task, more than 4 is more coordination than parallel work.
    public static let sizes = 2...4
    /// The longest member name: it ends up in a branch and a folder next to the slug.
    public static let longestName = 16
    /// What joins the slug and a member's name. `Slug.make` never makes a "--", and names may not hold one, so
    /// `<slug>--<name>` can't be another task's slug or another member's; and a ref can't be both `agent/<slug>` and
    /// `agent/<slug>/<name>`, hence no "/".
    public static let joiner = "--"

    /// Why the team is refused, in words the lead can act on.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var text: String
        public var description: String { text }
    }

    /// Why `name` can't be a member's name, or nil when it can. A name is lowercase ASCII letters, digits and single
    /// hyphens, starts with a letter, doesn't end with a hyphen, and is at most `longestName` characters: safe as part
    /// of a git ref (no "..", "@{", ".lock", spaces or control characters) and of a folder name (no "/", no leading
    /// dot), and free of `joiner`.
    public static func nameProblem(_ name: String) -> String? {
        guard !name.isEmpty else { return "a member's name is empty" }
        guard name.count <= longestName else { return "member name \"\(name)\" is longer than \(longestName) characters" }
        guard !name.contains(joiner) else { return "member name \"\(name)\" holds \"\(joiner)\", which joins the slug and the name" }
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)) || scalar == "-")
        }
        guard allowed else {
            return "member name \"\(name)\" may hold only lowercase letters, digits and hyphens (it goes in a branch and a folder)"
        }
        guard let first = name.first, first.isLetter else { return "member name \"\(name)\" must start with a letter" }
        guard name.last != "-" else { return "member name \"\(name)\" must not end with a hyphen" }
        return nil
    }

    /// The branch of the member at `index` (0: the integrator) named `name` on the task `slug`.
    public static func branch(slug: String, member name: String, index: Int) -> String {
        index == 0 ? Worktrees.branch(slug) : Worktrees.branch(slug + joiner + name)
    }

    /// The worktree of the member at `index` (0: the integrator) named `name` on the task `slug`, in the repository at
    /// `root`.
    public static func worktree(root: String, slug: String, member name: String, index: Int) -> String {
        index == 0 ? Worktrees.path(root: root, slug: slug) : Worktrees.path(root: root, slug: slug + joiner + name)
    }

    /// Why `members` can't be a team, or nil when they can: 2 to 4 of them, each with a valid name (`nameProblem`), no
    /// name twice, and each member's branch and worktree the ones its place in the list gives (`branch`, `worktree`):
    /// the first is the integrator, on the task's own branch.
    public static func problem(_ members: [LeadTeamMember], slug: String, root: String) -> String? {
        guard sizes.contains(members.count) else {
            return "a team has \(sizes.lowerBound) to \(sizes.upperBound) members, not \(members.count)"
        }
        var seen: Set<String> = []
        for (index, member) in members.enumerated() {
            if let problem = nameProblem(member.name) { return problem }
            guard seen.insert(member.name).inserted else { return "member name \"\(member.name)\" is used twice" }
            let branch = branch(slug: slug, member: member.name, index: index)
            guard member.branch == branch else {
                return "member \(index + 1) (\(member.name)) is on \(member.branch), not \(branch)"
            }
            let worktree = worktree(root: root, slug: slug, member: member.name, index: index)
            guard member.worktree == worktree else {
                return "member \(index + 1) (\(member.name))'s worktree is \(member.worktree), not \(worktree)"
            }
        }
        return nil
    }

    /// The team for the task `slug` in the repository at `root`, from its parts as (name, part), the integrator first:
    /// each member with its branch and worktree, no worker yet. Throws, saying why, when they can't be a team.
    public static func make(slug: String, root: String, parts: [(name: String, part: String)]) throws -> [LeadTeamMember] {
        let members = parts.enumerated().map { index, part in
            LeadTeamMember(name: part.name, part: part.part,
                           branch: branch(slug: slug, member: part.name, index: index),
                           worktree: worktree(root: root, slug: slug, member: part.name, index: index))
        }
        if let problem = problem(members, slug: slug, root: root) { throw Refusal(text: problem) }
        return members
    }
}

extension LeadTask {
    /// It's a team task: it has members (`team`).
    public var isTeam: Bool { team?.isEmpty == false }

    /// A team task's integrator, member 1; nil for a plain task.
    public var integrator: LeadTeamMember? { team?.first }

    /// The member named `name`; nil when there's none (or it's a plain task).
    public func teamMember(_ name: String) -> LeadTeamMember? { team?.first { $0.name == name } }
}
