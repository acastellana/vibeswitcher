import Foundation
import Testing
@testable import VibeCore

private func workflowFile(_ root: String) -> String { root + "/.vibeswitcher/workflow.md" }

/// What a worker's Bash does to the project's workflow.md: one setting's line rewritten, the rest kept.
private func workerWrites(_ key: String, _ value: String, root: String) throws {
    let path = workflowFile(root)
    let current = FileManager.default.contents(atPath: path) ?? Data()
    try LeadWorkflow.updating(current, with: [(key, value)]).write(to: URL(fileURLWithPath: path))
}

/// workflow.md's guard rails (`LeadVault.guardedKeys`): its test_command and init_command run as the lead in merge,
/// and its merge policy and limits hold the team. A worker that writes the file (the project's copy, or its
/// worktree's committed and merged) doesn't get its commands run or its settings taken: only what the lead set with
/// configure counts; merge and start_worker refuse anything else, naming it.
extension LeadGuardRailsTests {

    @Test func aTestCommandAWorkerWroteIsntRunByMerge() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["test_command": "test -f b.txt"]).isError)
        _ = try reported(lead, runtime, root: root)
        try passingAudit(lead, runtime)
        let main = head("main", root)
        // From the worker's session: its own command in place of the lead's.
        let ran = temp.url("ran-as-lead").path
        try workerWrites("test_command", "touch \(ran); true", root: root)
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("test_command is now `touch \(ran); true`") && merged.text.contains("configure"), "\(merged.text)")
        #expect(!FileManager.default.fileExists(atPath: ran))
        #expect(head("main", root) == main)
        // Nor by setting something else: configure takes only the settings it's given as the lead's.
        #expect(!lead.call("configure", ["max_workers": "2"]).isError)
        #expect(lead.call("merge", ["task": "add-b"]).isError)
        #expect(!FileManager.default.fileExists(atPath: ran))
        // The lead sets it back: the audited work merges, tested with the lead's command.
        #expect(!lead.call("configure", ["test_command": "test -f b.txt"]).isError)
        let again = lead.call("merge", ["task": "add-b"])
        #expect(!again.isError, "\(again.text)")
        #expect(!FileManager.default.fileExists(atPath: ran))
    }

    @Test func anInitCommandAWorkerWroteStopsStartWorkerAndMerge() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["init_command": "true"]).isError)
        _ = try reported(lead, runtime, root: root)
        try passingAudit(lead, runtime)
        let ran = temp.url("init-as-lead").path
        try workerWrites("init_command", "touch \(ran)", root: root)
        _ = lead.call("add_task", ["title": "Add c", "goal": "c.txt exists", "acceptance": ["test -f c.txt"]])
        let started = lead.call("start_worker", ["task": "add-c"])
        #expect(started.isError)
        #expect(started.text.hasPrefix("Not started") && started.text.contains("init_command is now `touch \(ran)`"), "\(started.text)")
        #expect(!runtime.spawned.contains { $0.command.contains("--name 'worker-add-c'") })
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError && merged.text.contains("init_command is now"), "\(merged.text)")
        #expect(!FileManager.default.fileExists(atPath: ran))
        // Cleared by the worker: still not what the lead set.
        try workerWrites("init_command", "", root: root)
        #expect(lead.call("merge", ["task": "add-b"]).text.contains("init_command is now empty"))
    }

    /// A lead that never set them: the commands as they were when it first started a worker are the ones merge runs.
    @Test func withNothingSetTheCommandsAtTheFirstStartAreTheLeads() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try reported(lead, runtime, root: root)
        try passingAudit(lead, runtime)
        #expect(try vault.guardedSettings(root: root) == LeadVault.guardedHashes(LeadWorkflow.load(from: workflowFile(root))))
        let ran = temp.url("ran-as-lead").path
        try workerWrites("test_command", "touch \(ran)", root: root)
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError && merged.text.contains("test_command is now `touch \(ran)`"), "\(merged.text)")
        #expect(!FileManager.default.fileExists(atPath: ran))
        // Gone again: what the lead had (none) merges untested, as before.
        try workerWrites("test_command", "", root: root)
        let again = lead.call("merge", ["task": "add-b"])
        #expect(!again.isError, "\(again.text)")
    }

    /// The worktree's copy: committed by the worker (past the exclude) and merged, it becomes the project's file; the
    /// next merge doesn't run its commands.
    @Test func aWorkflowCommittedOnTheBranchDoesntBecomeTheLeads() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["test_command": "true"]).isError)
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        _ = lead.call("start_worker", ["task": "add-b"])
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("b.txt", "bee\n", in: worktree)
        let ran = temp.url("ran-as-lead").path
        try FileManager.default.createDirectory(atPath: worktree + "/.vibeswitcher", withIntermediateDirectories: true)
        try "---\ntest_command: touch \(ran); true\n---\n".write(toFile: workflowFile(worktree), atomically: true, encoding: .utf8)
        Git.run(["add", "-f", ".vibeswitcher/workflow.md"], in: worktree)
        Git.run(["commit", "-q", "-m", "workflow"], in: worktree)
        _ = try seat("worker-add-b", runtime).call("report", doneReport("added"))
        try passingAudit(lead, runtime)
        // The verifier missed it: the branch merges, tested with the lead's command, and its file lands.
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(!FileManager.default.fileExists(atPath: ran))
        #expect(LeadWorkflow.load(from: workflowFile(root)).testCommand == "touch \(ran); true")
        // The next merge (or worker) doesn't take it.
        _ = lead.call("add_task", ["title": "Add c", "goal": "c.txt exists", "acceptance": ["test -f c.txt"]])
        let started = lead.call("start_worker", ["task": "add-c"])
        #expect(started.isError && started.text.contains("test_command is now `touch \(ran); true`"), "\(started.text)")
        #expect(!FileManager.default.fileExists(atPath: ran))
    }

    /// They cross the host's socket as JSON.
    @Test func theCommandMessagesReadBackAsSent() throws {
        let requests: [LeadVault.Request] = [.guarded(root: "/r"), .setGuarded(root: "/r", hashes: ["test_command": "ab"])]
        for request in requests {
            #expect(try JSONDecoder().decode(LeadVault.Request.self, from: JSONEncoder().encode(request)) == request)
        }
        for reply in [LeadVault.Reply.guarded(nil), .guarded(["init_command": "cd"])] {
            #expect(try JSONDecoder().decode(LeadVault.Reply.self, from: JSONEncoder().encode(reply)) == reply)
        }
    }

    @Test func onlyTheAppOrTheLeadRecordsTheGuardRails() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["test_command": "true"]).isError)
        _ = try reported(lead, runtime, root: root)
        _ = lead.call("audit", ["task": "add-b"])
        let forged = ["test_command": LeadVault.hash("touch /tmp/x")]
        let recorded = try vault.guardedSettings(root: root)
        for session in [try launched("worker-add-b", runtime).session, try launched("verify-add-b", runtime).session] {
            let seat = FakeSeat(runtime, agent: LeadAgent(pid: 7100, tty: "ttys071", session: session))
            #expect(throws: LeadVault.Refused.self) { try self.vault(for: seat).setGuardedSettings(forged, root: root) }
        }
        let outside = NoAgent(runtime)
        #expect(throws: LeadVault.Refused.self) { try self.vault(for: outside).setGuardedSettings(forged, root: root) }
        #expect(try vault.guardedSettings(root: root) == recorded)
        // The worker's own tool server can't configure: it has no such tool.
        #expect(try seat("worker-add-b", runtime).call("configure", ["test_command": "touch /tmp/x"]).isError)
        #expect(LeadWorkflow.load(from: workflowFile(root)).testCommand == "true")
    }
}

