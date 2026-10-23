import Foundation
import Testing
@testable import VibeCore

struct MCPServerTests {
    final class Echo: MCPToolset {
        var tools: [MCPToolInfo] {
            [MCPToolInfo(name: "echo", description: "Says it back", properties: ["text": .init(type: "string", description: "What to say")], required: ["text"])]
        }
        func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult {
            guard name == "echo", let text = arguments["text"] as? String else { return MCPToolResult(text: "bad call", isError: true) }
            return MCPToolResult(text: "echo: \(text)")
        }
    }

    /// A call that runs a grouped `sleep 60` (`Shell.run` starts it in a process group of its own, as merge's test
    /// command), its pid in `<marks>/sleep`, and notes its cleanup in `<marks>/cleaned` as it ends.
    final class Sleeper: MCPToolset {
        let marks: String
        init(marks: String) { self.marks = marks }
        var tools: [MCPToolInfo] { [MCPToolInfo(name: "sleep", description: "Sleeps a minute")] }
        func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult {
            defer { FileManager.default.createFile(atPath: marks + "/cleaned", contents: nil) }
            let slept = Shell.run(executable: "/bin/sh", args: ["-c", "sleep 60 & echo $! > sleep; wait"], in: marks, timeout: 120)
            return MCPToolResult(text: slept.cancelled ? "cancelled" : "slept", isError: slept.cancelled)
        }
    }

