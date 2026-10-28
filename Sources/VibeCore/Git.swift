import CryptoKit
import Foundation

/// Runs git (never through a shell, never prompting for credentials), with what the repository's own git folder could
/// make it run kept out (`GitGuard`).
public enum Git {
    public struct Result: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public var error: String
        /// It ran past its time limit and was stopped.
        public var timedOut = false
        /// The work it ran for was cancelled (see `ShellCancel`), and it was stopped.
        public var cancelled = false
        public var ok: Bool { status == 0 && !timedOut && !cancelled }
    }

    /// What git runs with here: never prompting for credentials, and without the optional locks: `git status` and the
    /// like don't take index.lock to save what they refreshed. Killed while they held it (SIGKILL; they remove it on
    /// TERM) they would leave it, and every git that changes that index refuses until someone removes it.
    public static let environment = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]

    /// A run that was stopped (out of time, or cancelled) gives no output, only `error` saying so: its callers take
    /// `output` as git's answer, and what it wrote until then isn't one (a shell it ran may even answer after its
    /// time is up, and exit 0). `env` adds to `environment` (a commit's identity and dates, say). It runs guarded
    /// (`GitGuard.command`): only the hooks the lead accepted, and none of the repository's own executable config; in
    /// a repository whose config includes another file it doesn't run, and `error` says why.
    @discardableResult
    public static func run(_ args: [String], in directory: String, env: [String: String] = [:], timeout: TimeInterval = 120,
                           grace: TimeInterval = 5) -> Result {
        let guarded = GitGuard.command(args, in: directory, env: env)
        if let refused = guarded.refused { return Result(status: 128, output: "", error: refused) }
        var result = Shell.run(executable: "/usr/bin/git", args: guarded.args, in: directory,
                               env: environment.merging(guarded.env) { $1 }.merging(env) { $1 }, timeout: timeout, grace: grace)
        if result.timedOut || result.cancelled {
            result.output = ""
            let stopped = result.cancelled ? "git was stopped: cancelled." : "git was stopped: it ran past \(Worktrees.duration(timeout))."
            result.error = result.error.isEmpty ? stopped : stopped + "\n" + result.error
        }
        return result
    }
}

/// What a worker, or its branch's code, can write into the repository's shared git folder never runs as the lead's
/// tool server: since auto_advance, its git runs unattended (merges' fast-forwards, update-ref, cleanups, start_worker's
/// `worktree add`), and a worktree shares `<common-dir>` with the main checkout. So every `Git.run`:
/// - takes its hooks from a copy the lead accepted (`accept`), kept in VibeSwitcher's private folder, never from the
///   repository's hooks folder: a hook planted there (post-merge, reference-transaction, post-checkout…) doesn't run.
///   The hooks a repository has when the guard first sees it are the baseline, accepted then (`baseline`), so the
///   user's own keep running (project-c's commit-msg) and the lead is told once which; a later change there runs only
///   once the lead accepts it, and is told to the lead (`notice`) until it does.
/// - runs without the fsmonitor, without any transport (`protocol.allow=never`: no lazy fetch, so no credential helper
///   or ssh command), with diff's external drivers and textconv off (`--no-ext-diff --no-textconv`), and without a git
///   of its own in any submodule (`submodule.recurse=false`, `--ignore-submodules=dirty`).
/// - takes the executable keys the repository's own config sets (`.git/config`, a worktree's config.worktree: filter
///   drivers, merge drivers, gpg programs, pagers, editors, ssh commands) from the user's global or system config, or as
///   a neutral value when they have none (`neutral`). Told to the lead too.
/// - doesn't run at all in a repository whose own config includes another file (`include.path`, `includeIf.*.path`):
///   what that one sets isn't checked, so the lead is told which file and key until it's gone (`refusal`).
public enum GitGuard {
    /// `args` as git runs them here, and what its environment adds to `env` (the call's own); or, instead, why git
    /// doesn't run here (`refusal`).
    static func command(_ args: [String], in directory: String, env given: [String: String] = [:])
        -> (args: [String], env: [String: String], refused: String?) {
        let place = place(of: directory)
        if case let .unsure(folder) = place { return (args, [:], unsure(folder)) }
        let dirs = place.dirs
        let config = dirs.map { repositoryConfig(common: $0.common, env: given) } ?? (keys: [], includes: [])
        if let refused = refusal(config.includes) { return (args, [:], refused) }
        if let dirs { baseline(in: directory, commonDir: dirs.common) }
        let hooks = dirs.map { hooksCopy(commonDir: $0.common).path } ?? "/dev/null"
        var front = ["-c", "core.hooksPath=\(hooks)", "-c", "core.fsmonitor=false", "-c", "protocol.allow=never",
                     "-c", "submodule.recurse=false"]
        // Diff's drivers, from the repository's attributes and config, run only for a patch: never here. Nor a git in
        // each submodule, to see whether its files changed: that one reads the submodule's own config (`.git/modules/`,
        // as writable as the rest), whose filters nothing here overrides. A submodule's new commits still show; the
        // flag, unlike the config, holds over a `submodule.<name>.ignore` the repository's config sets.
        var rest = args
        if let first = args.first, ["diff", "log", "show"].contains(first) { rest.insert(contentsOf: ["--no-ext-diff", "--no-textconv"], at: 1) }
        if let first = args.first, ["diff", "status"].contains(first) { rest.insert("--ignore-submodules=dirty", at: 1) }
        front += rest
        // As the environment's pairs, not `-c`: a key's subsection may hold "=", which `-c` would split at.
        var env: [String: String] = [:]
        let overridden = overrides(config.keys, in: directory, env: given)
        if !overridden.isEmpty {
            env["GIT_CONFIG_COUNT"] = "\(overridden.count)"
            for (index, pair) in overridden.enumerated() {
                env["GIT_CONFIG_KEY_\(index)"] = pair.key
                env["GIT_CONFIG_VALUE_\(index)"] = pair.value
            }
        }
        return (front, env, nil)
    }

