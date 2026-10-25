import Foundation
import Testing
@testable import VibeCore

/// auto_advance (see `LeadAdvance`): finished work moves on by itself, through the lead's own tools, with no lead tool
/// call in between. Fake workers and verifiers report through their own tool servers; the test commands are fakes.
/// Each wait is on the loop's own passes (`Advancing.until`), never a fixed sleep.
struct LeadAdvanceTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    /// Where the fake test commands write what they did.
    let log: String
    init() {
        vault = Self.newVault(in: temp)
        log = temp.url("runs.log").path
    }

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

    func commit(_ file: String, _ text: String, in dir: String) throws {
        try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        Git.run(["commit", "-q", "-m", "change \(file)"], in: dir)
    }

    /// A lead with merge_policy auto, `test` as its test command and `settings` besides.
    func team(test: String? = nil, _ settings: [String: Any] = [:]) throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        // On AC power, whatever this Mac's own reading says.
        lead.power = { nil }
        var all: [String: Any] = ["merge_policy": "auto", "test_command": test ?? "echo \"ran $(cat *.txt | tr '\\n' ' ')\" >> '\(log)'"]
        all.merge(settings) { $1 }
        let configured = lead.call("configure", all)
        #expect(!configured.isError, "\(configured.text)")
        return (root, runtime, lead)
    }

    /// The lead's loop, its passes run on threads of their own (the tool server runs them as its background work).
    final class Advancing: @unchecked Sendable {
        private let lock = NSCondition()
        private var count = 0
        let lead: LeadToolset

        init(_ lead: LeadToolset, run: ((@escaping () -> Void) -> Bool)? = nil) {
            self.lead = lead
            lead.startAdvancing(run: run ?? { work in
                Thread.detachNewThread(work)
                return true
            })
            lead.advancing?.passed = { [weak self] in self?.ended() }
        }

        private func ended() {
            lock.lock()
            count += 1
            lock.broadcast()
            lock.unlock()
        }

        var passes: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        /// Waits, run of passes by run, until `condition` holds (60 s at most); whether it does.
        @discardableResult
        func until(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(60)
            lock.lock()
            defer { lock.unlock() }
            while true {
                lock.unlock()
                let met = condition()
                lock.lock()
                if met { return true }
                let seen = count
                while count == seen {
                    guard lock.wait(until: deadline) else { return false }
                }
            }
        }

        /// One more run of passes, and waits for it: what a change the folder watch might not see would bring.
        func settle() {
            let before = passes
            lead.advancing?.trigger()
            lock.lock()
            let deadline = Date().addingTimeInterval(60)
            while count == before, lock.wait(until: deadline) {}
            lock.unlock()
        }

        /// No more passes, the one under way ended: nothing writes the test's folders after it.
        func stop() { lead.advancing?.stop(wait: true) }
    }

    func task(_ slug: String, _ root: String) -> LeadTask? { BoardStore(root: root).load().task(slug) }

    /// The lead's reports from the loop.
    func reports(_ runtime: FakeRuntime) -> [String] {
        runtime.calls.lock()
        defer { runtime.calls.unlock() }
        return runtime.steered.filter { $0.text.hasPrefix("VibeSwitcher moved finished work on by itself") }.map(\.text)
    }

    /// What the task's worker session was sent.
    func toWorker(_ slug: String, _ root: String, _ runtime: FakeRuntime) -> [String] {
        guard let worker = task(slug, root)?.worker else { return [] }
        runtime.calls.lock()
        defer { runtime.calls.unlock() }
        return runtime.steered.filter { $0.target == worker }.map(\.text)
    }

    /// A report from `about` on the board says `text`.
    func said(_ about: String, _ text: String, _ root: String) -> Bool {
        BoardStore(root: root).load().reports?.contains { $0.about == about && $0.text.contains(text) } == true
    }

    /// The lead's tool server again (a new build's), in the same session, as the fixture's lead is set up.
    func restarted(_ root: String, _ runtime: FakeRuntime) -> LeadToolset {
        let lead = LeadToolset(root: root, runtime: runtime, vault: vault(for: runtime))
        lead.testLock = testLock
        lead.macLimits = { MacLimits(maxSessions: 6) }
        lead.roomWaits = roomWaits
        lead.power = { nil }
        return lead
    }

    func head(_ ref: String, _ root: String) -> String { Git.run(["rev-parse", ref], in: root).output }

    func progress(_ root: String) -> String {
        (try? String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)) ?? ""
    }

    /// `slug`'s worker (started by the loop) commits `file` and reports done.
    func work(_ slug: String, file: String, root: String, _ runtime: FakeRuntime) throws {
        try commit(file, "bee\n", in: Worktrees.path(root: root, slug: slug))
        let report = try seat("worker-\(slug)", runtime).call("report", doneReport("added \(file)"))
        #expect(!report.isError, "\(report.text)")
    }

    // MARK: review none

    @Test func aReviewNoneTaskStartsMergesWithItsTestRunAndIsCleanedUpWithNoLeadCall() throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        let added = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(added.text.contains("starts by itself"), "\(added.text)")
        #expect(advancing.until { task("add-b", root)?.status == .running })
        let worktree = Worktrees.path(root: root, slug: "add-b")

        // From here on, only the fake worker acts.
        try work("add-b", file: "b.txt", root: root, runtime)
        // Its report told the lead it needn't merge.
        #expect(said("worker add-b", LeadAdvance.mergesItself, root))
        #expect(advancing.until { task("add-b", root)?.status == .done && task("add-b", root)?.worktree == nil
            && reports(runtime).contains { $0.contains("Cleaned up add-b") } })
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
        #expect(task("add-b", root)?.merged?.unaudited == true)
        // The full test command ran on it, once.
        let runs = try String(contentsOfFile: log, encoding: .utf8)
        #expect(runs == "ran one bee \n", "\(runs)")
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(!Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/agent/add-b"], in: root).ok)
        // One report says both, and the progress log has each step.
        let merged = reports(runtime).filter { $0.contains("Merged add-b") }
        #expect(merged.count == 1 && merged[0].contains("Cleaned up add-b"), "\(reports(runtime))")
        #expect(progress(root).contains("Automatically (auto_advance): Merged add-b"))
        #expect(progress(root).contains("Automatically (auto_advance): Started a worker on add-b"))
    }

    @Test func aMergeWhoseTestsFailSendsItsWorkerTheOutputAndTheTaskStaysInProgress() throws {
        let (root, runtime, lead) = try team(test: "echo BROKEN-ON-PURPOSE; exit 1")
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(advancing.until { task("add-b", root)?.status == .running })
        let main = head("main", root)
        try work("add-b", file: "b.txt", root: root, runtime)
        #expect(advancing.until { toWorker("add-b", root, runtime).contains { $0.contains("BROKEN-ON-PURPOSE") } && task("add-b", root)?.status == .running
            && reports(runtime).contains { $0.contains("Merge of add-b failed") } })
        #expect(head("main", root) == main)
        let after = try #require(task("add-b", root))
        #expect(after.status == .running && after.setback?.stage == .merge, "\(after.status)")
        #expect(reports(runtime).contains { $0.contains("Merge of add-b failed") && $0.contains("Sent its worker the output") })
        // Not tried again until its worker reports again.
        advancing.settle()
        #expect(toWorker("add-b", root, runtime).filter { $0.contains("BROKEN-ON-PURPOSE") }.count == 1)
    }

    @Test func aMergeThatPassesOnItsRerunMergesAndSaysSo() throws {
        // Fails its first run in the merge's scratch home, passes the rerun in the same one (`MergeRerun`: run whole).
        let flaky = "[[ -e \"$HOME/ran\" ]] || { touch \"$HOME/ran\"; echo '✘ Test flaky() recorded an issue at FlakyTests.swift:3:5: Expectation failed: ready'; "
            + "echo '✘ Test flaky() failed after 0.010 seconds with 1 issue.'; echo '✘ Test run with 2 tests failed after 0.020 seconds with 1 issue.'; exit 1; }; echo ok >> '\(log)'"
        let (root, runtime, lead) = try team(test: flaky)
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(advancing.until { task("add-b", root)?.status == .running })
        try work("add-b", file: "b.txt", root: root, runtime)
        #expect(advancing.until { task("add-b", root)?.status == .done && reports(runtime).contains { $0.contains("Merged add-b") } })
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "ok\n")
        #expect(reports(runtime).contains { $0.contains("Merged add-b") && $0.contains("merged on the rerun") }, "\(reports(runtime))")
    }

    // MARK: audit

    @Test func anAuditTaskGetsItsAuditAndACleanVerdictMerges() throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(advancing.until { task("add-b", root)?.status == .running })
        try work("add-b", file: "b.txt", root: root, runtime)
        #expect(said("worker add-b", LeadAdvance.auditsItself, root))
        #expect(advancing.until { vault.current(.verifier, root: root, task: "add-b")?.auditing == head("agent/add-b", root)
            && reports(runtime).contains { $0.contains("Started the audit of add-b") } })
        // Not before its verdict.
        #expect(task("add-b", root)?.status == .review && (try? String(contentsOfFile: log, encoding: .utf8)) == nil)
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked", "tests": "passed"])
        #expect(!verdict.isError, "\(verdict.text)")
        #expect(advancing.until { task("add-b", root)?.status == .done && task("add-b", root)?.worktree == nil
            && reports(runtime).contains { $0.contains("Cleaned up add-b") } })
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
        #expect(task("add-b", root)?.merged?.unaudited == false)
        #expect(reports(runtime).contains { $0.contains("Merged add-b") && $0.contains("on its passing audit") })
    }

    @Test func openImportantFindingsGoBackToTheWorkerOnceAndTheTaskDoesntMerge() throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(advancing.until { task("add-b", root)?.status == .running })
        try work("add-b", file: "b.txt", root: root, runtime)
        #expect(advancing.until { vault.current(.verifier, root: root, task: "add-b") != nil })
        let finding: [String: Any] = ["severity": "Important", "file": "b.txt", "line": 1, "evidence": "b.txt says bee, the contract wants b", "failure_scenario": "cat b.txt gives bee where the contract wants b", "status": "open"]
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "one problem",
                                                                                "tests": "passed", "findings": [finding]])
        #expect(!verdict.isError, "\(verdict.text)")
        #expect(said("verifier add-b", LeadAdvance.sendsBackItself, root))
        #expect(advancing.until { toWorker("add-b", root, runtime).contains { $0.contains("F1") && $0.contains("contract wants b") }
            && task("add-b", root)?.autoSentBack != nil && reports(runtime).contains { $0.contains("add-b:F1") } })
        let after = try #require(task("add-b", root))
        #expect(after.status == .running && after.autoSentBack == head("agent/add-b", root))
        #expect(!Git.run(["show", "main:b.txt"], in: root).ok)
        #expect(reports(runtime).contains { $0.contains("add-b:F1") })
        // Once per verdict, through another pass and another loop (a new build's) alike.
        advancing.settle()
        advancing.stop()
        let again = Advancing(restarted(root, runtime))
        defer { again.stop() }
        again.settle()
        #expect(toWorker("add-b", root, runtime).filter { $0.contains("F1") }.count == 1)
    }

    @Test func pastTheRoundCapTheTaskIsLeftToTheLead() throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(advancing.until { task("add-b", root)?.status == .running })
        try work("add-b", file: "b.txt", root: root, runtime)
        let finding: [String: Any] = ["severity": "Important", "file": "b.txt", "line": 1, "evidence": "b.txt says bee, the contract wants b", "failure_scenario": "cat b.txt gives bee where the contract wants b", "status": "open"]
        let verdict: [String: Any] = ["completion": "incomplete", "integrity": "clean", "summary": "one problem", "tests": "passed"]
        #expect(advancing.until { vault.current(.verifier, root: root, task: "add-b") != nil })
        _ = try seat("verify-add-b", runtime).call("submit_audit", verdict.merging(["findings": [finding]]) { $1 })
        // Round 1: back to its worker, which tries again.
        #expect(advancing.until { toWorker("add-b", root, runtime).contains { $0.contains("F1") } && task("add-b", root)?.autoSentBack != nil })
        #expect(toWorker("add-b", root, runtime).last { $0.contains("F1") }?.contains("answer_findings") == true)
        try commit("b.txt", "be\n", in: Worktrees.path(root: root, slug: "add-b"))
        let again = try seat("worker-add-b", runtime).call("report", doneReport("tried b"))
        #expect(!again.isError, "\(again.text)")
        let first = vault.current(.verifier, root: root, task: "add-b")?.id
        #expect(advancing.until { vault.current(.verifier, root: root, task: "add-b").map { $0.id != first } ?? false })
        // Round 2 leaves it open too: the ledger says reconsider, and the loop leaves the task to the lead.
        let still = finding.merging(["id": "F1", "evidence": "b.txt still says bee"]) { $1 }
        let second = try seat("verify-add-b", runtime).call("submit_audit", verdict.merging(["findings": [still]]) { $1 })
        #expect(!second.isError, "\(second.text)")
        #expect(vault.audits(root: root, task: "add-b")?.reconsider == true)
        advancing.settle()
        #expect(task("add-b", root)?.status == .failed)
        #expect(toWorker("add-b", root, runtime).filter { $0.contains("F1") }.count == 1)
        #expect(!BoardStore(root: root).load().reports!.contains { $0.about == "verifier add-b" && $0.text.contains(LeadAdvance.sendsBackItself) && $0.text.contains("still says bee") })
    }

    // MARK: holds and switches

    @Test func nothingMovesATaskTheLeadHoldsNorWithAutoAdvanceOff() throws {
        let (root, runtime, lead) = try team(test: nil, ["max_workers": 4])
        _ = lead.call("add_task", ["title": "Kept", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "Held", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "Own", "goal": "g", "acceptance": ["a"], "auto_advance": false])
        #expect(!lead.call("update_task", ["task": "held", "status": "blocked"]).isError)
        #expect(!lead.call("start_worker", ["task": "kept"]).isError)
        try commit("b.txt", "bee\n", in: Worktrees.path(root: root, slug: "kept"))
        #expect(!lead.call("update_task", ["task": "kept", "status": "kept", "reason": "the user looks first"]).isError)
        _ = try seat("worker-kept", runtime).call("report", doneReport("done"))
        #expect(task("kept", root)?.status == .kept)

        let advancing = Advancing(lead)
        defer { advancing.stop() }
        advancing.settle()
        #expect(task("kept", root)?.status == .kept && task("kept", root)?.merged == nil)
        #expect(task("held", root)?.status == .blocked && task("own", root)?.status == .planned)
        #expect(reports(runtime).isEmpty, "\(reports(runtime))")

        // The workflow's switch turns all of it off.
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        #expect(LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md").autoAdvance == false)
        #expect(!lead.call("update_task", ["task": "held", "status": "planned"]).isError)
        advancing.settle()
        #expect(task("held", root)?.status == .planned)
        // And on again.
        #expect(!lead.call("configure", ["auto_advance": true]).isError)
        #expect(advancing.until { task("held", root)?.status == .running })
        #expect(task("own", root)?.status == .planned)
        // A worker turning it back on in the file isn't the lead's say.
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        let path = root + "/.vibeswitcher/workflow.md"
        let edited: String = try String(contentsOfFile: path, encoding: .utf8).replacingOccurrences(of: "auto_advance: false", with: "auto_advance: true")
        try edited.write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
        #expect(!lead.call("update_task", ["task": "own", "auto_advance": true]).isError)
        #expect(advancing.until { reports(runtime).contains { $0.contains("auto_advance isn't what you last set") } })
        #expect(task("own", root)?.status == .planned)
    }

    /// Waits for `path` to be there (60 s at most): what a fake test command touches when it starts.
    func appears(_ path: String) -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: path) {
            guard Date() < deadline else { return false }
            usleep(50_000)
        }
        return true
    }

    /// Tasks add-b and add-c reported done, add-b's merge held in its tests until `release` (the first test run waits
    /// for it, as a long suite would), and `meanwhile` done while it waits.
    func duringAMerge(_ meanwhile: (LeadToolset) -> Void) throws -> (root: String, runtime: FakeRuntime, advancing: Advancing) {
        let gate = temp.url("gate").path, started = temp.url("started").path, release = temp.url("release").path
        let test = "if mkdir '\(gate)' 2>/dev/null; then touch '\(started)'; while [ ! -e '\(release)' ]; do sleep 0.05; done; fi; echo ran >> '\(log)'"
        let (root, runtime, lead) = try team(test: test)
        let advancing = Advancing(lead)
        _ = lead.call("add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "Add c", "goal": "g", "acceptance": ["a"]])
        #expect(advancing.until { task("add-b", root)?.status == .running && task("add-c", root)?.status == .running })
        try work("add-b", file: "b.txt", root: root, runtime)
        #expect(appears(started))
        try work("add-c", file: "c.txt", root: root, runtime)
        meanwhile(lead)
        FileManager.default.createFile(atPath: release, contents: nil)
        #expect(advancing.until { task("add-b", root)?.status == .done })
        advancing.settle()
        return (root, runtime, advancing)
    }

    @Test func aTaskOptedOutDuringAnotherTasksMergeIsntMerged() throws {
        let (root, runtime, advancing) = try duringAMerge { lead in
            #expect(!lead.call("update_task", ["task": "add-c", "auto_advance": false]).isError)
        }
        defer { advancing.stop() }
        #expect(task("add-c", root)?.status == .review && task("add-c", root)?.merged == nil)
        #expect(!Git.run(["show", "main:c.txt"], in: root).ok)
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "ran\n")
        // The task it was merging when the hold came lands and is cleaned up as ever.
        #expect(advancing.until { task("add-b", root)?.worktree == nil })
        #expect(!reports(runtime).contains { $0.contains("add-c") && $0.contains("Merged") })
    }

    @Test func theSwitchTurnedOffDuringAMergeStopsWhatComesAfterIt() throws {
        let (root, _, advancing) = try duringAMerge { lead in
            #expect(!lead.call("configure", ["auto_advance": false]).isError)
        }
        defer { advancing.stop() }
        // The merge under way lands; nothing after it moves: no merge of add-c, no cleanup of add-b.
        #expect(task("add-c", root)?.status == .review && task("add-c", root)?.merged == nil)
        #expect(task("add-b", root)?.worktree != nil)
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "ran\n")
    }

    @Test func aTaskBlockedWhileTheMacsRoomIsCountedDoesntStart() throws {
        let (root, runtime, lead) = try team()
        _ = lead.call("add_task", ["title": "Waits", "goal": "g", "acceptance": ["a"]])
        // The lead blocks it the moment the loop counts the Mac's sessions for its start.
        let store = BoardStore(root: root)
        runtime.onSessions = {
            runtime.onSessions = nil
            try? store.update { board in
                guard let index = board.taskIndex("waits") else { return }
                board.tasks[index].status = .blocked
            }
        }
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        advancing.settle()
        #expect(task("waits", root)?.status == .blocked && task("waits", root)?.worker == nil)
        #expect(runtime.spawned.isEmpty)
        #expect(!reports(runtime).contains { $0.contains("waits") })
    }

    @Test func aLoopThatFoundItsLockHeldAMomentTakesItAtItsNextRun() throws {
        let (root, _, lead) = try team()
        let store = BoardStore(root: root)
        try store.prepare()
        // A worker's tool server looking whether a loop runs holds the lock for a moment, just as the loop starts.
        let probe = try #require(FileLock.attempt(LeadAdvance.runningLock(store)))
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        // Its first run ends while the probe still holds it.
        advancing.settle()
        probe.release()
        #expect(!LeadAdvance.running(store))
        // The next run takes it, and keeps it.
        advancing.settle()
        #expect(LeadAdvance.running(store))
    }

    @Test func afterTakesTheBoardsTasksAndRefusesLoops() throws {
        let (root, _, lead) = try team()
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        let two = lead.call("add_task", ["title": "Two", "goal": "g", "acceptance": ["a"], "after": ["one"]])
        #expect(!two.isError && two.text.contains("once one is done"), "\(two.text)")
        #expect(task("two", root)?.after == ["one"])
        #expect(lead.call("add_task", ["title": "Three", "goal": "g", "acceptance": ["a"], "after": ["nope"]]).isError)
        #expect(task("three", root) == nil)
        let loop = lead.call("update_task", ["task": "one", "after": ["two"]])
        #expect(loop.isError && loop.text.contains("already comes after one"), "\(loop.text)")
        #expect(lead.call("update_task", ["task": "one", "after": ["one"]]).isError)
        #expect(!lead.call("update_task", ["task": "two", "after": []]).isError)
        #expect(task("two", root)?.after == nil)
        #expect(lead.tools.first { $0.name == "update_task" }?.properties["after"] != nil)
        #expect(lead.call("configure", [:]).text.contains("- auto_advance: true"))
    }

    // MARK: starts

    @Test func plannedTasksStartInBoardOrderOnceTheirAfterTasksAreDoneWithinMaxWorkers() throws {
        let (root, runtime, lead) = try team(test: nil, ["max_workers": 1])
        _ = lead.call("add_task", ["title": "First", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "Second", "goal": "g", "acceptance": ["a"], "after": ["first"]])
        _ = lead.call("add_task", ["title": "Third", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "Fourth", "goal": "g", "acceptance": ["a"]])
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        let states = { ["first", "second", "third", "fourth"].map { task($0, root)?.status } }
        #expect(advancing.until { task("first", root)?.status == .running })
        #expect(states() == [.running, .planned, .planned, .planned])
        // first's done report frees its slot: third takes it (second waits for first's merge, fourth comes later on the board).
        try work("first", file: "b.txt", root: root, runtime)
        #expect(advancing.until { task("third", root)?.status == .running && task("first", root)?.status == .done })
        #expect(task("second", root)?.status == .planned && task("fourth", root)?.status == .planned)
        // first is done now: second goes before fourth.
        try work("third", file: "c.txt", root: root, runtime)
        #expect(advancing.until { task("second", root)?.status == .running })
        #expect(task("fourth", root)?.status == .planned)
        try work("second", file: "d.txt", root: root, runtime)
        #expect(advancing.until { task("fourth", root)?.status == .running })
        #expect(reports(runtime).contains { $0.contains("Started a worker on second") && $0.contains("its after tasks done (first)") })
    }

    @Test func aStartWaitsForTheMacsRoomAndGoesOnTheAppsNudge() throws {
        let (root, runtime, lead) = try team()
        lead.macLimits = { MacLimits(maxSessions: 1) }
        runtime.others = [LeadSessionInfo(id: "other", cwd: "/elsewhere/.vibeswitcher/worktrees/x", label: "Worker: other", live: true, status: "working", tty: nil)]
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Waits", "goal": "g", "acceptance": ["a"]])
        advancing.settle()
        #expect(task("waits", root)?.status == .planned)
        let waits = roomWaits.waits()
        #expect(waits.count == 1 && waits[0].wait.auto == true && waits[0].wait.what == "start_worker(waits)", "\(waits)")
        // More passes don't keep recording it.
        _ = lead.call("add_task", ["title": "Later", "goal": "g", "acceptance": ["a"], "after": ["waits"]])
        advancing.settle()
        #expect(roomWaits.waits().count == 1)

        // The other project's session ends; the app's room watch nudges this lead's server, and tells the lead nothing.
        runtime.calls.lock()
        runtime.others = []
        runtime.calls.unlock()
        let told = roomWaits.look(mac: MacLoad.count([], load: 0.5), limits: MacLimits(maxSessions: 1))
        #expect(told.isEmpty)
        #expect(advancing.until { task("waits", root)?.status == .running })
    }

    @Test func aBatteryHoldStopsStartsAndMergesUntilACPowerReturns() throws {
        let (root, _, lead) = try team()
        var low = PowerState(onBattery: true, percent: 20)
        low.heldUnder = 50
        let power = Locked<PowerState?>(low)
        lead.power = { power.get() }
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Waits", "goal": "g", "acceptance": ["a"]])
        advancing.settle()
        #expect(task("waits", root)?.status == .planned)
        power.set(PowerState(onBattery: false, percent: 60, charging: true))
        LeadAdvance.nudge(root: root)
        #expect(advancing.until { task("waits", root)?.status == .running })
    }

    // MARK: two at once, and restarts

    @Test func twoWorkersReportingAtOnceMergeOneAfterTheOtherNeverAtOnce() throws {
        // Each run takes a lock of its own: one already held means two ran at once.
        let held = temp.url("running").path
        let test = "mkdir '\(held)' || { echo overlap >> '\(log)'; exit 1; }; echo run >> '\(log)'; sleep 0.3; rmdir '\(held)'"
        let (root, runtime, lead) = try team(test: test, ["max_workers": 2])
        // Two loops, as two tool servers of the same lead would run them.
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        let second = restarted(root, runtime)
        let other = Advancing(second)
        defer { other.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "Add c", "goal": "g", "acceptance": ["a"]])
        #expect(advancing.until { task("add-b", root)?.status == .running && task("add-c", root)?.status == .running })
        try commit("b.txt", "bee\n", in: Worktrees.path(root: root, slug: "add-b"))
        try commit("c.txt", "sea\n", in: Worktrees.path(root: root, slug: "add-c"))
        let workers = [try seat("worker-add-b", runtime), try seat("worker-add-c", runtime)]
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            _ = workers[index].call("report", doneReport("added"))
        }
        #expect(advancing.until { task("add-b", root)?.status == .done && task("add-c", root)?.status == .done })
        let runs = try String(contentsOfFile: log, encoding: .utf8)
        #expect(runs == "run\nrun\n", "\(runs)")
        #expect(Git.run(["show", "main:b.txt"], in: root).ok && Git.run(["show", "main:c.txt"], in: root).ok)
    }

    @Test func aNewBuildsLoopTakesWhatsStillDueOnceAndNothingTwice() throws {
        let (root, runtime, lead) = try team()
        // The old build: it started the worker, then was gone before the report came.
        let old = Advancing(lead)
        _ = lead.call("add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"]])
        #expect(old.until { task("add-b", root)?.status == .running })
        // Its last run ends, and nothing starts another.
        old.stop()
        lead.advancing = nil
        try work("add-b", file: "b.txt", root: root, runtime)
        #expect(task("add-b", root)?.status == .review)

        // The new build's first pass merges it and cleans it up.
        let new = Advancing(restarted(root, runtime))
        #expect(new.until { task("add-b", root)?.status == .done && task("add-b", root)?.worktree == nil })
        new.stop()
        let reported = reports(runtime).count
        // And the one after it finds nothing left to do.
        let newer = Advancing(restarted(root, runtime))
        defer { newer.stop() }
        newer.settle()
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "ran one bee \n")
        #expect(reports(runtime).count == reported)
        #expect(progress(root).components(separatedBy: "Automatically (auto_advance): Merged add-b").count == 2)
    }

    @Test func anInstallsSwitchWaitsForAPassUnderWay() throws {
        let binary = temp.url("vibeswitcher-mcp").path
        try "build 1".write(toFile: binary, atomically: true, encoding: .utf8)
        let build = Locked(BinaryWatch.Identity(modified: 1, size: 1, inode: 1))
        let watch = BinaryWatch(path: binary, running: build.get(), identify: { _ in build.get() })
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: LeadAdvanceTests.NoTools(), watch: watch)
        let asked = DispatchSemaphore(value: 0)
        let switches = Locked(0)
        server.switchWhen = {
            switches.change { $0 += 1 }
            asked.signal()
            return false
        }
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        #expect(pipe(&input) == 0 && pipe(&output) == 0)
        let served = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            server.serve(input: input[0], output: output[1])
            served.signal()
        }
        defer {
            close(input[1])
            _ = served.wait(timeout: .now() + 20)
            for fd in [input[0], output[0], output[1]] { close(fd) }
        }
        // A pass under way, and a new build installed meanwhile.
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        #expect(server.background {
            started.signal()
            release.wait()
        })
        started.wait()
        build.set(BinaryWatch.Identity(modified: 2, size: 2, inode: 2))
        // The server reads and answers a request (it looks whether to switch first): no switch while the pass runs.
        let ping = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8) + Data([0x0A])
        _ = ping.withUnsafeBytes { write(input[1], $0.baseAddress, $0.count) }
        var reply = [UInt8](repeating: 0, count: 4096)
        var answer = [pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)]
        #expect(poll(&answer, 1, 30_000) == 1)
        #expect(read(output[0], &reply, reply.count) > 0)
        #expect(switches.get() == 0)
        // Once it ends, the switch is tried.
        release.signal()
        #expect(asked.wait(timeout: .now() + 30) == .success)
        #expect(switches.get() >= 1)
    }

    final class NoTools: MCPToolset {
        var tools: [MCPToolInfo] { [] }
        func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult { MCPToolResult(text: "none", isError: true) }
    }
}
