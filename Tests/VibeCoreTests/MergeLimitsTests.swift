import Foundation
import Testing
@testable import VibeCore

/// A runtime whose calls come from several threads at once, and whose spawn takes a while (as starting a session
/// does), so calls overlap.
final class ConcurrentRuntime: LeadRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [(id: String, cwd: String, label: String)] = []
    let me = LeadAgent(pid: 4343, tty: "ttys041", session: "lead-session")
    let server = "/App/vibeswitcher-mcp"

    var spawned: Int { lock.withLock { started.count } }

    func claudeCommand(root: String) -> String { "claude --dangerously-skip-permissions" }
    func spawn(cwd: String, command: String, env: [String: String], label: String, agent: String) throws -> String {
        usleep(200_000)
        return lock.withLock {
            let id = "session-\(started.count + 1)"
            started.append((id, cwd, label))
            return id
        }
    }
    func answerTrust(session: String, folder: String) {}
    func kill(_ session: String) {}
    func forget(_ session: String) {}
    func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String, clearDraft: Bool) throws -> LeadDelivery.Delivered { .steered }
    func sessions() throws -> [LeadSessionInfo] {
        lock.withLock { started.map { LeadSessionInfo(id: $0.id, cwd: $0.cwd, label: $0.label, live: true, status: "working", tty: nil) } }
    }
    func transcript(of session: String) throws -> String? { nil }
    func currentAgent() -> LeadAgent? { me }
    func isRunning(_ agent: LeadAgent) -> Bool { true }
    func loadAverages() -> MacLoad.Averages? { MacLoad.Averages(one: 0.5, five: 0.5) }
}

extension LeadToolsetTests {
    func workflow(_ root: String, _ lines: String) throws {
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try "---\n\(lines)\n---\n".write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
    }

