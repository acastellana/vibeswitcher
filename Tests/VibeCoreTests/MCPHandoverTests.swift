import Darwin
import Foundation
import Testing
@testable import VibeCore

private final class Anchor {}

/// The built `vibeswitcher-mcp`, beside this test bundle.
private let toolServer = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path

/// A real `vibeswitcher-mcp` process on real pipes, in a scratch home, installed at `installed`, with this test as its
/// MCP client. Its builds are scripts standing in for one: each runs the built tool server as a test build
/// (`VIBESWITCHER_MCP_TEST_BUILD`, see its main.swift), whose tools say which build answers, from which process.
final class ScratchToolServer {
    let dir: URL
    let installed: String
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var replies: [Int: [String: Any]] = [:]
    /// The id of every reply, in the order they came (a reply sent twice is here twice).
    private var answered: [Int] = []
    private var notified: [String] = []

    /// `extra`: more of the server's environment.
    init(_ scratch: Scratch, environment extra: [String: String] = [:]) throws {
        dir = scratch.url("mcp-handover")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        installed = dir.appendingPathComponent("vibeswitcher-mcp").path
        #expect(FileManager.default.isExecutableFile(atPath: toolServer), "swift build makes \(toolServer)")
        try install(build: "A")
        process.executableURL = URL(fileURLWithPath: installed)
        process.arguments = ["--root", dir.path]
        process.environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path, "PATH": "/usr/bin:/bin",
                               "TMPDIR": dir.path + "/", "VIBESWITCHER_MCP_TEST_BINARY": installed].merging(extra) { $1 }
        let log = dir.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
        process.standardInput = input
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.read(handle.availableData) }
        try process.run()
    }

    deinit { stop() }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    var log: String { (try? String(contentsOf: dir.appendingPathComponent("server.log"), encoding: .utf8)) ?? "" }

    /// Installs a build as an install does: written beside the binary, then renamed over it.
    func install(build: String) throws {
        try install("#!/bin/sh\nVIBESWITCHER_MCP_TEST_BUILD=\(build) exec '\(toolServer)' \"$@\"\n")
    }

    func install(_ script: String, mode: Int = 0o755) throws {
        let next = dir.appendingPathComponent("next").path
        FileManager.default.createFile(atPath: next, contents: Data(script.utf8), attributes: [.posixPermissions: mode])
        #expect(rename(next, installed) == 0)
    }

    /// Writes the messages in one go, a line each.
    func send(_ messages: [[String: Any]]) throws {
        var data = Data()
        for message in messages { data += try JSONSerialization.data(withJSONObject: message) + Data([0x0A]) }
        input.fileHandleForWriting.write(data)
    }

    func call(_ id: Int, _ tool: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
    }

    /// The reply to request `id`, once it's come.
    func reply(_ id: Int) throws -> [String: Any] {
        var found: [String: Any]?
        _ = eventually {
            lock.lock()
            found = replies[id]
            lock.unlock()
            return found != nil
        }
        return try #require(found, "no reply to \(id); the server's log: \(log)")
    }

    /// A tool call's text: the build that answered and its process, then any notice.
    func texts(_ id: Int) throws -> [String] {
        let content = try #require((try reply(id)["result"] as? [String: Any])?["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }
    }

    func tools(_ id: Int) throws -> [String] {
        try #require((try reply(id)["result"] as? [String: Any])?["tools"] as? [[String: Any]]).compactMap { $0["name"] as? String }
    }

    /// The ids of the replies so far, in the order they came.
    var replyOrder: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return answered
    }

    /// Writes `data` as it is: part of a line, say.
    func write(_ data: Data) { input.fileHandleForWriting.write(data) }

    /// The notifications the server sent, in order.
    var notifications: [String] {
        lock.lock()
        defer { lock.unlock() }
        return notified
    }

    private func read(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer += data
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<end])
            buffer = Data(buffer[buffer.index(after: end)...])
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let id = message["id"] as? Int {
                replies[id] = message
                answered.append(id)
            } else if let method = message["method"] as? String {
                notified.append(method)
            }
        }
    }

    static let initialize: [[String: Any]] = [
        ["jsonrpc": "2.0", "id": 0, "method": "initialize",
         "params": ["protocolVersion": "2025-11-25", "capabilities": ["roots": ["listChanged": true]],
                    "clientInfo": ["name": "claude-code", "version": "2.1.302"]]],
        ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
    ]
}

