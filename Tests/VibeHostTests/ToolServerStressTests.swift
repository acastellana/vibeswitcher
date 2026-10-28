import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Incident 4 (2026-10-27/28): the lead's tool server failed start_worker and cleanup with "Bad file descriptor", then
/// ended mid-session ("connection closed (cleanly)"). Out of descriptors, Foundation's `Pipe()` fails unseen (both its
/// handles hold fd 0, the server's stdin) and Process.run fails with that EBADF, as it does when it can't make its own.
/// The real `vibeswitcher-mcp`, in a lead's session on a scratch host, under many tool calls at once.
@Suite(.serialized, hostTestLimit) struct ToolServerStressTests {
    /// A lead's tool server on a scratch host, a repository whose board has a running task (`live`, its worker a
    /// session in its worktree) and finished ones with worktrees (`done-<n>`), as cleanup finds them.
    final class Rig {
        let host: ScratchHostProcess
        let root: String
        let folder: String
        let server: LeadToolServerHandoverTests.Server
        let pid: Int32
        private var sessions: [HostSession] = []
        private var next = 100
        let finished: Int

        /// `limit`: the server's soft limit on open files (`ulimit -n`), none set when nil.
        init(limit: Int? = nil, finished: Int = 8) throws {
            let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
            try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
            self.finished = finished
            host = try ScratchHostProcess()
            // The session's tools find the host where they always do: under its home.
            try FileManager.default.createDirectory(atPath: host.home + "/.vibeswitcher", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: host.home + "/.vibeswitcher/host.sock", withDestinationPath: host.socket)
            // Over the load limit always: audit refuses before it starts a verifier (see `refusesAudits`).
            try MacLimits(loadThreshold: Self.anyLoad).save(to: URL(fileURLWithPath: host.home + "/.vibeswitcher/mac-limits.json"))
            let root = host.dir + "/repo"
            self.root = root
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
            try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
            Git.run(["add", "a.txt"], in: root)
            Git.run(["commit", "-q", "-m", "first"], in: root)

            let worktree = Worktrees.path(root: root, slug: "live")
            #expect(Git.run(["worktree", "add", "-q", "-b", Worktrees.branch("live"), worktree], in: root).ok)
            for index in 1...finished {
                let slug = "done-\(index)"
                #expect(Git.run(["worktree", "add", "-q", "-b", Worktrees.branch(slug), Worktrees.path(root: root, slug: slug)], in: root).ok)
            }
            let (app, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
            let worker = try app.spawn(keepRunning, cwd: worktree)
            sessions.append(worker)
            try BoardStore(root: root).update { board in
                var task = LeadTask(slug: "live", title: "Live", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: .running)
                task.worker = worker.id.uuidString
                task.worktree = worktree
                board.tasks.append(task)
                for index in 1...finished {
                    var done = LeadTask(slug: "done-\(index)", title: "Done \(index)", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: .done)
                    done.worktree = Worktrees.path(root: root, slug: "done-\(index)")
                    board.tasks.append(done)
                }
            }

            let folder = host.dir + "/mcp"
            self.folder = folder
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder + "/a.in", contents: nil)
            let courier = try Courier(host.dir + "/lead-courier", socket: host.socket)
            // Its home is the scratch one, for Foundation too (which reads CFFIXED_USER_HOME, not HOME): never the user's
            // host. No job control: the server stays in the session's process group, which the end kills.
            let ulimit = limit.map { "ulimit -n \($0); " } ?? ""
            let lead = try app.spawn("set +m; (\(courier.command)) & export HOME='\(host.home)' CFFIXED_USER_HOME='\(host.home)'; "
                + "cd '\(root)'; while [ ! -f '\(folder)/go' ]; do sleep 0.05; done; \(ulimit)"
                + "tail -n +1 -f '\(folder)/a.in' | '\(mcp)' --root '\(root)' --role lead > '\(folder)/a.out' 2> '\(folder)/a.err' & "
                + "echo $! > '\(folder)/pid'; wait", cwd: root)
            sessions.append(lead)
            guard case .grant(let grant)? = app.vault(.issue(role: .lead, root: root, task: nil, auditing: nil)) else {
                throw TestClient.NoWelcome(description: "the app got no lead grant: \(host.log)")
            }
            #expect(app.vault(.bind(grant: grant, root: root, session: lead.id.uuidString)) == .ok)
            // The worker is a member of the lead's team, as start_worker checks.
            let issued = try courier.send([.vault(.issue(role: .worker, root: root, task: "live", auditing: nil))])
            guard case .vault(.grant(let workerGrant))? = issued[2] else {
                throw TestClient.NoWelcome(description: "the scratch lead could not issue its worker grant")
            }
            #expect(try courier.send([.vault(.bind(grant: workerGrant, root: root, session: worker.id.uuidString))])[2] == .vault(.ok))
            FileManager.default.createFile(atPath: folder + "/go", contents: nil)

            server = LeadToolServerHandoverTests.Server(folder: folder, name: "a")
            var started: Int32?
            #expect(eventually { started = (try? String(contentsOfFile: folder + "/pid", encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }; return started != nil })
            pid = try #require(started)
            #expect(try server.ask(1, "initialize", ["protocolVersion": "2025-06-18"]) != nil, "stderr: \(server.errors)")
            server.notify("notifications/initialized")
            #expect(try server.tools(2).contains("cleanup"), "stderr: \(server.errors)")
        }

