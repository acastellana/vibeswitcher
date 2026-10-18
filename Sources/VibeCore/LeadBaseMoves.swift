import Foundation

// The user's own sessions commit to the lead's base too (a fix, a version bump), and a merge refuses a base that
// moved since the lead last left it. So each session's hooks tell the session host the git commands it runs that
// can move a branch, before and after, and the host records them under the session it tells the hook's process is
// in (never one it says it is). A move is taken as the user's when it fast-forwards from the head the lead left and
// every reflog entry since is one such command, from a session the app opened that holds no role in the team; any
// other move waits for the user's click in the app.

extension LeadVault {
    /// A git command that can move a branch (`GitMoves.verbs`), as a session's hooks tell the host just before it
    /// runs and just after: the checkout's branch and its head at that moment.
    public struct GitStep: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable { case before, after }
        public var phase: Phase
        /// The agent's id for the tool call (pairs the two), when it gives one.
        public var call: String?
        public var verb: String
        public var branch: String
        public var head: String

        public init(phase: Phase, call: String?, verb: String, branch: String, head: String) {
            self.phase = phase
            self.call = call
            self.verb = verb
            self.branch = branch
            self.head = head
        }
    }

    /// Such a command as the host recorded it, in the session the host told the hook's process runs in.
    public struct GitRun: Codable, Equatable, Sendable {
        public var session: String
        /// The session is one of the user's: the app opened it (no session started it), and it held no role in the
        /// team when it ran this.
        public var user: Bool
        public var call: String?
        public var verb: String
        public var branch: String
        public var before: String
        public var after: String?
        public var started: Double
        public var ended: Double?

        public init(session: String, user: Bool, call: String?, verb: String, branch: String, before: String,
                    after: String? = nil, started: Double, ended: Double? = nil) {
            self.session = session
            self.user = user
            self.call = call
            self.verb = verb
            self.branch = branch
            self.before = before
            self.after = after
            self.started = started
            self.ended = ended
        }
    }

    /// The base moved since the lead last left it: the commits that came in, and whether the vault took the move as
    /// the user's own (see `judge`).
    public struct BaseMove: Codable, Equatable, Sendable {
        public struct Commit: Codable, Equatable, Sendable {
            public var sha: String
            public var subject: String
        }

        public var branch: String
        public var from: String
        public var to: String
        public var accepted: Bool
        /// The commits that came in, newest first (none when it isn't a fast-forward).
        public var commits: [Commit]
        /// The sessions whose commands made it, and their names in the window when the host knows them.
        public var sessions: [String]
        public var labels: [String]?
        /// Why it wasn't taken.
        public var reason: String?
        /// A command of the user's that may account for it hasn't finished (its hooks haven't said so): look again
        /// in a moment.
        public var waiting: Bool?

        /// "1 commit", "3 commits".
        public var count: String { "\(commits.count) commit\(commits.count == 1 ? "" : "s")" }

        /// The board's line for a move taken: "accepted 1 commit from your session Claude · app: a92a8dc Fix …".
        public var acceptedLine: String {
            let names = (labels ?? []).isEmpty ? sessions.map { String($0.prefix(8)) } : labels ?? []
            let from = names.isEmpty ? "" : " from your session\(names.count == 1 ? "" : "s") \(names.joined(separator: ", "))"
            return "accepted \(count) on \(branch)\(from): " + commits.prefix(3).map { "\($0.sha.prefix(7)) \($0.subject)" }.joined(separator: "; ")
                + (commits.count > 3 ? "; …" : "")
        }
    }

    /// What git says about a branch since the head the lead left: where it is now, whether that fast-forwards from
    /// there, the commits in between (with their parents) and the branch's reflog.
    public struct BaseHistory: Equatable, Sendable {
        public struct Entry: Equatable, Sendable {
            public var old: String
            public var new: String
            public var time: Double
            public var message: String
        }

        public struct Commit: Equatable, Sendable {
            public var parents: [String]
            public var subject: String
        }

        public var head: String
        public var fastForward: Bool
        /// The commits in `since..head`, newest first, and each one's parents.
        public var order: [String]
        public var commits: [String: Commit]
        /// Oldest first.
        public var reflog: [Entry]

        public static func read(root: String, branch: String, since: String) -> BaseHistory? {
            guard let head = LeadVault.branchHead(branch, root: root) else { return nil }
            let fastForward = Git.run(["merge-base", "--is-ancestor", since, head], in: root).ok
            var order: [String] = []
            var commits: [String: Commit] = [:]
            if fastForward {
                let log = Git.run(["log", "--max-count=500", "--format=%H%x09%P%x09%s", "\(since)..\(head)"], in: root)
                for line in log.output.split(separator: "\n") {
                    let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    guard fields.count >= 2 else { continue }
                    order.append(fields[0])
                    commits[fields[0]] = Commit(parents: fields[1].split(separator: " ").map(String.init), subject: fields.count > 2 ? fields[2] : "")
                }
            }
            let path = Git.run(["rev-parse", "--git-path", "logs/refs/heads/\(branch)"], in: root).output
            let file = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            return BaseHistory(head: head, fastForward: fastForward, order: order, commits: commits,
                               reflog: Array(entries(text).suffix(500)))
        }

        /// A reflog file's lines: `<old> <new> <name> <email> <time> <zone>\t<message>`.
        static func entries(_ text: String) -> [Entry] {
            text.split(separator: "\n").compactMap { line in
                let halves = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                let words = halves[0].split(separator: " ")
                guard words.count >= 4, let time = Double(words[words.count - 2]) else { return nil }
                return Entry(old: String(words[0]), new: String(words[1]), time: time, message: halves.count > 1 ? String(halves[1]) : "")
            }
        }

        /// `commit` is `ancestor` or descends from it, through the commits since the lead's head.
        func descends(_ commit: String, from ancestor: String) -> Bool {
            var queue = [commit]
            var seen: Set<String> = []
            while let next = queue.popLast() {
                if next == ancestor { return true }
                guard seen.insert(next).inserted, let parents = commits[next]?.parents else { continue }
                queue.append(contentsOf: parents)
            }
            return false
        }
    }

    /// What a reflog entry says moved the branch, of the moves a session of the user's may make on the base.
    enum MoveKind: String {
        case commit, merge, pull, cherryPick = "cherry-pick", revert, am

        /// From the entry's message ("commit (merge): …", "merge agent/x: Fast-forward", "pull: …"). An amend, a
        /// rebase, a reset, a plumbing update: none.
        init?(message: String) {
            let action = message.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            let words = action.split(separator: " ").map(String.init)
            guard let first = words.first, let kind = MoveKind(rawValue: first) else { return nil }
            if kind == .commit, words.contains("(amend)") { return nil }
            if kind == .pull, words.count > 1 { return nil }
            self = kind
        }

        /// A command that makes one entry each time it runs (cherry-pick, revert and am make one per commit).
        static func single(_ verb: String) -> Bool { ["commit", "merge", "pull"].contains(verb) }

        /// The command `verb` can have made an entry of this kind (`git merge --continue` concludes with a commit).
        func madeBy(_ verb: String) -> Bool { rawValue == verb || (self == .commit && verb == "merge") || (self == .merge && verb == "pull") }
    }

    /// Whether the move from `recorded` to `history.head` is the user's own: a fast-forward whose every reflog entry
    /// since `recorded` is one the user's sessions' recorded `runs` account for (the command made it, while it ran,
    /// between the heads it ran from and to, and it is what that command makes), and that no team session's could.
    public static func judge(from recorded: String, history: BaseHistory, branch: String, runs: [GitRun],
                             now: Double = Date().timeIntervalSince1970) -> BaseMove {
        var move = BaseMove(branch: branch, from: recorded, to: history.head, accepted: false,
                            commits: history.order.map { BaseMove.Commit(sha: $0, subject: history.commits[$0]?.subject ?? "") },
                            sessions: [], reason: nil)
        let from = recorded.prefix(8), to = history.head.prefix(8)
        guard history.fastForward else {
            move.reason = "\(branch) was rewritten: \(to) doesn't descend from \(from) (a reset, a rebase or an amend)."
            return move
        }
        // The reflog, from the head back to where the lead left it, each entry starting where the one before it ended.
        var chain: [BaseHistory.Entry] = []
        var at = history.head
        for entry in history.reflog.reversed() {
            guard entry.new == at else { break }
            chain.insert(entry, at: 0)
            if entry.old == recorded { break }
            at = entry.old
        }
        guard chain.first?.old == recorded else {
            move.reason = "\(branch)'s reflog doesn't show how it got from \(from) to \(to)."
            return move
        }
        let runs = runs.filter { $0.branch == branch }
        var used: Set<Int> = []
        for entry in chain {
            let commit = entry.new.prefix(8)
            guard let kind = MoveKind(message: entry.message) else {
                move.reason = "‘\(entry.message)’ moved \(branch) to \(commit): not a commit, merge, cherry-pick, revert, am or pull."
                return move
            }
            let firstParent = history.commits[entry.new]?.parents.first == entry.old
            guard firstParent || ((kind == .merge || kind == .pull) && history.descends(entry.new, from: entry.old)) else {
                move.reason = "\(commit) isn't what a \(kind.rawValue) on \(entry.old.prefix(8)) makes."
                return move
            }
            let candidates = runs.indices.filter { index in
                let run = runs[index]
                guard let after = run.after, let ended = run.ended, kind.madeBy(run.verb) else { return false }
                return entry.time >= run.started.rounded(.down) - 2 && entry.time <= ended + 2
                    && history.descends(entry.old, from: run.before) && history.descends(after, from: entry.new)
                    && !(MoveKind.single(run.verb) && used.contains(index))
            }
            if let team = candidates.first(where: { !runs[$0].user }) {
                move.reason = "\(commit) (‘\(entry.message)’) came from a session that isn't one of yours (\(runs[team].session.prefix(8)): a team member's, or one a session started)."
                return move
            }
            guard let index = candidates.first else {
                // A command of the user's still running may be the one: its hooks say so when it's done.
                // Not for long: a command its agent was refused leaves no after. The app looks again while it asks.
                move.waiting = runs.contains { $0.user && $0.ended == nil && now - $0.started < 120 && entry.time >= $0.started.rounded(.down) - 2 }
                move.reason = "No command VibeSwitcher saw a session of yours run accounts for \(commit) (‘\(entry.message)’)."
                return move
            }
            used.insert(index)
            if !move.sessions.contains(runs[index].session) { move.sessions.append(runs[index].session) }
        }
        move.accepted = true
        return move
    }

    /// The vault takes the base as it is now, when the move since the lead last left it is the user's own (see
    /// `judge`): the head is recorded, and the move says what came in. Otherwise it says why not, and the head stays.
    /// The app, or the repository's lead.
    public func acceptMove(root: String, branch: String) throws -> BaseMove {
        guard case .move(let move) = try call(.acceptMove(root: root, branch: branch)) else { throw Self.unexpected }
        return move
    }

    /// A session's hooks: a git command it's about to run, or just ran (see `GitMoves`).
    public func record(_ step: GitStep, root: String) throws {
        _ = try call(.ranGit(root: root, step: step))
    }
}

