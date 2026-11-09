import Foundation

/// The lead's sync with the project's remote (GitHub), in two fixed-shape tools, so the lead needn't run git fetch,
/// which its deny rules refuse (`LeadLaunch.gitAround`): `git fetch origin +main:main` or a URL would move main or
/// reach anywhere.
/// - fetch_remote fetches workflow.md's `remote` (origin unless set) and only the base branch, into its
///   remote-tracking ref, and says how far the base is ahead and behind and what a merge would be. Nothing in the
///   call's arguments names a remote, a refspec, a URL or an option.
/// - merge_remote merges that remote-tracking branch into the base in a scratch detached worktree where no agent works
///   (as merge's `Worktrees.rebaseAndTest`): a plain fast-forward when the base has nothing of its own, else a true merge
///   commit, so the remote's tip stays an ancestor of the base and a later push is a fast-forward. The lead's records
///   merge by union; a conflict anywhere else stops it, the files named, and never picks a side. The test command runs
///   on the result under the heavy slot, and the base fast-forwards to it only when it passes and the base hasn't moved
///   (`Worktrees.fastForward`, which leaves the main checkout's uncommitted files alone).
public enum LeadRemote {
    public static let defaultRemote = "origin"

    /// The transports the fetch may use: the guard's git uses none (`GitGuard`, `protocol.allow=never`), and this one
    /// call opens only these. Never `ext::` (a command), a remote helper, or plain http or git (unauthenticated).
    static let transports = ["file", "https", "ssh"]

    /// The vault's guarded-settings key (`LeadVault.setGuardedSettings`) holding the hash of `remote`'s URL as the lead
    /// took it: on its first fetch, or by setting `remote` with configure. A remote's URL is the repository's git config,
    /// which a worker's `git remote set-url` changes; a fetch from another URL is refused until the lead takes it.
    public static func urlKey(_ remote: String) -> String { "remote_url:\(remote)" }

