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

    /// How a receipt and a progress line name it: the commit's first 12 characters. A build that recorded none is
    /// unknown: its executable's date (the host log's build id) is when it was copied into place, not what it holds
    /// (install-app.sh's `cp -R` dates the copy), so it's only said beside.
    public var label: String {
        if let commit { return String(commit.prefix(12)) + (changed ? " with changes not committed" : "") }
        guard let builtAt else { return "unknown (no commit recorded)" }
        return "unknown (no commit recorded; its files dated \(Self.date(builtAt)), \(Int(builtAt.timeIntervalSince1970)))"
    }

    static func date(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: date)
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

    /// Commits on the base touching the gate's own code that the running build lacks, or why it couldn't be compared
    /// with the base (taken as lacking them: the check fails closed).
    struct GateLag: Equatable {
        /// Each one's short id and subject, newest first; empty when `uncompared`.
        var commits: [(id: String, subject: String)]
        var build: ServerBuild
        /// Why the build couldn't be compared with the base (git failed or ran out of time, the build's commit isn't in
        /// this repository, or it recorded none and its files' date can't tell); nil when it was.
        var uncompared: String?

        init(commits: [(id: String, subject: String)] = [], build: ServerBuild, uncompared: String? = nil) {
            self.commits = commits
            self.build = build
            self.uncompared = uncompared
        }

        static func == (lhs: GateLag, rhs: GateLag) -> Bool {
            lhs.commits.map(\.id) == rhs.commits.map(\.id) && lhs.build == rhs.build && lhs.uncompared == rhs.uncompared
        }

        /// status's line.
        func text(base: String) -> String {
            if let uncompared {
                return "Gate code on \(base) couldn't be compared with the installed build (\(build.label)): \(uncompared). "
                    + "Taken as not installed yet; merges run the installed build."
            }
            let shown = commits.prefix(3).map { LeadToolset.clip($0.subject, 80) }.joined(separator: "; ")
                + (commits.count > 3 ? "; … and \(commits.count - 3) more" : "")
            return "Gate code on \(base) isn't installed yet: \(commits.count) commit\(commits.count == 1 ? "" : "s") (\(shown)); merges run the installed build (\(build.label))."
        }

        /// What merge_remote and a merge of a branch carrying the remote say when they refuse.
        func refusal(base: String, what: String) -> String {
            "Not merged (nothing was tested): \(text(base: base)) \(what) runs through that build's gate, which "
                + (uncompared == nil ? "lacks them. " : "may lack them. ")
                + "Ask the user to install the app from \(base) (scripts/build-app.sh --install), then merge again."
        }
    }

    /// The commits on `workflow`'s base touching `gatePaths` that the running build (`runningBuild`) lacks: past its
    /// commit, or (a build that recorded none) committed after its files' date, which is no earlier than its build.
    /// Fails closed (turn-this-incident-into-12:F1, F3): a git log that fails or runs out of time, a commit this
    /// repository doesn't hold, or a build with no commit whose files' date is past all the gate's commits (an install
    /// copies the files, dating them then) is a lag that couldn't be compared. Nil when there's none, when no build is
    /// known (not running from an installed app), and in a repository holding none of the gate's code.
    func gateLag(_ workflow: LeadWorkflow) -> GateLag? {
        guard let build = runningBuild(), let head = branchHead(workflow.base) else { return nil }
        let paths = ["--"] + Self.gatePaths
        func failed(_ what: String, _ result: Git.Result) -> GateLag {
            let said = (result.error.isEmpty ? result.output : result.error).split(separator: "\n").first.map(String.init) ?? ""
            return GateLag(build: build, uncompared: "git log \(what) failed" + (said.isEmpty ? "" : " (\(LeadToolset.clip(said, 160)))"))
        }
        func entries(_ output: String, fields: Int) -> [[String]] {
            output.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: fields - 1, omittingEmptySubsequences: false).map(String.init) }
        }
        // Another project's repository holds none of it: nothing to lag behind.
        let newest = Git.run(["log", "-1", "--format=%h", head] + paths, in: root)
        guard newest.ok else { return failed("of \(workflow.base)'s gate code", newest) }
        guard !newest.output.isEmpty else { return nil }
        let found: [(id: String, subject: String)]
        if let commit = build.commit {
            guard Git.run(["cat-file", "-e", "\(commit)^{commit}"], in: root).ok else {
                return GateLag(build: build, uncompared: "its commit \(commit.prefix(12)) isn't in this repository")
            }
            let log = Git.run(["log", "--format=%h%x09%s", "\(commit)..\(head)"] + paths, in: root)
            guard log.ok else { return failed("\(commit.prefix(8))..\(workflow.base)", log) }
            found = entries(log.output, fields: 2).map { ($0[0], $0.count > 1 ? $0[1] : "") }
        } else if let builtAt = build.builtAt {
            let log = Git.run(["log", "--format=%h%x09%ct%x09%s", "--since=\(ISO8601DateFormatter().string(from: builtAt))", head] + paths, in: root)
            guard log.ok else { return failed("of \(workflow.base)'s gate code since \(ServerBuild.date(builtAt))", log) }
            let after = Int(builtAt.timeIntervalSince1970)
            found = entries(log.output, fields: 3).filter { $0.count >= 2 && (Int($0[1]) ?? 0) > after }.map { ($0[0], $0.count > 2 ? $0[2] : "") }
            // None after its files' date: they may be the install's copy of an older build, so that tells nothing.
            if found.isEmpty {
                return GateLag(build: build, uncompared: "it recorded no commit, and its files' date (\(ServerBuild.date(builtAt))) is past \(workflow.base)'s gate code, as an install's copy dates them; install a build that records its commit")
            }
        } else {
            return GateLag(build: build, uncompared: "it recorded no commit, and its files' date can't be read")
        }
        return found.isEmpty ? nil : GateLag(commits: found, build: build)
    }

    /// " (build …)" for a merge's progress line, or "" when no build is known.
    var buildNote: String { runningBuild().map { " (build \($0.label))" } ?? "" }
}
