import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The Mac-wide limits as two projects' leads count them on one host (2026-10-28): since PR #1 the host lists a lead
/// only its own team, and each lead's status read the Mac as holding its own workers alone ("5 team sessions across
/// 1 project" with 9 running across 3), so start_worker went past mac_max_sessions. Each lead's real tool server, in a
/// session of a scratch host, now counts both projects' workers from the host's census, while the host still keeps
/// the other project's sessions from it: their screens, attaching to them and typing into them are refused.
@Suite(.serialized) struct MacCensusHostTests {
    let temp = Scratch()

    @Test func eachLeadCountsBothProjectsWorkersButReachesOnlyItsOwn() throws {
        let built = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: built), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let files = FileManager.default
        let dir = temp.url("census").path
        let home = dir + "/home", folder = dir + "/mcp"
        // VibeSwitcher's folder, where the host's socket is: short (a socket's path has a 104-byte limit).
        let vibe = temp.adopt(URL(fileURLWithPath: "\(shortScratchRoot)/vscn-\(UUID().uuidString.prefix(8))")).path
        for path in [vibe, folder, home] { try files.createDirectory(atPath: path, withIntermediateDirectories: true) }
        let book = LeadVault.Book()
        let host = try TestHost(vault: book)
        try files.createSymbolicLink(atPath: vibe + "/host.sock", withDestinationPath: host.socket)
        let app = try TestClient(host)
        defer { app.close() }

