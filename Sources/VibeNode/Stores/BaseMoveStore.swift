import Foundation
import VibeCore

/// Each lead's base, watched (the app's `BaseMoves` 88-217; the engine plan's E6): when it moved since the lead last left
/// it, and not through its merges,
/// the session host's vault is asked to take the move as the user's own (`LeadVault.judge`). Otherwise (a commit no
/// session of the user's is seen making, a rewrite, a team member's) it becomes a card, asked once per move: `base
/// accept` takes the base as the card showed it in the vault, with the lead and its team running on; `base keep` leaves
/// the lead's merges refused and isn't asked again until it moves again. What it does is noted for the lead's merge to
/// say (`LeadVault.BaseMoveNote`, `BaseMoveRefusal`), as the app writes them, on the engine's reads queue.
///
/// `base show FOLDER [--from COMMIT]` (`show`) makes a card on demand, also with no lead running (a fresh vault's).
///
/// **Not the app's typed `!` lines** (on purpose, the independent review of 2026-11-22): a `!` git line the user sends
/// with `vibeswitcher send` never accounts for a move. A line vouches for a time window, not for the move it made: any
/// reflog entry that fits the window (whose time `GIT_COMMITTER_DATE` sets) would be taken, a team session's command
/// the hooks' parser doesn't recognise (`env git …`, `sh -c`, an alias, a script) isn't seen as the team's, and a line
/// that moved nothing stays open meanwhile; on a node, where every process of the user's can run git in the lead's
/// folder, nobody can tell who wrote a reflog entry. So the user's own git line draws a card like any other move: one
/// `vibeswitcher approve` away.
///
/// Looked at from the engine's queue (`main`); git, the vault and the files' stamps are asked off it (`background`).
public final class BaseMoveStore: @unchecked Sendable {
    /// A commit as a card lists it.
    public struct Commit: Equatable, Sendable {
        public var sha: String
        public var subject: String
        public init(sha: String, subject: String) {
            self.sha = sha
            self.subject = subject
        }
    }

    /// What a base-move card showed: the base branch, where it was (and how that's known), where it is, the commits
    /// between, and why the vault didn't take it.
    public struct Shown: Equatable, Sendable {
        /// How "from" is known: the head the vault recorded (`recorded`), the commit the user named (`given`), a
        /// snapshot's (E8: `unverified`), or not at all (`none`: the card lists the base's last commits).
        public enum From: String, Sendable { case recorded, given, unverified, none }

        public var branch: String
        public var from: String?
        public var fromIs: From
        public var to: String
        /// Newest first.
        public var commits: [Commit]
        public var reason: String?
        /// The move the look found (nil for `show`'s card).
        public var move: LeadVault.BaseMove?

        public init(branch: String, from: String?, fromIs: From, to: String, commits: [Commit], reason: String? = nil,
                    move: LeadVault.BaseMove? = nil) {
            self.branch = branch
            self.from = from
            self.fromIs = fromIs
            self.to = to
            self.commits = commits
            self.reason = reason
            self.move = move
        }

        /// Nothing to accept: the base is at the head the vault recorded. Never a card: on 2026-11-23 each `approve`
        /// drew one such card per project ("from 2ccf4f6d… (recorded) to 2ccf4f6d…"), each superseding the last, and
        /// left it open. (A commit given that is the tip still makes one: its accept records the head, as a first one.)
        public var unmoved: Bool { fromIs == .recorded && from == to }

        init(_ move: LeadVault.BaseMove) {
            self.init(branch: move.branch, from: move.from, fromIs: .recorded, to: move.to,
                      commits: move.commits.map { Commit(sha: $0.sha, subject: $0.subject) }, reason: move.reason, move: move)
        }
    }

    /// Who took a move.
    public enum Taker: Equatable, Sendable {
        /// The vault, from the user's sessions' hooks.
        case vault
        /// The user, with `base accept`.
        case you
    }