struct MCPHandoverTests {
    let scratch = Scratch()

    @Test func aClientKeepsItsSessionAcrossANewBuild() throws {
        let server = try ScratchToolServer(scratch)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize + [server.call(2, "build")])
        let initialized = try #require(try server.reply(0)["result"] as? [String: Any])
        #expect((initialized["capabilities"] as? [String: Any])?["tools"] as? [String: Bool] == ["listChanged": true])
        #expect(try server.tools(1) == ["build", "slow", "only-A"])
        let pid = server.process.processIdentifier
        #expect(try server.texts(2) == ["A \(pid)"])

        try server.install(build: "B")
        // Two calls in one write: the second is input the old build read but never handled.
        try server.send([server.call(3, "build"), server.call(4, "build")])
        #expect(try server.texts(3) == ["B \(pid)"])
        #expect(try server.texts(4) == ["B \(pid)"])
        // The same process, still running, on the same pipes: no disconnect, no new initialize.
        #expect(server.process.isRunning)
        #expect(server.notifications == ["notifications/tools/list_changed"])
        try server.send([["jsonrpc": "2.0", "id": 5, "method": "tools/list"]])
        #expect(try server.tools(5) == ["build", "slow", "only-B"])
        #expect(server.log.contains("switched in place to the new build"))

