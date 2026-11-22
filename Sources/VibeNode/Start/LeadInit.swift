import Foundation
import VibeCore

/// `vibeswitcher lead FOLDER --init` (the app's first-commit offer, `LeadController` and `ProjectFolderStart`; the
/// parity table's first row), narrowed by the whole-feature review of 2026-11-22: a folder in **no repository** gets a
/// git repository and a first commit of its files, then its lead. A folder with any `.git`, or inside a repository, is
/// refused: the user makes that first commit. Planned before the typed code (`plan`, touching nothing), made after it
/// (`make`), by the command line's own process.
///
/// Built for a folder a worker may have written, so nothing of the folder runs and nothing of it can be in the way:
/// - **Built privately.** The repository is made in the node's private scratch folder (`git init --bare --template=`:
///   no template, no sample hook), its objects hashed there from bytes read through the folder's descriptor, the
///   commit made there with plumbing (`hash-object --no-filters`, `update-index --cacheinfo`, `write-tree`,
///   `commit-tree`, `update-ref`). Nothing under the folder is touched while it is built, so no link, planted object or
///   hook of the folder's can be in the way. No hooks folder is installed, so the lead's first look accepts none.
/// - **Installed through descriptors.** `.git` is made with `mkdirat` on the folder's descriptor (it must not exist),
///   the private git folder copied into it one `mkdirat`/`openat(O_CREAT|O_EXCL|O_NOFOLLOW)` at a time, and checked to
///   be the folder it made; `.gitignore` the same way. Any failure removes what was made, through the descriptors.
/// - **Read through descriptors.** Each file is opened from the folder's descriptor one component at a time with
///   `O_NOFOLLOW` (a folder on the way swapped for a link refuses), `fstat`ed a plain file with one link (a hard link to
///   a file elsewhere refuses), copied in a stream into the private folder within its size (`maxFileBytes`, all of them
///   within `maxTotalBytes`; a read short of its size refuses). A link is committed as a link.
/// - **git with nothing inherited.** Every call starts from a fixed environment (`environment`), never this process's
///   (no `GIT_DIR`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY` or `GIT_CONFIG_*` of the caller's), no system config, hooks
///   and signing and the attributes file forced off, the trusted git by its path (`Platform.Tools.git`).
/// - **The user's own words for the rest.** The author is the user's global git config's; every committed name is shown
///   in the prompt (`maxFiles` at most, else refused), and the secrets left out (the app's list and more, matched
///   without case) are named and kept out of later commits; a name with a control character, or a repository of its
///   own inside, is refused. The folder is checked again after the code: the same folder (its inode), not a link, not
///   the home folder or `/`, still in no repository, no `.git`.
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
        /// The branch made (the user's `init.defaultBranch`, else main).
        public var branch: String
        /// What the commit holds, relative to `folder`, sorted.
        public var files: [String]
        /// What looks like a secret: not committed, and kept out of later commits.
        public var leftOut: [String]
        /// The folder has no .gitignore: `gitignore` is made and committed.
        public var addsGitignore: Bool
        public var identity: Identity
        /// The folder's device and inode at the plan: the same folder after the code.
        public var device: UInt64
        public var inode: UInt64
    }

    /// The most files a first commit holds here; past it the user makes it.
    public static let maxFiles = 2000
    /// The largest file read, and all of them together.
    public static let maxFileBytes: Int64 = 100 * 1024 * 1024
    public static let maxTotalBytes: Int64 = 500 * 1024 * 1024

    /// File names that look like secrets: the app's (`FolderRepository.secretNames`) and more, matched without case.
    public static let secretNames = FolderRepository.secretNames + [
        ".npmrc", ".netrc", ".git-credentials", ".pypirc", ".envrc", "*.env", "credentials.json", "*.pfx", "*.jks", "*.tfvars",
        "terraform.tfstate*", "id_dsa*", "*.keystore",
    ]

    /// The .gitignore made when the folder has none.
    public static var gitignore: String { (secretNames + FolderRepository.buildNames).joined(separator: "\n") + "\n" }

    /// Whether a file's name (the last part of `path`) looks like a secret, whatever its case.
    public static func looksSecret(_ path: String) -> Bool {
        let name = ((path.hasSuffix("/") ? String(path.dropLast()) : path) as NSString).lastPathComponent.lowercased()
        return secretNames.contains { fnmatch($0.lowercased(), name, 0) == 0 }
    }

    // MARK: git, with nothing inherited

    /// The environment every git call here gets, whole: nothing of this process's (no `GIT_*` of the caller's), the
    /// user's `home` for their global config, no system config, English messages.
    static func environment(home: String, adding: [String: String] = [:]) -> [String: String] {
        var environment = ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": home,
                           "XDG_CONFIG_HOME": (home as NSString).appendingPathComponent(".config"), "LC_ALL": "C", "LANG": "C",
                           "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_LITERAL_PATHSPECS": "1",
                           "GIT_ATTR_NOSYSTEM": "1", "GIT_PAGER": "cat", "GIT_EDITOR": "/bin/false", "GIT_ASKPASS": "/bin/false"]
        for (key, value) in adding { environment[key] = value }
        return environment
    }

    /// Forced on every call, over any config (`-c` wins over files).
    static let front = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never", "-c", "submodule.recurse=false",
                        "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false", "-c", "gpg.program=/bin/false", "-c", "core.attributesFile=/dev/null",
                        "-c", "core.pager=cat", "-c", "core.sshCommand=/bin/false", "-c", "init.templateDir="]

    public struct Ran: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public var error: String
        public var ok: Bool { status == 0 }
        public var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// git (the trusted one, by its path) with `args` in `directory`, the environment `environment(home:adding:)` and
    /// nothing else; stdout read, stderr kept in a file of the private `scratch`. Bounded waits, never Foundation's.
    static func git(_ args: [String], in directory: String, home: String, scratch: URL, adding: [String: String] = [:], timeout: TimeInterval = 120) -> Ran {
        let errors = scratch.appendingPathComponent("stderr-\(UUID().uuidString.prefix(8))").path
        defer { unlink(errors) }
        var ends: [Int32] = [-1, -1]
        guard Sys.pipeClosedOnExec(&ends) == 0 else { return Ran(status: -1, output: "", error: "no pipe (errno \(errno))") }
        var spawn = Platform.Spawn(executable: Platform.Tools.git, arguments: [Platform.Tools.git] + front + args)
        spawn.environment = environment(home: home, adding: adding).map { "\($0.key)=\($0.value)" }.sorted()
        spawn.directory = directory
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .descriptor(ends[1])
        spawn.stderr = .path(errors, flags: O_WRONLY | O_CREAT | O_TRUNC, mode: 0o600)
        spawn.group = .ownGroup
        let started = spawn.start()
        Sys.close(ends[1])
        defer { Sys.close(ends[0]) }
        guard case .success(let pid) = started else { return Ran(status: -1, output: "", error: "git couldn't be started") }
        let clock = MacTime.real
        let deadline = clock.awake() + timeout
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var timedOut = false
        while true {
            let left = deadline - clock.awake()
            guard left > 0 else { timedOut = true; break }
            var watched = pollfd(fd: ends[0], events: Int16(POLLIN), revents: 0)
            let woke = poll(&watched, 1, Int32(max(1, min(left * 1_000, 1_000))))
            if woke < 0, errno == EINTR { continue }
            if woke == 0 { continue }
            let got = Sys.read(ends[0], &chunk, chunk.count)
            if got < 0, errno == EINTR || errno == EAGAIN { continue }
            guard got > 0 else { break }
            output.append(contentsOf: chunk[0..<got])
        }
        if timedOut { Sys.kill(-pid, SIGKILL) }
        var status: Int32 = 0
        let collectBy = clock.awake() + 10
        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { break }
            if reaped < 0, errno != EINTR { return Ran(status: -1, output: "", error: "git's end wasn't collected") }
            if clock.awake() > collectBy { Sys.kill(-pid, SIGKILL) }
            usleep(5_000)
        }
        let said = FileManager.default.contents(atPath: errors).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let exit: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Ran(status: timedOut ? -1 : exit, output: String(decoding: output, as: UTF8.self), error: timedOut ? "git ran past \(Int(timeout)) s" : said)
    }

    static func failed(_ step: String, _ ran: Ran) -> Refusal {
        let said = [ran.error, ran.output].first { !$0.isEmpty } ?? "it exited with status \(ran.status)"
        return Refusal("git \(step) failed: \(ConfigSeal.inert(said, limit: 400))")
    }

    // MARK: Folders

    static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    /// What is at `path` without following a link: nil when nothing.
    static func kind(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    /// The folder's device and inode, not following a link.
    static func identityOf(_ path: String) -> (device: UInt64, inode: UInt64)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    /// Why `folder` isn't one to make a repository in (not a folder, a link, `/`, the home folder), or nil.
    static func folderRefusal(_ folder: String, home: String) -> String? {
        let shown = ConfigSeal.inert(folder, limit: 400)
        guard kind(folder) == S_IFDIR else { return "\(shown) isn't a folder (or is a link to one: give the folder itself)" }
        let now = resolved(folder)
        guard now != "/", now != resolved(home) else { return "--init makes no repository of \(shown): a project's lead goes in a folder of its own" }
        return nil
    }

    /// Why `folder` isn't in no repository, or nil: it has a `.git` of any kind, or git finds a repository there, or git
    /// says anything else than that there is none (a folder inside a git folder, inside a bare repository).
    static func repositoryRefusal(_ folder: String, home: String, scratch: URL) -> String? {
        let shown = ConfigSeal.inert(folder, limit: 400)
        if kind((folder as NSString).appendingPathComponent(".git")) != nil {
            return "\(shown) has a .git already: --init is only for a folder in no repository. With commits, start the lead without --init; with none, make the first commit yourself (git add, git commit) or remove the empty .git"
        }
        let found = git(["rev-parse", "--show-toplevel"], in: folder, home: home, scratch: scratch)
        if found.ok {
            return "\(shown) is inside the repository \(ConfigSeal.inert(found.trimmed, limit: 400)): --init is only for a folder in no repository"
        }
        guard found.error.contains("not a git repository") else {
            return "\(shown): git couldn't say it is in no repository (\(ConfigSeal.inert(found.error.trimmingCharacters(in: .whitespacesAndNewlines), limit: 300))): --init refuses"
        }
        return nil
    }

    // MARK: The plan

    /// What the commit will hold, or why not. Touches nothing in the folder: the listing (the folder's .gitignore and the
    /// user's excludes as git reads them) uses a bare git folder of its own in the private `scratch`, removed after.
    public static func plan(_ folder: String, home: String, scratch: URL) -> Result<Plan, Refusal> {
        tidy(scratch)
        if let refused = folderRefusal(folder, home: home) { return .failure(Refusal(refused)) }
        let chosen = resolved(folder)
        let shown = ConfigSeal.inert(folder, limit: 400)
        let probe = scratch.appendingPathComponent("lead-init-\(UUID().uuidString)", isDirectory: true)
        do { try VibePaths.ensurePrivate(probe) } catch { return .failure(Refusal("a private scratch folder couldn't be made: \(error.localizedDescription)")) }
        defer { try? FileManager.default.removeItem(at: probe) }
        if let refused = repositoryRefusal(chosen, home: home, scratch: probe) { return .failure(Refusal(refused)) }
        let name = git(["config", "--global", "--get", "user.name"], in: "/", home: home, scratch: probe).trimmed
        let email = git(["config", "--global", "--get", "user.email"], in: "/", home: home, scratch: probe).trimmed
        guard !name.isEmpty, !email.isEmpty else {
            return .failure(Refusal("the first commit needs your name and email in your global git config: `git config --global user.name NAME` and `git config --global user.email EMAIL`"))
        }
        let configured = git(["config", "--global", "--get", "init.defaultBranch"], in: "/", home: home, scratch: probe)
        // As `ProjectCreation.branch`: the configured one when it is one word, else main.
        let branch = configured.ok && !configured.trimmed.isEmpty && !configured.trimmed.contains(where: \.isWhitespace) ? configured.trimmed : "main"
        guard git(["check-ref-format", "--branch", branch], in: "/", home: home, scratch: probe).ok else {
            return .failure(Refusal("your init.defaultBranch, \(ConfigSeal.inert(branch, limit: 100)), isn't a branch name git takes"))
        }
        let addsGitignore = kind((chosen as NSString).appendingPathComponent(".gitignore")) == nil
        // The listing leaves out what a build leaves behind, as the .gitignore made will; secrets are listed, to be named.
        let builds = probe.appendingPathComponent("builds")
        do { try VibePaths.writePrivate(Data((FolderRepository.buildNames.joined(separator: "\n") + "\n").utf8), to: builds) } catch {
            return .failure(Refusal("the folder's files couldn't be listed: \(error.localizedDescription)"))
        }
        let gitDir = probe.appendingPathComponent("list.git").path
        let made = git(["init", "--quiet", "--bare", "--template=", gitDir], in: probe.path, home: home, scratch: probe)
        guard made.ok else { return .failure(failed("init", made)) }
        let listing = git(["--git-dir=\(gitDir)", "--work-tree=\(chosen)", "ls-files", "-z", "--others", "--exclude-standard"]
                          + (addsGitignore ? ["--exclude-from=\(builds.path)"] : []), in: chosen, home: home, scratch: probe)
        guard listing.ok else { return .failure(failed("ls-files", listing)) }
        let all = Set(listing.output.split(separator: "\0").map(String.init)).sorted()
        if let odd = all.first(where: { $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }) {
            return .failure(Refusal("\(ConfigSeal.inert(odd, limit: 200)) has a control character in its name: --init refuses it; rename it, or make the first commit yourself"))
        }
        if let nested = all.first(where: { $0.hasSuffix("/") }) {
            return .failure(Refusal("\(ConfigSeal.inert(nested, limit: 200)) is a repository of its own: --init doesn't commit one inside; make the first commit yourself"))
        }
        var files = all.filter { !looksSecret($0) }
        if addsGitignore, !files.contains(".gitignore") { files.append(".gitignore") }
        guard files.count <= maxFiles else {
            return .failure(Refusal("\(shown) has \(files.count) files to commit, more than --init commits (\(maxFiles)): make the first commit yourself"))
        }
        guard let id = identityOf(chosen) else { return .failure(Refusal("\(shown) isn't there")) }
        return .success(Plan(folder: chosen, branch: branch, files: files.sorted(), leftOut: all.filter(looksSecret).sorted(),
                             addsGitignore: addsGitignore, identity: Identity(name: name, email: email), device: id.device, inode: id.inode))
    }

    /// Private folders an interrupted run left in `scratch` (Ctrl-C at the prompt or mid-build), an hour old or more:
    /// removed.
    static func tidy(_ scratch: URL, now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        for name in names where name.hasPrefix("lead-init-") {
            let url = scratch.appendingPathComponent(name)
            let changed = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? now
            if now.timeIntervalSince(changed) >= 3600 { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func count(_ files: Int) -> String { files == 1 ? "1 file" : "\(files) files" }

    /// What the code is asked for: what is made, every committed file by name (one a line), what is left out and why,
    /// and whose name the commit carries.
    public static func words(_ plan: Plan) -> String {
        let folder = ConfigSeal.inert(plan.folder, limit: 400)
        var text = "First, a git repository in \(folder) on branch \(ConfigSeal.inert(plan.branch, limit: 100)), and a first commit of its \(count(plan.files.count))"
            + (plan.addsGitignore ? " (with a .gitignore for secrets and build output)" : "")
            + ", as \(ConfigSeal.inert(plan.identity.name, limit: 100)) <\(ConfigSeal.inert(plan.identity.email, limit: 100))>. It stays on this node: nothing is pushed."
        if !plan.files.isEmpty { text += "\nCommitted:\n" + plan.files.map { "  " + ConfigSeal.inert($0, limit: 300) }.joined(separator: "\n") }
        if !plan.leftOut.isEmpty { text += "\nLeft out, as they look like secrets:\n" + plan.leftOut.map { "  " + ConfigSeal.inert($0, limit: 300) }.joined(separator: "\n") }
        text += "\nNothing of the folder's runs (no hooks, no filters); anything changed in the folder before the code is typed refuses it."
        return text
    }

    // MARK: Reading the folder

    /// What is at a planned path, read relative to the folder's descriptor `directory` one component at a time
    /// (`openat` with `O_NOFOLLOW`), its bytes (a link's target) copied in a stream to the new private file `copy`.
    enum Found: Equatable {
        case file(bytes: Int64, executable: Bool)
        case link
    }

    static func read(_ path: String, in directory: Int32, to copy: String, limit: Int64) -> Result<Found, Refusal> {
        let shown = ConfigSeal.inert(path, limit: 200)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return .failure(Refusal("\(shown) isn't a path in the folder")) }
        var parent = dup(directory)
        guard parent >= 0 else { return .failure(Refusal("\(shown) couldn't be read (errno \(errno))")) }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                return .failure(Refusal("the folder changed since the code was asked (\(shown): a folder on its way isn't one now, or is a link): nothing was made"))
            }
            close(parent)
            parent = next
        }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return .failure(Refusal("the folder changed since the code was asked (shown and gone: \(shown)): nothing was made"))
        }
        let out = open(copy, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { return .failure(Refusal("a private copy couldn't be made (errno \(errno))")) }
        defer { close(out) }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlinkat(parent, name, &buffer, Int(PATH_MAX))
            guard count >= 0 else { return .failure(Refusal("\(shown) couldn't be read as a link (errno \(errno))")) }
            guard buffer.withUnsafeBytes({ write(out, $0.baseAddress, count) }) == count else { return .failure(Refusal("a private copy couldn't be written")) }
            return .success(.link)
        case S_IFREG:
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return .failure(Refusal("the folder changed since the code was asked (\(shown) couldn't be opened as a file): nothing was made")) }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else {
                return .failure(Refusal("the folder changed since the code was asked (\(shown) isn't a plain file now): nothing was made"))
            }
            guard opened.st_nlink == 1 else {
                return .failure(Refusal("\(shown) has \(opened.st_nlink) hard links (the same file elsewhere too): --init doesn't commit it; make the first commit yourself"))
            }
            let size = Int64(opened.st_size)
            guard size <= limit else {
                return .failure(Refusal("\(shown) is \(size) bytes, more than --init commits (\(limit) here): make the first commit yourself"))
            }
            var copied: Int64 = 0
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let got = Sys.read(fd, &chunk, chunk.count)
                if got < 0, errno == EINTR { continue }
                guard got >= 0 else { return .failure(Refusal("\(shown) couldn't be read (errno \(errno)): nothing was made")) }
                if got == 0 { break }
                copied += Int64(got)
                guard copied <= size else { return .failure(Refusal("\(shown) grew while it was read: nothing was made")) }
                guard chunk.withUnsafeBytes({ write(out, $0.baseAddress, got) }) == got else { return .failure(Refusal("a private copy couldn't be written")) }
            }
            guard copied == size else { return .failure(Refusal("\(shown) read short of its size: nothing was made")) }
            return .success(.file(bytes: size, executable: opened.st_mode & 0o111 != 0))
        default:
            return .failure(Refusal("\(shown) isn't a file now: nothing was made"))
        }
    }

    // MARK: Making it

    /// The paths hashed or staged in one git call.
    static let batch = 200

    /// What `make` made: the paths the commit holds, and its id.
    public struct Made: Equatable, Sendable {
        public var files: [String]
        public var commit: String
    }

    /// Makes what `plan` says, or nothing: the folder checked again (the same inode, not a link, not home or `/`, in no
    /// repository, no `.git`), the repository built in a private folder of `scratch` (`build`), then installed into the
    /// folder through its descriptor (`install`). `maxFile` and `maxTotal`: the size caps (tests give smaller).
    public static func make(_ plan: Plan, home: String, scratch: URL, maxFile: Int64 = maxFileBytes, maxTotal: Int64 = maxTotalBytes) -> Result<Made, Refusal> {
        let folder = plan.folder
        let shown = ConfigSeal.inert(folder, limit: 400)
        if let refused = folderRefusal(folder, home: home) { return .failure(Refusal(refused)) }
        let directory = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return .failure(Refusal("\(shown) couldn't be opened (errno \(errno))")) }
        defer { close(directory) }
        var opened = stat()
        guard fstat(directory, &opened) == 0, UInt64(opened.st_dev) == plan.device, UInt64(opened.st_ino) == plan.inode, resolved(folder) == folder else {
            return .failure(Refusal("\(shown) isn't the folder it was when the code was asked"))
        }
        let probe = scratch.appendingPathComponent("lead-init-\(UUID().uuidString)", isDirectory: true)
        do { try VibePaths.ensurePrivate(probe) } catch { return .failure(Refusal("a private scratch folder couldn't be made: \(error.localizedDescription)")) }
        defer { try? FileManager.default.removeItem(at: probe) }
        if let refused = repositoryRefusal(folder, home: home, scratch: probe) { return .failure(Refusal(refused)) }
        let built: (gitDir: String, made: Made)
        switch build(plan, directory: directory, home: home, probe: probe, maxFile: maxFile, maxTotal: maxTotal) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let done): built = done
        }
        if let refused = install(built.gitDir, plan: plan, into: directory) { return .failure(refused) }
        return .success(built.made)
    }

    /// The repository built in `probe` (private): `git init --bare --template=`, each planned file read through the
    /// folder's descriptor and hashed there with no filter, staged by mode and object, compared entry by entry,
    /// committed with plumbing on the plan's branch (with its reflog), then made a non-bare repository's git folder for
    /// the folder (`core.bare=false`, its index, the files left out in `info/exclude`). Nothing in the folder is written.
    static func build(_ plan: Plan, directory: Int32, home: String, probe: URL, maxFile: Int64, maxTotal: Int64) -> Result<(gitDir: String, made: Made), Refusal> {
        let gitDir = probe.appendingPathComponent("git").path
        let index = probe.appendingPathComponent("index").path
        let empty = probe.appendingPathComponent("empty", isDirectory: true)
        do { try VibePaths.ensurePrivate(empty) } catch { return .failure(Refusal("a private scratch folder couldn't be made")) }
        func run(_ args: [String], adding: [String: String] = [:]) -> Ran {
            git(["--git-dir=\(gitDir)", "--work-tree=\(empty.path)"] + args, in: probe.path, home: home, scratch: probe,
                adding: ["GIT_INDEX_FILE": index].merging(adding) { $1 })
        }
        let made = git(["init", "--quiet", "--bare", "--template=", "--initial-branch=\(plan.branch)", gitDir], in: probe.path, home: home, scratch: probe)
        guard made.ok else { return .failure(failed("init", made)) }
        // The .gitignore's bytes are this process's own; every other file's are read through the folder's descriptor.
        var copies: [(path: String, mode: String, copy: String)] = []
        var total: Int64 = 0
        for (number, path) in plan.files.enumerated() {
            let copy = probe.appendingPathComponent("blob-\(number)").path
            if plan.addsGitignore, path == ".gitignore" {
                guard FileManager.default.createFile(atPath: copy, contents: Data(gitignore.utf8), attributes: [.posixPermissions: 0o600]) else {
                    return .failure(Refusal("a private copy couldn't be made"))
                }
                copies.append((path, "100644", copy))
                continue
            }
            switch read(path, in: directory, to: copy, limit: maxFile) {
            case .failure(let refusal): return .failure(refusal)
            case .success(.link): copies.append((path, "120000", copy))
            case .success(.file(let bytes, let executable)):
                total += bytes
                guard total <= maxTotal else {
                    return .failure(Refusal("the files come to more than --init commits (\(maxTotal) bytes here), at \(ConfigSeal.inert(path, limit: 200)): make the first commit yourself"))
                }
                copies.append((path, executable ? "100755" : "100644", copy))
            }
        }
        var entries: [String: String] = [:]
        var start = 0
        while start < copies.count {
            let slice = Array(copies[start..<min(start + batch, copies.count)])
            let hashed = run(["hash-object", "--no-filters", "-w", "--"] + slice.map(\.copy))
            let objects = hashed.output.split(whereSeparator: \.isNewline).map(String.init)
            guard hashed.ok, objects.count == slice.count else { return .failure(failed("hash-object", hashed)) }
            for (item, object) in zip(slice, objects) { entries[item.path] = "\(item.mode) \(object)" }
            start += batch
        }
        let ordered = entries.sorted { $0.key < $1.key }
        start = 0
        while start < ordered.count {
            let slice = ordered[start..<min(start + batch, ordered.count)]
            let staged = run(["update-index", "--add"] + slice.flatMap { ["--cacheinfo", $0.value.replacingOccurrences(of: " ", with: ",") + ",\($0.key)"] })
            guard staged.ok else { return .failure(failed("update-index", staged)) }
            start += batch
        }
        let listed = run(["ls-files", "-s", "-z"])
        guard listed.ok else { return .failure(failed("ls-files", listed)) }
        var inIndex: [String: String] = [:]
        for record in listed.output.split(separator: "\0") {
            let parts = record.split(separator: "\t", maxSplits: 1)
            let head = parts.first?.split(separator: " ") ?? []
            guard parts.count == 2, head.count == 3 else { return .failure(Refusal("the index read back isn't one git writes")) }
            inIndex[String(parts[1])] = "\(head[0]) \(head[1])"
        }
        guard inIndex == entries, Set(entries.keys) == Set(plan.files) else { return .failure(Refusal("the index read back isn't what was hashed")) }
        let tree = run(["write-tree"])
        guard tree.ok, !tree.trimmed.isEmpty else { return .failure(failed("write-tree", tree)) }
        let identity = ["GIT_AUTHOR_NAME": plan.identity.name, "GIT_AUTHOR_EMAIL": plan.identity.email,
                        "GIT_COMMITTER_NAME": plan.identity.name, "GIT_COMMITTER_EMAIL": plan.identity.email]
        let commit = run(["commit-tree", tree.trimmed, "-m", ProjectCreation.commitMessage], adding: identity)
        guard commit.ok, !commit.trimmed.isEmpty else { return .failure(failed("commit-tree", commit)) }
        let moved = run(["update-ref", "--create-reflog", "-m", "commit (initial): " + ProjectCreation.commitMessage, "refs/heads/\(plan.branch)", commit.trimmed, ""],
                        adding: identity)
        guard moved.ok else { return .failure(failed("update-ref", moved)) }
        for (key, value) in [("core.bare", "false"), ("core.logallrefupdates", "true")] {
            let set = git(["config", "--file", gitDir + "/config", key, value], in: probe.path, home: home, scratch: probe)
            guard set.ok else { return .failure(failed("config", set)) }
        }
        do {
            try VibePaths.ensurePrivate(URL(fileURLWithPath: gitDir + "/info"))
            let lines = plan.leftOut.map { "/" + escapedPattern($0) + "\n" }.joined()
            try VibePaths.writePrivate(Data(lines.utf8), to: URL(fileURLWithPath: gitDir + "/info/exclude"))
            try FileManager.default.copyItem(atPath: index, toPath: gitDir + "/index")
        } catch {
            return .failure(Refusal("the repository's files couldn't be made: \(error.localizedDescription)"))
        }
        return .success((gitDir, Made(files: plan.files, commit: commit.trimmed)))
    }

    /// Installs the private git folder `gitDir` as the folder's `.git` through its descriptor `directory`: `.git` made
    /// with `mkdirat` (refused when anything is there), kept open, each folder below made and opened `O_NOFOLLOW` from
    /// its parent's descriptor, each file made new (`O_CREAT|O_EXCL|O_NOFOLLOW`) and written; then `.gitignore` the
    /// same way; `.git` checked to be the folder made. Why not, after removing what was made, or nil.
    static func install(_ gitDir: String, plan: Plan, into directory: Int32) -> Refusal? {
        guard mkdirat(directory, ".git", 0o755) == 0 else {
            return Refusal(errno == EEXIST ? "\(ConfigSeal.inert(plan.folder, limit: 400)) has a .git now: nothing was made"
                                           : ".git couldn't be made (errno \(errno)): nothing was made")
        }
        let git = openat(directory, ".git", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var made = stat()
        guard git >= 0, fstat(git, &made) == 0 else {
            // Something replaced the folder just made: it isn't ours to remove.
            return Refusal(".git changed as it was made: look at the folder; nothing of the repository was written")
        }
        defer { close(git) }
        func undo(_ refusal: Refusal) -> Refusal {
            Descriptors.removeContents(of: git)
            var now = stat()
            if fstatat(directory, ".git", &now, AT_SYMLINK_NOFOLLOW) == 0, now.st_ino == made.st_ino, now.st_dev == made.st_dev {
                unlinkat(directory, ".git", AT_REMOVEDIR)
            }
            return refusal
        }
        if let why = Descriptors.copy(from: gitDir, into: git) { return undo(Refusal(why)) }
        var now = stat()
        guard fstatat(directory, ".git", &now, AT_SYMLINK_NOFOLLOW) == 0, now.st_ino == made.st_ino, now.st_dev == made.st_dev else {
            return undo(Refusal(".git changed while the repository was written: nothing was left"))
        }
        if plan.addsGitignore {
            guard Descriptors.create(directory, ".gitignore", Data(gitignore.utf8), mode: 0o644) else {
                return undo(Refusal("the .gitignore couldn't be made in \(ConfigSeal.inert(plan.folder, limit: 400)) (it came meanwhile, or errno \(errno)): nothing was left"))
            }
        }
        return nil
    }

    /// Writing and removing relative to descriptors, never through a link.
    enum Descriptors {
        static func create(_ directory: Int32, _ name: String, _ data: Data, mode: mode_t) -> Bool {
            let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
        }

        /// Copies the private folder `source`'s contents into the folder `target` is open on: folders with `mkdirat` and
        /// opened `O_NOFOLLOW`, files made new; anything else in `source` refuses. Why not, or nil.
        static func copy(from source: String, into target: Int32) -> String? {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: source) else { return "the private repository couldn't be read" }
            for name in names.sorted() {
                let path = (source as NSString).appendingPathComponent(name)
                var info = stat()
                guard lstat(path, &info) == 0 else { return "the private repository couldn't be read" }
                let mode = info.st_mode & 0o777
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    guard mkdirat(target, name, mode | 0o700) == 0 else { return ".git's \(name) couldn't be made (errno \(errno))" }
                    let sub = openat(target, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard sub >= 0 else { return ".git's \(name) changed as it was made" }
                    defer { close(sub) }
                    if let why = copy(from: path, into: sub) { return why }
                case S_IFREG:
                    guard let data = FileManager.default.contents(atPath: path) else { return "the private repository couldn't be read" }
                    guard create(target, name, data, mode: mode | 0o400) else { return ".git's \(name) couldn't be written (errno \(errno))" }
                default:
                    return "the private repository holds something that isn't a file or a folder"
                }
            }
            return nil
        }

        /// Removes everything in the folder `directory` is open on, through descriptors (a link is removed, never followed).
        static func removeContents(of directory: Int32) {
            let listing = dup(directory)
            guard listing >= 0, let stream = fdopendir(listing) else { return }
            defer { closedir(stream) }
            var names: [String] = []
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
                }
                if name != ".", name != ".." { names.append(name) }
            }
            for name in names {
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let sub = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if sub >= 0 { removeContents(of: sub); close(sub) }
                    unlinkat(directory, name, AT_REMOVEDIR)
                } else {
                    unlinkat(directory, name, 0)
                }
            }
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
