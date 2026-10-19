import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A host that takes each connection and drops it, as one does through a handover (the client fds are close-on-exec)
/// or a stop: after the client's hello, before its welcome, or after the request that follows the welcome, before
/// any answer. Its socket is gone with it.
final class DroppingHost {
    enum Drop { case beforeWelcome, beforeReply }

    let path = "\(shortScratchRoot)/drop-\(UUID().uuidString.prefix(8)).sock"
    private let listener: Int32
    private let done = Flag()
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0

    /// The connections it took and dropped.
    var dropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    init(_ drop: Drop) throws {
        listener = try UnixSocket.listen(path: path)
        let listener = listener, path = path, done = done, finished = finished
        Thread.detachNewThread { [weak self] in
            defer {
                close(listener)
                unlink(path)
                finished.signal()
            }
            while !done.isSet {
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { usleep(5_000); continue }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                if let hello = Self.frame(fd), drop == .beforeReply,
                   let payload = try? HostCoding.encode(HostEventEnvelope(replyTo: hello.seq, event: .welcome(protocolVersion: HostProtocol.version, hostBuild: 0, sessions: []))) {
                    let frame = HostFrame.encode(.control, payload)
                    _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                    _ = Self.frame(fd)
                }
                close(fd)
                self?.lock.lock()
                self?.count += 1
                self?.lock.unlock()
            }
        }
    }

    /// The next request the client sends on `fd`; nil when it closes first or says nothing for 5 s.
    private static func frame(_ fd: Int32) -> HostRequestEnvelope? {
        var decoder = HostFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let frame = try? decoder.next() { return try? HostCoding.decode(HostRequestEnvelope.self, from: frame.payload) }
            let read = Darwin.read(fd, &buffer, buffer.count)
            guard read > 0 else { return nil }
            decoder.append(Data(buffer[0..<read]))
        }
    }

    deinit {
        done.set()
        _ = finished.wait(timeout: .now() + hangGuard)
    }
}

/// E-09: a host that drops the connection (a handover, a stop) is never a host with no sessions.
@Suite(.serialized) struct DroppedHostTests {
    @Test func aHostThatClosesBeforeItsWelcomeIsAnErrorNotNoSessions() throws {
        let host = try DroppingHost(.beforeWelcome)
        do {
            let sessions = try HostCall.sessions(socket: host.path, timeout: hangGuard)
            Issue.record("sessions() returned \(sessions.count) sessions, no error")
        } catch let failure as HostCall.Failure {
            #expect(failure.description.contains("closed the connection"), "\(failure)")
        }
        #expect(host.dropped == 1)
        // Every call that waits on it says so too, not a bare "didn't answer".
        #expect(throws: HostCall.Failure.self) { try HostCall.request(.screen(id: UUID()), socket: host.path, timeout: hangGuard) }
        #expect(throws: HostCall.Failure.self) { try HostCall.vault(.whoami(root: "/x"), socket: host.path, timeout: hangGuard) }
    }

