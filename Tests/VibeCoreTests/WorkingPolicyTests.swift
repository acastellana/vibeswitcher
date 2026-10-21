import Foundation
import Testing
@testable import VibeCore

/// The user's working policy reaches every project's lead, workers and verifiers: one text (~/.vibeswitcher/policy.md,
/// edited in Settings › Project lead) in every role's prompt, told once to each running lead when it changes and once
/// when this build first runs. Heavy work runs one at a time Mac-wide for every project: `vs-heavy` on every session's
/// PATH, and every project's merge taking the same lock around its tests.
struct WorkingPolicyTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    /// Where the witness keeps what it told (a relaunch's watch reads the same file).
    let told: URL
    init() {
        vault = Self.newVault(in: temp)
        told = temp.url("told").appendingPathComponent("policy-told.json")
    }

    static let task = LeadTask(slug: "split-layer", title: "Split the layer",
                               contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
    static let custom = "- Ship small.\n- Ask before deleting data."

    // MARK: The text

    @Test func theDefaultIsTheUsersFiveRulesVerbatim() {
        let rules = ["One agent owns each change through completion. Separate reviewers only for security, irreversible operations, or complex changes.",
                     "Run affected tests while editing, then the full suite once before merging. Repeat only when new changes justify it.",
                     "Parallelize independent implementation work. Serialize expensive builds and tests so workers don't compete for CPU.",
                     "Fix material bugs. Cosmetic observations don't automatically become tasks or block delivery.",
                     "Stop when the requested behavior works and relevant checks pass. No recursive audit loop without a concrete unresolved concern."]
        #expect(WorkingPolicy.defaultText == rules.map { "- \($0)" }.joined(separator: "\n"))
    }

    @Test func itsKeptInPolicyMdAndBlankOrMissingIsTheDefault() throws {
        let file = temp.url("home").appendingPathComponent("policy.md")
        #expect(WorkingPolicy.load(from: file) == WorkingPolicy.defaultText)
        try WorkingPolicy.save("\n" + Self.custom + "\n\n", to: file)
        #expect(WorkingPolicy.load(from: file) == Self.custom)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try WorkingPolicy.save("   ", to: file)
        #expect(WorkingPolicy.load(from: file) == WorkingPolicy.defaultText)
        // Under ~/.vibeswitcher (VIBESWITCHER_HOME in a test run).
        #expect(WorkingPolicy.file == VibePaths.root.appendingPathComponent("policy.md"))
    }

    // MARK: Every role's prompt, in any project

    @Test func everyLeadWorkerAndVerifierPromptHasItForAnyProject() {
        let workflow = LeadWorkflow.parse("---\ntest_command: pnpm test\nbase_branch: dev\n---")
        let root = "/Users/someone/dev/genswap"
        let prompts = [
            ("lead", LeadPrompts.lead(project: "genswap", root: root, workflow: workflow, policy: Self.custom)),
            ("worker", LeadPrompts.worker(task: Self.task, root: root, workflow: workflow, policy: Self.custom)),
            ("verifier", LeadPrompts.verifier(task: Self.task, root: root, workflow: workflow, policy: Self.custom)),
        ]
        for (role, prompt) in prompts {
            #expect(prompt.contains(WorkingPolicy.section(Self.custom)), "\(role)")
            #expect(prompt.contains("Settings › Project lead"), "\(role)")
            #expect(!prompt.contains(WorkingPolicy.defaultText), "\(role)")
            #expect(prompt.contains(root), "\(role)")
        }
        // Without one given, each takes the policy as it is now: the default while there's no file.
        #expect(LeadPrompts.worker(task: Self.task, root: root, workflow: workflow).contains(WorkingPolicy.section(WorkingPolicy.load())))
        #expect(LeadPrompts.lead(project: "tge", root: "/r/tge", workflow: workflow).contains(WorkingPolicy.section(WorkingPolicy.load())))
    }

    @Test func workersAndVerifiersWrapHeavyWorkInVsHeavy() {
        let workflow = LeadWorkflow.parse("---\ntest_command: cargo test\n---")
        let worker = LeadPrompts.worker(task: Self.task, root: "/r/tge", workflow: workflow)
        let verifier = LeadPrompts.verifier(task: Self.task, root: "/r/tge", workflow: workflow)
        for prompt in [worker, verifier] {
            #expect(prompt.contains(LeadPrompts.heavyWork))
            #expect(prompt.contains("`vs-heavy <command>`") && prompt.contains("full test suite or a release build"))
        }
    }

    // MARK: The witness

    func watch(_ policy: Locked<String>) -> LeadWitness.PolicyWatch {
        LeadWitness.PolicyWatch(read: { policy.get() }, file: told)
    }

    @Test func eachRunningLeadIsToldOnceWhenThisBuildFirstRunsAndOnceWhenItChanges() {
        let policy = Locked(WorkingPolicy.defaultText)
        let watch = watch(policy)
        // This build's first look: genswap's and TGE's leads, started by an older build, are told once.
        let first = watch.look(running: ["genswap-lead", "tge-lead"])
        #expect(first?.leads == ["genswap-lead", "tge-lead"])
        #expect(first?.text == WorkingPolicy.witnessText(WorkingPolicy.defaultText))
        #expect(first?.text.contains("Apply it from now on") == true)
        // Looked at again (a minute on, or after a relaunch: a new watch on the same file), nothing.
        #expect(watch.look(running: ["genswap-lead", "tge-lead"]) == nil)
        #expect(self.watch(policy).look(running: ["genswap-lead", "tge-lead"]) == nil)
        // A lead started since, with the policy in its prompt, isn't told it.
        watch.started("films-lead", with: WorkingPolicy.defaultText)
        #expect(watch.look(running: ["genswap-lead", "tge-lead", "films-lead"]) == nil)
        // Changed: each running lead once, with the new text.
        policy.set(Self.custom)
        let changed = watch.look(running: ["genswap-lead", "tge-lead", "films-lead"])
        #expect(changed?.leads == ["genswap-lead", "tge-lead", "films-lead"])
        #expect(changed?.text.hasSuffix(Self.custom) == true)
        #expect(watch.look(running: ["genswap-lead", "tge-lead", "films-lead"]) == nil)
        // A lead whose prompt had the old one (prepared before the change) is told the new one.
        watch.started("late-lead", with: WorkingPolicy.defaultText)
        #expect(watch.look(running: ["late-lead"])?.leads == ["late-lead"])
    }

    @Test func aChangeWithNoLeadRunningIsntToldToLeadsStartedWithIt() {
        let policy = Locked(WorkingPolicy.defaultText)
        let watch = watch(policy)
        #expect(watch.look(running: []) == nil)
        watch.started("new-lead", with: WorkingPolicy.defaultText)
        #expect(watch.look(running: ["new-lead"]) == nil)
        // One the host reports only later (an older build's), still once.
        #expect(watch.look(running: ["new-lead", "old-lead"])?.leads == ["old-lead"])
        #expect(watch.look(running: ["new-lead", "old-lead"]) == nil)
    }

    // MARK: vs-heavy on every session's PATH

    @Test func sessionsGetTheBundlesVsHeavyFirstOnTheirPath() throws {
        let app = temp.url("VibeSwitcher.app")
        let macOS = app.appendingPathComponent("Contents/MacOS"), bin = app.appendingPathComponent("Contents/Resources/bin")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let host = macOS.appendingPathComponent("vibeswitcher-host").path
        // No vs-heavy there (a swift build's binaries): PATH as it was.
        #expect(TestLock.commandFolder(besideExecutable: host) == nil)
        #expect(TestLock.sessionEnvironment(["PATH": "/usr/bin:/bin"], adding: nil) == ["PATH": "/usr/bin:/bin"])
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: TestLockTests.vsHeavyScript, to: bin.appendingPathComponent("vs-heavy"))
        let folder = try #require(TestLock.commandFolder(besideExecutable: host))
        #expect(folder == bin.resolvingSymlinksInPath().path)
        let environment = TestLock.sessionEnvironment(["PATH": "/usr/bin:\(folder):/bin", "HOME": "/h"], adding: folder)
        #expect(environment == ["PATH": "\(folder):/usr/bin:/bin", "HOME": "/h"])
        // A login shell (its path_helper puts the system's folders first) still finds it.
        let home = temp.url("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v vs-heavy"]
        process.environment = ["PATH": environment["PATH"]!, "HOME": home.path, "ZDOTDIR": home.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(found.trimmingCharacters(in: .whitespacesAndNewlines) == folder + "/vs-heavy")
    }

    // MARK: Every project's merge takes the same lock

    @Test func aMergeInAnyProjectWaitsForVsHeavysRunAndHoldsTheSameLock() throws {
        let url = temp.url("genswap")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let lock = try #require(lead.testLock)
        let order = temp.url("order").path, seen = temp.url("seen").path
        let q = RecentProjects.shellQuote
        let test = "echo merge >> \(q(order)); echo \"$\(TestLock.heldVariable)\" > \(q(seen))"
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": test]).isError)
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]]).isError)
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        #expect(!(try seat("worker-add-b", runtime).call("report", ["status": "done", "summary": "added"])).isError)

        // Another project's worker runs its suite under vs-heavy, on the same lock.
        let holder = try TestLockTests.runVsHeavy(["--as", "tge's suite", "/bin/sh", "-c", "echo started >> \(q(order)); sleep 2; echo suite >> \(q(order))"],
                                               lockDirectory: (lock.path as NSString).deletingLastPathComponent, output: temp.url("holder.out").path)
        #expect(eventually { TestLockTests.lines(order) == ["started"] })
        let merged = lead.call("merge", ["task": "add-b"])
        holder.waitUntilExit()
        #expect(!merged.isError, "\(merged.text)")
        // Never side by side: the merge's tests ran once the suite was done, holding the lock (and saying so to them).
        #expect(TestLockTests.lines(order) == ["started", "suite", "merge"])
        #expect(TestLockTests.lines(seen) == [lock.path])
    }

    // MARK: New projects

    @Test func aNewProjectGetsMaxWorkers3AndAnExistingWorkflowIsUntouched() throws {
        let fresh = temp.url("fresh").path
        try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        Git.run(["init", "-q", "-b", "main"], in: fresh)
        let path = try BoardStore(root: fresh).prepare()
        #expect(LeadWorkflow.load(from: path).maxWorkers == 3)
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("\nmax_workers: 3\n"))
        let existing = temp.url("existing").path
        try FileManager.default.createDirectory(atPath: existing + "/.vibeswitcher", withIntermediateDirectories: true)
        Git.run(["init", "-q", "-b", "main"], in: existing)
        let text = "---\nmax_workers: 5\ntest_command: make\n---\nOur notes.\n"
        try text.write(toFile: existing + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        let kept = try BoardStore(root: existing).prepare()
        #expect(try String(contentsOfFile: kept, encoding: .utf8) == text)
        #expect(LeadWorkflow.load(from: kept).maxWorkers == 5)
    }
}
