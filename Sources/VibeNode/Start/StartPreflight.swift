import Foundation
import VibeCore

/// What `start` needs before it writes a unit or starts anything (the bootstrap path's "Who starts the node"; the
/// start plan's ST-D5 step 6): `claude` resolving to an executable file from its link (`NodePreflight.claudeLink`,
/// never PATH), `swift` and `node` in the folders the unit's PATH adds (`NodeFolders.toolFolders`), and a git in a
/// folder only root can write (`Platform.Tools.git`). It looks only at the paths it is given, with no shell, and names
/// every missing piece.
public struct StartPreflight: Sendable {
    public var claudeLink: String
    public var swiftBin: String
    public var nodeBin: String
    public var git: String

    public init(claudeLink: String, swiftBin: String, nodeBin: String, git: String = Platform.Tools.git) {
        self.claudeLink = claudeLink
        self.swiftBin = swiftBin
        self.nodeBin = nodeBin
        self.git = git
    }

    /// What was found: four absolute paths.
    public struct Found: Equatable, Sendable {
        /// The program `claudeLink` resolves to.
        public var claude: String
        /// `<swiftBin>/swift` and `<nodeBin>/node`, as the unit's PATH finds them.
        public var swift: String
        public var node: String
        public var git: String

        public init(claude: String, swift: String, node: String, git: String) {
            self.claude = claude
            self.swift = swift
            self.node = node
            self.git = git
        }
    }

    /// The four programs, or every one missing, each by its label (`claude:`, `swift:`, `node:`, `git:`), in that order.
    public func check() -> Result<Found, StartRefusal> {
        var missing: [String] = []
        let claude = NodePreflight.resolve(claudeLink)
        if let why = claude.why { missing.append(why) }
        let swift = NodeFolders.join(swiftBin, "swift"), node = NodeFolders.join(nodeBin, "node")
        if !NodePreflight.isExecutableFile(swift) {
            missing.append("swift: nothing runnable at \(ConfigSeal.inert(swift, limit: .max)); the unit's PATH takes swift in ~/.local/share/swiftly/bin, never the shell's PATH")
        }
        if !NodePreflight.isExecutableFile(node) {
            missing.append("node: nothing runnable at \(ConfigSeal.inert(node, limit: .max)); the unit's PATH takes node in ~/.nvm/versions/node/<version>/bin, never the shell's PATH")
        }
        if git == Platform.Tools.absentGit {
            missing.append("git: no git in a folder only root can write (on PATH, owned by root up to /)")
        } else if !NodePreflight.isExecutableFile(git) {
            missing.append("git: nothing runnable at \(ConfigSeal.inert(git, limit: .max))")
        }
        guard missing.isEmpty, let path = claude.path else {
            return .failure(StartRefusal("start's preflight: " + missing.joined(separator: "; ")))
        }
        return .success(Found(claude: path, swift: swift, node: node, git: git))
    }
}
