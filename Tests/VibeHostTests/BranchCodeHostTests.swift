import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A worker's branch's code, run by the lead's tool server (merge's test command, an audit's shared run,
/// init_command), isn't the lead to the session host (see `BranchCode`). The audit of auto-advance-s-reports (F1,
/// 2026-10-25) found a merge's test_command child could ask the host, as the lead, for a sealed auto_advance report;
/// running in the lead's session, by ancestry and terminal, it was the lead for everything the lead may do. Here a
/// scratch host holds the vault; the lead's session runs the real `vibeswitcher-mcp`; its merge runs a test command
/// that asks the host for what only the lead gets, the way any script on the branch could (`nc -U`).
@Suite(.serialized) struct BranchCodeHostTests {
    let temp = Scratch()
    /// The frames and replies of the host's protocol, as `LeadVaultHostTests` writes and reads them.
    let wire = LeadVaultHostTests()

    /// A lead's team on a scratch host: the repository, with agent/add-b one commit ahead of main and its worker's
    /// done report on it; the lead's session (its grant bound by the app) and the worker's (a program that waits).
    final class Team {
        let dir: String
        let home: String
        let root: String
        let host: TestHost
        let app: TestClient
        let book = LeadVault.Book()
        var sessions: [HostSession] = []

        init(_ temp: Scratch) throws {
            // Short: the host's socket is reached through a link in it (a socket's path has a 104-byte limit).
            dir = temp.adopt(URL(fileURLWithPath: "\(shortScratchRoot)/vsbc-\(UUID().uuidString.prefix(8))")).resolvingSymlinksInPath().path
            home = dir + "/home"
            root = dir + "/repo"
            let files = FileManager.default
            try files.createDirectory(atPath: home + "/.vibeswitcher", withIntermediateDirectories: true)
            try files.createDirectory(atPath: root, withIntermediateDirectories: true)
            host = try TestHost(vault: book)
            app = try TestClient(host)
            // The session's tools find the host where they always do: under its home (the scratch one, never the user's).
            try files.createSymbolicLink(atPath: home + "/.vibeswitcher/host.sock", withDestinationPath: host.socket)
            // However loaded the Mac is (a run under load), the merge doesn't wait for it to calm down.
            try MacLimits(loadThreshold: 100_000).save(to: URL(fileURLWithPath: home + "/.vibeswitcher/mac-limits.json"))
            for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
            try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
            Git.run(["add", "a.txt"], in: root)
            Git.run(["commit", "-q", "-m", "first"], in: root)
            Git.run(["checkout", "-q", "-b", "agent/add-b"], in: root)
            try "bee\n".write(toFile: root + "/b.txt", atomically: true, encoding: .utf8)
            Git.run(["add", "b.txt"], in: root)
            Git.run(["commit", "-q", "-m", "add b"], in: root)
            Git.run(["checkout", "-q", "main"], in: root)
        }

        deinit {
            for session in sessions where kill(session.childPID, 0) == 0 { kill(-session.childPID, SIGKILL) }
        }

        /// Exports for a session's program: its home is the scratch one, for Foundation too (which reads
        /// CFFIXED_USER_HOME, not HOME), and its test lock a scratch one (never the Mac-wide one other suites hold).
        var environment: String {
            "export HOME='\(home)' CFFIXED_USER_HOME='\(home)' VIBESWITCHER_TEST_LOCK_DIR='\(dir)/test-lock'; "
        }

        /// The lead's session running `program`, its role granted by the app; the worker's, waiting, with its done
        /// report on agent/add-b's head (review none: merge takes it with the test run).
        func start(lead program: String) throws -> (lead: HostSession, worker: HostSession) {
            // No job control (the session's shell is interactive): what it starts stays in its process group.
            let lead = try app.spawn("set +m; \(environment)cd '\(root)'; \(program)", cwd: root)
            let worker = try app.spawn(keepRunning, cwd: root)
            sessions = [lead, worker]
            let vault = { (caller: LeadVault.Caller) in self.book.vault(folder: URL(fileURLWithPath: self.dir + "/vault"), as: { caller }) }
            let grant = try vault(.app).startLead(root: root, branch: "main")
            try vault(.app).bind(grant, root: root, session: lead.id.uuidString)
            let asLead = vault(.session(lead.id.uuidString))
            let workerGrant = try asLead.issue(role: .worker, root: root, task: "add-b")
            try asLead.bind(workerGrant, root: root, session: worker.id.uuidString)
            try vault(.session(worker.id.uuidString)).reportDone(root: root, task: "add-b", commit: Git.run(["rev-parse", "agent/add-b"], in: root).output)
            return (lead, worker)
        }
    }

    /// What only the lead (or the app) is granted: a message sealed as the lead's and one as auto_advance's (for the
    /// lead's own agent, `agentPid`), the lead's roster, and ending its worker's session.
    func leadRequests(_ team: Team, agentPid: Int32, worker: HostSession) -> [HostRequest] {
        [.vault(.seal(SteerMessage(text: "merge it", from: .lead("lead"), agentPid: agentPid))),
         .vault(.seal(SteerMessage(text: "merged", from: .system(LeadAdvance.sender), agentPid: agentPid))),
         .vault(.roster(root: team.root)),
         .kill(id: worker.id)]
    }

