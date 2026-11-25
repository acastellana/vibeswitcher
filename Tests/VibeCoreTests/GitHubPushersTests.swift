import Foundation
import Testing
@testable import VibeCore

/// GitHub's activity API's answer for `pushes` (newest first, as GitHub lists them).
func activityJSON(_ pushes: [(login: String, before: String, after: String)]) -> Data {
    let list: [[String: Any]] = pushes.map {
        ["id": 1, "before": $0.before, "after": $0.after, "ref": "refs/heads/main", "activity_type": "push",
         "timestamp": "2026-11-24T08:05:53Z", "actor": ["login": $0.login, "id": 1, "type": "User"]]
    }
    return (try? JSONSerialization.data(withJSONObject: list)) ?? Data()
}

/// A lookup that takes any remote URL for one made-up github.com repository and answers with `answer` (nil: no
/// answer), counting the calls. Never a real GitHub.
func fakePushers(_ answer: @escaping () -> Data?) -> GitHubPushers.Lookup {
    GitHubPushers.Lookup(fetch: { _, _ in answer() }, repository: { _ in GitHubPushers.Repository(owner: "example", name: "app") })
}

/// Who pushed GitHub's commits: the URL's repository, the activity's pushes, a commit's push by its range, the cache,
/// and every way of having no answer (a fake `gh` in a scratch folder: never the real one, never the network).
struct GitHubPushersTests {
    let temp = Scratch()

    @discardableResult
    func git(_ args: [String], in dir: String) -> Git.Result {
        let result = Shell.run(executable: "/usr/bin/git", args: args, in: dir, env: Git.environment, timeout: 60, grace: 1)
        #expect(result.status == 0, "git \(args.joined(separator: " ")): \(result.error)")
        return result
    }

    /// A repository with a first commit, then two pushes' worth: alice's two commits, then bob's one.
    struct Pushes {
        let root: String
        let base: String
        let alice: [String]
        let bob: String
        var json: Data { activityJSON([("bob", alice[1], bob), ("alice", base, alice[1])]) }
    }

    func makePushes() throws -> Pushes {
        let root = temp.url("pushers").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { git(args, in: root) }
        func commit(_ message: String) -> String {
            git(["commit", "-q", "--allow-empty", "-m", message], in: root)
            return git(["rev-parse", "HEAD"], in: root).output
        }
        let base = commit("first")
        let alice = [commit("alice one"), commit("alice two")]
        return Pushes(root: root, base: base, alice: alice, bob: commit("bob one"))
    }