    /// A server whose input ends (its lead closed or restarted) cancels its running calls and returns once they've
    /// ended, their cleanup run: it exited at once, leaving a merge's tests running on unlocked and its scratch
    /// worktree behind (process audit 2026-10-22, #6).
    @Test func aServerWhoseInputEndsEndsItsCallsFirst() throws {
        let temp = Scratch()
        let marks = temp.url("mcp-stop").path
        try FileManager.default.createDirectory(atPath: marks, withIntermediateDirectories: true)
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: Sleeper(marks: marks))
        let input = Pipe(), output = Pipe()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            server.serve(input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor)
            done.signal()
        }
        input.fileHandleForWriting.write(Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sleep","arguments":{}}}"# + "\n").utf8))
        let pidFile = marks + "/sleep"
        #expect(eventually { (try? String(contentsOfFile: pidFile, encoding: .utf8))?.hasSuffix("\n") == true })
        let sleep = try #require((try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        #expect(kill(sleep, 0) == 0)
        try input.fileHandleForWriting.close()
        #expect(done.wait(timeout: .now() + hangGuard) == .success)
        #expect(FileManager.default.fileExists(atPath: marks + "/cleaned"), "the call's cleanup didn't run")
        #expect(eventually(timeout: 5) { kill(sleep, 0) != 0 })
        // It answered that it was cancelled, the client still reading.
        try output.fileHandleForWriting.close()
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(said.contains(#""text":"cancelled""#), "\(said)")

        // `stop` (SIGTERM, in vibeswitcher-mcp) ends it the same way, its input still open.
        let again = MCPServer(name: "vibeswitcher", version: "1", toolset: Sleeper(marks: marks))
        try? FileManager.default.removeItem(atPath: pidFile)
        try? FileManager.default.removeItem(atPath: marks + "/cleaned")
        let open = Pipe(), quiet = Pipe()
        let ended = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            again.serve(input: open.fileHandleForReading.fileDescriptor, output: quiet.fileHandleForWriting.fileDescriptor)
            ended.signal()
        }
        open.fileHandleForWriting.write(Data((#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sleep","arguments":{}}}"# + "\n").utf8))
        #expect(eventually { (try? String(contentsOfFile: pidFile, encoding: .utf8))?.hasSuffix("\n") == true })
        let second = try #require((try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        again.stop()
        #expect(ended.wait(timeout: .now() + hangGuard) == .success)
        #expect(FileManager.default.fileExists(atPath: marks + "/cleaned"))
        #expect(eventually(timeout: 5) { kill(second, 0) != 0 })
        try open.fileHandleForWriting.close()
        try quiet.fileHandleForWriting.close()
    }

    func send(_ server: MCPServer, _ object: [String: Any]) throws -> [String: Any]? {
        guard let reply = server.handle(try JSONSerialization.data(withJSONObject: object)) else { return nil }
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    /// What claude 2.1.302 sent a scratch stdio server (recorded): by default `server/discover` in the 2026-07-28 envelope,
    /// then, on "method not found", initialize with 2025-11-25; with `MCP_PROTOCOL_NEGOTIATION=legacy` initialize alone.
    static let discover = #"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.302","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}}}}}"#
    static let initialize = #"{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.302","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"}},"jsonrpc":"2.0","id":0}"#
    static let call = #"{"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"},"_meta":{"claudecode/toolUseId":"toolu_013Ffh6GpR6G7hQBksHPoZ4q","progressToken":2}},"jsonrpc":"2.0","id":2}"#

    func send(_ server: MCPServer, line: String) throws -> [String: Any]? {
        guard let reply = server.handle(Data(line.utf8)) else { return nil }
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    @Test func aClientOfThe20260728RevisionFallsBackToInitialize() throws {
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: Echo())
        let discovered = try #require(try send(server, line: Self.discover))
        #expect(discovered["id"] as? String == "server-discover-probe-1")
        #expect((discovered["error"] as? [String: Any])?["code"] as? Int == -32601)
        let initialized = try #require(try send(server, line: Self.initialize))
        #expect((initialized["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        let called = try #require(try send(server, line: Self.call))
        #expect(((called["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String == "echo: hi")
    }

    @Test func aLegacyClientGetsTheVersionItAskedFor() throws {
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: Echo())
        let initialized = try #require(try send(server, line: Self.initialize))
        #expect((initialized["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        for version in ["2025-06-18", "2024-11-05"] {
            let reply = try #require(try send(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": version]]))
            #expect((reply["result"] as? [String: Any])?["protocolVersion"] as? String == version)
        }
    }

    /// Never echoed blindly: a version this server doesn't speak gets the newest one it does.
    @Test func anUnknownVersionGetsTheNewestSupportedOne() throws {
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: Echo())
        for asked: Any in ["2026-07-28", "2025-03-26", "2099-01-01", "nonsense", NSNull()] {
            let reply = try #require(try send(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": asked]]))
            #expect((reply["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        }
        #expect(MCPServer.negotiate(nil) == "2025-11-25")
    }

    @Test func handshakeListAndCall() throws {
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: Echo())
        let initialized = try #require(try send(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                        "params": ["protocolVersion": "2025-06-18", "capabilities": [:]]]))
        let result = try #require(initialized["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "vibeswitcher")
        #expect(result["capabilities"] as? [String: Any] != nil)
        #expect(try send(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)

        let list = try #require(try send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "echo")
        let schema = try #require(tools.first?["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["text"])

        let call = try #require(try send(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "hi"]]]))
        let content = try #require((call["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "echo: hi")
        #expect((call["result"] as? [String: Any])?["isError"] as? Bool == false)
        #expect(call["id"] as? Int == 3)
    }

    @Test func errorsAreReportedNotCrashed() throws {
        let server = MCPServer(name: "v", version: "1", toolset: Echo())
        let bad = try #require(try send(server, ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "echo", "arguments": [:]]]))
        #expect((bad["result"] as? [String: Any])?["isError"] as? Bool == true)
        let unknown = try #require(try send(server, ["jsonrpc": "2.0", "id": "x", "method": "nope"]))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(unknown["id"] as? String == "x")
        let garbage = try #require(server.handle(Data("not json".utf8)).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((garbage["error"] as? [String: Any])?["code"] as? Int == -32700)
        let ping = try #require(try send(server, ["jsonrpc": "2.0", "id": 5, "method": "ping"]))
        #expect(ping["result"] as? [String: Any] != nil)
    }
}

struct StaleServerTests {
    let temp = Scratch()
    /// The binary on disk as the tests replace it: `nil` is a missing file.
    final class Disk: @unchecked Sendable {
        var binary: BinaryWatch.Identity? = BinaryWatch.Identity(modified: 100, size: 5_000, inode: 7)
    }

    func watch(_ disk: Disk) -> BinaryWatch {
        BinaryWatch(path: "/Applications/VibeSwitcher.app/Contents/MacOS/vibeswitcher-mcp", identify: { _ in disk.binary })
    }

    @Test func theSameBinaryIsNoUpdate() {
        let disk = Disk()
        let watch = watch(disk)
        #expect(watch.update() == nil)
        #expect(watch.notice() == nil)
    }

    @Test func aReplacedBinaryIsAnUpdateWithNoAdviceToReconnect() {
        let disk = Disk()
        let watch = watch(disk)
        let newer = BinaryWatch.Identity(modified: 200, size: 5_000, inode: 7)
        disk.binary = newer
        #expect(watch.update() == newer)
        // The server switches to it by itself: nothing for the agent to do, so nothing said.
        #expect(watch.notice() == nil)
        // A copy that kept the time but not the file is another build too.
        let copied = Disk()
        let other = self.watch(copied)
        copied.binary = BinaryWatch.Identity(modified: 100, size: 5_000, inode: 8)
        #expect(other.update() == copied.binary)
        // Put back: nothing to switch to.
        disk.binary = BinaryWatch.Identity(modified: 100, size: 5_000, inode: 7)
        #expect(watch.update() == nil)
    }

    @Test func aBuildThatCouldntTakeOverIsTriedAgainLaterAndSaidSo() {
        let disk = Disk()
        let watch = watch(disk)
        let broken = BinaryWatch.Identity(modified: 200, size: 5_000, inode: 7)
        disk.binary = broken
        let now = Date()
        watch.failed(broken, because: "its probe exited with status 3", at: now)
        #expect(watch.update(now: now.addingTimeInterval(30)) == nil)
        #expect(watch.update(now: now.addingTimeInterval(61)) == broken)
        let notice = watch.notice() ?? ""
        #expect(notice.contains("couldn't switch to the new build (its probe exited with status 3)"))
        #expect(!notice.contains("/mcp"))
        // Another build replacing it is tried at once.
        let fixed = BinaryWatch.Identity(modified: 300, size: 5_100, inode: 9)
        disk.binary = fixed
        #expect(watch.update(now: now.addingTimeInterval(1)) == fixed)
        // The old build back in place: nothing to switch to, nothing to say.
        disk.binary = BinaryWatch.Identity(modified: 100, size: 5_000, inode: 7)
        #expect(watch.update() == nil)
        #expect(watch.notice() == nil)
    }

    @Test func aMissingBinaryIsNoCrashAndNoUpdate() {
        let disk = Disk()
        let watch = watch(disk)
        // Mid-install, or the app moved: nothing to compare with yet.
        disk.binary = nil
        #expect(watch.update() == nil)
        disk.binary = BinaryWatch.Identity(modified: 300, size: 6_000, inode: 9)
        #expect(watch.update() == disk.binary)
        // Never seen at start: never an update, it can't tell old from new.
        disk.binary = nil
        let blind = self.watch(disk)
        disk.binary = BinaryWatch.Identity(modified: 400, size: 6_000, inode: 9)
        #expect(blind.update() == nil)
        #expect(BinaryWatch(path: "/nonexistent/vibeswitcher-mcp").update() == nil)
    }

    /// After a switch, the build the process runs is the one the build before checked, not the file as it is by then.
    @Test func theBuildHandedOverIsTheOneRunning() {
        let disk = Disk()
        disk.binary = BinaryWatch.Identity(modified: 300, size: 6_000, inode: 9)
        let handed = BinaryWatch.Identity(modified: 200, size: 5_000, inode: 8)
        let watch = BinaryWatch(path: "/x/vibeswitcher-mcp", running: handed, identify: { _ in disk.binary })
        #expect(watch.update() == disk.binary)
    }

    @Test func aRealFileIsIdentifiedAndItsReplacementNoticed() throws {
        let folder = temp.url("binary-watch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("vibeswitcher-mcp")
        try Data("old".utf8).write(to: binary)
        let watch = BinaryWatch(path: binary.path)
        #expect(BinaryWatch.identity(of: binary.path) != nil)
        #expect(watch.update() == nil)
        // An install writes a new file in its place.
        try FileManager.default.removeItem(at: binary)
        try Data("newer".utf8).write(to: binary)
        #expect(watch.update() == BinaryWatch.identity(of: binary.path))
    }

    @Test func toolResultsCarryANoticeOnlyWhenSwitchingFailed() throws {
        let disk = Disk()
        let watch = watch(disk)
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: MCPServerTests.Echo(), watch: watch)
        func call() throws -> [String?] {
            let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                      "params": ["name": "echo", "arguments": ["text": "hi"]]])
            let reply = try #require(server.handle(request).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            return try #require((reply["result"] as? [String: Any])?["content"] as? [[String: Any]]).map { $0["text"] as? String }
        }
        #expect(try call() == ["echo: hi"])
        disk.binary = BinaryWatch.Identity(modified: 200, size: 5_000, inode: 7)
        #expect(try call() == ["echo: hi"])
        watch.failed(try #require(disk.binary), because: "it couldn't start")
        #expect(try call() == ["echo: hi", watch.notice()])
    }
}