    public enum Outcome: Equatable, Sendable {
        /// Where the lead left it (or nothing to tell).
        case still
        /// The vault took it as the user's.
        case taken(LeadVault.BaseMove)
        /// A command of the user's that may account for it is still running.
        case waiting
        /// Asked about.
        case ask(LeadVault.BaseMove)
    }

    /// The move waiting for the user's answer, by root. On `main`'s queue.
    public private(set) var asking: [String: LeadVault.BaseMove] = [:]
    /// What went wrong taking one the user accepted, by root.
    public private(set) var failures: [String: String] = [:]

    private let vault: LeadVault
    private let reads: BoardReads
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    /// A move to ask about appeared.
    public var onAsk: (String, LeadVault.BaseMove) -> Void = { _, _ in }
    /// A move was taken (the lead hears it when the user took it: its merges go ahead now).
    public var onTaken: (String, LeadVault.BaseMove, Taker) -> Void = { _, _, _ in }
    /// The server's log.
    public var log: (String) -> Void = { _ in }
    /// Each root whose files were stamped, on the thread that stamped them (for tests).
    public var stamped: (String) -> Void = { _ in }

    /// Each root's base branch, and its reflog's and workflow.md's stamps at the last look: looked at again when one
    /// changed, a command was still running, or every `period`.
    private var branches: [String: String] = [:]
    private var stamps: [String: Stamps] = [:]
    private var lookedAt: [String: Date] = [:]
    private var looking: Set<String> = []
    /// The moves the user kept refused (root → the commit it moved to): not asked again.
    private var kept: [String: String] = [:]
    /// How often a base is looked at with nothing changed.
    public static let period: TimeInterval = 30

    struct Stamps: Equatable {
        var reflog: BoardFiles.Stamp?
        var workflow: BoardFiles.Stamp?
    }

    public init(vault: LeadVault, reads: BoardReads,
                background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
                main: @escaping (@escaping () -> Void) -> Void) {
        self.vault = vault
        self.reads = reads
        self.background = background
        self.main = main
    }

    /// The leads' roots, at each refresh. The reflog's and workflow.md's stamps are taken off the engine's queue.
    public func look(_ roots: Set<String>, now: Date = Platform.Clock.steadyDate()) {
        if !Set(asking.keys).isSubset(of: roots) { asking = asking.filter { roots.contains($0.key) } }
        for root in roots where !looking.contains(root) {
            let (known, last) = (branches[root], stamps[root])
            let due = lookedAt[root].map { now.timeIntervalSince($0) >= Self.period } ?? true
            looking.insert(root)
            background { [vault] in
                guard due || known.map({ self.stamps(root: root, branch: $0) }) != last else {
                    return self.main { self.looking.remove(root) }
                }
                let branch = Self.base(root: root)
                let outcome = Self.check(vault: vault, root: root, branch: branch)
                let stamps = outcome == .waiting ? nil : self.stamps(root: root, branch: branch)
                self.main {
                    self.lookedAt[root] = now
                    self.looked(root, branch: branch, outcome, stamps: stamps)
                }
            }
        }
    }

    /// Asks the vault about the base's move, if it moved.
    public static func check(vault: LeadVault, root: String, branch: String) -> Outcome {
        guard vault.headMoved(root: root, branch: branch) != nil, let move = try? vault.acceptMove(root: root, branch: branch) else { return .still }
        if move.accepted { return move.from == move.to ? .still : .taken(move) }
        if move.waiting == true { return .waiting }
        return .ask(move)
    }

    /// What a look found, on `main`'s queue, with the stamps it took after (nil: none, while a command still runs).
    func looked(_ root: String, branch: String, _ outcome: Outcome, stamps taken: Stamps?) {
        looking.remove(root)
        branches[root] = branch
        // Still running: look again at the next refresh, whatever the reflog says.
        guard outcome != .waiting, let taken else { return }
        stamps[root] = taken
        switch outcome {
        case .still, .waiting:
            asking[root] = nil
            note(nil, root)
        case .taken(let move):
            asking[root] = nil
            note(nil, root)
            tell(root, move, .vault)
            onTaken(root, move, .vault)
        case .ask(let move):
            guard kept[root] != move.to, asking[root] != move else { return }
            let new = asking[root]?.to != move.to
            asking[root] = move
            note(LeadVault.BaseMoveNote(branch: move.branch, from: move.from, to: move.to, state: .asking, commits: move.commits.count, reason: move.reason), root)
            if new {
                log("lead: \(move.branch) moved to \(move.to.prefix(8)) (left at \(move.from.prefix(8))), not taken: \(move.reason ?? ""); asking")
                onAsk(root, move)
            }
        }
    }

