import Foundation
import VibeCore

/// `vibeswitcher lead FOLDER --init` (the app's first-commit offer, `LeadController` and `ProjectFolderStart`; the
/// parity table's first row): a folder in no repository gets `git init` and a first commit of its files, a repository's
/// own folder with no commits at all a first commit. Planned before the typed code (`plan`, touching nothing), made after
/// it (`make`), by the command line's own process.
///
/// Built for a folder a worker may have written (the independent review of 2026-11-22), so its git runs nothing of the
/// folder's and commits exactly what the code was typed for:
/// - git here is never `Git.run`: that one takes a first-seen repository's hooks as its accepted baseline and runs
///   them. Every call here has hooks off (`core.hooksPath=/dev/null`, and the commit `--no-verify`), no fsmonitor, no
///   transport, no submodule recursion, literal pathspecs, and, once the repository is there, its git folder and work
///   tree given (`GIT_DIR`, `GIT_WORK_TREE`): no `core.worktree`, no `.git` file naming another place. No baseline is
///   recorded anywhere.
/// - An existing repository is taken only when its `.git` is a folder of its own (not a link, not a file, no
///   `commondir`) whose config holds only plain keys (`allowedKeys`): no filter, hook path, include or `core.worktree`.
/// - The files are added by path, the ones planned; the index is compared with the plan before the commit, and any
///   difference (a file come or gone during the prompt) refuses, leaving the folder as it was. What is printed after is
///   what the commit holds.
/// - The author is the user's, from their global git config (`git config --global`), never the folder's.
/// - What looks like a secret (`secretNames`, the app's list and more, matched without case) is left out, named in the
///   prompt, and kept out of later commits (`.git/info/exclude`).
/// - The folder is checked again after the code: the same folder by its resolved path, not a link, not the home folder
///   or `/`.
public enum LeadInit {
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    public struct Identity: Equatable, Sendable {
        public var name: String
        public var email: String
    }

    public struct Plan: Equatable, Sendable {
        /// The folder, by its resolved path.
        public var folder: String
        /// A repository with no commits already: no git init.
        public var inRepository: Bool
        /// The branch `git init` makes (the user's `init.defaultBranch`, else main); nil in a repository.
        public var branch: String?
        /// What the commit holds, relative to `folder`, sorted (a nested repository as its folder's name).
        public var files: [String]
        /// What looks like a secret: not committed, and kept out of later commits.
        public var leftOut: [String]
        /// Folders holding a repository of their own: committed as a reference to it.
        public var nested: [String]
        /// The folder has no .gitignore: `gitignore` is written and committed.
        public var addsGitignore: Bool
        public var identity: Identity
    }

    /// File names that look like secrets: the app's (`FolderRepository.secretNames`) and more, matched without case.
    public static let secretNames = FolderRepository.secretNames + [
        ".npmrc", ".netrc", ".git-credentials", ".pypirc", ".envrc", "*.env", "credentials.json", "*.pfx", "*.jks", "*.tfvars",
        "terraform.tfstate*", "id_dsa*", "*.keystore",
    ]

    /// The .gitignore written when the folder has none.
    public static var gitignore: String { (secretNames + FolderRepository.buildNames).joined(separator: "\n") + "\n" }

    /// Whether a file's name (the last part of `path`) looks like a secret, whatever its case.
    public static func looksSecret(_ path: String) -> Bool {
        let name = ((path.hasSuffix("/") ? String(path.dropLast()) : path) as NSString).lastPathComponent.lowercased()
        return secretNames.contains { fnmatch($0.lowercased(), name, 0) == 0 }
    }

    /// The keys an existing repository's own config may hold for `--init` to run git in it: what `git init` and a
    /// clone write. Anything else (a filter or merge driver, `core.hooksPath`, `core.worktree`, an include, a pager) is
    /// refused, naming it.
    static func allowed(_ key: String) -> Bool {
        let key = key.lowercased()
        let exact: Set<String> = ["core.repositoryformatversion", "core.filemode", "core.bare", "core.logallrefupdates", "core.ignorecase",
                                  "core.precomposeunicode", "core.symlinks", "extensions.objectformat", "init.defaultbranch", "user.name", "user.email"]
        if exact.contains(key) { return true }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let last = parts.last else { return false }
        switch parts[0] {
        case "remote": return ["url", "fetch"].contains(last)
        case "branch": return ["remote", "merge"].contains(last)
        default: return false
        }
    }

