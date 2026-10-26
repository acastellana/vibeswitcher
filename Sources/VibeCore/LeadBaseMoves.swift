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
        /// A command a team session ran could have made one of its entries: never taken on what the window saw typed.
        public var team: Bool?

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
    /// `slack`: how long before a command was seen starting an entry may be its (a hook tells it a moment late).
    public static func judge(from recorded: String, history: BaseHistory, branch: String, runs: [GitRun],
                             now: Double = Date().timeIntervalSince1970, slack: Double = 2) -> BaseMove {
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
        // The command made the entry: while it ran, between the heads it ran from and to, and it's what it makes.
        func made(_ run: GitRun, _ entry: BaseHistory.Entry, _ kind: MoveKind) -> Bool {
            guard let after = run.after, let ended = run.ended, kind.madeBy(run.verb) else { return false }
            return entry.time >= run.started.rounded(.down) - slack && entry.time <= ended + 2
                && history.descends(entry.old, from: run.before) && history.descends(after, from: entry.new)
        }
        // A team session's command was running when the entry was made: it may be what made it, whatever it was and
        // wherever it ended (one still running hasn't said), the hook's slack included. Over the whole chain, also past
        // the first entry nobody accounts for.
        func mayHaveMade(_ run: GitRun, _ entry: BaseHistory.Entry) -> Bool {
            entry.time >= run.started.rounded(.down) - 2 && run.ended.map { entry.time <= $0 + 2 } ?? true
        }
        if chain.contains(where: { entry in runs.contains { !$0.user && mayHaveMade($0, entry) } }) {
            move.team = true
        }
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
                made(runs[index], entry, kind) && !(MoveKind.single(runs[index].verb) && used.contains(index))
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

    /// A shell line you sent from VibeSwitcher's window into a session (the composer, or Run on a code block): the
    /// app's own process saw you send it. `!` makes it a shell command the agent runs as it is, with no hooks and no
    /// agent in between, so nothing else tells the host about it.
    public struct Typed: Equatable, Sendable {
        public var session: String
        public var line: String
        public var cwd: String
        public var at: Double

        /// How long after it was sent a line accounts for what it moved: such a command runs as soon as it's sent.
        public static let lasts: Double = 30

        public init(session: String, line: String, cwd: String, at: Double) {
            self.session = session
            self.line = line
            self.cwd = cwd
            self.at = at
        }

        /// The shell line in what was sent: what follows a leading `!`. Anything else is a message to the agent,
        /// whose own commands its hooks tell.
        public static func shell(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("!") else { return nil }
            let line = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }

    /// The window's typed lines as the runs they are on `branch` in `root` (for `judge`, with no slack: only what
    /// appeared after it was sent): each git command among them that can move a branch, in a checkout of `branch`
    /// there now, from when it was sent until `Typed.lasts` later (or `now`), between where the lead left it
    /// (`recorded`) and `head`.
    public static func runs(typed: [Typed], root: String, branch: String, recorded: String, head: String, now: Double,
                            checkout: (String) -> (root: String, branch: String, head: String)? = GitMoves.checkout(at:)) -> [GitRun] {
        let root = GitMoves.resolved(root)
        var known: [String: (root: String, branch: String, head: String)?] = [:]
        return typed.flatMap { typed in
            GitMoves.commands(in: typed.line, cwd: typed.cwd).compactMap { command -> GitRun? in
                let place = known[command.folder] ?? checkout(command.folder)
                known[command.folder] = place
                guard let place, GitMoves.resolved(place.root) == root, place.branch == branch else { return nil }
                return GitRun(session: typed.session, user: true, call: nil, verb: command.verb, branch: branch, before: recorded,
                              after: head, started: typed.at, ended: min(now, typed.at + Typed.lasts))
            }
        }
    }

    /// What VibeSwitcher's window does about a move the vault didn't take, for the lead's merge to say. It words the
    /// refusal only: what takes a move is the vault's head, which the app sets when you accept.
    public struct BaseMoveNote: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            /// The window asks you: a card in the lead's chat, and a notification.
            case asking
            /// You answered Keep Refused.
            case kept
        }

        public var branch: String
        public var from: String
        public var to: String
        public var state: State
        public var commits: Int
        public var reason: String?

        public init(branch: String, from: String, to: String, state: State, commits: Int, reason: String?) {
            self.branch = branch
            self.from = from
            self.to = to
            self.state = state
            self.commits = commits
            self.reason = reason
        }

        static func path(root: String) -> String {
            (BoardStore(root: root).folder as NSString).appendingPathComponent("run/base-move.json")
        }

        public static func load(root: String) -> BaseMoveNote? {
            (try? Data(contentsOf: URL(fileURLWithPath: path(root: root)))).flatMap { try? JSONDecoder().decode(BaseMoveNote.self, from: $0) }
        }

        public func save(root: String) throws {
            let url = URL(fileURLWithPath: Self.path(root: root))
            try VibePaths.ensurePrivate(url.deletingLastPathComponent(), within: URL(fileURLWithPath: BoardStore(root: root).folder))
            try VibePaths.writePrivate(try JSONEncoder().encode(self), to: url)
        }

        public static func clear(root: String) {
            try? FileManager.default.removeItem(atPath: path(root: root))
        }
    }

    /// A merge of the lead's that a base move refused: its merges wait on the user now, so the window tells them (once
    /// per move: `AlertRules.baseMoved`). Until a merge is refused the move waits on no one, and stays silent: the user
    /// commits on the base themselves. Written by the lead's merge, read by the window.
    public struct BaseMoveRefusal: Codable, Equatable, Sendable {
        public var branch: String
        /// The commit the base had moved to.
        public var to: String
        public var at: Double

        public init(branch: String, to: String, at: Double) {
            self.branch = branch
            self.to = to
            self.at = at
        }

        static func path(root: String) -> String {
            (BoardStore(root: root).folder as NSString).appendingPathComponent("run/base-move-refused.json")
        }

        public static func load(root: String) -> BaseMoveRefusal? {
            (try? Data(contentsOf: URL(fileURLWithPath: path(root: root)))).flatMap { try? JSONDecoder().decode(BaseMoveRefusal.self, from: $0) }
        }

        public func save(root: String) throws {
            let url = URL(fileURLWithPath: Self.path(root: root))
            try VibePaths.ensurePrivate(url.deletingLastPathComponent(), within: URL(fileURLWithPath: BoardStore(root: root).folder))
            try VibePaths.writePrivate(try JSONEncoder().encode(self), to: url)
        }

        public static func clear(root: String) {
            try? FileManager.default.removeItem(atPath: path(root: root))
        }

        /// A merge refused for `move` (the vault's answer about `base` at `current`): marked, unless the move waits on a
        /// command of the user's still running (it isn't the user's to answer then).
        public static func mark(base: String, current: String, move: Result<BaseMove, Error>, root: String, now: Double = Date().timeIntervalSince1970) {
            if case .success(let move) = move, move.waiting == true { return }
            try? BaseMoveRefusal(branch: base, to: current, at: now).save(root: root)
        }
    }

    /// The merge's refusal when `base` moved from `known` to `current` and the vault didn't take it (`move`, or the
    /// error asking for it): why, and what the window does about it, from its note.
    public static func moveRefusal(base: String, known: String, current: String, move: Result<BaseMove, Error>, root: String) -> String {
        let head = "Not merged: \(base) moved since the lead last left it (\(known.prefix(8)) → \(current.prefix(8))), and not through merge."
        let why: String
        switch move {
        case .success(let move) where move.waiting == true:
            return head + (move.reason.map { " \($0)" } ?? "") + " A command of the user's that may account for it is still running: merge again in a moment."
        case .success(let move): why = move.reason ?? ""
        case .failure(let error): why = "(\(error))"
        }
        let commits = "`git log \(known.prefix(8))..\(base)` lists them"
        guard let note = BaseMoveNote.load(root: root), note.branch == base, note.from == known, note.to == current else {
            return head + " \(why) VibeSwitcher's window looks at \(base) every few seconds: it takes the move as the user's when they ran it from the window, and otherwise asks them to accept it in your chat (\(commits)). Merge again in a minute: this then says which. No restart is needed."
        }
        let count = "\(note.commits) commit\(note.commits == 1 ? "" : "s")"
        switch note.state {
        case .asking:
            return head + " \(why) So VibeSwitcher is asking the user: a card in your chat in its window lists the \(count) (\(commits)) with Accept, and as this merge waits on it, it notifies them now. You get a message when they accept; merge then. Don't ask them to restart you or to run anything: Accept is all it takes. Tell them if the commits aren't theirs."
        case .kept:
            return head + " \(why) The user answered Keep Refused in VibeSwitcher's window, so nothing merges onto these \(count) (\(commits)). Ask them what to do with them; a restart doesn't change it."
        }
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

    /// The repository `folder` is in (its main checkout, also from a linked worktree such as .claude/worktrees/x,
    /// where a lead works), its checked-out branch and that branch's head.
    public static func checkout(at folder: String) -> (root: String, branch: String, head: String)? {
        let top = Git.run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "HEAD"], in: folder).output
            .split(separator: "\n").map(String.init)
        let branch = Git.run(["symbolic-ref", "-q", "--short", "HEAD"], in: folder)
        guard top.count == 3, branch.ok, !branch.output.isEmpty else { return nil }
        let common = top[1] as NSString
        return (common.lastPathComponent == ".git" ? common.deletingLastPathComponent : top[0], branch.output, top[2])
    }

    /// A path with its symlinks resolved, to compare roots by.
    static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

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