    /// The user took the move the card showed: the vault's head is where it moved to (the commits shown, no further).
    /// `done` hears on `main`'s queue whether it was recorded (nil) or why not.
    public func accept(_ root: String, move: LeadVault.BaseMove? = nil, done: @escaping (String?) -> Void = { _ in }) {
        guard let move = move ?? asking[root] else { return done("no move of \(LeadMail.project(of: root))'s base waits for you") }
        asking[root] = nil
        failures[root] = nil
        background { [vault] in
            do {
                try vault.setHead(move.to, root: root, branch: move.branch)
                self.main {
                    self.note(nil, root)
                    self.tell(root, move, .you)
                    self.onTaken(root, move, .you)
                    done(nil)
                }
            } catch {
                self.main {
                    self.failures[root] = "\(error)"
                    self.asking[root] = move
                    done("\(error)")
                }
            }
        }
    }

    /// The user keeps the lead's merges refused: not asked again about this move.
    public func keepRefused(_ root: String, move: LeadVault.BaseMove? = nil) {
        guard let move = move ?? asking[root] else { return }
        asking[root] = nil
        kept[root] = move.to
        failures[root] = nil
        note(LeadVault.BaseMoveNote(branch: move.branch, from: move.from, to: move.to, state: .kept, commits: move.commits.count, reason: move.reason), root)
        log("lead: the user kept \(move.branch) at \(move.to.prefix(8)) refused")
    }

    /// The board's updates and progress, and the log, say what was taken.
    private func tell(_ root: String, _ move: LeadVault.BaseMove, _ taker: Taker) {
        let commits = move.commits.prefix(3).map { "\($0.sha.prefix(7)) \($0.subject)" }.joined(separator: "; ") + (move.commits.count > 3 ? "; …" : "")
        let line: String
        switch taker {
        case .vault: line = move.acceptedLine
        case .you: line = "You accepted \(move.count) on \(move.branch) from the command line: " + commits
        }
        log("lead: \(line) (\(move.from.prefix(8)) → \(move.to.prefix(8)))")
        let store = BoardStore(root: root)
        reads.async { _ in
            try? store.update { $0.updates.append(LeadUpdate(title: "Took \(move.count) on \(move.branch)", body: line)) }
            try? store.appendProgress(line)
        }
    }

    /// What the lead's merge says about the move (nil: nothing to say), written on the reads queue.
    private func note(_ note: LeadVault.BaseMoveNote?, _ root: String) {
        reads.async { _ in
            if let note {
                try? note.save(root: root)
            } else {
                LeadVault.BaseMoveNote.clear(root: root)
                LeadVault.BaseMoveRefusal.clear(root: root)
            }
        }
    }

    /// The branch the lead merges into, as its tools resolve it.
    public static func base(root: String) -> String {
        let store = BoardStore(root: root)
        return LeadWorkflow.load(from: ConfigHoldStore.workflowPath(root: root)).baseBranch ?? store.load().baseBranch ?? Worktrees.mainBranch(root: root)
    }

    /// Where git logs the branch's moves, in a main checkout.
    static func reflog(root: String, branch: String) -> String {
        (root as NSString).appendingPathComponent(".git/logs/refs/heads/\(branch)")
    }

    private func stamps(root: String, branch: String) -> Stamps {
        stamped(root)
        return Stamps(reflog: BoardFiles.Stamp(Self.reflog(root: root, branch: branch)), workflow: BoardFiles.Stamp(ConfigHoldStore.workflowPath(root: root)))
    }

