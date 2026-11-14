import Foundation
import Testing
@testable import VibeCore

/// A team task's start (docs/process/reviews/team-on-one-task-design.md, "The unit"; T5): its first worker is the
/// integrator, alone on agent/<slug>; its `split` branches every other member from the integrator's commit; and the
/// lead's tools (start_worker, auto_advance) start the members' workers within max_workers and the Mac's limits. On
/// scratch repositories and a fake session host only.
struct LeadSplitTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let parts: [[String: Any]] = [
        ["name": "core", "part": "CORE-PART: Sources/Core.swift, the shared types"],
        ["name": "ui", "part": "UI-PART: Sources/UI.swift and its tests"],
        ["name": "docs", "part": "DOCS-PART: docs/guide.md"],
    ]

    func repo() throws -> String {
        let url = temp.url("split")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try commit("a.txt", "one\n", in: root)
        return root
    }

    @discardableResult
    func commit(_ file: String, _ text: String, in dir: String) throws -> String {
        try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        Git.run(["commit", "-q", "-m", "change \(file)"], in: dir)
        return Git.run(["rev-parse", "HEAD"], in: dir).output
    }

    func task(_ root: String) -> LeadTask? { BoardStore(root: root).load().task("build-it") }
    func prompt(_ root: String, _ name: String) throws -> String {
        try String(contentsOf: vault.runFolder(root: root, name: name).appendingPathComponent("prompt.md"), encoding: .utf8)
    }

    /// A lead with a team task `build-it` of `parts` (core the integrator), its integrator started; `settings` configured
    /// first.
    func started(_ settings: [String: Any] = [:], parts: [[String: Any]] = Self.parts) throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        if !settings.isEmpty {
            let configured = lead.call("configure", settings)
            #expect(!configured.isError, "\(configured.text)")
        }
        let added = lead.call("add_task", ["title": "Build it", "goal": "It's built", "acceptance": ["swift test passes"], "team": parts])
        #expect(!added.isError, "\(added.text)")
        let start = lead.call("start_worker", ["task": "build-it"])
        #expect(!start.isError, "\(start.text)")
        return (root, runtime, lead)
    }

    /// The integrator commits the shared interface and splits; the result.
    func split(_ root: String, _ runtime: FakeRuntime) throws -> MCPToolResult {
        try commit("api.swift", "protocol API {}\n", in: Worktrees.path(root: root, slug: "build-it"))
        return try seat("worker-build-it", runtime).call("split", [:])
    }

    @Test func theIntegratorStartsAloneAndSplitBranchesAndTheLeadStartsTheMembers() throws {
        let (root, runtime, lead) = try started()
        let worktree = Worktrees.path(root: root, slug: "build-it")
        // The first worker is the integrator, alone, on agent/<slug>.
        #expect(runtime.spawned.map(\.cwd) == [worktree])
        #expect(Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree).output == "agent/build-it")
        let integrator = try #require(task(root)?.worker)
        #expect(task(root)?.team?.first?.worker == integrator)
        let brief = try prompt(root, "worker-build-it")
        #expect(brief.contains("branch agent/build-it, and nowhere else"))
        #expect(brief.contains("you are core, the integrator") && brief.contains("call `split`") && brief.contains("CORE-PART"))
        #expect(brief.contains("- ui: UI-PART") && brief.contains("- docs: DOCS-PART"))
        // Its tools have split; it starts no session itself.
        let seat = try seat("worker-build-it", runtime)
        #expect(seat.tools.map(\.name).contains("split"))

        let head = try commit("api.swift", "protocol API {}\n", in: worktree)
        let split = seat.call("split", [:])
        #expect(!split.isError, "\(split.text)")
        #expect(runtime.spawned.count == 1)
        for name in ["ui", "docs"] {
            let member = Worktrees.path(root: root, slug: "build-it--\(name)")
            #expect(Git.run(["rev-parse", "HEAD"], in: member).output == head)
            #expect(Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: member).output == "agent/build-it--\(name)")
            #expect(task(root)?.teamMember(name)?.from == head)
        }
        // The lead is told to start them (auto_advance isn't running here).
        #expect(runtime.steered.contains { $0.target == "agent:4242" && $0.text.contains("split its team") && $0.text.contains("start_worker(build-it)") })

        let members = lead.call("start_worker", ["task": "build-it"])
        #expect(!members.isError, "\(members.text)")
        #expect(members.text.contains("ui, docs"))
        #expect(runtime.spawned.map(\.cwd) == [worktree, Worktrees.path(root: root, slug: "build-it--ui"), Worktrees.path(root: root, slug: "build-it--docs")])
        let ui = try #require(task(root)?.teamMember("ui")?.worker)
        #expect(ui == runtime.spawned[1].id && task(root)?.teamMember("docs")?.worker == runtime.spawned[2].id)
        // The integrator stays the task's worker, its grant kept: its tools still work.
        #expect(task(root)?.worker == integrator)
        #expect(!seat.call("progress", ["text": "interface in"]).isError)

        // A member's brief: its own part, its own branch, the integrator's name; no other member's part.
        let uiBrief = try prompt(root, "worker-build-it--ui")
        #expect(uiBrief.contains("branch agent/build-it--ui, and nowhere else"))
        #expect(uiBrief.contains("you are ui, a member") && uiBrief.contains("core is its integrator") && uiBrief.contains("UI-PART"))
        #expect(uiBrief.contains("It's built") && uiBrief.contains("swift test passes"))
        #expect(!uiBrief.contains("DOCS-PART") && !uiBrief.contains("CORE-PART"))
        #expect(!uiBrief.contains("agent/build-it, and nowhere else"))

        // A member: no split, no report for the task; its progress is its own line on the task's lane.
        let member = try self.seat("worker-build-it--ui", runtime)
        #expect(!member.tools.map(\.name).contains("split"))
        #expect(member.call("split", [:]).isError)
        let report = member.call("report", doneReport("my part"))
        #expect(report.isError && report.text.contains("Only build-it's integrator, core"), "\(report.text)")
        #expect(task(root)?.status == .running)
        #expect(!member.call("progress", ["text": "lexer done"]).isError)
        #expect(task(root)?.checkpoints?.last?.text == "ui: lexer done")

        // Split once; and nothing more to start.
        let again = seat.call("split", [:])
        #expect(again.isError && again.text.contains("split already"), "\(again.text)")
        let more = lead.call("start_worker", ["task": "build-it"])
        #expect(more.isError && more.text.contains("already run"), "\(more.text)")
        #expect(runtime.spawned.count == 3)
    }

    @Test func splitIsRefusedForAPlainTaskAndWithUncommittedChanges() throws {
        let (root, runtime, lead) = try started()
        // A plain task's worker has no split, and a plain worker's tools are as they were.
        #expect(!lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"]]).isError)
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        let plain = try seat("worker-plain", runtime)
        #expect(plain.tools.map(\.name) == ["report", "ask_lead", "progress", "answer_findings"])
        #expect(plain.call("split", [:]).isError)
        #expect(!(try prompt(root, "worker-plain")).contains("Team task"))

        // Uncommitted changes in the integrator's worktree: refused, nothing branched.
        let worktree = Worktrees.path(root: root, slug: "build-it")
        try commit("api.swift", "protocol API {}\n", in: worktree)
        try "half\n".write(toFile: worktree + "/api.swift", atomically: true, encoding: .utf8)
        let seat = try seat("worker-build-it", runtime)
        let dirty = seat.call("split", [:])
        #expect(dirty.isError && dirty.text.contains("uncommitted changes") && dirty.text.contains("api.swift"), "\(dirty.text)")
        #expect(Worktrees.members(root: root, slug: "build-it").isEmpty)
        #expect(task(root)?.team.map(LeadTeam.isSplit) == false)
        // start_worker on the unsplit task with its integrator running: refused as ever.
        #expect(lead.call("start_worker", ["task": "build-it"]).isError)
        #expect(runtime.spawned.count == 2)
    }

    /// The stored team is checked before an integrator or a member starts, and before a split.
    @Test func aBrokenStoredTeamIsRefusedWithItsProblem() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        #expect(!lead.call("add_task", ["title": "Build it", "goal": "g", "acceptance": ["a"], "team": Self.parts]).isError)
        try BoardStore(root: root).update { board in
            let index = try #require(board.taskIndex("build-it"))
            board.tasks[index].team?[1].branch = "agent/other-task"
        }
        let refused = lead.call("start_worker", ["task": "build-it"])
        #expect(refused.isError && refused.text.contains("isn't valid") && refused.text.contains("agent/other-task"), "\(refused.text)")
        #expect(runtime.spawned.isEmpty)

        // Broken after the integrator started: its split is refused, nothing branched.
        try BoardStore(root: root).update { board in
            let index = try #require(board.taskIndex("build-it"))
            board.tasks[index].team?[1].branch = "agent/build-it--ui"
        }
        #expect(!lead.call("start_worker", ["task": "build-it"]).isError)
        try BoardStore(root: root).update { board in
            let index = try #require(board.taskIndex("build-it"))
            board.tasks[index].team?[2].worktree = root + "/elsewhere"
        }
        let split = try split(root, runtime)
        #expect(split.isError && split.text.contains("isn't valid") && split.text.contains("elsewhere"), "\(split.text)")
        #expect(Worktrees.members(root: root, slug: "build-it").isEmpty)
    }

    /// max_workers counts live members: those without room stay queued, named, and start on a later start_worker.
    @Test func membersWithoutRoomUnderMaxWorkersWaitQueued() throws {
        let (root, runtime, lead) = try started(["max_workers": 2])
        #expect(!(try split(root, runtime)).isError)
        let first = lead.call("start_worker", ["task": "build-it"])
        #expect(!first.isError, "\(first.text)")
        #expect(first.text.contains("Started") && first.text.contains("ui") && first.text.contains("Queued: docs") && first.text.contains("max_workers is 2"), "\(first.text)")
        #expect(runtime.spawned.count == 2)
        #expect(task(root)?.teamMember("docs")?.worker == nil)
        // Still no room: refused whole, docs named as queued.
        let full = lead.call("start_worker", ["task": "build-it"])
        #expect(full.isError && full.text.contains("docs queued"), "\(full.text)")
        // Live members count for any other task's start too.
        #expect(!lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"]]).isError)
        let plain = lead.call("start_worker", ["task": "plain"])
        #expect(plain.isError && plain.text.contains("2 workers already run"), "\(plain.text)")

        // Room again: the queued one starts, once.
        #expect(!lead.call("configure", ["max_workers": 3]).isError)
        let second = lead.call("start_worker", ["task": "build-it"])
        #expect(!second.isError && second.text.contains("docs"), "\(second.text)")
        #expect(runtime.spawned.count == 3 && task(root)?.teamMember("docs")?.worker == runtime.spawned[2].id)
    }

    /// The Mac-wide limits hold members back as they hold any worker.
    @Test func membersWithoutRoomOnTheMacWaitQueued() throws {
        let (root, runtime, lead) = try started()
        #expect(!(try split(root, runtime)).isError)
        // The integrator and one more: the Mac's team sessions are full after the first member.
        lead.macLimits = { MacLimits(maxSessions: 2) }
        let started = lead.call("start_worker", ["task": "build-it"])
        #expect(!started.isError, "\(started.text)")
        #expect(started.text.contains("Queued: docs") && started.text.contains("mac_max_sessions"), "\(started.text)")
        #expect(runtime.spawned.count == 2)
    }

    /// A split team whose integrator ended: start_worker starts its integrator again, alone, told it's split; no member
    /// starts by the lead's tools or auto_advance until it runs.
    @Test func anEndedIntegratorStartsAgainAloneBeforeAnyMember() throws {
        let (root, runtime, lead) = try started()
        #expect(!(try split(root, runtime)).isError)
        runtime.calls.withLock { runtime.killed.append(runtime.spawned[0].id) }
        #expect(throws: LeadAdvance.NotDue.self) { try lead.advanceMembers("build-it") }
        #expect(runtime.spawned.count == 1)
        let again = lead.call("start_worker", ["task": "build-it"])
        #expect(!again.isError, "\(again.text)")
        #expect(runtime.spawned.count == 2 && runtime.spawned[1].cwd == Worktrees.path(root: root, slug: "build-it"))
        #expect(task(root)?.worker == runtime.spawned[1].id && task(root)?.team?.first?.worker == runtime.spawned[1].id)
        #expect(task(root)?.team?.dropFirst().allSatisfy { $0.worker == nil } == true)
        #expect(try prompt(root, "worker-build-it").contains("The team is split already"))
    }

    /// Members run on Claude, whatever the task's agent: their brief has no Codex part.
    @Test func membersRunOnClaude() throws {
        let (root, runtime, lead) = try started()
        let codex = lead.call("update_task", ["task": "build-it", "agent": "codex"])
        #expect(!codex.isError, "\(codex.text)")
        #expect(!(try split(root, runtime)).isError)
        let members = lead.call("start_worker", ["task": "build-it"])
        #expect(!members.isError, "\(members.text)")
        let ui = try #require(task(root)?.teamMember("ui")?.worker)
        #expect(runtime.agents[ui] == "claude")
        #expect(!(try prompt(root, "worker-build-it--ui")).contains("You run in the Codex CLI"))
    }

    /// add_task's and update_task's team: checked as LeadTeam.make checks it, and only before a split.
    @Test func theLeadSetsAndClearsATeamBeforeItsSplitOnly() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        let tooMany = lead.call("add_task", ["title": "Big", "goal": "g", "acceptance": ["a"],
                                             "team": (1...5).map { ["name": "m\($0)", "part": "p"] }])
        #expect(tooMany.isError && tooMany.text.contains("2 to 4"), "\(tooMany.text)")
        let badName = lead.call("add_task", ["title": "Big", "goal": "g", "acceptance": ["a"], "team": [["name": "A b", "part": "p"], ["name": "c", "part": "p"]]])
        #expect(badName.isError)
        #expect(BoardStore(root: root).load().tasks.isEmpty)
        #expect(!lead.call("add_task", ["title": "Build it", "goal": "g", "acceptance": ["a"]]).isError)
        #expect(task(root)?.isTeam == false)
        let set = lead.call("update_task", ["task": "build-it", "team": Self.parts])
        #expect(!set.isError && set.text.contains("core (integrator), ui, docs"), "\(set.text)")
        #expect(task(root)?.team?.map(\.branch) == ["agent/build-it", "agent/build-it--ui", "agent/build-it--docs"])
        #expect(!lead.call("update_task", ["task": "build-it", "team": []]).isError)
        #expect(task(root)?.team == nil)
        #expect(!lead.call("update_task", ["task": "build-it", "team": Self.parts]).isError)
        #expect(!lead.call("start_worker", ["task": "build-it"]).isError)
        // Running: its integrator's brief has the team it started with.
        #expect(lead.call("update_task", ["task": "build-it", "team": []]).isError)
        #expect(task(root)?.isTeam == true)
    }

    /// A team task's re-roll ends its members' workers, keeps their branches as archives, removes their worktrees and
    /// branches, and its fresh integrator starts unsplit.
    @Test func aRerollStopsTheMembersAndArchivesTheirBranches() throws {
        let (root, runtime, lead) = try started()
        #expect(!(try split(root, runtime)).isError)
        #expect(!lead.call("start_worker", ["task": "build-it"]).isError)
        let ui = Worktrees.path(root: root, slug: "build-it--ui")
        let uiHead = try commit("ui.swift", "struct UI {}\n", in: ui)
        let members = [runtime.spawned[1].id, runtime.spawned[2].id]

        let rerolled = lead.call("update_task", ["task": "build-it", "reroll": true])
        #expect(!rerolled.isError, "\(rerolled.text)")
        #expect(Set(members).isSubset(of: Set(runtime.killed)))
        #expect(Git.run(["rev-parse", "refs/heads/archive/build-it-1--ui"], in: root).output == uiHead)
        #expect(Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/archive/build-it-1--docs"], in: root).ok)
        #expect(Worktrees.members(root: root, slug: "build-it").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ui))
        let team = try #require(task(root)?.team)
        #expect(!LeadTeam.isSplit(team) && team.dropFirst().allSatisfy { $0.worker == nil })
        // Its fresh integrator, alone, may split again.
        #expect(task(root)?.worker == runtime.spawned.last?.id && runtime.spawned.last?.cwd == Worktrees.path(root: root, slug: "build-it"))
        #expect(!(try split(root, runtime)).isError)
    }
}

