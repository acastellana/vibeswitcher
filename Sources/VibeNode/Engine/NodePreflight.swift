import Foundation
import VibeCore

/// What a lead's start needs on the node, looked at first, with no shell (the engine plan's EN-D13): the program
/// `claude` resolves to and git. `claude` is never looked up on a PATH or through a login shell (`LoginShellCommand`
/// runs `~/.bashrc`, which any worker can edit, and the node unit's PATH doesn't hold its folder): the link it is given
/// (`claudeLink`) is resolved with `realpath` and taken only when it names an executable regular file, whose absolute
/// path the lead is then started by. git is `Platform.Tools.git`, which is `absentGit` when no root-owned folder on
/// PATH holds one (stage 2's Task 10c). The refusal names what's missing and the link it read. The app's install of
/// what's missing (`ToolInstaller`) has no form here: agents install nothing, the user does.
public struct NodePreflight: Sendable {
    /// The link `claude` is found by: `<home>/.local/bin/claude` on the user's node, `<root>/v2/test/claude` on a scratch
    /// node (a link a test puts there), a parameter in a test.
    public var claudeLink: String
    /// The git the engine runs.
    public var git: String

    public init(claudeLink: String, git: String = Platform.Tools.git) {
        self.claudeLink = claudeLink
        self.git = git
    }

    /// The link a node with root `root` reads: on a scratch node (a root other than the account's own `~/.vibeswitcher`)
    /// only `<root>/v2/test/claude`; on the user's node `<home>/.local/bin/claude`, the home from the user database.
    public static func claudeLink(root: URL, accountHome: String = VibePaths.accountHome) -> String {
        guard VibePaths.isAccountRoot(root, accountHome: accountHome) else {
            return root.appendingPathComponent("v2/test/claude").path
        }
        return URL(fileURLWithPath: accountHome, isDirectory: true).appendingPathComponent(".local/bin/claude").path
    }

    /// The program the lead and its roles run (`claude`'s resolved, absolute path), or why there is none and what else
    /// is missing: every missing piece named, the link read with each.
    public func check() -> Result<String, Refusal> {
        var missing: [String] = []
        let claude = Self.resolve(claudeLink)
        if let why = claude.why { missing.append(why) }
        if git == Platform.Tools.absentGit {
            missing.append("git: no git on PATH in a folder owned by root that only root can write")
        } else if !Self.isExecutableFile(git) {
            missing.append("git: nothing runnable at \(git)")
        }
        if let path = claude.path, missing.isEmpty { return .success(path) }
        return .failure(Refusal(missing: missing))
    }

    /// Why a lead didn't start for want of its programs: one line for each.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var missing: [String]
        public var description: String {
            "the lead wasn't started: " + missing.joined(separator: "; ")
        }
    }

    /// `link` resolved with `realpath` (no shell, no PATH), when it names an executable regular file; else why not.
    static func resolve(_ link: String) -> (path: String?, why: String?) {
        guard link.hasPrefix("/") else { return (nil, "claude: the link \(link) isn't an absolute path") }
        guard let resolved = realpath(link, nil) else {
            return (nil, "claude: \(link) names nothing (\(String(cString: strerror(errno)))); Claude Code's link is read there, never looked up on PATH")
        }
        let path = String(cString: resolved)
        free(resolved)
        guard isExecutableFile(path) else {
            return (nil, "claude: \(link) resolves to \(path), which isn't an executable regular file")
        }
        return (path, nil)
    }

    /// A regular file this process may run.
    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }
}
