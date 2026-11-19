import Darwin
import Foundation
import Testing
@testable import VibeCore

/// The threads that decode and restore the board run with `ToolThread.stackSize`, and what they do fits a quarter of
/// it: growth of a board or receipt type fails here long before it overflows one.
struct ToolThreadStackTests {
    /// Reading a board, archiving its old tasks, and bringing one back (`BoardStore.restore` under `update`, where
    /// 2026-11-18's overflow was), then reading it with its archive.
    @Test func aBoardsReadArchiveAndRestoreFitAQuarterOfTheStack() throws {
        let fixture = LeadBoardArchiveTests()
        let store = try fixture.store()
        let board = fixture.board()
        try store.locked { try store.write(board) }
        let used = StackGauge.used {
            _ = try? store.read()
            _ = try? store.archive(now: fixture.now)
            try? store.update { board in _ = store.restore("old-first", into: &board) }
            _ = store.loadAll()
        }
        #expect(store.load().task("old-first") != nil)
        StackGauge.fits(used, "Reading, archiving and restoring the board")
    }

    /// The gauge sees deep calls: 8192 nested frames, 16 bytes each at least (a frame and its return address), count,
    /// to the page; a thread that does nothing touches little.
    @Test func theGaugeSeesDeepCalls() {
        let shallow = StackGauge.used {}
        let deep = StackGauge.used { _ = Self.dive(8192) }
        #expect(shallow < 64 << 10, "shallow \(shallow)")
        #expect(deep - shallow >= 8192 * 16 - Int(getpagesize()), "shallow \(shallow), deep \(deep)")
        #expect(deep < 2 << 20, "deep \(deep)")
    }

    /// Not optimized: a release build would make the recursion a loop.
    @_optimize(none)
    static func dive(_ depth: Int) -> Int { depth == 0 ? 0 : dive(depth - 1) &+ 1 }
}

/// Tool calls as the tool server runs them (`MCPServer.handle` on a thread of `ToolThread.stackSize`), each measured.
final class GaugedCalls: @unchecked Sendable {
    private let deepest = Locked((bytes: 0, tool: ""))

    /// The reply's text.
    @discardableResult
    func call(_ toolset: MCPToolset, _ tool: String, _ arguments: [String: Any] = [:]) throws -> String {
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: toolset)
        let request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
        let reply = Locked(Data())
        let used = StackGauge.used { reply.set(server.handle(request) ?? Data()) }
        if used > deepest.get().bytes { deepest.set((used, tool)) }
        return String(decoding: reply.get(), as: UTF8.self)
    }

    /// The deepest call fits a quarter of the tool server's threads' stack.
    func fit(sourceLocation: SourceLocation = #_sourceLocation) {
        let (bytes, tool) = deepest.get()
        #expect(bytes > 0)
        StackGauge.fits(bytes, "The tool call \(tool)", sourceLocation: sourceLocation)
    }
}

extension LeadAdvanceTests {
    /// The lead's and the worker's tool calls while auto_advance starts, merges and cleans up a task, and the passes
    /// (`Advancing` measures every run of them).
    @Test func toolCallsAndPassesFitAQuarterOfTheToolThreadStack() async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        let calls = GaugedCalls()
        let added = try calls.call(lead, "add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(added.contains("starts by itself"), "\(added)")
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        try calls.call(lead, "status")
        try calls.call(lead, "board", ["task": "add-b"])
        try commit("b.txt", "bee\n", in: Worktrees.path(root: root, slug: "add-b"))
        let report = try calls.call(try seat("worker-add-b", runtime), "report", doneReport("added b.txt"))
        #expect(!report.contains("\"isError\":true"), "\(report)")
        #expect(await advancing.until { task("add-b", root)?.status == .done && task("add-b", root)?.worktree == nil })
        try calls.call(lead, "status")
        try calls.call(lead, "board")
        calls.fit()
        #expect(advancing.deepest > 0)
    }

