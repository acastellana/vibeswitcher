import Foundation

/// The build of the tool server running now: the source commit `scripts/build-app.sh` wrote into the app's Info.plist
/// (`VSSourceCommit`), and the executable's modification time (the session host's log names a build by it).
///
/// turn-this-incident-into-12, 2026-11-07 22:10: the fix that lands a branch carrying origin/main as a true merge
/// (3b10a688, 4fb98121) was on main at 20:15, but the app merging at 22:10 was the 17:28 install, so the merge ran the
/// old gate and squashed the other Mac's commits again. Each merge now names the build that ran it, and status says
/// when main holds gate code the installed build lacks (`LeadToolset.gateLag`).
public struct ServerBuild: Equatable, Sendable {
    /// The commit it was built from; nil for a build from before build-app.sh recorded it.
    public var commit: String?
    /// Built with changes in Sources/ not committed (`VSSourceChanged`).
    public var changed: Bool
    /// The executable's modification time.
    public var builtAt: Date?

    public init(commit: String?, changed: Bool = false, builtAt: Date?) {
        self.commit = commit
        self.changed = changed
        self.builtAt = builtAt
    }

    /// How a receipt and a progress line name it: the commit's first 12 characters, else the build's time.
    public var label: String {
        if let commit { return String(commit.prefix(12)) + (changed ? " with changes not committed" : "") }
        guard let builtAt else { return "unknown" }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return "of \(format.string(from: builtAt)) (\(Int(builtAt.timeIntervalSince1970)); no commit recorded)"
    }

    /// This process's build, read once (an install the tool server switches to replaces the process, so it reads its
    /// own). Nil outside an app bundle: `swift test`'s runner and `swift run` have no installed build to lag behind.
    public static let running: ServerBuild? = read(executable: Bundle.main.executablePath ?? CommandLine.arguments[0])

    /// The build of the executable at `path`, inside `<name>.app/Contents/MacOS/`; nil anywhere else.
    static func read(executable path: String) -> ServerBuild? {
        let macOS = (path as NSString).deletingLastPathComponent
        let contents = (macOS as NSString).deletingLastPathComponent
        guard (macOS as NSString).lastPathComponent == "MacOS", (contents as NSString).lastPathComponent == "Contents",
              (contents as NSString).deletingLastPathComponent.hasSuffix(".app") else { return nil }
        let plist = (try? Data(contentsOf: URL(fileURLWithPath: (contents as NSString).appendingPathComponent("Info.plist"))))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let commit = (plist["VSSourceCommit"] as? String).flatMap(Self.validCommit)
        let builtAt = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        return ServerBuild(commit: commit, changed: plist["VSSourceChanged"] as? Bool ?? false, builtAt: builtAt)
    }

    /// `text` when it's a full commit id (40 or 64 hex characters), else nil.
    static func validCommit(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard [40, 64].contains(trimmed.count), trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed
    }
}

extension LeadToolset {
    /// The merge gate's own code (merge, its batches, the remote's tools, the lead's records, the tool server): a
    /// change to it on main does nothing for merges until it's installed. Git pathspecs, from the repository's root.
    static let gatePaths = ["Sources/VibeCore/Lead*", "Sources/VibeCore/Worktrees*", "Sources/VibeCore/MergeRerun*", "Sources/vibeswitcher-mcp/"]

    /// Commits on the base touching the gate's own code that the running build lacks.
    struct GateLag: Equatable {
        /// Each one's short id and subject, newest first.
        var commits: [(id: String, subject: String)]
        var build: ServerBuild

        static func == (lhs: GateLag, rhs: GateLag) -> Bool {
            lhs.commits.map(\.id) == rhs.commits.map(\.id) && lhs.build == rhs.build
        }

        /// status's line.
        func text(base: String) -> String {
            let shown = commits.prefix(3).map { LeadToolset.clip($0.subject, 80) }.joined(separator: "; ")
                + (commits.count > 3 ? "; … and \(commits.count - 3) more" : "")
            return "Gate code on \(base) isn't installed yet: \(commits.count) commit\(commits.count == 1 ? "" : "s") (\(shown)); merges run the installed build (\(build.label))."
        }

        /// What merge_remote and a merge of a branch carrying the remote say when they refuse.
        func refusal(base: String, what: String) -> String {
            "Not merged (nothing was tested): \(text(base: base)) \(what) runs through that build's gate, which lacks them. "
                + "Ask the user to install the app from \(base) (scripts/build-app.sh --install), then merge again."
        }
    }

    /// The commits on `workflow`'s base touching `gatePaths` that the running build (`runningBuild`) lacks: past its
    /// commit, or (a build that recorded none, or one this repository doesn't hold) committed after it was built. Nil
    /// when there are none, or no build is known (not running from an installed app).
    func gateLag(_ workflow: LeadWorkflow) -> GateLag? {
        guard let build = runningBuild(), let head = branchHead(workflow.base) else { return nil }
        let paths = ["--"] + Self.gatePaths
        var found: [(id: String, subject: String)] = []
        if let commit = build.commit, Git.run(["cat-file", "-e", "\(commit)^{commit}"], in: root).ok {
            let log = Git.run(["log", "--format=%h%x09%s", "\(commit)..\(head)"] + paths, in: root)
            guard log.ok else { return nil }
            found = log.output.split(separator: "\n").map { line in
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                return (parts[0], parts.count > 1 ? parts[1] : "")
            }
        } else if let builtAt = build.builtAt {
            let after = Int(builtAt.timeIntervalSince1970)
            // Bounded by the date, so a long history isn't walked at each status.
            let since = ISO8601DateFormatter().string(from: builtAt)
            let log = Git.run(["log", "--format=%h%x09%ct%x09%s", "--since=\(since)", head] + paths, in: root)
            guard log.ok else { return nil }
            for line in log.output.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count >= 2, let time = Int(parts[1]) else { continue }
                // Newest first: the first one built into it ends the list (a later date below it is clock skew).
                guard time > after else { break }
                found.append((parts[0], parts.count > 2 ? parts[2] : ""))
            }
        } else {
            return nil
        }
        return found.isEmpty ? nil : GateLag(commits: found, build: build)
    }

    /// " (build …)" for a merge's progress line, or "" when no build is known.
    var buildNote: String { runningBuild().map { " (build \($0.label))" } ?? "" }
}