/// auto_advance starts a split team's members by itself, as there's room, never twice; with auto_advance off it doesn't.
struct LeadSplitAdvanceTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("advance")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func task(_ root: String) -> LeadTask? { BoardStore(root: root).load().task("build-it") }

    /// A lead whose loop runs, with `settings`, a team task of three, its integrator started and split.
    func split(_ settings: [String: Any]) async throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset, advancing: LeadAdvanceTests.Advancing) {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        #expect(!lead.call("configure", settings).isError)
        #expect(!lead.call("add_task", ["title": "Build it", "goal": "g", "acceptance": ["a"], "team": LeadSplitTests.parts, "auto_advance": false]).isError)
        #expect(!lead.call("start_worker", ["task": "build-it"]).isError)
        if settings["auto_advance"] as? Bool != false { #expect(!lead.call("update_task", ["task": "build-it", "auto_advance": true]).isError) }
        let worktree = Worktrees.path(root: root, slug: "build-it")
        try "protocol API {}\n".write(toFile: worktree + "/api.swift", atomically: true, encoding: .utf8)
        Git.run(["add", "api.swift"], in: worktree)
        Git.run(["commit", "-q", "-m", "interface"], in: worktree)
        let advancing = LeadAdvanceTests.Advancing(lead)
        let split = try seat("worker-build-it", runtime).call("split", [:])
        #expect(!split.isError, "\(split.text)")
        return (root, runtime, lead, advancing)
    }

    func spawned(_ runtime: FakeRuntime) -> [String] { runtime.calls.withLock { runtime.spawned.map(\.cwd) } }

    @Test func queuedMembersStartByThemselvesWhenRoomFreesAndNeverTwice() async throws {
        let (root, runtime, lead, advancing) = try await split(["max_workers": 2])
        defer { advancing.stop() }
        let ui = Worktrees.path(root: root, slug: "build-it--ui"), docs = Worktrees.path(root: root, slug: "build-it--docs")
        #expect(await advancing.until { spawned(runtime).contains(ui) })
        await advancing.settle()
        #expect(!spawned(runtime).contains(docs) && task(root)?.teamMember("docs")?.worker == nil)

        // Room frees: docs starts by itself.
        #expect(!lead.call("configure", ["max_workers": 3]).isError)
        await advancing.settle()
        #expect(await advancing.until { spawned(runtime).contains(docs) })
        #expect(spawned(runtime).count == 3)

        // Never twice: more passes start nothing, a member whose worker ended included (that's the lead's to restart).
        runtime.calls.withLock { runtime.killed.append(runtime.spawned[1].id) }
        await advancing.settle()
        await advancing.settle()
        #expect(spawned(runtime).count == 3)
    }

    @Test func withAutoAdvanceOffNoMemberStartsByItself() async throws {
        let (root, runtime, lead, advancing) = try await split(["auto_advance": false])
        defer { advancing.stop() }
        await advancing.settle()
        await advancing.settle()
        #expect(spawned(runtime).count == 1)
        #expect(runtime.steered.contains { $0.text.contains("Start their workers with start_worker(build-it)") })
        // The lead starts them.
        let started = lead.call("start_worker", ["task": "build-it"])
        #expect(!started.isError, "\(started.text)")
        #expect(spawned(runtime).count == 3 && task(root)?.teamMember("docs")?.worker != nil)
    }
}