extension LeadGuardRailsTests {
    /// The limits that hold how many of itself a worker's lead starts: a worker raising one doesn't get more started.
    @Test func aLimitAWorkerLoosenedStopsStartWorker() throws {
        // The records' folder too: pointed elsewhere in the repository, or outside it (which keeps them local).
        for (key, loose, leads) in [("max_workers", "10", "3"), ("heavy_slots", "50", ""),
                                    ("records_dir", "notes", "docs/lead"), ("records_dir", "/tmp/elsewhere", "docs/lead")] {
            let root = try repo()
            let runtime = FakeRuntime()
            let lead = try lead(root, runtime)
            for title in ["One", "Two"] { _ = lead.call("add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
            #expect(!lead.call("start_worker", ["task": "one"]).isError)
            try workerWrites(key, loose, root: root)
            let refused = lead.call("start_worker", ["task": "two"])
            #expect(refused.isError && refused.text.hasPrefix("Not started") && refused.text.contains("\(key) is now `\(loose)`"), "\(key): \(refused.text)")
            #expect(!runtime.spawned.contains { $0.command.contains("--name 'worker-two'") })
            // As the lead had it again: the worker starts.
            #expect(!lead.call("configure", [key: leads]).isError)
            let started = lead.call("start_worker", ["task": "two"])
            #expect(!started.isError, "\(key): \(started.text)")
        }
    }
}

/// The merge policy and what it holds back are the owner's choice, set by the lead: a worker that rewrites them in
/// workflow.md doesn't get its commit past the user.
extension LeadMergePolicyTests {
    @Test func aWorkerLooseningTheMergePolicyIsRefusedAtMerge() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "ask_all"]).isError)
        try audited(lead, runtime, root: root, file: "b.txt")
        let main = Git.run(["rev-parse", "main"], in: root).output
        try workerWrites("merge_policy", "auto", root: root)
        let refused = lead.call("merge", ["task": "change"])
        #expect(refused.isError)
        #expect(refused.text.contains("merge_policy is now `auto`") && refused.text.contains("configure"), "\(refused.text)")
        #expect(Git.run(["rev-parse", "main"], in: root).output == main)
        #expect(BoardStore(root: root).load().task("change")?.status != .done)
        // Set back: the lead's ask_all holds it for the user, as before.
        try workerWrites("merge_policy", "ask_all", root: root)
        let held = lead.call("merge", ["task": "change"])
        #expect(held.isError && held.text.contains("the merge policy is ask_all"), "\(held.text)")
        #expect(Git.run(["rev-parse", "main"], in: root).output == main)
    }

    @Test func aWorkerNarrowingTheSensitivePathsIsRefusedAtMerge() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "ask_sensitive", "sensitive_paths": ".github/"]).isError)
        try audited(lead, runtime, root: root, file: ".github/workflows/ci.yml")
        let main = Git.run(["rev-parse", "main"], in: root).output
        // Nothing it touches is sensitive any more, as the worker would have it; or nothing is listed at all.
        for narrowed in ["docs/", ""] {
            try workerWrites("sensitive_paths", narrowed, root: root)
            let refused = lead.call("merge", ["task": "change"])
            #expect(refused.isError)
            #expect(refused.text.contains(narrowed.isEmpty ? "sensitive_paths is now empty" : "sensitive_paths is now `docs/`"), "\(refused.text)")
            #expect(Git.run(["rev-parse", "main"], in: root).output == main)
        }
        // The lead sets it as it should read: the commit waits for the user's approval of it.
        #expect(!lead.call("configure", ["sensitive_paths": ".github/"]).isError)
        let held = lead.call("merge", ["task": "change"])
        #expect(held.isError && held.text.contains(".github/workflows/ci.yml"), "\(held.text)")
        #expect(Git.run(["rev-parse", "main"], in: root).output == main)
    }
}