    /// How long the fetch may run.
    public static let fetchTimeout: TimeInterval = 600

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// A remote's name as these tools take one from workflow.md: letters, digits, `.`, `_` and `-`, not starting with
    /// `-` or `.`: never a URL, a path, a refspec or an option.
    public static func isName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty, name.count <= 100 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy(allowed.contains) && first != "-" && first != "." && !name.hasSuffix(".lock")
    }

    /// The remote-tracking ref the base branch is fetched into.
    public static func trackingRef(remote: String, branch: String) -> String { "refs/remotes/\(remote)/\(branch)" }

    /// The transport git takes `url` by (as its `transport_get` does): `<helper>::…` a remote helper, `scheme://` its
    /// scheme, `host:path` (scp-like, no slash before the colon) ssh, anything else a local path.
    static func transport(of url: String) -> String {
        if let helper = url.range(of: "::"), !url[..<helper.lowerBound].contains("/") { return String(url[..<helper.lowerBound]) }
        if let scheme = url.range(of: "://") { return url[..<scheme.lowerBound].lowercased() }
        if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") { return "ssh" }
        return "file"
    }

    /// The remote's URL as git fetches it (`insteadOf` applied), refused unless it's one of `transports`.
    public static func url(root: String, remote: String) -> Result<String, Failure> {
        guard isName(remote) else {
            return .failure(Failure("workflow.md's remote, \"\(remote)\", isn't a remote's name (letters, digits, . _ -): set it with configure (remote), or leave it empty for origin."))
        }
        let names = Git.run(["remote"], in: root)
        guard names.ok else { return .failure(Failure("git remote failed: \(Worktrees.said(names))")) }
        guard names.output.split(whereSeparator: \.isNewline).map(String.init).contains(remote) else {
            let listed = names.output.split(whereSeparator: \.isNewline).joined(separator: ", ")
            return .failure(Failure("This repository has no git remote \(remote) (\(listed.isEmpty ? "it has none" : "it has \(listed)"))."
                                    + " The user adds it (git remote add); or set workflow.md's remote with configure."))
        }
        let url = Git.run(["remote", "get-url", remote], in: root)
        guard url.ok, !url.output.isEmpty else { return .failure(Failure("git remote get-url \(remote) failed: \(Worktrees.said(url))")) }
        // `::` anywhere: git takes what's before it as a remote helper's name when it's all scheme characters
        // (`file::/x` runs git-remote-file), which `transport(of:)` would read as the file transport.
        if let helper = url.output.range(of: "::") {
            return .failure(Failure("Not synced: \(remote)'s URL goes by \(url.output[..<helper.lowerBound])::, a remote helper (a program git would run), and these tools use only \(transports.joined(separator: ", ")) (the URL is the repository's git config, the user's to change)."))
        }
        let kind = transport(of: url.output)
        guard transports.contains(kind), !url.output.hasPrefix("-"), !url.output.contains(where: \.isNewline) else {
            return .failure(Failure("Not fetched: \(remote)'s URL goes by \(kind), and fetch_remote uses only \(transports.joined(separator: ", ")) (the URL is the repository's git config, the user's to change)."))
        }
        return .success(url.output)
    }

    /// The git that talks to the remote (fetch_remote's fetch, the app's push), run where the repository's own config
    /// isn't read at all: in a scratch git folder made for this one run (`scratch`, private to you, removed after),
    /// whose config VibeSwitcher writes, with the repository's objects as its object store (`GIT_OBJECT_DIRECTORY`). A
    /// URL given on the command line is still rewritten by `url.*.insteadOf` and `pushInsteadOf`, sent through
    /// `http.*` (a proxy, `curloptResolve`, CA files, extra headers) and read as the name of a `remote.<url>` section
    /// when the repository's config says so, and any session writes that config, also between a check of it and
    /// git reading it again: so the transport git doesn't read it, rather than having it checked first. The user's
    /// global and system config still apply (theirs, as their credential helpers are), and the guarded git's defaults
    /// (`GitGuard`: no hooks, no fsmonitor, no transport but the ones `args` open).
    /// `refs`: refs to write in the scratch folder first (what a fetch tells the remote it has); `read`: refs to read
    /// back after it ran (what a fetch fetched), by name, nil for one it doesn't hold.
    static func transportGit(_ args: [String], root: String, scratch: URL, refs: [String: String] = [:], read: [String] = [],
                             timeout: TimeInterval) -> (run: Git.Result, read: [String: String]) {
        let refused = { (text: String) in (Git.Result(status: 128, output: "", error: text), [String: String]()) }
        guard let common = GitGuard.gitDirs(of: root)?.common else { return refused("\(root) isn't a checkout VibeSwitcher's git can vouch for.") }
        let format = Git.run(["rev-parse", "--show-object-format"], in: root).output
        let dir = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            for folder in ["objects", "refs/heads", "refs/tags", "refs/remotes"] { try VibePaths.ensurePrivate(dir.appendingPathComponent(folder), within: scratch) }
            try VibePaths.writePrivate(Data("ref: refs/heads/scratch\n".utf8), to: dir.appendingPathComponent("HEAD"))
            let config = format == "sha256" ? "[core]\n\trepositoryformatversion = 1\n\tbare = true\n[extensions]\n\tobjectformat = sha256\n"
                                            : "[core]\n\trepositoryformatversion = 0\n\tbare = true\n"
            try VibePaths.writePrivate(Data(config.utf8), to: dir.appendingPathComponent("config"))
            for (ref, commit) in refs where ref.hasPrefix("refs/") && !ref.contains("..") {
                try VibePaths.ensurePrivate(dir.appendingPathComponent(ref).deletingLastPathComponent(), within: scratch)
                try VibePaths.writePrivate(Data((commit + "\n").utf8), to: dir.appendingPathComponent(ref))
            }
        } catch {
            return refused("Couldn't make a scratch git folder at \(dir.path): \(error)")
        }
        let env = Git.environment.merging(["GIT_DIR": dir.path, "GIT_OBJECT_DIRECTORY": (common as NSString).appendingPathComponent("objects")]) { $1 }
        let front = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never", "-c", "submodule.recurse=false"]
        var run = Shell.run(executable: "/usr/bin/git", args: front + args, in: scratch.path, env: env, timeout: timeout, grace: 5)
        if run.timedOut || run.cancelled {
            run.output = ""
            let stopped = run.cancelled ? "git was stopped: cancelled." : "git was stopped: it ran past \(Worktrees.duration(timeout))."
            run.error = run.error.isEmpty ? stopped : stopped + "\n" + run.error
        }
        var found: [String: String] = [:]
        for ref in read {
            let value = Shell.run(executable: "/usr/bin/git", args: front + ["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: scratch.path,
                                  env: env, timeout: 30, grace: 1)
            if value.status == 0, !value.output.isEmpty { found[ref] = value.output }
        }
        return (run, found)
    }

    /// The user's own credential helpers (global and system config, in git's order), as `-c` pairs: after an empty
    /// `credential.helper`, which drops every helper read before (the repository's own config could name any program
    /// there), these come back. A key `-c` can't spell (an `=` in its URL) is left out.
    static func credentialHelpers(root: String) -> [String] {
        let listed = Shell.run(executable: "/usr/bin/git", args: ["config", "--show-scope", "-z", "--get-regexp", #"^credential\..*helper$"#],
                               in: root, env: Git.environment, timeout: 30, grace: 1)
        guard listed.status == 0 else { return [] }
        let fields = listed.output.components(separatedBy: "\0")
        var pairs: [String] = []
        var index = 0
        while index + 1 < fields.count {
            let scope = fields[index], entry = fields[index + 1]
            index += 2
            guard ["system", "global"].contains(scope) else { continue }
            let key = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? entry
            let value = entry.count > key.count ? String(entry.dropFirst(key.count + 1)) : ""
            guard !key.contains("="), !value.isEmpty else { continue }
            pairs += ["-c", "\(key)=\(value)"]
        }
        return pairs
    }

    /// The one fetch these tools run: `remote`'s `branch` into its remote-tracking ref, nothing else. The repository's
    /// executable config stays out as for every guarded git (`GitGuard`); on top, only `transports` are opened, the
    /// credential helpers are the user's own (`credentialHelpers`), upload-pack is git's own (`remote.<name>.uploadpack`
    /// could name any program for a local remote), and no tags, submodules, pruning or maintenance come along. `--refmap=`
    /// leaves out the repository's own `remote.<name>.fetch` refspecs, which git would otherwise apply to the fetched
    /// ref too: a mirror's `+refs/*:refs/*` would write the base branch itself.
    /// The URL is given, not the remote's name: the one the vault pinned (`urlKey`), checked by the caller, so git
    /// doesn't read `remote.<name>.url` again after the check (a worker's `git remote set-url` in between).
    static func fetchArguments(url: String, remote: String, branch: String, helpers: [String]) -> [String] {
        let open = transports.flatMap { ["-c", "protocol.\($0).allow=always"] }
        return open + ["-c", "credential.helper="] + helpers
            + ["fetch", "--no-tags", "--no-recurse-submodules", "--no-prune", "--no-auto-maintenance", "--no-write-fetch-head",
               "--upload-pack=git-upload-pack", "--refmap=", "--quiet", "--", url, "+refs/heads/\(branch):\(trackingRef(remote: remote, branch: branch))"]
    }

    /// Fetches `branch` from `url` (`remote`'s, as the caller checked it against the vault's pin: `fetchArguments`)
    /// and returns the remote-tracking ref's commit.
    /// `scratch`: where its scratch git folder goes (`transportGit`).
    public static func fetch(root: String, remote: String, url: String, branch: String, scratch: URL,
                             timeout: TimeInterval = fetchTimeout) -> Result<String, Failure> {
        guard Git.run(["check-ref-format", "--branch", branch], in: root).ok, !branch.hasPrefix("-") else {
            return .failure(Failure("The base branch \"\(branch)\" isn't a branch's name."))
        }
        guard isName(remote), !url.contains("::"), transports.contains(transport(of: url)), !url.hasPrefix("-") else {
            return .failure(Failure("Not fetched: \(url) isn't a URL fetch_remote uses."))
        }
        // A remote helper named by the repository's config (`remote.<name>.vcs`) is a program of its choosing.
        let vcs = Git.run(["config", "--get", "remote.\(remote).vcs"], in: root).output
        guard vcs.isEmpty else { return .failure(Failure("Not fetched: \(remote) is set to go through a remote helper (remote.\(remote).vcs = \(vcs)), which fetch_remote doesn't run.")) }
        // What this repository has, for the remote to send only what's new: the remote-tracking ref and the branch.
        let ref = trackingRef(remote: remote, branch: branch)
        var known: [String: String] = [:]
        for (name, local) in [(ref, ref), ("refs/heads/\(branch)", "refs/heads/\(branch)")] {
            let commit = Git.run(["rev-parse", "--verify", "--quiet", local + "^{commit}"], in: root).output
            if !commit.isEmpty { known[name] = commit }
        }
        let (fetched, read) = transportGit(fetchArguments(url: url, remote: remote, branch: branch, helpers: credentialHelpers(root: root)),
                                           root: root, scratch: scratch, refs: known, read: [ref], timeout: timeout)
        guard fetched.ok else { return .failure(Failure("git fetch \(remote) \(branch) failed: \(Worktrees.said(fetched))")) }
        guard let tip = read[ref], Git.run(["cat-file", "-e", tip + "^{commit}"], in: root).ok else {
            return .failure(Failure("Fetched, but \(remote)/\(branch) can't be read."))
        }
        // The fetch wrote the remote's objects into this repository's object store, its ref in the scratch folder:
        // the remote-tracking ref is set here, to that commit.
        let set = Git.run(["update-ref", "-m", "fetch_remote: \(url)", ref, tip], in: root)
        guard set.ok else { return .failure(Failure("Fetched \(tip.prefix(8)), but \(ref) couldn't be set: \(Worktrees.said(set))")) }
        return .success(tip)
    }

    /// What a merge of the remote's tip into the base would be.
    public enum Outlook: Equatable, Sendable {
        /// The base has it all already.
        case upToDate
        /// The base has nothing of its own: it moves to the remote's tip.
        case fastForward
        /// A merge commit, clean.
        case merge
        /// A merge commit whose only conflicts are in these lead records, which merge by union.
        case recordsByUnion([String])
        /// A merge that conflicts in these files (outside the lead's records): merge_remote stops on it.
        case conflict([String])
    }

    /// How the base and the remote's tip stand: the commits each has that the other hasn't, the remote's (newest
    /// first, `subjects` at most `limit` of them), and what a merge would be.
    public struct Incoming: Equatable, Sendable {
        public var head: String
        public var tip: String
        public var ahead: Int
        public var behind: Int
        public var subjects: [String]
        public var outlook: Outlook
    }

    public static func incoming(root: String, head: String, tip: String, records: String?, limit: Int = 30) -> Result<Incoming, Failure> {
        let counts = Git.run(["rev-list", "--left-right", "--count", "\(head)...\(tip)"], in: root)
        let numbers = counts.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.ok, numbers.count == 2 else { return .failure(Failure("git rev-list \(head.prefix(8))...\(tip.prefix(8)) failed: \(Worktrees.said(counts))")) }
        let (ahead, behind) = (numbers[0], numbers[1])
        let log = Git.run(["log", "--format=%h %s", "--max-count=\(limit)", "\(head)..\(tip)"], in: root)
        guard log.ok else { return .failure(Failure("git log \(head.prefix(8))..\(tip.prefix(8)) failed: \(Worktrees.said(log))")) }
        let subjects = log.output.split(whereSeparator: \.isNewline).map(String.init)
        let outlook: Outlook
        if behind == 0 {
            outlook = .upToDate
        } else if ahead == 0 {
            outlook = .fastForward
        } else {
            switch Worktrees.trialMerge(root: root, base: head, commit: tip) {
            case .failure(let error): return .failure(Failure(error.description))
            case .success(let conflicts) where conflicts.isEmpty: outlook = .merge
            case .success(let conflicts):
                let outside = conflicts.filter { !isRecord($0, records: records) }
                outlook = outside.isEmpty ? .recordsByUnion(conflicts) : .conflict(outside)
            }
        }
        return .success(Incoming(head: head, tip: tip, ahead: ahead, behind: behind, subjects: subjects, outlook: outlook))
    }

    /// One of the lead's records (`LeadRecords.paths`), which merge by union; or the product inventory, which both
    /// Macs' records commits make (`ProductInventory`): taken by union too, and made again from the merged code by the
    /// records commit after merge_remote, so a conflict in it never stops one.
    static func isRecord(_ file: String, records: String?) -> Bool {
        records.map { LeadRecords.paths($0).contains(file) || file == ProductInventory.output } ?? false
    }

    /// How merge_remote's run went.
    public enum Landing: Equatable, Sendable {
        /// The base has the remote's tip already: nothing to do.
        case upToDate
        /// The tests passed on `commit`: the remote's tip itself (`merged` false, a fast-forward) or a merge commit of it
        /// on the base. Nothing has moved yet: the caller fast-forwards the base to it.
        case passed(commit: String, merged: Bool)
        /// The merge conflicts in these files outside the lead's records; nothing was made.
        case conflict([String])
        case failed(String)
        case hung(command: String, after: TimeInterval, output: String, stall: StallWatch.Stall?)
        case cancelled
        case error(String)
    }

    /// Merges `tip` (`label`, e.g. origin/main) into `head` (the base's commit) where no agent works, in a detached
    /// worktree at `scratch` removed afterwards, and runs `setup` and `test` there in a scratch home (`home`, by default
    /// beside it), holding `lock`, as merge does. The base itself, and the main checkout, aren't touched.
    public static func mergeAndTest(root: String, head: String, tip: String, label: String, records: String?,
                                    setup: String?, test: String?, scratch: URL, home: URL? = nil,
                                    timeout: TimeInterval = Worktrees.testTimeout, lock: TestLock?) -> Landing {
        if Git.run(["merge-base", "--is-ancestor", tip, head], in: root).ok { return .upToDate }
        let path = scratch.path
        let home = (home ?? scratch.deletingLastPathComponent().appendingPathComponent(scratch.lastPathComponent + "-home")).path
        let cancel = ShellCancel.current
        let remove = {
            ShellCancel.with(nil) {
                SessionStrays.endInside(folder: path)
                Git.run(["worktree", "remove", "--force", path], in: root)
                try? FileManager.default.removeItem(atPath: path)
                Git.run(["worktree", "prune"], in: root)
                try? FileManager.default.removeItem(atPath: home)
            }
        }
        if FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: home) { remove() }
        guard cancel?.isCancelled != true else { return .cancelled }
        try? FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { remove() }
        // The base has nothing of its own: the remote's tip is the result, as `git merge` would fast-forward to it.
        let forward = Git.run(["merge-base", "--is-ancestor", head, tip], in: root).ok
        let added = Git.run(["worktree", "add", "--detach", "-q", path, forward ? tip : head], in: root)
        guard added.ok else {
            if cancel?.isCancelled == true { return .cancelled }
            return .error(added.error.isEmpty ? "Couldn't set up a worktree to merge \(label) in." : added.error)
        }
        if !forward {
            let message = "Merge remote-tracking branch '\(label)'"
            let merged = Worktrees.noEditor(["merge", "--no-ff", "--no-edit", "-q", "-m", message, tip], in: path)
            if !merged.ok {
                let unmerged = Git.run(["diff", "--name-only", "-z", "--diff-filter=U"], in: path).output
                    .split(separator: "\0").map(String.init).sorted()
                let outside = unmerged.filter { !isRecord($0, records: records) }
                guard !unmerged.isEmpty, outside.isEmpty else {
                    Git.run(["merge", "--abort"], in: path)
                    if cancel?.isCancelled == true { return .cancelled }
                    return unmerged.isEmpty ? .error("Merging \(label) into \(head.prefix(8)) failed, and not on a conflict: \(Worktrees.said(merged))") : .conflict(outside)
                }
                if let failure = union(unmerged, in: path) {
                    Git.run(["merge", "--abort"], in: path)
                    return .error(failure)
                }
                let committed = Worktrees.noEditor(["commit", "-q", "--no-edit"], in: path)
                guard committed.ok else {
                    Git.run(["merge", "--abort"], in: path)
                    return .error("Committing the merge of \(label) failed: \(Worktrees.said(committed))")
                }
            }
        }
        guard cancel?.isCancelled != true else { return .cancelled }
        let made = Git.run(["rev-parse", "HEAD"], in: path).output
        guard Git.run(["merge-base", "--is-ancestor", tip, made], in: path).ok, Git.run(["merge-base", "--is-ancestor", head, made], in: path).ok else {
            return .error("The merge of \(label) didn't end on top of both \(head.prefix(8)) and \(tip.prefix(8)).")
        }
        let (stopped, _) = Worktrees.runChecks(setup: setup, test: test, in: path, home: home, timeout: timeout, lock: lock,
                                               as: "VibeSwitcher's test of \(label) merged into \(head.prefix(8))", place: root)
        switch stopped {
        case nil: return .passed(commit: made, merged: !forward)
        case .failed(let output)?: return .failed(output)
        case .hung(let command, let after, let output, let stall)?: return .hung(command: command, after: after, output: output, stall: stall)
        case .cancelled?: return .cancelled
        case .error(let text)?: return .error(text)
        case .passed?, .passedOnRerun?, .conflict?: return .error("unexpected")
        }
    }

    /// Resolves each of `files` (the lead's records, conflicted at `path`) by union, as `merge=union` in .gitattributes
    /// does: both sides' lines kept, ours first where they overlap. A file one side deleted keeps the other's. Nil
    /// when every one is resolved and staged, else what failed. Each side is written by git itself
    /// (`checkout-index --temp`), byte for byte, into the scratch worktree, and merged there (`merge-file --union`).
    static func union(_ files: [String], in path: String) -> String? {
        let fileManager = FileManager.default
        for file in files {
            // "base ours theirs\tfile", "." for a side that has none.
            let staged = Git.run(["checkout-index", "--stage=all", "--temp", "--", file], in: path)
            let line = staged.output.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
            let sides = line.split(separator: " ").map { $0 == "." ? nil : (path as NSString).appendingPathComponent(String($0)) }
            guard staged.ok, sides.count == 3 else { return "Couldn't read the sides of \(file) to merge them: \(Worktrees.said(staged))" }
            defer { for side in sides { if let side { try? fileManager.removeItem(atPath: side) } } }
            let (base, ours, theirs) = (sides[0], sides[1], sides[2])
            let target = (path as NSString).appendingPathComponent(file)
            let result: String
            switch (ours, theirs) {
            case (nil, nil):
                guard Git.run(["rm", "-q", "--cached", "--ignore-unmatch", "--", file], in: path).ok else { return "Couldn't take \(file) out of the merge." }
                continue
            case (let one?, nil), (nil, let one?):
                result = one
            case (let ours?, let theirs?):
                // In place, into ours; it exits with the number of conflicts (none with --union), a negative status on error.
                let run = Shell.run(executable: "/usr/bin/git", args: ["merge-file", "--union", ours, base ?? "/dev/null", theirs],
                                    in: path, env: Git.environment, timeout: 30, grace: 1)
                guard run.status == 0, !run.timedOut, !run.cancelled else { return "git merge-file --union on \(file) failed: \(Worktrees.said(run))" }
                result = ours
            }
            do {
                try fileManager.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                guard let data = fileManager.contents(atPath: result) else { return "Couldn't read the union of \(file)." }
                try data.write(to: URL(fileURLWithPath: target))
            } catch { return "Couldn't write the union of \(file): \(error)" }
            guard Git.run(["add", "--", file], in: path).ok else { return "Couldn't stage the union of \(file)." }
        }
        return nil
    }
}

