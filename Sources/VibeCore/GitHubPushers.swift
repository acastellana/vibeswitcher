import Foundation

/// Who pushed a commit to GitHub: the handle ("@login") on the update card's GitHub-only changes and in fetch_remote's
/// and merge_remote's incoming commits. Git's author names aren't GitHub handles, and the project takes direct pushes
/// from two Macs (no pull requests), so the handle comes from GitHub's record of the push: the repository's activity
/// (`GET repos/{owner}/{repo}/activity?ref=refs/heads/{branch}`: each push's actor, before and after), read through the
/// user's own `gh` as it's signed in. A commit is the push's whose `before..after` holds it (`git rev-list`, on the
/// fetched objects).
///
/// Read-only, and never in the way: GET only, `gh api` alone (the token stays gh's: never read, kept, logged or passed
/// on), a few seconds at most, once per fetched tip (cached). Without an answer (no gh, signed out, offline, too old a
/// push for GitHub's record, a remote that isn't github.com), commits just have no handle.
public enum GitHubPushers {
    /// How long one `gh api` call may take.
    public static let timeout: TimeInterval = 5
    /// The pushes read: one page, GitHub's largest.
    static let pageSize = 100

    /// A github.com repository, as its URL names it.
    public struct Repository: Hashable, Sendable {
        public var owner: String
        public var name: String
        public init(owner: String, name: String) {
            self.owner = owner
            self.name = name
        }
    }

    /// One push (or force-push) to the branch: who, and the branch's tip before and after it.
    public struct Push: Equatable, Sendable {
        public var login: String
        public var before: String
        public var after: String
        public init(login: String, before: String, after: String) {
            self.login = login
            self.before = before
            self.after = after
        }
    }

    /// The repository a github.com remote URL names (`https://github.com/o/r(.git)`, `git@github.com:o/r.git`,
    /// `ssh://git@github.com/o/r.git`); nil for any other host (a GitHub Enterprise, a path, another forge).
    public static func repository(url: String) -> Repository? {
        var rest: Substring
        if let scheme = url.range(of: "://") {
            guard ["https", "ssh", "git"].contains(url[..<scheme.lowerBound].lowercased()) else { return nil }
            rest = url[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var host = rest[..<slash]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
            guard isGitHub(host) else { return nil }
            rest = rest[rest.index(after: slash)...]
        } else if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
            // scp-like: [user@]host:path
            var host = url[..<colon]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            guard isGitHub(host) else { return nil }
            rest = url[url.index(after: colon)...]
        } else {
            return nil
        }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(isPathName) else { return nil }
        return Repository(owner: String(parts[0]), name: String(parts[1]))
    }

    private static func isGitHub(_ host: Substring) -> Bool {
        ["github.com", "www.github.com"].contains(host.lowercased())
    }