/// The git commands in an agent's shell tool calls that can move a branch, for its hooks to tell the host.
public enum GitMoves {
    public static let verbs: Set<String> = ["commit", "merge", "cherry-pick", "revert", "am", "pull"]
    static let shellTools: Set<String> = ["Bash", "shell", "local_shell", "exec_command", "container.exec"]

    /// The commands in a shell line, each with the folder it runs in (`cd` before it, `git -C`). Anything this
    /// doesn't follow (a subshell, a variable) is only missed: a move nobody accounts for waits for your click.
    public static func commands(in line: String, cwd: String) -> [(verb: String, folder: String)] {
        var found: [(verb: String, folder: String)] = []
        var folder = cwd
        for segment in segments(line) {
            var words = segment
            while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
            guard let program = words.first else { continue }
            if program == "cd", words.count > 1 {
                folder = resolve(words[1], in: folder)
                continue
            }
            guard program == "git" || program.hasSuffix("/git") else { continue }
            var index = 1
            var at = folder
            while index < words.count, words[index].hasPrefix("-") {
                if words[index] == "-C", index + 1 < words.count {
                    at = resolve(words[index + 1], in: at)
                    index += 1
                } else if words[index] == "-c" {
                    index += 1
                }
                index += 1
            }
            if index < words.count, verbs.contains(words[index]) { found.append((words[index], at)) }
        }
        return found
    }