        // And on to the next build, the same way.
        try server.install(build: "C")
        try server.send([server.call(6, "build")])
        #expect(try server.texts(6) == ["C \(pid)"])
        #expect(server.notifications == ["notifications/tools/list_changed", "notifications/tools/list_changed"])
    }

    /// The old build finishes what it has in hand, answering it, before the new one takes over.
    @Test func aCallInHandIsFinishedByTheOldBuild() throws {
        let server = try ScratchToolServer(scratch)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize + [server.call(2, "slow", ["seconds": 3])])
        _ = try server.reply(1)
        let pid = server.process.processIdentifier
        try server.install(build: "B")
        // While the slow call runs, the old build goes on serving.
        try server.send([server.call(3, "build")])
        #expect(try server.texts(3) == ["A \(pid)"])
        #expect(try server.texts(2) == ["A \(pid)"])
        try server.send([server.call(4, "build")])
        #expect(try server.texts(4) == ["B \(pid)"])
        #expect(server.process.isRunning)
    }

    @Test func aBuildThatCantTakeOverLeavesTheOldOneServing() throws {
        let server = try ScratchToolServer(scratch)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        let pid = server.process.processIdentifier

        // A build that won't run.
        try server.install("#!/bin/sh\necho 'this build is broken' >&2\nexit 3\n")
        try server.send([server.call(2, "build")])
        let broken = try server.texts(2)
        #expect(broken.first == "A \(pid)")
        #expect(broken.count == 2 && broken[1].contains("couldn't switch to the new build (its probe exited with status 3)"))
        #expect(server.log.contains("this build is broken"))
        #expect(server.log.contains("couldn't switch to the new build at \(server.installed): its probe exited with status 3; this build serves on"))

        // One that can't be executed at all.
        try server.install("#!/bin/sh\nexit 0\n", mode: 0o644)
        try server.send([server.call(3, "build")])
        #expect(try server.texts(3).first == "A \(pid)")
        #expect(server.log.contains("it couldn't start: Permission denied"))

        // One that refuses the session: an answer that isn't the probe's.
        try server.install("#!/bin/sh\necho 'vibeswitcher-mcp handover 999 ok'\n")
        try server.send([server.call(4, "build")])
        #expect(try server.texts(4).first == "A \(pid)")
        #expect(server.log.contains("its probe said vibeswitcher-mcp handover 999 ok"))
        // Through all of it the old build kept its tools.
        try server.send([["jsonrpc": "2.0", "id": 5, "method": "tools/list"]])
        #expect(try server.tools(5) == ["build", "slow", "only-A"])

        // A good build then takes over at once.
        try server.install(build: "B")
        try server.send([server.call(6, "build")])
        #expect(try server.texts(6) == ["B \(pid)"])
    }

    /// Requests written back to back across the switch, the last one split over two writes: each is answered once, by
    /// the new build, in the order sent; none is lost in the old build's read buffer, none answered by both.
    @Test func pipelinedRequestsAcrossASwitchAreEachAnsweredOnceInOrder() throws {
        let server = try ScratchToolServer(scratch)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        let pid = server.process.processIdentifier

        try server.install(build: "B")
        // Pings and tools/list are answered as they're read, so their replies come in the order sent.
        var burst = Data()
        for id in 2...41 {
            let message: [String: Any] = id % 10 == 0 ? ["jsonrpc": "2.0", "id": id, "method": "tools/list"]
                : ["jsonrpc": "2.0", "id": id, "method": "ping"]
            burst += try JSONSerialization.data(withJSONObject: message) + Data([0x0A])
        }
        let last = try JSONSerialization.data(withJSONObject: server.call(42, "build")) + Data([0x0A])
        server.write(burst + last.prefix(10))
        #expect(eventually { server.replyOrder.contains(41) })
        server.write(last.dropFirst(10))
        #expect(try server.texts(42) == ["B \(pid)"])
        #expect(server.replyOrder == [0, 1] + Array(2...42))
        #expect(try server.tools(40) == ["build", "slow", "only-B"])
        #expect(server.notifications == ["notifications/tools/list_changed"])
        #expect(server.log.components(separatedBy: "switched in place to the new build").count == 2)
    }

    /// An install that replaces the file again while the build before it is being probed: the server never executes a
    /// build that didn't answer its probe, and settles on the last one with a switch to it, not a switch per change.
    @Test func aBuildReplacedDuringItsProbeIsNeverExecutedUnprobed() throws {
        let server = try ScratchToolServer(scratch)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        let pid = server.process.processIdentifier
        let record = server.dir.appendingPathComponent("c-ran").path
        let next = server.dir.appendingPathComponent("next").path
        // Build C says each time it runs whether as a probe or as the server.
        let c = "#!/bin/sh\nif [ \"$1\" = \(MCPHandover.probeFlag) ]; then echo probe >> '\(record)'; else echo run >> '\(record)'; fi\n"
            + "VIBESWITCHER_MCP_TEST_BUILD=C exec '\(toolServer)' \"$@\"\n"
        let cScript = server.dir.appendingPathComponent("c").path
        FileManager.default.createFile(atPath: cScript, contents: Data(c.utf8), attributes: [.posixPermissions: 0o755])
        // Build B, as it's probed, is replaced by C (an install landing just then), and still answers its probe.
        try server.install("#!/bin/sh\nif [ \"$1\" = \(MCPHandover.probeFlag) ]; then cp '\(cScript)' '\(next)' && mv '\(next)' '\(server.installed)'; fi\n"
                           + "VIBESWITCHER_MCP_TEST_BUILD=B exec '\(toolServer)' \"$@\"\n")
        try server.send([server.call(2, "build")])
        let first = try server.texts(2)
        #expect(first == ["A \(pid)"] || first == ["C \(pid)"], "\(first)")
        try server.send([server.call(3, "build")])
        #expect(try server.texts(3) == ["C \(pid)"])
        // C answered a probe before it ran, and runs once: one switch, to it.
        #expect((try? String(contentsOfFile: record, encoding: .utf8)) == "probe\nrun\n")
        try server.send([server.call(4, "build")])
        #expect(try server.texts(4) == ["C \(pid)"])
        #expect(server.log.components(separatedBy: "switched in place to the new build").count == 2)
        #expect(!server.log.contains("couldn't switch"))
    }

    /// The installed binary gone (mid-install, or the app moved): the old build serves on and says so once.
    @Test func aMissingBinaryLeavesTheOldBuildServingAndIsSaidOnce() throws {
        let server = try ScratchToolServer(scratch)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        let pid = server.process.processIdentifier
        #expect(unlink(server.installed) == 0)
        for id in 2...4 {
            try server.send([server.call(id, "build")])
            #expect(try server.texts(id) == ["A \(pid)"])
        }
        #expect(eventually { server.log.contains("is gone") })
        #expect(server.log.components(separatedBy: "\(server.installed) is gone (an install under way, or the app moved); this build serves on").count == 2)
        // Back, as a new build: it takes over.
        try server.install(build: "B")
        try server.send([server.call(5, "build")])
        #expect(try server.texts(5) == ["B \(pid)"])
    }

    /// A build the kernel won't run (no code signature) never replaces the running one; the first result after says
    /// why, once.
    @Test func anUnsignedBuildLeavesTheOldOneServing() throws {
        let server = try ScratchToolServer(scratch)
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        let pid = server.process.processIdentifier
        let unsigned = server.dir.appendingPathComponent("unsigned").path
        try FileManager.default.copyItem(atPath: toolServer, toPath: unsigned)
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        strip.arguments = ["--remove-signature", unsigned]
        try strip.run()
        strip.waitUntilExit()
        #expect(strip.terminationStatus == 0)
        #expect(rename(unsigned, server.installed) == 0)
        try server.send([server.call(2, "build")])
        let texts = try server.texts(2)
        #expect(texts.first == "A \(pid)")
        #expect(texts.count == 2 && texts[1].contains("couldn't switch to the new build (its probe was killed by signal 9)"), "\(texts)")
        try server.send([server.call(3, "build")])
        #expect(try server.texts(3) == ["A \(pid)"])
        #expect(server.log.contains("couldn't switch to the new build at \(server.installed): its probe was killed by signal 9; this build serves on"))
    }

    /// A build that fails its probe each time it's tried again is said once, not at each retry.
    @Test func aBuildRefusedAtEachRetryIsSaidOnce() throws {
        // Tried again every 0.2 s rather than every minute.
        let server = try ScratchToolServer(scratch, environment: ["VIBESWITCHER_MCP_TEST_RETRY": "0.2"])
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        let pid = server.process.processIdentifier
        let probes = server.dir.appendingPathComponent("probes").path
        try server.install("#!/bin/sh\necho probed >> '\(probes)'\necho 'this build is broken' >&2\nexit 3\n")
        // An idle server looks every second: three probes, each refused.
        #expect(eventually { ((try? String(contentsOfFile: probes, encoding: .utf8)) ?? "").split(separator: "\n").count >= 3 })
        try server.send([server.call(2, "build")])
        let texts = try server.texts(2)
        #expect(texts.first == "A \(pid)")
        #expect(texts.count == 2 && texts[1].contains("its probe exited with status 3"))
        #expect(server.log.components(separatedBy: "couldn't switch to the new build at").count == 2, "\(server.log)")
    }
}