// MARK: The lead's tools

extension LeadToolset {
    /// fetch_remote: workflow.md's remote, the base branch only, into its remote-tracking ref (`LeadRemote.fetch`),
    /// and how the base stands against it. Takes no arguments: nothing the caller says reaches git.
    func fetchRemote() throws -> MCPToolResult {
        let workflow = self.workflow
        try checkSettings(workflow, not: "Not fetched", keys: ["remote"])
        let (remote, base) = (workflow.remoteName, workflow.base)
        let label = "\(remote)/\(base)"
        // The URL as the lead took it: the first fetch takes it, configure (remote) takes it again.
        let (url, first) = try pinnedURL(remote, not: "Not fetched", first: true)
        let tip: String
        let scratch = vault.scratch(root: root, "remote-git")
        try vault.ensurePrivate(scratch)
        switch LeadRemote.fetch(root: root, remote: remote, url: url, branch: base, scratch: scratch) {
        case .success(let fetched): tip = fetched
        case .failure(let error): throw Problem(text: error.description)
        }
        // What merge_remote merges: this tip, as the vault keeps it, never whatever the ref holds by then (any
        // worktree, or a task's test code, can move a remote-tracking ref).
        try vault.setHead(tip, root: root, branch: LeadRemote.trackingRef(remote: remote, branch: base))
        guard let head = branchHead(base) else { throw Problem(text: "Fetched \(label), but there's no local branch \(base) to compare it with.") }
        let incoming: LeadRemote.Incoming
        switch LeadRemote.incoming(root: root, head: head, tip: tip, records: workflow.recordsDir) {
        case .success(let found): incoming = found
        case .failure(let error): throw Problem(text: "Fetched \(label) (\(tip.prefix(8))), but comparing it with \(base) failed: \(error)")
        }
        let standing = "\(base) is \(Self.commits(incoming.ahead)) ahead of \(label) and \(Self.commits(incoming.behind)) behind it"
        try? store.appendProgress("Fetched \(label) at \(tip.prefix(8)): \(standing)")
        var lines = ["Fetched \(label) (\(tip.prefix(8))) from \(url)\(first ? " (its first fetch: this URL is now the one fetch_remote takes; configure(remote) takes another)" : ""): \(standing)."]
        if !incoming.subjects.isEmpty {
            lines.append("Incoming, newest first\(incoming.behind > incoming.subjects.count ? " (the first \(incoming.subjects.count))" : ""):")
            lines += incoming.subjects.map { "- \($0)" }
        }
        lines.append("merge_remote would " + Self.outlook(incoming.outlook, base: base, label: label))
        return MCPToolResult(text: lines.joined(separator: "\n"))
    }

