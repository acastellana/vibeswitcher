import Foundation
import Testing
@testable import VibeCore

/// The Mac is every project's: start_worker, audit and merge weigh its load and all projects' team sessions, not just
/// their own. Replays 2026-10-19 00:20–01:00 and 07:45–08:30: three leads (vibeswitcher, genswap, films) each ran
/// workers and verifiers, the Mac sat at load 100–190, merges failed on timing-sensitive tests and a build took 25 min.
extension LeadToolsetTests {
    static let cores = Double(MacLoad.processors)

    static func member(_ project: String, _ task: String, _ role: String = "Worker", live: Bool = true) -> LeadSessionInfo {
        LeadSessionInfo(id: "\(project)-\(role)-\(task)", cwd: "/Users/x/dev/\(project)/.vibeswitcher/worktrees/\(task)",
                        label: "\(role): \(task)", live: live, status: "working", tty: nil)
    }

    /// genswap's and films' teams, as the host listed them that night: 4 + 2 live, one ended, and their leads.
    static let neighbours: [LeadSessionInfo] = [
        member("genswap", "a"), member("genswap", "b"), member("genswap", "c"), member("genswap", "a", "Verifier"),
        member("films", "x"), member("films", "x", "Verifier"), member("films", "y", live: false),
        LeadSessionInfo(id: "genswap-lead", cwd: "/Users/x/dev/genswap", label: "Lead · genswap", live: true, status: nil, tty: nil),
        LeadSessionInfo(id: "films-lead", cwd: "/Users/x/dev/films", label: "Lead · films", live: true, status: nil, tty: nil),
    ]

    // MARK: Counting

    @Test func theMacCountsEveryProjectsLiveWorkersAndVerifiers() {
        let mac = MacLoad.count(Self.neighbours.map { ($0.label, $0.cwd, $0.live) }, load: 150.25)
        #expect(mac.sessions == 6)
        #expect(mac.holders == [MacLoad.Holder(project: "genswap", sessions: 4), MacLoad.Holder(project: "films", sessions: 2)])
        #expect(mac.line == "Mac: load 150.2, 6 team sessions across 2 projects")
        #expect(mac.sessionsText == "6 team sessions across 2 projects (genswap 4, films 2)")
        #expect(mac.isBusy(threshold: 24) && !mac.isBusy(threshold: 200))
        #expect(mac.isFull(max: 6) && !mac.isFull(max: 7))
        // A task's own folder is left out: the session about to start there takes its place.
        let without = MacLoad.count(Self.neighbours.map { ($0.label, $0.cwd, $0.live) }, load: nil,
                                    except: "/Users/x/dev/genswap/.vibeswitcher/worktrees/a/")
        #expect(without.sessions == 4)
        #expect(without.line == "Mac: load unknown, 4 team sessions across 2 projects")
        #expect(!without.isBusy(threshold: 1))
        #expect(MacLoad.count([], load: 1).line == "Mac: load 1.0, 0 team sessions across 0 projects")
        #expect(MacLoad.oneMinute().map { $0 >= 0 } == true)
    }

    // MARK: The limits

    @Test func theMacLimitsAreSetOnceForTheMacNotInWorkflowMd() throws {
        let defaults = MacLimits()
        #expect(defaults.maxSessions == 10 && defaults.loadThreshold == nil && defaults.loadLimit == 2 * Self.cores)
        #expect(defaults.loadLimitText == "\(MacLoad.number(2 * Self.cores)), twice the \(MacLoad.processors) cores")
        let folder = URL(fileURLWithPath: try repo()).appendingPathComponent("limits")
        let file = folder.appendingPathComponent("mac-limits.json")
        #expect(MacLimits.load(from: file) == defaults)
        try MacLimits(maxSessions: 4, loadThreshold: 30.5).save(to: file)
        #expect(MacLimits.load(from: file) == MacLimits(maxSessions: 4, loadThreshold: 30.5))
        #expect(MacLimits.load(from: file).loadLimitText == "30.5 in Settings")
        // What isn't a limit is kept as the nearest one: at least one session, a threshold more than 0 or none.
        #expect(MacLimits(maxSessions: 0, loadThreshold: -3) == MacLimits(maxSessions: 1))
        try Data("{\"maxSessions\": \"lots\"}".utf8).write(to: file)
        #expect(MacLimits.load(from: file) == defaults)
        #expect(MacLimits.file == VibePaths.root.appendingPathComponent("mac-limits.json"))
        // workflow.md's keys are ignored, and said so; the template no longer has them.
        let set = LeadWorkflow.parse("---\nload_threshold: 30.5\nmac_max_sessions: 20\nmax_workers: 4\n---")
        #expect(set.ignoredKeys == ["load_threshold", "mac_max_sessions"] && set.maxWorkers == 4)
        #expect(LeadWorkflow.parse("---\nload_threshold:\nmac_max_sessions: 20\n---").ignoredKeys == ["mac_max_sessions"])
        #expect(LeadWorkflow.parse(LeadWorkflow.template).ignoredKeys.isEmpty)
        #expect(!LeadWorkflow.configurable.contains("load_threshold") && !LeadWorkflow.configurable.contains("mac_max_sessions"))
    }