    // MARK: git, running nothing of the folder's

    /// git with nothing of the repository's run: hooks off, no fsmonitor, no transport, no submodule recursion, literal
    /// pathspecs; `gitDir` and `workTree` given when the repository is there. Never `Git.run` (no baseline).
    static func git(_ args: [String], in directory: String, gitDir: String? = nil, workTree: String? = nil,
                    env: [String: String] = [:]) -> Git.Result {
        var environment = Git.environment.merging(["GIT_LITERAL_PATHSPECS": "1"]) { $1 }
        if let gitDir { environment["GIT_DIR"] = gitDir }
        if let workTree { environment["GIT_WORK_TREE"] = workTree }
        let front = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never", "-c", "submodule.recurse=false"]
        return Shell.run(executable: Platform.Tools.git, args: front + args, in: directory, env: environment.merging(env) { $1 }, timeout: 120)
    }

    /// The repository's git in `folder` (its `.git`, its files).
    static func repo(_ args: [String], _ folder: String, env: [String: String] = [:]) -> Git.Result {
        git(args, in: folder, gitDir: (folder as NSString).appendingPathComponent(".git"), workTree: folder, env: env)
    }

    static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    /// What is at `path` without following a link: nil when nothing.
    static func kind(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    static func failed(_ step: String, _ result: Git.Result) -> Refusal {
        let said = [result.error, result.output].first { !$0.isEmpty } ?? "it exited with status \(result.status)"
        return Refusal("git \(step) failed: \(ConfigSeal.inert(said, limit: 400))")
    }

    /// The environment `git config --global` reads `home`'s global config in (`~/.gitconfig`, `~/.config/git/config`).
    static func global(_ home: String) -> [String: String] {
        ["HOME": home, "XDG_CONFIG_HOME": (home as NSString).appendingPathComponent(".config")]
    }

    /// The user's identity from their global git config only (`--global`), never a repository's.
    static func identity(home: String) -> Result<Identity, Refusal> {
        let name = git(["config", "--global", "--get", "user.name"], in: "/", env: global(home)).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = git(["config", "--global", "--get", "user.email"], in: "/", env: global(home)).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else {
            return .failure(Refusal("the first commit needs your name and email in your global git config: `git config --global user.name NAME` and `git config --global user.email EMAIL`"))
        }
        return .success(Identity(name: name, email: email))
    }

    /// Why an existing repository in `folder` isn't one git may run in here, or nil.
    static func repositoryRefusal(_ folder: String) -> String? {
        let dotGit = (folder as NSString).appendingPathComponent(".git")
        let shown = ConfigSeal.inert(dotGit, limit: 400)
        guard kind(dotGit) == S_IFDIR else { return "\(shown) isn't a folder of its own (a link, or a file naming another git folder): --init doesn't make a commit there" }
        guard kind((dotGit as NSString).appendingPathComponent("commondir")) == nil else { return "\(shown) is a linked worktree's: --init doesn't make a commit there" }
        let config = (dotGit as NSString).appendingPathComponent("config")
        guard kind(config) == S_IFREG else { return "\(shown)/config isn't a plain file: --init doesn't make a commit there" }
        let listed = git(["config", "--file", config, "--null", "--list"], in: "/")
        guard listed.ok else { return "\(shown)/config didn't read: \(ConfigSeal.inert(listed.error, limit: 200))" }
        for entry in listed.output.split(separator: "\0") {
            let key = String(entry.split(separator: "\n", maxSplits: 1).first ?? "")
            if key.lowercased() == "core.worktree" { return "\(shown)/config sets core.worktree (its files elsewhere): --init doesn't make a commit there" }
            if key.lowercased() == "core.bare", entry.lowercased().hasSuffix("\ntrue") { return "\(shown) is a bare repository's: --init doesn't make a commit there" }
            guard allowed(key) else {
                return "\(shown)/config sets \(ConfigSeal.inert(key, limit: 120)), which --init doesn't run git under: make the first commit yourself, or take the key out"
            }
        }
        return nil
    }

    /// A repository with no commits at all: HEAD unborn and no refs.
    static func isEmpty(_ folder: String) -> Bool {
        guard !repo(["rev-parse", "--verify", "--quiet", "HEAD"], folder).ok else { return false }
        let refs = repo(["for-each-ref", "--count=1"], folder)
        return refs.ok && refs.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Why `folder` (as `chosen` resolved at the plan) isn't one to make a repository in, or nil.
    static func folderRefusal(_ folder: String, chosen: String? = nil, home: String) -> String? {
        let shown = ConfigSeal.inert(folder, limit: 400)
        guard kind(folder) == S_IFDIR else { return "\(shown) isn't a folder (or is a link to one: give the folder itself)" }
        let now = resolved(folder)
        if let chosen, now != chosen { return "\(shown) isn't the folder it was when the code was asked" }
        guard now != "/", now != resolved(home) else { return "--init makes no repository of \(shown): a project's lead goes in a folder of its own" }
        return nil
    }

    // MARK: The plan

    /// nil: the folder has commits, nothing to make. Else what the commit will hold, or why not. Touches nothing in the
    /// folder; the listing of a folder in no repository uses a bare git folder of its own in `scratch`, removed after.
    public static func plan(_ folder: String, home: String, scratch: URL) -> Result<Plan?, Refusal> {
        if let refused = folderRefusal(folder, home: home) { return .failure(Refusal(refused)) }
        let chosen = resolved(folder)
        let shown = ConfigSeal.inert(folder, limit: 400)
        let top = git(["rev-parse", "--show-toplevel"], in: chosen)
        var inRepository = false
        if top.ok, !top.output.isEmpty {
            let root = resolved(top.output.trimmingCharacters(in: .whitespacesAndNewlines))
            if git(["rev-parse", "--verify", "--quiet", "HEAD"], in: chosen).ok { return .success(nil) }
            // Its own .git first: one whose config moves its work tree (core.worktree) is said as that.
            if kind((chosen as NSString).appendingPathComponent(".git")) != nil, let refused = repositoryRefusal(chosen) { return .failure(Refusal(refused)) }
            guard root == chosen else {
                return .failure(Refusal("\(shown) is in the repository \(ConfigSeal.inert(root, limit: 400)), which has no commits: --init makes a first commit only in a repository's own folder"))
            }
            if let refused = repositoryRefusal(chosen) { return .failure(Refusal(refused)) }
            guard isEmpty(chosen) else {
                return .failure(Refusal("\(shown) has no commit on its branch but has some elsewhere (an orphan branch, a fetch): --init makes a first commit only in a repository with none at all"))
            }
            inRepository = true
        } else if kind((chosen as NSString).appendingPathComponent(".git")) != nil {
            return .failure(Refusal("\(shown) has a .git that isn't a repository git finds: --init doesn't make one there"))
        }
        let who: Identity
        switch identity(home: home) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let found): who = found
        }
        let branch = inRepository ? nil : ProjectCreation.branch(fromConfig: git(["config", "--global", "--get", "init.defaultBranch"], in: "/", env: global(home)))
        let addsGitignore = kind((chosen as NSString).appendingPathComponent(".gitignore")) == nil
        let probe = scratch.appendingPathComponent("lead-init-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        // The listing leaves out what a build leaves behind, as the .gitignore written will; secrets are listed, to be
        // named as left out.
        let builds = probe.appendingPathComponent("builds")
        do {
            try VibePaths.ensurePrivate(probe)
            try VibePaths.writePrivate(Data((FolderRepository.buildNames.joined(separator: "\n") + "\n").utf8), to: builds)
        } catch {
            return .failure(Refusal("the folder's files couldn't be listed: \(error.localizedDescription)"))
        }
        var listing: Git.Result
        let exclude = addsGitignore ? ["--exclude-from=\(builds.path)"] : []
        if inRepository {
            listing = repo(["ls-files", "-z", "--cached", "--others", "--exclude-standard"] + exclude, chosen)
        } else {
            let gitDir = probe.appendingPathComponent("git").path
            let made = git(["init", "--quiet", "--bare", gitDir], in: probe.path)
            guard made.ok else { return .failure(failed("init", made)) }
            listing = git(["ls-files", "-z", "--others", "--exclude-standard"] + exclude, in: chosen, gitDir: gitDir, workTree: chosen)
        }
        guard listing.ok else { return .failure(failed("ls-files", listing)) }
        let all = Set(listing.output.split(separator: "\0").map(String.init)).sorted()
        let nested = all.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }
        var files = all.filter { !looksSecret($0) }.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        if addsGitignore, !files.contains(".gitignore") { files.append(".gitignore") }
        return .success(Plan(folder: chosen, inRepository: inRepository, branch: branch, files: files.sorted(),
                             leftOut: all.filter(looksSecret).sorted(), nested: nested.sorted(), addsGitignore: addsGitignore, identity: who))
    }