    /// An owner's or repository's name as GitHub allows one: letters, digits, `-`, `_`, `.`; never `.` or `..`.
    private static func isPathName(_ name: Substring) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return !name.isEmpty && name.count <= 100 && name != "." && name != ".." && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// A handle as GitHub gives one (letters, digits and `-`, an app's with `[bot]`); anything else isn't shown.
    static func isLogin(_ login: String) -> Bool {
        let name = login.hasSuffix("[bot]") ? String(login.dropLast(5)) : login
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return !name.isEmpty && name.count <= 39 && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func isCommitID(_ id: String) -> Bool {
        (id.count == 40 || id.count == 64) && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    /// The activity API's endpoint for `branch`'s pushes.
    static func endpoint(_ repository: Repository, branch: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        let ref = ("refs/heads/" + branch).addingPercentEncoding(withAllowedCharacters: safe) ?? "refs/heads/main"
        return "repos/\(repository.owner)/\(repository.name)/activity?ref=\(ref)&per_page=\(pageSize)"
    }

    /// The pushes in the activity API's answer, newest first as it gives them: those with a handle and both tips
    /// (a branch's creation or deletion has an all-zero one, and holds nothing to attribute). Nil when it isn't one.
    static func pushes(_ data: Data) -> [Push]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let zero = { (id: String) in id.allSatisfy { $0 == "0" } }
        return list.compactMap { entry in
            guard let login = (entry["actor"] as? [String: Any])?["login"] as? String, isLogin(login),
                  let before = entry["before"] as? String, let after = entry["after"] as? String,
                  isCommitID(before), isCommitID(after), !zero(before), !zero(after) else { return nil }
            return Push(login: login, before: before, after: after)
        }
    }

    /// Each of `commits` (full ids) that a push's `before..after` holds, with that push's handle: the newest push
    /// first, so a force-push that brings old commits back names who put them there now. A push whose tips this
    /// repository doesn't hold (force-pushed away, never fetched) is passed over.
    public static func attribute(_ commits: [String], pushes: [Push], root: String) -> [String: String] {
        var wanted = Set(commits)
        var found: [String: String] = [:]
        for push in pushes where !wanted.isEmpty {
            let range = Git.run(["rev-list", "\(push.before)..\(push.after)"], in: root, timeout: 30)
            guard range.ok else { continue }
            for id in range.output.split(whereSeparator: \.isNewline).map(String.init) where wanted.contains(id) {
                found[id] = push.login
                wanted.remove(id)
            }
        }
        return found
    }

    /// The text a commit's line gets: " (pushed by @login)", or nothing.
    public static func note(_ login: String?) -> String {
        login.map { " (pushed by @\($0))" } ?? ""
    }

    // MARK: gh

    /// Where `gh` is: on `path` (the process's PATH), else where Homebrew puts it (an app started from the Finder has
    /// neither /opt/homebrew/bin nor /usr/local/bin on its PATH). Nil when it isn't installed.
    public static func ghExecutable(path: String? = ProcessInfo.processInfo.environment["PATH"],
                                    fallbacks: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> String? {
        let dirs = (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") } + fallbacks
        return dirs.map { $0 + "/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `gh api`'s answer to a GET of `endpoint` on github.com, or nil: no gh, signed out (it exits non-zero), offline,
    /// or past `timeout`. What gh says on stderr isn't kept.
    public static func ghGet(_ endpoint: String, executable: String?, timeout: TimeInterval = GitHubPushers.timeout) -> Data? {
        guard let executable else { return nil }
        let env = ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_SPINNER_DISABLED": "1", "NO_COLOR": "1",
                   "GH_PAGER": "cat", "PAGER": "cat"]
        let result = Shell.run(executable: executable, args: ["api", "--hostname", "github.com", "--method", "GET", endpoint],
                               in: "/", env: env, timeout: timeout, grace: 1)
        guard result.ok, !result.output.isEmpty else { return nil }
        return Data(result.output.utf8)
    }

    // MARK: The lookup

    /// The lookup, cached per fetched tip: a repeated check of the same tip (the update card's minute looks, a
    /// fetch_remote that found nothing new) doesn't ask GitHub again, whatever it answered the first time.
    public final class Lookup: @unchecked Sendable {
        /// GitHub's activity for a repository's branch (`ghGet`), or nil.
        let fetch: (_ repository: Repository, _ branch: String) -> Data?
        /// The github.com repository a remote's URL names (`repository(url:)`).
        let repository: (_ url: String) -> Repository?
        private let lock = NSLock()
        private var cache: [String: [Push]] = [:]
        /// Per tip: the commits matched to its pushes so far, and the handles found for them.
        private var looked: [String: Set<String>] = [:]
        private var named: [String: [String: String]] = [:]
        /// How many times GitHub was asked (the cache's tests).
        public var asked: Int { lock.withLock { askedCount } }
        private var askedCount = 0

        public init(fetch: @escaping (_ repository: Repository, _ branch: String) -> Data?,
                    repository: @escaping (_ url: String) -> Repository? = GitHubPushers.repository(url:)) {
            self.fetch = fetch
            self.repository = repository
        }

        /// Through the user's gh.
        public static func gh(executable: @escaping () -> String? = { GitHubPushers.ghExecutable() },
                              timeout: TimeInterval = GitHubPushers.timeout) -> Lookup {
            Lookup(fetch: { repository, branch in
                GitHubPushers.ghGet(GitHubPushers.endpoint(repository, branch: branch), executable: executable(), timeout: timeout)
            })
        }

        /// Never asks anyone: no handles.
        public static let none = Lookup(fetch: { _, _ in nil }, repository: { _ in nil })

        /// The handle that pushed each of `commits` that GitHub's record of `branch` holds, `tip` being the branch's
        /// tip as fetched from `url`. Empty when `url` isn't github.com or GitHub didn't answer.
        public func pushers(root: String, url: String, branch: String, tip: String, commits: [String]) -> [String: String] {
            guard !commits.isEmpty, let repository = repository(url) else { return [:] }
            let key = "\(repository.owner)/\(repository.name) \(branch) \(tip)"
            // Held through the fetch (a few seconds at most, once per tip), so two checks of one tip at once ask once.
            let found: [Push] = lock.withLock {
                if let cached = cache[key] { return cached }
                askedCount += 1
                let fetched = fetch(repository, branch).flatMap(GitHubPushers.pushes) ?? []
                cache[key] = fetched
                return fetched
            }
            guard !found.isEmpty else { return [:] }
            // Commits already matched for this tip aren't matched again (the card's minute looks ask for the same
            // ones): only the new ones go through git.
            let (known, matched) = lock.withLock { (looked[key] ?? [], named[key] ?? [:]) }
            let fresh = commits.filter { !known.contains($0) }
            let more = fresh.isEmpty ? [:] : GitHubPushers.attribute(fresh, pushes: found, root: root)
            let all = matched.merging(more) { $1 }
            lock.withLock {
                looked[key, default: []].formUnion(fresh)
                named[key] = all
            }
            return all.filter { commits.contains($0.key) }
        }
    }

    /// The app's and the lead's: through the user's gh.
    public static let shared = Lookup.gh()
}
