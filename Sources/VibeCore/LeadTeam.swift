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

    public init(name: String, part: String, worker: String? = nil, branch: String, worktree: String,
                wallSeen: Int? = nil, mainRedTold: [String]? = nil, from: String? = nil) {
        self.name = name
        self.part = part
        self.worker = worker
        self.branch = branch
        self.worktree = worktree
        self.wallSeen = wallSeen
        self.mainRedTold = mainRedTold
        self.from = from
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

    /// The workers a board's running team tasks run beside their integrators (an integrator is its task's one worker,
    /// as a plain task's is): each other member whose worker is in `live`.
    public static func memberWorkers(_ board: LeadBoard, live: Set<String>) -> Int {
        board.tasks.filter { $0.status == .running }.reduce(0) { count, task in
            count + (task.team ?? []).dropFirst().filter { $0.worker.map(live.contains) ?? false }.count
        }
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
        counts for the task: report done once every part is in agent/\(task.slug) and the acceptance checks pass there. \
        Until the team's tools for taking a part in arrive, ask_lead when a member's part is ready.
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
        \(integrator) reports for the task (your report is refused): once your part passes its own tests and everything's \
        committed, say so with progress ("part done") and ask_lead, so \(integrator) takes it in.
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

    /// What a worker has beyond a plain worker's tools: `split`, for a team task's integrator.
    var teamTools: [MCPToolInfo] {
        guard role == .worker, let taskID, store.load().task(taskID)?.isTeam == true else { return [] }
        return [Self.splitTool]
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
                      + "Once your part passes its own tests and everything's committed, say so with progress (\"part done\") and ask_lead, so \(integrator) takes it in.")
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
    /// Called holding start_worker's lock.
    func startMembers(_ task: LeadTask, sessions: [LeadSessionInfo], overrideUsage: Bool) throws -> MCPToolResult? {
        guard let team = task.team, task.isTeam, LeadTeam.isSplit(team), task.status == .running,
              let integrator = task.worker, sessions.contains(where: { $0.id == integrator && $0.live }) else { return nil }
        let slug = task.slug
        if let problem = LeadTeam.problem(team, slug: slug, root: root) {
            throw Problem(text: "No member of \(slug) started: its team as the board holds it isn't valid (\(problem)). Tell the user.")
        }
        let pending = team.dropFirst().filter { member in member.worker.map { id in !sessions.contains { $0.id == id && $0.live } } ?? true }
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
            if let worker = member.worker, live.contains(worker) { continue }
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
            guard let result = try startMembers(task, sessions: try hostSessions("no member of \(slug) was started"), overrideUsage: false) else {
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
