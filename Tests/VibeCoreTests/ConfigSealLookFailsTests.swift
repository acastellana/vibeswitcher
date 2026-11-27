import Foundation
import Testing
@testable import VibeCore

/// A look at the agents' config (`LeadVault.checkConfig`) that doesn't complete holds every gate that waits on
/// "nothing is held" (`LeadToolset.checkConfig(not:)`): a worker's or verifier's start, an audit's, a merge before
/// and after its tests, alone or in a batch, auto_advance's. None of them passes on the last completed record. Each
/// failure is the test vault's (`Failing`), never a real stall: the look's call throws as a timed-out host call does,
/// the host refuses it with something other than a hold, or the record can't be read.
struct ConfigSealLookFailsTests: LeadTeamFixture {
    let fixture = MergeBatchTests()
    var vault: LeadVault { fixture.vault }

    /// How the test vault's look fails while `Failing` is on.
    enum Shape: String, CaseIterable, Sendable {
        /// The look's call throws, as a host call that timed out does.
        case timedOut
        /// The host answers the look with a refusal that isn't the seal's hold.
        case refused
        /// The record (the guard rails' and the seal's) can't be read.
        case recordUnread
    }

    /// Whether the test vault's looks fail now: switched on by the test, or by the suite's run (`armed` and its marker
    /// file there), and off for good once `off`.
    final class Failing: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false, disabled = false
        var marker: String?
        var on: Bool {
            get { lock.lock(); defer { lock.unlock() }; return !disabled && (value || marker.map { FileManager.default.fileExists(atPath: $0) } == true) }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
        func off() { lock.lock(); disabled = true; lock.unlock() }
    }

    var zshrc: String { book.configHome + "/.zshrc" }