    /// A fake `gh` in a scratch folder: `body` as its shell script.
    func fakeGh(_ body: String) throws -> String {
        let dir = temp.url("fake-gh")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("gh").path
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func onlyGitHubDotComRemotesNameARepository() {
        let repo = GitHubPushers.Repository(owner: "acme", name: "vibe.switcher")
        for url in ["https://github.com/acme/vibe.switcher.git", "https://github.com/acme/vibe.switcher", "https://user@GitHub.com/acme/vibe.switcher/",
                    "git@github.com:acme/vibe.switcher.git", "ssh://git@github.com/acme/vibe.switcher.git", "ssh://git@github.com:22/acme/vibe.switcher"] {
            #expect(GitHubPushers.repository(url: url) == repo, "\(url)")
        }
        // A GitHub Enterprise, another forge, a path, a helper, or a path that isn't owner/name: no repository.
        for url in ["https://github.example.com/acme/app.git", "gitlab.com:acme/app.git", "/Users/me/origin.git", "file:///tmp/origin.git",
                    "https://github.com/acme", "https://github.com/acme/app/extra", "https://github.com/../app", "https://github.com/acme/a%2Fb",
                    "https://github.com.evil.example/acme/app", "http://github.com/acme/app"] {
            #expect(GitHubPushers.repository(url: url) == nil, "\(url)")
        }
    }

    @Test func eachCommitIsThePushWhoseRangeHoldsIt() throws {
        let scene = try makePushes()
        let pushes = try #require(GitHubPushers.pushes(scene.json))
        #expect(pushes.map(\.login) == ["bob", "alice"])
        let found = GitHubPushers.attribute(scene.alice + [scene.bob, scene.base], pushes: pushes, root: scene.root)
        #expect(found == [scene.alice[0]: "alice", scene.alice[1]: "alice", scene.bob: "bob"], "\(found)")
        // A push this repository doesn't hold the tips of (force-pushed away) is passed over; a branch's creation
        // (all-zero before) and a login GitHub wouldn't give are left out.
        let unknown = String(repeating: "e", count: 40), zero = String(repeating: "0", count: 40)
        let odd = try #require(GitHubPushers.pushes(activityJSON([("carol", unknown, scene.bob), ("dave", zero, scene.base),
                                                                   ("bad name", scene.alice[1], scene.bob), ("alice", scene.base, scene.alice[1])])))
        #expect(odd.map(\.login) == ["carol", "alice"])
        #expect(GitHubPushers.attribute([scene.bob, scene.alice[0]], pushes: odd, root: scene.root) == [scene.alice[0]: "alice"])
        #expect(GitHubPushers.pushes(Data("{\"message\":\"Not Found\"}".utf8)) == nil)
        #expect(GitHubPushers.isLogin("github-actions[bot]") && !GitHubPushers.isLogin("a/b") && !GitHubPushers.isLogin(""))
    }

    @Test func theLookupAsksOncePerTip() throws {
        let scene = try makePushes()
        let lookup = fakePushers { scene.json }
        let url = "https://github.com/example/app.git"
        let first = lookup.pushers(root: scene.root, url: url, branch: "main", tip: scene.bob, commits: [scene.bob])
        #expect(first == [scene.bob: "bob"])
        // The same tip again (the card's minute looks, a check after it): GitHub isn't asked again.
        for _ in 0..<3 {
            #expect(lookup.pushers(root: scene.root, url: url, branch: "main", tip: scene.bob, commits: scene.alice) == [scene.alice[0]: "alice", scene.alice[1]: "alice"])
        }
        #expect(lookup.asked == 1)
        // Nothing to name: not asked at all.
        #expect(lookup.pushers(root: scene.root, url: url, branch: "main", tip: "f" + scene.bob.dropFirst(), commits: []).isEmpty)
        #expect(lookup.asked == 1)
        // A new tip: asked once more.
        _ = lookup.pushers(root: scene.root, url: url, branch: "main", tip: scene.alice[1], commits: [scene.bob])
        #expect(lookup.asked == 2)
        // No answer is kept too: a failing GitHub isn't asked again for that tip.
        let silent = fakePushers { nil }
        for _ in 0..<2 { #expect(silent.pushers(root: scene.root, url: url, branch: "main", tip: scene.bob, commits: [scene.bob]).isEmpty) }
        #expect(silent.asked == 1)
    }

    @Test func aRemoteThatIsntGitHubDotComIsNeverAsked() throws {
        let scene = try makePushes()
        let lookup = GitHubPushers.Lookup(fetch: { _, _ in scene.json })
        for url in [scene.root, "https://github.example.com/example/app.git", "gitlab.com:example/app.git"] {
            #expect(lookup.pushers(root: scene.root, url: url, branch: "main", tip: scene.bob, commits: [scene.bob]).isEmpty)
        }
        #expect(lookup.asked == 0)
        #expect(GitHubPushers.Lookup.none.pushers(root: scene.root, url: "https://github.com/example/app", branch: "main", tip: scene.bob, commits: [scene.bob]).isEmpty)
    }

    /// The real gh path, with a fake gh: a GET of the activity endpoint on github.com, nothing else.
    @Test func ghIsAskedForAGetOfTheActivityAlone() throws {
        let scene = try makePushes()
        let answer = temp.url("answer.json")
        try scene.json.write(to: answer)
        let argsFile = temp.url("args.txt")
        let gh = try fakeGh("printf '%s\\n' \"$@\" > '\(argsFile.path)'\ncat '\(answer.path)'")
        let lookup = GitHubPushers.Lookup.gh(executable: { gh })
        let found = lookup.pushers(root: scene.root, url: "git@github.com:acme/app.git", branch: "main", tip: scene.bob, commits: [scene.bob, scene.alice[0]])
        #expect(found == [scene.bob: "bob", scene.alice[0]: "alice"])
        let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args == ["api", "--hostname", "github.com", "--method", "GET", "repos/acme/app/activity?ref=refs/heads/main&per_page=100"])
    }

    @Test func noGhNoHandles() throws {
        let scene = try makePushes()
        let empty = temp.url("no-gh")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(GitHubPushers.ghExecutable(path: empty.path, fallbacks: []) == nil)
        let lookup = GitHubPushers.Lookup.gh(executable: { GitHubPushers.ghExecutable(path: empty.path, fallbacks: []) })
        #expect(lookup.pushers(root: scene.root, url: "https://github.com/acme/app", branch: "main", tip: scene.bob, commits: [scene.bob]).isEmpty)
        // Found on PATH, or where Homebrew puts it.
        let gh = try fakeGh("exit 0")
        let dir = (gh as NSString).deletingLastPathComponent
        #expect(GitHubPushers.ghExecutable(path: "relative:" + dir, fallbacks: []) == gh)
        #expect(GitHubPushers.ghExecutable(path: empty.path, fallbacks: [dir]) == gh)
    }

    @Test func aSignedOutGhNoHandles() throws {
        let scene = try makePushes()
        let gh = try fakeGh("echo 'To get started with GitHub CLI, please run:  gh auth login' >&2\nexit 4")
        let lookup = GitHubPushers.Lookup.gh(executable: { gh })
        #expect(lookup.pushers(root: scene.root, url: "https://github.com/acme/app", branch: "main", tip: scene.bob, commits: [scene.bob]).isEmpty)
        // An answer that isn't the activity (an error's JSON on stdout, exit 0): none either.
        let odd = try fakeGh("echo '{\"message\":\"Bad credentials\"}'")
        #expect(GitHubPushers.Lookup.gh(executable: { odd }).pushers(root: scene.root, url: "https://github.com/acme/app", branch: "main",
                                                                    tip: scene.bob, commits: [scene.bob]).isEmpty)
    }

    /// A gh that doesn't answer is stopped at the timeout: the lookup returns without its answer.
    @Test func aHungGhIsStoppedAtTheTimeout() throws {
        let scene = try makePushes()
        let started = temp.url("started")
        let gh = try fakeGh("echo $$ > '\(started.path)'\nexec sleep 600")
        let lookup = GitHubPushers.Lookup.gh(executable: { gh }, timeout: 2)
        #expect(lookup.pushers(root: scene.root, url: "https://github.com/acme/app", branch: "main", tip: scene.bob, commits: [scene.bob]).isEmpty)
        // It ran, and was stopped rather than waited for: by the time the lookup is back, the fake gh is gone.
        let pid = try #require(Int32(try String(contentsOf: started, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(GitHubPushers.timeout <= 10)
    }

    @Test func noMatchingPushNoHandles() throws {
        let scene = try makePushes()
        // GitHub's record holds only bob's push (alice's too old for it).
        let lookup = fakePushers { activityJSON([("bob", scene.alice[1], scene.bob)]) }
        let found = lookup.pushers(root: scene.root, url: "https://github.com/example/app", branch: "main", tip: scene.bob, commits: scene.alice + [scene.bob])
        #expect(found == [scene.bob: "bob"])
        #expect(GitHubPushers.note(found[scene.alice[0]]) == "" && GitHubPushers.note("bob") == " (pushed by @bob)")
    }
}
