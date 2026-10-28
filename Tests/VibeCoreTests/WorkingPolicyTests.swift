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
        let root = "/Users/someone/dev/project-c"
        let prompts = [
            ("lead", LeadPrompts.lead(project: "project-c", root: root, workflow: workflow, policy: Self.custom)),
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
        // This build's first look: project-c's and TGE's leads, started by an older build, are told once.
        let first = watch.look(running: ["project-c-lead", "tge-lead"])
        #expect(first?.leads == ["project-c-lead", "tge-lead"])
        #expect(first?.text == WorkingPolicy.witnessText(WorkingPolicy.defaultText))
        #expect(first?.text.contains("Apply it from now on") == true)
        // Looked at again (a minute on, or after a relaunch: a new watch on the same file), nothing.
        #expect(watch.look(running: ["project-c-lead", "tge-lead"]) == nil)
        #expect(self.watch(policy).look(running: ["project-c-lead", "tge-lead"]) == nil)
        // A lead started since, with the policy in its prompt, isn't told it.
        watch.started("films-lead", with: WorkingPolicy.defaultText)
        #expect(watch.look(running: ["project-c-lead", "tge-lead", "films-lead"]) == nil)
        // Changed: each running lead once, with the new text.
        policy.set(Self.custom)
        let changed = watch.look(running: ["project-c-lead", "tge-lead", "films-lead"])
        #expect(changed?.leads == ["project-c-lead", "tge-lead", "films-lead"])
        #expect(changed?.text.hasSuffix(Self.custom) == true)
        #expect(watch.look(running: ["project-c-lead", "tge-lead", "films-lead"]) == nil)
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

    /// A compaction a lead's transcript shows, `minutes` after the epoch-ish start of these tests.
    static func compaction(_ id: String, at minutes: Double) -> TranscriptTail.Compaction {
        TranscriptTail.Compaction(id: id, at: 1_800_000_000 + minutes * 60)
    }

    static func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60) }

    @Test func aLeadToldInAMessageIsToldAgainOnceAfterEachCompaction() {
        let policy = Locked(WorkingPolicy.defaultText)
        let watch = watch(policy)
        // TGE's lead, started before the policy, compacted once already: told now, and not again for that compaction.
        let old = Self.compaction("c0", at: 0)
        #expect(watch.look(running: ["tge-lead"], compactions: ["tge-lead": old], now: Self.at(1))?.leads == ["tge-lead"])
        #expect(watch.look(running: ["tge-lead"], compactions: ["tge-lead": old], now: Self.at(2)) == nil)
        // Its context compacted since: told again, once.
        let first = Self.compaction("c1", at: 10)
        let again = watch.look(running: ["tge-lead"], compactions: ["tge-lead": first], now: Self.at(11))
        #expect(again?.leads == ["tge-lead"])
        #expect(again?.text == WorkingPolicy.witnessText(WorkingPolicy.defaultText))
        #expect(watch.look(running: ["tge-lead"], compactions: ["tge-lead": first], now: Self.at(12)) == nil)
        // Never twice for the same one, after a relaunch too (a new watch on the same file).
        #expect(self.watch(policy).look(running: ["tge-lead"], compactions: ["tge-lead": first], now: Self.at(13)) == nil)
        // The next compaction: once more.
        let second = Self.compaction("c2", at: 20)
        #expect(watch.look(running: ["tge-lead"], compactions: ["tge-lead": second], now: Self.at(21))?.leads == ["tge-lead"])
        #expect(watch.look(running: ["tge-lead"], compactions: ["tge-lead": second], now: Self.at(22)) == nil)
        // The transcript's tail no longer showing it (it scrolled past): nothing.
        #expect(watch.look(running: ["tge-lead"], now: Self.at(23)) == nil)
    }

    @Test func aCompactionBeforeTheTellingIsntToldAgainAndAPromptedLeadKeepsItThroughCompactions() {
        let policy = Locked(WorkingPolicy.defaultText)
        let watch = watch(policy)
        // Told at minute 5; a compaction it shows from minute 3 (another id than any told) came before that.
        #expect(watch.look(running: ["project-c-lead"], now: Self.at(5))?.leads == ["project-c-lead"])
        #expect(watch.look(running: ["project-c-lead"], compactions: ["project-c-lead": Self.compaction("g0", at: 3)], now: Self.at(6)) == nil)
        // A lead started with it in its prompt has it after any compaction: not told.
        watch.started("films-lead", with: WorkingPolicy.defaultText)
        let compacted = ["films-lead": Self.compaction("f1", at: 30), "project-c-lead": Self.compaction("g1", at: 30)]
        #expect(watch.look(running: ["films-lead", "project-c-lead"], compactions: compacted, now: Self.at(31))?.leads == ["project-c-lead"])
        // The policy changed: the prompted lead has the old one in its prompt, so it's told, and from then on it's
        // told again after a compaction like any lead told in a message.
        policy.set(Self.custom)
        #expect(watch.look(running: ["films-lead", "project-c-lead"], compactions: compacted, now: Self.at(40))?.leads == ["films-lead", "project-c-lead"])
        let later = ["films-lead": Self.compaction("f2", at: 50)]
        #expect(watch.look(running: ["films-lead", "project-c-lead"], compactions: later, now: Self.at(51))?.leads == ["films-lead"])
        #expect(watch.look(running: ["films-lead", "project-c-lead"], compactions: later, now: Self.at(52)) == nil)
    }

    @Test func aTranscriptsLastCompactionIsItsLatestMainThreadBoundary() throws {
        func line(_ object: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let lines = [
            line(["type": "user", "uuid": "u1", "timestamp": "2026-10-24T10:00:00.000Z", "message": ["role": "user", "content": "hi"]]),
            line(["type": "system", "subtype": "compact_boundary", "uuid": "b1", "timestamp": "2026-10-24T10:05:00.000Z",
                  "content": "Conversation compacted", "isSidechain": false]),
            line(["type": "user", "isCompactSummary": true, "uuid": "s1", "timestamp": "2026-10-24T10:05:01.000Z",
                  "message": ["role": "user", "content": "This session is being continued from a previous conversation that mentions compact_boundary."]]),
            line(["type": "system", "subtype": "compact_boundary", "uuid": "b2", "timestamp": "2026-10-24T11:00:00.000Z",
                  "content": "Conversation compacted", "isSidechain": false]),
            line(["type": "system", "subtype": "compact_boundary", "uuid": "side", "timestamp": "2026-10-24T11:30:00.000Z",
                  "content": "Conversation compacted", "isSidechain": true]),
            line(["type": "assistant", "uuid": "a1", "timestamp": "2026-10-24T11:31:00.000Z", "message": ["role": "assistant", "content": []]]),
        ]
        let found = try #require(TranscriptTail.lastCompaction(Data((lines.joined(separator: "\n") + "\n").utf8)))
        #expect(found.id == "b2")
        #expect(found.at == ChatReader.date("2026-10-24T11:00:00.000Z")?.timeIntervalSince1970)
        // A partial last line isn't read yet; none at all: nil.
        #expect(TranscriptTail.lastCompaction(Data((lines.prefix(3).joined(separator: "\n") + "\n" + lines[3].dropLast(5)).utf8))?.id == "b1")
        #expect(TranscriptTail.lastCompaction(Data((lines[0] + "\n").utf8)) == nil)
        // From a file, read again once it changed.
        let file = temp.url("transcript.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.prefix(2).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(TranscriptTail.lastCompaction(url: file)?.id == "b1")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(TranscriptTail.lastCompaction(url: file)?.id == "b2")
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
        let url = temp.url("project-c")
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
        #expect(!(try seat("worker-add-b", runtime).call("report", doneReport("added"))).isError)

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