        deinit {
            for session in sessions where kill(session.childPID, 0) == 0 { kill(-session.childPID, SIGKILL) }
            host.stop()
        }

        /// The server's open descriptors now.
        var descriptors: Int? { MCPLog.openDescriptors(pid: pid) }

        /// Its log (`MCPLog`), under the scratch home.
        var log: String {
            (try? String(contentsOf: MCPLog.file(role: "lead", pid: pid, root: URL(fileURLWithPath: host.home + "/.vibeswitcher")), encoding: .utf8)) ?? ""
        }

        /// Sends every call at once (the server runs each on a thread of its own) and waits for all their answers:
        /// each call's text and whether it's an error, nil for one that got no answer.
        func burst(_ calls: [(tool: String, arguments: [String: Any])]) throws -> [(text: String, isError: Bool)?] {
            let ids = calls.map { _ in next += 1; return next }
            var lines = Data()
            for (id, call) in zip(ids, calls) {
                lines += try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                                                      "params": ["name": call.tool, "arguments": call.arguments]]) + Data([0x0A])
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: folder + "/a.in"))
            handle.seekToEndOfFile()
            handle.write(lines)
            try handle.close()
            _ = eventually { Set(server.replies().keys).isSuperset(of: ids) || !alive }
            let replies = server.replies()
            return ids.map { id in
                replies[id].map { result in
                    (((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n"),
                     result["isError"] as? Bool ?? true)
                }
            }
        }

        var alive: Bool { kill(pid, 0) == 0 }

        /// The rig's load_threshold, under any 1-minute load a running Mac has: audit refuses at it after its git and host
        /// calls, before it starts a verifier. Under the threshold (2026-10-28, two merges' full runs hung 45 min) each
        /// burst's audit started a verifier session on the scratch host, waited on Claude's trust question (15 s) and
        /// its tools (`roleWait`, 45 s) and ended it: a minute a burst on a calm Mac, past the hang guard on a busy one,
        /// and each of the test's later waits then waited out its own.
        static let anyLoad = 0.001

        /// A round of the lead's calls, interleaved: start_worker (refused: its worker runs), cleanup of finished
        /// tasks (git runs for each), status, an audit refused (the Mac over the rig's load limit, `anyLoad`), and a call
        /// for no task.
        func round(_ copies: Int = 1) -> [(tool: String, arguments: [String: Any])] {
            var calls: [(tool: String, arguments: [String: Any])] = []
            for copy in 0..<copies {
                calls.append(("start_worker", ["task": "live"]))
                calls.append(("cleanup", ["task": "done-\(copy % finished + 1)"]))
                calls.append(("status", [:]))
                calls.append(("audit", ["task": "live"]))
                calls.append(("cleanup", ["task": "done-\((copy + 3) % finished + 1)"]))
                calls.append(("start_worker", ["task": "nothing-\(copy)"]))
            }
            return calls
        }
    }

    /// Many interleaved start_worker, cleanup, status and refused audit calls at once, while other clients call the
    /// host: every call is answered, none with EBADF, the server answers after, and its descriptors are as before.
    @Test func manyCallsAtOnceLeaveTheServerAnsweringWithItsDescriptorsAsBefore() throws {
        let rig = try Rig()
        // A first round opens what stays open (the folder watch, the dispatch queues' kqueue): counted from after it.
        let round = rig.round(2)
        let first = try rig.burst(round)
        try #require(first.allSatisfy { $0 != nil }, "unanswered in the first round; stderr: \(rig.server.errors)")
        // Each audit was refused before it started a verifier (none waited on one's tools).
        let audits = zip(round, first).filter { $0.0.tool == "audit" }.map { $0.1?.text ?? "" }
        #expect(audits.count == 2 && audits.allSatisfy(Self.refusesAudits), "audit: \(audits)")
        var base: Int?
        #expect(eventually { base = rig.descriptors; return base != nil })
        let before = try #require(base)

        // Other clients of the host meanwhile, as the app and other tool servers are.
        let stop = Flag()
        let callers = DispatchGroup()
        for _ in 0..<4 {
            callers.enter()
            Thread.detachNewThread {
                while !stop.isSet { _ = try? HostCall.sessions(socket: rig.host.socket, appKey: rig.host.appKey, timeout: hangGuard) }
                callers.leave()
            }
        }
        var answers: [(text: String, isError: Bool)?] = []
        // A burst with a call unanswered waited out its hang guard: the next would too, so the test ends its bursts there.
        for _ in 0..<5 where answers.allSatisfy({ $0 != nil }) { answers += try rig.burst(rig.round(4)) }
        stop.set()
        _ = callers.wait(timeout: .now() + hangGuard)

        #expect(answers.allSatisfy { $0 != nil }, "\(answers.filter { $0 == nil }.count) of \(answers.count) calls got no answer; stderr: \(rig.server.errors)")
        let broken = answers.compactMap { $0 }.filter { Self.saysBadDescriptor($0.text) }
        #expect(broken.isEmpty, "EBADF: \(broken.prefix(3))")
        #expect(!Self.saysBadDescriptor(rig.server.errors) && !Self.saysBadDescriptor(rig.log), "stderr: \(rig.server.errors)\nlog: \(rig.log)")
        // Still answering.
        #expect(try rig.server.ask(1_000, "ping") != nil)
        let status = try rig.burst([("status", [:])])
        #expect(status.first??.isError == false, "status: \(String(describing: status.first))")
        // Flat: what the calls opened is closed once they're done (their readers and connections end as they do).
        var after: Int?
        let flat = eventually(timeout: 60) { after = rig.descriptors; return (after ?? .max) <= before + 4 }
        #expect(flat, "descriptors went from \(before) to \(after.map(String.init) ?? "?") after \(answers.count) calls")
        #expect(rig.log.contains("started: pid \(rig.pid)"), "log: \(rig.log)")
    }

    /// Out of descriptors (a low limit, many calls at once): the calls that can't start their commands say so (EMFILE),
    /// none fails with EBADF, the server's input isn't touched, and it answers once they're done.
    @Test func outOfDescriptorsTheServerSaysSoAndServesOn() throws {
        let rig = try Rig(limit: Self.lowLimit)
        var exhausted = false
        var answers: [(text: String, isError: Bool)?] = []
        for _ in 0..<6 where !exhausted && rig.alive && answers.allSatisfy({ $0 != nil }) {
            answers += try rig.burst(rig.round(16))
            exhausted = rig.log.contains("EMFILE")
        }
        // The point of the test: the calls did run out (else it says nothing of the incident).
        #expect(exhausted, "no call ran out of descriptors at limit \(Self.lowLimit); answers: \(answers.prefix(6)); log: \(rig.log.suffix(2_000))")
        #expect(rig.alive, "the tool server ended; log: \(rig.log)\nstderr: \(rig.server.errors)")
        let broken = answers.compactMap { $0 }.filter { Self.saysBadDescriptor($0.text) }
        #expect(broken.isEmpty, "\(broken.count) calls failed with EBADF, e.g. \(broken.first?.text ?? "")")
        #expect(answers.allSatisfy { $0 != nil }, "\(answers.filter { $0 == nil }.count) of \(answers.count) calls got no answer; log: \(rig.log)")
        #expect(!rig.log.contains("EBADF") && !Self.servingEnded(rig.log), "log: \(rig.log)")
        // The board kept every task (a read that failed for want of a descriptor isn't an empty board).
        #expect(BoardStore(root: rig.root).load().tasks.count == 1 + rig.finished)
        // Once the burst is over it serves as before.
        #expect(try rig.server.ask(2_000, "ping") != nil, "log: \(rig.log)")
        let status = try rig.burst([("status", [:])])
        #expect(status.first??.isError == false, "status: \(String(describing: status.first))")
    }

    /// Room for the server's own (stdio, its log, the folder watch, dispatch) and a few calls' commands at once.
    static let lowLimit = 32

    /// The log says the input loop ended (`MCPServer.serve`'s exits).
    static func servingEnded(_ log: String) -> Bool {
        log.contains("; ending") || log.contains("serve: input ended") || log.contains("serve: stopped")
    }

    /// An audit refused for the Mac's load (`macRefusal`), no verifier started.
    static func refusesAudits(_ text: String) -> Bool {
        text.hasPrefix("No verifier started") && text.contains("load_threshold")
    }

    static func saysBadDescriptor(_ text: String) -> Bool {
        text.contains("Bad file descriptor") || text.contains("NSPOSIXErrorDomain Code=9")
    }
}

extension LeadToolServerHandoverTests.Server {
    /// The results so far, by request id.
    func replies() -> [Int: [String: Any]] {
        let text = (try? String(contentsOfFile: "\(folder)/\(name).out", encoding: .utf8)) ?? ""
        var found: [Int: [String: Any]] = [:]
        for line in text.split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = object["id"] as? Int, let result = object["result"] as? [String: Any] else { continue }
            found[id] = result
        }
        return found
    }

    /// A notification (no answer comes).
    func notify(_ method: String) {
        guard let line = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method]),
              let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "\(folder)/\(name).in")) else { return }
        handle.seekToEndOfFile()
        handle.write(line + Data([0x0A]))
        try? handle.close()
    }
}
