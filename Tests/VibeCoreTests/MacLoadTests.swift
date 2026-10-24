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

    // MARK: The keys

    @Test func theMacLimitsAreWorkflowKeysWithDefaults() {
        let defaults = LeadWorkflow.parse(LeadWorkflow.template)
        #expect(defaults.loadThreshold == nil)
        #expect(defaults.loadLimit == 2 * Self.cores)
        #expect(defaults.macMaxSessions == 6)
        #expect(LeadWorkflow().macMaxSessions == 6 && LeadWorkflow().loadLimit == 2 * Self.cores)
        let set = LeadWorkflow.parse("---\nload_threshold: 30.5\nmac_max_sessions: 4\n---")
        #expect(set.loadThreshold == 30.5 && set.loadLimit == 30.5)
        #expect(set.macMaxSessions == 4)
        // What isn't a limit reads as the default.
        let wrong = LeadWorkflow.parse("---\nload_threshold: -3\nmac_max_sessions: lots\n---")
        #expect(wrong.loadThreshold == nil && wrong.macMaxSessions == 6)
        #expect(LeadWorkflow.parse("---\nmac_max_sessions: 0\n---").macMaxSessions == 1)
        #expect(LeadWorkflow.configurable.contains("load_threshold") && LeadWorkflow.configurable.contains("mac_max_sessions"))
    }

    @Test func configureSetsTheMacLimits() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let set = call(lead, "configure", ["load_threshold": 30, "mac_max_sessions": "4"])
        #expect(!set.isError, "\(set.text)")
        #expect(set.text.contains("- load_threshold: 30 in workflow.md"))
        #expect(set.text.contains("- mac_max_sessions: 4"))
        let read = LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md")
        #expect(read.loadThreshold == 30 && read.macMaxSessions == 4)
        #expect(call(lead, "configure", ["load_threshold": "busy"]).isError)
        #expect(call(lead, "configure", ["mac_max_sessions": 0]).isError)
        // Cleared: the defaults again.
        let cleared = call(lead, "configure", ["load_threshold": "", "mac_max_sessions": ""])
        #expect(!cleared.isError, "\(cleared.text)")
        #expect(cleared.text.contains("- load_threshold: \(MacLoad.number(2 * Self.cores)), twice the \(MacLoad.processors) cores"))
        #expect(cleared.text.contains("- mac_max_sessions: 6"))
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
        // A threshold the owner set is said as theirs (the lead sets it: merge and start_worker take guard rails only so).
        #expect(!call(lead, "configure", ["load_threshold": "100"]).isError)
        #expect(call(lead, "start_worker", ["task": "one"]).text.contains("load_threshold 100 in workflow.md"))
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
        // The owner raises the cap (through the lead): it starts.
        #expect(!call(lead, "configure", ["mac_max_sessions": "8"]).isError)
        #expect(!call(lead, "start_worker", ["task": "two"]).isError)
    }

    // MARK: audit

    @Test func auditRefusesWhileTheMacIsLoadedButNotForTheTasksOwnWorker() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "add-b"])
        _ = call(try seat("worker-add-b", runtime), "report", ["status": "done", "summary": "added"])
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
        try workflow(root, "mac_max_sessions: 1")
        let audit = call(lead, "audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(runtime.spawned.count == 2)
    }

    // MARK: merge

    @Test func mergeWaitsForTheLoadToDropBeforeTesting() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        #expect(!call(lead, "configure", ["load_threshold": "24"]).isError)
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

        var workflow = LeadWorkflow()
        workflow.loadThreshold = 30
        workflow.macMaxSessions = 4
        let prompt = LeadPrompts.lead(project: "p", root: root, workflow: workflow)
        #expect(prompt.contains("other projects' leads run their teams on it too"))
        #expect(prompt.contains("load_threshold (30)"))
        #expect(prompt.contains("mac_max_sessions (4)"))
        #expect(prompt.contains("merge waits up to test_timeout_min"))
        #expect(LeadPrompts.lead(project: "p", root: root, workflow: LeadWorkflow()).contains("load_threshold (\(MacLoad.number(2 * Self.cores)), twice the cores)"))
    }
}
