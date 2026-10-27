import Foundation

/// A folder you chose for a project that isn't in a git repository: made one so its lead can start, with a first
/// commit of its files (workers start from commits). A repository with no commits yet gets the same first commit,
/// without the git init. `plan` says what would be committed and touches nothing; `make` does it, or leaves the folder
/// as it was. The commit stays on this Mac: nothing is pushed.
public enum FolderRepository {
    /// File names that look like secrets: never committed here.
    public static let secretNames = [".env", ".env.*", "*.pem", "*.key", "id_rsa*", "id_ed25519*", "id_ecdsa*", "*.p12"]
    /// What a build or the Mac leaves behind.
    public static let buildNames = [".DS_Store", "node_modules/", ".build/", "build/", "dist/", "target/", ".venv/", "__pycache__/"]

    /// The .gitignore written when the folder has none.
    public static var gitignore: String { (secretNames + buildNames).joined(separator: "\n") + "\n" }

    /// Whether a file's name (the last part of `path`) looks like a secret.
    public static func looksSecret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return secretNames.contains { fnmatch($0, name, 0) == 0 }
    }

    public struct Plan: Equatable, Sendable {
        /// The folder made a repository.
        public var folder: String
        /// It has no .gitignore: `gitignore` is written (and committed).
        public var addsGitignore: Bool
        /// What the first commit holds, relative to `folder` (the new .gitignore included).
        public var files: [String]
        /// What's left out as it looks like a secret: kept out of later commits too (.git/info/exclude).
        public var leftOut: [String]
        /// Folders holding a repository of their own: committed as a reference to it, without their files.
        public var nested: [String] = []
        /// `folder` is already a repository, with no commits yet: no git init, and what's staged is committed too.
        public var inRepository = false
    }

    /// What `make` would commit in `folder`. Lists it with a git directory of its own in `scratch` (removed after),
    /// so the folder isn't touched; a repository's top folder (one with a .git, and no commits yet) is listed with its
    /// own, which `ls-files` only reads. Runs git: call off the main thread.
    public static func plan(for folder: String, scratch: URL, git: ProjectCreation.GitRunner = { Git.run($0, in: $1) })
        -> Result<Plan, ProjectCreation.Problem> {
        guard ProjectCreation.existing(folder) == .folder else { return .failure(.failed("\(ProjectCreation.tildePath(folder)) isn't a folder.")) }
        let probe = scratch.appendingPathComponent("probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        let gitignorePath = (folder as NSString).appendingPathComponent(".gitignore")
        let addsGitignore = ProjectCreation.existing(gitignorePath) == .none
        let ours = probe.appendingPathComponent("gitignore")
        do {
            try VibePaths.ensurePrivate(probe)
            try VibePaths.writePrivate(Data(gitignore.utf8), to: ours)
        } catch {
            return .failure(.failed("The folder's files couldn't be listed: \(error.localizedDescription)"))
        }
        let inRepository = ProjectCreation.existing((folder as NSString).appendingPathComponent(".git")) != .none
        var listing: [String]
        if inRepository {
            // Its own excludes (.git/info/exclude) count, and what's already staged is committed too.
            listing = ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        } else {
            let gitDir = probe.appendingPathComponent("git").path
            let made = git(["init", "--quiet", "--bare", gitDir], folder)
            guard made.ok else { return .failure(failed("init", made)) }
            listing = ["--git-dir=\(gitDir)", "--work-tree=\(folder)", "ls-files", "-z", "--others", "--exclude-standard"]
        }
        // The .gitignore that will be there, as if it were: root-relative patterns, like .git/info/exclude.
        if addsGitignore { listing.append("--exclude-from=\(ours.path)") }
        let listed = git(listing, folder)
        guard listed.ok else { return .failure(failed("ls-files", listed)) }
        let all = Set(listed.output.split(separator: "\0").map(String.init)).sorted()
        var files = all.filter { !looksSecret($0) }
        if addsGitignore, !files.contains(".gitignore") { files.append(".gitignore") }
        // git lists a folder holding a repository of its own as "name/", and doesn't look inside it.
        let nested = all.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }
        return .success(Plan(folder: folder, addsGitignore: addsGitignore, files: files.sorted(),
                             leftOut: all.filter(looksSecret).sorted(), nested: nested.sorted(), inRepository: inRepository))
    }

    /// git init (on the default branch) in `plan.folder`, its .gitignore if it had none, and a first commit of all its
    /// files but the ones left out. When a step fails, what this made (.git, the .gitignore) is removed. In a repository
    /// with no commits yet (`plan.inRepository`) there's no git init, and a failed step puts its index and
    /// .git/info/exclude back as they were instead. Runs git and writes files: call off the main thread.
    public static func make(_ plan: Plan, git: ProjectCreation.GitRunner = { Git.run($0, in: $1) }) -> ProjectCreation.Problem? {
        let folder = plan.folder
        let dotGit = (folder as NSString).appendingPathComponent(".git")
        let gitignorePath = (folder as NSString).appendingPathComponent(".gitignore")
        var wroteGitignore = false
        /// In a repository: its index and exclude file, and what they held before (nil: missing).
        var kept: [(path: URL, data: Data?)] = []
        var exclude = URL(fileURLWithPath: dotGit).appendingPathComponent("info/exclude")
        if plan.inRepository {
            guard ProjectCreation.existing(dotGit) != .none else { return .failed("\(ProjectCreation.tildePath(folder)) has no .git.") }
            guard isEmptyRepository(folder, git: git) else {
                return .failed("\(ProjectCreation.tildePath(folder)) has a commit already.")
            }
            // .git can be a file naming the git directory (a worktree's, a submodule's): git says where they are.
            var paths: [URL] = []
            for name in ["index", "info/exclude"] {
                let found = git(["rev-parse", "--git-path", name], folder)
                let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard found.ok, !path.isEmpty else { return failed("rev-parse", found) }
                paths.append(URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: folder, isDirectory: true)).standardizedFileURL)
            }
            exclude = paths[1]
            kept = paths.map { ($0, try? Data(contentsOf: $0)) }
        } else {
            guard ProjectCreation.existing(dotGit) == .none else { return .failed("\(ProjectCreation.tildePath(folder)) already has a .git.") }
        }
        func undo(_ problem: ProjectCreation.Problem) -> ProjectCreation.Problem {
            if plan.inRepository {
                for (path, data) in kept {
                    if let data { try? data.write(to: path) } else { try? FileManager.default.removeItem(at: path) }
                }
            } else {
                try? FileManager.default.removeItem(atPath: dotGit)
            }
            if wroteGitignore { try? FileManager.default.removeItem(atPath: gitignorePath) }
            return problem
        }
        if plan.addsGitignore {
            // Only if it's still missing: one that came meanwhile is the folder's own, and stays as it is.
            if ProjectCreation.existing(gitignorePath) == .none {
                guard FileManager.default.createFile(atPath: gitignorePath, contents: Data(gitignore.utf8)) else {
                    return .failed("The .gitignore couldn't be written in \(ProjectCreation.tildePath(folder)).")
                }
                wroteGitignore = true
            }
        }
        if !plan.inRepository {
            let branch = ProjectCreation.branch(fromConfig: git(["config", "--get", "init.defaultBranch"], folder))
            let initialized = git(["init", "--quiet", "--initial-branch=\(branch)"], folder)
            guard initialized.ok else { return undo(failed("init", initialized)) }
        }
        let added = git(["add", "-A"], folder)
        guard added.ok else { return undo(failed("add", added)) }
        // What's staged, looked at again: a secret-named file that came since the plan, or one the folder's .gitignore
        // un-ignores (`!.env`, which no exclude overrides), is taken out of the index before the commit.
        let staged = git(["ls-files", "-z"], folder)
        guard staged.ok else { return undo(failed("ls-files", staged)) }
        let secrets = staged.output.split(separator: "\0").map(String.init).filter(looksSecret)
        if !secrets.isEmpty {
            // -f: git refuses an entry that differs from both HEAD and the file (a repository of its own named like a
            // secret, a file rewritten since the add) otherwise. It only takes it out of the index; the file stays.
            let removed = git(["rm", "--cached", "-f", "--quiet", "--ignore-unmatch", "--"] + secrets.map { ":(literal)\($0)" }, folder)
            guard removed.ok else { return undo(failed("rm --cached", removed)) }
            let check = git(["ls-files", "-z"], folder)
            guard check.ok else { return undo(failed("ls-files", check)) }
            if let still = check.output.split(separator: "\0").map(String.init).first(where: looksSecret) {
                return undo(.failed("\(still) looks like a secret and couldn't be kept out of the first commit."))
            }
        }
        let leftOut = Set(plan.leftOut).union(secrets).sorted()
        if !leftOut.isEmpty {
            // Kept out of later commits too (a worker's `git add -A`), without changing the folder's own files.
            do {
                try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
                let lines = leftOut.map { "/" + escapedPattern($0) }.joined(separator: "\n") + "\n"
                var existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
                // One edited without a last newline: its last pattern isn't run into the first of these.
                if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
                try Data((existing + lines).utf8).write(to: exclude)
            } catch {
                return undo(.failed("The files left out couldn't be noted in .git/info/exclude: \(error.localizedDescription)"))
            }
        }
        let committed = git(["commit", "--quiet", "--allow-empty", "-m", ProjectCreation.commitMessage], folder)
        guard committed.ok else { return undo(failed("commit", committed)) }
        return nil
    }

    /// A repository with no commits at all: HEAD unborn and no refs. An orphan branch (`git checkout --orphan`) or a
    /// fetch with nothing checked out has commits elsewhere: no first commit is made there.
    public static func isEmptyRepository(_ folder: String, git: ProjectCreation.GitRunner = { Git.run($0, in: $1) }) -> Bool {
        guard !git(["rev-parse", "--verify", "--quiet", "HEAD"], folder).ok else { return false }
        let refs = git(["for-each-ref", "--count=1"], folder)
        return refs.ok && refs.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private static func failed(_ step: String, _ result: Git.Result) -> ProjectCreation.Problem {
        let said = [result.error, result.output].first { !$0.isEmpty } ?? "it exited with status \(result.status)."
        return .failed("git \(step) failed: \(said)")
    }
}