    @Test func aHostThatClosesBeforeItsReplyIsAnError() throws {
        let host = try DroppingHost(.beforeReply)
        do {
            let reply = try HostCall.request(.screen(id: UUID()), socket: host.path, timeout: hangGuard)
            Issue.record("request() returned \(reply), no error")
        } catch let failure as HostCall.Failure {
            #expect(failure.description.contains("closed the connection"), "\(failure)")
        }
        // Input waits on the host reading it: one that drops it hasn't.
        #expect(throws: HostCall.Failure.self) {
            try HostCall.send(.input(id: UUID(), bytes: Data("x".utf8), reply: false), socket: host.path, timeout: hangGuard)
        }
        // The welcome came, so the list is the host's (it closing afterwards doesn't take it back).
        #expect(try HostCall.sessions(socket: host.path, timeout: hangGuard).isEmpty)
    }

    /// The real `vibeswitcher-mcp` in a lead's session on a scratch host, its runtime's host calls going to a host that
    /// drops each connection (VIBESWITCHER_MCP_TEST_RUNTIME_SOCKET; the vault stays on the scratch host): start_worker
    /// and cleanup refuse, the worker in the worktree is left alone. Then, with the host answering, the same calls see it.
    @Test func startWorkerAndCleanupRefuseWhileTheHostDropsTheConnection() throws {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let host = try ScratchHostProcess()
        let dropping = try DroppingHost(.beforeWelcome)
        var sessions: [HostSession] = []
        defer {
            for session in sessions where kill(session.childPID, 0) == 0 { kill(-session.childPID, SIGKILL) }
            host.stop()
        }
        // The vault is the host's, where the session's tools always find it: under its home.
        try FileManager.default.createDirectory(atPath: host.home + "/.vibeswitcher", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: host.home + "/.vibeswitcher/host.sock", withDestinationPath: host.socket)
        // The runtime's: the dropping host for now.
        let runtimeSocket = host.dir + "/runtime.sock"
        try FileManager.default.createSymbolicLink(atPath: runtimeSocket, withDestinationPath: dropping.path)
        let root = host.dir + "/repo"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)

        // Task one runs: its worker is a live session in its worktree.
        let worktree = Worktrees.path(root: root, slug: "one")
        #expect(Git.run(["worktree", "add", "-q", "-b", Worktrees.branch("one"), worktree], in: root).ok)
        let (app, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        let worker = try app.spawn(keepRunning, cwd: worktree)
        sessions.append(worker)
        try BoardStore(root: root).update { board in
            var task = LeadTask(slug: "one", title: "One", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: .running)
            task.worker = worker.id.uuidString
            task.worktree = worktree
            board.tasks.append(task)
        }

        let folder = host.dir + "/mcp"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/a.in", contents: nil)
        // Its home is the scratch one, for Foundation too (which reads CFFIXED_USER_HOME, not HOME): never the user's host.
        let lead = try app.spawn("set +m; export HOME='\(host.home)' CFFIXED_USER_HOME='\(host.home)' VIBESWITCHER_MCP_TEST_RUNTIME_SOCKET='\(runtimeSocket)'; "
            + "cd '\(root)'; while [ ! -f '\(folder)/go' ]; do sleep 0.05; done; "
            + "tail -n +1 -f '\(folder)/a.in' | '\(mcp)' --root '\(root)' --role lead > '\(folder)/a.out' 2> '\(folder)/a.err'", cwd: root)
        sessions.append(lead)
        guard case .grant(let grant)? = app.vault(.issue(role: .lead, root: root, task: nil, auditing: nil)) else {
            Issue.record("the app got no lead grant: \(host.log)"); return
        }
        #expect(app.vault(.bind(grant: grant, root: root, session: lead.id.uuidString)) == .ok)
        FileManager.default.createFile(atPath: folder + "/go", contents: nil)

        let server = LeadToolServerHandoverTests.Server(folder: folder, name: "a")
        #expect(try server.ask(1, "initialize", ["protocolVersion": "2025-06-18"]) != nil, "stderr: \(server.errors)")
        #expect(try server.tools(2).contains("cleanup"))
        func call(_ id: Int, _ tool: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool)? {
            guard let result = try server.ask(id, "tools/call", ["name": tool, "arguments": arguments]) else { return nil }
            let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return (text, result["isError"] as? Bool ?? true)
        }

        let start = try call(3, "start_worker", ["task": "one"])
        #expect(start?.isError == true && start?.text.contains("can't be read") == true, "start_worker: \(start?.text ?? "no answer")")
        let cleanup = try call(4, "cleanup", ["task": "one", "force": true])
        #expect(cleanup?.isError == true && cleanup?.text.contains("can't be read") == true, "cleanup: \(cleanup?.text ?? "no answer")")
        #expect(dropping.dropped >= 2)
        // Nothing was started, ended or removed: the worker still runs in its worktree.
        #expect(FileManager.default.fileExists(atPath: worktree))
        #expect(kill(worker.childPID, 0) == 0)
        #expect(app.screen(worker.id) != nil)
        #expect(BoardStore(root: root).load().task("one")?.worker == worker.id.uuidString)

        // The host answers again: the worker reads as running, so still no second one.
        try FileManager.default.removeItem(atPath: runtimeSocket)
        try FileManager.default.createSymbolicLink(atPath: runtimeSocket, withDestinationPath: host.socket)
        let again = try call(5, "start_worker", ["task": "one"])
        #expect(again?.isError == true && again?.text.contains("still running") == true, "start_worker: \(again?.text ?? "no answer")")
    }
}