    /// A hook event's git commands that can move a branch, before or after the tool call that runs them: each with
    /// its repository's root and the step to record (`branch` and `head` say where the checkout is now).
    public static func steps(for payload: [String: Any],
                             checkout: (String) -> (root: String, branch: String, head: String)? = checkout(at:)) -> [(root: String, step: LeadVault.GitStep)] {
        let phase: LeadVault.GitStep.Phase
        switch payload["hook_event_name"] as? String {
        case "PreToolUse": phase = .before
        case "PostToolUse": phase = .after
        default: return []
        }
        guard let tool = payload["tool_name"] as? String, shellTools.contains(tool) else { return [] }
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        guard let line = (input["command"] as? String) ?? (input["command"] as? [String])?.joined(separator: " ") ?? (input["cmd"] as? String),
              let cwd = (input["workdir"] as? String) ?? (payload["cwd"] as? String) else { return [] }
        let call = (payload["tool_use_id"] as? String) ?? (payload["call_id"] as? String)
        var known: [String: (root: String, branch: String, head: String)?] = [:]
        return commands(in: line, cwd: cwd).compactMap { command in
            let place = known[command.folder] ?? checkout(command.folder)
            known[command.folder] = place
            guard let place else { return nil }
            return (place.root, LeadVault.GitStep(phase: phase, call: call, verb: command.verb, branch: place.branch, head: place.head))
        }
    }

    /// The repository `folder` is in, its checked-out branch and that branch's head.
    public static func checkout(at folder: String) -> (root: String, branch: String, head: String)? {
        let top = Git.run(["rev-parse", "--show-toplevel", "HEAD"], in: folder).output.split(separator: "\n").map(String.init)
        let branch = Git.run(["symbolic-ref", "-q", "--short", "HEAD"], in: folder)
        guard top.count == 2, branch.ok, !branch.output.isEmpty else { return nil }
        return (top[0], branch.output, top[1])
    }

    private static func resolve(_ path: String, in folder: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : ((folder as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// A shell line's simple commands, each as its words (quotes taken off). `&&`, `||`, `;`, `|` and newlines end one.
    static func segments(_ line: String) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var characters = Array(line)[...]
        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }
        while let character = characters.popFirst() {
            if let open = quote {
                if character == open { quote = nil } else if character == "\\", open == "\"", let next = characters.popFirst() { word.append(next) } else { word.append(character) }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                inWord = true
            case "\\":
                if let next = characters.popFirst(), next != "\n" { word.append(next); inWord = true }
            case " ", "\t":
                endWord()
            case ";", "\n", "|", "&", "(", ")":
                endSegment()
            default:
                word.append(character)
                inWord = true
            }
        }
        endSegment()
        return segments
    }
}
