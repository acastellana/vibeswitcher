import Foundation
import Testing
@testable import VibeCore

/// The incident of 2026-11-21 09:08 (docs/lead-v2/incidents.md): an audit's finder stopped on a permission prompt to
/// Read the audit's own shared-run log (`<root>/.vibeswitcher/audit/<task>/<run>/test.log`, init.log the same), which
/// its brief names and which is outside its worktree; no one on the node answers a session's prompt, so the audit
/// never reached a verdict. A verifier's or finder's settings now let it read exactly that run's three files
/// (init.log, test.log, run.txt), and nothing else changes (`LeadLaunch.auditLogReads`).
///
/// The rules are held as Claude Code holds them (`VerifierEvidenceReadTests.Rules`: its check of a Read, not a run of
/// Claude Code): a deny rule on any spelling refuses; otherwise every spelling must match an allow rule.
struct AuditLogReadTests {
    typealias Rules = VerifierEvidenceReadTests.Rules
    let temp = Scratch()

    /// The settings of the last session `runtime` started as `name`, as Claude Code's Read check holds them.
    func rules(_ name: String, _ runtime: FakeRuntime, home: String) throws -> (rules: Rules, settings: [String: Any]) {
        let settings = try LaunchArguments.json("--settings", in: try LaunchArguments.command(name, runtime))
        let permissions = try #require(settings["permissions"] as? [String: Any])
        return (Rules(allow: permissions["allow"] as? [String] ?? [], deny: permissions["deny"] as? [String] ?? [], home: home), settings)
    }

    func real(_ path: String) -> String {
        guard let found = realpath(path, nil) else { return path }
        defer { free(found) }
        return String(cString: found)
    }

