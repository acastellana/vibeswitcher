import Darwin
import Foundation
import Testing
@testable import VibeCore

/// The Mac-wide test and build slots as the lead meets them (2026-10-22 03:3x): a 38-minute TGE pytest held the only
/// slot, two builds, another pytest and a merge queued behind it, and the merge's tool call was ended by Claude Code
/// after 1800 s with no progress. Now merge and an audit take one of heavy_slots, say who holds them every 30 s while
/// they wait (MCP progress), refuse past test_timeout_min naming them, and status names a slot held over 30 min.
extension LeadToolsetTests {
    /// What a call's `ToolProgress` was told, with when.
    final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(at: Date, text: String)] = []
        func add(_ text: String) { lock.withLock { all.append((Date(), text)) } }
        var texts: [String] { lock.withLock { all.map(\.text) } }
        var times: [Date] { lock.withLock { all.map(\.at) } }
    }

    /// `heavy_slots` other runs holding every slot of the fixture's test lock, each with a note naming it: the
    /// processes, to end after.
    func fillSlots(_ count: Int, notes: [String], ago: TimeInterval = 0) throws -> [Process] {
        let lock = testLock.with(slots: count)
        return try (1...count).map { slot in
            let holder = try TestLockTests.outsideHolder(path: lock.slotPath(slot))
            let note = lock.slotPath(slot) + ".holder"
            try "pid \(holder.processIdentifier), \(notes[slot - 1]), since 02:53:22\n".write(toFile: note, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: note)
            return holder
        }
    }

    func end(_ processes: [Process]) {
        for process in processes {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    @Test func aMergeWaitingOnFullSlotsSaysWhoHoldsThemAndRefusesPastTheTimeout() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        // 0.02 min: the wait is bounded at 1.2 s.
        #expect(!call(lead, "configure", ["heavy_slots": "2", "test_command": "test -f b.txt", "test_timeout_min": "0.02"]).isError)
        let holders = try fillSlots(2, notes: [".venv/bin/python -m pytest -q in /Users/a/dev/TGE-ANALYSIS/.vibeswitcher/worktrees/redesign",
                                               "vs-heavy swift build in /Users/a/dev/vibeswitcher/.vibeswitcher/worktrees/w"])
        defer { end(holders) }
        let told = Told()
        let before = Git.run(["rev-parse", "main"], in: root).output
        let refused = ToolProgress.with(ToolProgress(every: 0.2, told.add)) { call(lead, "merge", ["task": "add-b"]) }
        #expect(refused.isError)
        #expect(refused.text.contains("Every slot of the Mac-wide test and build lock") && refused.text.contains("Nothing was tested"), "\(refused.text)")
        #expect(refused.text.contains("pytest -q in /Users/a/dev/TGE-ANALYSIS/.vibeswitcher/worktrees/redesign (TGE-ANALYSIS)"), "\(refused.text)")
        #expect(refused.text.contains("vs-heavy swift build in /Users/a/dev/vibeswitcher/.vibeswitcher/worktrees/w (vibeswitcher)"), "\(refused.text)")
        #expect(Git.run(["rev-parse", "main"], in: root).output == before)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
        // Progress at once and then every `every` (30 s for a client), each naming both holders: never silent.
        let waits = told.texts.filter { $0.hasPrefix("Waiting ") && $0.contains("for a slot of the Mac-wide test and build lock (all 2 slots held)") }
        #expect(waits.count >= 3, "\(told.texts)")
        #expect(waits.allSatisfy { $0.contains("(TGE-ANALYSIS)") && $0.contains("(vibeswitcher)") }, "\(waits)")
        let times = told.times
        let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
        #expect(gaps.allSatisfy { $0 < 1 }, "\(gaps)")
        // A slot frees: the merge goes on, and says it waited and for whom.
        end([holders[1]])
        let merged = ToolProgress.with(ToolProgress(every: 0.2, told.add)) { call(lead, "merge", ["task": "add-b"]) }
        #expect(!merged.isError, "\(merged.text)")
        #expect(FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    @Test func theMergesTestRunSaysHowItGoesWhileItRuns() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        #expect(!call(lead, "configure", ["test_command": "sleep 1; test -f b.txt"]).isError)
        let told = Told()
        let merged = ToolProgress.with(ToolProgress(every: 0.2, told.add)) { call(lead, "merge", ["task": "add-b"]) }
        #expect(!merged.isError, "\(merged.text)")
        #expect(told.texts.contains { $0.hasPrefix("Running the test command (") }, "\(told.texts)")
        // Done: it says nothing more.
        let after = told.texts.count
        Thread.sleep(forTimeInterval: 0.6)
        #expect(told.texts.count == after)
    }

    @Test func theLoadWaitSaysHowItGoesToo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        #expect(!call(lead, "configure", ["load_threshold": "24"]).isError)
        lead.loadPoll = 0.01
        runtime.loadReadings = [150, 120, 3]
        let told = Told()
        let merged = ToolProgress.with(ToolProgress(every: 0.01, told.add)) { call(lead, "merge", ["task": "add-b"]) }
        #expect(!merged.isError, "\(merged.text)")
        #expect(told.texts.first?.contains("for the Mac's 1-minute load (150) to drop below load_threshold (24) before testing add-b") == true, "\(told.texts)")
    }

    @Test func anAuditRunWaitingOnFullSlotsSaysWhoHoldsThem() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "add-b"])
        _ = call(try seat("worker-add-b", runtime), "report", ["status": "done", "summary": "added"])
        #expect(!call(lead, "configure", ["audit_finders": "2", "test_command": "true", "test_timeout_min": "0.01"]).isError)
        let holders = try fillSlots(1, notes: ["scripts/test.sh in /Users/a/dev/genswap"])
        defer { end(holders) }
        let told = Told()
        _ = ToolProgress.with(ToolProgress(every: 0.1, told.add)) { call(lead, "audit", ["task": "add-b"]) }
        #expect(told.texts.contains { $0.contains("its one slot held") && $0.contains("scripts/test.sh in /Users/a/dev/genswap (genswap)") }, "\(told.texts)")
    }

    @Test func statusNamesASlotHeldOverThirtyMinutes() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!call(lead, "status").text.contains("held long"))
        let holders = try fillSlots(1, notes: [".venv/bin/python -m pytest -q in /Users/a/dev/TGE-ANALYSIS/.vibeswitcher/worktrees/redesign"], ago: 38 * 60 + 5)
        defer { end(holders) }
        let header = try #require(call(lead, "status").text.split(separator: "\n").first.map(String.init))
        #expect(header.contains("; a test and build slot held long: TGE-ANALYSIS (.venv/bin/python -m pytest -q) for 38 min."), "\(header)")
        // The workflow shows the count merge and audits take.
        #expect(call(lead, "configure").text.contains("- heavy_slots: 1 (not set: "))
        #expect(!call(lead, "configure", ["heavy_slots": "4"]).isError)
        #expect(call(lead, "configure").text.contains("- heavy_slots: 4 (builds and full test runs at once"))
        #expect(call(lead, "configure", ["heavy_slots": "0"]).isError)
    }

    @Test func workersGetTheProjectsHeavySlots() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        #expect(runtime.environments["session-1"]?[TestLock.slotsVariable] == nil)
        #expect(!call(lead, "configure", ["heavy_slots": "2"]).isError)
        _ = call(lead, "add_task", ["title": "Two", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "two"])
        #expect(runtime.environments["session-2"]?[TestLock.slotsVariable] == "2")
    }
}

