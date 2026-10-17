import Foundation
import Testing
@testable import VibeCore

struct StallDetectorTests {
    @Test func aStallIsReportedOnceAndItsEndWithItsLength() {
        var detector = StallDetector(threshold: 2)
        let start = Date(timeIntervalSince1970: 1000)
        detector.beat(at: start)
        #expect(detector.check(at: start + 1) == nil)
        #expect(detector.check(at: start + 2.5) == .stalled(since: start))
        // Still stuck: not again.
        #expect(detector.check(at: start + 5) == nil)
        detector.beat(at: start + 6)
        #expect(detector.check(at: start + 6.1) == .recovered(after: 6))
        #expect(detector.check(at: start + 7) == nil)
    }
}

struct BreadcrumbsTests {
    @Test func keepsTheLatestLines() throws {
        let crumbs = Breadcrumbs(capacity: 3)
        for index in 1...5 { crumbs.note("event \(index)") }
        let lines = crumbs.lines
        #expect(lines.count == 3)
        #expect(lines.first?.hasSuffix("event 3") == true)
        #expect(lines.last?.hasSuffix("event 5") == true)
    }

    @Test func theLogFileStaysSmall() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        let crumbs = Breadcrumbs(capacity: 10, file: folder.appendingPathComponent("app.log"), maxFileBytes: 2_000)
        for index in 0..<200 { crumbs.note("a line that takes some room \(index)") }
        crumbs.flush()
        let size = (try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("app.log").path)[.size] as? Int) ?? 0
        #expect(size > 0 && size <= 2_000)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("app.log.1").path))
    }
}

struct PendingDeliveryTests {
    @Test func aSentMessageNotSeenSoonIsLate() {
        let sent = Date(timeIntervalSince1970: 1000)
        let message = PendingMessage(text: "hello", afterPrompts: 0, expectsSoon: true, sentAt: sent)
        #expect(!message.late(at: sent + 10))
        #expect(message.late(at: sent + 16))
        // Queued for after a turn: it can take as long as the turn.
        #expect(!PendingMessage(text: "later", afterPrompts: 0, sentAt: sent).late(at: sent + 600))
        // A command (/clear…) isn't written to the conversation as a prompt.
        #expect(!PendingMessage(text: "/clear", afterPrompts: 0, expectsSoon: true, sentAt: sent).late(at: sent + 60))
    }
}

final class SlowTools: MCPToolset {
    var tools: [MCPToolInfo] { [MCPToolInfo(name: "slow", description: "runs a long command")] }
    func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult {
        let started = Date()
        _ = Shell.run(executable: "/bin/sleep", args: ["30"], in: "/tmp", timeout: 60)
        return MCPToolResult(text: "took \(Int(Date().timeIntervalSince(started)))")
    }
}

struct MCPConcurrencyTests {
    @Test func otherCallsAnswerWhileOneRunsAndCancelStopsIt() throws {
        let server = MCPServer(name: "t", version: "1", toolset: SlowTools())
        let lock = NSLock()
        var replies: [String: (Date, String)] = [:]
        let respond: (Data) -> Void = { data in
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            lock.lock()
            replies["\(object?["id"] ?? "?")"] = (Date(), String(decoding: data, as: UTF8.self))
            lock.unlock()
        }
        let started = Date()
        server.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow","arguments":{}}}"#.utf8), respond: respond)
        server.receive(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8), respond: respond)
        func reply(_ id: String) -> (Date, String)? { lock.lock(); defer { lock.unlock() }; return replies[id] }
        var waited = 0
        while reply("2") == nil, waited < 50 { usleep(100_000); waited += 1 }
        #expect(reply("2") != nil)
        #expect(reply("1") == nil)
        server.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#.utf8), respond: respond)
        waited = 0
        while reply("1") == nil, waited < 100 { usleep(100_000); waited += 1 }
        #expect(reply("1") != nil)
        #expect(Date().timeIntervalSince(started) < 15)
    }
}