    @Test func configureRefusesTheMacLimitsAndPointsToSettings() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        lead.macLimits = { MacLimits(maxSessions: 10, loadThreshold: 30) }
        let before = FileManager.default.contents(atPath: root + "/.vibeswitcher/workflow.md")
        for arguments: [String: Any] in [["mac_max_sessions": "20"], ["load_threshold": 50, "max_workers": 5], ["mac_max_sessions": ""]] {
            let refused = call(lead, "configure", arguments)
            #expect(refused.isError, "\(refused.text)")
            #expect(refused.text.hasPrefix("Nothing was changed"), "\(refused.text)")
            #expect(refused.text.contains("Settings › Project lead"), "\(refused.text)")
            #expect(refused.text.contains("load_threshold 30 in Settings, mac_max_sessions 10"), "\(refused.text)")
        }
        #expect(FileManager.default.contents(atPath: root + "/.vibeswitcher/workflow.md") == before)
        // configure shows them, as the Mac's.
        let shown = call(lead, "configure").text
        #expect(shown.contains("Mac-wide, set by the user in VibeSwitcher's Settings › Project lead"), "\(shown)")
        #expect(shown.contains("- load_threshold: 30 in Settings") && shown.contains("- mac_max_sessions: 10"), "\(shown)")
    }

    @Test func workflowMdsMacLimitsAreIgnoredAndStatusSaysSoOnce() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        // TGE-ANALYSIS's: 20 in its workflow.md, while the Mac's cap is 6 and the neighbours hold 6.
        try workflow(root, "mac_max_sessions: 20\nload_threshold: 999")
        runtime.others = Self.neighbours
        let refused = call(lead, "start_worker", ["task": "one"])
        #expect(refused.isError && refused.text.contains("(mac_max_sessions 6)"), "\(refused.text)")
        let said = "workflow.md's mac_max_sessions and load_threshold are ignored: the Mac-wide limits are set once for every project in VibeSwitcher's Settings › Project lead."
        #expect(call(lead, "status").text.contains(said))
        #expect(!call(lead, "status").text.contains("are ignored"))
        // configure still says it, as the file's settings.
        #expect(call(lead, "configure").text.contains(said))
    }

    @Test func noRefusalSuggestsRaisingTheCap() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        runtime.others = Self.neighbours
        runtime.load = 150
        var texts = [call(lead, "start_worker", ["task": "one"]).text]
        runtime.others = []
        runtime.load = 1
        _ = call(lead, "start_worker", ["task": "one"])
        _ = call(try seat("worker-one", runtime), "report", doneReport("done"))
        runtime.others = Self.neighbours
        texts.append(call(lead, "audit", ["task": "one"]).text)
        for text in texts {
            #expect(text.contains("mac_max_sessions 6"), "\(text)")
            for advice in ["raise", "Raise", "higher", "increase", "configure", "workflow.md"] {
                #expect(!text.contains(advice), "\(advice): \(text)")
            }
        }
    }

    // MARK: start_worker

    @Test func startWorkerRefusesWhileTheMacIsLoaded() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        runtime.load = 150
        runtime.others = [Self.member("genswap", "a"), Self.member("films", "x")]
        let refused = call(lead, "start_worker", ["task": "one"])
        #expect(refused.isError)
        #expect(refused.text.contains("Not started"))
        #expect(refused.text.contains("load 150.0 (load_threshold \(MacLoad.number(2 * Self.cores)), twice the \(MacLoad.processors) cores)"))
        #expect(refused.text.contains("2 team sessions across 2 projects (films 1, genswap 1) (mac_max_sessions 6)"))
        #expect(refused.text.contains(LeadPrompts.retryWhenWoken) && !refused.text.contains("about 5 minutes"))
        #expect(runtime.spawned.isEmpty)
        #expect(BoardStore(root: root).load().task("one")?.status == .planned)
        // A threshold the user set in Settings is said as theirs.
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 100) }
        #expect(call(lead, "start_worker", ["task": "one"]).text.contains("load_threshold 100 in Settings"))
        // Once it eases, it starts.
        runtime.load = 3
        let started = call(lead, "start_worker", ["task": "one"])
        #expect(!started.isError, "\(started.text)")
    }

    @Test func startWorkerRefusesAtTheMacWideCapCountingOtherProjects() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
        // Its own worker, and the neighbours' six: max_workers (3 here) doesn't stop a second one, the Mac does.
        runtime.others = Self.neighbours
        let refused = call(lead, "start_worker", ["task": "two"])
        #expect(refused.isError)
        #expect(refused.text.contains("team sessions of all its projects are at mac_max_sessions"))
        #expect(refused.text.contains("7 team sessions across 3 projects (genswap 4, films 2, \((root as NSString).lastPathComponent) 1) (mac_max_sessions 6)"))
        #expect(!refused.text.contains("above load_threshold"))
        #expect(runtime.spawned.count == 1)
        // The user raises the Mac's cap in Settings: it starts.
        lead.macLimits = { MacLimits(maxSessions: 8) }
        #expect(!call(lead, "start_worker", ["task": "two"]).isError)
    }

    /// 2026-10-28: since PR #1 the host lists a lead only its own team. Counted from that, status read "5 team sessions
    /// across 1 project" with 9 running across 3, and start_worker went past the Mac's cap. The host's census counts
    /// every project's team for it.
    @Test func startWorkerRefusesAtTheMacWideCapCountingProjectsTheHostDoesntList() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
        runtime.unlisted = Self.neighbours
        #expect(try runtime.sessions().count == 1)
        let own = (root as NSString).lastPathComponent
        let counted = "7 team sessions across 3 projects (genswap 4, films 2, \(own) 1) (mac_max_sessions 6)"
        #expect(call(lead, "status").text.contains("Mac (every project's team): load 0.5 (load_threshold \(MacLoad.number(2 * Self.cores)), twice the \(MacLoad.processors) cores), \(counted)."))
        let refused = call(lead, "start_worker", ["task": "two"])
        #expect(refused.isError)
        #expect(refused.text.contains("team sessions of all its projects are at mac_max_sessions"), "\(refused.text)")
        #expect(refused.text.contains(counted), "\(refused.text)")
        #expect(runtime.spawned.count == 1)
        // A census that can't be read starts nothing: counted from its own team, the lead would go past the cap.
        lead.macLimits = { MacLimits(maxSessions: 8) }
        runtime.censusDown = "The session host didn't answer in time."
        let unknown = call(lead, "start_worker", ["task": "two"])
        #expect(unknown.isError && unknown.text.contains("count of every project's team sessions can't be read"), "\(unknown.text)")
        #expect(call(lead, "status").text.contains("Mac (every project's team): not known"))
        #expect(runtime.spawned.count == 1)
        runtime.censusDown = nil
        #expect(!call(lead, "start_worker", ["task": "two"]).isError)
    }

    @Test func theCensusCountsLiveTeamSessionsByRepositoryAndRole() {
        let census = HostCensus.count(Self.neighbours.map { ($0.label, $0.cwd, $0.live) }
                                      + [("Claude", "/Users/x/dev/genswap", true), ("Worker: z", "/Users/x/dev/films/.vibeswitcher/worktrees/z/", true)])
        #expect(census == [HostCensus(root: "/Users/x/dev/films", role: .lead, sessions: 1),
                           HostCensus(root: "/Users/x/dev/films", role: .verifier, sessions: 1),
                           HostCensus(root: "/Users/x/dev/films", role: .worker, sessions: 2),
                           HostCensus(root: "/Users/x/dev/genswap", role: .lead, sessions: 1),
                           HostCensus(root: "/Users/x/dev/genswap", role: .verifier, sessions: 1),
                           HostCensus(root: "/Users/x/dev/genswap", role: .worker, sessions: 3)])
        // The Mac from it: the leads aren't counted, and the sessions listed in the task's own worktree are left out.
        let listed = [Self.member("genswap", "a"), Self.member("genswap", "a", "Verifier"), Self.member("genswap", "b")]
        let mac = MacLoad.count(census: census, sessions: listed.map { ($0.label, $0.cwd, $0.live) }, load: 2,
                                except: "/Users/x/dev/genswap/.vibeswitcher/worktrees/a")
        #expect(mac.holders == [MacLoad.Holder(project: "films", sessions: 3), MacLoad.Holder(project: "genswap", sessions: 2)])
        #expect(MacLoad.count(census: census, sessions: [], load: 2).sessions == 7)
    }

    // MARK: audit

    @Test func auditRefusesWhileTheMacIsLoadedButNotForTheTasksOwnWorker() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "add-b"])
        _ = call(try seat("worker-add-b", runtime), "report", doneReport("added"))
        runtime.load = 190
        let busy = call(lead, "audit", ["task": "add-b"])
        #expect(busy.isError)
        #expect(busy.text.contains("No verifier started"))
        #expect(busy.text.contains("load 190.0"))
        #expect(runtime.spawned.count == 1)
        // A cap the neighbours fill.
        runtime.load = 1
        runtime.others = Self.neighbours
        let full = call(lead, "audit", ["task": "add-b"])
        #expect(full.isError)
        #expect(full.text.contains("6 team sessions across 2 projects (genswap 4, films 2)"))
        #expect(runtime.spawned.count == 1)
        // Its own worker, done, isn't counted: with a cap of one and nobody else, the verifier starts.
        runtime.others = []
        lead.macLimits = { MacLimits(maxSessions: 1) }
        let audit = call(lead, "audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(runtime.spawned.count == 2)
    }

    /// A task worked on and reported done, the neighbours' six sessions on the Mac and room for one more: the
    /// verifier fits only in its worker's place.
    func reportedOnAFullMac(_ runtime: FakeRuntime) throws -> (root: String, lead: LeadToolset, worker: String) {
        let root = try repo()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"]])
        #expect(!call(lead, "start_worker", ["task": "add-b"]).isError)
        _ = call(try seat("worker-add-b", runtime), "report", doneReport("added"))
        runtime.others = Self.neighbours
        lead.macLimits = { MacLimits(maxSessions: 7) }
        return (root, lead, try #require(BoardStore(root: root).load().task("add-b")?.worker))
    }

    /// 2026-10-24: finished workers waiting for their audits held 4 to 5 of the Mac's 10 slots, verifiers were
    /// refused for mac_max_sessions, and the lead ended the idle workers by hand. audit ends the task's own worker,
    /// idle since its done report, when the Mac has no room for the verifier beside it.
    @Test func auditEndsTheTasksOwnIdleWorkerToMakeRoom() throws {
        let runtime = FakeRuntime()
        let (root, lead, worker) = try reportedOnAFullMac(runtime)
        runtime.statuses[worker] = LeadActivity.idle(background: nil).text
        let audit = call(lead, "audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(runtime.killed == [worker])
        #expect(audit.text.contains("Ended add-b's worker, idle since its done report on "), "\(audit.text)")
        #expect(audit.text.contains("(8 with it, 7 at most), and the audit takes its slot"), "\(audit.text)")
        #expect(audit.text.contains("Verifier started on add-b"), "\(audit.text)")
        #expect(runtime.spawned.contains { $0.command.contains("--name 'verify-add-b'") })
        let task = BoardStore(root: root).load().task("add-b")
        #expect(task?.stopped == worker && task?.status == .review)
    }

    /// The worker is mid-turn (working, waiting on its background task or on a prompt), its last report isn't done on
    /// the branch's head, or the Mac has room beside it: it's never ended, and the verifier starts as before.
    @Test func auditNeverEndsAWorkerMidTurnOrNotDoneOrWithRoomBesideIt() throws {
        for case_ in ["working", "background", "prompt", "not done on head", "room"] {
            let runtime = FakeRuntime()
            let (root, lead, worker) = try reportedOnAFullMac(runtime)
            runtime.statuses[worker] = LeadActivity.idle(background: nil).text
            switch case_ {
            case "working": runtime.statuses[worker] = LeadActivity.working("Bash").text
            case "background": runtime.statuses[worker] = LeadActivity.idle(background: "swift test").text
            case "prompt": runtime.waiting[worker] = PendingPrompt(text: "Run: ls?")
            case "not done on head":
                let worktree = Worktrees.path(root: root, slug: "add-b")
                try "more\n".write(toFile: worktree + "/more.txt", atomically: true, encoding: .utf8)
                Git.run(["add", "more.txt"], in: worktree)
                Git.run(["commit", "-q", "-m", "more after the report"], in: worktree)
            default: lead.macLimits = { MacLimits(maxSessions: 8) }
            }
            let audit = call(lead, "audit", ["task": "add-b"])
            #expect(!audit.isError, "\(case_): \(audit.text)")
            #expect(runtime.killed.isEmpty, "\(case_)")
            #expect(!audit.text.contains("Ended add-b's worker"), "\(case_): \(audit.text)")
            #expect(BoardStore(root: root).load().task("add-b")?.stopped == nil, "\(case_)")
        }
    }

    /// Refused for the load, or with the neighbours alone at the cap (its slot wouldn't be enough): the idle worker
    /// stays, and nothing starts.
    @Test func anAuditRefusedAnywayEndsNoWorker() throws {
        for case_ in ["load", "full without it"] {
            let runtime = FakeRuntime()
            let (_, lead, worker) = try reportedOnAFullMac(runtime)
            runtime.statuses[worker] = LeadActivity.idle(background: nil).text
            if case_ == "load" { runtime.load = 190 } else { lead.macLimits = { MacLimits(maxSessions: 6) } }
            let refused = call(lead, "audit", ["task": "add-b"])
            #expect(refused.isError && refused.text.contains("No verifier started"), "\(case_): \(refused.text)")
            #expect(runtime.killed.isEmpty, "\(case_)")
            #expect(!runtime.spawned.contains { $0.command.contains("--name 'verify-add-b'") }, "\(case_)")
        }
    }

    /// The host refuses to end the worker: the verifier starts beside it, as before, and the reply says so.
    @Test func aWorkerTheHostWontEndIsSaidAndTheVerifierStillStarts() throws {
        let runtime = FakeRuntime()
        let (_, lead, worker) = try reportedOnAFullMac(runtime)
        runtime.statuses[worker] = LeadActivity.idle(background: nil).text
        runtime.refusals[worker] = "no such session"
        let audit = call(lead, "audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(audit.text.contains("wasn't ended to make room for the verifier") && audit.text.contains("no such session"), "\(audit.text)")
        #expect(audit.text.contains("Verifier started on add-b"), "\(audit.text)")
    }

    // MARK: merge

    @Test func mergeWaitsForTheLoadToDropBeforeTesting() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 24) }
        lead.loadPoll = 0.01
        runtime.loadReadings = [150, 120, 40, 3]
        let reads = runtime.loadReads
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("waited") && merged.text.contains("from 150 below load_threshold"))
        #expect(runtime.loadReads - reads == 4)
        #expect(FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    @Test func mergeRefusesWhenTheLoadStaysAboveTheThreshold() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        // 0.005 min: the wait is bounded by test_timeout_min (0.3 s).
        try workflow(root, "test_timeout_min: 0.005")
        lead.loadPoll = 0.02
        runtime.load = 150
        runtime.others = Self.neighbours
        let before = Git.run(["rev-parse", "main"], in: root).output
        let started = Date()
        let refused = call(lead, "merge", ["task": "add-b"])
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(refused.isError)
        #expect(refused.text.contains("Not merged (nothing was tested)"))
        #expect(refused.text.contains("stayed above load_threshold"))
        #expect(refused.text.contains(LeadPrompts.retryWhenWoken))
        #expect(refused.text.contains("load 150.0"))
        // The task's own worker and verifier count too, here: the Mac as it is.
        #expect(refused.text.contains("8 team sessions across 3 projects (genswap 4, films 2, \((root as NSString).lastPathComponent) 2)"))
        #expect(runtime.loadReads > 3)
        #expect(Git.run(["rev-parse", "main"], in: root).output == before)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
        // The load drops: the same verdict merges.
        runtime.load = 2
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(!merged.text.contains("waited"))
    }

    // MARK: What the lead is told

    @Test func statusAndThePromptTellTheLeadAboutTheMac() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        runtime.others = Self.neighbours
        runtime.load = 12.5
        let status = call(lead, "status").text
        #expect(status.contains("Mac (every project's team): load 12.5"))
        #expect(status.contains("6 team sessions across 2 projects (genswap 4, films 2) (mac_max_sessions 6)"))
        #expect(status.contains("start_worker and audit refuse until it eases"))
        runtime.others = []
        runtime.load = 1
        #expect(!call(lead, "status").text.contains("refuse until it eases"))

        let prompt = LeadPrompts.lead(project: "p", root: root, workflow: LeadWorkflow(), limits: MacLimits(maxSessions: 4, loadThreshold: 30))
        #expect(prompt.contains("other projects' leads run their teams on it too"))
        #expect(prompt.contains("load_threshold (30)"))
        #expect(prompt.contains("mac_max_sessions (4); both are set once for the Mac by the user in VibeSwitcher's Settings"))
        #expect(prompt.contains("VibeSwitcher sends you one message once there's room again"))
        #expect(prompt.contains("merge waits up to test_timeout_min"))
        #expect(LeadPrompts.lead(project: "p", root: root, workflow: LeadWorkflow(), limits: MacLimits())
            .contains("load_threshold (\(MacLoad.number(2 * Self.cores)), twice the cores)"))
    }
}