/// `Worktrees.members` and what goes by it count a member's folder only when it's a real worktree on its branch
/// (audit F1, F2 of member-worktrees-a-sub), and take the board's stored team over the disk. Scratch repositories only.
struct MemberCheckoutTests {
    let temp = Scratch()

    func repo() throws -> String {
        let url = temp.url("members")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// F1: a folder named like a member's that isn't a worktree isn't counted, and no git runs in it.
    @Test func aPlainFolderAtAMembersNameIsNoMember() throws {
        let root = try repo()
        try Worktrees.create(root: root, slug: "one")
        let folder = Worktrees.path(root: root, slug: "one--stray")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "mine\n".write(toFile: folder + "/keep.txt", atomically: true, encoding: .utf8)
        #expect(Worktrees.memberCheckout(root: root, slug: "one", member: "stray") == nil)
        #expect(Worktrees.members(root: root, slug: "one").isEmpty)
        guard case .success(let work) = Worktrees.memberWork(root: root, slug: "one", base: "main", merged: nil) else { Issue.record("memberWork failed"); return }
        #expect(work.isEmpty)
        #expect(try Worktrees.removeMembers(root: root, slug: "one").isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder + "/keep.txt"))
    }

    /// F2: a symlink at a member's name to another task's worktree, its branch there too, is never that member's
    /// worktree: not read, not removed (its branch is), and named in the failure.
    @Test func aSymlinkAtAMembersNameIsLeftAlone() throws {
        let root = try repo()
        let team = try Worktrees.create(root: root, slug: "one")
        let other = try Worktrees.create(root: root, slug: "other")
        try "work\n".write(toFile: other + "/unsaved.txt", atomically: true, encoding: .utf8)
        Git.run(["branch", "agent/one--x", Git.run(["rev-parse", "HEAD"], in: team).output], in: root)
        let link = Worktrees.path(root: root, slug: "one--x")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: other)
        #expect(Worktrees.memberCheckout(root: root, slug: "one", member: "x") == nil)
        // Counted by its branch; its folder isn't read.
        #expect(Worktrees.members(root: root, slug: "one") == ["x"])
        guard case .success(let work) = Worktrees.memberWork(root: root, slug: "one", base: "main", merged: nil) else { Issue.record("memberWork failed"); return }
        #expect(work.allSatisfy { $0.uncommitted.isEmpty })
        #expect(throws: Worktrees.Failure.self) { try Worktrees.removeMembers(root: root, slug: "one") }
        #expect(FileManager.default.fileExists(atPath: other + "/unsaved.txt") && Worktrees.isWorktree(root: root, slug: "other"))
        #expect(!Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/agent/one--x"], in: root).ok)
    }

    /// The board's stored team is taken over the disk: a leftover member's branch from another team isn't counted.
    @Test func theStoredTeamIsTakenOverTheDisk() throws {
        let root = try repo()
        let team = try Worktrees.create(root: root, slug: "one")
        let head = Git.run(["rev-parse", "HEAD"], in: team).output
        try Worktrees.createMember(root: root, slug: "one", member: "ui", from: head)
        Git.run(["branch", "agent/one--old", head], in: root)
        #expect(Worktrees.members(root: root, slug: "one") == ["old", "ui"])
        #expect(Worktrees.members(root: root, slug: "one", team: ["ui", "docs"]) == ["ui"])
        #expect(Worktrees.memberCheckout(root: root, slug: "one", member: "ui") == Worktrees.path(root: root, slug: "one--ui"))
        #expect(try Worktrees.removeMembers(root: root, slug: "one", team: ["ui"]) == ["ui"])
        #expect(Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/agent/one--old"], in: root).ok)
    }
}