    /// The lead's own steps, by its tool calls with no auto_advance: start, audit, merge and clean up an audited task.
    @Test func theLeadsManualStepsFitAQuarterOfTheToolThreadStack() throws {
        let (root, runtime, lead) = try team()
        let calls = GaugedCalls()
        try calls.call(lead, "add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"],
                                          "review": "audit", "auto_advance": false])
        let started = try calls.call(lead, "start_worker", ["task": "add-b"])
        #expect(!started.contains("\"isError\":true"), "\(started)")
        try commit("b.txt", "bee\n", in: Worktrees.path(root: root, slug: "add-b"))
        try calls.call(try seat("worker-add-b", runtime), "report", doneReport("added b.txt"))
        let audit = try calls.call(lead, "audit", ["task": "add-b"])
        #expect(!audit.contains("\"isError\":true"), "\(audit)")
        try calls.call(try seat("verify-add-b", runtime), "submit_audit",
                       ["completion": "complete", "integrity": "clean", "summary": "checked"])
        let merged = try calls.call(lead, "merge", ["task": "add-b"])
        #expect(!merged.contains("\"isError\":true"), "\(merged)")
        try calls.call(lead, "cleanup", ["task": "add-b"])
        try calls.call(lead, "status")
        try calls.call(lead, "board", ["task": "add-b"])
        #expect(task("add-b", root)?.status == .done)
        calls.fit()
    }
}

/// `Boxed` fields code as plain optionals do: the board's JSON is the same byte for byte, a nil one left out.
struct BoxedTests {
    struct Plain: Codable, Equatable {
        var first: String
        var receipt: LeadReceipt?
        var merged: LeadMergeRecord?
        var last: Int?
    }

    struct Wrapped: Codable, Equatable {
        var first: String
        @Boxed var receipt: LeadReceipt?
        @Boxed var merged: LeadMergeRecord?
        var last: Int?
    }

    static let receipt = LeadReceipt(ending: .merged, startedAt: 10, endedAt: 20, worked: 5,
                                     worker: LeadTokens(input: 1_000, output: 200, cost: 0.5), verifier: nil)
    static let merged = LeadMergeRecord(commit: "c", tested: true, onto: "o", audited: nil, at: 30)

    @Test(arguments: [false, true], [false, true])
    func aBoxedFieldCodesAsAPlainOptional(sorted: Bool, present: Bool) throws {
        let plain = Plain(first: "a", receipt: present ? Self.receipt : nil, merged: present ? Self.merged : nil, last: 3)
        var wrapped = Wrapped(first: "a", last: 3)
        wrapped.receipt = plain.receipt
        wrapped.merged = plain.merged
        let encoder = JSONEncoder()
        // The board's own format (`BoardStore.write`), byte for byte; unsorted keys come in hash order, which no two
        // encodings promise to share, so those as the same JSON.
        if sorted { encoder.outputFormatting = [.sortedKeys, .prettyPrinted] }
        let bytes = try encoder.encode(plain), boxed = try encoder.encode(wrapped)
        if sorted {
            #expect(boxed == bytes)
        } else {
            #expect(try JSONSerialization.jsonObject(with: boxed) as? NSDictionary == JSONSerialization.jsonObject(with: bytes) as? NSDictionary)
        }
        #expect(String(decoding: bytes, as: UTF8.self).contains("receipt") == present)
        let back = try JSONDecoder().decode(Wrapped.self, from: bytes)
        #expect(back == wrapped && back.receipt == plain.receipt && back.merged == plain.merged)
    }

    @Test func nullDecodesAsNilAndACopyNeverSharesAChange() throws {
        let decoded = try JSONDecoder().decode(Wrapped.self, from: Data(#"{"first":"a","receipt":null}"#.utf8))
        #expect(decoded.receipt == nil && decoded.merged == nil)
        var task = LeadTask(slug: "s", title: "t", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
        task.receipt = Self.receipt
        var copy = task
        copy.receipt?.worked = 99
        #expect(task.receipt?.worked == 5 && copy.receipt?.worked == 99 && task != copy)
        copy.receipt = nil
        #expect(copy.receipt == nil)
    }

    /// The four largest optionals a task held inline (569, 194, 137 and 136 bytes) take a pointer each. A task's
    /// growth otherwise is the stack gauges' to catch, not a size limit's.
    @Test func aTaskHoldsItsLargestFieldsOnTheHeap() {
        let pointer = MemoryLayout<UnsafeRawPointer>.size
        #expect(MemoryLayout<Boxed<LeadReceipt>>.size == pointer && MemoryLayout<Boxed<LeadStall>>.size == pointer
            && MemoryLayout<Boxed<LeadWaits>>.size == pointer && MemoryLayout<Boxed<LeadMergeRecord>>.size == pointer)
        #expect(MemoryLayout<LeadReceipt?>.size > 500)
    }
}