extension MCPServerTests {
    /// Says "half way" through its call's progress, then answers.
    final class Halfway: MCPToolset {
        var tools: [MCPToolInfo] { [MCPToolInfo(name: "slow", description: "Takes a while")] }
        func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult {
            ToolProgress.current?.send("half way")
            return MCPToolResult(text: ToolProgress.current == nil ? "no progress" : "done")
        }
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String: Any]] = []
        func add(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            lock.withLock { all.append(object) }
        }
        var objects: [[String: Any]] { lock.withLock { all } }
    }

    @Test func aCallWithAProgressTokenHearsItsProgress() throws {
        let server = MCPServer(name: "v", version: "1", toolset: Halfway())
        let lines = Lines()
        let call = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"slow","arguments":{},"_meta":{"progressToken":"tok-7"}}}"#
        server.receive(Data(call.utf8), respond: lines.add)
        #expect(eventually(timeout: 10) { lines.objects.contains { $0["id"] as? Int == 7 } })
        let objects = lines.objects
        #expect(objects.count == 2)
        let note = try #require(objects.first)
        #expect(note["method"] as? String == "notifications/progress" && note["id"] == nil)
        let params = try #require(note["params"] as? [String: Any])
        #expect(params["progressToken"] as? String == "tok-7" && params["progress"] as? Int == 1 && params["message"] as? String == "half way")
        #expect(((objects.last?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String == "done")
        // No token: nothing is sent but the answer.
        let plain = Lines()
        server.receive(Data(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"slow","arguments":{}}}"#.utf8), respond: plain.add)
        #expect(eventually(timeout: 10) { !plain.objects.isEmpty })
        #expect(plain.objects.count == 1)
        #expect(((plain.objects.first?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String == "no progress")
    }
}