    // MARK: base show

    /// How many of the base's commits a card lists when it knows no "from".
    public static let unknownFromCommits = 20

    /// The card `base show FOLDER [--from COMMIT]` makes (S7, E8), also with no lead running: the base is
    /// `workflow.md`'s `base_branch`, read only while its hash is the one the user's `config accept` recorded
    /// (`ConfigHoldStore.baseBranchKey`); "from" is the commit given, else the head the vault records, else the head the
    /// snapshot of the last `base accept` keeps for the branch (`snapshotHeads`, E8: after a host restart, whose vault
    /// lost it), marked unverified (a worker can rewrite the snapshot), else none (the card lists the base's last
    /// `unknownFromCommits` commits and says so). A refusal says why. Reads git and the vault.
    public static func show(root: String, from given: String?, vault: LeadVault, snapshotHeads: [String: String] = [:]) -> Result<Shown, ShowRefusal> {
        let workflow = LeadWorkflow.load(from: ConfigHoldStore.workflowPath(root: root))
        let record: [String: String]?
        do { record = try vault.guardedRecord(root: root) } catch { return .failure(.init("the vault can't be asked about \(root): \(error)")) }
        let named = workflow.baseBranch ?? ""
        guard let recorded = record?[ConfigHoldStore.baseBranchKey] else {
            return .failure(.init("workflow.md's base branch isn't accepted yet: run `vibeswitcher config held` and `config accept` first"))
        }
        guard recorded == LeadVault.hash(named) else {
            return .failure(.init("workflow.md's base_branch changed since the user accepted it: run `vibeswitcher config held` and `config accept` again"))
        }
        let branch = named.isEmpty ? Worktrees.mainBranch(root: root) : named
        let head = Git.run(["rev-parse", "--verify", "refs/heads/\(branch)"], in: root)
        guard head.ok, !head.output.isEmpty else { return .failure(.init("\(branch) isn't a branch of \(root)")) }
        var from: String?
        var fromIs = Shown.From.none
        if let given {
            let resolved = Git.run(["rev-parse", "--verify", given + "^{commit}"], in: root)
            guard resolved.ok, !resolved.output.isEmpty else { return .failure(.init("\(given) isn't a commit of \(root)")) }
            from = resolved.output
            fromIs = .given
        } else if let recordedHead = try? vault.head(root: root, branch: branch) {
            from = recordedHead
            fromIs = .recorded
        } else if let kept = snapshotHeads[branch], Git.run(["rev-parse", "--verify", "--quiet", kept + "^{commit}"], in: root).ok {
            from = kept
            fromIs = .unverified
        }
        let range = from.map { ["\($0)..\(head.output)"] } ?? ["-n", String(unknownFromCommits), head.output]
        let log = Git.run(["log", "--format=%H%x09%s"] + range, in: root)
        guard log.ok else { return .failure(.init("git log of \(branch) didn't read: \(log.error)")) }
        let commits = log.output.split(whereSeparator: \.isNewline).map { line -> Commit in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return Commit(sha: parts.first ?? "", subject: parts.count > 1 ? parts[1] : "")
        }
        var reason: String?
        if let from, Git.run(["merge-base", "--is-ancestor", from, head.output], in: root).status != 0 {
            reason = "\(branch) at \(head.output.prefix(8)) doesn't descend from \(from.prefix(8)): it was rewritten"
        }
        if fromIs == .none { reason = "no head is recorded for \(branch) and none was given: the last \(unknownFromCommits) commits are listed" }
        if fromIs == .unverified {
            reason = (reason.map { $0 + "; " } ?? "") + "the vault records no head for \(branch) (a host restart erases it): \(from?.prefix(8) ?? "") is the head "
                + "your last `base accept` recorded, from an unsealed snapshot a worker could rewrite, so check the commits listed against it"
        }
        return .success(Shown(branch: branch, from: from, fromIs: fromIs, to: head.output, commits: from == head.output ? [] : commits, reason: reason))
    }

    public struct ShowRefusal: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }
}
