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
    /// The integrator's commit its branch was made from by `split`; nil until the team is split (always nil for the
    /// integrator).
    public var from: String?
    /// Its last part_done (`LeadPartHandoff`): the commit its part was done at and its handoff; nil until it reports
    /// one (and after a re-roll).
    public var handoff: LeadPartHandoff?

    public init(name: String, part: String, worker: String? = nil, branch: String, worktree: String,
                wallSeen: Int? = nil, mainRedTold: [String]? = nil, from: String? = nil, handoff: LeadPartHandoff? = nil) {
        self.name = name
        self.part = part
        self.worker = worker
        self.branch = branch
        self.worktree = worktree
        self.wallSeen = wallSeen
        self.mainRedTold = mainRedTold
        self.from = from
        self.handoff = handoff
    }
}

/// A member's part_done (docs/process/reviews/team-on-one-task-design.md, "The unit"; T7): its part passes its own
/// tests at `commit`, and a short structured handoff for the integrator, three parts and nothing free-form: what
/// changed, its caveats, and how to verify it. The integrator is told once (`told`), and take_part merges `commit`.
public struct LeadPartHandoff: Codable, Equatable, Sendable {
    /// The member's branch head the part was reported done at: what take_part merges.
    public var commit: String
    /// What changed: the files, and the interface the part provides or uses.
    public var changed: String
    /// What's stubbed, assumed or untested.
    public var caveats: String
    /// How to verify it: the exact focused test command.
    public var verify: String
    /// When it was reported (seconds since 1970).
    public var at: Double
    /// The integrator's worker it was told to (`LeadToolset.deliverParts`); nil until it was. A new integrator worker
    /// is told again.
    public var told: String?

