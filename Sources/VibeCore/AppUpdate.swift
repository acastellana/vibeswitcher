import Foundation

/// The app's own update check: whether the source checkout VibeSwitcher is built from (`scripts/build-app.sh --install`)
/// holds commits to what the build reads that the installed build (`ServerBuild`) lacks, on this Mac's main or on
/// GitHub's (the checkout's remote, fetched read-only into its remote-tracking ref, as fetch_remote does).
///
/// Commits only GitHub has wait for the project's lead (fetch_remote, then merge_remote, which tests them before main
/// moves): the app never moves main itself. Commits on this Mac's main install at once, with the user's click: a shell
/// session in the checkout that asks for the signing keychain's password (`installCommand`).
public enum AppUpdate {
    /// What the build reads: build-app.sh's `source_state` list. A commit touching none of it (the lead's records under
    /// docs/, say) makes no new version.
    public static let buildPaths = ["Sources", "Package.swift", "Package.resolved", "scripts/build-app.sh", "scripts/lib", "Resources", "Web"]

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// One commit of the changelog.
    public struct Change: Codable, Equatable, Sendable {
        public var id: String
        public var subject: String
        public init(id: String, subject: String) {
            self.id = id
            self.subject = subject
        }
    }

    /// A newer version: what it holds, and whether it can be installed now.
    public struct Offer: Codable, Equatable, Sendable {
        /// The installed build's commit.
        public var installed: String
        /// The base branch (main) as it was looked at, and the remote's tip as last fetched (nil: never fetched).
        public var head: String
        public var tip: String?
        /// The newest commit to what the build reads: "this version", which Later snoozes. Not the branch's tip, which
        /// the lead's records commits move all day.
        public var newest: String
        /// The commits to what the build reads that the installed build lacks, newest first: main's, and GitHub's.
        public var changes: [Change]
        /// How many of `changes` only GitHub has: the project's lead merges them first (merge_remote). 0: ready.
        public var waiting: Int
        /// A plain-language summary on top of the changes (`summarize`); nil: the subjects alone.
        public var summary: String?

        public init(installed: String, head: String, tip: String?, newest: String, changes: [Change], waiting: Int, summary: String? = nil) {
            self.installed = installed
            self.head = head
            self.tip = tip
            self.newest = newest
            self.changes = changes
            self.waiting = waiting
            self.summary = summary
        }

        /// Install & Restart can go: main holds all of it.
        public var ready: Bool { waiting == 0 }
    }

