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
    /// session's hooks do, then on the same connection `<name>.later` once `<name>.later.go` exists (unless
    /// `<name>.stop` comes first), and keeps running.
    func hooksShell(_ host: TestHost, _ name: String) throws -> String {
        let base = folder.appendingPathComponent(name).path
        let script = base + ".sh"
        let socket = (ncHangsUpFlags + ["-U"]).joined(separator: " ") + " '\(host.socket)'"
        try """
        while [ ! -f '\(base).go' ]; do sleep 0.05; done
        (cat '\(base).requests'
         while [ ! -f '\(base).later.go' ] && [ ! -f '\(base).stop' ]; do sleep 0.05; done
         if [ -f '\(base).later.go' ]; then cat '\(base).later'; fi
         while [ ! -f '\(base).stop' ]; do sleep 0.05; done) | /usr/bin/nc \(socket) > '\(base).answers'
        sleep 30
        """.write(toFile: script, atomically: true, encoding: .utf8)
        return "sh '\(script)'"
    }

    /// Frames for the host after `frames`' first `sent` requests: numbered on from `sent + 2`, no hello.
    func frames(_ requests: [HostRequest], after sent: Int) throws -> Data {
        var data = Data()
        for (index, request) in requests.enumerated() {
            data.append(HostFrame.encode(.control, try HostCoding.encode(HostRequestEnvelope(seq: sent + index + 2, request: request))))
        }
        return data
    }

    /// The session's hooks say it ran `git commit` on main from `before`, and `make` makes the commit in between, as
    /// git runs between its hooks: the before step sent and answered, then the commit, then the after step to its
    /// head. The commit before the before step was a race: the vault takes a reflog entry as a command's only from
    /// 2 s before the host saw the command start (`judge`'s slack), and on a busy Mac the shell's poll and nc's start
    /// could take longer (the move's reason then "no command … accounts for", not the session's).
    func hooksSay(_ name: String, root: String, before: String, commit make: @escaping () throws -> String) async throws -> (replies: [Int: HostEvent], made: String) {
        var made = ""
        let got = try await sessionSends(name, [step(.before, root, before)], then: {
            made = try make()
            return [step(.after, root, made)]
        }, expecting: 2...3)
        return (got, made)
    }

    func move(_ book: LeadVault.Book, _ root: String) -> LeadVault.BaseMove? {
        if case .move(let move) = book.answer(.acceptMove(root: root, branch: "main"), from: .app) { return move }
        return nil
    }

    /// The session's shell sends `requests` to the host (as anything running in it could), once; with `later`, once
    /// those are answered, what `later` makes, on the same connection; the replies to `seqs` are waited for, or (nil)
    /// `until` holds.
    func sessionSends(_ name: String, _ requests: [HostRequest], then later: (() throws -> [HostRequest])? = nil,
                      expecting seqs: ClosedRange<Int>?, until: () -> Bool = { true }) async throws -> [Int: HostEvent] {
        let base = folder.appendingPathComponent(name)
        try frames(requests).write(to: base.appendingPathExtension("requests"))
        FileManager.default.createFile(atPath: base.path + ".go", contents: nil)
        let answers = base.appendingPathExtension("answers")
        if let later {
            // The last of them answered (an input sent with `reply: false` gets none; the host answers in order).
            #expect(await eventually { answered(answers, (requests.count + 1)...(requests.count + 1)) }, "\(name)")
            try frames(try later(), after: requests.count).write(to: base.appendingPathExtension("later"))
            FileManager.default.createFile(atPath: base.path + ".later.go", contents: nil)
        }
        if let seqs { #expect(await eventually { answered(answers, seqs) }, "\(name)") }
        let held = await eventually(until)
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
    @Test func aWorkersKeysCannotContaminateYourSessionOrItsCommits() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try gitRepo()
        let log = folder.appendingPathComponent("host.log").path
        let logged = { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, appExecutable: try #require(HostServer.executable(of: getpid())), log: log)
        let app = try TestClient(host)
        let lead = try await app.spawn("sleep 30")
        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no lead grant"); return
        }
        #expect(book.answer(.bind(grant: grant, root: root, session: lead.id.uuidString), from: .app) == .ok)
        let worker = try await app.spawn(try hooksShell(host, "typist"))
        guard case .grant(let workerGrant) = book.answer(.issue(role: .worker, root: root, task: "t", auditing: nil), from: .session(lead.id.uuidString)) else {
            Issue.record("no worker grant"); return
        }
        #expect(book.answer(.bind(grant: workerGrant, root: root, session: worker.id.uuidString), from: .session(lead.id.uuidString)) == .ok)
        var left = Git.run(["rev-parse", "main"], in: root).output
        #expect(book.answer(.setHead(root: root, branch: "main", commit: left), from: .app) == .ok)

        // Yours: you type into it (the app), and it types into itself (its own terminal). Its commit is taken.
        let mine = try await app.spawn(try hooksShell(host, "mine"))
        app.send(.input(id: mine.id, bytes: Data("commit it\r".utf8), reply: false))
        var made = ""
        var got = try await sessionSends("mine", [.input(id: mine.id, bytes: Data("\r".utf8), reply: false), step(.before, root, left)], then: {
            made = try commit("b.txt", in: root)
            return [step(.after, root, made)]
        }, expecting: 3...4)
        #expect(got[3] == .vault(.ok) && got[4] == .vault(.ok), "\(got)")
        #expect(move(book, root)?.accepted == true)
        #expect(book.answer(.head(root: root, branch: "main"), from: .app) == .head(made))
        #expect(!logged().contains("input to \(HostServer.short(mine.id))"))
        left = made

        // The worker's Bash attempts to type into another idle session of yours. It is refused at the socket.
        let idle = try await app.spawn(try hooksShell(host, "idle"))
        let rejected = try await sessionSends("typist", [.input(id: idle.id, bytes: Data("git cherry-pick \(left)\r".utf8), reply: false)], expecting: 2...2)
        guard case .error? = rejected[2] else { Issue.record("A worker typed into your session"); return }
        // The user's own later keys and git operation remain the user's.
        app.send(.input(id: idle.id, bytes: Data("\r".utf8), reply: false))
        got = try await sessionSends("idle", [.input(id: idle.id, bytes: Data("\r".utf8), reply: false), step(.before, root, left)], then: {
            made = try commit("c.txt", in: root)
            return [step(.after, root, made)]
        }, expecting: 3...4)
        #expect(got[3] == .vault(.ok) && got[4] == .vault(.ok), "\(got)")
        let asked = try #require(move(book, root))
        #expect(asked.accepted, "\(asked)")
        #expect(book.answer(.head(root: root, branch: "main"), from: .app) == .head(made))
    }

    @Test func gitCommandsCountAsYoursOnlyFromASessionTheAppOpenedOutsideTheTeam() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try gitRepo()
        let log = folder.appendingPathComponent("host.log").path
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, appExecutable: try #require(HostServer.executable(of: getpid())), log: log)
        let app = try TestClient(host)
        let other = try TestClient(host, asApp: false)
        let lead = try await app.spawn("sleep 30")
        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no lead grant"); return
        }
        #expect(book.answer(.bind(grant: grant, root: root, session: lead.id.uuidString), from: .app) == .ok)
        var left = Git.run(["rev-parse", "main"], in: root).output
        #expect(book.answer(.setHead(root: root, branch: "main", commit: left), from: .app) == .ok)

        // A session another hosted session asked for: not the user's own session. Unknown clients may no
        // longer bootstrap this fixture through spawn, so send it from a real scratch parent session.
        let childRequests = folder.appendingPathComponent("child.requests")
        let childAnswers = folder.appendingPathComponent("child.answers")
        let childStop = folder.appendingPathComponent("child.stop")
        try frames([.spawn(SpawnRequest(cwd: folder.path, command: try hooksShell(host, "stranger"), env: [:],
                                       cols: 80, rows: 24, keepShell: false, label: "Test", agent: nil))]).write(to: childRequests)
        _ = try await app.spawn(nc(host, childRequests, childAnswers, until: childStop))
        #expect(await eventually { answered(childAnswers, 2...2) })
        guard case .spawned(let stranger)? = try replies(Data(contentsOf: childAnswers))[2] else {
            Issue.record("The scratch parent could not spawn its child"); return
        }
        FileManager.default.createFile(atPath: childStop.path, contents: nil)
        var (got, made) = try await hooksSay("stranger", root: root, before: left) { try commit("b.txt", in: root) }
        #expect(got[2] == .vault(.ok) && got[3] == .vault(.ok), "\(got)")
        #expect(move(book, root)?.accepted == false)
        #expect(move(book, root)?.reason?.contains(String(stranger.id.uuidString.prefix(8))) == true)
        // (You accept it in the app.)
        #expect(book.answer(.setHead(root: root, branch: "main", commit: made), from: .app) == .ok)
        left = made

        // A session the app opened that holds the worker's role.
        let worker = try await app.spawn(try hooksShell(host, "worker"))
        guard case .grant(let workerGrant) = book.answer(.issue(role: .worker, root: root, task: "t", auditing: nil), from: .session(lead.id.uuidString)) else {
            Issue.record("no worker grant"); return
        }
        #expect(book.answer(.bind(grant: workerGrant, root: root, session: worker.id.uuidString), from: .session(lead.id.uuidString)) == .ok)
        (got, made) = try await hooksSay("worker", root: root, before: left) { try commit("c.txt", in: root) }
        #expect(got[2] == .vault(.ok), "\(got)")
        #expect(move(book, root)?.accepted == false)
        #expect(book.answer(.setHead(root: root, branch: "main", commit: made), from: .app) == .ok)
        left = made

        // A session the app opened, holding no role: yours. The move is taken, named after the session, and logged.
        let yours = try await app.spawn(try hooksShell(host, "yours"))
        (got, made) = try await hooksSay("yours", root: root, before: left) { try commit("d.txt", in: root) }
        #expect(got[2] == .vault(.ok), "\(got)")
        // Through the host, as the app asks (the reply carries the session's name in the window).
        let seq = app.send(.vault(.acceptMove(root: root, branch: "main")))
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .vault(.move(let taken))? = app.reply(to: seq) else { Issue.record("\(String(describing: app.reply(to: seq)))"); return }
        #expect(taken.accepted, "\(taken.reason ?? "")")
        #expect(taken.sessions == [yours.id.uuidString])
        #expect(taken.labels == ["Test"])
        #expect(book.answer(.head(root: root, branch: "main"), from: .app) == .head(made))
        #expect(await eventually { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains("vault: accepted 1 commit on main from your session Test") })

        // An unknown process cannot contaminate input to a session of yours. Its attempted keys are refused,
        // and the session's own later git operation remains attributable to you.
        let typed = try await app.spawn(try hooksShell(host, "typed"))
        let refusedInput = other.send(.input(id: typed.id, bytes: Data("x".utf8), reply: false))
        #expect(await eventually { other.reply(to: refusedInput) != nil })
        guard case .error? = other.reply(to: refusedInput) else { Issue.record("Unknown input was accepted"); return }
        left = made
        (got, made) = try await hooksSay("typed", root: root, before: left) { try commit("e.txt", in: root) }
        #expect(got[2] == .vault(.ok), "\(got)")
        #expect(move(book, root)?.accepted == true)
        #expect(book.answer(.head(root: root, branch: "main"), from: .app) == .head(made))

        // A process outside every session can't say what any session ran.
        let requests = folder.appendingPathComponent("outside.requests")
        try frames([.vault(.ranGit(root: root, step: LeadVault.GitStep(phase: .before, call: nil, verb: "commit", branch: "main", head: made)))])
            .write(to: requests)
        await #expect(refused(try ask(host, requests, expecting: 2...2)[2]))
    }
}
