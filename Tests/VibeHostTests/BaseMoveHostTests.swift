import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The session host records a session's git commands under the session its process is in (as the hooks' connection
/// is told apart), and counts them as the user's only for a session the app opened that holds no role in the team.
extension LeadVaultHostTests {
    func gitRepo() throws -> String {
        let repo = folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let root = repo.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "commit.gpgsign", "false"]] {
            Git.run(args, in: root)
        }
        try commit("a.txt", in: root)
        return root
    }

    @discardableResult
    func commit(_ file: String, in root: String) throws -> String {
        try "\(file)\n".write(toFile: root + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: root)
        #expect(Git.run(["commit", "-q", "-m", "add \(file)"], in: root).ok)
        return Git.run(["rev-parse", "HEAD"], in: root).output
    }

    /// A shell for a session: once `<name>.go` exists it sends `<name>.requests` to the host over `nc -U`, as a
    /// session's hooks do, and keeps running.
    func hooksShell(_ host: TestHost, _ name: String) throws -> String {
        let base = folder.appendingPathComponent(name)
        let script = base.appendingPathExtension("sh").path
        try """
        while [ ! -f '\(base.path).go' ]; do sleep 0.05; done
        \(nc(host, base.appendingPathExtension("requests"), base.appendingPathExtension("answers"), until: base.appendingPathExtension("stop")))
        sleep 30
        """.write(toFile: script, atomically: true, encoding: .utf8)
        return "sh '\(script)'"
    }

    /// The session's hooks say it ran `git commit` on main, from `before` to `after`: sent, and answered.
    func hooksSay(_ name: String, root: String, before: String, after: String) throws -> [Int: HostEvent] {
        let base = folder.appendingPathComponent(name)
        try frames([.vault(.ranGit(root: root, step: LeadVault.GitStep(phase: .before, call: "t", verb: "commit", branch: "main", head: before))),
                    .vault(.ranGit(root: root, step: LeadVault.GitStep(phase: .after, call: "t", verb: "commit", branch: "main", head: after)))])
            .write(to: base.appendingPathExtension("requests"))
        FileManager.default.createFile(atPath: base.path + ".go", contents: nil)
        let answers = base.appendingPathExtension("answers")
        #expect(eventually { answered(answers, 2...3) }, "\(name)")
        FileManager.default.createFile(atPath: base.path + ".stop", contents: nil)
        return try replies(Data(contentsOf: answers))
    }

    func move(_ book: LeadVault.Book, _ root: String) -> LeadVault.BaseMove? {
        if case .move(let move) = book.answer(.acceptMove(root: root, branch: "main"), from: .app) { return move }
        return nil
    }

    /// The session's shell sends `requests` to the host (as anything running in it could), once; the replies to
    /// `seqs` are waited for, or (nil) `until` holds.
    func sessionSends(_ name: String, _ requests: [HostRequest], expecting seqs: ClosedRange<Int>?, until: () -> Bool = { true }) throws -> [Int: HostEvent] {
        let base = folder.appendingPathComponent(name)
        try frames(requests).write(to: base.appendingPathExtension("requests"))
        FileManager.default.createFile(atPath: base.path + ".go", contents: nil)
        let answers = base.appendingPathExtension("answers")
        if let seqs { #expect(eventually { answered(answers, seqs) }, "\(name)") }
        let held = eventually(until)
        #expect(held, "\(name)")
        FileManager.default.createFile(atPath: base.path + ".stop", contents: nil)
        return (try? replies(Data(contentsOf: answers))) ?? [:]
    }

    func step(_ phase: LeadVault.GitStep.Phase, _ root: String, _ head: String) -> HostRequest {
        .vault(.ranGit(root: root, step: LeadVault.GitStep(phase: phase, call: "t", verb: "commit", branch: "main", head: head)))
    }

    /// F-L3r: a worker's Bash types into an idle session of yours (outside the team, so the host lets it), say
    /// `git cherry-pick <sha>`. What that session then runs is the worker's say, not yours: the commit it makes on the
    /// base is asked about at the next merge, even once the session types into itself or you type into it after.
    /// Your own keys and the session's own terminal leave it yours.
    @Test func aWorkersKeysInYourSessionMakeWhatItCommitsNotYours() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try gitRepo()
        let log = folder.appendingPathComponent("host.log").path
        let logged = { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, appExecutable: try #require(HostServer.executable(of: getpid())), log: log)
        let app = try TestClient(host)
        let lead = try app.spawn("sleep 30")
        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no lead grant"); return
        }
        #expect(book.answer(.bind(grant: grant, root: root, session: lead.id.uuidString), from: .app) == .ok)
        let worker = try app.spawn(try hooksShell(host, "typist"))
        guard case .grant(let workerGrant) = book.answer(.issue(role: .worker, root: root, task: "t", auditing: nil), from: .session(lead.id.uuidString)) else {
            Issue.record("no worker grant"); return
        }
        #expect(book.answer(.bind(grant: workerGrant, root: root, session: worker.id.uuidString), from: .session(lead.id.uuidString)) == .ok)
        var left = Git.run(["rev-parse", "main"], in: root).output
        #expect(book.answer(.setHead(root: root, branch: "main", commit: left), from: .app) == .ok)

        // Yours: you type into it (the app), and it types into itself (its own terminal). Its commit is taken.
        let mine = try app.spawn(try hooksShell(host, "mine"))
        app.send(.input(id: mine.id, bytes: Data("commit it\r".utf8), reply: false))
        var made = try commit("b.txt", in: root)
        var got = try sessionSends("mine", [.input(id: mine.id, bytes: Data("\r".utf8), reply: false), step(.before, root, left), step(.after, root, made)],
                                   expecting: 3...4)
        #expect(got[3] == .vault(.ok) && got[4] == .vault(.ok), "\(got)")
        #expect(move(book, root)?.accepted == true)
        #expect(book.answer(.head(root: root, branch: "main"), from: .app) == .head(made))
        #expect(!logged().contains("input to \(HostServer.short(mine.id))"))
        left = made

        // The worker's Bash types `git cherry-pick` into another idle session of yours, over the host's socket.
        let idle = try app.spawn(try hooksShell(host, "idle"))
        _ = try sessionSends("typist", [.input(id: idle.id, bytes: Data("git cherry-pick \(left)\r".utf8), reply: false)], expecting: nil) {
            logged().contains("input to \(HostServer.short(idle.id)) from session \(worker.id.uuidString.prefix(8)), not the app")
        }
        // You type into it after, and it types into itself (its shell running what it was sent): still the worker's say.
        app.send(.input(id: idle.id, bytes: Data("\r".utf8), reply: false))
        made = try commit("c.txt", in: root)
        got = try sessionSends("idle", [.input(id: idle.id, bytes: Data("\r".utf8), reply: false), step(.before, root, left), step(.after, root, made)],
                               expecting: 3...4)
        #expect(got[3] == .vault(.ok) && got[4] == .vault(.ok), "\(got)")
        // Refused at the merge, and asked about (the window's card: not taken, nothing still running, the session named).
        let asked = try #require(move(book, root))
        #expect(!asked.accepted && asked.waiting != true, "\(asked)")
        #expect(asked.reason?.contains(String(idle.id.uuidString.prefix(8))) == true, "\(asked.reason ?? "")")
        #expect(book.answer(.head(root: root, branch: "main"), from: .app) == .head(left))
        // Through the host, as the app asks at merge: the same.
        let seq = app.send(.vault(.acceptMove(root: root, branch: "main")))
        #expect(eventually { app.reply(to: seq) != nil })
        guard case .vault(.move(let viaHost))? = app.reply(to: seq) else { Issue.record("\(String(describing: app.reply(to: seq)))"); return }
        #expect(!viaHost.accepted)
        #expect(logged().contains("vault: didn't take main at \(made.prefix(8))"))
    }

    @Test func gitCommandsCountAsYoursOnlyFromASessionTheAppOpenedOutsideTheTeam() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try gitRepo()
        let log = folder.appendingPathComponent("host.log").path
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, appExecutable: try #require(HostServer.executable(of: getpid())), log: log)
        let app = try TestClient(host)
        let other = try TestClient(host, asApp: false)
        let lead = try app.spawn("sleep 30")
        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no lead grant"); return
        }
        #expect(book.answer(.bind(grant: grant, root: root, session: lead.id.uuidString), from: .app) == .ok)
        var left = Git.run(["rev-parse", "main"], in: root).output
        #expect(book.answer(.setHead(root: root, branch: "main", commit: left), from: .app) == .ok)

        // A session something other than the app asked for (a script of a worker's could): not yours.
        let stranger = try other.spawn(try hooksShell(host, "stranger"))
        var made = try commit("b.txt", in: root)
        var got = try hooksSay("stranger", root: root, before: left, after: made)
        #expect(got[2] == .vault(.ok) && got[3] == .vault(.ok), "\(got)")
        #expect(move(book, root)?.accepted == false)
        #expect(move(book, root)?.reason?.contains(String(stranger.id.uuidString.prefix(8))) == true)
        // (You accept it in the app.)
        #expect(book.answer(.setHead(root: root, branch: "main", commit: made), from: .app) == .ok)
        left = made

        // A session the app opened that holds the worker's role.
        let worker = try app.spawn(try hooksShell(host, "worker"))
        guard case .grant(let workerGrant) = book.answer(.issue(role: .worker, root: root, task: "t", auditing: nil), from: .session(lead.id.uuidString)) else {
            Issue.record("no worker grant"); return
        }
        #expect(book.answer(.bind(grant: workerGrant, root: root, session: worker.id.uuidString), from: .session(lead.id.uuidString)) == .ok)
        made = try commit("c.txt", in: root)
        got = try hooksSay("worker", root: root, before: left, after: made)
        #expect(got[2] == .vault(.ok), "\(got)")
        #expect(move(book, root)?.accepted == false)
        #expect(book.answer(.setHead(root: root, branch: "main", commit: made), from: .app) == .ok)
        left = made

        // A session the app opened, holding no role: yours. The move is taken, named after the session, and logged.
        let yours = try app.spawn(try hooksShell(host, "yours"))
        made = try commit("d.txt", in: root)
        got = try hooksSay("yours", root: root, before: left, after: made)
        #expect(got[2] == .vault(.ok), "\(got)")
        // Through the host, as the app asks (the reply carries the session's name in the window).
        let seq = app.send(.vault(.acceptMove(root: root, branch: "main")))
        #expect(eventually { app.reply(to: seq) != nil })
        guard case .vault(.move(let taken))? = app.reply(to: seq) else { Issue.record("\(String(describing: app.reply(to: seq)))"); return }
        #expect(taken.accepted, "\(taken.reason ?? "")")
        #expect(taken.sessions == [yours.id.uuidString])
        #expect(taken.labels == ["Test"])
        #expect(book.answer(.head(root: root, branch: "main"), from: .app) == .head(made))
        #expect(eventually { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains("vault: accepted 1 commit on main from your session Test") })

        // A session of yours something else typed into (a worker's Bash can type into any session outside a team): what
        // its agent runs may be that something's say, so it isn't taken as yours.
        let typed = try app.spawn(try hooksShell(host, "typed"))
        other.send(.input(id: typed.id, bytes: Data("x".utf8), reply: false))
        #expect(eventually { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains("input to \(HostServer.short(typed.id)) from a process outside the sessions, not the app") })
        left = made
        made = try commit("e.txt", in: root)
        got = try hooksSay("typed", root: root, before: left, after: made)
        #expect(got[2] == .vault(.ok), "\(got)")
        #expect(move(book, root)?.accepted == false)
        #expect(book.answer(.head(root: root, branch: "main"), from: .app) == .head(left))

        // A process outside every session can't say what any session ran.
        let requests = folder.appendingPathComponent("outside.requests")
        try frames([.vault(.ranGit(root: root, step: LeadVault.GitStep(phase: .before, call: nil, verb: "commit", branch: "main", head: made)))])
            .write(to: requests)
        #expect(refused(try ask(host, requests, expecting: 2...2)[2]))
    }
}
