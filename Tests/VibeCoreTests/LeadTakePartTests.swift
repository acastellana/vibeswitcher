import Foundation
import Testing
@testable import VibeCore

/// A team task's parts coming together (docs/process/reviews/team-on-one-task-design.md, "The unit" and
/// "Integration"; T7): a member reports `part_done` with a three-part handoff (no audit, no merge; its integrator is
/// told once); the integrator's `take_part(member)` has its tool server merge that member's reported commit into
/// agent/<slug>, a conflict left for it; and only the integrator's done counts, once every part is taken. A team
/// `build-it` of core (the integrator, session-1), ui (session-2) and docs (session-3), on a scratch repository and a
/// fake session host.
struct LeadTakePartTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    struct Team {
        var root: String
        var runtime: FakeRuntime
        var lead: LeadToolset
        var core: LeadToolset
        var ui: LeadToolset
        var docs: LeadToolset
        var worktree: String { Worktrees.path(root: root, slug: "build-it") }
        func folder(_ member: String) -> String { Worktrees.path(root: root, slug: "build-it--\(member)") }
    }

    func repo() throws -> String {
        let url = temp.url("parts")
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

    /// The team, its integrator started; split and its members running unless `split` is false.
    func team(split: Bool = true) throws -> Team {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        let configured = lead.call("configure", ["max_workers": 6, "test_command": "true"])
        #expect(!configured.isError, "\(configured.text)")
        let parts: [[String: Any]] = [["name": "core", "part": "the shared types"], ["name": "ui", "part": "the views"], ["name": "docs", "part": "the guide"]]
        let added = lead.call("add_task", ["title": "Build it", "goal": "It's built", "acceptance": ["swift test passes"], "team": parts])
        #expect(!added.isError, "\(added.text)")
        #expect(!lead.call("start_worker", ["task": "build-it"]).isError)
        let core = try seat("worker-build-it", runtime)
        guard split else { return Team(root: root, runtime: runtime, lead: lead, core: core, ui: core, docs: core) }
        try commit("api.swift", "protocol API {}\n", in: Worktrees.path(root: root, slug: "build-it"))
        let splat = core.call("split", [:])
        #expect(!splat.isError, "\(splat.text)")
        let members = lead.call("start_worker", ["task": "build-it"])
        #expect(!members.isError, "\(members.text)")
        #expect(runtime.spawned.map(\.id) == ["session-1", "session-2", "session-3"])
        return Team(root: root, runtime: runtime, lead: lead, core: core,
                    ui: try seat("worker-build-it--ui", runtime), docs: try seat("worker-build-it--docs", runtime))
    }

    func task(_ team: Team) -> LeadTask? { BoardStore(root: team.root).load().task("build-it") }

    static func handoff(_ member: String) -> [String: Any] {
        ["status": "part_done", "changed": "Sources/\(member).swift: the \(member) part, using API",
         "caveats": "none", "verify": "bash scripts/test.sh --filter \(member.capitalized)Tests"]
    }

    /// `member` commits `file` and reports its part done.
    @discardableResult
    func partDone(_ team: Team, _ member: String, file: String? = nil, text: String? = nil) throws -> MCPToolResult {
        let tools = member == "ui" ? team.ui : team.docs
        try commit(file ?? "\(member).swift", text ?? "struct \(member.capitalized) {}\n", in: team.folder(member))
        let result = tools.call("report", Self.handoff(member))
        #expect(!result.isError, "\(result.text)")
        return result
    }

    /// The part_done notices a session got.
    func notices(_ team: Team, to session: String) -> [String] {
        team.runtime.steered.filter { $0.target == session && $0.text.contains("reports its part done") }.map(\.text)
    }

    func inBranch(_ commit: String, _ team: Team) -> Bool {
        Git.run(["merge-base", "--is-ancestor", commit, "refs/heads/agent/build-it"], in: team.root).ok
    }

    @Test func partDoneMarksThePartStartsNoAuditAndTellsTheIntegratorOnce() throws {
        let team = try team()
        let reply = try partDone(team, "ui")
        #expect(reply.text.contains("No audit or merge starts") && reply.text.contains("take_part(ui)"), "\(reply.text)")
        let head = Git.run(["rev-parse", "HEAD"], in: team.folder("ui")).output
        let handoff = try #require(task(team)?.teamMember("ui")?.handoff)
        #expect(handoff.commit == head && handoff.caveats == "none" && handoff.verify == "bash scripts/test.sh --filter UiTests")
        // No audit, no merge, nothing changed on the task: it runs on, its integrator its worker.
        #expect(task(team)?.status == .running && task(team)?.auditNeeded == nil && task(team)?.evidence == nil)
        #expect(team.runtime.spawned.count == 3)
        #expect(!team.runtime.steered.contains { $0.text.contains("says it's done") })
        // A member's tool server can't reach the integrator's session: the lead's delivers the notice, once.
        #expect(notices(team, to: "session-1").isEmpty)
        team.lead.deliverParts()
        team.lead.deliverParts()
        team.lead.deliverParts()
        let got = notices(team, to: "session-1")
        #expect(got.count == 1)
        let notice = try #require(got.first)
        #expect(notice.contains("Member ui of build-it's team") && notice.contains("> Sources/ui.swift: the ui part, using API")
                && notice.contains("> bash scripts/test.sh --filter UiTests") && notice.contains("take_part(ui)"), "\(notice)")
        #expect(team.runtime.steered.first { $0.text == notice }?.sender == .lead("lead of \(LeadMail.project(of: team.root))"))
        #expect(task(team)?.teamMember("ui")?.handoff?.told == "session-1")
        // No other member is told.
        #expect(notices(team, to: "session-2").isEmpty && notices(team, to: "session-3").isEmpty)
    }

    @Test func aNoticeThatDidntGoIsSentAgainNextTime() throws {
        let team = try team()
        try partDone(team, "ui")
        team.runtime.delivery = .notSubmitted("Member ui")
        team.lead.deliverParts()
        #expect(task(team)?.teamMember("ui")?.handoff?.told == nil)
        team.runtime.delivery = .steered
        team.lead.deliverParts()
        team.lead.deliverParts()
        #expect(notices(team, to: "session-1").count == 2)
        #expect(task(team)?.teamMember("ui")?.handoff?.told == "session-1")
    }

    @Test func partDoneNeedsItsHandoffAndACommittedPart() throws {
        let team = try team()
        // Nothing committed since the split.
        let empty = team.ui.call("report", Self.handoff("ui"))
        #expect(empty.isError && empty.text.contains("no commit since the split"), "\(empty.text)")
        try commit("ui.swift", "struct UI {}\n", in: team.folder("ui"))
        // Each of the three parts is required.
        for key in ["changed", "caveats", "verify"] {
            var arguments = Self.handoff("ui")
            arguments[key] = "  "
            let refused = team.ui.call("report", arguments)
            #expect(refused.isError && refused.text.contains("three parts") && refused.text.contains("\(key) is missing"), "\(refused.text)")
        }
        // A credential's shape never goes to the integrator.
        var secret = Self.handoff("ui")
        secret["caveats"] = "token=sk-abcdefabcdefabcdefabcdef1234"
        #expect(team.ui.call("report", secret).isError)
        // Uncommitted changes: the integrator's take wouldn't hold them.
        try "draft\n".write(toFile: team.folder("ui") + "/draft.txt", atomically: true, encoding: .utf8)
        let dirty = team.ui.call("report", Self.handoff("ui"))
        #expect(dirty.isError && dirty.text.contains("uncommitted changes") && dirty.text.contains("draft.txt"), "\(dirty.text)")
        #expect(task(team)?.teamMember("ui")?.handoff == nil)
        try FileManager.default.removeItem(atPath: team.folder("ui") + "/draft.txt")
        #expect(!team.ui.call("report", Self.handoff("ui")).isError)
        // Again on the same commit: nothing new.
        let again = team.ui.call("report", Self.handoff("ui"))
        #expect(again.isError && again.text.contains("already"), "\(again.text)")
    }

    @Test func takePartMergesThatMembersPartIntoTheTeamBranch() throws {
        let team = try team()
        try partDone(team, "ui")
        let commit = try #require(task(team)?.teamMember("ui")?.handoff?.commit)
        let taken = team.core.call("take_part", ["member": "ui"])
        #expect(!taken.isError, "\(taken.text)")
        #expect(taken.text.contains("Took ui's part") && taken.text.contains("run its command: bash scripts/test.sh --filter UiTests"), "\(taken.text)")
        #expect(taken.text.contains("Parts not taken yet: docs"), "\(taken.text)")
        #expect(inBranch(commit, team))
        #expect(FileManager.default.fileExists(atPath: team.worktree + "/ui.swift"))
        #expect(Git.run(["status", "--porcelain"], in: team.worktree).output.isEmpty)
        #expect(Git.run(["log", "-1", "--format=%s"], in: team.worktree).output == "Take ui's part: agent/build-it--ui at \(commit.prefix(8))")
        // Again: nothing to take.
        let again = team.core.call("take_part", ["member": "@ui"])
        #expect(!again.isError && again.text.contains("already"), "\(again.text)")
    }

    @Test func aConflictingPartIsLeftInProgressForTheIntegrator() throws {
        let team = try team()
        try commit("shared.txt", "core's\n", in: team.worktree)
        try partDone(team, "ui", file: "shared.txt", text: "ui's\n")
        let taken = team.core.call("take_part", ["member": "ui"])
        #expect(!taken.isError, "\(taken.text)")
        #expect(taken.text.contains("stopped on conflicts") && taken.text.contains("shared.txt") && taken.text.contains("left in progress"), "\(taken.text)")
        #expect(taken.text.contains("run its command: bash scripts/test.sh --filter UiTests"))
        #expect(Git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: team.worktree).ok)
        // Not taken while it's in progress: the next take waits for it, and the done names ui.
        try partDone(team, "docs")
        let next = team.core.call("take_part", ["member": "docs"])
        #expect(next.isError && next.text.contains("merge is in progress"), "\(next.text)")
        let done = team.core.call("report", doneReport("built"))
        #expect(done.isError && done.text.contains("ui (done at"), "\(done.text)")
        // The integrator resolves it and commits: ui's part is in.
        try "both\n".write(toFile: team.worktree + "/shared.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "shared.txt"], in: team.worktree)
        #expect(Worktrees.noEditor(["commit", "-q", "--no-edit"], in: team.worktree).ok)
        #expect(inBranch(try #require(task(team)?.teamMember("ui")?.handoff?.commit), team))
        #expect(!team.core.call("take_part", ["member": "docs"]).isError)
    }

    @Test func takePartIsRefusedToANonIntegratorAnUnknownMemberAPartNotDoneAndADirtyWorktree() throws {
        let team = try team()
        try partDone(team, "ui")
        // A member: it has no take_part (refused before the tool runs), and the tool itself refuses it too.
        let member = team.docs.call("take_part", ["member": "ui"])
        #expect(member.isError && member.text.contains("No tool take_part"), "\(member.text)")
        #expect(throws: LeadToolset.Problem.self) { try team.docs.takePart(["member": "ui"]) }
        #expect(!team.docs.tools.map(\.name).contains("take_part") && team.core.tools.map(\.name).contains("take_part"))
        // An unknown member, and the integrator itself.
        let unknown = team.core.call("take_part", ["member": "zed"])
        #expect(unknown.isError && unknown.text.contains("isn't a member") && unknown.text.contains("ui, docs"), "\(unknown.text)")
        let itself = team.core.call("take_part", ["member": "core"])
        #expect(itself.isError && itself.text.contains("is you"), "\(itself.text)")
        // A part not reported done: refused, not taken with a warning.
        try commit("docs.md", "guide\n", in: team.folder("docs"))
        let notDone = team.core.call("take_part", ["member": "docs"])
        #expect(notDone.isError && notDone.text.contains("hasn't reported its part done"), "\(notDone.text)")
        // A member that committed after its part_done.
        try commit("ui2.swift", "struct More {}\n", in: team.folder("ui"))
        let moved = team.core.call("take_part", ["member": "ui"])
        #expect(moved.isError && moved.text.contains("committed since its part_done"), "\(moved.text)")
        #expect(!team.ui.call("report", Self.handoff("ui")).isError)
        // Uncommitted changes in the integrator's worktree.
        try "wip\n".write(toFile: team.worktree + "/api.swift", atomically: true, encoding: .utf8)
        let dirty = team.core.call("take_part", ["member": "ui"])
        #expect(dirty.isError && dirty.text.contains("uncommitted changes") && dirty.text.contains("api.swift"), "\(dirty.text)")
        #expect(!inBranch(try #require(task(team)?.teamMember("ui")?.handoff?.commit), team))
        // A plain task's worker.
        #expect(!team.lead.call("add_task", ["title": "Plain one", "goal": "g", "acceptance": ["a"]]).isError)
        let plainWorker = try issued(.worker, task: "plain-one", root: team.root, team.runtime, session: "plain-session")
        let refused = plainWorker.call("take_part", ["member": "ui"])
        #expect(refused.isError && refused.text.contains("No tool take_part"), "\(refused.text)")
        #expect(!plainWorker.tools.map(\.name).contains("take_part"))
        #expect(throws: LeadToolset.Problem.self) { try plainWorker.takePart(["member": "ui"]) }
    }

    @Test func theIntegratorsDoneIsRefusedNamingThePartsNotTakenUntilAllAre() throws {
        let team = try team()
        let none = team.core.call("report", doneReport("built"))
        #expect(none.isError && none.text.contains("ui (no part_done yet)") && none.text.contains("docs (no part_done yet)"), "\(none.text)")
        #expect(task(team)?.status == .running && task(team)?.report == nil)
        try partDone(team, "ui")
        try partDone(team, "docs")
        let notTaken = team.core.call("report", doneReport("built"))
        #expect(notTaken.isError && notTaken.text.contains("ui (done at") && notTaken.text.contains("take_part(docs)"), "\(notTaken.text)")
        #expect(!team.core.call("take_part", ["member": "ui"]).isError)
        let one = team.core.call("report", doneReport("built"))
        #expect(one.isError && !one.text.contains("ui (") && one.text.contains("docs (done at"), "\(one.text)")
        #expect(!team.core.call("take_part", ["member": "docs"]).isError)
        // A member that commits after its part was taken: its part isn't done as it stands.
        try commit("late.swift", "struct Late {}\n", in: team.folder("docs"))
        let late = team.core.call("report", doneReport("built"))
        #expect(late.isError && late.text.contains("docs (committed since its part_done"), "\(late.text)")
        #expect(!team.docs.call("report", Self.handoff("docs")).isError)
        #expect(!team.core.call("take_part", ["member": "docs"]).isError)
        // Every part in: today's path (the pre-done check, then review).
        let done = team.core.call("report", doneReport("built"))
        #expect(!done.isError, "\(done.text)")
        #expect(task(team)?.status == .review && task(team)?.report == "built")
        #expect(team.runtime.steered.contains { $0.target == "agent:4242" && $0.text.contains("The worker on build-it says it's done") })
    }

    @Test func anUnsplitTeamsDoneIsRefused() throws {
        let team = try team(split: false)
        try commit("api.swift", "protocol API {}\n", in: team.worktree)
        let done = team.core.call("report", doneReport("built"))
        #expect(done.isError && done.text.contains("isn't split yet"), "\(done.text)")
        #expect(task(team)?.status == .running)
    }

    @Test func aMembersDoneIsRefusedAndItsBlockedAndOverBudgetReachTheLeadNamingIt() throws {
        let team = try team()
        let done = team.ui.call("report", doneReport("my part"))
        #expect(done.isError && done.text.contains("Only build-it's integrator, core") && done.text.contains("report(status: part_done"), "\(done.text)")
        #expect(team.ui.tools.first { $0.name == "report" }?.properties["status"]?.options == ["part_done", "blocked", "over_budget"])
        let blocked = team.ui.call("report", ["status": "blocked", "summary": "the API lacks a hook"])
        #expect(!blocked.isError, "\(blocked.text)")
        #expect(team.runtime.steered.contains { $0.target == "agent:4242" && $0.text.contains("Member ui of build-it's team is blocked: the API lacks a hook") })
        let over = team.docs.call("report", ["status": "over_budget", "summary": "guide half written"])
        #expect(!over.isError, "\(over.text)")
        #expect(team.runtime.steered.contains { $0.target == "agent:4242" && $0.text.contains("Member docs of build-it's team says it's over the task's time budget") })
        // The task runs on: its integrator works; nothing is recorded as the task's.
        #expect(task(team)?.status == .running && task(team)?.blocker == nil && task(team)?.overBudget == nil)
        let blank = team.ui.call("report", ["status": "blocked"])
        #expect(blank.isError)
    }

    @Test func partDoneIsNoReportForAPlainWorkerOrTheIntegrator() throws {
        let team = try team()
        let integrator = team.core.call("report", Self.handoff("core"))
        #expect(integrator.isError && integrator.text.contains("take_part each member's done part"), "\(integrator.text)")
        #expect(!team.lead.call("add_task", ["title": "Plain one", "goal": "g", "acceptance": ["a"]]).isError)
        let plain = try issued(.worker, task: "plain-one", root: team.root, team.runtime, session: "plain-session")
        let refused = plain.call("report", ["status": "part_done", "summary": "x"])
        #expect(refused.isError && refused.text.contains("plain task"), "\(refused.text)")
        #expect(BoardStore(root: team.root).load().task("plain-one")?.status == .planned)
    }

    @Test func aTamperedTeamOnTheBoardIsNeitherMergedNorAnnounced() throws {
        let team = try team()
        try partDone(team, "ui")
        // Another task's branch, put in ui's place on the board (a worker's shell can write it), with its head.
        Git.run(["branch", "agent/other", "main"], in: team.root)
        let other = Git.run(["rev-parse", "agent/other"], in: team.root).output
        try BoardStore(root: team.root).update { board in
            guard let index = board.taskIndex("build-it") else { return }
            board.tasks[index].team?[1].branch = "agent/other"
            board.tasks[index].team?[1].handoff?.commit = other
        }
        let before = Git.run(["rev-parse", "HEAD"], in: team.worktree).output
        let taken = team.core.call("take_part", ["member": "ui"])
        #expect(taken.isError && taken.text.contains("isn't valid"), "\(taken.text)")
        #expect(Git.run(["rev-parse", "HEAD"], in: team.worktree).output == before)
        team.lead.deliverParts()
        #expect(notices(team, to: "session-1").isEmpty)
    }

    @Test func aPartTakenBeforeItsNoticeIsNotAnnouncedAgain() throws {
        let team = try team()
        try partDone(team, "ui")
        #expect(!team.core.call("take_part", ["member": "ui"]).isError)
        team.lead.deliverParts()
        #expect(notices(team, to: "session-1").isEmpty)
        #expect(task(team)?.teamMember("ui")?.handoff?.told == "session-1")
    }
}