    /// The remote's tip as fetch_remote last fetched it (the vault's, never the ref's: any session can move that); nil
    /// before a fetch. merge lands a task that carries commits of it as a true merge (`Worktrees.put`). Throws, opening
    /// with `not`, when the host didn't answer: taken for "never fetched", the task's merge of the remote lands squashed
    /// and the remote's records are skipped (2026-11-07 19:46). A merge reads it once and uses that for all it does.
    func fetchedTip(_ workflow: LeadWorkflow, not: String) throws -> String? {
        let remote = workflow.remoteName
        guard LeadRemote.isName(remote) else { return nil }
        return try recordedHead(LeadRemote.trackingRef(remote: remote, branch: workflow.base), "fetch_remote left \(remote)/\(workflow.base)", not: not)
    }

    /// The head the vault has for `branch`; nil when none is recorded. Throws a refusal opening with `not`, naming
    /// `what` couldn't be read, when the host didn't answer, which isn't "none recorded".
    func recordedHead(_ branch: String, _ what: String, not: String) throws -> String? {
        do { return try vault.head(root: root, branch: branch) } catch {
            throw Problem(text: "\(not): couldn't read where \(what). \(error) Try again once the session host answers.")
        }
    }

    /// Refuses a task whose branch holds commits of the remote's branch that fetch_remote didn't fetch (nothing fetched
    /// yet, or the remote-tracking ref moved past what it fetched): merge lands a branch that carries the remote's
    /// commits as a true merge, with the remote's records as fetch_remote fetched them in the commit itself, so
    /// records past that would be dropped for good (merge_remote then has nothing to merge).
    func checkRemoteCarried(_ slug: String, commit: String, fetched: String?) throws {
        let workflow = self.workflow
        let remote = workflow.remoteName
        guard LeadRemote.isName(remote), let base = branchHead(workflow.base) else { return }
        let ref = Git.run(["rev-parse", "--verify", "--quiet", LeadRemote.trackingRef(remote: remote, branch: workflow.base) + "^{commit}"], in: root)
        guard ref.ok, !ref.output.isEmpty else { return }
        let found = Git.run(["merge-base", commit, ref.output], in: root)
        guard found.ok, !found.output.isEmpty, !Git.run(["merge-base", "--is-ancestor", found.output, base], in: root).ok else { return }
        let label = "\(remote)/\(workflow.base)"
        guard let fetched else {
            throw Problem(text: "Not merged (nothing was tested): agent/\(slug) holds commits of \(label) (up to \(found.output.prefix(8))) that \(workflow.base) lacks, and fetch_remote hasn't fetched \(label). Run fetch_remote, then merge again: a branch that carries the remote's commits lands as a true merge, with the remote's records as fetch_remote fetched them.")
        }
        guard Git.run(["merge-base", "--is-ancestor", found.output, fetched], in: root).ok else {
            throw Problem(text: "Not merged (nothing was tested): agent/\(slug) holds commits of \(label) (up to \(found.output.prefix(8))) past what fetch_remote fetched (\(fetched.prefix(8))). Run fetch_remote, then merge again: the remote's records are taken as fetch_remote fetched them.")
        }
        // turn-this-incident-into-12: a branch carrying the remote lands as a true merge only through a gate that does
        // that; the installed one may predate it.
        if let lag = gateLag(workflow) {
            throw Problem(text: lag.refusal(base: workflow.base, what: "agent/\(slug) holds commits of \(label) (up to \(found.output.prefix(8))), and its merge"))
        }
    }