    /// A team whose lead's vault fails its looks as `shape` says while `failing` is on; `suite`: the test command's
    /// script, else one that passes.
    func scene(_ shape: Shape, _ failing: Failing, suite: String? = nil) throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        try FileManager.default.createDirectory(atPath: book.configHome, withIntermediateDirectories: true)
        try "export PATH\n".write(toFile: zshrc, atomically: true, encoding: .utf8)
        let scene = try fixture.team(["merge_batching": "always"], suite: suite ?? """
            #!/bin/bash
            echo run >> \(RecentProjects.shellQuote(fixture.runs))
            echo '✔ Test breaks() passed after 0.010 seconds.'
            echo '✔ Test run with 2 tests passed after 0.020 seconds.'
            """)
        let book = self.book
        nonisolated(unsafe) let runtime = scene.runtime
        let failingVault = LeadVault(folder: vault.folder) { request in
            if failing.on {
                switch (shape, request) {
                case (.timedOut, .setGuarded(_, let hashes)) where hashes[ConfigSeal.checkKey] != nil:
                    throw HostCall.Failure(description: "timed out after 5 s")
                case (.refused, .setGuarded(_, let hashes)) where hashes[ConfigSeal.checkKey] != nil:
                    return .refused("The session host answered something else.")
                case (.recordUnread, .guarded):
                    throw HostCall.Failure(description: "timed out after 5 s")
                default: break
                }
            }
            return book.answer(request, from: runtime.currentAgent()?.session.map { .session($0) } ?? .unknown)
        }
        let lead = LeadToolset(root: scene.root, runtime: scene.runtime, vault: failingVault)
        lead.testLock = fixture.testLock
        lead.power = { nil }
        lead.macLimits = { MacLimits(maxSessions: 12) }
        lead.roomWaits = fixture.roomWaits
        lead.usageStore = fixture.usageStore
        lead.auditSampleSeed = { unsampledSeed }
        return (scene.root, scene.runtime, lead)
    }

    func main(_ root: String) -> String { Git.run(["rev-parse", "main"], in: root).output }

    /// A worker ran (the team isn't quiet), ~/.zshrc changed, and every look fails: no worker or verifier starts,
    /// nothing merges or runs its tests. Once looks complete again, the change is held, named: it was never sealed.
    @Test(arguments: Shape.allCases)
    func aLookThatFailsHoldsEveryGateBeforeTheTests(shape: Shape) throws {
        let failing = Failing()
        let (root, runtime, lead) = try scene(shape, failing)
        try fixture.audited(lead, runtime, root: root, "add-x", ["x.txt": "x\n"], review: "none")
        try fixture.audited(lead, runtime, root: root, "add-y", ["y.txt": "y\n"], review: "none")
        // A task whose work is reported and waits for its audit.
        let added = lead.call("add_task", ["title": "add-z", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!added.isError, "\(added.text)")
        #expect(!lead.call("start_worker", ["task": "add-z"]).isError)
        try fixture.commit(["z.txt": "z\n"], in: Worktrees.path(root: root, slug: "add-z"), "add-z's work")
        #expect(!(try seat("worker-add-z", runtime).call("report", doneReport("done"))).isError)
        let next = lead.call("add_task", ["title": "next", "goal": "g", "acceptance": ["a"]])
        #expect(!next.isError, "\(next.text)")

        try "export PATH\nevil\n".write(toFile: zshrc, atomically: true, encoding: .utf8)
        failing.on = true
        let before = main(root), spawned = runtime.spawned.count
        let gates: [(String, MCPToolResult)] = [
            ("start_worker", lead.call("start_worker", ["task": "next"])),
            ("audit", lead.call("audit", ["task": "add-z"])),
            ("merge", lead.call("merge", ["task": "add-x"])),
            ("merge batch", lead.call("merge", ["tasks": ["add-x", "add-y"]])),
        ]
        for (gate, result) in gates {
            #expect(result.isError, "\(gate) passed on a look that failed (\(shape)): \(result.text)")
            if shape != .recordUnread {
                #expect(result.text.contains("couldn't say whether the agents' config is as sealed"), "\(gate): \(result.text)")
            }
        }
        #expect(runtime.spawned.count == spawned, "a session started on a look that failed")
        #expect(main(root) == before)
        #expect(fixture.ran().isEmpty, "tests ran on a look that failed")

        // Looks complete again: what changed meanwhile is held, not sealed as the user's.
        failing.on = false
        let held = lead.call("start_worker", ["task": "next"])
        #expect(held.isError && held.text.contains("~/.zshrc"), "\(held.text)")
        #expect(vault.heldConfig(root: root) == ["~/.zshrc"])
    }

    /// The tests ran and wrote ~/.zshrc; the look after them fails: nothing lands, alone or in a batch.
    @Test(arguments: Shape.allCases, [false, true])
    func aLookThatFailsAfterTheTestsLandsNothing(shape: Shape, batch: Bool) throws {
        let failing = Failing()
        failing.marker = fixture.temp.url("tests-ran").path
        let (root, runtime, lead) = try scene(shape, failing, suite: """
            #!/bin/bash
            echo run >> \(RecentProjects.shellQuote(fixture.runs))
            echo evil >> \(RecentProjects.shellQuote(zshrc))
            touch \(RecentProjects.shellQuote(failing.marker!))
            echo '✔ Test breaks() passed after 0.010 seconds.'
            echo '✔ Test run with 2 tests passed after 0.020 seconds.'
            """)
        try fixture.audited(lead, runtime, root: root, "add-x", ["x.txt": "x\n"], review: "none")
        try fixture.audited(lead, runtime, root: root, "add-y", ["y.txt": "y\n"], review: "none")
        let before = main(root)
        let result = lead.call("merge", batch ? ["tasks": ["add-x", "add-y"]] : ["task": "add-x"])
        #expect(result.isError, "landed on a look that failed (\(shape)): \(result.text)")
        #expect(fixture.ran().count == 1)
        #expect(main(root) == before)

        failing.off()
        let held = lead.call("merge", batch ? ["tasks": ["add-x", "add-y"]] : ["task": "add-x"])
        #expect(held.isError && held.text.contains("~/.zshrc"), "\(held.text)")
        #expect(main(root) == before)
    }

    /// auto_advance's pass starts no worker on a look that fails.
    @Test(arguments: Shape.allCases)
    func autoAdvanceStartsNothingOnALookThatFails(shape: Shape) async throws {
        let failing = Failing()
        let (root, runtime, lead) = try scene(shape, failing)
        try fixture.audited(lead, runtime, root: root, "add-x", ["x.txt": "x\n"], review: "none")
        try "export PATH\nevil\n".write(toFile: zshrc, atomically: true, encoding: .utf8)
        failing.on = true
        let spawned = runtime.spawned.count
        let added = lead.call("add_task", ["title": "next", "goal": "g", "acceptance": ["a"], "auto_advance": true])
        #expect(!added.isError, "\(added.text)")
        let before = main(root)
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        await advancing.settle()
        await advancing.settle()
        #expect(runtime.spawned.count == spawned, "auto_advance started a session on a look that failed (\(shape))")
        #expect(main(root) == before, "auto_advance merged on a look that failed (\(shape))")
        #expect(fixture.board(root).task("add-x")?.merged == nil)
    }
}