    func write(_ path: String, _ text: String = "x") throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// The incident, by a 2-finder audit through the tools: each finder's launch lets it read the one shared run's
    /// logs (the panel's, which its brief names) and run.txt without a prompt, by either spelling of the project.
    @Test func eachFinderOfATwoFinderAuditReadsTheSharedRunsLogsWithoutAPrompt() throws {
        let fixture = LeadAuditFindersTests()
        let runtime = FakeRuntime()
        let (root, lead) = try fixture.ready(runtime, finders: 2)
        let head = Git.run(["rev-parse", "agent/add-b"], in: root).output
        let started = lead.call("audit", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        let folder = root + "/.vibeswitcher/audit/add-b/\(head.prefix(12))"
        let panel = try #require(BoardStore(root: root).load().task("add-b")?.panel)
        #expect(panel.logs == [folder + "/test.log"], "\(panel.logs)")
        #expect(FileManager.default.fileExists(atPath: folder + "/run.txt"))
        let home = temp.url("home").path
        for name in ["verify-add-b", "finder2-add-b"] {
            let rules = try rules(name, runtime, home: home).rules
            for spelled in Set([folder, real(folder)]) {
                for file in panel.logs.map({ ($0 as NSString).lastPathComponent }) + ["run.txt"] {
                    #expect(rules.reads(spelled + "/" + file), "\(name) would be asked to Read \(spelled)/\(file)")
                }
            }
        }
    }

    /// The grant is narrow: the same finders' launches allow nothing else outside the worktree (another run of the task,
    /// another task's audit folder, the rest of `.vibeswitcher`, the lead's private files, a log that's a link out), no
    /// Edit or Write of the audit folder, and their deny rules still refuse every edit; the worker's launch is as it was.
    @Test func theGrantIsThatRunsThreeFilesReadOnlyAndAWorkerGetsNothing() throws {
        let fixture = LeadAuditFindersTests()
        let runtime = FakeRuntime()
        let (root, lead) = try fixture.ready(runtime, finders: 2)
        let head = Git.run(["rev-parse", "agent/add-b"], in: root).output
        let audit = root + "/.vibeswitcher/audit"
        let home = temp.url("home").path
        // Another run of this task, another task's run, and the lead's private files, there before the audit.
        try write(audit + "/add-b/000000000000/test.log")
        try write(audit + "/other-task/\(head.prefix(12))/test.log")
        try write(home + "/.vibeswitcher/lead/seal.json", "{}")
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let folder = audit + "/add-b/\(head.prefix(12))"
        let expected = Set([folder, real(folder)]).sorted().flatMap { spelled in LeadLaunch.auditLogFiles.map { "Read(/\(spelled)/\($0))" } }
        for name in ["verify-add-b", "finder2-add-b"] {
            let (rules, _) = try rules(name, runtime, home: home)
            // Exactly the verifier's own rules, its task's evidence (none kept), and the run's three files.
            #expect(rules.allow == LeadLaunch.allow(.verifier) + LeadLaunch.evidenceReads(.verifier, root: root, task: "add-b") + expected, "\(rules.allow)")
            #expect(!rules.allow.contains { $0.hasPrefix("Edit(") || $0.hasPrefix("Write(") || $0.hasPrefix("NotebookEdit") }, "\(rules.allow)")
            for tool in LeadLaunch.readOnly { #expect(rules.deny.contains(tool), "\(name) may \(tool)") }
            #expect(Set(LeadLaunch.deny(.verifier)).isSubset(of: Set(rules.deny)))
            let refused = [
                audit + "/add-b/000000000000/test.log", audit + "/other-task/\(head.prefix(12))/test.log", folder, folder + "/other.log",
                folder + "/../000000000000/test.log", audit + "/add-b", root + "/.vibeswitcher/board.json", root + "/.vibeswitcher/workflow.md",
                home + "/.vibeswitcher/lead/seal.json", root + "/a.txt", "/etc/hosts",
            ]
            for path in refused { #expect(!rules.reads(path), "\(name) reads \(path)") }
        }
        // A log replaced by a link out of the folder lands elsewhere: that spelling matches no rule, so it prompts.
        let (finder, _) = try rules("finder2-add-b", runtime, home: home)
        try FileManager.default.removeItem(atPath: folder + "/test.log")
        try FileManager.default.createSymbolicLink(atPath: folder + "/test.log", withDestinationPath: home + "/.vibeswitcher/lead/seal.json")
        #expect(!finder.reads(folder + "/test.log"))
        // The worker's launch: its own rules only, nothing of the audit's.
        let (worker, settings) = try rules("worker-add-b", runtime, home: home)
        #expect(worker.allow == LeadLaunch.allow(.worker, base: "main"), "\(worker.allow)")
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self).contains("/.vibeswitcher/audit"))
        #expect(!worker.reads(folder + "/run.txt"))
    }

    /// A single verifier of a branch behind its base is handed its merged result's run, and reads those logs as a finder
    /// does; one with no shared run (its own tests) gets no rule.
    @Test func aVerifierOfAMergedResultReadsItsRunsLogsAndAPlainOneGetsNoRule() throws {
        let stale = StaleBranchTests()
        let root = try stale.repo()
        try stale.commit("a.txt", "one\ntwo\nthree\nfour\nfive\n", in: root, "a has lines")
        let runtime = FakeRuntime()
        let lead = try stale.lead(root, runtime)
        #expect(!lead.call("configure", ["test_command": "git rev-parse HEAD"]).isError)
        try stale.behindInACleanFile(lead, runtime, root: root)
        let merge = try Worktrees.mergedCommit(root: root, base: "main", commit: "agent/add-b").get()
        let audit = lead.call("audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        let folder = root + "/.vibeswitcher/audit/add-b/\(merge.prefix(12))"
        let (rules, _) = try rules("verify-add-b", runtime, home: temp.url("home").path)
        for file in ["test.log", "run.txt"] { #expect(rules.reads(folder + "/" + file), "\(folder)/\(file)") }
        #expect(rules.allow.filter { $0.contains("/.vibeswitcher/audit/") }.count == LeadLaunch.auditLogFiles.count * Set([folder, real(folder)]).count)

        // Up to date: no merged result, no shared run, no rule.
        let plain = LeadAuditFindersTests()
        let plainRuntime = FakeRuntime()
        let (plainRoot, plainLead) = try plain.ready(plainRuntime, finders: 1)
        #expect(!plainLead.call("audit", ["task": "add-b"]).isError)
        let (own, _) = try self.rules("verify-add-b", plainRuntime, home: temp.url("home").path)
        #expect(own.allow == LeadLaunch.allow(.verifier) + LeadLaunch.evidenceReads(.verifier, root: plainRoot, task: "add-b"), "\(own.allow)")
        #expect(!own.allow.contains { $0.contains("/.vibeswitcher/audit/") })
    }

    /// No rule for logs that aren't one run's folder of this task in this project, for another role, or through a link.
    @Test func noRuleForLogsOutsideTheTasksRunFolder() throws {
        let base = temp.url("unit").path
        let root = base + "/repo"
        let folder = root + "/.vibeswitcher/audit/t/abc123"
        try write(folder + "/test.log")
        try write(root + "/.vibeswitcher/audit/other/abc123/test.log")
        try write(base + "/elsewhere/test.log")
        let mine = LeadLaunch.auditLogReads(.verifier, root: root, task: "t", logs: [folder + "/init.log", folder + "/test.log"])
        let spelled = Set([folder, real(folder)]).sorted()
        #expect(mine == spelled.flatMap { f in ["init.log", "test.log", "run.txt"].map { "Read(/\(f)/\($0))" } })
        for role in [LeadLaunch.Role.worker, .lead] {
            #expect(LeadLaunch.auditLogReads(role, root: root, task: "t", logs: [folder + "/test.log"]).isEmpty)
        }
        let none: [(String?, [String])] = [
            (nil, [folder + "/test.log"]), ("t", []), ("other", [folder + "/test.log"]),
            ("t", [root + "/.vibeswitcher/audit/other/abc123/test.log"]), ("t", [base + "/elsewhere/test.log"]),
            ("t", [folder + "/test.log", root + "/.vibeswitcher/audit/t/def456/test.log"]), ("t", [root + "/.vibeswitcher/audit/t/test.log"]),
            ("t", [folder + "/sub/test.log"]), ("t", [root + "/.vibeswitcher/audit/t/a*b/test.log"]), ("t*", [root + "/.vibeswitcher/audit/t*/abc123/test.log"]),
            ("..", [root + "/.vibeswitcher/audit/../abc123/test.log"]), ("t", [root + "/.vibeswitcher/audit/t/nothere/test.log"]),
        ]
        for (task, logs) in none {
            #expect(LeadLaunch.auditLogReads(.verifier, root: root, task: task, logs: logs).isEmpty, "\(task ?? "nil"): \(logs)")
        }
        #expect(LeadLaunch.auditLogReads(.verifier, root: "repo", task: "t", logs: ["repo/.vibeswitcher/audit/t/abc123/test.log"]).isEmpty)
        // A run folder that's a link (to another task's run) isn't where it says it is.
        try FileManager.default.createSymbolicLink(atPath: root + "/.vibeswitcher/audit/t/linked", withDestinationPath: root + "/.vibeswitcher/audit/other/abc123")
        #expect(LeadLaunch.auditLogReads(.verifier, root: root, task: "t", logs: [root + "/.vibeswitcher/audit/t/linked/test.log"]).isEmpty)
    }
}
