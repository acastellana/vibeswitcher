import Foundation

/// push_remote: the lead asks to push the base branch to the project's remote, and only your click in VibeSwitcher
/// pushes it, each time (decision F6BE148C).
/// - The lead's tool records a request in the session host's vault (`LeadVault.requestPush`, the repository's lead
///   only): the base's head now, how many commits it's ahead of the remote's tip fetch_remote fetched, their
///   subjects, and the remote, its URL and the branch from workflow.md, never from the call's arguments. A newer
///   request replaces an open one. It never waits: the reply says it's waiting for your click.
/// - Nothing a session can write approves one. The request isn't a file, and the vault records no approval at all: it
///   hands an open request to the app only (`LeadVault.settlePush`, refused to every session), when you click Push or
///   Decline on its card, and the app, in its own process, runs the push itself (`push`): never the lead's Bash,
///   which stays denied. So an ask_user answer, a board edit, a peer's or lead-mail message, or a tool call pushes
///   nothing.
/// - The push is `git push <the pinned URL> <the approved commit>:refs/heads/<branch>`: that commit even if the base
///   moved on since, no `--force`, `--force-with-lease`, `-f` or `+` refspec, so the remote takes only a
///   fast-forward. Its outcome (pushed, rejected as not a fast-forward, the remote's refusal, an auth or network
///   error with git's own words) goes to the lead as a VibeSwitcher message and to the progress log; so does a decline.
public enum LeadPush {
    /// A push the lead asked for, as the vault keeps it.
    public struct Request: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// The base's head when it was asked: what Push pushes, whatever the base holds by then.
        public var commit: String
        public var remote: String
        /// The branch it goes to on the remote (the base's name, workflow.md's `base`).
        public var branch: String
        /// The remote's URL as the vault pinned it (`LeadRemote.urlKey`) when it was asked.
        public var url: String
        /// How many commits `commit` is ahead of the remote's tip as fetch_remote fetched it.
        public var ahead: Int
        /// Those commits, `<short sha> <subject>`, newest first (at most `subjectLimit`).
        public var subjects: [String]
        public var askedAt: Double

        public init(id: String = LeadPush.newID(), commit: String, remote: String, branch: String, url: String, ahead: Int,
                    subjects: [String], askedAt: Double = Date().timeIntervalSince1970) {
            self.id = id
            self.commit = commit
            self.remote = remote
            self.branch = branch
            self.url = url
            self.ahead = ahead
            self.subjects = subjects
            self.askedAt = askedAt
        }