    /// A folder for what a test command leaves to look at (the pid of the child it started).
    func marks() throws -> String {
        let path = temp.url("marks").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func pid(in file: String) -> Int32? {
        (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Both merge locks are free, and git lists no worktree but the repository's and the task's.
    func mergeLeftNothingBehind(_ root: String, slug: String = "add-b") {
        let task = FileLock.attempt(root + "/.vibeswitcher/run/merge-\(slug).lock")
        #expect(task != nil)
        task?.release()
        let base = FileLock.attempt(vault.scratch(root: root, "merge-into-\(LeadVault.hash("main").prefix(16)).lock").path)
        #expect(base != nil)
        base?.release()
        #expect(!FileManager.default.fileExists(atPath: vault.scratch(root: root, "merge-\(slug)").path))
        let listed = Git.run(["worktree", "list", "--porcelain"], in: root).output.components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }
        #expect(listed.count == 2, "\(listed)")
    }

    /// E-17: a test command that never exits is stopped at test_timeout_min with what it started; the merge says
    /// the tests hung, records no failure, and leaves no lock or scratch worktree behind.
    @Test func aMergeWhoseTestsHangIsStoppedAndSaysSo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        let marks = try marks()
        // 0.05 min: 3 s.
        // As the lead sets them: merge runs only the commands it set.
        let set = call(lead, "configure", ["test_timeout_min": "0.05", "test_command": "sleep \(ShellTests.childRuns) & echo $! > \(marks)/child; wait"])
        #expect(!set.isError, "\(set.text)")
        let main = Git.run(["rev-parse", "main"], in: root).output
        let started = Date()
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(Date().timeIntervalSince(started) < hangGuard)
        #expect(merged.isError)
        #expect(merged.text.contains("tests hung after 3 s") && merged.text.contains("test_timeout_min"), "\(merged.text)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .review && task.setback == nil)
        #expect(Git.run(["rev-parse", "main"], in: root).output == main)
        mergeLeftNothingBehind(root)
        if let child = pid(in: marks + "/child") { #expect(eventually { kill(child, 0) != 0 }) }
        // With the limit raised and tests that end, the same audit merges.
        #expect(!call(lead, "configure", ["test_timeout_min": "", "test_command": "test -f b.txt"]).isError)
        let again = call(lead, "merge", ["task": "add-b"])
        #expect(!again.isError, "\(again.text)")
    }

    /// E-12: a merge cancelled through MCP (notifications/cancelled) stops its tests, removes its scratch worktree,
    /// says cancelled, and doesn't fail the task.
    @Test func aCancelledMergeIsCancelledNotFailed() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        let marks = try marks()
        #expect(!call(lead, "configure", ["test_command": "sleep \(ShellTests.childRuns) & echo $! > \(marks)/child; wait"]).isError)
        let server = MCPServer(name: "vibeswitcher", version: "test", toolset: lead)
        let replies = Locked<[[String: Any]]>([])
        let send = { (message: [String: Any]) in
            server.receive(try! JSONSerialization.data(withJSONObject: message)) { reply in
                let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] ?? [:]
                replies.change { $0.append(object) }
            }
        }
        send(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "merge", "arguments": ["task": "add-b"]]])
        #expect(eventually { pid(in: marks + "/child") != nil })
        send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]])
        #expect(eventually { !replies.get().isEmpty })
        let result = try #require(replies.get().first?["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("cancelled") && !text.contains("fails"), "\(text)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .review && task.setback == nil)
        mergeLeftNothingBehind(root)
        let child = try #require(pid(in: marks + "/child"))
        #expect(eventually { kill(child, 0) != 0 })
    }

    /// E-15: a merge stopped by something else than a conflict says what stopped it, and doesn't send the worker to
    /// merge the base in.
    @Test func aMergeStoppedByAHookSaysSoNotConflict() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        try "c\n".write(toFile: root + "/c.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "c.txt"], in: root)
        Git.run(["commit", "-q", "-m", "c"], in: root)
        let hooks = Git.run(["rev-parse", "--path-format=absolute", "--git-path", "hooks"], in: root).output
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'pre-rebase hook says no' >&2\nexit 1\n".write(toFile: hooks + "/pre-rebase", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks + "/pre-rebase")
        // Through merge only: the lead's base moved by hand here, as merge would have moved it.
        try vault.setHead(Git.run(["rev-parse", "main"], in: root).output, root: root, branch: "main")
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("pre-rebase hook says no") && !merged.text.contains("conflicts with"), "\(merged.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
        mergeLeftNothingBehind(root)
    }

    /// E-18: start_worker calls at once with max_workers 2 start exactly 2 workers.
    @Test func startWorkerCallsAtOnceStayWithinMaxWorkers() throws {
        let root = try repo()
        try workflow(root, "max_workers: 2")
        let runtime = ConcurrentRuntime()
        let grant = try vault.startLead(root: root, branch: "main")
        try vault.bind(grant, root: root, session: "lead-session")
        let lead = LeadToolset(root: root, runtime: runtime, vault: vault(for: runtime))
        let slugs = ["one", "two", "three", "four", "five"]
        for title in slugs { _ = call(lead, "add_task", ["title": title.capitalized, "goal": "g", "acceptance": ["a"]]) }
        let results = Locked<[MCPToolResult]>([])
        DispatchQueue.concurrentPerform(iterations: slugs.count) { index in
            let result = lead.call("start_worker", ["task": slugs[index]])
            results.change { $0.append(result) }
        }
        let started = results.get().filter { !$0.isError }
        let refused = results.get().filter(\.isError)
        #expect(started.count == 2, "\(results.get().map(\.text))")
        #expect(refused.count == 3 && refused.allSatisfy { $0.text.contains("max_workers is 2") }, "\(refused.map(\.text))")
        #expect(runtime.spawned == 2)
        #expect(BoardStore(root: root).load().tasks.filter { $0.status == .running }.count == 2)
    }

    @Test func configureSetsTheTestTimeLimit() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(call(lead, "configure").text.contains("test_timeout_min: 45"))
        let set = call(lead, "configure", ["test_timeout_min": 90])
        #expect(!set.isError, "\(set.text)")
        #expect(LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md").testTimeout == 90 * 60)
        #expect(call(lead, "configure", ["test_timeout_min": "0"]).isError)
        #expect(call(lead, "configure", ["test_timeout_min": "soon"]).isError)
        // Cleared, it's the default again.
        #expect(!call(lead, "configure", ["test_timeout_min": ""]).isError)
        #expect(LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md").testTimeoutMinutes == 45)
        #expect(LeadWorkflow.parse("---\ntest_timeout_min: 2.5\n---").testTimeout == 150)
        #expect(LeadWorkflow.parse("---\ntest_timeout_min: -3\n---").testTimeoutMinutes == 45)
    }
}
