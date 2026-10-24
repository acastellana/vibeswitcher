import Foundation

/// Home's New Project…: a folder in the projects folder, with a git repository and a first commit so a lead can start
/// in it at once. `plan` says what would be made (pure); `create` makes it, or leaves nothing behind.
public enum ProjectCreation {
    /// Where projects go when Settings doesn't say: shown and stored as a tilde path.
    public static var defaultLocation: String { "~/dev" }
    public static let commitMessage = "Initial commit"
    public static let gitignore = ".DS_Store\n.build/\n"

    public static func readme(name: String) -> String {
        "# \(name.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// Why a project can't be made; `message` is what the sheet shows.
    public enum Problem: Error, Equatable, Sendable {
        case emptyName
        case noLetters
        case separator
        case leadingDot
        case noLocation
        case locationIsFile(String)
        case exists(folder: String, location: String)
        case isFile(name: String, location: String)
        /// A step failed (git, or writing a file); the text is what it said.
        case failed(String)

        public var message: String {
            switch self {
            case .emptyName: return "Give the project a name."
            case .noLetters: return "A project name needs at least one letter or number."
            case .separator: return "A folder name can't contain “/” or “:”."
            case .leadingDot: return "A folder name can't start with “.”: the folder would be hidden."
            case .noLocation: return "Choose where to put the project."
            case .locationIsFile(let location): return "\(location) is a file, not a folder."
            case .exists(let folder, let location): return "There's already a folder named “\(folder)” in \(location)."
            case .isFile(let name, let location): return "There's already a file named “\(name)” in \(location)."
            case .failed(let text): return text
            }
        }
    }

    /// What's at a path: nothing, a folder, or something else (a file).
    public enum Existing: Equatable, Sendable { case none, folder, file }

    public static func existing(_ path: String) -> Existing {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return .none }
        return isFolder.boolValue ? .folder : .file
    }

    /// The folder name for a project name: trimmed, each run of spaces a hyphen, lowercase ("My App" → "my-app").
    public static func folderName(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
            .lowercased()
    }

    /// The branch `git init` makes: git's init.defaultBranch (`git config --get init.defaultBranch`), else main.
    public static func branch(fromConfig result: Git.Result) -> String {
        let configured = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !configured.isEmpty && !configured.contains(where: \.isWhitespace) ? configured : "main"
    }

    /// "~/dev" for a folder in the home folder, else the path as it is.
    public static func tildePath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = trimmed == "~" ? home : trimmed.hasPrefix("~/") ? home + trimmed.dropFirst(1) : trimmed
        return full.isEmpty ? "" : (full as NSString).standardizingPath
    }

    public struct File: Equatable, Sendable {
        public var name: String
        public var contents: String
    }

    public struct Plan: Equatable, Sendable {
        /// The new project's folder (full path).
        public var folder: String
        /// The projects folder isn't there yet: it's made first (0755).
        public var createsLocation: Bool
        /// README.md and .gitignore.
        public var files: [File]

        /// What git runs in `folder`, in order: `git init` on the default branch, then the first commit of `files`.
        public func gitSteps(branch: String) -> [[String]] {
            [["init", "--quiet", "--initial-branch=\(branch)"], ["add", "--"] + files.map(\.name),
             ["commit", "--quiet", "-m", ProjectCreation.commitMessage]]
        }
    }

    /// What making the project `name` in `location` writes and runs, or why it can't. `folderName` is what the sheet
    /// shows under the name (derived from it, or edited). `existing` says what's at a path (the file system's, here).
    public static func plan(name: String, folderName: String, location: String, home: String = NSHomeDirectory(),
                            existing: (String) -> Existing = ProjectCreation.existing) -> Result<Plan, Problem> {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !folderName.isEmpty else { return .failure(.emptyName) }
        guard !folderName.contains("/"), !folderName.contains(":") else { return .failure(.separator) }
        guard folderName.contains(where: { $0.isLetter || $0.isNumber }) else { return .failure(.noLetters) }
        guard !folderName.hasPrefix(".") else { return .failure(.leadingDot) }
        let root = expand(location, home: home)
        guard !root.isEmpty else { return .failure(.noLocation) }
        let shown = tildePath(root, home: home)
        let place = existing(root)
        if place == .file { return .failure(.locationIsFile(shown)) }
        let folder = (root as NSString).appendingPathComponent(folderName)
        switch existing(folder) {
        case .folder: return .failure(.exists(folder: folderName, location: shown))
        case .file: return .failure(.isFile(name: folderName, location: shown))
        case .none: break
        }
        let files = [File(name: "README.md", contents: readme(name: title)), File(name: ".gitignore", contents: gitignore)]
        return .success(Plan(folder: folder, createsLocation: place == .none, files: files))
    }

    /// Runs git: arguments and the folder it runs in.
    public typealias GitRunner = (_ args: [String], _ directory: String) -> Git.Result

    /// Makes what `plan` says (nil), or nothing: when a step fails, what this made (the project's folder, and the projects
    /// folder if it made that) is removed, and the error says what failed. Runs git and writes files: call off the main
    /// thread. Checks again that the folder isn't there (it may have come since the plan), before writing anything.
    public static func create(_ plan: Plan, git: GitRunner = { Git.run($0, in: $1) }) -> Problem? {
        let manager = FileManager.default
        let location = (plan.folder as NSString).deletingLastPathComponent
        let name = (plan.folder as NSString).lastPathComponent
        switch existing(plan.folder) {
        case .folder: return .exists(folder: name, location: tildePath(location))
        case .file: return .isFile(name: name, location: tildePath(location))
        case .none: break
        }
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        // The levels of the location that aren't there yet, outermost first (~/a, ~/a/b, ~/a/b/c): each is made on
        // its own, so a failure removes exactly those, and never a folder that was there before.
        var missing: [String] = []
        var level = location
        while !level.isEmpty, level != "/", existing(level) == .none {
            missing.insert(level, at: 0)
            level = (level as NSString).deletingLastPathComponent
        }
        var madeLevels: [String] = [], madeFolder = false
        func undo(_ problem: Problem) -> Problem {
            if madeFolder { try? manager.removeItem(atPath: plan.folder) }
            // Deepest first, and only while empty (rmdir): nothing anyone else put there meanwhile goes with them.
            for made in madeLevels.reversed() { rmdir(made) }
            return problem
        }
        do {
            for level in missing {
                try manager.createDirectory(atPath: level, withIntermediateDirectories: false, attributes: attributes)
                madeLevels.append(level)
            }
            // Not withIntermediateDirectories: if the folder came meanwhile, this fails instead of writing into it.
            try manager.createDirectory(atPath: plan.folder, withIntermediateDirectories: false, attributes: attributes)
            madeFolder = true
            for file in plan.files {
                try file.contents.write(toFile: (plan.folder as NSString).appendingPathComponent(file.name),
                                        atomically: true, encoding: .utf8)
            }
        } catch {
            return undo(.failed("The project's folder couldn't be made: \(error.localizedDescription)"))
        }
        let branch = branch(fromConfig: git(["config", "--get", "init.defaultBranch"], plan.folder))
        for step in plan.gitSteps(branch: branch) {
            let result = git(step, plan.folder)
            guard result.ok else {
                let said = [result.error, result.output].first { !$0.isEmpty } ?? "it exited with status \(result.status)."
                return undo(.failed("git \(step[0]) failed: \(said)"))
            }
        }
        return nil
    }
}
