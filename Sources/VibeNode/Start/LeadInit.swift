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
/// - The files are hashed as they are on disk with no filter and staged by mode and object into an index of the call's
///   own (nothing the repository's index held counts), compared entry by entry, and committed with plumbing (no index
///   refresh, no filter, no hook, no signing: those keys forced off on every call). The config and the folder (its
///   inode) are checked again right before the commit. A file gone during the prompt refuses, leaving the folder as it
///   was. What is printed after is what the commit holds.
/// - `.gitignore` and `.git/info/exclude` are written relative to the folder's descriptor, never through a link.
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
        /// The folder's device and inode at the plan: the same folder after the code, and after each git call.
        public var device: UInt64
        public var inode: UInt64
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
        var environment = Git.environment.merging(["GIT_LITERAL_PATHSPECS": "1", "GIT_ATTR_NOSYSTEM": "1", "GIT_PAGER": "cat",
                                                   "GIT_EDITOR": "/bin/false", "GIT_ASKPASS": "/bin/false"]) { $1 }
        if let gitDir { environment["GIT_DIR"] = gitDir }
        if let workTree { environment["GIT_WORK_TREE"] = workTree }
        // Forced on every call, over whatever the repository's config says by then (`-c` wins over its files): the
        // config is checked once and again before the commit, but it stays writable between git calls.
        let front = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never", "-c", "submodule.recurse=false",
                     "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false", "-c", "gpg.program=/bin/false", "-c", "core.attributesFile=/dev/null",
                     "-c", "core.pager=cat", "-c", "core.sshCommand=/bin/false"]
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

    /// The folder's device and inode, not following a link.
    static func identityOf(_ path: String) -> (device: UInt64, inode: UInt64)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
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
        guard let id = identityOf(chosen) else { return .failure(Refusal("\(shown) isn't there")) }
        return .success(Plan(folder: chosen, inRepository: inRepository, branch: branch, files: files.sorted(),
                             leftOut: all.filter(looksSecret).sorted(), nested: nested.sorted(), addsGitignore: addsGitignore, identity: who,
                             device: id.device, inode: id.inode))
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
        if plan.inRepository { text += "\nEach file is committed as it is on disk: what its index held before isn't." }
        text += "\nNothing of the folder's git runs (no hooks, no filters), and anything changed in the folder before the code is typed refuses it."
        return text
    }

    // MARK: Making it

    /// The paths hashed or staged in one git call.
    static let batch = 200

    /// What `make` made: the paths the commit holds, and a note when something after the commit didn't go as asked.
    public struct Made: Equatable, Sendable {
        public var files: [String]
        public var note: String?
    }

    /// One entry of the commit: its mode and object.
    struct Entry: Equatable {
        var mode: String
        var object: String
    }

    /// Makes what `plan` says, or nothing. The folder checked again (its resolved path, not a link, the same inode), the
    /// repository's config again; git init (unless in a repository); the .gitignore made new and the files left out noted
    /// in `.git/info/exclude`, both through descriptors (never through a link); then each planned file hashed as it is on
    /// disk with no filter (`hash-object --no-filters`), staged into an index of this call's own by mode and object
    /// (`update-index --cacheinfo`: nothing the repository's index held counts), the index compared entry by entry, the
    /// config and the folder checked once more, and the commit made with plumbing (`write-tree`, `commit-tree`,
    /// `update-ref` of a branch that must not exist yet: no index refresh, no filter, no hook). The repository's own index
    /// is then read from the commit. On a refusal before the commit what this made is removed (an existing repository's
    /// exclude file put back).
    public static func make(_ plan: Plan, home: String, scratch: URL) -> Result<Made, Refusal> {
        let folder = plan.folder
        let shown = ConfigSeal.inert(folder, limit: 400)
        if let refused = folderRefusal(folder, chosen: folder, home: home) { return .failure(Refusal(refused)) }
        func same() -> Bool { identityOf(folder).map { $0.device == plan.device && $0.inode == plan.inode } ?? false }
        guard same() else { return .failure(Refusal("\(shown) isn't the folder it was when the code was asked")) }
        let directory = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return .failure(Refusal("\(shown) couldn't be opened (errno \(errno))")) }
        defer { close(directory) }
        var opened = stat()
        guard fstat(directory, &opened) == 0, UInt64(opened.st_dev) == plan.device, UInt64(opened.st_ino) == plan.inode else {
            return .failure(Refusal("\(shown) isn't the folder it was when the code was asked"))
        }
        let dotGit = (folder as NSString).appendingPathComponent(".git")
        var keptExclude: Data??
        var wroteGitignore = false
        var madeGit = false
        if plan.inRepository {
            if let refused = repositoryRefusal(folder) { return .failure(Refusal(refused)) }
            guard isEmpty(folder) else { return .failure(Refusal("\(shown) has a commit now: nothing was made")) }
        } else {
            guard kind(dotGit) == nil else { return .failure(Refusal("\(shown) has a .git now: nothing was made")) }
        }
        func undo(_ refusal: Refusal) -> Result<Made, Refusal> {
            if madeGit, kind(dotGit) == S_IFDIR, same() { try? FileManager.default.removeItem(atPath: dotGit) }
            if let kept = keptExclude { _ = Descriptors.writeExclude(directory, kept) }
            if wroteGitignore { unlinkat(directory, ".gitignore", 0) }
            return .failure(refusal)
        }
        if !plan.inRepository {
            // In the folder itself, with nothing given: git init makes `.git` there, never anywhere a variable names.
            let made = git(["init", "--quiet", "--initial-branch=\(plan.branch ?? "main")"], in: folder)
            madeGit = made.ok || kind(dotGit) == S_IFDIR
            guard made.ok else { return undo(failed("init", made)) }
            guard same(), kind(dotGit) == S_IFDIR, repositoryRefusal(folder) == nil else { return undo(Refusal("the new repository isn't as git init makes it: nothing was made")) }
        }
        if plan.addsGitignore {
            // Made new, relative to the folder's descriptor (never through a link, never over a file that came meanwhile).
            guard Descriptors.create(directory, ".gitignore", Data(gitignore.utf8)) else {
                return undo(Refusal("the .gitignore couldn't be made in \(shown) (it came meanwhile, or errno \(errno))"))
            }
            wroteGitignore = true
        }
        if !plan.leftOut.isEmpty {
            switch Descriptors.readExclude(directory) {
            case .failure(let why): return undo(why)
            case .success(let existing):
                keptExclude = .some(existing)
                var text = existing.map { String(decoding: $0, as: UTF8.self) } ?? ""
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                text += plan.leftOut.map { "/" + escapedPattern($0) }.joined(separator: "\n") + "\n"
                if let why = Descriptors.writeExclude(directory, Data(text.utf8)) { return undo(Refusal(why)) }
            }
        }
        let probe = scratch.appendingPathComponent("lead-init-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        do { try VibePaths.ensurePrivate(probe) } catch { return undo(Refusal("a scratch folder couldn't be made: \(error.localizedDescription)")) }
        let own = ["GIT_INDEX_FILE": probe.appendingPathComponent("index").path]
        let entries: [String: Entry]
        switch stage(plan, directory: directory, probe: probe, index: own) {
        case .failure(let refusal): return undo(refusal)
        case .success(let staged): entries = staged
        }
        // Checked again right before the commit: the config git read meanwhile, and the folder.
        if let refused = repositoryRefusal(folder) { return undo(Refusal(refused)) }
        guard same() else { return undo(Refusal("\(shown) isn't the folder it was when the code was asked")) }
        let identity = ["GIT_AUTHOR_NAME": plan.identity.name, "GIT_AUTHOR_EMAIL": plan.identity.email,
                        "GIT_COMMITTER_NAME": plan.identity.name, "GIT_COMMITTER_EMAIL": plan.identity.email]
        let tree = repo(["write-tree"], folder, env: own)
        guard tree.ok, !tree.output.isEmpty else { return undo(failed("write-tree", tree)) }
        let commit = repo(["commit-tree", tree.output.trimmingCharacters(in: .whitespacesAndNewlines), "-m", ProjectCreation.commitMessage], folder, env: identity)
        guard commit.ok, !commit.output.isEmpty else { return undo(failed("commit-tree", commit)) }
        let head = commit.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // The branch HEAD names, which must not exist yet (empty old value): a commit that came meanwhile isn't replaced.
        let moved = repo(["update-ref", "-m", "lead --init: " + ProjectCreation.commitMessage, "HEAD", head, ""], folder)
        guard moved.ok else { return undo(failed("update-ref", moved)) }
        let listed = repo(["ls-tree", "-r", "-z", "--name-only", head], folder)
        let files = listed.ok ? listed.output.split(separator: "\0").map(String.init).sorted() : entries.keys.sorted()
        // The repository's own index, now the commit's (read-tree touches the index alone, never a file).
        let read = repo(["read-tree", head], folder)
        let note = read.ok ? nil : "the commit is made, but its index wasn't updated (\(ConfigSeal.inert(read.error, limit: 200))): `git reset` in the folder puts it right"
        return .success(Made(files: files, note: same() ? note : (note.map { $0 + "; " } ?? "") + "the folder changed during the commit: look at it before the lead starts"))
    }

    /// What is at a planned path, read relative to the folder's descriptor `directory` one component at a time
    /// (`openat` with `O_NOFOLLOW`: a folder on the way swapped for a link refuses), never through the path.
    enum Found {
        case file(Data, executable: Bool)
        case link(String)
        case folder
    }

    static func read(_ path: String, in directory: Int32) -> Result<Found, Refusal> {
        let shown = ConfigSeal.inert(path, limit: 200)
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last, !parts.contains(".."), !parts.contains(".") else { return .failure(Refusal("\(shown) isn't a path in the folder")) }
        var parent = dup(directory)
        guard parent >= 0 else { return .failure(Refusal("\(shown) couldn't be read (errno \(errno))")) }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                return .failure(Refusal("the folder changed since the code was asked (\(shown): a folder on its way isn't one now, or is a link): nothing was committed"))
            }
            close(parent)
            parent = next
        }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return .failure(Refusal("the folder changed since the code was asked (shown and gone: \(shown)): nothing was committed"))
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlinkat(parent, name, &buffer, Int(PATH_MAX))
            guard count >= 0 else { return .failure(Refusal("\(shown) couldn't be read as a link (errno \(errno))")) }
            return .success(.link(String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)))
        case S_IFDIR:
            return .success(.folder)
        case S_IFREG:
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return .failure(Refusal("the folder changed since the code was asked (\(shown) couldn't be opened as a file): nothing was committed")) }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else {
                return .failure(Refusal("the folder changed since the code was asked (\(shown) isn't a plain file now): nothing was committed"))
            }
            let data = (try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd()) ?? Data()
            return .success(.file(data, executable: opened.st_mode & 0o111 != 0))
        default:
            return .failure(Refusal("\(shown) isn't a file now: nothing was committed"))
        }
    }

    /// Each planned path read relative to the folder's descriptor (`read`: never through the path, so nothing from
    /// outside the folder is pulled in), its bytes (a link's target) copied into the private `probe` and hashed from
    /// there with no filter (`--no-filters`; a nested repository by its HEAD), staged by mode and object into the index
    /// `index` names, then compared with it entry by entry. Any path that isn't what the plan listed refuses.
    static func stage(_ plan: Plan, directory: Int32, probe: URL, index: [String: String]) -> Result<[String: Entry], Refusal> {
        let folder = plan.folder
        var entries: [String: Entry] = [:]
        var copies: [(path: String, mode: String, copy: String)] = []
        for (number, path) in plan.files.enumerated() {
            let found: Found
            switch read(path, in: directory) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let read): found = read
            }
            let copy = probe.appendingPathComponent("blob-\(number)").path
            switch found {
            case .file(let data, let executable):
                guard scratchCopy(data, at: copy) else { return .failure(Refusal("a scratch copy couldn't be made")) }
                copies.append((path, executable ? "100755" : "100644", copy))
            case .link(let target):
                guard scratchCopy(Data(target.utf8), at: copy) else { return .failure(Refusal("a scratch copy couldn't be made")) }
                copies.append((path, "120000", copy))
            case .folder:
                guard plan.nested.contains(path) else { return .failure(Refusal("\(ConfigSeal.inert(path, limit: 200)) is a folder now: nothing was committed")) }
                // A reference: its commit's id only, nothing of its files.
                let nested = git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: (folder as NSString).appendingPathComponent(path))
                guard nested.ok, !nested.output.isEmpty else {
                    return .failure(Refusal("\(ConfigSeal.inert(path, limit: 200)) is a repository of its own with no commit: it can't be committed as a reference"))
                }
                entries[path] = Entry(mode: "160000", object: nested.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        var start = 0
        while start < copies.count {
            let slice = Array(copies[start..<min(start + batch, copies.count)])
            let hashed = repo(["hash-object", "--no-filters", "-w", "--"] + slice.map(\.copy), folder)
            let objects = hashed.output.split(whereSeparator: \.isNewline).map(String.init)
            guard hashed.ok, objects.count == slice.count else { return .failure(failed("hash-object", hashed)) }
            for (item, object) in zip(slice, objects) { entries[item.path] = Entry(mode: item.mode, object: object) }
            start += batch
        }
        let ordered = entries.sorted { $0.key < $1.key }
        start = 0
        while start < ordered.count {
            let slice = ordered[start..<min(start + batch, ordered.count)]
            let staged = repo(["update-index", "--add"] + slice.flatMap { ["--cacheinfo", "\($0.value.mode),\($0.value.object),\($0.key)"] }, folder, env: index)
            guard staged.ok else { return .failure(failed("update-index", staged)) }
            start += batch
        }
        // The index as git wrote it, entry by entry: exactly the planned paths, each with the mode and object hashed.
        let listed = repo(["ls-files", "-s", "-z"], folder, env: index)
        guard listed.ok else { return .failure(failed("ls-files", listed)) }
        var inIndex: [String: Entry] = [:]
        for record in listed.output.split(separator: "\0") {
            let parts = record.split(separator: "\t", maxSplits: 1)
            let head = parts.first?.split(separator: " ") ?? []
            guard parts.count == 2, head.count == 3 else { return .failure(Refusal("the index read back isn't one git writes")) }
            inIndex[String(parts[1])] = Entry(mode: String(head[0]), object: String(head[1]))
        }
        guard inIndex == entries, Set(entries.keys) == Set(plan.files) else {
            return .failure(Refusal("the index read back isn't what was hashed from the folder: nothing was committed"))
        }
        return .success(entries)
    }

    /// `data` as a new private file at `path`, in the call's own scratch folder.
    static func scratchCopy(_ data: Data, at path: String) -> Bool {
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// The folder's `.gitignore` and `.git/info/exclude`, written relative to the folder's descriptor: each folder
    /// opened `O_NOFOLLOW`, each file made new (`O_EXCL`) and renamed in, so a link put in their place is refused, never
    /// written through.
    enum Descriptors {
        static func create(_ directory: Int32, _ name: String, _ data: Data) -> Bool {
            let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
        }

        /// `.git/info` opened from the folder's descriptor (made when missing), never through a link; -1 and why.
        static func info(_ directory: Int32) -> (Int32, String?) {
            let git = openat(directory, ".git", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard git >= 0 else { return (-1, ".git couldn't be opened as a folder of its own (errno \(errno)): nothing was made") }
            defer { close(git) }
            if mkdirat(git, "info", 0o755) != 0, errno != EEXIST { return (-1, ".git/info couldn't be made (errno \(errno))") }
            let info = openat(git, "info", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard info >= 0 else { return (-1, ".git/info isn't a folder of the repository's own (a link?): --init writes only into the repository's own files") }
            return (info, nil)
        }

        /// The exclude file's bytes (nil: there's none).
        static func readExclude(_ directory: Int32) -> Result<Data?, Refusal> {
            let (info, why) = info(directory)
            guard info >= 0 else { return .failure(Refusal(why ?? "")) }
            defer { close(info) }
            let fd = openat(info, "exclude", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 { return errno == ENOENT ? .success(nil) : .failure(Refusal(".git/info/exclude isn't a file of the repository's own (a link?)")) }
            defer { close(fd) }
            var kind = stat()
            guard fstat(fd, &kind) == 0, kind.st_mode & S_IFMT == S_IFREG else { return .failure(Refusal(".git/info/exclude isn't a plain file")) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            return .success((try? handle.readToEnd()) ?? Data())
        }

        /// Writes `data` as the exclude file (nil: removes it); why not.
        @discardableResult
        static func writeExclude(_ directory: Int32, _ data: Data?) -> String? {
            let (info, why) = info(directory)
            guard info >= 0 else { return why }
            defer { close(info) }
            guard let data else { unlinkat(info, "exclude", 0); return nil }
            let temporary = "exclude.vs-\(UUID().uuidString.prefix(8))"
            guard create(info, temporary, data) else { return ".git/info/exclude couldn't be written (errno \(errno))" }
            guard renameat(info, temporary, info, "exclude") == 0 else {
                unlinkat(info, temporary, 0)
                return ".git/info/exclude couldn't be written (errno \(errno))"
            }
            return nil
        }
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