    static func count(_ files: Int) -> String { files == 1 ? "1 file" : "\(files) files" }

    /// The most names a list in the prompt shows; the rest are counted.
    public static let shownNames = 20

    static func some(_ list: [String]) -> String {
        list.prefix(shownNames).map { ConfigSeal.inert($0, limit: 200) }.joined(separator: ", ")
            + (list.count > shownNames ? " and \(list.count - shownNames) more" : "")
    }

    /// What the code is asked for: what is made, every file by name (the first `shownNames`, the rest counted), what is
    /// left out and why, and whose name the commit carries.
    public static func words(_ plan: Plan) -> String {
        let folder = ConfigSeal.inert(plan.folder, limit: 400)
        var text = (plan.inRepository ? "First, in \(folder) (a repository with no commits yet), a first commit" : "First, git init in \(folder), and a first commit")
            + " of its \(count(plan.files.count))" + (plan.addsGitignore ? " (with a .gitignore for secrets and build output)" : "")
            + ", as \(ConfigSeal.inert(plan.identity.name, limit: 100)) <\(ConfigSeal.inert(plan.identity.email, limit: 100))>. It stays on this node: nothing is pushed."
        if !plan.files.isEmpty { text += "\nCommitted: \(some(plan.files))." }
        if !plan.leftOut.isEmpty { text += "\nLeft out, as they look like secrets: \(some(plan.leftOut))." }
        if !plan.nested.isEmpty { text += "\nA repository of its own, committed as a reference (its files aren't included): \(some(plan.nested))." }
        text += "\nNothing of the folder's git runs (no hooks, no filters), and anything changed in the folder before the code is typed refuses it."
        return text
    }