extension LeadGuardRailsTests {
    /// A guard rail is compared as the team reads it: a line left out and the same default written out are one value,
    /// and so are two spellings of one folder; an empty records_dir (local) or another folder is a change.
    @Test func anOmittedSettingAndItsExplicitDefaultAreTheSame() {
        let hashes = { (front: String) in LeadVault.guardedHashes(LeadWorkflow.parse("---\n\(front)\n---\n")) }
        let omitted = hashes("")
        #expect(hashes("records_dir: docs/lead\nmax_workers: 3\nmac_max_sessions: 6\nload_threshold:") == omitted)
        // The Mac-wide limits aren't workflow.md's (see `MacLimits`): a worker writing them there changes nothing.
        #expect(hashes("mac_max_sessions: 50\nload_threshold: 999") == omitted)
        #expect(hashes("records_dir: ./docs/lead/") == omitted)
        #expect(LeadVault.guardedHashes(LeadWorkflow.parse(LeadWorkflow.template)) == omitted)
        #expect(hashes("merge_policy: ask-all") == hashes("merge_policy: ask_all"))
        for changed in ["records_dir:", "records_dir: notes", "max_workers: 4", "heavy_slots: 2", "merge_policy: auto"] {
            #expect(hashes(changed) != omitted, "\(changed)")
        }
        // Empty and a folder outside the repository both keep the records local: the same value.
        #expect(hashes("records_dir:") == hashes("records_dir: /tmp/elsewhere"))
    }

    @Test func aRewrittenFileWithTheSameSettingsStillStarts() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["records_dir": "docs/lead", "max_workers": "3"]).isError)
        for title in ["One", "Two", "Three"] { _ = lead.call("add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        #expect(!lead.call("start_worker", ["task": "one"]).isError)
        // The file rewritten without those lines (their defaults): nothing changed, the worker starts.
        try "---\ntest_timeout_min: 30\n---\n".write(toFile: workflowFile(root), atomically: true, encoding: .utf8)
        let started = lead.call("start_worker", ["task": "two"])
        #expect(!started.isError, "\(started.text)")
        // The lead keeps the records local; a worker's file that leaves the line out puts them back in docs/lead.
        #expect(!lead.call("configure", ["records_dir": ""]).isError)
        try "---\ntest_timeout_min: 30\n---\n".write(toFile: workflowFile(root), atomically: true, encoding: .utf8)
        let refused = lead.call("start_worker", ["task": "three"])
        #expect(refused.isError && refused.text.contains("records_dir is now `docs/lead`"), "\(refused.text)")
    }
}