        /// `origin/main`.
        public var target: String { "\(remote)/\(branch)" }
        public var short: String { String(commit.prefix(8)) }
    }

    public static let subjectLimit = 30
    /// How long the push may run.
    public static let timeout: TimeInterval = 600

    public static func newID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    /// Why the vault doesn't keep `request` (nil: it does): a whole commit, a remote's name, a branch's name, an id.
    static func invalid(_ request: Request) -> String? {
        guard LeadVault.isFullCommit(request.commit.lowercased()) else { return "A push request names a whole commit." }
        guard LeadRemote.isName(request.remote) else { return "A push request names a remote by its name." }
        guard isBranchName(request.branch) else { return "A push request names a branch." }
        guard !request.id.isEmpty, request.id.count <= 64, request.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return "A push request has an id." }
        guard request.ahead > 0, request.subjects.count <= subjectLimit, !request.url.isEmpty else { return "A push request has commits to push." }
        return nil
    }

    /// A branch's name as a push's destination takes it: no option, no refspec characters, no `..`.
    static func isBranchName(_ branch: String) -> Bool {
        guard !branch.isEmpty, branch.count <= 200, !branch.hasPrefix("-"), !branch.hasPrefix("/"), !branch.hasSuffix("/"),
              !branch.hasSuffix(".lock"), !branch.contains(".."), !branch.contains("//"), !branch.contains("@{") else { return false }
        let forbidden = CharacterSet(charactersIn: ":+^~?*[\\ \t\n\r").union(.controlCharacters)
        return branch.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    /// How a push (or the click that didn't push) came out.
    public enum Outcome: Equatable, Sendable {
        /// The remote's branch is at the commit now (`created`: it had no such branch).
        case pushed(created: Bool)
        /// The remote's branch was at the commit already.
        case upToDate
        /// Refused as not a fast-forward of the remote's branch (it has commits the request's lacks): git's words.
        case notFastForward(String)
        /// The remote refused it (a protected branch, a hook): git's words.
        case remoteRejected(String)
        /// git push failed without a ref's verdict: authentication, the network, anything else git says.
        case failed(String)
        /// Not run: a check before it failed (the URL changed, the config could steer it…).
        case refused(String)
        /// You clicked Decline.
        case declined
        /// No open request had that id (a newer one replaced it, or it was settled already).
        case gone

        public var pushed: Bool {
            switch self {
            case .pushed, .upToDate: return true
            default: return false
            }
        }
    }

    /// The push's arguments: `url` (given, not the remote's name: git doesn't look the remote up again), only
    /// `commit` to `refs/heads/<branch>`. No force in any spelling; no tags, submodules, signing or hooks (the app's
    /// push runs nothing of the repository's); git's own receive-pack; the transports and credential helpers as
    /// fetch_remote's (`LeadRemote.fetchArguments`).
    static func arguments(url: String, commit: String, branch: String, helpers: [String]) -> [String] {
        let open = LeadRemote.transports.flatMap { ["-c", "protocol.\($0).allow=always"] }
        return open + ["-c", "credential.helper="] + helpers
            + ["-c", "push.followTags=false", "-c", "push.gpgSign=false", "-c", "push.recurseSubmodules=no",
               "push", "--porcelain", "--no-verify", "--no-follow-tags", "--recurse-submodules=no", "--no-signed", "--no-atomic",
               "--receive-pack=git-receive-pack", "--", url, "\(commit):refs/heads/\(branch)"]
    }

    /// The app's push of `request` (on your click, never a session's): checked again first, as git will run it — the
    /// commit is one, the remote's URL is still the one the vault pinned (`pinned`, its hash) and the request names,
    /// and git runs where the repository's own config isn't read (`LeadRemote.transportGit`, in `scratch`), so nothing
    /// there (`url.*.pushInsteadOf`, `http.*`, a `remote.<url>` section) steers it, then or after any check.
    public static func push(_ request: Request, root: String, pinned: String?, scratch: URL, timeout: TimeInterval = timeout) -> Outcome {
        if let invalid = invalid(request) { return .refused(invalid) }
        guard Git.run(["check-ref-format", "--branch", request.branch], in: root).ok else { return .refused("\(request.branch) isn't a branch's name.") }
        guard Git.run(["cat-file", "-e", request.commit + "^{commit}"], in: root).ok else {
            return .refused("\(request.short) isn't a commit in this repository any more.")
        }
        let url: String
        switch LeadRemote.url(root: root, remote: request.remote) {
        case .success(let found): url = found
        case .failure(let error): return .refused(error.description)
        }
        guard url == request.url else {
            return .refused("\(request.remote)'s URL is \(url) now, not \(request.url) as when the lead asked: any session can change it (git remote set-url).")
        }
        guard let pinned, pinned == LeadVault.hash(url) else {
            return .refused("\(url) isn't the URL of \(request.remote)'s the lead fetched from (the vault's pin): fetch_remote first, or configure(remote) if the user changed it.")
        }
        let run = LeadRemote.transportGit(arguments(url: url, commit: request.commit, branch: request.branch, helpers: LeadRemote.credentialHelpers(root: root)),
                                          root: root, scratch: scratch, timeout: timeout).run
        return outcome(of: run, branch: request.branch)
    }

    /// What `git push --porcelain` said: its line for `refs/heads/<branch>` (`<flag>\t<from>:<to>\t<summary>`), else
    /// its error.
    static func outcome(of run: Git.Result, branch: String) -> Outcome {
        let destination = ":refs/heads/\(branch)"
        let line = run.output.split(whereSeparator: \.isNewline).map(String.init).first { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            return fields.count >= 3 && fields[1].hasSuffix(destination)
        }
        let said = clip(run.error.isEmpty ? run.output : run.error)
        guard let line, !run.timedOut, !run.cancelled else {
            return .failed(said.isEmpty ? "git push exited with status \(run.status)." : said)
        }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let (flag, summary) = (fields[0], fields[2])
        switch flag {
        case " ", "*": return run.status == 0 ? .pushed(created: flag == "*") : .failed(said)
        case "=": return .upToDate
        case "!":
            let words = summary + (said.isEmpty ? "" : "\n" + said)
            return summary.hasPrefix("[remote rejected]") ? .remoteRejected(clip(words)) : .notFastForward(clip(words))
        default:
            // "+" (forced) or "-" (deleted) can't come from these arguments: said as they are.
            return .failed("git push said \(line)")
        }
    }

    static func clip(_ text: String, _ limit: Int = 1200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.suffix(limit)) : trimmed
    }

    /// Your click on request `id`, in the app: the vault hands the request over (only to the app) and takes it off,
    /// then Push pushes it (`push`) and Decline doesn't; the progress log says which and how it went. `gone` when no
    /// open request has that id.
    public static func settle(id: String, root: String, push approve: Bool, vault: LeadVault,
                              timeout: TimeInterval = timeout) -> (request: Request?, outcome: Outcome) {
        let request: Request?
        do { request = try vault.settlePush(id: id, root: root) } catch {
            return (nil, .refused("The session host didn't hand the request over: \(error)"))
        }
        guard let request else { return (nil, .gone) }
        let outcome: Outcome
        if !approve {
            outcome = .declined
        } else {
            do {
                let pinned = try vault.guardedSettings(root: root)?[LeadRemote.urlKey(request.remote)]
                let scratch = vault.scratch(root: root, "remote-git")
                try vault.ensurePrivate(scratch)
                outcome = push(request, root: root, pinned: pinned, scratch: scratch, timeout: timeout)
            } catch {
                outcome = .refused("Couldn't get ready to push (which URL of \(request.remote)'s the lead fetched from, or a scratch folder): \(error)")
            }
        }
        try? BoardStore(root: root).appendProgress(progressLine(request, outcome))
        return (request, outcome)
    }

    /// What the lead is told of it (a VibeSwitcher message).
    public static func message(_ request: Request, _ outcome: Outcome) -> String {
        let asked = "your push request \(request.id) (\(request.branch) at \(request.short), \(LeadToolset.commits(request.ahead)) ahead, to \(request.target), \(request.url))"
        switch outcome {
        case .pushed(let created):
            return "The user clicked Push on \(asked): pushed. \(request.target) is at \(request.short) now"
                + (created ? " (a new branch there)." : ", a fast-forward.")
        case .upToDate:
            return "The user clicked Push on \(asked): \(request.target) was at \(request.short) already; nothing to push."
        case .notFastForward(let said):
            return "The user clicked Push on \(asked): rejected, it isn't a fast-forward of \(request.target) (the remote has commits \(request.short) lacks). Nothing was forced, nothing was pushed. "
                + "fetch_remote, then merge_remote, then push_remote again. git said:\n\(said)"
        case .remoteRejected(let said):
            return "The user clicked Push on \(asked): the remote refused it; nothing was pushed. git said:\n\(said)"
        case .failed(let said):
            return "The user clicked Push on \(asked): git push failed (authentication or the network?); nothing was pushed. git said:\n\(said)"
        case .refused(let why):
            return "The user clicked Push on \(asked), but VibeSwitcher didn't push it: \(why)"
        case .declined:
            return "The user declined \(asked): nothing was pushed."
        case .gone:
            return "The user's click on push request \(request.id) found it no longer open: nothing was pushed."
        }
    }

    /// The progress log's line for it.
    public static func progressLine(_ request: Request, _ outcome: Outcome) -> String {
        let what = "\(request.branch) at \(request.short) (\(LeadToolset.commits(request.ahead))) to \(request.target)"
        switch outcome {
        case .pushed: return "Pushed \(what), on the user's click"
        case .upToDate: return "Push of \(what): already there"
        case .notFastForward: return "Push of \(what) rejected: not a fast-forward; nothing forced"
        case .remoteRejected: return "Push of \(what) refused by the remote"
        case .failed(let said): return "Push of \(what) failed: \(clip(said.replacingOccurrences(of: "\n", with: " "), 200))"
        case .refused(let why): return "Push of \(what) not run: \(clip(why.replacingOccurrences(of: "\n", with: " "), 200))"
        case .declined: return "The user declined the push of \(what)"
        case .gone: return "Push request \(request.id) was no longer open"
        }
    }
}