    // MARK: Making it

    /// The paths added in one `git add`.
    static let addBatch = 200

    /// Makes what `plan` says, or nothing: the folder checked again, git init (unless in a repository), the .gitignore
    /// if planned, the files left out noted in `.git/info/exclude`, the planned files added by path, the index compared
    /// with the plan, then the commit. On any refusal what this made is removed (a repository's index and exclude file
    /// put back). The paths the commit holds.
    public static func make(_ plan: Plan, home: String) -> Result<[String], Refusal> {
        let folder = plan.folder
        if let refused = folderRefusal(folder, chosen: folder, home: home) { return .failure(Refusal(refused)) }
        let dotGit = (folder as NSString).appendingPathComponent(".git")
        let gitignorePath = (folder as NSString).appendingPathComponent(".gitignore")
        let exclude = (dotGit as NSString).appendingPathComponent("info/exclude")
        let index = (dotGit as NSString).appendingPathComponent("index")
        var kept: [(path: String, data: Data?)] = []
        var wroteGitignore = false
        if plan.inRepository {
            if let refused = repositoryRefusal(folder) { return .failure(Refusal(refused)) }
            guard isEmpty(folder) else { return .failure(Refusal("\(ConfigSeal.inert(folder, limit: 400)) has a commit now: nothing was made")) }
            for path in [index, (exclude as NSString).deletingLastPathComponent, exclude] where kind(path) == S_IFLNK {
                return .failure(Refusal("\(ConfigSeal.inert(path, limit: 400)) is a link: --init writes only into the repository's own files"))
            }
            kept = [index, exclude].map { ($0, FileManager.default.contents(atPath: $0)) }
        } else {
            guard kind(dotGit) == nil else { return .failure(Refusal("\(ConfigSeal.inert(folder, limit: 400)) has a .git now: nothing was made")) }
        }
        func undo(_ refusal: Refusal) -> Result<[String], Refusal> {
            if plan.inRepository {
                for (path, data) in kept {
                    if let data { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) } else { try? FileManager.default.removeItem(atPath: path) }
                }
            } else if kind(dotGit) == S_IFDIR {
                try? FileManager.default.removeItem(atPath: dotGit)
            }
            if wroteGitignore { unlink(gitignorePath) }
            return .failure(refusal)
        }
        if !plan.inRepository {
            // In the folder itself, with nothing given: git init makes `.git` there, never anywhere a variable names.
            let made = git(["init", "--quiet", "--initial-branch=\(plan.branch ?? "main")"], in: folder)
            guard made.ok else { return undo(failed("init", made)) }
            guard kind(dotGit) == S_IFDIR, repositoryRefusal(folder) == nil else { return undo(Refusal("the new repository isn't as git init makes it: nothing was made")) }
        }
        if plan.addsGitignore {
            // Made new (never through a link, never over a file that came meanwhile: that one is the folder's own and the
            // index check below refuses the difference).
            let fd = open(gitignorePath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return undo(Refusal("the .gitignore couldn't be written in \(ConfigSeal.inert(folder, limit: 400)) (errno \(errno))")) }
            wroteGitignore = true
            let data = Data(gitignore.utf8)
            let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            guard wrote == data.count else { return undo(Refusal("the .gitignore couldn't be written in \(ConfigSeal.inert(folder, limit: 400))")) }
        }
        if !plan.leftOut.isEmpty {
            guard kind(exclude) != S_IFLNK, kind((exclude as NSString).deletingLastPathComponent) != S_IFLNK else {
                return undo(Refusal("\(ConfigSeal.inert(exclude, limit: 400)) is a link: --init writes only into the repository's own files"))
            }
            do {
                try FileManager.default.createDirectory(atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                var existing = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
                if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
                let lines = plan.leftOut.map { "/" + escapedPattern($0) }.joined(separator: "\n") + "\n"
                try Data((existing + lines).utf8).write(to: URL(fileURLWithPath: exclude), options: .atomic)
            } catch {
                return undo(Refusal("the files left out couldn't be noted in .git/info/exclude: \(error.localizedDescription)"))
            }
        }
        let identity = ["GIT_AUTHOR_NAME": plan.identity.name, "GIT_AUTHOR_EMAIL": plan.identity.email,
                        "GIT_COMMITTER_NAME": plan.identity.name, "GIT_COMMITTER_EMAIL": plan.identity.email]
        // Already in the index (a repository's staged files) needn't be added again; the rest by path, in batches.
        let staged = repo(["ls-files", "-z", "--cached"], folder)
        guard staged.ok else { return undo(failed("ls-files", staged)) }
        let before = Set(staged.output.split(separator: "\0").map(String.init))
        let toAdd = plan.files.filter { !before.contains($0) }
        var start = 0
        while start < toAdd.count {
            let batch = Array(toAdd[start..<min(start + addBatch, toAdd.count)])
            let added = repo(["add", "--"] + batch, folder, env: identity)
            guard added.ok else { return undo(failed("add", added)) }
            start += addBatch
        }
        let now = repo(["ls-files", "-z", "--cached"], folder)
        guard now.ok else { return undo(failed("ls-files", now)) }
        let inIndex = Set(now.output.split(separator: "\0").map(String.init))
        guard inIndex == Set(plan.files) else {
            let extra = inIndex.subtracting(plan.files).sorted(), missing = Set(plan.files).subtracting(inIndex).sorted()
            return undo(Refusal("the folder changed since the code was asked (" + [extra.isEmpty ? nil : "staged and not shown: \(some(extra))",
                                                                                    missing.isEmpty ? nil : "shown and gone: \(some(missing))"]
                .compactMap { $0 }.joined(separator: "; ") + "): nothing was committed"))
        }
        let committed = repo(["commit", "--quiet", "--no-verify", "--allow-empty", "-m", ProjectCreation.commitMessage], folder, env: identity)
        guard committed.ok else { return undo(failed("commit", committed)) }
        let tree = repo(["ls-tree", "-r", "-z", "--name-only", "HEAD"], folder)
        return .success(tree.ok ? tree.output.split(separator: "\0").map(String.init).sorted() : plan.files)
    }

    /// A path as a gitignore pattern that matches only itself.
    static func escapedPattern(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "\\*?[!# ".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
