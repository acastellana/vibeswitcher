import Foundation
import Testing
@testable import VibeCore

/// start_worker looks before it starts (`LaunchPreflight`, through the runtime): a Mac without the worker's CLI gets a
/// clear error naming it, and no grant or session; one with everything starts the worker as before. The look runs in
/// an injected environment (`LaunchPreflightTests`' fake login shell, xcode-select and git).
struct StartWorkerPreflightTests: LeadTeamFixture {
    let temp = Scratch()
    /// The fake Macs' folders, kept as long as the test (removed with it).
    let macs = LaunchPreflightTests()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func added(_ lead: LeadToolset) {
        let added = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "boundaries": ["only b.txt"]])
        #expect(!added.isError, "\(added.text)")
    }

    @Test func aMacWithoutClaudeGetsAClearErrorAndNoWorker() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        runtime.preflight = try macs.make(.init(claude: false)).preflight
        let lead = try lead(root, runtime)
        added(lead)

        let refused = lead.call("start_worker", ["task": "add-b"])
        #expect(refused.isError)
        #expect(refused.text.hasPrefix("Not started: Claude Code isn't installed. VibeSwitcher starts it as `claude`"), "\(refused.text)")
        #expect(refused.text.contains("Install Claude Code") && refused.text.contains("never installs anything"))
        #expect(runtime.preflighted == [runtime.claude])
        #expect(runtime.spawned.isEmpty)
        // No grant left behind for the worker that didn't start.
        #expect(try vault.roster(root: root).allSatisfy { $0.role != .worker || !$0.holds })
        #expect(BoardStore(root: root).load().task("add-b")?.status == .planned)
    }

    @Test func aMacWithEverythingStartsTheWorkerAsBefore() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        runtime.preflight = try macs.make(.init()).preflight
        let lead = try lead(root, runtime)
        added(lead)

        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        #expect(runtime.preflighted == [runtime.claude])
        #expect(runtime.spawned.count == 1)
        #expect(runtime.spawned.first?.cwd == Worktrees.path(root: root, slug: "add-b"))
        #expect(runtime.spawned.first?.command.hasPrefix(runtime.claude + " --append-system-prompt-file") == true)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .running)
    }
}