// MARK: The vault

extension LeadVault {
    /// The repository's lead asks to push (`LeadPush`): it replaces an open request.
    public func requestPush(_ request: LeadPush.Request, root: String) throws {
        _ = try call(.requestPush(root: root, push: request))
    }

    /// The open push request, if any (the app, or the repository's lead).
    public func pushRequest(root: String) throws -> LeadPush.Request? {
        guard case .push(let request) = try call(.pushRequest(root: root)) else { throw Self.unexpected }
        return request
    }

    /// The app only, on your click: the open request with this id, taken off (nil when none has it).
    public func settlePush(id: String, root: String) throws -> LeadPush.Request? {
        guard case .push(let request) = try call(.settlePush(root: root, id: id)) else { throw Self.unexpected }
        return request
    }
}

// MARK: The lead's tool

extension LeadToolset {
    /// push_remote: records a push request (`LeadPush`) for your click; pushes nothing and never waits. Takes no
    /// arguments: the remote, its URL and the branch are workflow.md's and the vault's, the commit is the base's head.
    func pushRemote() throws -> MCPToolResult {
        let workflow = self.workflow
        let not = "Not asked (nothing was pushed)"
        try checkSettings(workflow, not: not, keys: ["remote"])
        let (remote, base) = (workflow.remoteName, workflow.base)
        let label = "\(remote)/\(base)"
        guard LeadPush.isBranchName(base) else { throw Problem(text: "\(not): the base branch \"\(base)\" isn't a branch's name a push can take.") }
        let url = try pinnedURL(remote, not: not, first: false).url
        guard let head = branchHead(base) else { throw Problem(text: "\(not): there's no branch \(base) to push.") }
        try checkBaseMoves(base: base, current: head)
        // The remote's tip as fetch_remote fetched it, as the vault keeps it.
        let ref = LeadRemote.trackingRef(remote: remote, branch: base)
        let tracked = Git.run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: root).output
        guard let fetched = vault.head(root: root, branch: ref), !tracked.isEmpty else {
            throw Problem(text: "\(not): fetch_remote hasn't fetched \(label) yet. Run it first: a push is asked for only on top of what it fetched.")
        }
        guard fetched == tracked else {
            throw Problem(text: "\(not): \(label) is at \(tracked.prefix(8)), not where fetch_remote left it (\(fetched.prefix(8))): something else moved it. Run fetch_remote again.")
        }
        guard Git.run(["merge-base", "--is-ancestor", fetched, head], in: root).ok else {
            throw Problem(text: "\(not): \(label) (\(fetched.prefix(8))) has commits \(base) lacks, so the push wouldn't be a fast-forward. Run merge_remote first (after fetch_remote), then push_remote.")
        }
        let ahead = Int(Git.run(["rev-list", "--count", "\(fetched)..\(head)"], in: root).output) ?? 0
        guard ahead > 0 else {
            throw Problem(text: "Nothing to push: \(base) (\(head.prefix(8))) has nothing \(label) hasn't, as fetch_remote last fetched it.")
        }
        let log = Git.run(["log", "--format=%h %s", "--max-count=\(LeadPush.subjectLimit)", "\(fetched)..\(head)"], in: root)
        let subjects = log.output.split(whereSeparator: \.isNewline).map { Self.clip(String($0), 200) }
        let replaced: LeadPush.Request?
        do { replaced = try vault.pushRequest(root: root) } catch { throw Problem(text: "\(not): the session host couldn't be asked (\(error)).") }
        let request = LeadPush.Request(commit: head, remote: remote, branch: base, url: url, ahead: ahead, subjects: subjects)
        do { try vault.requestPush(request, root: root) } catch { throw Problem(text: "\(not): the session host didn't record the request (\(error)).") }
        try? store.appendProgress("Asked the user to push \(base) at \(head.prefix(8)) (\(Self.commits(ahead))) to \(label)")
        var lines = ["Push request \(request.id): \(base) at \(head.prefix(8)), \(Self.commits(ahead)) ahead of \(label), to \(url). "
                     + "Waiting for the user's click: nothing is pushed until they click Push on its card in VibeSwitcher (Decline pushes nothing). "
                     + "Don't wait on it: the outcome comes as a VibeSwitcher message. Push pushes \(head.prefix(8)) itself, as a fast-forward only, even if \(base) moves on meanwhile; push_remote again asks for a newer head."]
        if let replaced { lines.append("It replaces your open request \(replaced.id) (\(replaced.short)).") }
        lines.append("The commits, newest first\(ahead > subjects.count ? " (the first \(subjects.count))" : ""):")
        lines += subjects.map { "- \($0)" }
        return MCPToolResult(text: lines.joined(separator: "\n"))
    }

    /// `remote`'s URL now (`LeadRemote.url`), when it's the one the vault pinned; `first`: none pinned yet pins it
    /// (fetch_remote's first fetch), else none pinned is refused (a push goes only where the lead fetched from).
    func pinnedURL(_ remote: String, not: String, first: Bool) throws -> (url: String, first: Bool) {
        let url: String
        switch LeadRemote.url(root: root, remote: remote) {
        case .success(let found): url = found
        case .failure(let error): throw Problem(text: error.description)
        }
        let pinned: String?
        do { pinned = try vault.guardedSettings(root: root)?[LeadRemote.urlKey(remote)] } catch {
            throw Problem(text: "\(not): the session host couldn't say which URL of \(remote)'s you took (\(error)).")
        }
        if let pinned, pinned != LeadVault.hash(url) {
            throw Problem(text: "\(not): \(remote)'s URL is now \(url), not the one you fetched from before. Any session can change it (git remote set-url), so a worker's repository could stand in for the remote. "
                          + "Ask the user whether they changed it; if they did, configure(remote: \"\(remote)\") takes the URL it has now, and fetch_remote fetches from it.")
        }
        if pinned == nil {
            guard first else { throw Problem(text: "\(not): fetch_remote hasn't fetched from \(remote) yet. Run it first.") }
            try vault.setGuardedSettings([LeadRemote.urlKey(remote): LeadVault.hash(url)], root: root)
        }
        return (url, pinned == nil)
    }
}