    /// What every route gives `Worktrees.fastForward`: who's landing, `carried` (the remote's commits the commit is
    /// meant to hold), and the workflow's records with their lock.
    func landingCheck(_ route: String, carried: [String] = [], workflow: LeadWorkflow) -> Worktrees.Landing {
        Worktrees.Landing(route: route, records: workflow.recordsDir, carried: carried,
                          lockRecords: { [store] body in try store.withRecordsLock(body) }, probe: records.landingProbe)
    }

    /// The commit of what fetch_remote fetched that `branch` (a task's audited head, read before it's made into anything
    /// else) holds and `base` lacks, as a list for its landing's check; empty when it carries none. Throws when git can't
    /// say: "no answer" isn't "carries none" (2026-11-07 19:46), and the check would then have nothing to ask of a
    /// flattened commit.
    func carriedRemote(_ fetched: String?, branch: String, onto base: String) throws -> [String] {
        guard let fetched, !fetched.isEmpty else { return [] }
        let git = { [root, probe = records.landingProbe] (args: [String]) in probe?.git?(args) ?? Git.run(args, in: root, timeout: Worktrees.landingCheckTimeout) }
        let unsure = { (result: Git.Result) in Problem(text: "Not merged: couldn't tell whether \(branch.prefix(8)) carries the remote's commits (\(Worktrees.said(result))), so it doesn't land. \(base.prefix(8)) wasn't moved.") }
        let found = git(["merge-base", branch, fetched])
        if found.status == 1, !found.timedOut, !found.cancelled, !found.signaled { return [] }
        guard found.ok, !found.output.isEmpty else { throw unsure(found) }
        let held = git(["merge-base", "--is-ancestor", found.output, base])
        if held.ok { return [] }
        guard held.status == 1, !held.timedOut, !held.cancelled, !held.signaled else { throw unsure(held) }
        return [found.output]
    }