    /// The commits to what the build reads in `targets` and not in `installed`, newest first (merges left out: their
    /// subjects say nothing of what changed). Nil when git failed.
    static func changes(root: String, from installed: String, to targets: [String], excluding: [String] = []) -> [Change]? {
        let log = Git.run(["log", "--no-merges", "--format=%H%x09%s"] + targets + (["^" + installed] + excluding.map { "^" + $0 })
                          + ["--"] + buildPaths, in: root, timeout: 60)
        guard log.ok else { return nil }
        return log.output.split(whereSeparator: \.isNewline).map { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return Change(id: String(parts[0]), subject: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// What `root`'s `base` (main) and `remote`/`base` (as last fetched) hold for the build that `installed` lacks; nil
    /// when there's nothing newer. Fails when it can't be compared: no commit recorded by the build, one this repository
    /// doesn't hold, or a build from neither branch's history (a task's branch).
    public static func find(root: String, remote: String, base: String, installed: ServerBuild?) -> Result<Offer?, Failure> {
        guard let commit = installed?.commit else {
            return .failure(Failure("the installed build recorded no source commit"))
        }
        func resolve(_ ref: String) -> String? {
            let found = Git.run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: root)
            return found.ok && !found.output.isEmpty ? found.output : nil
        }
        guard let head = resolve("refs/heads/\(base)") else { return .failure(Failure("\(root) has no branch \(base)")) }
        guard Git.run(["cat-file", "-e", commit + "^{commit}"], in: root).ok else {
            return .failure(Failure("the installed build's commit \(commit.prefix(12)) isn't in \(root)"))
        }
        let tip = LeadRemote.isName(remote) ? resolve(LeadRemote.trackingRef(remote: remote, branch: base)) : nil
        let within = { (branch: String) in Git.run(["merge-base", "--is-ancestor", commit, branch], in: root).ok }
        guard within(head) || tip.map(within) == true else {
            return .failure(Failure("the installed build's commit \(commit.prefix(12)) isn't on \(base) or \(remote)/\(base)"))
        }
        guard let local = changes(root: root, from: commit, to: [head]),
              let remoteOnly = tip.map({ changes(root: root, from: commit, to: [$0], excluding: [head]) }) ?? [] else {
            return .failure(Failure("git log in \(root) failed"))
        }
        // Both, newest first, as git orders them.
        guard let all = changes(root: root, from: commit, to: [head] + (remoteOnly.isEmpty ? [] : [tip!])), let newest = all.first else {
            return local.isEmpty && remoteOnly.isEmpty ? .success(nil) : .failure(Failure("git log in \(root) failed"))
        }
        return .success(Offer(installed: commit, head: head, tip: tip, newest: newest.id, changes: all, waiting: remoteOnly.count))
    }

    /// Fetches `remote`'s `base` into its remote-tracking ref (`LeadRemote.fetch`: that ref only, nothing else moves),
    /// from the URL the repository's config names, only when it's the one the lead's vault pinned (`pin`, its hash;
    /// `LeadRemote.urlKey`): any session can change a remote's URL, and a worker's repository mustn't stand in for
    /// GitHub. Never pinned (the lead never ran fetch_remote): not fetched.
    public static func fetch(root: String, remote: String, base: String, pin: String?, scratch: URL) -> Result<String, Failure> {
        let url: String
        switch LeadRemote.url(root: root, remote: remote) {
        case .success(let found): url = found
        case .failure(let error): return .failure(Failure(error.description))
        }
        guard let pin else { return .failure(Failure("the lead hasn't fetched \(remote) yet (fetch_remote pins its URL)")) }
        guard pin == LeadVault.hash(url) else {
            return .failure(Failure("\(remote)'s URL isn't the one the lead's fetch_remote took; not fetched"))
        }
        switch LeadRemote.fetch(root: root, remote: remote, url: url, branch: base, scratch: scratch, timeout: 120) {
        case .success(let tip): return .success(tip)
        case .failure(let error): return .failure(Failure(error.description))
        }
    }

    /// VibeSwitcher's own checkout among `roots` (the projects the app's leads run in): the one with the app's build
    /// script and sources, holding `installed`'s commit when one does. Nil when none is.
    public static func sourceCheckout(among roots: [String], installed: ServerBuild?) -> String? {
        let fm = FileManager.default
        let candidates = roots.sorted().filter {
            fm.fileExists(atPath: $0 + "/scripts/build-app.sh") && fm.fileExists(atPath: $0 + "/Sources/VibeSwitcher")
                && fm.fileExists(atPath: $0 + "/Package.swift")
        }
        if let commit = installed?.commit, let holding = candidates.first(where: { Git.run(["cat-file", "-e", commit + "^{commit}"], in: $0).ok }) {
            return holding
        }
        return candidates.first
    }

    // MARK: Install

    /// Where setup-signing.sh keeps the signing keychain build-app.sh signs with.
    public static var signingKeychain: String { VibePaths.home + "/.vibeswitcher/signing/vibeswitcher.keychain-db" }

    /// The install as a shell runs it in the checkout: the signing keychain unlocked first (security asks for its
    /// password there, never stored), then build-app.sh --install, which builds, installs to /Applications and
    /// relaunches the app. Without a signing keychain, the build alone (it signs ad hoc).
    public static func installCommand(keychain: String? = AppUpdate.signingKeychain) -> String {
        let build = "scripts/build-app.sh --install"
        guard let keychain, FileManager.default.fileExists(atPath: keychain) else { return build }
        return "security unlock-keychain \(shellWord(keychain)) && \(build)"
    }

    /// `text` as one shell word: as it is when it's plain, else in single quotes.
    static func shellWord(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Why Install & Restart can't go now, or nil when it can: what the click checks again, as the card may be hours
    /// old. The build is of the checkout's HEAD, so it must be on `base`, holding the offer's commits.
    public static func installRefusal(root: String, base: String, offer: Offer) -> String? {
        guard offer.ready else { return "GitHub's commits aren't on this Mac's \(base) yet: the project's lead merges them first." }
        let branch = Git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
        guard branch.ok, branch.output == base else {
            return "The checkout at \(root) is on \(branch.ok && !branch.output.isEmpty ? branch.output : "a detached HEAD"), not \(base): the build would be of that."
        }
        guard Git.run(["merge-base", "--is-ancestor", offer.newest, "HEAD"], in: root).ok else {
            return "The checkout's \(base) doesn't hold the new version any more. Check for Updates again."
        }
        return nil
    }

    // MARK: The changelog

    /// The changes grouped by the area their subject opens with ("Chat: …", "Lead: …"), in the order each area's
    /// newest change comes; subjects without one go under "Other", last.
    public static func groups(_ changes: [Change]) -> [(area: String, changes: [Change])] {
        var order: [String] = []
        var grouped: [String: [Change]] = [:]
        for change in changes {
            let area = Self.area(change.subject) ?? "Other"
            if grouped[area] == nil { order.append(area) }
            grouped[area, default: []].append(change)
        }
        order.removeAll { $0 == "Other" }
        if grouped["Other"] != nil { order.append("Other") }
        return order.map { ($0, grouped[$0]!) }
    }

    /// "Chat" for "Chat: replies stream faster", "Chat bench" for "Chat bench: …"; nil for a subject that opens with
    /// no short area before a colon.
    static func area(_ subject: String) -> String? {
        guard let colon = subject.range(of: ": ") else { return nil }
        let head = subject[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, head.count <= 24, head.split(separator: " ").count <= 3,
              head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "." }) else { return nil }
        return head.prefix(1).uppercased() + head.dropFirst()
    }

    /// The headless model's instructions for the summary.
    static let summarySystem = """
        You write the short "what's new" note of a Mac app's update for its user. You get the subjects of the commits \
        since their installed version. Answer with two or three plain sentences, at most 60 words, about what changes \
        for them: no commit ids, file names, jargon, lists, headings or markdown, and nothing the subjects don't say.
        """

    /// What the model is asked: the subjects, newest first, at most 60 of them.
    public static func summaryPrompt(_ changes: [Change]) -> String {
        let shown = changes.prefix(60).map { "- " + LeadToolset.clip($0.subject, 200) }
        return "Commits since the installed version, newest first:\n" + shown.joined(separator: "\n")
            + (changes.count > 60 ? "\n(and \(changes.count - 60) more)" : "")
    }

    /// The summary `ask` gives for the changes (a headless Claude call: `headless`), cleaned up; nil when it gave
    /// nothing, and the card shows the subjects alone.
    public static func summarize(_ changes: [Change], ask: (String) -> String?) -> String? {
        guard !changes.isEmpty, let answer = ask(summaryPrompt(changes)) else { return nil }
        let text = answer.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return LeadToolset.clip(text, 600)
    }

    /// The headless Claude call on a small model (`ClaudeHeadless`), no tools, settings or session; nil when Claude
    /// isn't there, fails or takes longer than a minute. Blocks: call it off the main thread.
    public static func headless(_ prompt: String) -> String? {
        let command = ClaudeHeadless.command(prompt: prompt, system: summarySystem)
        return ClaudeHeadless.run(executable: command.executable, args: command.args, timeout: 60)
    }
}
