import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The lead's tool server under a scratch host (the stage 2 plan's Task 11a, stage 1's R9): a real `vibeswitcher-host`
/// on a scratch home, socket and lock, with this test as its app (through the connector stand-in on Linux,
/// `TestHosts.connectAsApp`; by its code and key on the Mac), runs the built `vibeswitcher-mcp` as a session's program,
/// as Claude Code starts it in the lead's session. The tool server learns its role from the host: the session starts
/// holding none, the app binds the lead's grant to it, and the server's tools are then the lead's.
@Suite(.serialized, hostTestLimit) struct ToolServerUnderAHostTests {
    /// The tool server's stdin and stdout, two FIFOs in the test's scratch folder. Each is opened both ways here, so
    /// neither the test's open nor the session's waits for the other's (as `PeerPerMessageTests.Running` does); the
    /// replies' end doesn't block, so a look at it gives back what came so far.
    final class Pipes {
        let folder: String
        let input: String
        let output: String
        private let requests: Int32
        private let replies: Int32
        private var unread: [UInt8] = []
        private var lines: [[String: Any]] = []

        init(folder: String) throws {
            self.folder = folder
            input = folder + "/in"
            output = folder + "/out"
            for fifo in [input, output] { try #require(mkfifo(fifo, 0o600) == 0, "no FIFO at \(fifo): errno \(errno)") }
            let requests = open(input, O_RDWR | O_CLOEXEC), replies = open(output, O_RDWR | O_CLOEXEC | O_NONBLOCK)
            guard requests >= 0, replies >= 0 else {
                let code = errno
                for fd in [requests, replies] where fd >= 0 { Sys.close(fd) }
                throw Failure(what: "the FIFOs didn't open: errno \(code)")
            }
            self.requests = requests
            self.replies = replies
        }

        deinit {
            Sys.close(requests)
            Sys.close(replies)
        }

        var errors: String { (try? String(contentsOfFile: folder + "/err", encoding: .utf8)) ?? "" }

        struct Failure: Error, CustomStringConvertible {
            let what: String
            var description: String { what }
        }

        func send(_ id: Int, _ method: String, _ params: [String: Any] = [:]) throws {
            let line = Array(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + Data([0x0A]))
            guard Sys.write(requests, line, line.count) == line.count else { throw Failure(what: "\(method): not written (errno \(errno))") }
        }

        /// The reply to `id`, if it has come: what the server wrote so far is read first.
        func reply(_ id: Int) -> [String: Any]? {
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(replies, &chunk, chunk.count)
                guard count > 0 else { break }
                unread += chunk.prefix(count)
            }
            while let end = unread.firstIndex(of: UInt8(ascii: "\n")) {
                if let object = (try? JSONSerialization.jsonObject(with: Data(unread[..<end]))) as? [String: Any] { lines.append(object) }
                unread.removeFirst(end + 1)
            }
            return lines.first { ($0["id"] as? Int) == id }.flatMap { $0["result"] as? [String: Any] }
        }

        /// Asks and waits for the answer (within `timeout`, the hang guard unless given).
        func ask(_ id: Int, _ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = hangGuard) async throws -> [String: Any]? {
            try send(id, method, params)
            _ = await eventually(timeout: timeout) { reply(id) != nil }
            return reply(id)
        }
    }

    @Test func theLeadsToolServerListsItsToolsAndServesStatus() async throws {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let host = try await ScratchHostProcess()
        var sessions: [HostSession] = []
        defer {
            for session in sessions where kill(session.childPID, 0) == 0 { kill(-session.childPID, SIGKILL) }
            host.stop()
        }
        // The session's tools find the host where they always do: under its home.
        try FileManager.default.createDirectory(atPath: host.home + "/.vibeswitcher", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: host.home + "/.vibeswitcher/host.sock", withDestinationPath: host.socket)
        // A scratch repository, its board empty.
        let root = host.dir + "/board"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let folder = host.dir + "/mcp"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let pipes = try Pipes(folder: folder)

        let (app, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        guard case .grant(let grant)? = app.vault(.issue(role: .lead, root: root, task: nil, auditing: nil)) else {
            Issue.record("the app got no lead grant: \(host.log)"); return
        }
        // The lead's session: its program is the tool server, its stdin and stdout the FIFOs. Its home is the scratch
        // one, for Foundation too (which reads CFFIXED_USER_HOME, not HOME): never the user's host.
        let quote = RecentProjects.shellQuote
        let lead = try await app.spawn("export HOME=\(quote(host.home)) CFFIXED_USER_HOME=\(quote(host.home)); cd \(quote(root)); "
                                       + "exec \(quote(mcp)) --root \(quote(root)) --role lead < \(quote(pipes.input)) > \(quote(pipes.output)) 2> \(quote(folder + "/err"))",
                                       cwd: root, label: "Lead")
        sessions = [lead]
        await #expect(app.vault(.bind(grant: grant, root: root, session: lead.id.uuidString)) == .ok)

        let initialized = try await pipes.ask(1, "initialize", ["protocolVersion": "2025-06-18"]) != nil
        #expect(initialized, "stderr: \(pipes.errors)")
        // The server waits up to `roleWait` (45 s) for its session's role, serving no tools meanwhile: asked again
        // until the lead's are there, for 50 s from here, each ask a round trip.
        let wanted: Set<String> = ["start_worker", "audit", "merge", "status"]
        var tools: [String] = []
        var id = 2
        _ = await eventuallyAsync(timeout: 50) {
            let listed = try? await pipes.ask(id, "tools/list", timeout: 5)
            id += 1
            tools = ((listed?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            return wanted.isSubset(of: tools)
        }
        #expect(wanted.isSubset(of: tools), "tools: \(tools); stderr: \(pipes.errors); host log: \(host.log)")

        // status answers with the scratch board: its project, its branch, no task.
        let result = try await pipes.ask(id, "tools/call", ["name": "status", "arguments": [String: Any]()])
        let text = ((result?["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        #expect(result?["isError"] as? Bool == false, "status: \(text.isEmpty ? "no answer" : text); stderr: \(pipes.errors)")
        #expect(text.contains("Project \(LeadMail.project(of: root)) on branch main — 0 task(s)"), "status: \(text)")
    }
}