/// The session host restarts after an install (it hands over to its new build) just as the tool servers switch to
/// theirs: a server that can't ask it which role its session holds asks again until it answers.
struct MCPHostRestartTests {
    let scratch = Scratch()

    func server(_ environment: [String: String] = [:]) throws -> ScratchToolServer {
        try ScratchToolServer(scratch, environment: environment)
    }

    /// The session host as the test builds play it (see main.swift): a file there while it answers, holding the role.
    func hostEnvironment(_ path: String, hold: Bool = false, patience: TimeInterval? = nil) -> [String: String] {
        var environment = ["VIBESWITCHER_MCP_TEST_HOST": path]
        if hold { environment["VIBESWITCHER_MCP_TEST_HOLD"] = "1" }
        if let patience { environment["VIBESWITCHER_MCP_TEST_PATIENCE"] = "\(patience)" }
        return environment
    }

    /// The host plays: `role` while it answers ("" for a session with none), nil while it can't be asked.
    func host(_ path: String, _ role: String?) throws {
        if let role { try Data(role.utf8).write(to: URL(fileURLWithPath: path)) } else { try? FileManager.default.removeItem(atPath: path) }
    }

    @Test func aSwitchWhileTheHostIsDownGetsTheRoleOnceItsBack() throws {
        let path = scratch.url("host").path
        try host(path, "worker")
        let server = try server(hostEnvironment(path))
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize + [server.call(2, "build")])
        let pid = server.process.processIdentifier
        #expect(try server.texts(2) == ["A worker \(pid)"])

        try host(path, nil)
        try server.install(build: "B")
        try server.send([server.call(3, "build")])
        // Not a refusal: the new build waits for the host's answer.
        #expect(try server.texts(3) == [MCPHostedToolset.waiting])
        #expect(server.log.contains("switched in place to the new build"))
        #expect(server.log.contains("the session host can't be asked yet"))