    public init(commit: String, changed: String, caveats: String, verify: String, at: Double, told: String? = nil) {
        self.commit = commit
        self.changed = changed
        self.caveats = caveats
        self.verify = verify
        self.at = at
        self.told = told
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

// MARK: Splitting a team, and starting its members (docs/process/reviews/team-on-one-task-design.md, "The unit")

extension LeadTeam {
    /// The task and member a member's worker grant names, `<slug>--<name>` (`Worktrees.memberSlug`): a member of that
    /// task's stored team other than the integrator. Nil for anything else (a plain task's slug, the integrator's).
    public static func seat(_ id: String, in board: LeadBoard) -> (task: LeadTask, member: LeadTeamMember)? {
        guard let range = id.range(of: joiner) else { return nil }
        let slug = String(id[..<range.lowerBound]), name = String(id[range.upperBound...])
        guard let task = board.tasks.first(where: { $0.slug == slug }), let team = task.team,
              let index = team.firstIndex(where: { $0.name == name }), index > 0 else { return nil }
        return (task, team[index])
    }

    /// The team was split: its members other than the integrator were branched (`LeadTeamMember.from`, set for all of
    /// them at once).
    public static func isSplit(_ team: [LeadTeamMember]) -> Bool { team.count > 1 && team.dropFirst().contains { $0.from != nil } }

    /// The workers a board's team tasks run beside their integrators (an integrator is its task's one worker, as a
    /// plain task's is): each other member whose worker is in `live`, whatever its task's status (a member still runs
    /// while its task is blocked or stopped, and takes a place in max_workers all the same).
    public static func memberWorkers(_ board: LeadBoard, live: Set<String>) -> Int {
        board.tasks.reduce(0) { count, task in
            count + (task.team ?? []).dropFirst().filter { $0.worker.map(live.contains) ?? false }.count
        }
    }

    /// The sessions of `task`'s members other than its integrator that are still live in `sessions`.
    static func liveMembers(_ task: LeadTask, in sessions: [LeadSessionInfo]) -> [LeadSessionInfo] {
        let workers = Set((task.team ?? []).dropFirst().compactMap(\.worker))
        return sessions.filter { $0.live && workers.contains($0.id) }
    }

    /// "a (integrator), b, c".
    static func names(_ team: [LeadTeamMember]) -> String {
        team.enumerated().map { $0.offset == 0 ? "\($0.element.name) (integrator)" : $0.element.name }.joined(separator: ", ")
    }

    /// The parts the lead's `team` argument gives, as (name, part), the integrator first; nil when none was given, empty
    /// to make the task a plain one again. Refused, saying why, for any other shape.
    static func parts(_ given: Any?) throws -> [(name: String, part: String)]? {
        guard let given, !(given is NSNull) else { return nil }
        let shape = "team is a list of 2 to 4 members, each {name, part}, the integrator first (an empty list makes it a plain task). Nothing was changed."
        guard let list = given as? [Any] else { throw Refusal(text: shape) }
        return try list.map { item in
            guard let object = item as? [String: Any], let name = object["name"] as? String,
                  let part = (object["part"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !part.isEmpty else {
                throw Refusal(text: "Each team member is {name, part}, its part said (what it owns: its files, its piece of the contract). " + shape)
            }
            return (name.trimmingCharacters(in: .whitespacesAndNewlines), part)
        }
    }

    /// Sets `task`'s team from `parts` (empty: none, a plain task again) in the repository at `root`, and says what
    /// changed. Refused once the team is split, and while the task runs or is past its work (its integrator's brief was
    /// written from the team it had).
    static func set(_ parts: [(name: String, part: String)], on task: inout LeadTask, root: String) throws -> String {
        if let team = task.team, isSplit(team) {
            throw BoardError(text: "\(task.slug)'s team was split already (its members have branches), so it isn't changed. Nothing was changed.")
        }
        guard [.planned, .failed, .blocked].contains(task.status) else {
            throw BoardError(text: "\(task.slug) is \(task.status.rawValue): a team is set while the task is planned, failed or blocked, before its integrator starts. Nothing was changed.")
        }
        guard !parts.isEmpty else {
            task.team = nil
            return "team cleared (a plain task)"
        }
        do { task.team = try make(slug: task.slug, root: root, parts: parts) } catch let refusal as Refusal {
            throw BoardError(text: "Not a team: \(refusal.text). Nothing was changed.")
        }
        return "team " + names(task.team ?? [])
    }

    /// What the integrator's brief adds to a plain worker's (`LeadPrompts.worker`): its part, the other members' parts,
    /// and the team's rules, `split` first. Nil for a plain task.
    public static func integratorBrief(_ task: LeadTask) -> String? {
        guard let team = task.team, let integrator = team.first, team.count > 1 else { return nil }
        let others = team.dropFirst().map { "- \($0.name): \($0.part)" }.joined(separator: "\n")
        let split = isSplit(team)
            ? "The team is split already (at \(team.dropFirst().compactMap(\.from).first.map { String($0.prefix(8)) } ?? "?")): don't split again; the members work on their parts."
            : "Start alone: commit the shared interface the parts build on (types, stubs, hooks), then call `split`. It branches every "
                + "other member from your current commit (agent/\(task.slug)--<name>, in .vibeswitcher/worktrees/\(task.slug)--<name>), and the "
                + "lead's tools start their workers as there's room. It's refused with uncommitted changes (commit first), and a team splits once."
        return """
        Team task: you are \(integrator.name), the integrator of this task's team of \(team.count). You own the task's branch, \
        agent/\(task.slug), and its one report. Your part: \(integrator.part)
        The other members, each a worker of its own in its own worktree:
        \(others)
        Team rules: \(split) After the split, edit only your part's files: each member owns its part's. Only your report \
        counts for the task: report done once every part is in agent/\(task.slug) and the acceptance checks pass there; \
        it's refused, naming the parts not taken, until then. When a member reports its part done you're told once, with \
        its handoff: take it in with take_part(<name>) (VibeSwitcher merges its branch into yours and leaves any conflict \
        for you to resolve and commit), then run its verify command.
        """
    }

    /// What a member's brief adds to a plain worker's (`LeadPrompts.worker`): its own part only, the integrator's name,
    /// and the team's rules. The other members' parts aren't in it: the task's contract is all it shares with them.
    public static func memberBrief(_ task: LeadTask, member: LeadTeamMember) -> String {
        let integrator = task.integrator?.name ?? "member 1"
        let from = member.from.map { " \($0.prefix(8))" } ?? ""
        return """
        Team task: you are \(member.name), a member of this task's team; \(integrator) is its integrator and owns \
        agent/\(task.slug). Your part, and only yours: \(member.part)
        Team rules: work only on your part's files, on your branch \(member.branch) in this worktree. The other members work \
        on theirs beside you, each in its own worktree, so edit nothing outside your part. Your branch was made from the \
        integrator's commit\(from), which holds the shared interface: if your part needs a change to it, ask_lead. The \
        contract below is the whole team's: its acceptance checks run on the integrated branch, not on yours. Only \
        \(integrator) reports done for the task: once your part passes its own tests and everything's committed, call \
        report(status: part_done) with its handoff (changed: the files, and the interface your part provides or uses; \
        caveats: what's stubbed, assumed or untested; verify: the exact focused test command), and \(integrator) takes it \
        in. report blocked or over_budget as any worker: they reach the lead, naming you.
        """
    }

    /// `task` after a re-roll: no member runs or was branched any more, so its fresh integrator splits again.
    static func reset(_ task: inout LeadTask) {
        guard let team = task.team else { return }
        task.team = team.map { member in
            var member = member
            member.worker = nil
            member.from = nil
            member.wallSeen = nil
            member.mainRedTold = nil
            member.handoff = nil
            return member
        }
    }
}

extension LeadToolset {
    /// The integrator's tool (`tools`, a team task's integrator only).
    static let splitTool = MCPToolInfo(
        name: "split",
        description: "Team task, integrator only: once the shared interface is committed, branch every other member of your team from your current commit "
            + "(each on agent/<task>--<name>, in a worktree of its own); the lead's tools then start their workers as max_workers and the Mac's limits "
            + "allow (one without room starts once there's room). Members run on Claude. Refused with uncommitted changes in your worktree, and once the team is split.")

    /// What a worker has beyond a plain worker's tools: on a team task, the wall's `post` and `wall`, and `split` for
    /// its integrator. Never a verifier's: it has no tool for the wall.
    var teamTools: [MCPToolInfo] {
        guard role == .worker, wallSeat() != nil else { return [] }
        return (memberSeat() == nil ? [Self.splitTool, Self.takePartTool] : []) + [Self.postTool, Self.wallTool]
    }

    /// A worker's tools, `plain` being a plain worker's: a member's `report` is its own (`memberReportTool`), and a team
    /// task's worker has `teamTools` besides.
    func workerTools(_ plain: [MCPToolInfo]) -> [MCPToolInfo] {
        let tools = memberSeat() == nil ? plain : plain.map { $0.name == "report" ? Self.memberReportTool : $0 }
        return tools + teamTools
    }

    /// This worker's place on a team task when it's a member other than the integrator (its grant is for
    /// `<slug>--<name>`); nil for any other caller.
    func memberSeat() -> (task: LeadTask, member: LeadTeamMember)? {
        guard role == .worker, let taskID else { return nil }
        return LeadTeam.seat(taskID, in: store.load())
    }

    /// A tool that's the integrator's alone on a team task (`report`, `answer_findings`), refused to a member.
    func refuseMember(_ tool: String) throws {
        guard let seat = memberSeat() else { return }
        let integrator = seat.task.integrator?.name ?? "member 1"
        throw Problem(text: "Only \(seat.task.slug)'s integrator, \(integrator), calls \(tool) for the team task; you're \(seat.member.name), a member. "
                      + "Once your part passes its own tests and everything's committed, report(status: part_done, …) with its handoff, so \(integrator) takes it in.")
    }

    /// Who asks in ask_lead's message to the lead: "The worker on x", or "Member b of x's team" (a lead's message to x
    /// reaches its integrator only, for now).
    func askerText(_ slug: String) -> (who: String, answer: String) {
        guard let seat = memberSeat() else { return ("The worker on \(slug)", "") }
        return ("Member \(seat.member.name) of \(slug)'s team", " (it reaches \(slug)'s integrator, \(seat.task.integrator?.name ?? "member 1"), who passes it on)")
    }

    /// split: the integrator branches every other member of its team from its current commit, and the lead's tools start
    /// their workers (`startMembers`; only the lead's server may start a session). One split per team, in a lock.
    func split() throws -> MCPToolResult {
        guard role == .worker, let taskID else { throw Problem(text: "Only a team task's integrator splits its team.") }
        let board = try store.read()
        if let seat = LeadTeam.seat(taskID, in: board) {
            throw Problem(text: "Not split: only \(seat.task.slug)'s integrator, \(seat.task.integrator?.name ?? "member 1"), splits the team; you're \(seat.member.name), a member.")
        }
        guard let task = board.task(taskID) else { throw Problem(text: "Your task isn't on the board any more.") }
        guard task.isTeam else { throw Problem(text: "Not split: \(task.slug) is a plain task, with no team to split into.") }
        return try exclusively("split-\(task.slug)") { try splitAlone(task.slug) }
    }

    private func splitAlone(_ slug: String) throws -> MCPToolResult {
        guard let task = try store.read().task(slug), let team = task.team, task.isTeam else { throw Problem(text: "Not split: \(slug) has no team any more.") }
        if let problem = LeadTeam.problem(team, slug: slug, root: root) {
            throw Problem(text: "Not split: \(slug)'s team as the board holds it isn't valid (\(problem)). Tell the lead with ask_lead: update_task sets it again.")
        }
        if LeadTeam.isSplit(team) {
            let at = team.dropFirst().compactMap(\.from).first.map { " at \($0.prefix(8))" } ?? ""
            throw Problem(text: "Not split: \(slug)'s team was split already\(at), and a team splits once. Its members' workers start as there's room.")
        }
        guard task.status == .running else { throw Problem(text: "Not split: \(slug) is \(task.status.rawValue), not running.") }
        let worktree = Worktrees.path(root: root, slug: slug), branch = Worktrees.branch(slug)
        guard Worktrees.isWorktree(root: root, slug: slug) else {
            throw Problem(text: "Not split: \(worktree) isn't a worktree on \(branch). Report blocked, saying so.")
        }
        let status = Git.run(["status", "--porcelain", "--untracked-files=all"], in: worktree)
        guard status.ok else { throw Problem(text: "Not split: your worktree's uncommitted changes can't be read (\(status.error)).") }
        let changes = status.output.split(separator: "\n").map(String.init)
        guard changes.isEmpty else {
            throw Problem(text: "Not split: your worktree has uncommitted changes, which the members' branches wouldn't hold: "
                          + changes.prefix(10).joined(separator: "; ") + (changes.count > 10 ? "; …" : "")
                          + ". Commit them (or move a scratch file out of the worktree), then split again.")
        }
        guard let head = branchHead(branch) else { throw Problem(text: "Not split: \(branch) has no commit.") }
        // Each member's branch and worktree; the ones made here go again if one can't be made, so a retry starts clean.
        var made: [LeadTeamMember] = []
        do {
            for member in team.dropFirst() {
                let there = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(member.branch)"], in: root).ok
                    || (try? FileManager.default.attributesOfItem(atPath: member.worktree)) != nil
                try Worktrees.createMember(root: root, slug: slug, member: member.name, from: head)
                if !there { made.append(member) }
            }
        } catch {
            for member in made {
                Git.run(["worktree", "remove", "--force", member.worktree], in: root)
                Git.run(["branch", "-D", member.branch], in: root)
            }
            throw Problem(text: "Not split: \(error). No member was branched.")
        }
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            for at in stride(from: 1, to: board.tasks[index].team?.count ?? 0, by: 1) { board.tasks[index].team?[at].from = head }
        }
        let names = team.dropFirst().map(\.name).joined(separator: ", ")
        try? store.appendProgress("Split \(slug) at \(head.prefix(8)): \(names) branched from its integrator's commit")
        let auto = advances(slug)
        _ = try? tellLead("\(slug)'s integrator split its team at \(head.prefix(8)): \(names) branched from it. "
                          + (auto ? "auto_advance starts their workers as max_workers and the Mac allow."
                             : "Start their workers with start_worker(\(slug)) (auto_advance doesn't, for it)."), about: "worker \(slug)")
        LeadAdvance.nudge(root: root)
        return MCPToolResult(text: "Split \(slug) at \(head.prefix(8)): \(names) each have a branch and a worktree from it. The lead's tools start their workers "
                             + "as max_workers and the Mac's limits allow; one without room starts once there's room. Go on with your part, and edit nothing of theirs.")
    }

    /// start_worker on a split team task whose integrator runs: starts its members whose worker doesn't run, one at a
    /// time, each only while max_workers (live members count) and the Mac's limits leave room; the rest stay queued,
    /// named, and start on a later start_worker or auto_advance pass. Members run on Claude, whatever the task's agent.
    /// Nil when `task` isn't such a task: start_worker then starts (or refuses) its integrator as for any task.
    /// `neverStarted` (auto_advance): only members no worker was started for; one whose worker ended is the lead's.
    /// Called holding start_worker's lock.
    func startMembers(_ task: LeadTask, sessions: [LeadSessionInfo], overrideUsage: Bool, neverStarted: Bool = false) throws -> MCPToolResult? {
        guard let team = task.team, task.isTeam, LeadTeam.isSplit(team), task.status == .running,
              let integrator = task.worker, sessions.contains(where: { $0.id == integrator && $0.live }) else { return nil }
        let slug = task.slug
        if let problem = LeadTeam.problem(team, slug: slug, root: root) {
            throw Problem(text: "No member of \(slug) started: its team as the board holds it isn't valid (\(problem)). Tell the user.")
        }
        let pending = team.dropFirst().filter { member in
            member.worker.map { id in !neverStarted && !sessions.contains { $0.id == id && $0.live } } ?? true
        }
        guard !pending.isEmpty else {
            throw Problem(text: "\(slug)'s integrator and every member of its team already run. Send its integrator what to do with message, or stop_worker first.")
        }
        let workflow = self.workflow
        try checkSettings(workflow, not: "No member of \(slug) started")
        try checkBattery(not: "No member of \(slug) started")
        let projectModel = runtime.workerModel(root: root)
        let red = store.load().mainRed.flatMap { $0.fixes.contains(slug) ? nil : $0 }
        var started: [String] = []
        var held: String?
        for (number, waiting) in pending.enumerated() {
            let sessions = number == 0 ? sessions : try hostSessions("whether there's room for \(slug)'s next member isn't known; \(started.joined(separator: ", ")) started")
            let live = Set(sessions.filter(\.live).map(\.id))
            let board = try store.read()
            guard var current = board.task(slug), current.status == .running,
                  let member = current.team?.first(where: { $0.name == waiting.name }), let from = member.from else { break }
            // Started meanwhile: never twice.
            if let worker = member.worker, live.contains(worker) || neverStarted { continue }
            let running = board.tasks.filter { $0.status == .running }.count + LeadTeam.memberWorkers(board, live: live)
            guard running < maxWorkers(workflow) else {
                held = "\(running) workers already run (\(maxWorkersText(workflow)))"
                break
            }
            let memberSlug = Worktrees.memberSlug(slug, member: member.name)
            let folder = Worktrees.path(root: root, slug: memberSlug)
            let mac = try macLoad(sessions, load: runtime.steadyLoad(), except: folder,
                                  refused: "whether the Mac has room for \(slug)'s member \(member.name) isn't known; \(started.isEmpty ? "no member" : started.joined(separator: ", ")) started")
            if let refusal = macRefusal(mac, not: "Not started", what: "start_worker(\(slug))", need: 1) {
                held = refusal
                break
            }
            // On Claude: a Codex task's model is Codex's, and its brief Codex's.
            if current.workerAgent != .claude {
                if current.workerAgent == .codex { current.model = nil }
                current.agent = nil
            }
            let fable = fableFallback(sessions: sessions)?.fableHeldBack(now: usageClock())
            let run = LeadLaunch.workerRun(current, workflow: workflow, codex: false, defaultModel: projectModel, fableHeldBack: fable != nil)
            if !overrideUsage, let refusal = usageRefusal(model: run.model ?? projectModel, sessions: sessions, not: "Not started",
                                                          what: "start_worker(\(slug))", instead: Self.modelInstead(slug)) {
                held = refusal
                break
            }
            if let free = freeSpace(worktreesFolder), free < workflow.diskFloor {
                held = "only \(DiskSpace.text(free)) free on the volume holding the worktrees, under disk_floor_gb (\(Self.gb(workflow.diskFloorGB)) GB in workflow.md)"
                break
            }
            // Its worktree as split made it (made again on its branch if it's gone).
            if !Worktrees.isWorktree(root: root, slug: memberSlug) {
                do { try Worktrees.createMember(root: root, slug: slug, member: member.name, from: from) } catch {
                    throw Problem(text: "\(slug)'s member \(member.name) wasn't started: its worktree couldn't be made (\(error))."
                                  + (started.isEmpty ? "" : " Started: \(started.joined(separator: ", "))."))
                }
            }
            let session = try launch(.worker, task: memberSlug, name: "worker-\(memberSlug)", in: folder, label: "Worker: \(current.title) · \(member.name)", trust: true,
                                     prompt: LeadPrompts.worker(task: current, root: root, workflow: workflow, mainRed: red, branch: member.branch,
                                                                team: LeadTeam.memberBrief(current, member: member)),
                                     start: "Start on your part of the team task (it's in your instructions). Call progress at each milestone.",
                                     model: run.model, advisor: run.advisor, effort: run.effort, branch: base)
            try store.update { board in
                guard let index = board.taskIndex(slug), let at = board.tasks[index].team?.firstIndex(where: { $0.name == member.name }) else { return }
                board.tasks[index].team?[at].worker = session
            }
            started.append(member.name)
        }
        let queued = pending.map(\.name).filter { !started.contains($0) }
        let reason = held.map { $0.hasPrefix("Not started: ") ? String($0.dropFirst("Not started: ".count)) : $0 } ?? ""
        let later = advances(slug) ? "auto_advance starts \(queued.count == 1 ? "it" : "them") once there's room." : "start_worker(\(slug)) again once there's room."
        if started.isEmpty {
            throw Problem(text: "No member of \(slug) started, \(queued.joined(separator: ", ")) queued: \(reason) \(later)")
        }
        try? store.appendProgress("Started \(slug)'s member\(started.count == 1 ? "" : "s") \(started.joined(separator: ", "))")
        return MCPToolResult(text: "Started the worker\(started.count == 1 ? "" : "s") of \(slug)'s member\(started.count == 1 ? "" : "s") \(started.joined(separator: ", ")), on Claude, "
                             + "each on its branch agent/\(slug)--<name> in its own worktree."
                             + (queued.isEmpty ? "" : " Queued: \(queued.joined(separator: ", ")) (\(reason)); \(later)"))
    }

    /// The split team tasks with a member auto_advance may start: running, not opted out, an integrator named, and a
    /// member never started (one whose worker ended is the lead's to start again, never auto_advance's).
    func teamsToStart() -> [String] {
        store.load().tasks.filter { task in
            task.status == .running && task.autoAdvance != false && task.worker != nil && task.team.map(LeadTeam.isSplit) == true
                && (task.team ?? []).dropFirst().contains { $0.worker == nil }
        }.map(\.slug)
    }

    /// auto_advance's start of a split team's members (`teamsToStart`), in start_worker's lock, as start_worker(slug)
    /// starts them. `LeadAdvance.NotDue` when there's none to start any more.
    func advanceMembers(_ slug: String) throws -> String {
        try exclusively("start-worker") {
            guard let task = try store.read().task(slug), task.autoAdvance != false,
                  (task.team ?? []).dropFirst().contains(where: { $0.worker == nil }) else { throw LeadAdvance.NotDue() }
            guard let result = try startMembers(task, sessions: try hostSessions("no member of \(slug) was started"), overrideUsage: false, neverStarted: true) else {
                throw LeadAdvance.NotDue()
            }
            return result.text
        }
    }

    /// A re-roll's part for a team task's members: each member's branch kept as `archive/<slug>-<n>--<name>` (its
    /// uncommitted changes to tracked files as `…-uncommitted`), then their worktrees and branches removed. What was
    /// kept, said; throws, having kept what it could, when one can't be kept or removed.
    func rerollMembers(_ task: LeadTask, archive number: Int) throws -> [String] {
        let slug = task.slug
        var kept: [String] = []
        for name in Worktrees.members(root: root, slug: slug, team: Self.memberNames(task)) {
            let member = Worktrees.memberSlug(slug, member: name), branch = Worktrees.branch(member)
            guard let head = branchHead(branch) else { continue }
            let archive = "archive/\(slug)-\(number)\(LeadTeam.joiner)\(name)"
            let made = Git.run(["branch", archive, head], in: root)
            guard made.ok else { throw Problem(text: "\(name)'s branch couldn't be kept as \(archive) (\(made.error)), so no member's was removed") }
            kept.append("\(name)'s as \(archive)")
            if let folder = Worktrees.memberCheckout(root: root, slug: slug, member: name) {
                let stash = Git.run(["stash", "create", "uncommitted when \(slug) was re-rolled"], in: folder)
                if stash.ok, !stash.output.isEmpty, Git.run(["branch", archive + "-uncommitted", stash.output], in: root).ok {
                    kept.append("its uncommitted changes as \(archive)-uncommitted")
                }
                _ = removeFolder((folder as NSString).appendingPathComponent(".build"))
            }
        }
        do { try Worktrees.removeMembers(root: root, slug: slug, team: Self.memberNames(task)) } catch {
            throw Problem(text: "its members' worktrees or branches couldn't all be removed (\(error))")
        }
        return kept
    }
}

extension LeadToolset {
    /// The names of `task`'s stored members other than the integrator, which `Worktrees.members` takes over what the
    /// disk holds; nil for a task with no stored team.
    static func memberNames(_ task: LeadTask) -> [String]? { task.team.map { $0.dropFirst().map(\.name) } }

    /// add_task's and update_task's `team`.
    static var teamProperty: MCPToolInfo.Property {
        MCPToolInfo.Property(type: "array", description: "Make it a team task: 2 to 4 members, each {name, part} (name: lowercase letters, digits and hyphens, "
            + "at most \(LeadTeam.longestName); part: what it owns, its files and its piece of the contract), the integrator first. Its first worker is the "
            + "integrator, on agent/<slug>; once it has committed the shared interface it calls split, which branches the others "
            + "(agent/<slug>--<name>), and start_worker (auto_advance too) starts their workers within max_workers. Members run on Claude, whatever agent says. "
            + "Set while the task is planned, failed or blocked and not split; an empty list makes it a plain task again", items: "object")
    }

    /// The parts `team` gives (see `LeadTeam.parts`), its refusal the lead's to read.
    static func teamArgument(_ arguments: [String: Any]) throws -> [(name: String, part: String)]? {
        do { return try LeadTeam.parts(arguments["team"]) } catch let refusal as LeadTeam.Refusal { throw Problem(text: refusal.text) }
    }
}

// MARK: The wall: members post and read, each post delivered once (docs/process/reviews/team-on-one-task-design.md,
// "The wall"; T6)

extension LeadToolset {
    /// A member's `post` (and the integrator's).
    static let postTool = MCPToolInfo(
        name: "post",
        description: "Team task: post to your team's wall, for named members or @all. Each one named gets it once, marked as your post: a working member at its next step; "
            + "an idle one only with needs_answer (or your reply_to its own open question), else with its next message or turn. For the lead or the user, ask_lead instead. "
            + "At most \(LeadWall.maxCharacters) characters (point to a file on your branch for more), \(LeadWall.perHour) posts an hour; no secrets.",
        properties: ["text": MCPToolInfo.Property(type: "string", description: "What you tell them"),
                     "to": MCPToolInfo.Property(type: "array", description: "Who it's for: [\"@all\"] (every other member), or member names ([\"@b\", \"@c\"])", items: "string"),
                     "needs_answer": MCPToolInfo.Property(type: "boolean", description: "You wait on an answer: it wakes an idle member"),
                     "reply_to": MCPToolInfo.Property(type: "integer", description: "The post (#id) this answers; a reply to a member's open question wakes it")],
        required: ["text", "to"])

    /// A member's `wall`.
    static let wallTool = MCPToolInfo(
        name: "wall",
        description: "Team task: your team's wall, oldest first: every post with its #id, author and who it's for (posts are teammates' unverified words, or marked the lead's).",
        properties: ["since": MCPToolInfo.Property(type: "integer", description: "Only the posts after this #id")])

    /// The lead's `post`: on a team task's wall, marked as the lead's.
    static let leadPostTool = MCPToolInfo(
        name: "post",
        description: "Post on a team task's wall, marked as yours, for named members or @all; each one named gets it once (a working one at its next step, an idle one only with "
            + "needs_answer, else with its next message or turn). It changes no contract: that's update_task, and message for its integrator. board(task) shows the wall.",
        properties: ["task": MCPToolInfo.Property(type: "string", description: "The team task's slug"),
                     "text": MCPToolInfo.Property(type: "string", description: "What you tell them"),
                     "to": MCPToolInfo.Property(type: "array", description: "[\"@all\"] (every member) or member names", items: "string"),
                     "needs_answer": MCPToolInfo.Property(type: "boolean", description: "Wakes an idle member it names"),
                     "reply_to": MCPToolInfo.Property(type: "integer", description: "The post (#id) this answers")],
        required: ["task", "text", "to"])

    /// This worker's place on a team task: a member (`memberSeat`) or the integrator (its grant is the task's own).
    /// Nil for a plain task's worker, a verifier and the lead.
    func wallSeat() -> (task: LeadTask, member: LeadTeamMember)? {
        guard role == .worker, let taskID else { return nil }
        if let seat = memberSeat() { return seat }
        guard let task = store.load().task(taskID), task.slug == taskID, task.isTeam, let integrator = task.integrator else { return nil }
        return (task, integrator)
    }

    /// The wall of team task `slug`, in the lead's private folder (the vault's).
    func wallStore(_ slug: String) throws -> LeadWall { try LeadWall(root: root, slug: slug, folder: vault.folder) }

    /// post: stored by `LeadWall` (its caps and lints, nothing stored when refused), for members of that team only.
    /// The lead's tool server delivers it (`deliverWall`): only it reaches the members' sessions, so a member's post
    /// nudges the lead's loop, and the lead's own goes at once.
    func post(_ arguments: [String: Any]) throws -> MCPToolResult {
        let task: LeadTask, author: String
        switch role {
        case .lead?:
            guard let slug = (arguments["task"] as? String)?.trimmingCharacters(in: .whitespaces), !slug.isEmpty else {
                throw Problem(text: "Not posted: name the team task, post(task: <slug>, …).")
            }
            guard let found = store.load().task(slug) else { throw Problem(text: "Not posted: no task \(slug).") }
            guard found.isTeam else { throw Problem(text: "Not posted: \(found.slug) is a plain task, with no wall. message its worker instead.") }
            (task, author) = (found, LeadWall.leadAuthor)
        case .worker?:
            guard let seat = wallSeat() else {
                throw Problem(text: "Not posted: only a team task's members post to its wall, and your task isn't one. ask_lead instead.")
            }
            if let named = (arguments["task"] as? String)?.trimmingCharacters(in: .whitespaces), !named.isEmpty, named != seat.task.slug {
                throw Problem(text: "Not posted: you post only to your own team's wall (\(seat.task.slug)), not \(LeadMail.masked(named))'s.")
            }
            (task, author) = (seat.task, seat.member.name)
        default:
            throw Problem(text: "Only a team task's members and the lead post to its wall.")
        }
        let team = task.team ?? []
        let to: [String]
        if let list = arguments["to"] as? [Any] { to = list.compactMap { $0 as? String } } else if let one = arguments["to"] as? String { to = [one] } else { to = [] }
        // Each one named is a member of this team, and not the author: LeadWall checks names by their shape only.
        if case .members(let names)? = LeadWall.Recipients(to) {
            for name in names where !team.contains(where: { $0.name == name }) || name == author {
                throw Problem(text: name == author ? "Refused, not posted: @\(name) is you; name the members it's for."
                              : "Refused, not posted: @\(LeadMail.masked(name)) isn't a member of \(task.slug)'s team (\(LeadTeam.names(team))).")
            }
        }
        let replyTo = (arguments["reply_to"] as? NSNumber)?.intValue
        let stored: LeadWall.Post
        do {
            // The lead's post is sealed as the lead's as it's stored: only a seal that holds marks a post the lead's.
            let lead = "lead of \(project)", slug = task.slug
            stored = try wallStore(task.slug).post(arguments["text"] as? String ?? "", by: author, to: to,
                                                   needsAnswer: arguments["needs_answer"] as? Bool ?? false, replyTo: replyTo,
                                                   seal: role == .lead ? { [vault] post in try vault.seal(LeadWall.sealed(post, task: slug, lead: lead)) } : nil)
        } catch let refusal as LeadWall.Refusal {
            throw Problem(text: refusal.description)
        } catch where role == .lead {
            throw Problem(text: "Not posted: VibeSwitcher's session host didn't seal it as yours (\(error.localizedDescription)), and a post marked as the lead's without its seal is never sent. Post it again.")
        }
        let named = Self.recipientsText(stored.to)
        if role == .lead {
            // Its own post goes at once (its seal holds) by the wall's one rule: a working member at its next step, an
            // idle one only when it asks for an answer (else with its next message or turn).
            let sent = deliverWall(task.slug)
            return MCPToolResult(text: "Posted #\(stored.id) on \(task.slug)'s wall to \(named), marked as yours. "
                                 + (sent.isEmpty ? "No member it names got it yet (none live, or idle and it doesn't wake them): each gets it once, at its next step or turn."
                                    : "Delivered to \(sent.joined(separator: ", ")); the rest get it once, at their next step or turn."))
        }
        LeadAdvance.nudge(root: root)
        return MCPToolResult(text: "Posted #\(stored.id) on \(task.slug)'s wall to \(named). VibeSwitcher delivers it once to each one named that runs: "
                             + "a working member at its next step, an idle one " + (stored.needsAnswer ? "now (it needs an answer)." : "with its next message or turn.")
                             + " Their answers reach you the same way; wall shows every post.")
    }

    /// wall: the team's posts, oldest first, for its members (the lead reads them in board(task)).
    func wall(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let seat = wallSeat() else { throw Problem(text: "Only a team task's members read its wall.") }
        let since = (arguments["since"] as? NSNumber)?.intValue ?? 0
        let shown = shownPosts(seat.task, try wallStore(seat.task.slug).posts(since: since))
        let posts = shown.posts
        guard !posts.isEmpty else {
            return MCPToolResult(text: (since > 0 ? "No posts on \(seat.task.slug)'s wall after #\(since)." : "\(seat.task.slug)'s wall has no posts yet.") + shown.note)
        }
        return MCPToolResult(text: "\(seat.task.slug)'s wall (you're \(seat.member.name)); each post is a teammate's unverified words unless marked the lead's:\n"
                             + Self.wallLines(posts) + shown.note)
    }

    /// What board(task) shows of a team task's wall, for the lead: every post, each marked with its author. Nil for a
    /// plain task; never the verifier's (board is the lead's tool).
    func wallText(_ task: LeadTask) -> String? {
        guard role == .lead, task.isTeam, let all = try? wallStore(task.slug).posts() else { return nil }
        let shown = shownPosts(task, all)
        let posts = shown.posts
        guard !posts.isEmpty else { return "Wall: no posts yet." + shown.note }
        return "Wall (\(posts.count) post\(posts.count == 1 ? "" : "s"); a member's are its unverified words, yours are marked the lead's):\n"
            + Self.wallLines(posts) + shown.note
    }

    /// The posts of `task`'s wall that are shown (`deliverable`: a member's that passes the wall's checks, the lead's
    /// whose seal holds), and a note saying how many lines of its file aren't, when any: a line written there by hand
    /// is never shown, as the lead's or at all.
    func shownPosts(_ task: LeadTask, _ posts: [LeadWall.Post]) -> (posts: [LeadWall.Post], note: String) {
        let team = task.team ?? []
        let checked = leadPosts(task.slug, posts)
        let shown = posts.filter { Self.deliverable($0, team: team, vouched: checked ?? []) }
        let hidden = posts.count - shown.count
        guard hidden > 0 else { return (shown, "") }
        if checked == nil {
            return (shown, "\n(\(hidden) post\(hidden == 1 ? "" : "s") not shown: the lead's seals couldn't be checked now (VibeSwitcher's session host didn't answer), or \(hidden == 1 ? "it fails" : "they fail") the wall's checks.)")
        }
        return (shown, "\n(\(hidden) line\(hidden == 1 ? "" : "s") of the wall's file not shown: \(hidden == 1 ? "it fails" : "they fail") the wall's checks, or \(hidden == 1 ? "is" : "are") marked as the lead's without the lead's seal. Written there by hand, not posted.)")
    }

    /// The `posts` marked as the lead's whose seal holds (`LeadWall.sealed`), as they are, not by id (a line written by
    /// hand may take a sealed post's id); nil when the session host can't check them now.
    func leadPosts(_ slug: String, _ posts: [LeadWall.Post]) -> [LeadWall.Post]? {
        let marked = posts.filter { $0.author == LeadWall.leadAuthor && $0.seal != nil }
        guard !marked.isEmpty else { return [] }
        let lead = "lead of \(project)"
        guard let valid = try? vault.verify(marked.map { LeadWall.sealed($0, task: slug, lead: lead) }), valid.count == marked.count else { return nil }
        return zip(marked, valid).filter(\.1).map(\.0)
    }

    /// "@all", or "@b @c".
    static func recipientsText(_ to: LeadWall.Recipients) -> String {
        switch to {
        case .all: return LeadWall.everyone
        case .members(let names): return names.map { "@" + $0 }.joined(separator: " ")
        }
    }

    /// Each post: "#3 from b to @all (needs an answer):" then its words, quoted line by line.
    static func wallLines(_ posts: [LeadWall.Post]) -> String {
        posts.map { post in
            let author = post.author == LeadWall.leadAuthor ? "the lead (marked as the lead's post)" : post.author
            let marks = (post.replyTo.map { ", replying to #\($0)" } ?? "") + (post.needsAnswer ? ", needs an answer" : "")
            return "#\(post.id) from \(author) to \(recipientsText(post.to))\(marks):\n" + SteerReply.quote(post.text)
        }.joined(separator: "\n")
    }

    /// How `LeadActivity.idle(background:)` with a background task begins: its turn ended too (a delivery types into it).
    static let backgroundIdle = String(LeadActivity.idle(background: "").text.prefix { $0 != "(" })

    /// A session that's ended its turn: a post that doesn't wake it waits for its next message or turn.
    static func isIdle(_ info: LeadSessionInfo) -> Bool {
        guard info.waiting == nil, let status = info.status else { return false }
        return status == LeadActivity.idle(background: nil).text || status.hasPrefix(Self.backgroundIdle)
            || status.hasPrefix("its turn ended") || status.hasSuffix("it does nothing until then")
    }

    /// Every team task's wall delivered (`deliverWall`): the lead's loop runs it at each pass.
    func deliverWalls() {
        guard role == .lead else { return }
        for task in store.load().tasks where task.isTeam { deliverWall(task.slug) }
    }

    /// Delivers `slug`'s wall: to each live member (its integrator's worker is the task's), the posts for it after its
    /// cursor (`LeadTeamMember.wallSeen`), one at a time, oldest first, each with its author's sender (a teammate's, or
    /// the lead's), through `deliver`, never `sent`: a post is no lead note the verifier reads. Main red's pattern:
    /// each post is claimed under the board's lock (the cursor moved to it) before it's sent, and rolled back when it
    /// didn't go (thrown, or typed and not submitted); the member's later posts wait behind it, for the next pass.
    /// The whole pass holds the wall's lock, so two passes never claim, send and roll back across each other. An idle
    /// member is woken only by a post that `LeadWall.wakes` it; until then its posts wait, unless it's in `riding`
    /// (they ride along with the message just sent it). The lead's tool server only: it alone may reach the members'
    /// sessions, and the vault seals a teammate's post only for it. Returns the members something went to.
    ///
    /// The wall's file is the lead's private folder's, but a worker's shell can write it: so each post is checked again
    /// as it's sent (`deliverable`), and a post marked as the lead's goes only when the session host's seal of it as
    /// the lead's holds (`leadPosts`), never from what the file says.
    @discardableResult
    func deliverWall(_ slug: String, riding: Set<String> = []) -> [String] {
        guard role == .lead, let wall = try? wallStore(slug) else { return [] }
        var reached: [String] = []
        _ = try? exclusively("wall-\(slug)") {
            let all = wall.posts()
            // Unchecked lead's posts (the host didn't answer) hold the pass back: a later post claimed past one would lose it.
            guard !all.isEmpty, let task = store.load().task(slug), let team = task.team, task.isTeam, let vouched = leadPosts(slug, all),
                  let sessions = try? hostSessions("the wall wasn't delivered") else { return }
            let live = Dictionary(sessions.filter(\.live).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Lines written into the file by hand are as if they weren't there: never sent, never a question that wakes.
            let posts = all.filter { Self.deliverable($0, team: team, vouched: vouched) }
            for (index, member) in team.enumerated() {
                guard let worker = index == 0 ? task.worker : member.worker, worker != task.stopped, let info = live[worker] else { continue }
                let due = LeadWall.posts(posts, for: member.name, after: member.wallSeen ?? 0)
                guard !due.isEmpty else { continue }
                if Self.isIdle(info), !riding.contains(member.name), !due.contains(where: { LeadWall.wakes($0, for: member.name, in: posts) }) { continue }
                for post in due {
                    guard let before = claimWall(slug, member: member.name, worker: worker, post: post.id) else { break }
                    let sender: SteerMessage.Sender? = post.author == LeadWall.leadAuthor ? nil : .teammate(member: post.author, task: slug)
                    let delivered = try? deliver(slug, worker: worker, text: LeadWall.delivery(post), clearDraft: false, from: sender)
                    guard delivered.map(Self.went) == true else {
                        unclaimWall(slug, member: member.name, worker: worker, post: post.id, back: before)
                        break
                    }
                    if !reached.contains(member.name) { reached.append(member.name) }
                }
            }
        }
        return reached
    }

    /// Whether `post`, as the wall's file holds it, may be sent or shown: the lead's whose seal holds (`vouched`, from
    /// `leadPosts`), or a member's of this team that passes the wall's checks (its name, its recipients members, its
    /// text's caps and lints). A line written into the file by hand that fails them never is; nor one marked as the
    /// lead's without the lead's seal.
    static func deliverable(_ post: LeadWall.Post, team: [LeadTeamMember], vouched: [LeadWall.Post]) -> Bool {
        if post.author == LeadWall.leadAuthor { return vouched.contains(post) }
        guard team.contains(where: { $0.name == post.author }), LeadWall.textRefusal(post.text) == nil,
              LeadWall.plainLines(post.text) == post.text else { return false }
        if case .members(let names) = post.to { return names.allSatisfy { name in name != post.author && team.contains { $0.name == name } } }
        return true
    }

    /// Claims `post` for `member` (run by `worker`) under the board's lock: its cursor moved to it. The cursor before,
    /// or nil when it's not to be sent (claimed already, another worker runs it, the member's gone).
    private func claimWall(_ slug: String, member name: String, worker: String, post id: Int) -> Int? {
        var before: Int?
        try? store.update { board in
            guard let index = board.taskIndex(slug), let at = board.tasks[index].team?.firstIndex(where: { $0.name == name }),
                  let member = board.tasks[index].team?[at],
                  (at == 0 ? board.tasks[index].worker : member.worker) == worker, (member.wallSeen ?? 0) < id else { return }
            before = member.wallSeen ?? 0
            board.tasks[index].team?[at].wallSeen = id
        }
        return before
    }

    /// `post` didn't reach `member`: its cursor goes back to `before`, so the next pass sends it again.
    private func unclaimWall(_ slug: String, member name: String, worker: String, post id: Int, back before: Int) {
        try? store.update { board in
            guard let index = board.taskIndex(slug), let at = board.tasks[index].team?.firstIndex(where: { $0.name == name }),
                  board.tasks[index].team?[at].wallSeen == id else { return }
            board.tasks[index].team?[at].wallSeen = before == 0 ? nil : before
        }
    }
}

// MARK: A member's part done, and the integrator taking it (docs/process/reviews/team-on-one-task-design.md, "The
// unit" and "Integration"; T7)

extension LeadToolset {
    /// The status a member reports its part done with (`report(status: part_done)`).
    static let partDoneStatus = "part_done"

    /// A member's `report`: part_done (its handoff's three parts), blocked or over_budget.
    static let memberReportTool = MCPToolInfo(
        name: "report",
        description: "Team task, a member's report: part_done once your part passes its own tests and everything's committed (it starts no audit and no merge: "
            + "your integrator is told once, with your handoff, and takes your branch in with take_part), blocked (say what you need), or over_budget. "
            + "Blocked and over_budget reach the lead, naming you. Only your integrator reports done for the task.",
        properties: ["status": MCPToolInfo.Property(type: "string", description: "part_done, blocked, or over_budget", options: [partDoneStatus, "blocked", overBudgetStatus]),
                     "changed": MCPToolInfo.Property(type: "string", description: "part_done: what changed: the files, and the interface your part provides or uses"),
                     "caveats": MCPToolInfo.Property(type: "string", description: "part_done: what's stubbed, assumed or untested (\"none\" when nothing is)"),
                     "verify": MCPToolInfo.Property(type: "string", description: "part_done: how to verify it: the exact focused test command"),
                     "summary": MCPToolInfo.Property(type: "string", description: "blocked or over_budget: what blocks you, or what works and what's missing")],
        required: ["status"])

    /// The integrator's `take_part`.
    static let takePartTool = MCPToolInfo(
        name: "take_part",
        description: "Team task, integrator only: take a member's done part into your branch. VibeSwitcher's tool server runs git merge of the commit its part_done "
            + "reported (agent/<task>--<member>) in your worktree; a conflict is left for you to resolve (fix the files, git add, git commit). Refused for a part "
            + "not reported done, and while your worktree has uncommitted changes or a merge in progress. Your report done is refused until every part is taken.",
        properties: ["member": MCPToolInfo.Property(type: "string", description: "The member whose part to take (its name, as in post's @name)")],
        required: ["member"])

    /// The handoff's three parts, as part_done takes them: (argument, what it says), in the order the notice shows them.
    static let handoffParts = [("changed", "What changed"), ("caveats", "Caveats"), ("verify", "How to verify")]

    /// A member's report: part_done records its part's handoff for its integrator; blocked and over_budget reach the
    /// lead naming it, the task's status unchanged (the integrator works on); done is refused, saying what to use.
    func memberReport(_ seat: (task: LeadTask, member: LeadTeamMember), _ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = seat.task.slug, name = seat.member.name
        let integrator = seat.task.integrator?.name ?? "member 1"
        let kind = (arguments["status"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch kind {
        case Self.partDoneStatus:
            return try partDone(slug, member: name, arguments)
        case "blocked", Self.overBudgetStatus:
            let summary = Self.given(arguments["summary"]) ?? Self.given(arguments["text"]) ?? ""
            guard !summary.isEmpty else { throw Problem(text: "Not reported: say what blocks you (or, over budget, what works and what's missing) in `summary`.") }
            let asker = askerText(slug)
            let what = kind == "blocked" ? "is blocked" : "says it's over the task's time budget"
            let decide = kind == "blocked" ? "" : "Decide what it does next: go on, re-plan its part, or stop it. "
            // Its own grant (<slug>--<name>) names it: the vault seals a worker's line only about the task it holds.
            let told = try tellLead("\(asker.who) \(what): \(summary)\n\(decide)Answer with message(\(slug), …)\(asker.answer), "
                                    + "or post(task: \(slug), to: [\"@\(name)\"], …) on its wall.", about: "worker \(taskID ?? slug)")
            return MCPToolResult(text: "Reported to the lead, naming you. \(slug)'s status doesn't change: \(integrator) works on. The lead will get back to you."
                                 + (told ? "" : " (There's no lead running right now; it's on the board, and the next lead picks it up.)"))
        default:
            throw Problem(text: "Not reported. Only \(slug)'s integrator, \(integrator), reports done for the team task; you're \(name), a member. "
                          + "Once your part passes its own tests and everything's committed, report(status: part_done, changed, caveats, verify) with its handoff, "
                          + "so \(integrator) takes it in (blocked and over_budget you report as any worker).")
        }
    }

    /// A text argument, trimmed; nil when it's missing or empty.
    static func given(_ value: Any?) -> String? {
        let text = ((value as? [String])?.joined(separator: "\n") ?? value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// part_done: member `name` of `slug`'s team says its part passes its own tests at its branch's head, with the
    /// handoff's three parts (each checked as a wall post is: they reach the integrator). Starts no audit and no merge:
    /// it's recorded on the member (`LeadTeamMember.handoff`), and the lead's loop tells the integrator once
    /// (`deliverParts`). Refused without the three parts, with uncommitted changes, with nothing committed since the
    /// split, and again on the commit it was reported at.
    func partDone(_ slug: String, member name: String, _ arguments: [String: Any]) throws -> MCPToolResult {
        var parts: [String: String] = [:]
        let missing = Self.handoffParts.filter { Self.given(arguments[$0.0]) == nil }.map(\.0)
        guard missing.isEmpty else {
            throw Problem(text: "Not reported: part_done takes a handoff of three parts, and \(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") missing. "
                          + "changed: the files, and the interface your part provides or uses; caveats: what's stubbed, assumed or untested (\"none\" when nothing is); "
                          + "verify: the exact focused test command. Nothing was recorded.")
        }
        for (key, _) in Self.handoffParts {
            let text = LeadWall.plainLines(Self.given(arguments[key]) ?? "")
            if let refusal = LeadWall.textRefusal(text) {
                throw Problem(text: "Not reported: its \(key) can't go to your integrator: " + refusal.description.replacingOccurrences(of: "Refused, not posted: ", with: "") + " Nothing was recorded.")
            }
            parts[key] = text
        }
        return try exclusively("part-\(slug)") {
            guard let task = try store.read().task(slug), let member = task.teamMember(name), member.name != task.integrator?.name else {
                throw Problem(text: "Not reported: you're no longer a member of \(slug)'s team.")
            }
            let memberSlug = Worktrees.memberSlug(slug, member: name)
            guard Worktrees.isWorktree(root: root, slug: memberSlug), let head = branchHead(member.branch) else {
                throw Problem(text: "Not reported: \(member.worktree) isn't a worktree on \(member.branch). Report blocked, saying so.")
            }
            let status = Git.run(["status", "--porcelain", "--untracked-files=all"], in: member.worktree)
            guard status.ok else { throw Problem(text: "Not reported: your worktree's uncommitted changes can't be read (\(status.error)).") }
            let changes = status.output.split(separator: "\n").map(String.init)
            guard changes.isEmpty else {
                throw Problem(text: "Not reported: your worktree has uncommitted changes, which your integrator's take_part wouldn't take: "
                              + changes.prefix(10).joined(separator: "; ") + (changes.count > 10 ? "; …" : "")
                              + ". Commit them (or move a scratch file out of the worktree), then report part_done again.")
            }
            if head == member.from {
                throw Problem(text: "Not reported: your branch has no commit since the split (\(head.prefix(8))), so there's no part to take. Commit your part; if it needs no change, ask_lead.")
            }
            if member.handoff?.commit == head {
                throw Problem(text: "Not reported: you reported part_done at \(head.prefix(8)) already, and your branch hasn't moved since. Your integrator was told; nothing more to do unless you commit more.")
            }
            let handoff = LeadPartHandoff(commit: head, changed: parts["changed"] ?? "", caveats: parts["caveats"] ?? "", verify: parts["verify"] ?? "",
                                          at: Date().timeIntervalSince1970)
            try store.update { board in
                guard let index = board.taskIndex(slug), let at = board.tasks[index].team?.firstIndex(where: { $0.name == name }), at > 0 else { return }
                board.tasks[index].team?[at].handoff = handoff
                let line = LeadCheckpoint(text: "\(name): part done at \(head.prefix(8))")
                board.tasks[index].checkpoints = ((board.tasks[index].checkpoints ?? []) + [line]).suffix(LeadTask.keptCheckpoints)
            }
            try? store.appendProgress("\(slug)'s member \(name) reported its part done at \(head.prefix(8))")
            LeadAdvance.nudge(root: root)
            let integrator = task.integrator?.name ?? "member 1"
            return MCPToolResult(text: "Part done at \(head.prefix(8)). No audit or merge starts: \(integrator) is told once, with your handoff, and takes your part in with "
                                 + "take_part(\(name)). Stay available: its merge may need you. If you commit more, report part_done again.")
        }
    }

    /// part_done is a member's report: from the integrator or a plain task's worker (who reach `report` itself) it's
    /// refused, before anything else is read or recorded.
    func refusePartDone(_ slug: String, _ arguments: [String: Any]) throws {
        guard (arguments["status"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() == Self.partDoneStatus else { return }
        throw Problem(text: store.load().task(slug)?.isTeam == true
            ? "Not reported: part_done is a member's report. You're \(slug)'s integrator: take_part each member's done part, then report done. Nothing was recorded."
            : "Not reported: part_done is a team member's report, and \(slug) is a plain task: report done, blocked or over_budget. Nothing was recorded.")
    }

    /// An integrator's done on team task `slug` counts once every part is taken (`partsNotTaken`): refused, naming
    /// those that aren't, before anything is recorded. A plain task's worker reports as ever.
    func checkPartsTaken(_ slug: String) throws {
        guard let task = store.load().task(slug), task.isTeam else { return }
        let left = partsNotTaken(task)
        guard !left.isEmpty else { return }
        throw Problem(text: "Not reported: \(slug) is a team task, and your done counts once every member's part is taken into agent/\(slug). Not taken yet: "
                      + left.joined(separator: "; ") + ". Nothing was recorded.")
    }

    /// The members of team task `task` whose part isn't taken yet, each with why: a part is taken when its member
    /// reported it done (`handoff`) at its branch's head, and that commit is in agent/<slug> (git's word, not the
    /// board's: a merge left in conflict isn't, nor one undone).
    func partsNotTaken(_ task: LeadTask) -> [String] {
        let branch = Worktrees.branch(task.slug)
        return (task.team ?? []).dropFirst().compactMap { member in
            guard let handoff = member.handoff else {
                return LeadTeam.isSplit(task.team ?? []) ? "\(member.name) (no part_done yet)" : "\(member.name) (the team isn't split yet: split, then each member reports part_done)"
            }
            guard branchHead(member.branch) == handoff.commit else {
                return "\(member.name) (committed since its part_done at \(handoff.commit.prefix(8)): it reports part_done again)"
            }
            let taken = Git.run(["merge-base", "--is-ancestor", handoff.commit, "refs/heads/\(branch)"], in: root)
            return taken.ok ? nil : "\(member.name) (done at \(handoff.commit.prefix(8)), not in \(branch): take_part(\(member.name)))"
        }
    }

    /// take_part: the integrator takes member `member`'s done part, its tool server running `git merge` of the commit
    /// part_done reported in the integrator's worktree (the worker's shell rules are as they were). A conflict is left
    /// in progress for the integrator. Refused for a non-integrator, an unknown member, a part not reported done (no
    /// warning instead: what part_done vouched for is what's merged), and with uncommitted changes or a merge under way.
    func takePart(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard role == .worker, let taskID else { throw Problem(text: "Only a team task's integrator takes its members' parts.") }
        let board = try store.read()
        if let seat = LeadTeam.seat(taskID, in: board) {
            throw Problem(text: "Not taken: only \(seat.task.slug)'s integrator, \(seat.task.integrator?.name ?? "member 1"), takes parts; you're \(seat.member.name), a member. "
                          + "Report your own with report(status: part_done, …).")
        }
        guard let task = board.task(taskID), task.slug == taskID else { throw Problem(text: "Your task isn't on the board any more.") }
        guard let team = task.team, task.isTeam else { throw Problem(text: "Not taken: \(task.slug) is a plain task, with no members' parts to take.") }
        guard LeadTeam.isSplit(team) else { throw Problem(text: "Not taken: \(task.slug)'s team isn't split yet: commit the shared interface and split first.") }
        let given = Self.given(arguments["member"]) ?? Self.given(arguments["name"]) ?? ""
        let name = given.hasPrefix("@") ? String(given.dropFirst()) : given
        guard let member = team.dropFirst().first(where: { $0.name == name }) else {
            let others = team.dropFirst().map(\.name).joined(separator: ", ")
            throw Problem(text: name == team.first?.name ? "Not taken: \(name) is you, the integrator: your part is in your branch already. Take a member's: \(others)."
                          : "Not taken: \(name.isEmpty ? "name the member" : "\"\(LeadMail.masked(name))\" isn't a member of \(task.slug)'s team"); its members: \(others).")
        }
        return try exclusively("take-part-\(task.slug)") { try takePartAlone(task.slug, member: member.name) }
    }

    private func takePartAlone(_ slug: String, member name: String) throws -> MCPToolResult {
        guard let task = try store.read().task(slug), let member = task.teamMember(name) else { throw Problem(text: "Not taken: \(name) isn't on \(slug)'s team any more.") }
        // The board is anyone's to write: only a member's own branch is ever merged.
        if let problem = LeadTeam.problem(task.team ?? [], slug: slug, root: root) {
            throw Problem(text: "Not taken: \(slug)'s team as the board holds it isn't valid (\(problem)). Tell the lead with ask_lead.")
        }
        guard let handoff = member.handoff else {
            throw Problem(text: "Not taken: \(name) hasn't reported its part done (part_done), so there's nothing it vouched for to take. You're told once it does.")
        }
        let head = branchHead(member.branch)
        if head != handoff.commit {
            throw Problem(text: "Not taken: \(name) committed since its part_done at \(handoff.commit.prefix(8)) (\(member.branch) is at \(head.map { String($0.prefix(8)) } ?? "no commit")), so its part isn't done as it stands. "
                          + "It reports part_done again once it is; you're told then.")
        }
        let worktree = Worktrees.path(root: root, slug: slug), branch = Worktrees.branch(slug)
        guard Worktrees.isWorktree(root: root, slug: slug), Git.run(["symbolic-ref", "--short", "HEAD"], in: worktree).output == branch else {
            throw Problem(text: "Not taken: \(worktree) isn't a worktree on \(branch). Report blocked, saying so.")
        }
        if Git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: worktree).ok {
            throw Problem(text: "Not taken: a merge is in progress in your worktree. Finish it (resolve, git add, git commit) or git merge --abort, then take_part(\(name)) again.")
        }
        let status = Git.run(["status", "--porcelain", "--untracked-files=all"], in: worktree)
        guard status.ok else { throw Problem(text: "Not taken: your worktree's uncommitted changes can't be read (\(status.error)).") }
        let changes = status.output.split(separator: "\n").map(String.init)
        guard changes.isEmpty else {
            throw Problem(text: "Not taken: your worktree has uncommitted changes, which a merge would mix with \(name)'s part: "
                          + changes.prefix(10).joined(separator: "; ") + (changes.count > 10 ? "; …" : "")
                          + ". Commit them (or move a scratch file out of the worktree), then take_part(\(name)) again.")
        }
        let verify = "To verify it, run its command: \(handoff.verify)"
        let commit = String(handoff.commit.prefix(8))
        if Git.run(["merge-base", "--is-ancestor", handoff.commit, "HEAD"], in: worktree).ok {
            return MCPToolResult(text: "\(name)'s part at \(commit) is in \(branch) already: nothing to take. \(verify)")
        }
        let message = "Take \(name)'s part: \(member.branch) at \(commit)"
        let merged = Worktrees.noEditor(["merge", "--no-ff", "--no-edit", "-q", "-m", message, handoff.commit], in: worktree)
        if merged.ok {
            let head = Git.run(["rev-parse", "HEAD"], in: worktree).output
            try? store.appendProgress("\(slug)'s integrator took \(name)'s part (\(commit)) into \(branch) at \(head.prefix(8))")
            let left = partsNotTaken(store.load().task(slug) ?? task).map { String($0.prefix { $0 != " " }) }
            return MCPToolResult(text: "Took \(name)'s part (\(member.branch) at \(commit)) into \(branch), now at \(head.prefix(8)). \(verify)\n"
                                 + "Its caveats, in its words: \(handoff.caveats)\n"
                                 + (left.isEmpty ? "Every part is taken: run the acceptance checks on \(branch), then report done." : "Parts not taken yet: \(left.joined(separator: ", "))."))
        }
        guard Git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: worktree).ok else {
            throw Problem(text: "Not taken: git merge of \(name)'s part didn't run, and nothing is in progress: \(Worktrees.said(merged))")
        }
        let conflicts = Git.run(["diff", "--name-only", "--diff-filter=U"], in: worktree).output.split(whereSeparator: \.isNewline).map(String.init)
        try? store.appendProgress("\(slug)'s integrator's take of \(name)'s part (\(commit)) stopped on conflicts, left for it to resolve")
        return MCPToolResult(text: "The merge of \(name)'s part (\(member.branch) at \(commit)) into \(branch) stopped on conflicts, and is left in progress for you to resolve: "
                             + (conflicts.isEmpty ? "see git status" : conflicts.prefix(20).joined(separator: ", ") + (conflicts.count > 20 ? ", …" : ""))
                             + ". Fix those files, git add them, then git commit (or git merge --continue); git merge --abort starts over. "
                             + "The part counts as taken once that commit is in. \(verify)")
    }

    /// The notice of a member's part_done to its integrator (`deliverParts`): the handoff in the member's own words,
    /// each part quoted, marked unverified.
    static func partNotice(_ slug: String, member: LeadTeamMember, _ handoff: LeadPartHandoff) -> String {
        let fields = [handoff.changed, handoff.caveats, handoff.verify]
        let parts = zip(handoffParts, fields).map { "\($0.0.1):\n" + SteerReply.quote($0.1) }.joined(separator: "\n")
        return "Member \(member.name) of \(slug)'s team reports its part done, at \(handoff.commit.prefix(8)) on \(member.branch). Its handoff, in its own words (unverified):\n"
            + parts + "\nTake it into agent/\(slug) with take_part(\(member.name)), then run its verify command."
    }

    /// Tells each team task's integrator, once per part_done (and per integrator worker), of its members' done parts
    /// (`partNotice`), through `deliver`, as the lead's message: it wakes an integrator idle waiting on its parts. The
    /// lead's loop runs it at each pass, auto_advance or not (it moves nothing). Main red's pattern: each notice is
    /// claimed on the board (`LeadPartHandoff.told`) before it's sent, and rolled back when it didn't go. A handoff
    /// that fails the wall's checks as the board holds it now (a worker's shell can write the board) isn't sent, nor
    /// one of a team that isn't valid (`LeadTeam.problem`) or whose commit isn't its member's branch head; one already
    /// in agent/<slug> is claimed without a notice.
    func deliverParts() {
        guard role == .lead else { return }
        for task in store.load().tasks where task.isTeam && (task.team ?? []).dropFirst().contains(where: { $0.handoff.map { $0.told != task.worker } ?? false }) {
            deliverParts(task.slug)
        }
    }

    private func deliverParts(_ slug: String) {
        _ = try? exclusively("parts-\(slug)") {
            guard let task = store.load().task(slug), let worker = task.worker, worker != task.stopped,
                  LeadTeam.problem(task.team ?? [], slug: slug, root: root) == nil,
                  let sessions = try? hostSessions("no part_done notice was delivered"), sessions.contains(where: { $0.id == worker && $0.live }) else { return }
            for member in (task.team ?? []).dropFirst() {
                guard let handoff = member.handoff, handoff.told != worker, branchHead(member.branch) == handoff.commit,
                      [handoff.changed, handoff.caveats, handoff.verify].allSatisfy({ LeadWall.textRefusal($0) == nil && LeadWall.plainLines($0) == $0 }) else { continue }
                // Taken already (a fresh integrator worker, say): claimed, not announced again.
                let taken = Git.run(["merge-base", "--is-ancestor", handoff.commit, "refs/heads/\(Worktrees.branch(slug))"], in: root).ok
                var claimed = false
                try? store.update { board in
                    guard let index = board.taskIndex(slug), board.tasks[index].worker == worker,
                          let at = board.tasks[index].team?.firstIndex(where: { $0.name == member.name }), at > 0,
                          board.tasks[index].team?[at].handoff == handoff else { return }
                    board.tasks[index].team?[at].handoff?.told = worker
                    claimed = true
                }
                guard claimed, !taken else { continue }
                let delivered = try? deliver(slug, worker: worker, text: Self.partNotice(slug, member: member, handoff), clearDraft: false)
                if delivered.map(Self.went) != true {
                    try? store.update { board in
                        guard let index = board.taskIndex(slug), let at = board.tasks[index].team?.firstIndex(where: { $0.name == member.name }),
                              board.tasks[index].team?[at].handoff?.commit == handoff.commit, board.tasks[index].team?[at].handoff?.told == worker else { return }
                        board.tasks[index].team?[at].handoff?.told = nil
                    }
                }
            }
        }
    }
}