        // Two projects, each a repository with a commit and an empty board, and their workers' worktrees.
        let projects = [(name: "alpha", workers: ["a-one", "a-two"]), (name: "beta", workers: ["b-one"])]
        for project in projects {
            let root = dir + "/" + project.name
            for worker in project.workers {
                try files.createDirectory(atPath: Worktrees.path(root: root, slug: worker), withIntermediateDirectories: true)
            }
            for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "core.pager", "cat"]] {
                Git.run(args, in: root)
            }
            try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
            Git.run(["add", "a.txt"], in: root)
            Git.run(["commit", "-q", "-m", "first"], in: root)
            try BoardStore(root: root).prepare()
        }

        // Each lead: a stand-in for Claude Code (argv[0] `claude`) running its tool server once the test says, and a
        // courier in the same session that sends the host what the test gives it, as any script of the lead's could.
        var leads: [String: (session: HostSession, courier: Courier, server: ToolServerSwitchTests.Server)] = [:]
        var workers: [String: [HostSession]] = [:]
        for project in projects {
            let root = dir + "/" + project.name, name = project.name
            let courier = try Courier("\(folder)/courier-\(name)", socket: host.socket)
            files.createFile(atPath: "\(folder)/\(name).in", contents: nil)
            let script = "\(folder)/\(name).sh"
            try """
            \(courier.command) &
            while [ ! -f '\(folder)/go-\(name)' ]; do sleep 0.05; done
            tail -n +1 -f '\(folder)/\(name).in' | '\(built)' --root '\(root)' --role lead > '\(folder)/\(name).out' 2> '\(folder)/\(name).err' &
            echo $! > '\(folder)/\(name).pid'
            wait
            """.write(toFile: script, atomically: true, encoding: .utf8)
            // Its home is the scratch one, for Foundation too (CFFIXED_USER_HOME) and VibeSwitcher's folder: never the user's.
            let session = try app.spawn("export HOME='\(home)' CFFIXED_USER_HOME='\(home)' VIBESWITCHER_HOME='\(vibe)'; cd '\(root)'; "
                                        + "exec /bin/bash -c 'exec -a claude /bin/bash \(script)'", cwd: root, label: "Lead · \(name)")
            // The app starts the lead; the lead, its workers (scratch programs in their worktrees, as the lead names them).
            guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
                Issue.record("no lead grant for \(name)"); return
            }
            #expect(book.answer(.bind(grant: grant, root: root, session: session.id.uuidString), from: .app) == .ok)
            let asLead = LeadVault.Caller.session(session.id.uuidString)
            for slug in project.workers {
                let worker = try app.spawn("echo SYNTHETIC_\(slug); exec /bin/cat", cwd: Worktrees.path(root: root, slug: slug), label: "Worker: \(slug)")
                guard case .grant(let workerGrant) = book.answer(.issue(role: .worker, root: root, task: slug, auditing: nil), from: asLead) else {
                    Issue.record("no worker grant for \(slug)"); return
                }
                #expect(book.answer(.bind(grant: workerGrant, root: root, session: worker.id.uuidString), from: asLead) == .ok)
                workers[name, default: []].append(worker)
            }
            leads[name] = (session, courier, ToolServerSwitchTests.Server(folder: folder, name: name))
        }
        for project in projects { files.createFile(atPath: "\(folder)/go-\(project.name)", contents: nil) }
        // The servers end before the scratch folder goes: one still ending would write into it again.
        defer {
            let pids = leads.values.compactMap { $0.server.pid }
            for pid in pids { kill(pid, SIGTERM) }
            #expect(eventually { pids.allSatisfy { kill($0, 0) != 0 } })
        }

        for (name, other) in [("alpha", "beta"), ("beta", "alpha")] {
            let lead = try #require(leads[name])
            // Its status counts both projects' workers (the leads aren't team sessions the cap counts).
            #expect(try lead.server.initialize(), "\(name)'s stderr: \(lead.server.errors)")
            var id = 2
            let status = try lead.server.settledCall(&id, "status")
            #expect(status?.isError == false, "status: \(status?.text ?? "no answer"); stderr: \(lead.server.errors)")
            // Naming only its own project: the status is the lead's, and what a lead is told can go into its repo's records.
            let mine = name == "alpha" ? "this one 2, 1 other 1" : "this one 1, 1 other 2"
            #expect(status?.text.contains("3 team sessions across 2 projects (\(mine)) (mac_max_sessions 10)") == true,
                    "\(name)'s status: \(status?.text ?? "no answer")")

            // The host still lists it only its own team, and refuses it the other project's sessions.
            let own = try #require(workers[name]?.first), stranger = try #require(workers[other]?.first)
            let answers = try lead.courier.send([
                .input(id: stranger.id, bytes: Data("synthetic-cross-project-input\n".utf8), reply: false),
                .screen(id: own.id),
                .screen(id: stranger.id),
                .attach(id: stranger.id, cols: 80, rows: 24),
                .inputUnit(id: stranger.id, writes: [.init(bytes: Array("synthetic-cross-project-unit\n".utf8), delay: 0)], more: false),
            ])
            guard case .welcome(_, _, let visible, _, _, _)? = answers[1] else { Issue.record("\(name): no welcome"); continue }
            #expect(Set(visible.map(\.id)) == Set([lead.session.id] + (workers[name] ?? []).map(\.id)), "\(name) sees \(visible.map(\.label))")
            #expect(answers[2] == .error(HostProtocol.unauthorized), "\(name)'s input into \(other)'s worker: \(String(describing: answers[2]))")
            guard case .screenText? = answers[3] else { Issue.record("\(name) can't read its own worker: \(String(describing: answers[3]))"); continue }
            for seq in 4...6 {
                #expect(answers[seq] == .error(HostProtocol.unauthorized), "\(name)'s request \(seq) on \(other)'s worker: \(String(describing: answers[seq]))")
            }
        }
        // Nothing reached the other project's workers.
        for worker in workers.values.flatMap({ $0 }) {
            #expect(!(app.screen(worker.id) ?? "").contains("synthetic-cross-project"))
        }
    }

    /// The census is counts by repository and role, for the app and any live session (one with no role in any team
    /// too); a connection that's neither gets nothing.
    @Test func theCensusIsCountsForTheAppAndAnySessionAndNothingForAStranger() throws {
        let host = try TestHost(vault: LeadVault.Book())
        let app = try TestClient(host)
        defer { app.close() }
        let root = temp.url("repo").path
        for slug in ["one", "two"] { try FileManager.default.createDirectory(atPath: Worktrees.path(root: root, slug: slug), withIntermediateDirectories: true) }
        let courier = try Courier(temp.url("courier").path, socket: host.socket)
        let plain = try app.spawn(courier.command)
        let sessions = [try app.spawn(keepRunning, cwd: root, label: "Lead · repo"),
                        try app.spawn(keepRunning, cwd: Worktrees.path(root: root, slug: "one"), label: "Worker: one"),
                        try app.spawn(keepRunning, cwd: Worktrees.path(root: root, slug: "two"), label: "Worker: two"),
                        try app.spawn(keepRunning, cwd: Worktrees.path(root: root, slug: "one"), label: "Verifier: one"),
                        try app.spawn("exit 0", cwd: Worktrees.path(root: root, slug: "two"), label: "Worker: two")]
        defer { for session in sessions + [plain] { _ = app.send(.kill(id: session.id)) } }
        #expect(eventually { app.latest(sessions[4].id)?.isLive == false })
        let expected = [HostCensus(root: root, role: .lead, sessions: 1), HostCensus(root: root, role: .verifier, sessions: 1),
                        HostCensus(root: root, role: .worker, sessions: 2)]

        let asked = app.send(.census)
        #expect(eventually { app.reply(to: asked) != nil })
        #expect(app.reply(to: asked) == .census(expected))
        let answers = try courier.send([.census])
        #expect(answers[2] == .census(expected), "\(String(describing: answers[2]))")
        // The session sees none of them listed: only the counts.
        guard case .welcome(_, _, let visible, _, _, _)? = answers[1] else { Issue.record("no welcome"); return }
        #expect(visible.map(\.id) == [plain.id])

        let stranger = try TestClient(host, asApp: false)
        defer { stranger.close() }
        let refused = stranger.send(.census)
        #expect(eventually { stranger.reply(to: refused) != nil })
        #expect(stranger.reply(to: refused) == .error(HostProtocol.unauthorized))
    }
}