        try host(path, "worker")
        #expect(eventually { server.notifications == ["notifications/tools/list_changed"] })
        try server.send([server.call(4, "build"), ["jsonrpc": "2.0", "id": 5, "method": "tools/list"]])
        #expect(try server.texts(4) == ["B worker \(pid)"])
        #expect(try server.tools(5) == ["build", "slow", "only-B"])
    }

    /// Optionally better still: no switch until the host answers, so the new build gets its role at once.
    @Test func aSwitchWaitsForTheHost() throws {
        let path = scratch.url("host").path
        try host(path, "lead")
        let server = try server(hostEnvironment(path, hold: true))
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        let pid = server.process.processIdentifier

        try host(path, nil)
        try server.install(build: "B")
        try server.send([server.call(2, "build")])
        #expect(try server.texts(2) == ["A lead \(pid)"])
        try host(path, "lead")
        try server.send([server.call(3, "build")])
        #expect(try server.texts(3) == ["B lead \(pid)"])
    }

    /// A fresh start with the host down: no tools for a moment, then the role's, and the client is told.
    @Test func aFreshStartWithTheHostDownGetsItsRoleWhenItsBack() throws {
        let path = scratch.url("host").path
        let server = try server(hostEnvironment(path))
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize + [server.call(2, "build")])
        #expect(try server.tools(1) == [])
        #expect(try server.texts(2) == [MCPHostedToolset.waiting])
        try host(path, "verifier")
        #expect(eventually { server.notifications == ["notifications/tools/list_changed"] })
        try server.send([["jsonrpc": "2.0", "id": 3, "method": "tools/list"], server.call(4, "build")])
        #expect(try server.tools(3) == ["build", "slow", "only-A"])
        #expect(try server.texts(4) == ["A verifier \(server.process.processIdentifier)"])
    }

    /// The host's answer is final: a session with no role stays without, whatever happens after.
    @Test func noRoleFromTheHostIsFinal() throws {
        let path = scratch.url("host").path
        try host(path, "")
        let server = try server(hostEnvironment(path))
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize + [server.call(2, "build")])
        #expect(try server.tools(1) == [])
        #expect(try server.texts(2) == ["A has no role"])
        try host(path, "lead")
        try server.send([server.call(3, "build")])
        #expect(try server.texts(3) == ["A has no role"])
        #expect(!server.log.contains("can't be asked"))
    }

    @Test func aHostThatNeverAnswersIsGivenUpOn() throws {
        let server = try server(hostEnvironment(scratch.url("host").path, patience: 1))
        defer { server.stop() }
        try server.send(ScratchToolServer.initialize)
        _ = try server.reply(1)
        var id = 2
        #expect(eventually {
            defer { id += 1 }
            try? server.send([server.call(id, "build")])
            return (try? server.texts(id)) == ["A has no role"]
        })
        #expect(server.log.contains("the session host didn't answer for 1 s; giving up"))
    }
}

struct MCPHostedToolsetTests {
    final class Count: @unchecked Sendable {
        var attempts = 0
        var settled = 0
    }

    @Test func aHostThatAnswersAtOnceMakesTheToolsetAtOnce() {
        let count = Count()
        let toolset = MCPHostedToolset(attempt: { count.attempts += 1; return MCPServerTests.Echo() }, giveUp: { MCPServerTests.Echo() })
        toolset.start { count.settled += 1 }
        #expect(toolset.settled)
        #expect(toolset.call("echo", ["text": "hi"]).text == "echo: hi")
        #expect(count.attempts == 1)
        #expect(count.settled == 0)
    }

    @Test func aHostThatCantBeAskedIsAskedAgainUntilItAnswers() {
        let lock = NSLock()
        let count = Count()
        let toolset = MCPHostedToolset(firstDelay: 0.01, longestDelay: 0.02, attempt: {
            lock.lock()
            defer { lock.unlock() }
            count.attempts += 1
            return count.attempts < 4 ? nil : MCPServerTests.Echo()
        }, giveUp: { MCPServerTests.Echo() })
        toolset.start {
            lock.lock()
            count.settled += 1
            lock.unlock()
        }
        // Meanwhile: no tools, and calls are told to come back.
        if !toolset.settled {
            #expect(toolset.tools.isEmpty)
            let waiting = toolset.call("echo", ["text": "hi"])
            #expect(waiting.text == MCPHostedToolset.waiting && waiting.isError)
        }
        #expect(eventually { lock.lock(); defer { lock.unlock() }; return count.settled == 1 })
        #expect(toolset.settled)
        #expect(toolset.call("echo", ["text": "hi"]).text == "echo: hi")
        #expect(count.attempts == 4)
    }