    // MARK: The repository

    /// Where `directory` is, as git finds its repository: outside any, in a checkout (its git folder, a worktree's own
    /// under `<common>/worktrees/`, and the common one), or in a folder the guard can't vouch is the one git takes.
    enum Place: Equatable {
        case outside
        case checkout(git: String, common: String)
        case unsure(String)

        var dirs: (git: String, common: String)? {
            if case let .checkout(git, common) = self { return (git, common) }
            return nil
        }
    }

    /// Where `directory` is, read from the files (no git process), up from it as git looks: at each folder, a `.git`
    /// (a worktree's file, or a folder), else the folder itself as a bare repository. Git walks past a `.git` folder
    /// that isn't a repository, and takes any folder that is one as a bare repository with its own config: what a
    /// worker can make of its worktree (an empty `.git`, a HEAD, objects and refs at its top), so that the guard
    /// checks one repository's config and git runs another's. So a `.git` folder is taken only when git would take it
    /// too (`isRepository`), and either of those is `unsure`, where git doesn't run.
    static func place(of directory: String) -> Place {
        let fileManager = FileManager.default
        var folder = URL(fileURLWithPath: directory).standardizedFileURL.path
        while true {
            let dotGit = (folder as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                // A `.git` file git can't follow, git refuses: so does the guard.
                guard let git = isDirectory.boolValue ? dotGit : linked(dotGit, in: folder) else { return .unsure(dotGit) }
                let common = commonDir(of: git)
                if isDirectory.boolValue, !isRepository(git, common: common) { return .unsure(dotGit) }
                return .checkout(git: resolved(git), common: resolved(common))
            }
            if mayBeRepository(folder) { return .unsure(folder) }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return .outside }
            folder = parent
        }
    }

    /// The git folder of the checkout holding `directory`, and the common one (`place`). Nil outside one.
    static func gitDirs(of directory: String) -> (git: String, common: String)? { place(of: directory).dirs }

    /// A git folder's common one: its `commondir`, relative to it, else itself.
    private static func commonDir(of git: String) -> String {
        guard let text = try? String(contentsOfFile: (git as NSString).appendingPathComponent("commondir"), encoding: .utf8) else { return git }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : (git as NSString).appendingPathComponent(path)
    }

    /// Whether git takes `git` as a repository (its `is_git_directory`), held at least as strictly: a HEAD that is a
    /// link into refs/, a `ref: refs/…` or an object id, and the common folder's objects and refs folders.
    static func isRepository(_ git: String, common: String) -> Bool {
        let fileManager = FileManager.default
        let head = (git as NSString).appendingPathComponent("HEAD")
        guard let kind = (try? fileManager.attributesOfItem(atPath: head))?[.type] as? FileAttributeType else { return false }
        if kind == .typeSymbolicLink {
            guard (try? fileManager.destinationOfSymbolicLink(atPath: head))?.hasPrefix("refs/") == true else { return false }
        } else {
            guard kind == .typeRegular, let data = fileManager.contents(atPath: head), let text = String(data: data, encoding: .utf8) else { return false }
            let ref = text.hasPrefix("ref:") && text.dropFirst(4).drop(while: \.isWhitespace).hasPrefix("refs/")
            let id = text.count >= 40 && text.prefix(40).allSatisfy(\.isHexDigit)
            guard ref || id else { return false }
        }
        return ["objects", "refs"].allSatisfy { name in
            let path = (common as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue && fileManager.isExecutableFile(atPath: path)
        }
    }

    /// Whether git might take `folder` itself as a repository, held loosely: any HEAD, with objects and refs or a
    /// commondir beside it.
    static func mayBeRepository(_ folder: String) -> Bool {
        let has = { (name: String) in FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) }
        return has("HEAD") && (has("objects") && has("refs") || has("commondir"))
    }

    /// Why git doesn't run where the guard can't vouch for the repository git would take (`place`).
    static func unsure(_ folder: String) -> String {
        "VibeSwitcher's guarded git doesn't run here: \(folder) isn't a repository it can vouch is the one git would take "
            + "(a .git folder that isn't one, which git walks past, or a folder that looks like a bare repository), so the config "
            + "it checks might not be the config git runs. A worker or its branch's code can make one in its worktree. "
            + "Only the user should repair or remove it, once they've looked at what's there."
    }

    /// A worktree's `.git` file: `gitdir: <path>`, relative to the folder holding it.
    private static func linked(_ file: String, in folder: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? path : (folder as NSString).appendingPathComponent(path)
    }

    private static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    /// `path` as the file system spells it (`/private/tmp`, not `/tmp`, unlike `resolved`): paths from git and ours compare.
    static func real(_ path: String) -> String {
        guard let found = realpath(path, nil) else { return path }
        defer { free(found) }
        return String(cString: found)
    }

    // MARK: Executable config

    /// The config keys that name a program git runs (or, for `protocol.*.allow`, a transport it may use), as
    /// `git config --get-regexp` spells them: section and key lowercased, the subsection as written.
    static let executableKeys = #"^(core\.(sshcommand|pager|editor|askpass)|sequence\.editor|diff\.external|gpg\.program|gpg\..+\.(program|defaultkeycommand)|pager\..+|filter\..+\.(clean|smudge|process|required)|diff\..+\.(textconv|command)|merge\..+\.driver|protocol\..+\.allow)$"#

    /// Words one of `executableKeys` holds, one of which a config file that sets one (or includes another) must hold.
    private static let executableWords = ["include", "sshcommand", "pager", "editor", "askpass", "external", "program",
                                          "defaultkeycommand", "clean", "smudge", "process", "required", "textconv",
                                          "command", "driver", "allow"]

    /// A key the repository's own config sets, as one with no global or system value of its own runs: nothing of the
    /// repository's. A filter passes the file through as it is; a merge driver is git's own three-way merge.
    static func neutral(_ key: String) -> String {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let (section, name) = (parts.first ?? "", parts.last ?? "")
        switch (section, name) {
        case ("core", "sshcommand"): return "ssh"
        case ("core", "pager"): return "cat"
        case ("core", "editor"), ("sequence", "editor"): return "true"
        case ("pager", _): return "false"
        case ("filter", "required"): return "false"
        case ("filter", _), ("core", "askpass"), ("diff", _): return ""
        case ("merge", "driver"): return "git merge-file --marker-size=%L %A %O %B"
        case ("protocol", _): return "never"
        case ("gpg", "program") where parts.count == 2: return "gpg"
        case ("gpg", "program"):
            return ["openpgp": "gpg", "x509": "gpgsm", "ssh": "ssh-keygen"][parts.dropFirst().dropLast().joined(separator: ".")] ?? "false"
        default: return "false"
        }
    }

    /// The repository's own config files: its config, and every worktree's config.worktree (a git
    /// that one of the lead's calls starts in another worktree, such as `worktree remove`'s status or `worktree add`'s
    /// checkout, reads that worktree's own).
    static func repositoryFiles(common: String) -> [String] {
        let worktrees = (common as NSString).appendingPathComponent("worktrees")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: worktrees)) ?? []).sorted()
        return [(common as NSString).appendingPathComponent("config"), (common as NSString).appendingPathComponent("config.worktree")]
            + names.map { ((worktrees as NSString).appendingPathComponent($0) as NSString).appendingPathComponent("config.worktree") }
    }

    /// An executable key as git reads it in a checkout: the scope it comes from, its name and its value.
    struct Entry: Equatable {
        var scope: String
        var key: String
        var value: String
    }

    /// The executable keys git reads in `directory` with `env`, from every scope (includes followed). Asked of git as it
    /// is, with nothing guarded: `git config` runs no hooks, filters or programs.
    static func executableEntries(in directory: String, env: [String: String] = [:]) -> [Entry] {
        let listed = Shell.run(executable: "/usr/bin/git", args: ["config", "--show-scope", "-z", "--get-regexp", executableKeys],
                               in: directory, env: Git.environment.merging(env) { $1 }, timeout: 30, grace: 1)
        guard listed.status == 0 else { return [] }
        // "<scope>\0<key>\n<value>\0", the value and its newline missing for a key without one.
        let fields = listed.output.components(separatedBy: "\0")
        var entries: [Entry] = []
        var index = 0
        while index + 1 < fields.count {
            let pair = fields[index + 1]
            let key = pair.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? pair
            let value = pair.count > key.count ? String(pair.dropFirst(key.count + 1)) : ""
            entries.append(Entry(scope: fields[index], key: key, value: value))
            index += 2
        }
        return entries
    }

    /// A config file's executable keys and include paths, as written (its includes not followed), with `env`.
    static func fileEntries(_ file: String, env: [String: String]) -> [(key: String, value: String)] {
        let inner = executableKeys.dropFirst(2).dropLast(2)
        let pattern = "^(\(inner)|include\\.path|includeif\\..+\\.path)$"
        let listed = Shell.run(executable: "/usr/bin/git", args: ["config", "--file", file, "--no-includes", "-z", "--get-regexp", pattern],
                               in: (file as NSString).deletingLastPathComponent, env: Git.environment.merging(env) { $1 }, timeout: 30, grace: 1)
        guard listed.status == 0 else { return [] }
        return listed.output.components(separatedBy: "\0").filter { !$0.isEmpty }.map { pair in
            let key = pair.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? pair
            return (key, pair.count > key.count ? String(pair.dropFirst(key.count + 1)) : "")
        }
    }

    /// An include in one of the repository's own config files: the file, the key (`include.path`, `includeif.<condition>.path`)
    /// and the path it names.
    struct Include: Equatable {
        var file: String
        var key: String
        var path: String
    }

    /// What the repository's own config files (`repositoryFiles`) set: each executable key, and each include. Only a
    /// file that holds one of `executableWords` (an include holds "include"), or can't be read, is asked of git: most
    /// repositories have none, and then no git runs.
    static func repositoryConfig(common: String, env: [String: String] = [:]) -> (keys: [String], includes: [Include]) {
        var keys: [String] = [], includes: [Include] = []
        for file in repositoryFiles(common: common) where FileManager.default.fileExists(atPath: file) {
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                let lower = text.lowercased()
                guard executableWords.contains(where: { lower.contains($0) }) else { continue }
            }
            for (key, value) in fileEntries(file, env: env) {
                if key == "include.path" || (key.hasPrefix("includeif.") && key.hasSuffix(".path")) {
                    includes.append(Include(file: file, key: key, path: value))
                } else if !keys.contains(key) {
                    keys.append(key)
                }
            }
        }
        return (keys, includes)
    }

    /// Why git doesn't run in a repository whose own config includes another file: what that file sets (a filter, a
    /// hooks folder) isn't checked, and following includes as git does (`~user/`, `gitdir:` patterns, relative paths)
    /// isn't something to get almost right. Nil without includes. None of the user's repositories uses one.
    static func refusal(_ includes: [Include]) -> String? {
        guard !includes.isEmpty else { return nil }
        let listed = includes.map { "\($0.file) sets \($0.key) = \($0.path)" }
        return "VibeSwitcher's guarded git doesn't run in this repository: its own config includes another file (\(listed.joined(separator: "; "))), "
            + "and what an included file sets (a filter, a hooks folder) isn't checked. A worker or its branch's code can write there. "
            + "Only the user should remove it (git config --file <that file> --unset <that key>), once they've read what it includes; "
            + "until then the tool server runs no git here (no merge, cleanup, start_worker or auto_advance)."
    }

    /// Each executable key the repository's own config sets (`keys`, from `repositoryConfig`), with the value git takes
    /// instead: the user's own (the last global or system one), else `neutral`.
    static func overrides(_ keys: [String], in directory: String, env: [String: String]) -> [(key: String, value: String)] {
        guard !keys.isEmpty else { return [] }
        let user = executableEntries(in: directory, env: env).filter { ["system", "global"].contains($0.scope) }
        return keys.map { key in (key, user.last { $0.key == key }?.value ?? neutral(key)) }
    }

    // MARK: Hooks

    /// Where VibeSwitcher keeps what the lead accepted for the repository whose common git folder is `commonDir`:
    /// in its private folder, which no role's tools read or edit (`LeadLaunch.privateFiles`).
    static func store(commonDir: String) -> URL {
        let key = SHA256.hash(data: Data(commonDir.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return VibePaths.root.appendingPathComponent("lead/git-hooks/\(key)", isDirectory: true)
    }

    /// The accepted copy, replaced whole at each accept: `hooks`, which git takes its hooks from (core.hooksPath), a
    /// shim per hook (`shim`), and beside it `run`, the accepted files themselves, subfolders and all, which the shims
    /// run. Siblings, so a hook that looks in the folder above its own (husky's `h` finds `../<hook>`) never lands on a
    /// shim, which would run it again, and again.
    static func copy(commonDir: String) -> URL { store(commonDir: commonDir).appendingPathComponent("copy", isDirectory: true) }

    /// Where git takes its hooks from (core.hooksPath); none there until the lead accepts some.
    static func hooksCopy(commonDir: String) -> URL { copy(commonDir: commonDir).appendingPathComponent("hooks", isDirectory: true) }

    /// The accepted files the shims in `hooksCopy` run.
    static func runCopy(commonDir: String) -> URL { copy(commonDir: commonDir).appendingPathComponent("run", isDirectory: true) }

    /// A file in a hooks folder, by its path there (`_/husky.sh`): git runs one at the top as a hook when it's named
    /// after one and executable; others are what those may read (a sibling script). `.sample`s never run.
    struct HookFile: Codable, Equatable {
        var name: String
        var sha256: String
        var executable: Bool
        var short: String { String(sha256.prefix(8)) }
    }

    /// What the lead accepted: the hooks folder git used then, and what was in it (all of it, run or not).
    struct Accepted: Codable, Equatable {
        var folder: String
        var files: [HookFile]
        var run: [String]
        /// Taken by the guard when it first saw the repository (`baseline`), not by the lead; `told` once the lead heard.
        var baseline: Bool?
        var told: Bool?
    }

    /// Trust on first use: a repository the guard has nothing accepted for yet gets the hooks it has now as its
    /// baseline, before git runs, so the user's own hooks keep running in the lead's git. Told to the lead once (`notice`).
    /// One that fails (a hook changing as it's copied) is tried again at the next call, git meanwhile running no hooks.
    static func baseline(in directory: String, commonDir: String) {
        guard !FileManager.default.fileExists(atPath: store(commonDir: commonDir).appendingPathComponent("accepted.json").path) else { return }
        _ = try? accept(root: directory, baseline: true)
    }

    /// The hook git runs in place of the accepted copy at `hook`: that copy, as branch code (`BranchCode`), never the
    /// lead. Under the marked wrapper, in a POSIX session of its own with no terminal, holding no descriptor but its
    /// standard three: the host gives nothing below the wrapper a session's standing, and a hook that escapes it can't
    /// reach the lead's terminal. An accepted hook may run what its checkout holds (project-b's call scripts in the
    /// working tree: the branch's, in a merge's), so it never needs the lead's standing. perl forks, starts the session
    /// and closes the rest; without it, the wrapper alone.
    static func shim(running hook: String) -> String {
        let quote = { (word: String) in "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = (BranchCode.wrapper + [hook]).map(quote).joined(separator: " ") + " \"$@\""
        let session = #"use POSIX (); my $pid = fork; defined $pid or die "fork: $!\n"; if (!$pid) { POSIX::setsid(); POSIX::close($_) for 3 .. 255; exec { $ARGV[0] } @ARGV; POSIX::_exit(127); } waitpid($pid, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8);"#
        return "#!/bin/sh\n# VibeSwitcher: the hook the lead accepted, run as branch code (GitGuard.shim).\n"
            + "if [ -x /usr/bin/perl ]; then exec /usr/bin/perl -e \(quote(session)) \(command); fi\n"
            + "exec \(command)\n"
    }

    /// The hooks folder git itself would use at `root` (core.hooksPath from any scope, else `<common>/hooks`).
    static func hooksFolder(root: String) -> String? {
        let asked = Shell.run(executable: "/usr/bin/git", args: ["rev-parse", "--path-format=absolute", "--git-path", "hooks"],
                              in: root, env: Git.environment, timeout: 30, grace: 1)
        return asked.ok && !asked.output.isEmpty ? asked.output : nil
    }

    /// The files in `folder` and its subfolders, by their path there, `.sample`s and dot files left out. A link to a
    /// folder isn't followed.
    static func files(in folder: String) -> [HookFile] {
        let fileManager = FileManager.default
        guard let walk = fileManager.enumerator(atPath: folder) else { return [] }
        var found: [HookFile] = []
        while let name = walk.nextObject() as? String {
            let last = (name as NSString).lastPathComponent
            if last.hasPrefix(".") { walk.skipDescendants(); continue }
            guard !last.hasSuffix(".sample") else { continue }
            let path = (folder as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let data = fileManager.contents(atPath: path) else { continue }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            found.append(HookFile(name: name, sha256: sha, executable: fileManager.isExecutableFile(atPath: path)))
        }
        return found.sorted { $0.name < $1.name }
    }

    static func accepted(commonDir: String) -> Accepted? {
        let file = store(commonDir: commonDir).appendingPathComponent("accepted.json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Accepted.self, from: $0) }
    }

    /// What the lead is told while the repository's hooks or its own executable config aren't what it accepted: what
    /// the tool server's git doesn't run, and how to accept it; or, in a repository whose config includes another file,
    /// that it runs no git there at all (`refusal`). Nil when there's nothing to tell.
    public static func notice(root: String) -> String? {
        let place = place(of: root)
        if case let .unsure(folder) = place { return "Git: " + unsure(folder) }
        guard let dirs = place.dirs else { return nil }
        let config = repositoryConfig(common: dirs.common)
        if let refused = refusal(config.includes) { return "Git config: " + refused }
        // Asked before any git ran here: the hooks it has now are the baseline, not news.
        baseline(in: root, commonDir: dirs.common)
        var parts: [String] = []
        if let folder = hooksFolder(root: root) {
            let now = files(in: folder)
            let before = accepted(commonDir: dirs.common)
            let was = before?.files ?? []
            var changes: [String] = []
            for file in now {
                switch was.first(where: { $0.name == file.name }) {
                case nil: changes.append("\(file.name) (new)")
                case let old? where old != file: changes.append("\(file.name) (changed)")
                default: break
                }
            }
            for old in was where !now.contains(where: { $0.name == old.name }) {
                changes.append("\(old.name) (removed\(before?.run.contains(old.name) == true ? "; its accepted copy still runs" : ""))")
            }
            if let before, before.baseline == true, before.told != true {
                var told = before
                told.told = true
                try? VibePaths.writePrivate(try JSONEncoder().encode(told), to: store(commonDir: dirs.common).appendingPathComponent("accepted.json"))
                if !before.run.isEmpty {
                    let ran = before.files.filter { before.run.contains($0.name) }.map { "\($0.name) (\($0.short))" }
                    let inside = real(before.folder).hasPrefix(real(root) + "/") && !real(before.folder).hasPrefix(real(dirs.common) + "/")
                    parts.append("Git hooks: accepted the existing hooks in \(before.folder) as the baseline, the first time VibeSwitcher's guarded git saw this repository: \(ran.joined(separator: ", ")). The tool server's git runs those, from a copy, as branch code (never as you); a later change there runs only once you accept it (accept_git_hooks). If one isn't the user's own, tell the user."
                        + (inside ? " That folder is inside the working tree (the repository's core.hooksPath): a branch can change it, and what its hooks call from the checkout is the branch's in a merge." : ""))
                }
            }
            if let before, before.folder != folder {
                changes.insert("the folder itself (it was \(before.folder): the repository's config sets core.hooksPath)", at: 0)
            }
            if !changes.isEmpty {
                parts.append("Git hooks: \(folder) isn't as you accepted it: \(changes.joined(separator: ", ")). The tool server's git (merges, cleanups, start_worker, auto_advance) runs only the hooks you accepted, from a copy, never that folder's. A worker or its branch's code can write there: read each one, and only when it's the user's own, accept_git_hooks to run them as they are now (hooks: the names, to run only those).")
            }
        }
        let keys = config.keys.sorted()
        if !keys.isEmpty {
            parts.append("Git config: this repository's own config sets \(keys.joined(separator: ", ")). The tool server's git doesn't run those: it takes the user's global value, or none (a filter passes files through, a merge driver is git's own merge). If one is the user's, it has to be set in their global config to apply to merges.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    public struct Refused: Error, CustomStringConvertible {
        public var description: String
    }

    /// Takes a copy of the repository's hooks, as they are now, for the tool server's git to run (all of them, or
    /// only those named in `only`); the folder as it is now is what `notice` compares with afterwards. What was accepted.
    public static func accept(root: String, only: [String]? = nil, baseline: Bool = false) throws -> String {
        guard let dirs = gitDirs(of: root), let folder = hooksFolder(root: root) else {
            throw Refused(description: "\(root) isn't a git repository.")
        }
        let now = files(in: folder)
        if let only, let unknown = only.first(where: { name in !now.contains { $0.name == name } }) {
            throw Refused(description: "There's no \(unknown) in \(folder) (it has \(now.isEmpty ? "nothing" : now.map(\.name).joined(separator: ", "))).")
        }
        let run = now.filter { only?.contains($0.name) ?? true }
        let store = store(commonDir: dirs.common)
        let fresh = store.appendingPathComponent("copy.\(UUID().uuidString)", isDirectory: true)
        let old = store.appendingPathComponent("old.\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        defer {
            try? fileManager.removeItem(at: fresh)
            try? fileManager.removeItem(at: old)
        }
        do {
            let shims = fresh.appendingPathComponent("hooks", isDirectory: true)
            let copies = fresh.appendingPathComponent("run", isDirectory: true)
            try VibePaths.ensurePrivate(shims)
            try VibePaths.ensurePrivate(copies)
            for file in run {
                // The bytes hashed: a copy of the file as it is now, compared with what was listed.
                guard let data = fileManager.contents(atPath: (folder as NSString).appendingPathComponent(file.name)),
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    throw Refused(description: "\(file.name) changed while it was copied; accept again.")
                }
                let copy = copies.appendingPathComponent(file.name)
                try VibePaths.ensurePrivate(copy.deletingLastPathComponent(), within: copies)
                try VibePaths.writePrivate(data, to: copy)
                try fileManager.setAttributes([.posixPermissions: file.executable ? 0o700 : 0o600], ofItemAtPath: copy.path)
                // What git runs: the copy, as branch code. What it reads sits around it in run, as in the folder.
                guard file.executable, !file.name.contains("/") else { continue }
                let runs = runCopy(commonDir: dirs.common).appendingPathComponent(file.name).path
                let shim = shims.appendingPathComponent(file.name)
                try VibePaths.writePrivate(Data(Self.shim(running: runs).utf8), to: shim)
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
            }
            let current = copy(commonDir: dirs.common)
            if fileManager.fileExists(atPath: current.path) { try fileManager.moveItem(at: current, to: old) }
            try fileManager.moveItem(at: fresh, to: current)
            let record = Accepted(folder: folder, files: now, run: run.map(\.name), baseline: baseline ? true : nil)
            try VibePaths.writePrivate(try JSONEncoder().encode(record), to: store.appendingPathComponent("accepted.json"))
        } catch let refused as Refused {
            throw refused
        } catch {
            throw Refused(description: "The hooks couldn't be copied: \(error.localizedDescription)")
        }
        let ran = run.map { "\($0.name) (\($0.short))" }
        let left = now.filter { file in !run.contains(file) }.map(\.name)
        return (ran.isEmpty ? "The tool server's git runs no hooks in this repository." : "The tool server's git runs these hooks from \(folder), copied as they are now: \(ran.joined(separator: ", ")).")
            + (left.isEmpty ? "" : " Not run: \(left.joined(separator: ", ")).")
            + " A later change there is told to you again, and runs only once you accept it."
    }
}
