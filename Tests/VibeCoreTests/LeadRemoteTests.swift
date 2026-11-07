import Foundation
import Testing
@testable import VibeCore

/// fetch_remote and merge_remote, against a scratch bare repository as `origin` (never a real remote, never the
/// network): the lead's main checkout, and a second clone standing in for the user's other Mac or GitHub's web
/// edits, which pushes to it.
struct LeadRemoteTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    /// git as the test's own setup runs it, unguarded (the tool server's git uses no transport, so it can't push).
    @discardableResult
    func git(_ args: [String], in dir: String) -> Git.Result {
        let result = Shell.run(executable: "/usr/bin/git", args: args, in: dir, env: Git.environment, timeout: 60, grace: 1)
        #expect(result.status == 0, "git \(args.joined(separator: " ")): \(result.error)")
        return result
    }

    struct Scene {
        let root: String
        let origin: String
        let other: String
    }

    /// The lead's repository (a.txt and the lead's records committed, origin its remote, pushed) with `workflow`
    /// as its workflow.md's settings, and another clone of origin.
    func makeScene(workflow: [String] = ["test_command: true"]) throws -> Scene {
        let base = temp.url("remote").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let (root, origin, other) = (base.appendingPathComponent("lead").path, base.appendingPathComponent("origin.git").path, base.appendingPathComponent("other").path)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        git(["init", "-q", "--bare", "-b", "main", origin], in: base.path)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { git(args, in: root) }
        try FileManager.default.createDirectory(atPath: root + "/docs/lead", withIntermediateDirectories: true)
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try "# Progress\n\n- first\n".write(toFile: root + "/docs/lead/progress.md", atomically: true, encoding: .utf8)
        try "# Decisions\n\n## first\n".write(toFile: root + "/docs/lead/decisions.md", atomically: true, encoding: .utf8)
        git(["add", "."], in: root)
        git(["commit", "-q", "-m", "first"], in: root)
        git(["remote", "add", "origin", origin], in: root)
        git(["push", "-q", "origin", "main"], in: root)
        git(["clone", "-q", origin, other], in: base.path)
        for args in [["config", "user.email", "o@o"], ["config", "user.name", "Other"]] { git(args, in: other) }
        // Written before the lead starts, so they're recorded as the lead's when it first reads them.
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try (["---"] + workflow + ["merge_policy: auto", "---", ""]).joined(separator: "\n")
            .write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        return Scene(root: root, origin: origin, other: other)
    }

    /// Commits `text` to `file` in `dir` (appended with `append`).
    func commit(_ file: String, _ text: String, in dir: String, append: Bool = false, message: String) throws {
        let path = dir + "/" + file
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let before = append ? (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" : ""
        try (before + text).write(toFile: path, atomically: true, encoding: .utf8)
        git(["add", file], in: dir)
        git(["commit", "-q", "-m", message], in: dir)
    }

    /// The other clone commits and pushes.
    func pushed(_ scene: Scene, _ file: String, _ text: String, append: Bool = false, message: String) throws -> String {
        try commit(file, text, in: scene.other, append: append, message: message)
        git(["push", "-q", "origin", "main"], in: scene.other)
        return git(["rev-parse", "HEAD"], in: scene.other).output
    }

    func head(_ root: String) -> String { Git.run(["rev-parse", "main"], in: root).output }
    func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    func isAncestor(_ commit: String, of other: String, in root: String) -> Bool {
        Git.run(["merge-base", "--is-ancestor", commit, other], in: root).ok
    }

    // MARK: Automatic fetching (clock-driven, scratch bare remotes only)

    @Test func automaticFetchStartsWithTheLeadServerBackgroundLifecycle() throws {
        let scene = try makeScene()
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        lead.power = { nil }
        #expect(!lead.call("fetch_remote", [:]).isError)
        let tip = try pushed(scene, "b.txt", "bee\n", message: "Other Mac")
        let finished = DispatchSemaphore(value: 0)
        lead.keepRecords { [weak lead] work in
            work()
            if lead?.store.load().reports?.last?.text.contains(tip) == true { finished.signal() }
            return true
        }
        #expect(finished.wait(timeout: .now() + 60) == .success)
        #expect(lead.store.load().reports?.last?.text.contains(tip) == true)
    }

    @Test func automaticFetchReportsCanBeSealedOnlyByTheLeadForItself() throws {
        let scene = try makeScene()
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        let session = try #require(runtime.me.session)
        let worker = try lead.vault.issue(role: .worker, root: scene.root, task: "t")
        try lead.vault.bind(worker, root: scene.root, session: "worker")
        let agents = [runtime.me.pid: session, Int32(5999): "worker"]
        let message = SteerMessage(text: "Incoming remote", from: .system(LeadRemotePoller.sender), agentPid: runtime.me.pid)
        let own = book.vault(folder: vault.folder, as: { .session(session) }, agentSession: { agents[$0] })
        _ = try own.seal(message)
        let other = book.vault(folder: vault.folder, as: { .session("worker") }, agentSession: { agents[$0] })
        #expect(throws: (any Error).self) { try other.seal(message) }
        let toWorker = SteerMessage(text: message.text, from: message.from, agentPid: 5999)
        #expect(throws: (any Error).self) { try own.seal(toWorker) }
    }

    @Test(arguments: ["fast-forward", "clean", "conflict"])
    func automaticFetchReportsNewTipsOnceWithMergeOutlook(_ mode: String) throws {
        let scene = try makeScene()
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        lead.power = { nil }
        #expect(!lead.call("fetch_remote", [:]).isError) // The lead alone pins the URL.
        let start = Date(timeIntervalSince1970: 10_000)
        let poller = LeadRemotePoller(lead: lead)
        poller.tick(now: start)
        #expect(runtime.steered.isEmpty) // Nothing new.
        _ = try pushed(scene, "b.txt", "bee\n", message: "Other Mac one")
        let tip = try pushed(scene, "a.txt", "theirs\n", message: "Other Mac two")
        if mode != "fast-forward" {
            try commit(mode == "conflict" ? "a.txt" : "local.txt", "ours\n", in: scene.root, message: "Local")
        }
        let before = head(scene.root)
        let due = start.addingTimeInterval(LeadRemotePoller.interval)
        poller.tick(now: due.addingTimeInterval(-1))
        #expect(runtime.steered.isEmpty)
        poller.tick(now: due)
        let text = try #require(runtime.steered.first?.text)
        #expect(runtime.steered.count == 1)
        #expect(text.contains("2 commits from the other Mac") && text.contains(tip))
        let expected = mode == "fast-forward" ? "fast-forward main" : mode == "clean" ? "it merges cleanly" : "conflicts in a.txt"
        #expect(text.contains(expected), "\(text)")
        #expect(head(scene.root) == before)
        #expect(lead.vault.head(root: scene.root, branch: "refs/remotes/origin/main") == tip)
        // Reconstruct the poller to prove the persisted tip survives server restarts.
        LeadRemotePoller(lead: lead).tick(now: due.addingTimeInterval(LeadRemotePoller.interval))
        #expect(runtime.steered.count == 1)
        let progress = read(BoardStore(root: scene.root).recordPath("progress.md"))
        #expect(progress.components(separatedBy: "Automatically fetched origin/main at \(tip.prefix(8))").count == 2)
        let next = try pushed(scene, "next.txt", "next\n", message: "Other Mac three")
        poller.tick(now: due.addingTimeInterval(2 * LeadRemotePoller.interval))
        #expect(runtime.steered.count == 2 && runtime.steered.last?.text.contains(next) == true)
    }

    @Test func automaticFetchSkipsUnpinnedChangedURLBatteryAndLoad() throws {
        let scene = try makeScene()
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        lead.power = { nil }
        let poller = LeadRemotePoller(lead: lead)
        let tip = try pushed(scene, "b.txt", "bee\n", message: "Remote one")
        let before = Git.run(["rev-parse", "refs/remotes/origin/main"], in: scene.root).output
        let now = Date()
        poller.tick(now: now)
        #expect(Git.run(["rev-parse", "refs/remotes/origin/main"], in: scene.root).output == before)
        #expect(try lead.vault.guardedSettings(root: scene.root)?[LeadRemote.urlKey("origin")] == nil)
        #expect(!lead.call("fetch_remote", [:]).isError)
        let next = try pushed(scene, "c.txt", "sea\n", message: "Remote two")
        var battery = PowerState(onBattery: true, percent: 10)
        battery.heldUnder = 50
        lead.power = { battery }
        poller.tick(now: now)
        lead.power = { nil }
        runtime.load = 1_000_000
        poller.tick(now: now)
        runtime.load = 0
        git(["remote", "set-url", "origin", scene.other], in: scene.root)
        poller.tick(now: now)
        #expect(runtime.steered.isEmpty)
        #expect(Git.run(["rev-parse", "refs/remotes/origin/main"], in: scene.root).output == tip)
        git(["remote", "set-url", "origin", scene.origin], in: scene.root)
        poller.tick(now: now)
        #expect(runtime.steered.count == 1 && runtime.steered[0].text.contains(next))
    }

    @Test func automaticFetchBacksOffFailuresUpToTwelveHoursAndRecovers() throws {
        let scene = try makeScene()
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        lead.power = { nil }
        #expect(!lead.call("fetch_remote", [:]).isError)
        let tip = try pushed(scene, "b.txt", "bee\n", message: "Remote one")
        let offline = scene.origin + ".offline"
        try FileManager.default.moveItem(atPath: scene.origin, toPath: offline)
        let start = Date(timeIntervalSince1970: 10_000)
        var now = start
        let poller = LeadRemotePoller(lead: lead)
        // Read the private scheduler record, and drive every retry with an injected clock.
        for hours in [4, 8, 12, 12] {
            poller.tick(now: now)
            let folder = lead.vault.scratch(root: scene.root, "remote-poll")
            let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
            let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(state["interval"] as? Double == Double(hours * 3600))
            now = now.addingTimeInterval(Double(hours * 3600))
        }
        try FileManager.default.moveItem(atPath: offline, toPath: scene.origin)
        LeadRemotePoller(lead: lead).tick(now: now.addingTimeInterval(-1))
        #expect(runtime.steered.isEmpty)
        poller.tick(now: now)
        #expect(runtime.steered.count == 1 && runtime.steered[0].text.contains(tip))
        let next = try pushed(scene, "c.txt", "sea\n", message: "Remote two")
        poller.tick(now: now.addingTimeInterval(LeadRemotePoller.interval))
        #expect(runtime.steered.count == 2 && runtime.steered[1].text.contains(next))
    }

    // MARK: fetch_remote

    @Test func fetchReportsAheadBehindAndTheIncomingSubjectsAndMovesOnlyTheTrackingRef() throws {
        let scene = try makeScene()
        let lead = try lead(scene.root, FakeRuntime())
        _ = try pushed(scene, "b.txt", "bee\n", message: "Remote one")
        let tip = try pushed(scene, "c.txt", "sea\n", message: "Remote two")
        try commit("d.txt", "dee\n", in: scene.root, message: "Local one")
        let before = head(scene.root)

        let fetched = lead.call("fetch_remote", [:])
        #expect(!fetched.isError, "\(fetched.text)")
        #expect(fetched.text.contains("main is 1 commit ahead of origin/main and 2 commits behind it"), "\(fetched.text)")
        let subjects = fetched.text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        #expect(subjects.count == 2 && subjects[0].hasSuffix(" Remote two") && subjects[1].hasSuffix(" Remote one"), "\(fetched.text)")
        #expect(fetched.text.contains("merge_remote would make a merge commit of origin/main into main (it merges cleanly)"), "\(fetched.text)")
        // Only the remote-tracking ref moved: main and the checkout are as they were.
        #expect(Git.run(["rev-parse", "refs/remotes/origin/main"], in: scene.root).output == tip)
        #expect(head(scene.root) == before)
        #expect(!FileManager.default.fileExists(atPath: scene.root + "/b.txt"))
        #expect(read(BoardStore(root: scene.root).recordPath("progress.md")).contains("Fetched origin/main at \(tip.prefix(8))"))

        // The outlooks: nothing new, a fast-forward, a conflict.
        let quiet = try makeScene()
        let idle = try self.lead(quiet.root, FakeRuntime())
        #expect(idle.call("fetch_remote", [:]).text.contains("main is 0 commits ahead of origin/main and 0 commits behind it.\nmerge_remote would do nothing"))
        _ = try pushed(quiet, "b.txt", "bee\n", message: "Remote one")
        #expect(idle.call("fetch_remote", [:]).text.contains("merge_remote would fast-forward main to origin/main"))
        _ = try pushed(quiet, "a.txt", "theirs\n", message: "Remote a")
        try commit("a.txt", "ours\n", in: quiet.root, message: "Local a")
        let conflict = idle.call("fetch_remote", [:])
        #expect(conflict.text.contains("merge_remote would stop: merging origin/main into main conflicts in a.txt"), "\(conflict.text)")
    }

    /// Nothing in the call's arguments reaches git: not a remote, a refspec, a URL or an option. The remote is
    /// workflow.md's, by name only, and its URL goes only by file, https or ssh, with git's own upload-pack.
    @Test func fetchCantBeSteeredToAnotherRemoteOrRefspec() throws {
        let scene = try makeScene()
        let lead = try lead(scene.root, FakeRuntime())
        #expect(lead.tools.first { $0.name == "fetch_remote" }?.properties.isEmpty == true)
        // Another repository, with a commit of its own, and a local remote naming it.
        let evil = (scene.origin as NSString).deletingLastPathComponent + "/evil"
        try FileManager.default.createDirectory(atPath: evil, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "e@e"], ["config", "user.name", "E"]] { git(args, in: evil) }
        try commit("evil.txt", "evil\n", in: evil, message: "Evil")
        let evilCommit = git(["rev-parse", "HEAD"], in: evil).output
        git(["remote", "add", "evil", evil], in: scene.root)
        let tip = try pushed(scene, "b.txt", "bee\n", message: "Remote one")
        let before = head(scene.root)

        let fetched = lead.call("fetch_remote", ["remote": "evil", "refspec": "+refs/heads/main:refs/heads/main", "url": evil,
                                                 "branch": "main", "options": ["--upload-pack=touch x"]])
        #expect(!fetched.isError, "\(fetched.text)")
        #expect(fetched.text.contains("Fetched origin/main (\(tip.prefix(8)))"), "\(fetched.text)")
        #expect(head(scene.root) == before)
        #expect(Git.run(["rev-parse", "--verify", "--quiet", "refs/remotes/evil/main"], in: scene.root).output.isEmpty)
        #expect(!Git.run(["cat-file", "-e", evilCommit], in: scene.root).ok)

        // A remote that isn't a name, or that names no git remote, is refused by configure or the fetch.
        for bad in ["-x", "../evil", "evil:main", "https://example.invalid/x.git", "+refs/heads/main:refs/heads/main"] {
            #expect(lead.call("configure", ["remote": bad]).isError, "\(bad)")
        }
        #expect(!lead.call("configure", ["remote": "nowhere"]).isError)
        #expect(lead.call("fetch_remote", [:]).text.contains("no git remote nowhere"))
        #expect(!lead.call("configure", ["remote": ""]).isError)

        // The fetch drops every credential helper read before its own -c (the repository's could name any program),
        // then takes the user's own (global and system) back.
        let arguments = LeadRemote.fetchArguments(url: scene.origin, remote: "origin", branch: "main", helpers: ["-c", "credential.helper=osxkeychain"])
        let reset = try #require(arguments.firstIndex(of: "credential.helper="))
        #expect(arguments[reset - 1] == "-c" && arguments[reset + 2] == "credential.helper=osxkeychain" && arguments.firstIndex(of: "fetch")! > reset + 2)
        #expect(arguments.suffix(3) == ["--", scene.origin, "+refs/heads/main:refs/remotes/origin/main"] && arguments.contains("--upload-pack=git-upload-pack"))
        #expect(LeadRemote.transport(of: "ext::sh -c x") == "ext" && LeadRemote.transport(of: "git@github.com:o/r.git") == "ssh"
                && LeadRemote.transport(of: "https://github.com/o/r") == "https" && LeadRemote.transport(of: "/srv/o.git") == "file")

        // The repository's config can't make the fetch run a program: an upload-pack of its own isn't used, and an
        // ext:: URL (a command) is refused.
        let marker = scene.root + "/../ran"
        let script = scene.root + "/../upload-pack.sh"
        try "#!/bin/sh\ntouch '\(marker)'\nexec git-upload-pack \"$@\"\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        git(["config", "remote.origin.uploadpack", script], in: scene.root)
        _ = try pushed(scene, "c.txt", "sea\n", message: "Remote two")
        let again = lead.call("fetch_remote", [:])
        #expect(!again.isError, "\(again.text)")
        #expect(!FileManager.default.fileExists(atPath: marker))
        git(["remote", "set-url", "origin", "ext::sh -c touch% \(marker)"], in: scene.root)
        let ext = lead.call("fetch_remote", [:])
        #expect(ext.isError && ext.text.contains("goes by ext"), "\(ext.text)")
        #expect(!FileManager.default.fileExists(atPath: marker))

        // A remote workflow.md names that the lead didn't set with configure is refused, as any guard rail is.
        let path = scene.root + "/.vibeswitcher/workflow.md"
        try LeadWorkflow.updating(read(path), with: [("remote", "evil")]).write(toFile: path, atomically: true, encoding: .utf8)
        let steered = lead.call("fetch_remote", [:])
        #expect(steered.isError && steered.text.contains("remote is now `evil`"), "\(steered.text)")
        #expect(Git.run(["rev-parse", "--verify", "--quiet", "refs/remotes/evil/main"], in: scene.root).output.isEmpty)
    }

    /// The remote's URL is the repository's git config, which any session changes: fetch_remote takes the URL it
    /// first fetched from (or the one the lead takes with configure) and refuses another.
    @Test func aRemoteWhoseURLChangedIsRefusedUntilTheLeadTakesIt() throws {
        let scene = try makeScene()
        let lead = try lead(scene.root, FakeRuntime())
        let first = lead.call("fetch_remote", [:])
        #expect(first.text.contains("from \(scene.origin) (its first fetch"), "\(first.text)")
        let fetched = Git.run(["rev-parse", "refs/remotes/origin/main"], in: scene.root).output
        // A repository standing in for the remote, with a commit of its own on main.
        let elsewhere = (scene.origin as NSString).deletingLastPathComponent + "/elsewhere"
        git(["clone", "-q", scene.origin, elsewhere], in: scene.root)
        for args in [["config", "user.email", "e@e"], ["config", "user.name", "E"]] { git(args, in: elsewhere) }
        try commit("x.txt", "x\n", in: elsewhere, message: "Not the remote's")
        let planted = git(["rev-parse", "HEAD"], in: elsewhere).output
        git(["remote", "set-url", "origin", elsewhere], in: scene.root)

        let refused = lead.call("fetch_remote", [:])
        #expect(refused.isError && refused.text.contains("origin's URL is now \(elsewhere), not the one you fetched from before"), "\(refused.text)")
        #expect(Git.run(["rev-parse", "refs/remotes/origin/main"], in: scene.root).output == fetched)
        #expect(!Git.run(["cat-file", "-e", planted], in: scene.root).ok)
        #expect(lead.call("merge_remote", [:]).text.contains("Nothing to merge"))

        // The lead takes it (the user said they changed it): then it fetches from there.
        #expect(!lead.call("configure", ["remote": "origin"]).isError)
        let taken = lead.call("fetch_remote", [:])
        #expect(!taken.isError && taken.text.contains("Fetched origin/main (\(planted.prefix(8))) from \(elsewhere):"), "\(taken.text)")
    }

    /// git applies the repository's configured fetch refspecs to a fetched ref too (its opportunistic update), unless
    /// told otherwise: fetch_remote moves only the remote-tracking ref.
    @Test func theFetchMovesNoRefButTheRemoteTrackingOne() throws {
        let scene = try makeScene()
        let lead = try lead(scene.root, FakeRuntime())
        git(["config", "--add", "remote.origin.fetch", "+refs/heads/*:refs/heads/mirrored/*"], in: scene.root)
        git(["config", "--add", "remote.origin.fetch", "+refs/*:refs/*"], in: scene.root)
        let tip = try pushed(scene, "b.txt", "bee\n", message: "Remote one")
        let before = head(scene.root)
        let fetched = lead.call("fetch_remote", [:])
        #expect(!fetched.isError, "\(fetched.text)")
        #expect(Git.run(["rev-parse", "refs/remotes/origin/main"], in: scene.root).output == tip)
        #expect(Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/mirrored/main"], in: scene.root).output.isEmpty)
        #expect(head(scene.root) == before)
    }

    // MARK: merge_remote

    @Test func mergeFastForwardsWhenMainHasNothingOfItsOwnAndKeepsUncommittedRecords() throws {
        let scene = try makeScene()
        let lead = try lead(scene.root, FakeRuntime())
        let tip = try pushed(scene, "b.txt", "bee\n", message: "Remote one")
        #expect(!lead.call("fetch_remote", [:]).isError)
        // The lead's records not committed yet (fetch_remote's line), and one more line of the lead's.
        let progress = BoardStore(root: scene.root).recordPath("progress.md")
        try (read(progress) + "- uncommitted line\n").write(toFile: progress, atomically: true, encoding: .utf8)

        let merged = lead.call("merge_remote", [:])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("Merged origin/main into main as a fast-forward: 1 commit from the remote"), "\(merged.text)")
        // main moved to the remote's tip (then the lead's records commit, after the merge, on top of it).
        #expect(isAncestor(tip, of: "main", in: scene.root))
        let first = Git.run(["rev-list", "--first-parent", "main"], in: scene.root).output.split(whereSeparator: \.isNewline).map(String.init)
        #expect(first.contains(tip), "\(first)")
        #expect(Git.run(["rev-list", "--merges", "main"], in: scene.root).output.isEmpty)
        #expect(read(scene.root + "/b.txt") == "bee\n")
        // The uncommitted lines are still there, in the file and then in the records' commit.
        #expect(read(progress).contains("- uncommitted line") && read(progress).contains("Fetched origin/main"))
        #expect(read(progress).contains("Merged origin/main into main"))
        #expect(Git.run(["show", "main:docs/lead/progress.md"], in: scene.root).output.contains("- uncommitted line"))
        // Taken as the user's work: the vault's head is main's, so a merge of a task wouldn't refuse it as a move.
        #expect(vault.head(root: scene.root, branch: "main") == head(scene.root))
        #expect(lead.call("merge_remote", [:]).text.contains("Nothing to merge"))
    }

    @Test func mergeMakesATrueMergeWhenBothSidesMoved() throws {
        let scene = try makeScene(workflow: ["test_command: test -f b.txt && test -f d.txt"])
        let tip = try pushed(scene, "b.txt", "bee\n", message: "Remote one")
        try commit("d.txt", "dee\n", in: scene.root, message: "Local one")
        let lead = try lead(scene.root, FakeRuntime())
        let local = head(scene.root)
        #expect(!lead.call("fetch_remote", [:]).isError)

        let merged = lead.call("merge_remote", [:])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("as a merge commit"), "\(merged.text)")
        let merge = try #require(Git.run(["rev-list", "--merges", "--max-count=1", "main"], in: scene.root).output.nilIfEmpty)
        let parents = Git.run(["rev-list", "--parents", "-n", "1", merge], in: scene.root).output.split(separator: " ").map(String.init)
        #expect(parents == [merge, local, tip], "\(parents)")
        #expect(Git.run(["log", "-1", "--format=%s", merge], in: scene.root).output == "Merge remote-tracking branch 'origin/main'")
        // The remote's tip is an ancestor of main: a push of main is a fast-forward.
        #expect(isAncestor(tip, of: "main", in: scene.root) && isAncestor(local, of: "main", in: scene.root))
        #expect(read(scene.root + "/b.txt") == "bee\n" && read(scene.root + "/d.txt") == "dee\n")
        #expect(vault.head(root: scene.root, branch: "main") == head(scene.root))
    }

    /// No .gitattributes here: merge_remote's own union takes both sides' lines of the lead's records, the
    /// records written and not committed yet among them.
    @Test func conflictsOnlyInTheLeadsRecordsMergeByUnion() throws {
        let scene = try makeScene()
        let tip = try pushed(scene, "docs/lead/progress.md", "- remote progress\n", append: true, message: "Remote records")
        _ = try pushed(scene, "docs/lead/decisions.md", "## remote decision\n", append: true, message: "Remote decision")
        try commit("docs/lead/progress.md", "- local progress\n", in: scene.root, append: true, message: "Local records")
        try commit("docs/lead/decisions.md", "## local decision\n", in: scene.root, append: true, message: "Local decision")
        let lead = try lead(scene.root, FakeRuntime())
        let fetched = lead.call("fetch_remote", [:])
        #expect(fetched.text.contains("its only conflicts are in the lead's records (docs/lead/decisions.md, docs/lead/progress.md), which merge by union"), "\(fetched.text)")

        let merged = lead.call("merge_remote", [:])
        #expect(!merged.isError, "\(merged.text)")
        #expect(isAncestor(tip, of: "main", in: scene.root))
        let progress = Git.run(["show", "main:docs/lead/progress.md"], in: scene.root).output
        let decisions = Git.run(["show", "main:docs/lead/decisions.md"], in: scene.root).output
        for line in ["- first", "- local progress", "- remote progress", "Fetched origin/main"] { #expect(progress.contains(line), "\(progress)") }
        for line in ["## first", "## local decision", "## remote decision"] { #expect(decisions.contains(line), "\(decisions)") }
        #expect(!progress.contains("<<<<<<<") && !decisions.contains("<<<<<<<") && !progress.contains("======="))
        #expect(read(scene.root + "/docs/lead/progress.md").contains("- remote progress"))
        #expect(Git.run(["status", "--porcelain"], in: scene.root).output.split(whereSeparator: \.isNewline).allSatisfy { $0.contains("docs/lead/") || $0.contains(".vibeswitcher") })
    }

    @Test func aCodeConflictStopsWithTheFileNamedAndMainUnmoved() throws {
        let scene = try makeScene()
        _ = try pushed(scene, "a.txt", "theirs\n", message: "Remote a")
        try commit("a.txt", "ours\n", in: scene.root, message: "Local a")
        let lead = try lead(scene.root, FakeRuntime())
        let before = head(scene.root)
        #expect(!lead.call("fetch_remote", [:]).isError)

        let merged = lead.call("merge_remote", [:])
        #expect(merged.isError)
        #expect(merged.text.contains("conflicts with main in a.txt") && merged.text.contains("main is unmoved at \(before.prefix(8))"), "\(merged.text)")
        #expect(head(scene.root) == before)
        #expect(read(scene.root + "/a.txt") == "ours\n")
        #expect(!FileManager.default.fileExists(atPath: scene.root + "/.git/MERGE_HEAD"))
        #expect(Git.run(["worktree", "list", "--porcelain"], in: scene.root).output.components(separatedBy: "worktree ").count == 2)
    }

    @Test func aFailingTestCommandLeavesMainUnmoved() throws {
        let scene = try makeScene(workflow: ["test_command: test ! -f bad.txt"])
        let lead = try lead(scene.root, FakeRuntime())
        _ = try pushed(scene, "bad.txt", "bad\n", message: "Remote breaks it")
        let before = head(scene.root)
        #expect(!lead.call("fetch_remote", [:]).isError)

        let merged = lead.call("merge_remote", [:])
        #expect(merged.isError)
        #expect(merged.text.contains("the tests fail on origin/main merged into main") && merged.text.contains("main is unmoved"), "\(merged.text)")
        #expect(head(scene.root) == before)
        #expect(!FileManager.default.fileExists(atPath: scene.root + "/bad.txt"))
    }

    /// The remote changed the lead's records while the main checkout holds lines of them not committed yet: they're
    /// committed first, and the merge keeps them and the remote's.
    @Test func uncommittedRecordsSurviveAMergeThatChangesThem() throws {
        let scene = try makeScene()
        let lead = try lead(scene.root, FakeRuntime())
        _ = try pushed(scene, "docs/lead/progress.md", "- remote progress\n", append: true, message: "Remote records")
        #expect(!lead.call("fetch_remote", [:]).isError)
        let progress = BoardStore(root: scene.root).recordPath("progress.md")
        try (read(progress) + "- dirty line\n").write(toFile: progress, atomically: true, encoding: .utf8)

        let merged = lead.call("merge_remote", [:])
        #expect(!merged.isError, "\(merged.text)")
        let text = read(progress)
        for line in ["- first", "- remote progress", "- dirty line", "Fetched origin/main", "Merged origin/main"] { #expect(text.contains(line), "\(text)") }
        #expect(Git.run(["show", "main:docs/lead/progress.md"], in: scene.root).output.contains("- dirty line"))
    }

    /// Any worktree, or a task's test code, can move a remote-tracking ref: merge_remote merges only the tip
    /// fetch_remote fetched, as the vault keeps it.
    @Test func mergeTakesOnlyTheTipFetchRemoteFetched() throws {
        let scene = try makeScene()
        try commit("x.txt", "x\n", in: scene.root, message: "Unaudited")
        let planted = head(scene.root)
        git(["reset", "-q", "--hard", "HEAD~1"], in: scene.root)
        let lead = try lead(scene.root, FakeRuntime())
        let tip = try pushed(scene, "b.txt", "bee\n", message: "Remote one")
        #expect(!lead.call("fetch_remote", [:]).isError)
        git(["update-ref", "refs/remotes/origin/main", planted], in: scene.root)
        let before = head(scene.root)

        let refused = lead.call("merge_remote", [:])
        #expect(refused.isError && refused.text.contains("origin/main is at \(planted.prefix(8)), not at \(tip.prefix(8)) where fetch_remote left it"), "\(refused.text)")
        #expect(head(scene.root) == before && !isAncestor(planted, of: "main", in: scene.root))

        #expect(!lead.call("fetch_remote", [:]).isError)
        let merged = lead.call("merge_remote", [:])
        #expect(!merged.isError, "\(merged.text)")
        #expect(isAncestor(tip, of: "main", in: scene.root) && !isAncestor(planted, of: "main", in: scene.root))
    }

    @Test func mergeWithoutAFetchSaysSo() throws {
        let scene = try makeScene()
        git(["update-ref", "-d", "refs/remotes/origin/main"], in: scene.root)
        let lead = try lead(scene.root, FakeRuntime())
        #expect(lead.call("merge_remote", [:]).text.contains("run fetch_remote first"))
    }

    // MARK: A task that merges the remote

    /// merge-github-s-main, 2026-11-06: merge_remote stopped on a code conflict, so a worker merged origin/main in
    /// and resolved it, and its audit passed on that true merge. merge(task) then squashed the branch onto main (as
    /// it does a branch that merged the base in): the other Mac's commits landed as copies, so origin/main wasn't an
    /// ancestor of main and push_remote refused, and the lead's records were put back to main's copy, dropping the
    /// other Mac's. A branch carrying what fetch_remote fetched lands as a true merge instead: the fetched commits
    /// stay themselves, and the records are main's and the remote's, by union (the worker's own edits to them aren't
    /// taken, as ever).
    @Test func aTaskThatMergedTheRemoteInLandsWithTheRemotesCommitsAndRecords() throws {
        let scene = try makeScene()
        // The other Mac: work, a code change that conflicts with this Mac's, and lead records of its own.
        _ = try pushed(scene, "b.txt", "bee\n", message: "Remote b")
        _ = try pushed(scene, "a.txt", "theirs\n", message: "Remote a")
        _ = try pushed(scene, "docs/lead/decisions.md", "## the other Mac's decision\n", append: true, message: "Remote decision")
        _ = try pushed(scene, "docs/lead/incidents.md", "# Incidents\n\n## the other Mac's incident\n", message: "Remote incident")
        let tip = try pushed(scene, "docs/lead/progress.md", "- the other Mac's progress\n", append: true, message: "Remote progress")
        // This Mac, meanwhile.
        try commit("a.txt", "ours\n", in: scene.root, message: "Local a")
        try commit("docs/lead/progress.md", "- local progress\n", in: scene.root, append: true, message: LeadRecords.subject)
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        lead.power = { nil }
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        #expect(!lead.call("fetch_remote", [:]).isError)
        #expect(lead.call("merge_remote", [:]).text.contains("conflicts with main in a.txt"))

        // A worker merges origin/main in and resolves the conflicts (its records by hand, both sides' lines), as the
        // task asked.
        #expect(!lead.call("add_task", ["title": "Merge the remote", "goal": "origin/main merged", "acceptance": ["a"]]).isError)
        #expect(!lead.call("start_worker", ["task": "merge-the-remote"]).isError)
        let worktree = Worktrees.path(root: scene.root, slug: "merge-the-remote")
        #expect(!Git.run(["merge", "-q", "--no-edit", "origin/main"], in: worktree).ok)
        try "ours and theirs\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        try "# Progress\n\n- first\n- local progress\n- the other Mac's progress\n- the worker's own line\n"
            .write(toFile: worktree + "/docs/lead/progress.md", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt", "docs/lead"], in: worktree)
        #expect(Git.run(["commit", "-q", "--no-edit"], in: worktree).ok)
        let branch = Git.run(["rev-parse", "HEAD"], in: worktree).output
        #expect(isAncestor(tip, of: branch, in: scene.root))
        #expect(!(try seat("worker-merge-the-remote", runtime)).call("report", doneReport("merged origin/main")).isError)
        // The lead's records hold lines not committed yet in the main checkout, as they do between flushes.
        let progressFile = BoardStore(root: scene.root).recordPath("progress.md")
        #expect(read(progressFile).contains("Started a worker on merge-the-remote"))
        try (read(progressFile) + "- a line not committed yet\n").write(toFile: progressFile, atomically: true, encoding: .utf8)
        #expect(!Git.run(["status", "--porcelain", "--", "docs/lead/progress.md"], in: scene.root).output.isEmpty)
        let before = head(scene.root)

        let merged = lead.call("merge", ["task": "merge-the-remote"])
        #expect(!merged.isError, "\(merged.text)")
        let main = head(scene.root)
        // The other Mac's commits are on main as themselves, on top of what main had: a push is a fast-forward.
        #expect(isAncestor(tip, of: main, in: scene.root), "origin/main (\(tip.prefix(8))) isn't an ancestor of main (\(main.prefix(8)))")
        #expect(isAncestor(before, of: main, in: scene.root) && main != before)
        #expect(!Git.run(["show", "\(main):b.txt"], in: scene.root).output.isEmpty)
        #expect(Git.run(["show", "\(main):a.txt"], in: scene.root).output == "ours and theirs")
        #expect(Git.run(["show", "\(main):b.txt"], in: scene.root).output == "bee")
        // The records: main's and the other Mac's, all of them; not the worker's own line.
        let progress = Git.run(["show", "\(main):docs/lead/progress.md"], in: scene.root).output
        for line in ["- first", "- local progress", "Started a worker on merge-the-remote", "- a line not committed yet", "- the other Mac's progress"] {
            #expect(progress.contains(line), "\(line) missing from main's progress.md:\n\(progress)")
        }
        #expect(!progress.contains("the worker's own line") && !progress.contains("<<<<<<<"), "\(progress)")
        #expect(Git.run(["show", "\(main):docs/lead/decisions.md"], in: scene.root).output.contains("## the other Mac's decision"))
        #expect(Git.run(["show", "\(main):docs/lead/incidents.md"], in: scene.root).output.contains("## the other Mac's incident"))
        // So push_remote asks for the push, rather than refusing it as no fast-forward.
        let push = lead.call("push_remote", [:])
        #expect(!push.text.contains("wouldn't be a fast-forward"), "\(push.text)")
    }

    /// A branch holding the remote's commits that fetch_remote didn't fetch (the ref moved past it, by hand or by
    /// anyone) is refused before anything is tested: their records would be taken only up to what it fetched, and the
    /// rest lost for good once the commits are on main. After fetch_remote, it merges.
    @Test func aTaskHoldingRemoteCommitsPastTheFetchIsRefusedUntilFetchRemote() throws {
        let scene = try makeScene()
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        lead.power = { nil }
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        _ = try pushed(scene, "b.txt", "bee\n", message: "Remote b")
        #expect(!lead.call("fetch_remote", [:]).isError)
        let later = try pushed(scene, "docs/lead/decisions.md", "## the other Mac's later decision\n", append: true, message: "Remote decision")
        // Moved past what fetch_remote fetched, not by it.
        git(["fetch", "-q", "origin", "main:refs/remotes/origin/main"], in: scene.root)
        #expect(!lead.call("add_task", ["title": "Merge the remote", "goal": "origin/main merged", "acceptance": ["a"]]).isError)
        #expect(!lead.call("start_worker", ["task": "merge-the-remote"]).isError)
        let worktree = Worktrees.path(root: scene.root, slug: "merge-the-remote")
        #expect(Git.run(["merge", "-q", "--no-edit", "origin/main"], in: worktree).ok)
        try commit("w.txt", "w\n", in: worktree, message: "w")
        #expect(!(try seat("worker-merge-the-remote", runtime)).call("report", doneReport("merged origin/main")).isError)
        let before = head(scene.root)

        let refused = lead.call("merge", ["task": "merge-the-remote"])
        #expect(refused.isError && refused.text.contains("past what fetch_remote fetched") && refused.text.contains("Run fetch_remote"), "\(refused.text)")
        #expect(head(scene.root) == before)

        #expect(!lead.call("fetch_remote", [:]).isError)
        let merged = lead.call("merge", ["task": "merge-the-remote"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(isAncestor(later, of: "main", in: scene.root))
        #expect(Git.run(["show", "main:docs/lead/decisions.md"], in: scene.root).output.contains("## the other Mac's later decision"))
    }

    /// turn-this-incident-into-12, 2026-11-07 22:10: the same incident a second time, through a batch. auto_advance
    /// (merge_batching: always) merged redo-the-github-merge, whose branch held a true merge of origin/main (the other
    /// Mac's commits, its "Lead: decisions and progress" commits among them), together with verifier-isolation "as
    /// one batch". It landed squashed into one single-parent commit (98df3ea2), so origin/main still wasn't an
    /// ancestor of main and push_remote was blocked again. (The app then running was built at 17:28, before the fix
    /// in merge and in batches, `Worktrees.put` with the fetched tip, landed at 20:15.) Whichever place the task takes
    /// on the stack, the remote's tip lands as itself, an ancestor of main, the batch's other task beside it.
    @Test(arguments: [true, false])
    func aBatchWithATaskThatMergedTheRemoteInLandsTheRemotesCommitsAsThemselves(remoteFirst: Bool) async throws {
        let scene = try makeScene()
        // The other Mac: code, and lead records committed as the lead commits them.
        _ = try pushed(scene, "b.txt", "bee\n", message: "Remote b")
        _ = try pushed(scene, "docs/lead/progress.md", "- the other Mac's progress\n", append: true, message: LeadRecords.subject)
        let tip = try pushed(scene, "docs/lead/decisions.md", "## the other Mac's decision\n", append: true, message: LeadRecords.subject)
        // This Mac, meanwhile: its own records, so the worker's merge is a true merge and main lacks the remote's tip.
        try commit("docs/lead/progress.md", "- local progress\n", in: scene.root, append: true, message: LeadRecords.subject)
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        lead.power = { nil }
        lead.macLimits = { MacLimits(maxSessions: 12) }
        lead.batchSize = 2
        lead.batchWindow = 0
        // Installed from main as it is: the gate's code is all in it.
        let build = ServerBuild(commit: head(scene.root), builtAt: nil)
        lead.runningBuild = { build }
        let set = lead.call("configure", ["merge_batching": "always"])
        #expect(!set.isError, "\(set.text)")
        #expect(!lead.call("fetch_remote", [:]).isError)

        /// `slug`'s worker started, `work` done in its worktree, reported done, and its audit passed.
        func audited(_ slug: String, _ work: (String) throws -> Void) throws {
            let added = lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"], "review": "audit", "auto_advance": true])
            #expect(!added.isError, "\(added.text)")
            #expect(!lead.call("start_worker", ["task": slug]).isError)
            try work(Worktrees.path(root: scene.root, slug: slug))
            #expect(!(try seat("worker-\(slug)", runtime)).call("report", doneReport("done")).isError)
            let audit = lead.call("audit", ["task": slug])
            #expect(!audit.isError, "\(audit.text)")
            let verdict = try seat("verify-\(slug)", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "tests": "passed", "summary": "ok"])
            #expect(!verdict.isError, "\(verdict.text)")
        }
        // redo-the-github-merge: origin/main merged in, the records' conflict resolved by hand.
        let redo = {
            try audited("redo-the-github-merge") { worktree in
                _ = Git.run(["merge", "-q", "--no-edit", "origin/main"], in: worktree)
                if !Git.run(["diff", "--name-only", "--diff-filter=U"], in: worktree).output.isEmpty {
                    try "# Progress\n\n- first\n- local progress\n- the other Mac's progress\n"
                        .write(toFile: worktree + "/docs/lead/progress.md", atomically: true, encoding: .utf8)
                    Git.run(["add", "docs/lead"], in: worktree)
                    #expect(Git.run(["commit", "-q", "--no-edit"], in: worktree).ok)
                }
                #expect(self.isAncestor(tip, of: "HEAD", in: worktree))
                #expect(Git.run(["rev-list", "--merges", "--count", "main..HEAD"], in: worktree).output == "1")
            }
        }
        // verifier-isolation: work of its own.
        let other = { try audited("verifier-isolation") { try self.commit("v.txt", "vee\n", in: $0, message: "Verifier isolation") } }
        if remoteFirst { try redo(); try other() } else { try other(); try redo() }
        let before = head(scene.root)

        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        let slugs = ["redo-the-github-merge", "verifier-isolation"]
        #expect(await advancing.until { slugs.allSatisfy { BoardStore(root: scene.root).load().task($0)?.status == .done } })
        let tasks = slugs.compactMap { BoardStore(root: scene.root).load().task($0) }
        #expect(tasks.count == 2 && tasks.allSatisfy { Set($0.merged?.batch ?? []) == Set(slugs) }, "merged one at a time, not as one batch: \(tasks.map { $0.merged?.batch ?? [] })")

        let main = head(scene.root)
        // The incident: 98df3ea2, one commit with a single parent and the remote's subjects in its message.
        let log = Git.run(["log", "--format=%h %p %s", "\(before)..\(main)"], in: scene.root).output
        #expect(isAncestor(tip, of: main, in: scene.root),
                "origin/main (\(tip.prefix(8))) isn't an ancestor of main (\(main.prefix(8))): the batch squashed or rebased the branch that merged it\n\(log)")
        #expect(isAncestor(before, of: main, in: scene.root))
        #expect(Git.run(["show", "\(main):b.txt"], in: scene.root).output == "bee")
        #expect(Git.run(["show", "\(main):v.txt"], in: scene.root).output == "vee")
        let progress = Git.run(["show", "\(main):docs/lead/progress.md"], in: scene.root).output
        #expect(progress.contains("- local progress") && progress.contains("- the other Mac's progress"), "\(progress)")
        #expect(Git.run(["show", "\(main):docs/lead/decisions.md"], in: scene.root).output.contains("## the other Mac's decision"))
        let push = lead.call("push_remote", [:])
        #expect(!push.text.contains("wouldn't be a fast-forward"), "\(push.text)")
        // Each merge names the build that ran it, in its receipt and its progress line.
        #expect(tasks.allSatisfy { $0.receipt?.build == build.label && $0.receipt?.line.contains("merged by build \(build.label)") == true },
                "\(tasks.map { $0.receipt?.build ?? "none" })")
        let lines = read(BoardStore(root: scene.root).recordPath("progress.md"))
        #expect(slugs.allSatisfy { slug in lines.split(separator: "\n").contains { $0.contains("Merged \(slug):") && $0.hasSuffix("(build \(build.label))") } }, "\(lines)")
    }

    // MARK: The installed build (turn-this-incident-into-12)

    /// The build build-app.sh made: its source commit from the app's Info.plist, its time from the executable; none
    /// outside an app bundle (a test runner, `swift run`).
    @Test func theServersBuildIsTheCommitBuildAppWroteAndNoneOutsideAnApp() throws {
        let base = temp.url("builds").resolvingSymlinksInPath()
        func app(_ name: String, plist: [String: Any]?) throws -> String {
            let macOS = base.appendingPathComponent("\(name)/Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            if let plist {
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .write(to: macOS.deletingLastPathComponent().appendingPathComponent("Info.plist"))
            }
            let tool = macOS.appendingPathComponent("vibeswitcher-mcp")
            try Data("x".utf8).write(to: tool)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_794_053_807)], ofItemAtPath: tool.path)
            return tool.path
        }
        let sha = String(repeating: "ab", count: 20)
        let built = try #require(ServerBuild.read(executable: try app("A.app", plist: ["VSSourceCommit": sha.uppercased()])))
        #expect(built.commit == sha && !built.changed && built.builtAt == Date(timeIntervalSince1970: 1_794_053_807))
        #expect(built.label == String(sha.prefix(12)))
        let changed = try #require(ServerBuild.read(executable: try app("C.app", plist: ["VSSourceCommit": sha, "VSSourceChanged": true])))
        #expect(changed.label == "\(sha.prefix(12)) with changes not committed")
        // Builds from before build-app.sh wrote it (the 17:28 install of the incident): its time stands for it.
        let old = try #require(ServerBuild.read(executable: try app("Old.app", plist: ["CFBundleName": "VibeSwitcher"])))
        #expect(old.commit == nil && old.label.hasPrefix("unknown (no commit recorded") && old.label.contains("1794053807"), "\(old.label)")
        #expect(try ServerBuild.read(executable: try app("Bad.app", plist: ["VSSourceCommit": "main; rm -rf /"]))?.commit == nil)
        #expect(ServerBuild.read(executable: try app("Tests.xctest", plist: ["VSSourceCommit": sha])) == nil)
        #expect(ServerBuild.read(executable: base.appendingPathComponent("vibeswitcher-mcp").path) == nil)
    }

    /// A commit to the gate's own code on main, which the scene's lead hasn't started yet.
    func gateCommit(_ scene: Scene, _ subject: String = "merge lands a branch carrying the remote as a true merge") throws {
        try commit("Sources/VibeCore/Worktrees.swift", "// \(subject)\n", in: scene.root, append: true, message: subject)
    }

    /// status says when main holds commits to the gate's own code the running build lacks: past its commit, or (a build
    /// that recorded none) committed after its files' date. Other commits don't count, and an install from main clears
    /// it. Fails closed (F3): a build with no commit whose files are dated past the gate's code (an install's copy dates
    /// them), or whose commit this repository doesn't hold, couldn't be compared, and says so. A repository holding none
    /// of the gate's code (another project's) never shows it.
    @Test func statusSaysWhenGateCodeOnMainIsntInstalledYet() throws {
        let scene = try makeScene()
        let lead = try lead(scene.root, FakeRuntime())
        lead.power = { nil }
        let elsewhere = String(repeating: "c", count: 40)
        var build: ServerBuild? = ServerBuild(commit: elsewhere, builtAt: nil)
        lead.runningBuild = { build }
        #expect(!lead.call("status", [:]).text.contains("Gate code on main"))
        build = ServerBuild(commit: nil, builtAt: Date().addingTimeInterval(3600))
        #expect(!lead.call("status", [:]).text.contains("Gate code on main"))

        let installed = head(scene.root)
        try commit("a.txt", "two\n", in: scene.root, message: "Not the gate")
        try gateCommit(scene)
        try commit("Sources/vibeswitcher-mcp/main.swift", "// tool server\n", in: scene.root, message: "The tool server too")
        build = ServerBuild(commit: installed, builtAt: nil)
        let status = lead.call("status", [:]).text
        let line = "Gate code on main isn't installed yet: 2 commits (The tool server too; merge lands a branch carrying the remote as a true merge); merges run the installed build (\(installed.prefix(12)))."
        #expect(status.contains(line), "\(status)")
        #expect(!status.contains("Not the gate"))
        // Installed from main: nothing to say.
        build = ServerBuild(commit: head(scene.root), builtAt: nil)
        #expect(!lead.call("status", [:]).text.contains("Gate code on main"))
        // Built from main with changes not committed (or main moved while it compiled): its commit doesn't say.
        build = ServerBuild(commit: head(scene.root), changed: true, builtAt: nil)
        #expect(lead.call("status", [:]).text.contains("couldn't be compared with the installed build (\(head(scene.root).prefix(12)) with changes not committed): it was built with changes not committed"))
        // A build that recorded no commit: the gate's commits after its files' date are surely past it.
        build = ServerBuild(commit: nil, builtAt: Date(timeIntervalSince1970: 0))
        #expect(lead.call("status", [:]).text.contains("Gate code on main isn't installed yet: 2 commits"))
        // None after it: the date may be the install's copy of an older build, so it can't be compared.
        build = ServerBuild(commit: nil, builtAt: Date().addingTimeInterval(3600))
        let undated = lead.call("status", [:]).text
        #expect(undated.contains("Gate code on main couldn't be compared with the installed build (unknown (no commit recorded")
                && undated.contains("it recorded no commit, and its files' date") && undated.contains("Taken as not installed yet"), "\(undated)")
        // A commit this repository doesn't hold: can't be compared either.
        build = ServerBuild(commit: elsewhere, builtAt: nil)
        #expect(lead.call("status", [:]).text.contains("couldn't be compared with the installed build (cccccccccccc): its commit cccccccccccc isn't in this repository"))
        // Not running from an installed app (no build known): nothing to say.
        build = nil
        #expect(!lead.call("status", [:]).text.contains("Gate code on main"))
    }

    /// turn-this-incident-into-12:F1: a git log that fails (here, a tree it needs is missing; a timeout returns the
    /// same failure) is a lag that couldn't be compared, never none: status says so, and merge_remote refuses.
    @Test func aGitLogThatFailsCountsAsALagThatCouldntBeCompared() throws {
        let scene = try makeScene()
        let installed = head(scene.root)
        try gateCommit(scene)
        let lead = try lead(scene.root, FakeRuntime())
        lead.power = { nil }
        lead.runningBuild = { ServerBuild(commit: installed, builtAt: nil) }
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        #expect(lead.call("status", [:]).text.contains("Gate code on main isn't installed yet: 1 commit"))
        // The gate commit's tree, gone: git log can't diff it.
        let tree = git(["rev-parse", "main^{tree}"], in: scene.root).output
        try FileManager.default.removeItem(atPath: scene.root + "/.git/objects/\(tree.prefix(2))/\(tree.dropFirst(2))")
        #expect(!Git.run(["log", "-1", "main", "--", "Sources/VibeCore/Worktrees*"], in: scene.root).ok)
        let before = head(scene.root)

        let status = lead.call("status", [:]).text
        #expect(status.contains("Gate code on main couldn't be compared with the installed build (\(installed.prefix(12))): git log of main's gate code failed")
                && status.contains("Taken as not installed yet"), "\(status)")
        let remote = lead.call("merge_remote", [:])
        #expect(remote.isError && remote.text.contains("couldn't be compared") && remote.text.contains("may lack them")
                && remote.text.contains("Ask the user to install"), "\(remote.text)")
        #expect(head(scene.root) == before)
    }

    /// While status says the gate's code on main isn't installed, merge_remote and a merge of a branch carrying the
    /// remote refuse, nothing tested and main unmoved, telling the lead to ask the user to install; a task not carrying
    /// the remote merges as ever. Once installed, both go ahead.
    @Test func mergeRemoteAndARemoteCarryingMergeRefuseUntilTheGateIsInstalled() throws {
        let scene = try makeScene()
        let installed = head(scene.root)
        try gateCommit(scene)
        let tip = try pushed(scene, "b.txt", "bee\n", message: "Remote b")
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        lead.power = { nil }
        var build = ServerBuild(commit: installed, builtAt: nil)
        lead.runningBuild = { build }
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        #expect(!lead.call("fetch_remote", [:]).isError)
        let before = head(scene.root)

        let remote = lead.call("merge_remote", [:])
        #expect(remote.isError && remote.text.contains("Gate code on main isn't installed yet: 1 commit")
                && remote.text.contains("merge_remote runs through that build's gate") && remote.text.contains("Ask the user to install"), "\(remote.text)")
        #expect(head(scene.root) == before)

        for slug in ["carry-the-remote", "own-work"] {
            #expect(!lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"]]).isError)
            #expect(!lead.call("start_worker", ["task": slug]).isError)
        }
        let carrying = Worktrees.path(root: scene.root, slug: "carry-the-remote")
        #expect(Git.run(["merge", "-q", "--no-edit", "origin/main"], in: carrying).ok)
        try commit("o.txt", "own\n", in: Worktrees.path(root: scene.root, slug: "own-work"), message: "Own work")
        for slug in ["carry-the-remote", "own-work"] {
            #expect(!(try seat("worker-\(slug)", runtime)).call("report", doneReport("done")).isError)
        }
        let refused = lead.call("merge", ["task": "carry-the-remote"])
        #expect(refused.isError && refused.text.contains("Not merged (nothing was tested): Gate code on main isn't installed yet")
                && refused.text.contains("agent/carry-the-remote holds commits of origin/main") && refused.text.contains("Ask the user to install"), "\(refused.text)")
        #expect(head(scene.root) == before)
        let own = lead.call("merge", ["task": "own-work"])
        #expect(!own.isError, "\(own.text)")
        #expect(read(BoardStore(root: scene.root).recordPath("progress.md")).split(separator: "\n")
            .contains { $0.contains("Merged own-work: own-work") && $0.hasSuffix("(build \(installed.prefix(12)))") })

        // The user installs from main.
        build = ServerBuild(commit: head(scene.root), builtAt: nil)
        let merged = lead.call("merge", ["task": "carry-the-remote"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(isAncestor(tip, of: head(scene.root), in: scene.root))
        #expect(BoardStore(root: scene.root).load().task("carry-the-remote")?.receipt?.build == build.label)
    }

    // MARK: Roles

    @Test func workersAndVerifiersHaveNeitherTool() throws {
        let scene = try makeScene()
        let runtime = FakeRuntime()
        let lead = try issued(.lead, task: nil, root: scene.root, runtime)
        #expect(Set(lead.tools.map(\.name)).isSuperset(of: ["fetch_remote", "merge_remote"]))
        let tip = try pushed(scene, "b.txt", "bee\n", message: "Remote one")
        let before = head(scene.root)
        for role in [LeadLaunch.Role.worker, .verifier] {
            let seat = try issued(role, task: "t", root: scene.root, runtime, session: "own-\(role.rawValue)")
            #expect(Set(seat.tools.map(\.name)).isDisjoint(with: ["fetch_remote", "merge_remote"]))
            for name in ["fetch_remote", "merge_remote"] {
                let refused = seat.call(name, [:])
                #expect(refused.isError && refused.text.contains("No tool \(name)"), "\(role) \(name): \(refused.text)")
            }
        }
        #expect(Git.run(["rev-parse", "refs/remotes/origin/main"], in: scene.root).output != tip)
        #expect(head(scene.root) == before)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
