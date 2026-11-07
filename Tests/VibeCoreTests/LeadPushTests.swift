import Foundation
import Testing
@testable import VibeCore

/// push_remote and the app's click on its request (`LeadPush`), against a scratch bare repository as `origin` (never a
/// real remote, never the network): `LeadRemoteTests`' scene, the lead's main checkout and another clone.
struct LeadPushTests {
    let remote = LeadRemoteTests()
    var vault: LeadVault { remote.vault }

    /// The origin's main, as the bare repository has it.
    func originMain(_ scene: LeadRemoteTests.Scene) -> String {
        Shell.run(executable: "/usr/bin/git", args: ["rev-parse", "--verify", "--quiet", "refs/heads/main"], in: scene.origin,
                  env: Git.environment, timeout: 30, grace: 1).output
    }

    /// A scene whose lead fetched origin and has `commits` commits of its own on main, and the lead's tool server.
    func ahead(_ commits: Int, workflow: [String] = ["test_command: true"]) throws -> (LeadRemoteTests.Scene, LeadToolset) {
        let scene = try remote.makeScene(workflow: workflow)
        let lead = try remote.lead(scene.root, FakeRuntime())
        let fetched = lead.call("fetch_remote", [:])
        #expect(!fetched.isError, "\(fetched.text)")
        for index in 0..<commits { try remote.commit("l\(index).txt", "\(index)\n", in: scene.root, message: "Local \(index)") }
        // The lead's own commits, as merge lands them: the vault's head of main moves with them.
        try vault.setHead(remote.head(scene.root), root: scene.root, branch: "main")
        return (scene, lead)
    }

    func asked(_ lead: LeadToolset, root: String) throws -> LeadPush.Request {
        let asked = lead.call("push_remote", [:])
        #expect(!asked.isError, "\(asked.text)")
        return try #require(try vault.pushRequest(root: root))
    }

