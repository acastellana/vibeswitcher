import Foundation
import Testing
@testable import VibeCore

/// The pre-done check (`LeadDoneCheck`): a worker's done report runs it first, in its worktree, holding a test and build
/// slot; a failure refuses the report with its output, a pass lets it through, and a run that times out or can't start
/// lets it through too, saying so (the merge's full suite stays the gate). A Codex worker's runs inside Codex's sandbox.
struct LeadDoneCheckTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("done-check")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func task(_ slug: String, _ root: String) -> LeadTask? { BoardStore(root: root).load().task(slug) }

    /// Task "add-b" with `check` its workflow.md done_check_command, its worker started on `agent` and b.txt committed:
    /// the lead's tools and the worker's.
    func working(_ root: String, _ runtime: FakeRuntime, check: String, agent: String? = nil) throws -> (lead: LeadToolset, worker: LeadToolset) {
        let lead = try lead(root, runtime)
        lead.codexWorkers = true
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "true", "done_check_command": check]).isError)
        var adding: [String: Any] = ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]]
        if let agent { adding["agent"] = agent }
        #expect(!lead.call("add_task", adding).isError)
        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        return (lead, try seat("worker-add-b", runtime))
    }

    func commit(_ file: String, in worktree: String) {
        try? "x\n".write(toFile: worktree + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: worktree)
        Git.run(["commit", "-q", "-m", "add \(file)"], in: worktree)
    }

    @Test func aFailingCheckRefusesTheDoneWithItsOutputAndAPassingOneLetsItThrough() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let check = "test -f ok.txt || { echo 'FAILED: ok.txt is missing'; exit 1; }"
        let (_, worker) = try working(root, runtime, check: check)
        let worktree = Worktrees.path(root: root, slug: "add-b")

        let refused = worker.call("report", doneReport("added b.txt"))
        #expect(refused.isError, "\(refused.text)")
        #expect(refused.text.contains("Not reported: the pre-done check failed") && refused.text.contains("FAILED: ok.txt is missing"), "\(refused.text)")
        #expect(refused.text.contains("workflow.md's done_check_command") && refused.text.contains(check), "\(refused.text)")
        // Nothing recorded: the task is still at work, no done in the vault.
        #expect(task("add-b", root)?.status == .running && task("add-b", root)?.report == nil)
        #expect(try vault.unaudited(root: root, task: "add-b").reported == nil)

        commit("ok.txt", in: worktree)
        let reported = worker.call("report", doneReport("added b.txt and ok.txt"))
        #expect(!reported.isError, "\(reported.text)")
        #expect(reported.text.contains("Its pre-done check passed"), "\(reported.text)")
        #expect(task("add-b", root)?.status == .review)
        let head = Git.run(["rev-parse", "agent/add-b"], in: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try vault.unaudited(root: root, task: "add-b").reported == head)
        // The lead hears it passed.
        #expect(runtime.steered.contains { $0.text.contains("Its pre-done check passed") }, "\(runtime.steered.map(\.text))")
    }

    @Test func itRunsHoldingATestAndBuildSlotOnAScratchHome() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let check = "test -n \"$\(TestLock.heldVariable)\" && test -n \"$\(TestLock.coresVariable)\" && test \"$HOME\" != \(RecentProjects.shellQuote(NSHomeDirectory())) "
            + "|| { echo \"no slot or the real home: $\(TestLock.heldVariable) $HOME\"; exit 1; }"
        let (_, worker) = try working(root, runtime, check: check)
        worker.testLock = testLock
        let reported = worker.call("report", doneReport("added b.txt"))
        #expect(!reported.isError && reported.text.contains("Its pre-done check passed"), "\(reported.text)")
    }

    @Test func aCheckPastItsLimitLetsTheDoneThroughSayingSo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (_, worker) = try working(root, runtime, check: "sleep 600")
        worker.doneCheckLimit = 1
        let reported = worker.call("report", doneReport("added b.txt"))
        #expect(!reported.isError, "\(reported.text)")
        #expect(reported.text.contains("The pre-done check (`sleep 600`) didn't decide: it ran past its") && reported.text.contains("the merge's full suite is the gate"),
                "\(reported.text)")
        #expect(task("add-b", root)?.status == .review)
        #expect(runtime.steered.contains { $0.text.contains("didn't decide") }, "\(runtime.steered.map(\.text))")
    }

    @Test func aCheckThatCantStartLetsTheDoneThroughSayingSo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (_, worker) = try working(root, runtime, check: "exit 1")
        // Every slot held, by another run: the check's wait for one ends at its limit, and it never starts.
        let lock = testLock
        guard case .held(let other, _, _) = lock.acquire(as: "another project's suite", timeout: 5) else {
            Issue.record("couldn't hold the scratch lock")
            return
        }
        defer { other.release() }
        worker.testLock = lock
        worker.doneCheckLimit = 1
        let reported = worker.call("report", doneReport("added b.txt"))
        #expect(!reported.isError, "\(reported.text)")
        #expect(reported.text.contains("didn't decide: it couldn't start") && reported.text.contains("stayed held"), "\(reported.text)")
        #expect(task("add-b", root)?.status == .review)
    }

    @Test func aCancelledCheckRecordsNothing() async throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let started = temp.url("started").path
        let (_, worker) = try working(root, runtime, check: "touch \(RecentProjects.shellQuote(started)); sleep 600")
        let token = ShellCancel()
        nonisolated(unsafe) let seat = worker
        let call = Task.detached { ShellCancel.with(token) { seat.call("report", doneReport("added b.txt")) } }
        // Once the check runs, its call is cancelled (the client gave up on it).
        #expect(await until { FileManager.default.fileExists(atPath: started) })
        token.cancel()
        let reported = await call.value
        #expect(reported.isError && reported.text.contains("the pre-done check was cancelled"), "\(reported.text)")
        #expect(task("add-b", root)?.status == .running && task("add-b", root)?.report == nil)
        #expect(try vault.unaudited(root: root, task: "add-b").reported == nil)
    }

    @Test func aCommitMadeWhileTheCheckRunsIsntReportedUnchecked() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        // The check commits, as a worker might while it waits on the call.
        let check = "echo c > c.txt && git add c.txt && git commit -q -m 'add c'"
        let (_, worker) = try working(root, runtime, check: check)
        let reported = worker.call("report", doneReport("added b.txt"))
        #expect(reported.isError && reported.text.contains("your branch moved") && reported.text.contains("while the pre-done check ran"), "\(reported.text)")
        #expect(try vault.unaudited(root: root, task: "add-b").reported == nil)
    }

    @Test func aCodexWorkersToolCallsMayOutlastTheCheck() throws {
        let root = try repo()
        let prepared = try LeadLaunch.prepareCodex(root: root, task: "t", base: "codex", prompt: "p", start: "s", server: "/App/vibeswitcher-mcp",
                                                   name: "worker-t", folder: temp.url("run"), cwd: root, temporary: temp.url("tmp"),
                                                   toolTimeout: LeadDoneCheck.callTimeout(limit: 300))
        // Codex's own limit is 60 s unless set: the slot's wait and the check's run, 5 min each, and two more.
        #expect(prepared.command.contains("mcp_servers.vibeswitcher.tool_timeout_sec=720"), "\(prepared.command)")
    }

    @Test func offOrADoneAgainOnTheSameCommitRunsNoCheck() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let marker = temp.url("ran").path
        let (lead, worker) = try working(root, runtime, check: "echo ran >> \(RecentProjects.shellQuote(marker))")
        #expect(!worker.call("report", doneReport("added b.txt")).isError)
        #expect((try? String(contentsOfFile: marker, encoding: .utf8)) == "ran\n")
        // Again on the same commit (a note, an answer): its first done ran it.
        #expect(!worker.call("report", doneReport("added b.txt, again")).isError)
        #expect((try? String(contentsOfFile: marker, encoding: .utf8)) == "ran\n")
        // The task's own off: none at all on a new commit.
        #expect(!lead.call("update_task", ["task": "add-b", "done_check": "off"]).isError)
        #expect(task("add-b", root)?.doneCheck == "off")
        commit("c.txt", in: Worktrees.path(root: root, slug: "add-b"))
        let reported = worker.call("report", doneReport("added c.txt"))
        #expect(!reported.isError && !reported.text.contains("pre-done check"), "\(reported.text)")
        #expect((try? String(contentsOfFile: marker, encoding: .utf8)) == "ran\n")
    }

    @Test func theTasksOwnCheckComesBeforeTheWorkflows() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (lead, worker) = try working(root, runtime, check: "true")
        let updated = lead.call("update_task", ["task": "add-b", "done_check": "echo 'task check failed'; exit 3"])
        #expect(!updated.isError && updated.text.contains("done_check"), "\(updated.text)")
        let refused = worker.call("report", doneReport("added b.txt"))
        #expect(refused.isError && refused.text.contains("the task's done_check") && refused.text.contains("task check failed"), "\(refused.text)")
        #expect(!lead.call("update_task", ["task": "add-b", "done_check": ""]).isError)
        #expect(task("add-b", root)?.doneCheck == nil)
        #expect(!worker.call("report", doneReport("added b.txt")).isError)
    }

    /// A stand-in for `codex sandbox`: it writes its arguments to `log`, then runs the command after `--` with
    /// CODEX_SANDBOX set, as Codex runs its commands.
    func fakeCodexSandbox(log: String) throws -> String {
        let folder = temp.url("sandbox-bin").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/codex"
        let script = "#!/bin/bash\nprintf '%s\\n' \"$@\" > \(RecentProjects.shellQuote(log))\n"
            + "while (( $# > 0 )) && [[ $1 != -- ]]; do shift; done; shift\nCODEX_SANDBOX=seatbelt exec \"$@\"\n"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    @Test func aCodexWorkersCheckRunsInsideCodexsSandbox() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let check = "test \"$CODEX_SANDBOX\" = seatbelt || { echo 'not in the sandbox'; exit 1; }"
        let (_, worker) = try working(root, runtime, check: check, agent: "codex")
        #expect(task("add-b", root)?.runningAgent == .codex)
        let log = temp.url("sandbox-args").path
        runtime.codex = try fakeCodexSandbox(log: log) + " --yolo -s danger-full-access"
        worker.alreadySandboxed = { false }
        let reported = worker.call("report", doneReport("added b.txt"))
        #expect(!reported.isError && reported.text.contains("Its pre-done check passed"), "\(reported.text)")
        let args = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        // Codex's workspace-write sandbox, no network, the worktree's writable roots; never the project command's flags.
        #expect(args.first == "sandbox" && args.contains("sandbox_mode=\"workspace-write\"") && args.contains("sandbox_workspace_write.network_access=false"), "\(args)")
        #expect(args.contains { $0.hasPrefix("sandbox_workspace_write.writable_roots=") && $0.contains("done-check-add-b-") }, "\(args)")
        #expect(!args.contains("--yolo") && !args.contains("danger-full-access"), "\(args)")
        #expect(args.last == check, "\(args)")
    }

    @Test func aCodexWorkersCheckInASandboxAlreadyRunsThereSaidToBeInCodexs() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let check = "test \"$CODEX_SANDBOX\" = seatbelt || { echo 'not told'; exit 1; }"
        let (_, worker) = try working(root, runtime, check: check, agent: "codex")
        // No codex to run it under: inside a sandbox, another can't be applied, and isn't asked for.
        runtime.codex = temp.url("no-such-codex").path
        worker.alreadySandboxed = { true }
        let reported = worker.call("report", doneReport("added b.txt"))
        #expect(!reported.isError && reported.text.contains("Its pre-done check passed"), "\(reported.text)")
    }

    /// The real `codex sandbox`, where Codex is installed: the check runs with CODEX_SANDBOX set, its status comes back,
    /// it writes in the worktree and its writable roots, and not elsewhere outside the temporary folders.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/codex") && !LeadDoneCheck.inSandbox()))
    func theRealCodexSandboxRunsTheCheckAsCodexWould() throws {
        let worktree = temp.url("worktree").resolvingSymlinksInPath()
        let writable = temp.url("writable").resolvingSymlinksInPath()
        let outside = temp.url("outside").resolvingSymlinksInPath()
        for folder in [worktree, writable, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // A folder everyone may write that isn't a temporary one (those, Codex's sandbox lets it write): refused there.
        let shared = "/Users/Shared"
        let probe = shared + "/vibeswitcher-done-check-probe-\(UUID().uuidString)"
        let command = "echo \"CS=$CODEX_SANDBOX\"; touch inside; touch \(RecentProjects.shellQuote(writable.path + "/w")); "
            + "touch \(RecentProjects.shellQuote(probe)) 2>/dev/null && echo WROTE-OUTSIDE; exit 7"
        let run = LeadDoneCheck.sandboxed(command, codex: "/opt/homebrew/bin/codex", writable: [writable.path], alreadySandboxed: false)
        let result = Shell.run(executable: "/bin/zsh", args: ["-c", run], in: worktree.path, timeout: 60, interleaved: true)
        defer { unlink(probe) }
        #expect(result.status == 7, "\(result.output)")
        #expect(result.output.contains("CS=seatbelt"), "\(result.output)")
        #expect(FileManager.default.fileExists(atPath: worktree.path + "/inside") && FileManager.default.fileExists(atPath: writable.path + "/w"))
        if FileManager.default.isWritableFile(atPath: shared) {
            #expect(!result.output.contains("WROTE-OUTSIDE") && !FileManager.default.fileExists(atPath: probe), "\(result.output)")
        }
    }

    @Test func theCommandComesFromTheTaskThenTheWorkflowThenTheLintsAndChangedSuites() {
        let lints = ["HomePathLint", "KeychainLint"]
        #expect(LeadDoneCheck.command(task: "make check", workflow: "make lint", test: "t", lints: lints, suites: [])?.command == "make check")
        #expect(LeadDoneCheck.command(task: "make check", workflow: "make lint", test: "t", lints: lints, suites: [])?.source == .task)
        #expect(LeadDoneCheck.command(task: " OFF ", workflow: "make lint", test: "t", lints: lints, suites: []) == nil)
        #expect(LeadDoneCheck.command(task: nil, workflow: "make lint", test: "t", lints: lints, suites: [])?.source == .workflow)
        #expect(LeadDoneCheck.command(task: "", workflow: "off", test: "t", lints: lints, suites: []) == nil)
        let standard = LeadDoneCheck.command(task: nil, workflow: nil, test: "bash scripts/test.sh", lints: lints, suites: ["LeadBoardTests", "KeychainLint"])
        #expect(standard?.command == "bash scripts/test.sh --filter 'HomePathLint|KeychainLint|LeadBoardTests'" && standard?.source == .standard)
        // No lint tests, or no test command: no default.
        #expect(LeadDoneCheck.command(task: nil, workflow: nil, test: "npm test", lints: [], suites: ["X"]) == nil)
        #expect(LeadDoneCheck.command(task: nil, workflow: nil, test: nil, lints: lints, suites: []) == nil)
    }

    @Test func theChangedFilesSuitesAreTheirTestFilesSuitesAndTheSourcesNamesakes() {
        let tests = ["Tests/VibeCoreTests/LeadBoardTests.swift", "Tests/VibeCoreTests/HistoryTests.swift", "Tests/VibeCoreTests/GitTests.swift"]
        let changed = ["Sources/VibeCore/LeadBoard.swift", "Sources/VibeCore/Zstd.swift", "Tests/VibeCoreTests/HistoryTests.swift",
                       "Tests/VibeCoreTests/NewOneTests.swift", "docs/guide/project-lead.md", "Tests/VibeCoreTests/Helpers.swift"]
        let sources = ["Tests/VibeCoreTests/HistoryTests.swift": "struct ScrollbackTests {}\nextension ScrollbackTests {}\nstruct Fake {}",
                       "Tests/VibeCoreTests/Helpers.swift": "struct FakeThing {}"]
        #expect(LeadDoneCheck.suites(changed: changed, testFiles: tests, sources: sources) == ["LeadBoardTests", "NewOneTests", "ScrollbackTests"])
    }

    @Test func aFailuresOutputIsCutToItsEndFromALinesStart() {
        let long = (1...2000).map { "line \($0)" }.joined(separator: "\n")
        let tail = LeadDoneCheck.tail(long)
        #expect(tail.hasPrefix("…\nline ") && tail.hasSuffix("line 2000") && tail.count <= LeadDoneCheck.shownOutput + 2)
        #expect(LeadDoneCheck.tail("short") == "short")
    }

    @Test func doneCheckSettingsReadAndConfigure() throws {
        let workflow = LeadWorkflow.parse("---\ndone_check_command: make check\ndone_check_min: 2.5\n---\n")
        #expect(workflow.doneCheckCommand == "make check" && workflow.doneCheckTimeout == 150)
        #expect(LeadWorkflow.parse("---\ndone_check_min: nope\n---\n").doneCheckMinutes == LeadDoneCheck.defaultMinutes)
        let template = LeadWorkflow.parse(LeadWorkflow.template)
        #expect(template.doneCheckCommand == nil && template.doneCheckMinutes == LeadDoneCheck.defaultMinutes)
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(lead.call("configure", ["done_check_min": "0"]).isError)
        let set = lead.call("configure", ["done_check_command": "off", "done_check_min": "3"])
        #expect(!set.isError && set.text.contains("done_check_command: off") && set.text.contains("done_check_min: 3"), "\(set.text)")
    }
}