    public static func commits(_ count: Int) -> String { "\(count) commit\(count == 1 ? "" : "s")" }

    static func outlook(_ outlook: LeadRemote.Outlook, base: String, label: String) -> String {
        switch outlook {
        case .upToDate: return "do nothing: \(base) has everything \(label) has."
        case .fastForward: return "fast-forward \(base) to \(label) (\(base) has nothing of its own), once the test command passes on it."
        case .merge: return "make a merge commit of \(label) into \(base) (it merges cleanly), once the test command passes on it."
        case .recordsByUnion(let files):
            return "make a merge commit of \(label) into \(base), once the test command passes on it; its only conflicts are in the lead's records (\(files.joined(separator: ", "))), which merge by union, both sides' lines kept."
        case .conflict(let files):
            return "stop: merging \(label) into \(base) conflicts in \(files.prefix(12).joined(separator: ", "))\(files.count > 12 ? ", …" : ""). It never picks a side for code: ask the user to resolve it (or plan a task that does)."
        }
    }

    /// merge_remote: the remote-tracking branch fetch_remote fetched, merged into the base where no agent works and
    /// tested (`LeadRemote.mergeAndTest`), then the base fast-forwarded to the result, as merge lands a task. Its
    /// commits are taken as the user's: the vault's head of the base moves with it.
    func mergeRemote() throws -> MCPToolResult {
        let workflow = self.workflow
        try checkSettings(workflow, not: "Not merged (nothing was tested)")
        try checkBattery(not: "Not merged")
        let (remote, base) = (workflow.remoteName, workflow.base)
        let label = "\(remote)/\(base)"
        guard LeadRemote.isName(remote) else { throw Problem(text: "workflow.md's remote, \"\(remote)\", isn't a remote's name: set it with configure (remote).") }
        let tracked = Git.run(["rev-parse", "--verify", "--quiet", LeadRemote.trackingRef(remote: remote, branch: base) + "^{commit}"], in: root)
        guard tracked.ok, !tracked.output.isEmpty else { throw Problem(text: "There's no \(label) to merge: run fetch_remote first.") }
        // turn-this-incident-into-12: the other Mac's commits land through the installed build's gate.
        if let lag = gateLag(workflow) { throw Problem(text: lag.refusal(base: base, what: "merge_remote")) }
        let tip = tracked.output
        let fetched = try fetchedTip(workflow, not: "Not merged (nothing was tested)")
        guard fetched == tip else {
            throw Problem(text: "Not merged: \(label) is at \(tip.prefix(8)), " + (fetched.map { "not at \($0.prefix(8)) where fetch_remote left it" } ?? "and fetch_remote hasn't fetched it")
                          + ": something else moved it (any session can). Run fetch_remote again; merge_remote merges only what it fetched.")
        }
        // When the remote changed the lead's records, those written since the last commit go in first: the merge is
        // made on top of them, and the main checkout holds none the fast-forward could meet. Otherwise they stay
        // uncommitted, as they are, and the fast-forward doesn't touch them.
        if let dir = workflow.recordsDir, let head = branchHead(base),
           !Git.run(["diff", "--name-only", "\(head)...\(tip)", "--"] + LeadRecords.paths(dir), in: root).output.isEmpty {
            records.flush(base: base)
        }
        let baseLock = vault.scratch(root: root, "merge-into-\(LeadVault.hash(base).prefix(16)).lock")
        try vault.ensurePrivate(baseLock.deletingLastPathComponent())
        guard let held = FileLock.attempt(baseLock.path) else {
            throw Problem(text: "Another merge into \(base) is running; merge_remote when it's done.")
        }
        defer { held.release() }
        guard let current = branchHead(base) else { throw Problem(text: "There's no branch \(base) to merge into.") }
        try checkBaseMoves(base: base, current: current)
        if Git.run(["merge-base", "--is-ancestor", tip, current], in: root).ok {
            return MCPToolResult(text: "Nothing to merge: \(base) has everything \(label) has (\(tip.prefix(8))). fetch_remote fetches what's new.")
        }
        if let lock = Worktrees.indexLock(blocking: base, root: root) {
            throw Problem(text: "Not merged (nothing was tested): \(Worktrees.refusal(lock))")
        }
        let waited = try waitForLoad(workflow, slug: label, doing: "merge_remote", done: "merged")
        // The remote's code runs from here, outside any session: the team isn't quiet (`ConfigSeal`). Unmarked, it
        // doesn't run.
        let mark = try markBranchRun(not: "Not merged (nothing was tested)")
        defer { endBranchRun(mark) }
        let landing = LeadRemote.mergeAndTest(root: root, head: current, tip: tip, label: label, records: workflow.recordsDir,
                                              setup: workflow.initCommand, test: workflow.mergeChecks,
                                              scratch: vault.scratch(root: root, "merge-remote"), home: vault.scratch(root: root, "merge-remote-home"),
                                              timeout: workflow.testTimeout, lock: heavyLock(workflow))
        let unmoved = "\(base) is unmoved at \(current.prefix(8))."
        let made: String, merged: Bool
        switch landing {
        case .upToDate:
            return MCPToolResult(text: "Nothing to merge: \(base) has everything \(label) has (\(tip.prefix(8))).")
        case .passed(let commit, let isMerge):
            // What its tests wrote outside the checkout (the agents' config) holds the merge, whatever they said.
            try checkConfig(not: "Not merged: the tests of \(label) passed, and after them")
            (made, merged) = (commit, isMerge)
        case .conflict(let files):
            try? store.appendProgress("merge_remote stopped: \(label) conflicts with \(base) in \(Self.clip(files.joined(separator: ", "), 300))")
            throw Problem(text: "Not merged: \(label) (\(tip.prefix(8))) conflicts with \(base) in \(files.prefix(12).joined(separator: ", "))\(files.count > 12 ? ", …" : ""). "
                          + "Nothing was picked for either side, and \(unmoved) Ask the user to resolve it, or plan a task whose worker merges \(label) and resolves those files.")
        case .failed(let output):
            _ = saveMergeLog(output, slug: "merge-remote")
            let copy = copyMergeLog(output, slug: "merge-remote", commit: tip, inWorktree: false)
            try? store.appendProgress("merge_remote stopped: the tests fail on \(label) merged into \(base): \(Self.clip(MergeFailure.reason(in: scrubbed(output)), 300))")
            throw Problem(text: "Not merged: the tests fail on \(label) merged into \(base); \(unmoved)\n\(MergeFailure.detail(scrubbed(output)))\n"
                          + copy.said("Their output"))
        case .hung(let command, let after, let output, let stall):
            _ = saveMergeLog(output, slug: "merge-remote")
            let copy = copyMergeLog(output, slug: "merge-remote", commit: tip, name: "merge-hung.log", inWorktree: false)
            throw Problem(text: "Not merged: \(command == "init_command" ? "init_command" : "the tests") \(Worktrees.hung(after: after, stall: stall)) on \(label) merged into \(base), and \(command == "init_command" ? "it was" : "they were") stopped; \(unmoved) "
                          + MergeRerun.causeText(output) + copy.said("The output so far", stop: ".") + "\n" + MergeFailure.end(of: scrubbed(output)))
        case .cancelled:
            throw Problem(text: "merge_remote was cancelled; nothing was merged, and \(unmoved)")
        case .error(let text):
            throw Problem(text: "Not merged: \(text) \(unmoved)")
        }
        if ShellCancel.current?.isCancelled == true {
            throw Problem(text: "merge_remote was cancelled after its tests passed; nothing was merged, and \(unmoved)")
        }
        switch ShellCancel.with(nil, { Worktrees.fastForward(root: root, base: base, to: made, from: current,
                                                            landing: landingCheck("merge_remote", carried: [tip], workflow: workflow)) }) {
        case .merged:
            // The remote's commits are the user's work, as the commits the user merges by hand: the base's head as the
            // vault knows it moves with them, so the next merge doesn't take them for a move nobody made.
            if let unrecorded = recordLanding(base: base, from: current, to: made, with: label) { throw Problem(text: unrecorded) }
            let brought = Int(Git.run(["rev-list", "--count", "\(current)..\(tip)"], in: root).output) ?? 0
            let how = merged ? "a merge commit, \(made.prefix(8))" : "a fast-forward"
            try? store.appendProgress("Merged \(label) into \(base): \(Self.commits(brought)) from the remote, as \(how); the tests passed on it" + buildNote)
            let patience = waited.map { " (The tests waited \(Worktrees.duration($0.after)) for the Mac's load to drop.)" } ?? ""
            return MCPToolResult(text: "Merged \(label) into \(base) as \(how): \(Self.commits(brought)) from the remote, the test command passing on the result. "
                                 + "\(label) (\(tip.prefix(8))) is an ancestor of \(base) now, so pushing \(base) is a fast-forward.\(patience)")
        case .refused(let reason):
            throw Problem(text: "Not merged: \(reason) The tests passed on \(made.prefix(8)), but \(base) wasn't moved; run merge_remote again.")
        }
    }
}