    @Test func patienceRunsOut() {
        final class Refuses: MCPToolset {
            var tools: [MCPToolInfo] { [] }
            func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult { MCPToolResult(text: "no host", isError: true) }
        }
        let toolset = MCPHostedToolset(patience: 0.1, firstDelay: 0.01, longestDelay: 0.02, attempt: { nil }, giveUp: { Refuses() })
        let settled = DispatchSemaphore(value: 0)
        toolset.start { settled.signal() }
        #expect(settled.wait(timeout: .now() + hangGuard) == .success)
        #expect(toolset.call("echo", [:]).text == "no host")
    }
}

struct MCPSessionTests {
    func send(_ server: MCPServer, _ object: [String: Any]) throws {
        _ = server.handle(try JSONSerialization.data(withJSONObject: object))
    }

    @Test func theSessionIsWhatTheClientSetUp() throws {
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: MCPServerTests.Echo())
        #expect(server.currentSession == MCPSession())
        try send(server, ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                          "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code"], "capabilities": [:]]])
        try send(server, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let session = server.currentSession
        #expect(session.protocolVersion == "2025-06-18")
        #expect(session.initialized)
        #expect(session.announcesToolChanges)
        #expect(session.tools == MCPServer.digest(MCPServerTests.Echo().tools))
        let client = try #require(session.client.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((client["clientInfo"] as? [String: Any])?["name"] as? String == "claude-code")
    }

    /// The guard rail: what goes to the new build is the MCP session and the input, never who the caller is. The new
    /// build asks the session host for its role, as at a fresh start.
    @Test func theHandoverCarriesNoRole() throws {
        var session = MCPSession()
        session.protocolVersion = "2025-11-25"
        session.client = Data("{}".utf8)
        session.tools = "digest"
        let state = MCPHandover.State(session: session, input: Data("x".utf8), binary: .init(modified: 1, size: 2, inode: 3))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(Set(json.keys) == ["format", "session", "input", "binary"])
        #expect(Set((json["session"] as? [String: Any])?.keys ?? [:].keys)
                == ["protocolVersion", "client", "initialized", "announcesToolChanges", "tools"])
        #expect(MCPHandover.decode(try JSONEncoder().encode(state)) == state)
        var other = state
        other.format = MCPHandover.format + 1
        #expect(MCPHandover.decode(try JSONEncoder().encode(other)) == nil)
        #expect(MCPHandover.decode(Data("not json".utf8)) == nil)
    }

    /// The new build's side, in this process: it answers the input carried over first, and tells a client that got
    /// another build's tools to ask again.
    @Test func aResumedServerGoesOnWithTheSession() throws {
        var session = MCPSession()
        session.initialized = true
        session.announcesToolChanges = true
        session.tools = "another build's tools"
        // A ping: answered on this thread, so before `serve` returns (a call's answer could come after).
        let carried = Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8 + [0x0A])
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: MCPServerTests.Echo(),
                               resuming: MCPHandover.State(session: session, input: carried, binary: nil))
        #expect(server.currentSession == session)
        let input = Pipe()
        let output = Pipe()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            server.serve(input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor)
            done.signal()
        }
        try input.fileHandleForWriting.close()
        #expect(done.wait(timeout: .now() + hangGuard) == .success)
        try output.fileHandleForWriting.close()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first == #"{"jsonrpc":"2.0","method":"notifications\/tools\/list_changed"}"#)
        #expect(lines.last == #"{"id":7,"jsonrpc":"2.0","result":{}}"#)

        // The same tools: nothing to tell.
        session.tools = MCPServer.digest(MCPServerTests.Echo().tools)
        let same = MCPServer(name: "vibeswitcher", version: "1", toolset: MCPServerTests.Echo(),
                             resuming: MCPHandover.State(session: session, input: Data(), binary: nil))
        let quiet = Pipe()
        let closed = Pipe()
        try closed.fileHandleForWriting.close()
        same.serve(input: closed.fileHandleForReading.fileDescriptor, output: quiet.fileHandleForWriting.fileDescriptor)
        try quiet.fileHandleForWriting.close()
        #expect(quiet.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