    func progress(_ root: String) -> String {
        (try? String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)) ?? ""
    }

    // MARK: The request

    @Test func pushRemoteRecordsARequestAndPushesNothing() throws {
        let (scene, lead) = try ahead(2)
        let before = originMain(scene)
        let main = remote.head(scene.root)

        let asked = lead.call("push_remote", [:])
        #expect(!asked.isError, "\(asked.text)")
        #expect(asked.text.contains("Waiting for the user's click") && asked.text.contains("2 commits ahead of origin/main"), "\(asked.text)")
        #expect(asked.text.contains("Local 1") && asked.text.contains("Local 0"), "\(asked.text)")
        #expect(originMain(scene) == before)
        let request = try #require(try vault.pushRequest(root: scene.root))
        #expect(request.commit == main && request.ahead == 2 && request.remote == "origin" && request.branch == "main" && request.url == scene.origin)
        #expect(request.subjects.count == 2 && request.subjects[0].hasSuffix(" Local 1"))
        #expect(asked.text.contains("Push request \(request.id):"))
        #expect(progress(scene.root).contains("Asked the user to push main at \(main.prefix(8))"))

        // A newer request replaces the open one: the old one's click finds nothing.
        try remote.commit("l9.txt", "9\n", in: scene.root, message: "Local 9")
        try vault.setHead(remote.head(scene.root), root: scene.root, branch: "main")
        let again = lead.call("push_remote", [:])
        #expect(again.text.contains("It replaces your open request \(request.id)"), "\(again.text)")
        let newer = try #require(try vault.pushRequest(root: scene.root))
        #expect(newer.id != request.id && newer.ahead == 3)
        let stale = LeadPush.settle(id: request.id, root: scene.root, push: true, vault: vault)
        #expect(stale.outcome == .gone && stale.request == nil)
        #expect(originMain(scene) == before)
        #expect(try vault.pushRequest(root: scene.root) == newer)
    }

    @Test func pushRemoteRefusesBeforeAFetchWhenTheRemoteIsAheadAndWhenNothingIsAhead() throws {
        // Before any fetch: no URL pinned, no tip fetched.
        let fresh = try remote.makeScene()
        let unfetched = try remote.lead(fresh.root, FakeRuntime())
        let early = unfetched.call("push_remote", [:])
        #expect(early.isError && early.text.contains("fetch_remote hasn't fetched"), "\(early.text)")

        // Nothing ahead.
        let (scene, lead) = try ahead(0)
        let nothing = lead.call("push_remote", [:])
        #expect(nothing.isError && nothing.text.contains("Nothing to push"), "\(nothing.text)")

        // The remote has a commit main lacks: merge_remote first.
        try remote.commit("l.txt", "l\n", in: scene.root, message: "Local")
        try vault.setHead(remote.head(scene.root), root: scene.root, branch: "main")
        _ = try remote.pushed(scene, "r.txt", "r\n", message: "Remote")
        #expect(!lead.call("fetch_remote", [:]).isError)
        let behind = lead.call("push_remote", [:])
        #expect(behind.isError && behind.text.contains("Run merge_remote first"), "\(behind.text)")
        #expect(try vault.pushRequest(root: scene.root) == nil)
    }

    // MARK: The click

    /// Push pushes the commit you were shown, not where main is by then.
    @Test func anApprovalPushesExactlyTheApprovedCommitEvenAfterMainMovedOn() throws {
        let (scene, lead) = try ahead(2)
        let request = try asked(lead, root: scene.root)
        try remote.commit("later.txt", "later\n", in: scene.root, message: "Later")
        let later = remote.head(scene.root)

        let settled = LeadPush.settle(id: request.id, root: scene.root, push: true, vault: vault)
        #expect(settled.outcome == .pushed(created: false), "\(settled.outcome)")
        #expect(originMain(scene) == request.commit && originMain(scene) != later)
        #expect(try vault.pushRequest(root: scene.root) == nil)
        let message = LeadPush.message(request, settled.outcome)
        #expect(message.contains("pushed. origin/main is at \(request.short) now, a fast-forward"), "\(message)")
        #expect(progress(scene.root).contains("Pushed main at \(request.short) (2 commits) to origin/main, on the user's click"))
        // Settled once: a second click pushes nothing more.
        #expect(LeadPush.settle(id: request.id, root: scene.root, push: true, vault: vault).outcome == .gone)
    }

    /// The remote moved on (another clone pushed): the push is refused as not a fast-forward, said so, and nothing is
    /// forced.
    @Test func aNonFastForwardIsRejectedAndReportedAndNothingIsForced() throws {
        let (scene, lead) = try ahead(1)
        let request = try asked(lead, root: scene.root)
        let theirs = try remote.pushed(scene, "theirs.txt", "theirs\n", message: "Theirs")

        let settled = LeadPush.settle(id: request.id, root: scene.root, push: true, vault: vault)
        guard case .notFastForward(let said) = settled.outcome else { Issue.record("\(settled.outcome)"); return }
        #expect(said.contains("[rejected]"), "\(said)")
        #expect(originMain(scene) == theirs)
        let message = LeadPush.message(request, settled.outcome)
        #expect(message.contains("rejected, it isn't a fast-forward of origin/main") && message.contains("Nothing was forced"), "\(message)")
        #expect(progress(scene.root).contains("rejected: not a fast-forward; nothing forced"))

        // No force in any spelling: only the commit to the branch.
        let arguments = LeadPush.arguments(url: scene.origin, commit: request.commit, branch: "main", helpers: [])
        #expect(!arguments.contains { $0.hasPrefix("--force") || $0 == "-f" || $0.hasPrefix("+") || $0.contains("mirror") || $0 == "--all" || $0 == "--tags" })
        #expect(arguments.suffix(3) == ["--", scene.origin, "\(request.commit):refs/heads/main"])
    }

    @Test func aDeclinePushesNothingAndReports() throws {
        let (scene, lead) = try ahead(1)
        let before = originMain(scene)
        let request = try asked(lead, root: scene.root)

        let settled = LeadPush.settle(id: request.id, root: scene.root, push: false, vault: vault)
        #expect(settled.outcome == .declined && settled.request == request)
        #expect(originMain(scene) == before)
        #expect(try vault.pushRequest(root: scene.root) == nil)
        #expect(LeadPush.message(request, .declined).contains("The user declined your push request \(request.id)"))
        #expect(progress(scene.root).contains("The user declined the push of main at \(request.short)"))
        #expect(LeadPush.settle(id: request.id, root: scene.root, push: true, vault: vault).outcome == .gone)
        #expect(originMain(scene) == before)
    }

    // MARK: Steering

    /// Nothing in the call's arguments reaches the request or git: the remote, its URL and the branch are
    /// workflow.md's and the vault's.
    @Test func theRemoteAndRefspecCantBeSteeredByArguments() throws {
        let (scene, lead) = try ahead(1)
        #expect(lead.tools.first { $0.name == "push_remote" }?.properties.isEmpty == true)
        let evil = (scene.origin as NSString).deletingLastPathComponent + "/evil.git"
        remote.git(["init", "-q", "--bare", "-b", "main", evil], in: scene.root)
        remote.git(["remote", "add", "evil", evil], in: scene.root)

        let asked = lead.call("push_remote", ["remote": "evil", "url": evil, "refspec": "+refs/heads/main:refs/heads/main",
                                              "branch": "other", "commit": "HEAD~1", "force": true, "options": ["--mirror"]])
        #expect(!asked.isError, "\(asked.text)")
        let request = try #require(try vault.pushRequest(root: scene.root))
        #expect(request.remote == "origin" && request.branch == "main" && request.url == scene.origin && request.commit == remote.head(scene.root))
        #expect(LeadPush.settle(id: request.id, root: scene.root, push: true, vault: vault).outcome == .pushed(created: false))
        #expect(originMain(scene) == request.commit)
        let evilMain = Shell.run(executable: "/usr/bin/git", args: ["rev-parse", "--verify", "--quiet", "refs/heads/main"], in: evil,
                                 env: Git.environment, timeout: 30, grace: 1).output
        #expect(evilMain.isEmpty)

        // A remote workflow.md names that the lead didn't set with configure is refused.
        let path = scene.root + "/.vibeswitcher/workflow.md"
        try LeadWorkflow.updating(remote.read(path), with: [("remote", "evil")]).write(toFile: path, atomically: true, encoding: .utf8)
        let steered = lead.call("push_remote", [:])
        #expect(steered.isError && steered.text.contains("remote is now `evil`"), "\(steered.text)")
    }

    /// The remote's URL changed after the request (any session can `git remote set-url`): the click refuses it, and
    /// pushes nowhere.
    @Test func aURLChangedAfterTheRequestIsRefusedAtTheClick() throws {
        let (scene, lead) = try ahead(1)
        let request = try asked(lead, root: scene.root)
        let before = originMain(scene)
        let elsewhere = (scene.origin as NSString).deletingLastPathComponent + "/elsewhere.git"
        remote.git(["init", "-q", "--bare", "-b", "main", elsewhere], in: scene.root)
        remote.git(["remote", "set-url", "origin", elsewhere], in: scene.root)

        let settled = LeadPush.settle(id: request.id, root: scene.root, push: true, vault: vault)
        guard case .refused(let why) = settled.outcome else { Issue.record("\(settled.outcome)"); return }
        #expect(why.contains("origin's URL is \(elsewhere) now"), "\(why)")
        #expect(originMain(scene) == before)
        #expect(Shell.run(executable: "/usr/bin/git", args: ["rev-parse", "--verify", "--quiet", "refs/heads/main"], in: elsewhere,
                          env: Git.environment, timeout: 30, grace: 1).output.isEmpty)
        // And push_remote refuses the new URL until the lead takes it.
        let refused = lead.call("push_remote", [:])
        #expect(refused.isError && refused.text.contains("origin's URL is now \(elsewhere), not the one you fetched from before"), "\(refused.text)")
    }

    /// F2: the push goes to the pinned URL given explicitly, by a git that doesn't read the repository's own config:
    /// a `remote.<url>.*` section, `url.*.pushInsteadOf` or `http.*` there (any session can write it, also after a
    /// check of it) doesn't steer it, and nothing reaches the other repository.
    @Test func repositoryConfigDoesntSteerThePush() throws {
        let (scene, lead) = try ahead(1)
        let evil = (scene.origin as NSString).deletingLastPathComponent + "/evil.git"
        remote.git(["init", "-q", "--bare", "-b", "main", evil], in: scene.root)
        let evilMain = {
            Shell.run(executable: "/usr/bin/git", args: ["rev-parse", "--verify", "--quiet", "refs/heads/main"], in: evil,
                      env: Git.environment, timeout: 30, grace: 1).output
        }
        for (index, (key, value)) in [("remote.\(scene.origin).pushurl", evil), ("url.\(evil).pushinsteadof", scene.origin),
                                      ("http.proxy", "http://127.0.0.1:9")].enumerated() {
            if index > 0 {
                try remote.commit("more\(index).txt", "\(index)\n", in: scene.root, message: "More \(index)")
                try vault.setHead(remote.head(scene.root), root: scene.root, branch: "main")
            }
            let request = try asked(lead, root: scene.root)
            remote.git(["config", key, value], in: scene.root)
            let settled = LeadPush.settle(id: request.id, root: scene.root, push: true, vault: vault)
            #expect(settled.outcome == .pushed(created: false), "\(key): \(settled.outcome)")
            #expect(originMain(scene) == request.commit && evilMain().isEmpty, "\(key)")
            remote.git(["config", "--unset", key], in: scene.root)
        }
    }

    /// The git that talks to the remote reads none of the repository's config, whatever is written there and when:
    /// only the folder it's given, made for that run.
    @Test func theTransportGitReadsNoneOfTheRepositorysConfig() throws {
        let scene = try remote.makeScene()
        remote.git(["config", "url./elsewhere.pushinsteadof", scene.origin], in: scene.root)
        remote.git(["config", "http.proxy", "http://127.0.0.1:9"], in: scene.root)
        let scratch = remote.temp.url("transport")
        let listed = LeadRemote.transportGit(["config", "--list", "--show-scope"], root: scene.root, scratch: scratch, timeout: 30).run
        #expect(listed.status == 0, "\(listed.error)")
        #expect(!listed.output.contains("pushinsteadof") && !listed.output.contains("http.proxy") && !listed.output.contains("remote.origin"), "\(listed.output)")
        // It sees the repository's objects, and leaves no folder behind.
        let head = remote.head(scene.root)
        #expect(LeadRemote.transportGit(["cat-file", "-e", head + "^{commit}"], root: scene.root, scratch: scratch, timeout: 30).run.status == 0)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.isEmpty == true)
    }

    /// F2, the fetch: it fetches from the pinned URL given explicitly (not the remote's name, which git would look up
    /// again), by a git that doesn't read the repository's config, so nothing there steers that URL.
    @Test func fetchGoesToThePinnedURLWhateverTheRepositorysConfigSays() throws {
        let scene = try remote.makeScene()
        let lead = try remote.lead(scene.root, FakeRuntime())
        #expect(!lead.call("fetch_remote", [:]).isError)
        let arguments = LeadRemote.fetchArguments(url: scene.origin, remote: "origin", branch: "main", helpers: [])
        #expect(arguments.suffix(3) == ["--", scene.origin, "+refs/heads/main:refs/remotes/origin/main"] && !arguments.contains("origin"))
        // Another repository with a commit of its own, which a `remote.<url>.url` section would fetch from.
        let evil = (scene.origin as NSString).deletingLastPathComponent + "/evil"
        try FileManager.default.createDirectory(atPath: evil, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "e@e"], ["config", "user.name", "E"]] { remote.git(args, in: evil) }
        try remote.commit("evil.txt", "evil\n", in: evil, message: "Evil")
        let planted = remote.git(["rev-parse", "HEAD"], in: evil).output
        for (index, (key, value)) in [("remote.\(scene.origin).url", evil), ("url.\(evil).insteadof", scene.origin + "-x"),
                                      ("http.proxy", "http://127.0.0.1:9")].enumerated() {
            let tip = try remote.pushed(scene, "r\(index).txt", "\(index)\n", message: "Remote \(index)")
            remote.git(["config", key, value], in: scene.root)
            let fetched = lead.call("fetch_remote", [:])
            #expect(!fetched.isError, "\(key): \(fetched.text)")
            #expect(Git.run(["rev-parse", "refs/remotes/origin/main"], in: scene.root).output == tip, "\(key)")
            #expect(!Git.run(["cat-file", "-e", planted], in: scene.root).ok)
            remote.git(["config", "--unset", key], in: scene.root)
        }
    }

    /// F1: a URL with `::` names a remote helper (git runs git-remote-<name>), even where the name is a transport's
    /// (`file::`), which `transport(of:)` alone reads as the file transport: refused by fetch and push.
    @Test func aRemoteHelperURLIsRefusedEvenWhenItNamesATransport() throws {
        #expect(LeadRemote.transport(of: "file::/srv/o.git") == "file")
        let (scene, lead) = try ahead(1)
        let request = try asked(lead, root: scene.root)
        let before = originMain(scene)
        for url in ["file::\(scene.origin)", "https::\(scene.origin)", "\(scene.origin)::x"] {
            remote.git(["remote", "set-url", "origin", url], in: scene.root)
            guard case .failure(let error) = LeadRemote.url(root: scene.root, remote: "origin") else { Issue.record("\(url) taken"); continue }
            #expect(error.description.contains("a remote helper"), "\(error)")
            let fetch = lead.call("fetch_remote", [:])
            #expect(fetch.isError && fetch.text.contains("a remote helper"), "\(url): \(fetch.text)")
            #expect(lead.call("push_remote", [:]).isError)
        }
        let settled = LeadPush.settle(id: request.id, root: scene.root, push: true, vault: vault)
        guard case .refused(let why) = settled.outcome else { Issue.record("\(settled.outcome)"); return }
        #expect(why.contains("a remote helper"), "\(why)")
        #expect(originMain(scene) == before)
    }

    // MARK: Who approves

    /// Only the app's click settles a request: not the lead that asked, a worker, a verifier, a process outside the
    /// sessions, an ask_user answer, the board, or any file; and the request is in no file a session can write.
    @Test func noSessionWritableFileOrToolCanApproveARequest() throws {
        let (scene, lead) = try ahead(1)
        let before = originMain(scene)
        let request = try asked(lead, root: scene.root)

        // The vault refuses every caller but the app.
        let runtime = FakeRuntime()
        let worker = try remote.issued(.worker, task: "t", root: scene.root, runtime, session: "own-worker")
        _ = worker
        for caller in [LeadVault.Caller.session("lead-session"), .session("own-worker"), .session("stranger"), .unknown] {
            let asCaller = remote.book.vault(folder: vault.folder, as: { caller })
            #expect(throws: LeadVault.Refused.self, "\(caller)") { _ = try asCaller.settlePush(id: request.id, root: scene.root) }
        }
        // Nor does a worker ask for one, or replace the lead's.
        let workerVault = remote.book.vault(folder: vault.folder, as: { .session("own-worker") })
        var forged = request
        forged.id = "forged"
        #expect(throws: LeadVault.Refused.self) { try workerVault.requestPush(forged, root: scene.root) }
        #expect(throws: LeadVault.Refused.self) { _ = try workerVault.pushRequest(root: scene.root) }

        // An ask_user answer saying Push, or approving the commit as merges are approved, settles nothing.
        let question = lead.call("ask_user", ["question": "Push main?", "options": ["Push", "Decline"]])
        #expect(!question.isError, "\(question.text)")
        let store = BoardStore(root: scene.root)
        let open = try #require(store.load().questions.first { $0.isOpen })
        for answer in ["Push", "Approve \(request.commit)"] {
            let outcome = try store.update { $0.answer(open.id, with: answer, saw: open.version) }
            if case .answered(let answered, _) = outcome { _ = try vault.recordApproval(answer, of: answered, root: scene.root) }
        }
        // Nor do the worker's tools, nor any of the lead's own (none settles; push_remote only asks).
        #expect(!worker.tools.map(\.name).contains("push_remote"))
        #expect(try vault.pushRequest(root: scene.root) == request)
        #expect(originMain(scene) == before)

        // The request is in no file under the repository or the vault's folder (sessions can write both).
        for folder in [scene.root, vault.folder.path] {
            let files = FileManager.default.enumerator(atPath: folder)?.compactMap { $0 as? String } ?? []
            for file in files where !file.hasPrefix(".git/objects") {
                let path = (folder as NSString).appendingPathComponent(file)
                guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { continue }
                #expect(!text.contains("\"\(request.id)\"") && !(text.contains(request.id) && text.contains(request.commit)), "\(path)")
            }
        }
    }

    @Test func workersAndVerifiersDontHavePushRemote() throws {
        let scene = try remote.makeScene()
        let runtime = FakeRuntime()
        let lead = try remote.issued(.lead, task: nil, root: scene.root, runtime)
        #expect(lead.tools.map(\.name).contains("push_remote"))
        for role in [LeadLaunch.Role.worker, .verifier] {
            let seat = try remote.issued(role, task: "t", root: scene.root, runtime, session: "own-\(role.rawValue)")
            #expect(!seat.tools.map(\.name).contains("push_remote"))
            let refused = seat.call("push_remote", [:])
            #expect(refused.isError && refused.text.contains("No tool push_remote"), "\(role): \(refused.text)")
        }
        #expect(try vault.pushRequest(root: scene.root) == nil)
    }
}