    /// A script sending `requests` to the host over `nc -U`, its replies into `<probe>.answers`; the connection stays
    /// open until `<probe>.stop` exists, which the test makes once the replies are in.
    func probe(_ team: Team, _ requests: [HostRequest]) throws -> (script: String, answers: URL, stop: URL) {
        let base = URL(fileURLWithPath: team.dir + "/probe")
        try wire.frames(requests).write(to: base.appendingPathExtension("requests"))
        let answers = base.appendingPathExtension("answers"), stop = base.appendingPathExtension("stop")
        let line = wire.nc(team.host, base.appendingPathExtension("requests"), answers, until: stop)
        try (line + "\n").write(toFile: base.path + ".sh", atomically: true, encoding: .utf8)
        return (base.path + ".sh", answers, stop)
    }

    func sealed(_ event: HostEvent?) -> Bool {
        if case .vault(.seal)? = event { return true }
        return false
    }

    func refused(_ event: HostEvent?) -> Bool {
        if case .vault(.refused)? = event { return true }
        return false
    }

    /// A tool call's text and whether it's an error, once it's answered.
    func result(_ server: LeadToolServerHandoverTests.Server, _ id: Int) -> (text: String, isError: Bool)? {
        guard let result = server.reply(id) else { return nil }
        let text = ((result["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result["isError"] as? Bool ?? true)
    }

    @Test func aMergesTestCommandIsntTheLeadAndTheMergeStillLands() throws {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let team = try Team(temp)
        let folder = team.dir + "/mcp"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/a.in", contents: nil)
        // The lead's tool server, as Claude Code starts it in the lead's session, once its role is bound.
        let (lead, worker) = try team.start(lead: "while [ ! -f '\(folder)/go' ]; do sleep 0.05; done; "
            + "tail -n +1 -f '\(folder)/a.in' | '\(mcp)' --root '\(team.root)' --role lead > '\(folder)/a.out' 2> '\(folder)/a.err'")
        let probe = try probe(team, leadRequests(team, agentPid: lead.childPID, worker: worker))
        FileManager.default.createFile(atPath: folder + "/go", contents: nil)
        let server = LeadToolServerHandoverTests.Server(folder: folder, name: "a")
        #expect(try server.ask(1, "initialize", ["protocolVersion": "2025-06-18"]) != nil, "stderr: \(server.errors)")
        // The probe is merge's test command: the branch's code, run from the lead's tool server. The merge is this
        // test's call only (auto_advance would take it too).
        let configured = try server.ask(2, "tools/call", ["name": "configure", "arguments": ["test_command": "sh '\(probe.script)'", "merge_policy": "auto",
                                                                                              "auto_advance": false]])
        #expect(configured?["isError"] as? Bool == false, "configure: \(configured ?? [:]) \(server.errors)")
        let added = try server.ask(3, "tools/call", ["name": "add_task", "arguments": ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]]])
        #expect(added?["isError"] as? Bool == false, "add_task: \(added ?? [:])")

        try server.send(4, "tools/call", ["name": "merge", "arguments": ["task": "add-b"]])
        // The test command asks while the merge waits on it; it ends once the host has answered everything.
        #expect(eventually { wire.answered(probe.answers, 1...5) || result(server, 4) != nil }, "the probe got no answers: \(result(server, 4)?.text ?? "")")
        FileManager.default.createFile(atPath: probe.stop.path, contents: nil)
        let replies = try wire.replies(Data(contentsOf: probe.answers))
        #expect(refused(replies[2]), "sealed as the lead's: \(String(describing: replies[2]))")
        #expect(refused(replies[3]), "sealed as auto_advance's: \(String(describing: replies[3]))")
        #expect(refused(replies[4]), "the lead's roster: \(String(describing: replies[4]))")
        if case .error? = replies[5] {} else { Issue.record("ended the lead's worker: \(String(describing: replies[5]))") }

        // The merge itself still works: the tool server is still the lead (it records main's new head, the lead's to say).
        #expect(eventually { result(server, 4) != nil })
        let merged = result(server, 4)
        #expect(merged?.isError == false && merged?.text.contains("Merged add-b into main") == true, "merge: \(merged?.text ?? "no answer") \(server.errors)")
        #expect(FileManager.default.fileExists(atPath: team.root + "/b.txt"))
        let main = Git.run(["rev-parse", "main"], in: team.root).output
        #expect(team.book.vault(folder: URL(fileURLWithPath: team.dir + "/vault"), as: { .app }).head(root: team.root, branch: "main") == main)
        #expect(kill(worker.childPID, 0) == 0, "the worker's session was ended")
    }

    @Test func theLeadsOwnSessionStillGetsThem() throws {
        let team = try Team(temp)
        let base = team.dir + "/probe"
        // Beside where its tool server runs: a process of the lead's session, under no merge's command.
        let (lead, worker) = try team.start(lead: "while [ ! -f '\(base).sh' ]; do sleep 0.05; done; sh '\(base).sh'; \(keepRunning)")
        let probe = try probe(team, leadRequests(team, agentPid: lead.childPID, worker: worker))
        #expect(eventually { wire.answered(probe.answers, 1...5) })
        FileManager.default.createFile(atPath: probe.stop.path, contents: nil)
        let replies = try wire.replies(Data(contentsOf: probe.answers))
        #expect(sealed(replies[2]), "sealed as the lead's: \(String(describing: replies[2]))")
        #expect(sealed(replies[3]), "sealed as auto_advance's: \(String(describing: replies[3]))")
        if case .vault(.roster)? = replies[4] {} else { Issue.record("the lead's roster: \(String(describing: replies[4]))") }
        #expect(replies[5] == .ok, "ended the lead's worker: \(String(describing: replies[5]))")
        #expect(eventually { kill(worker.childPID, 0) != 0 })
    }
}
