import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The real `vibeswitcher-mcp` through an install of a new build of itself (`MCPHandover`), end to end: a lead's and a
/// worker's sessions of a scratch host, each running a stand-in for Claude Code (a shell whose argv[0] is `claude`) with
/// its tool server, installed from a scratch copy of the built one as the app's is. The copy is replaced by another
/// one; each server switches to it in place, on the same pid and pipes, and the host still knows it as its session's:
/// the lead's status answers, its auto_advance loop holds its lock again and its sealed report verifies, and so does a
/// worker's report.
@Suite(.serialized) struct ToolServerSwitchTests {
    let temp = Scratch()

    /// One tool server in a session, talked to over files: lines appended to `<name>.in` (which it reads as Claude
    /// Code's pipe, `tail -f`), replies read from `<name>.out`, its stderr in `<name>.err` and its pid in `<name>.pid`.
    struct Server {
        let folder: String
        let name: String

        func write(_ message: [String: Any]) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: "\(folder)/\(name).in"))
            handle.seekToEndOfFile()
            handle.write(try JSONSerialization.data(withJSONObject: message) + Data([0x0A]))
            try handle.close()
        }

        var messages: [[String: Any]] {
            let text = (try? String(contentsOfFile: "\(folder)/\(name).out", encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }

        /// Asks and waits for the answer.
        func ask(_ id: Int, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any]? {
            try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            let reply = { messages.first { ($0["id"] as? Int) == id }?["result"] as? [String: Any] }
            _ = eventually { reply() != nil }
            return reply()
        }

        func initialize() throws -> Bool {
            let ok = try ask(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                               "clientInfo": ["name": "claude-code", "version": "test"]]) != nil
            try write(["jsonrpc": "2.0", "method": "notifications/initialized"])
            return ok
        }

        /// A tool call's text and whether it's an error.
        func call(_ id: Int, _ tool: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool)? {
            guard let result = try ask(id, "tools/call", ["name": tool, "arguments": arguments]) else { return nil }
            let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return (text, result["isError"] as? Bool ?? true)
        }

        /// A tool call once the toolset is settled: a call while the server still asks the host for its role (a loaded
        /// host may not answer its first whoami in time, see `MCPHostedToolset`) is answered `waiting`, and asked again
        /// as the next id. `id`: the next free one.
        func settledCall(_ id: inout Int, _ tool: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool)? {
            var answer: (text: String, isError: Bool)?
            _ = eventually {
                defer { id += 1 }
                answer = try? call(id, tool, arguments)
                return answer.map { $0.text != MCPHostedToolset.waiting } ?? false
            }
            return answer
        }

        var errors: String { (try? String(contentsOfFile: "\(folder)/\(name).err", encoding: .utf8)) ?? "" }
        var pid: pid_t? { (try? String(contentsOfFile: "\(folder)/\(name).pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    }

    /// The messages in a terminal's steer inbox, as posted.
    func inbox(_ vibe: String, tty: String) -> [SteerMessage] {
        let text = (try? String(contentsOfFile: "\(vibe)/steer/\(tty).jsonl", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(SteerMessage.self, from: Data($0.utf8)) }
    }

    @Test func theLeadsAndAWorkersServersKeepTheirRolesAndSealsThroughASwitch() throws {
        let built = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: built), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let files = FileManager.default
        let dir = temp.url("switch").path
        let home = dir + "/home", vibe = home + "/.vibeswitcher", folder = dir + "/mcp", root = dir + "/repo"
        for path in [vibe, folder, root, dir + "/app"] { try files.createDirectory(atPath: path, withIntermediateDirectories: true) }
        let book = LeadVault.Book()
        let host = try TestHost(vault: book)
        // The sessions' tools find the host where they always do: in VibeSwitcher's folder of their home.
        try files.createSymbolicLink(atPath: vibe + "/host.sock", withDestinationPath: host.socket)
        // The installed build, as the app's is: the servers run this file and watch it.
        let installed = dir + "/app/vibeswitcher-mcp"
        try files.copyItem(atPath: built, toPath: installed)

        // The project: a commit, and a repository config key the tool server's git doesn't run (so each loop's first
        // pass has something to tell the lead: what its git leaves out). One task, which nothing moves by itself.
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "core.pager", "cat"]] {
            Git.run(args, in: root)
        }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let store = BoardStore(root: root)
        try store.prepare()
        try store.update { board in
            var task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
            task.status = .running
            task.autoAdvance = false
            board.tasks.append(task)
        }

        let client = try TestClient(host)
        // Each session: a stand-in for Claude Code (argv[0] `claude`, so the tools find it as the session's agent),
        // starting its tool server once the test says, as Claude Code starts it for the session's role.
        func session(_ name: String, _ arguments: String) throws -> HostSession {
            files.createFile(atPath: "\(folder)/\(name).in", contents: nil)
            let script = "\(folder)/\(name).sh"
            try """
            while [ ! -f '\(folder)/go-\(name)' ]; do sleep 0.05; done
            tail -n +1 -f '\(folder)/\(name).in' | '\(installed)' --root '\(root)' \(arguments) > '\(folder)/\(name).out' 2> '\(folder)/\(name).err' &
            echo $! > '\(folder)/\(name).pid'
            wait
            """.write(toFile: script, atomically: true, encoding: .utf8)
            // Its home is the scratch one, for Foundation too (CFFIXED_USER_HOME) and VibeSwitcher's folder: never the user's.
            return try client.spawn("export HOME='\(home)' CFFIXED_USER_HOME='\(home)' VIBESWITCHER_HOME='\(vibe)'; cd '\(root)'; "
                                    + "exec /bin/bash -c 'exec -a claude /bin/bash \(script)'", cwd: root)
        }
        let leadSession = try session("lead", "--role lead")
        let workerSession = try session("worker", "--role worker --task t")
        // The app starts the lead; the lead, its worker.
        guard case .grant(let leadGrant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no lead grant"); return
        }
        #expect(book.answer(.bind(grant: leadGrant, root: root, session: leadSession.id.uuidString), from: .app) == .ok)
        let asLead = LeadVault.Caller.session(leadSession.id.uuidString)
        guard case .grant(let workerGrant) = book.answer(.issue(role: .worker, root: root, task: "t", auditing: nil), from: asLead) else {
            Issue.record("no worker grant"); return
        }
        #expect(book.answer(.bind(grant: workerGrant, root: root, session: workerSession.id.uuidString), from: asLead) == .ok)
        for name in ["lead", "worker"] { files.createFile(atPath: "\(folder)/go-\(name)", contents: nil) }

        let lead = Server(folder: folder, name: "lead"), worker = Server(folder: folder, name: "worker")
        #expect(try lead.initialize(), "lead's stderr: \(lead.errors)")
        #expect(try worker.initialize(), "worker's stderr: \(worker.errors)")
        var leadID = 2, workerID = 2
        let before = try lead.settledCall(&leadID, "status")
        #expect(before?.isError == false, "status: \(before?.text ?? "no answer"); stderr: \(lead.errors)")
        let leadPid = try #require(lead.pid), workerPid = try #require(worker.pid)
        // The servers end before the scratch folder goes: one still ending would write into it again.
        defer {
            for pid in [leadPid, workerPid] { kill(pid, SIGTERM) }
            #expect(eventually { kill(leadPid, 0) != 0 && kill(workerPid, 0) != 0 })
        }
        let leadTTY = try #require(store.load().leadTTY, "the lead didn't record itself on the board")

        // The loop runs in the lead's server: it holds its lock, and its first pass's report reaches the lead sealed.
        let advancing = LeadAdvance.runningLock(store)
        let fromLoop = { inbox(vibe, tty: leadTTY).filter { $0.from == .system(LeadAdvance.sender) } }
        #expect(eventually { !fromLoop().isEmpty }, "the lead's inbox: \(inbox(vibe, tty: leadTTY)); stderr: \(lead.errors)")
        #expect(FileLock.attempt(advancing) == nil, "the loop doesn't hold \(advancing)")
        let reportsBefore = fromLoop().count

        // The install: another build (another file) in its place, written beside it and renamed over it.
        try files.copyItem(atPath: built, toPath: dir + "/app/next")
        #expect(rename(dir + "/app/next", installed) == 0)
        // Each server switches between requests, an idle one within a second.
        #expect(eventually { lead.errors.contains("switched in place to the new build") && worker.errors.contains("switched in place to the new build") },
                "lead: \(lead.errors)\nworker: \(worker.errors)")
        #expect(!lead.errors.contains("couldn't switch") && !worker.errors.contains("couldn't switch"))
        // The same processes, on the same pipes, now the new build.
        #expect(kill(leadPid, 0) == 0 && kill(workerPid, 0) == 0)
        #expect(lead.pid == leadPid && worker.pid == workerPid)

        // The lead's server is still the lead's: status answers, its role is the same grant in the same session.
        let after = try lead.settledCall(&leadID, "status")
        #expect(after?.isError == false, "status: \(after?.text ?? "no answer"); stderr: \(lead.errors)")
        guard case .member(let current?) = book.answer(.current(role: .lead, root: root, task: nil), from: .app) else {
            Issue.record("the lead's role is gone after the switch"); return
        }
        #expect(current.id == leadGrant && current.session == leadSession.id.uuidString)
        // The new build's loop: its first pass reports again, sealed as auto_advance's, and it holds the lock again.
        #expect(eventually { fromLoop().count > reportsBefore }, "the lead's inbox: \(inbox(vibe, tty: leadTTY)); stderr: \(lead.errors)")
        #expect(FileLock.attempt(advancing) == nil, "the new build's loop doesn't hold \(advancing)")

        // The worker's server reports as its session's worker.
        let report = try worker.settledCall(&workerID, "report", ["status": "blocked", "summary": "Blocked on purpose (a test)."])
        #expect(report?.isError == false, "report: \(report?.text ?? "no answer"); stderr: \(worker.errors)")
        let fromWorker = { inbox(vibe, tty: leadTTY).filter { $0.from == .system("worker t") } }
        #expect(eventually { fromWorker().count == 1 }, "the lead's inbox: \(inbox(vibe, tty: leadTTY))")

        // Every one of them carries the host's seal for its sender.
        let sealed = fromLoop() + fromWorker()
        #expect(sealed.count > reportsBefore + 1 && sealed.allSatisfy { $0.seal != nil })
        #expect(book.answer(.verify(sealed), from: .unknown) == .verified(sealed.map { _ in true }))
    }
}
