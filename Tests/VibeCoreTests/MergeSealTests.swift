import Foundation
import Testing
@testable import VibeCore

/// Fake suites and a seal over the fixture's scratch home: no real sessions or user config.
struct MergeSealTests: LeadTeamFixture {
    let fixture = MergeBatchTests()
    var vault: LeadVault { fixture.vault }

    func scene(rerun: Bool = false, refusing: Refusing? = nil) throws -> (String, FakeRuntime, LeadToolset) {
        let config = book.configHome + "/.claude/CLAUDE.md"
        try FileManager.default.createDirectory(atPath: (config as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "before\n".write(toFile: config, atomically: true, encoding: .utf8)
        let scene = try fixture.team(["merge_batching": "always"], suite: """
            #!/bin/bash
            echo run >> \(RecentProjects.shellQuote(fixture.runs))
            echo after > \(RecentProjects.shellQuote(config))
            if \(rerun ? "true" : "false") && [[ $(wc -l < \(RecentProjects.shellQuote(fixture.runs))) -eq 1 ]]; then
              printf '%s\\n' \(RecentProjects.shellQuote(MergeBatchTests.failure))
              exit 1
            fi
            echo '✔ Test breaks() passed after 0.010 seconds.'
            echo '✔ Test run with 2 tests passed after 0.020 seconds.'
            """)
        let lead: LeadToolset
        if let refusing {
            let book = self.book
            nonisolated(unsafe) let runtime = scene.runtime
            let marking = LeadVault(folder: vault.folder) { request in
                if case .setGuarded(_, let hashes) = request, hashes[ConfigSeal.runKey] != nil, refusing.on {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                return book.answer(request, from: runtime.currentAgent()?.session.map { .session($0) } ?? .unknown)
            }
            lead = restarted(scene.root, scene.runtime, vault: marking)
        } else { lead = scene.lead }
        try fixture.audited(lead, scene.runtime, root: scene.root, "add-x", ["x.txt": "x\n"], review: "none")
        try fixture.audited(lead, scene.runtime, root: scene.root, "add-y", ["y.txt": "y\n"], review: "none")
        return (scene.root, scene.runtime, lead)
    }

    func merge(_ lead: LeadToolset, batch: Bool) -> MCPToolResult {
        lead.call("merge", batch ? ["tasks": ["add-x", "add-y"]] : ["task": "add-x"])
    }

    @Test(arguments: [false, true])
    func pendingSealRefusesBeforeAnyTests(batch: Bool) throws {
        let (root, _, lead) = try scene()
        let before = Git.run(["rev-parse", "main"], in: root).output
        try "pending\n".write(toFile: book.configHome + "/.claude/CLAUDE.md", atomically: true, encoding: .utf8)
        let refused = merge(lead, batch: batch)
        #expect(refused.isError, "\(refused.text)")
        #expect(refused.text.contains("nothing was tested"), "\(refused.text)")
        #expect(fixture.ran().isEmpty)
        #expect(Git.run(["rev-parse", "main"], in: root).output == before)
    }

    @Test(arguments: [false, true], [false, true])
    func passingRunSurvivesSealUntilAccept(batch: Bool, moveBase: Bool) throws {
        let (root, runtime, lead) = try scene()
        let before = Git.run(["rev-parse", "main"], in: root).output
        let held = merge(lead, batch: batch)
        #expect(held.isError, "\(held.text)")
        #expect(held.text.contains("kept"), "\(held.text)")
        #expect(fixture.ran().count == 1)
        #expect(Git.run(["rev-parse", "main"], in: root).output == before)
        let key = batch ? "add-x\nadd-y" : "add-x"
        let retainedTip = Git.run(["rev-parse", "--verify", "refs/vibeswitcher/seal-passes/\(LeadVault.hash(key))"], in: root)
        #expect(retainedTip.ok)
        let stillHeld = merge(lead, batch: batch)
        #expect(stillHeld.isError)
        #expect(fixture.ran().count == 1, "An unaccepted seal must neither land nor spend another run")
        #expect(Git.run(["rev-parse", "main"], in: root).output == before)
        _ = try vault.checkConfig(root: root)
        if moveBase {
            try fixture.commit(["new-base.txt": "new\n"], in: root, "base moves")
            try vault.setHead(Git.run(["rev-parse", "main"], in: root).output, root: root, branch: "main")
        }
        let expectedBase = Git.run(["rev-parse", "main"], in: root).output
        #expect(Git.run(["prune", "--expire=now"], in: root).ok)
        let landed = merge(lead, batch: batch)
        #expect(!landed.isError, "\(landed.text)")
        #expect(fixture.ran().count == (moveBase ? 2 : 1))
        #expect(fixture.board(root).task("add-x")?.merged != nil)
        #expect(fixture.board(root).task("add-x")?.merged?.onto == expectedBase)
        if batch { #expect(fixture.board(root).task("add-y")?.merged != nil) }
        if !moveBase { #expect(Git.run(["rev-parse", "main"], in: root).output == retainedTip.output) }
    }

    @Test(arguments: [false, true])
    func aChangedCommandRequiresNewTests(batch: Bool) throws {
        let (root, _, lead) = try scene()
        #expect(merge(lead, batch: batch).isError)
        #expect(fixture.ran().count == 1)
        _ = try vault.checkConfig(root: root)
        #expect(!lead.call("configure", ["test_command": "bash scripts/test.sh && true"]).isError)
        let landed = merge(lead, batch: batch)
        #expect(!landed.isError, "\(landed.text)")
        #expect(fixture.ran().count == 2)
    }

    func restarted(_ root: String, _ runtime: FakeRuntime, vault supplied: LeadVault? = nil) -> LeadToolset {
        let lead = LeadToolset(root: root, runtime: runtime, vault: supplied ?? vault(for: runtime))
        lead.testLock = fixture.testLock
        lead.power = { nil }
        lead.macLimits = { MacLimits(maxSessions: 12) }
        lead.roomWaits = fixture.roomWaits
        lead.usageStore = fixture.usageStore
        lead.auditSampleSeed = { unsampledSeed }
        return lead
    }

    /// The lead's shell can sign an ordinary lead message. Neither that signature nor an on-disk tip may assert
    /// that tests passed: after a restart even a genuine earlier pass runs again.
    @Test(arguments: [false, true])
    func aLeadSignedReceiptAndAnUntestedTipDoNotAuthorizeReuseAfterRestart(batch: Bool) throws {
        let (root, runtime, lead) = try scene()
        #expect(merge(lead, batch: batch).isError)
        _ = try vault.checkConfig(root: root)
        let base = Git.run(["rev-parse", "main"], in: root).output
        #expect(Git.run(["checkout", "-q", "-b", "forged-tip"], in: root).ok)
        try fixture.commit(["injected.txt": "not tested\n"], in: root, "untested")
        let tip = Git.run(["rev-parse", "HEAD"], in: root).output
        #expect(Git.run(["checkout", "-q", "main"], in: root).ok)
        let slugs = batch ? ["add-x", "add-y"] : ["add-x"]
        let key = slugs.joined(separator: "\n")
        let inputs: [[String: Any]] = slugs.map {
            ["slug": $0, "commit": Git.run(["rev-parse", "agent/\($0)"], in: root).output, "revision": 1]
        }
        let payload: [String: Any] = [
            "context": ["root": root, "base": "main", "onto": base, "inputs": inputs, "checks": "bash scripts/test.sh"],
            "tips": slugs.map { _ in tip }, "tests": 2, "ended": Date().timeIntervalSinceReferenceDate
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var message = SteerMessage(id: "merge seal pass v1 \(root)", text: String(decoding: data, as: UTF8.self),
                                   from: .lead("lead of \(lead.project)"), agentPid: 0)
        message.seal = try vault(for: runtime).seal(message)
        try LeadVault.writePrivate(JSONEncoder().encode(message), to: vault.scratch(root: root, "seal-pass-\(LeadVault.hash(key)).json"))
        #expect(Git.run(["update-ref", "refs/vibeswitcher/seal-passes/\(LeadVault.hash(key))", tip], in: root).ok)
        let fresh = restarted(root, runtime)
        #expect(Git.run(["for-each-ref", "--format=%(refname)", "refs/vibeswitcher/seal-passes/"], in: root).output.isEmpty)
        let landed = merge(fresh, batch: batch)
        #expect(!landed.isError, "\(landed.text)")
        #expect(fixture.ran().count == 2)
        #expect(!FileManager.default.fileExists(atPath: root + "/injected.txt"))
        #expect(FileManager.default.fileExists(atPath: root + "/x.txt"))
        if batch { #expect(FileManager.default.fileExists(atPath: root + "/y.txt")) }
    }

    @Test(arguments: [false, true])
    func aPassingRerunIsKeptWithoutRecordingAnotherRerun(batch: Bool) throws {
        let (root, _, lead) = try scene(rerun: true)
        let held = merge(lead, batch: batch)
        #expect(held.isError && held.text.contains("kept"), "\(held.text)")
        #expect(fixture.ran().count == 2)
        _ = try vault.checkConfig(root: root)
        let landed = merge(lead, batch: batch)
        #expect(!landed.isError, "\(landed.text)")
        #expect(fixture.ran().count == 2)
        let board = fixture.board(root)
        #expect(board.task("add-x")?.receipt?.mergeReruns == 1)
        #expect(FlakeLedgerStore(root: root).load().reruns.count == 1)
    }

    @Test(arguments: [false, true])
    func aNewWorkerCommitInvalidatesTheKeptPass(batch: Bool) throws {
        let (root, runtime, lead) = try scene()
        #expect(merge(lead, batch: batch).isError)
        _ = try vault.checkConfig(root: root)
        let worktree = Worktrees.path(root: root, slug: "add-x")
        try fixture.commit(["x.txt": "new x\n"], in: worktree, "x changes")
        let reported = try seat("worker-add-x", runtime).call("report", doneReport("new x"))
        #expect(!reported.isError, "\(reported.text)")
        let landed = merge(lead, batch: batch)
        #expect(!landed.isError, "\(landed.text)")
        #expect(fixture.ran().count == 2)
        #expect(try String(contentsOfFile: root + "/x.txt", encoding: .utf8) == "new x\n")
    }

    @Test func aPassingSplitPrefixSurvivesTheSealHold() throws {
        let config = book.configHome + "/.claude/CLAUDE.md"
        try FileManager.default.createDirectory(atPath: (config as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "before\n".write(toFile: config, atomically: true, encoding: .utf8)
        let (root, runtime, lead) = try fixture.team(["max_workers": 8], suite: """
            #!/bin/bash
            echo "run $* | $(ls *.txt | tr '\\n' ' ')" >> \(RecentProjects.shellQuote(fixture.runs))
            if [[ -e break.txt ]]; then
              printf '%s\\n' \(RecentProjects.shellQuote(MergeBatchTests.failure))
              exit 1
            fi
            if [[ -e x.txt ]]; then echo after > \(RecentProjects.shellQuote(config)); fi
            echo '✔ Test breaks() passed after 0.010 seconds.'
            echo '✔ Test run with 2 tests passed after 0.020 seconds.'
            """)
        for (slug, file) in [("add-x", "x.txt"), ("add-y", "y.txt"), ("break-it", "break.txt"), ("add-z", "z.txt")] {
            try fixture.audited(lead, runtime, root: root, slug, [file: "\(slug)\n"], review: "none")
        }
        let slugs = ["add-x", "add-y", "break-it", "add-z"]
        let held = try lead.mergeBatch(slugs)
        #expect(held.stopped != nil && held.text.contains("kept"), "\(held.text)")
        #expect(fixture.board(root).task("add-x")?.merged == nil)
        _ = try vault.checkConfig(root: root)
        let landed = try lead.mergeBatch(slugs)
        #expect(landed.end("add-x") != nil && fixture.board(root).task("add-x")?.merged != nil, "\(landed.text)")
        #expect(fixture.board(root).task("add-y")?.merged?.batch == ["add-x", "add-y"])
        #expect(fixture.board(root).task("add-z")?.merged != nil, "\(landed.text)")
        #expect(fixture.board(root).task("break-it")?.status == .failed)
        let prefixRuns = fixture.ran(first: true).filter { !$0.contains("--skip") && $0.contains("x.txt y.txt") && !$0.contains("break.txt") && !$0.contains("z.txt") }
        #expect(Git.run(["for-each-ref", "--format=%(refname)", "refs/vibeswitcher/seal-passes/"], in: root).output.isEmpty)
        #expect(prefixRuns.count == 1, "The passing prefix must not run again: \(fixture.ran())")
    }

    @Test func aBisectedBatchDropsSupersededPassRefs() throws {
        let (root, runtime, lead) = try fixture.team(["max_workers": 10, "auto_advance": false])
        let tasks = [("add-x", "x.txt"), ("add-y", "y.txt"), ("add-z", "z.txt"), ("break-it", "break.txt"), ("add-w", "w.txt")]
        for (slug, file) in tasks {
            try fixture.audited(lead, runtime, root: root, slug, [file: "\(slug)\n"], review: "none")
        }
        let result = try lead.mergeBatch(tasks.map(\.0))
        #expect(result.stopped == nil, "\(result.text)")
        for slug in ["add-x", "add-y", "add-z", "add-w"] {
            #expect(fixture.board(root).task(slug)?.merged != nil, "\(result.text)")
        }
        #expect(fixture.board(root).task("break-it")?.status == .failed)
        #expect(Git.run(["for-each-ref", "--format=%(refname)", "refs/vibeswitcher/seal-passes/"], in: root).output.isEmpty)
    }

    /// Reuse skips the test command, but landing can still run accepted Git hooks. It retains the existing mark
    /// for code outside a session, and a host that cannot record that mark still prevents landing.
    @Test(arguments: [false, true])
    func aRetainedMergeStillNeedsTheBranchRunMark(batch: Bool) throws {
        let refusing = Refusing()
        let (root, _, lead) = try scene(refusing: refusing)
        #expect(merge(lead, batch: batch).isError)
        _ = try vault.checkConfig(root: root)
        let before = Git.run(["rev-parse", "main"], in: root).output
        refusing.on = true
        let refused = merge(lead, batch: batch)
        #expect(refused.isError && refused.text.contains("couldn't record that the branch's code runs"), "\(refused.text)")
        #expect(Git.run(["rev-parse", "main"], in: root).output == before)
        #expect(fixture.ran().count == 1)
        refusing.on = false
        let landed = merge(lead, batch: batch)
        #expect(!landed.isError, "\(landed.text)")
        #expect(fixture.ran().count == 1)
    }

    @Test func autoAdvanceKeepsThePassingBatchTogetherAcrossAccept() async throws {
        let (root, runtime, lead) = try scene()
        lead.batchSize = 2
        lead.batchWindow = 0
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(await advancing.until {
            fixture.reports(runtime).contains { $0.contains("The batch of add-x, add-y stopped short") }
        })
        #expect(fixture.ran().count == 1)
        #expect(fixture.board(root).task("add-x")?.merged == nil)
        #expect(fixture.board(root).task("add-y")?.merged == nil)
        // Another actual pass while held still runs nothing and lands nothing.
        await advancing.settle()
        #expect(fixture.ran().count == 1)
        #expect(fixture.board(root).task("add-x")?.merged == nil)
        _ = try vault.checkConfig(root: root)
        // The app's Accept notifies the lead; the fixture's in-process vault has no app or folder witness to nudge it.
        lead.advancing?.trigger()
        #expect(await advancing.until {
            fixture.board(root).task("add-x")?.merged != nil && fixture.board(root).task("add-y")?.merged != nil
        })
        #expect(fixture.ran().count == 1)
        #expect(fixture.board(root).task("add-x")?.merged?.batch == ["add-x", "add-y"])
        #expect(fixture.board(root).task("add-y")?.merged?.batch == ["add-x", "add-y"])
    }
}
