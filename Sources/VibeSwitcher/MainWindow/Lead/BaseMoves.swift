import Foundation
import VibeCore

/// Each lead's base, watched: when it moved since the lead last left it, and not through its merges, the session host's
/// vault is asked to take the move as the user's own (`LeadVault.judge`). When it can't, and a `!` git command you sent
/// from this window accounts for it (no team session's command could have made it), it's taken as yours too: only
/// this, the app's own process, saw you send it. Otherwise (a commit no session of yours is seen making, a rewrite, a
/// team member's) the window asks you, once per move, listing what came in: Accept takes the base as it is in the
/// vault, with the lead and its team running on; Keep Refused leaves the lead's merges refused. Only this process takes
/// a move on your word. What it does is noted for the lead's merge to say (`LeadVault.BaseMoveNote`).
final class BaseMoves: ObservableObject {
    /// The move waiting for your answer, by repository root.
    @Published private(set) var asking: [String: LeadVault.BaseMove] = [:]
    /// What went wrong taking one you accepted, by root.
    @Published private(set) var failures: [String: String] = [:]

    /// Who took a move.
    enum Taker: Equatable {
        /// The vault, from your sessions' hooks.
        case vault
        /// The window, from a git command you sent from it.
        case typed
        /// You, with Accept.
        case you
    }

    enum Outcome: Equatable {
        /// Where the lead left it (or nothing to tell).
        case still
        /// The vault took it as yours, or the window did from what you sent it (those lines, used up).
        case taken(LeadVault.BaseMove, Taker, used: [LeadVault.Typed])
        /// A command of yours that may account for it is still running.
        case waiting
        /// Asked about; the lines you sent that were looked at for it are used up all the same.
        case ask(LeadVault.BaseMove, used: [LeadVault.Typed] = [])
    }

    private let vault: LeadVault
    /// Where the boards are written (the lead controller's, see `LeadReads`): off the main thread, in order with its reads.
    private let reads: LeadReads
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    /// A move to ask about appeared (a card in the lead's chat; you're told outside the window only once it refuses a
    /// merge: `AlertRules.baseMoved`).
    var onAsk: (String, LeadVault.BaseMove) -> Void = { _, _ in }
    /// A move was taken: the lead hears it when the window or you took it (its merges go ahead now).
    var onTaken: (String, LeadVault.BaseMove, Taker) -> Void = { _, _, _ in }
    /// app.log.
    var log: (String) -> Void = { Breadcrumbs.shared.note($0) }

    /// Each root's base branch, and its reflog's and workflow.md's stamps at the last look: looked at again when one
    /// changed (workflow.md says which branch is the base), a command was still running, or every 30 s.
    private var branches: [String: String] = [:]
    private var stamps: [String: Stamps] = [:]
    private var lookedAt: [String: Date] = [:]
    private var looking: Set<String> = []
    /// The moves you kept refused (root → the commit it moved to): not asked again.
    private var kept: [String: String] = [:]
    /// The `!` git commands you sent from the window lately (see `typed`).
    private(set) var sent: [LeadVault.Typed] = []
    /// How long one is kept for a look to come (what it accounts for is `Typed.lasts` after it was sent), and used
    /// once: by the move it's looked at for, taken or asked about.
    static let typedFor: TimeInterval = 300

    struct Stamps: Equatable {
        var reflog: LeadFiles.Stamp?
        var workflow: LeadFiles.Stamp?
    }

    init(vault: LeadVault = .standard, reads: LeadReads = LeadReads(),
         background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.vault = vault
        self.reads = reads
        self.background = background
        self.main = main
    }

    /// You sent `text` from the window (the composer, or Run on a code block) into the session `session`, which runs
    /// in `cwd`: kept when it's a `!` line with a git command that can move a branch.
    func typed(_ text: String, session: String, cwd: String, at: Date = Date()) {
        let now = at.timeIntervalSince1970
        sent.removeAll { now - $0.at > Self.typedFor }
        guard let line = LeadVault.Typed.shell(text), !GitMoves.commands(in: line, cwd: cwd).isEmpty else { return }
        sent = Array((sent + [LeadVault.Typed(session: session, line: line, cwd: cwd, at: now)]).suffix(50))
    }

    /// The leads' roots, every few seconds (the lead controller's refresh). The reflog's and workflow.md's stamps are
    /// taken off the main thread too: a stat waited 3 s on a busy disk (hang-20261027-175604).
    func look(_ roots: Set<String>, now: Date = Date()) {
        if !Set(asking.keys).isSubset(of: roots) { asking = asking.filter { roots.contains($0.key) } }
        let typed = sent.filter { now.timeIntervalSince1970 - $0.at <= Self.typedFor }
        for root in roots where !looking.contains(root) {
            let (known, last) = (branches[root], stamps[root])
            let due = lookedAt[root].map { now.timeIntervalSince($0) >= 30 } ?? true
            looking.insert(root)
            background { [vault] in
                guard due || known.map({ self.stamps(root: root, branch: $0) }) != last else {
                    return self.main { self.looking.remove(root) }
                }
                let branch = Self.base(root: root)
                let outcome = Self.check(vault: vault, root: root, branch: branch, typed: typed, now: now)
                let stamps = outcome == .waiting ? nil : self.stamps(root: root, branch: branch)
                self.main {
                    self.lookedAt[root] = now
                    self.looked(root, branch: branch, outcome, stamps: stamps)
                }
            }
        }
    }

    /// Asks the vault about the base's move, if it moved; when it doesn't take it, whether what you sent from the
    /// window accounts for it.
    static func check(vault: LeadVault, root: String, branch: String, typed: [LeadVault.Typed] = [], now: Date = Date()) -> Outcome {
        guard vault.headMoved(root: root, branch: branch) != nil, let move = try? vault.acceptMove(root: root, branch: branch) else { return .still }
        if move.accepted { return move.from == move.to ? .still : .taken(move, .vault, used: []) }
        if move.waiting == true { return .waiting }
        // A team session's command could have made it: only you say so.
        guard move.team != true, !typed.isEmpty,
              let history = LeadVault.BaseHistory.read(root: root, branch: branch, since: move.from), history.head == move.to else { return .ask(move) }
        let at = now.timeIntervalSince1970
        let used = typed.filter { !LeadVault.runs(typed: [$0], root: root, branch: branch, recorded: move.from, head: history.head, now: at).isEmpty }
        let runs = LeadVault.runs(typed: used, root: root, branch: branch, recorded: move.from, head: history.head, now: at)
        let yours = LeadVault.judge(from: move.from, history: history, branch: branch, runs: runs, now: at, slack: 0)
        guard yours.accepted, (try? vault.setHead(yours.to, root: root, branch: branch)) != nil else { return .ask(move, used: used) }
        return .taken(yours, .typed, used: used)
    }

    /// What a look found, on the main thread, with the stamps it took after (nil: none, while a command still runs).
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
        case .taken(let move, let taker, let used):
            asking[root] = nil
            sent.removeAll { used.contains($0) }
            note(nil, root)
            tell(root, move, taker)
            onTaken(root, move, taker)
        case .ask(let move, let used):
            sent.removeAll { used.contains($0) }
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

    /// You took the move: the vault's head is where it moved to (the commits you were shown, no further).
    func accept(_ root: String) {
        guard let move = asking.removeValue(forKey: root) else { return }
        failures[root] = nil
        background { [vault] in
            do {
                try vault.setHead(move.to, root: root, branch: move.branch)
                self.main {
                    self.note(nil, root)
                    self.tell(root, move, .you)
                    self.onTaken(root, move, .you)
                }
            } catch {
                self.main {
                    self.failures[root] = "\(error)"
                    self.asking[root] = move
                }
            }
        }
    }

    /// You keep the lead's merges refused: not asked again about this move.
    func keepRefused(_ root: String) {
        guard let move = asking.removeValue(forKey: root) else { return }
        kept[root] = move.to
        failures[root] = nil
        note(LeadVault.BaseMoveNote(branch: move.branch, from: move.from, to: move.to, state: .kept, commits: move.commits.count, reason: move.reason), root)
        log("lead: you kept \(move.branch) at \(move.to.prefix(8)) refused")
    }

    /// The board's updates and progress, and app.log, say what was taken.
    private func tell(_ root: String, _ move: LeadVault.BaseMove, _ taker: Taker) {
        let commits = move.commits.prefix(3).map { "\($0.sha.prefix(7)) \($0.subject)" }.joined(separator: "; ") + (move.commits.count > 3 ? "; …" : "")
        let line: String
        switch taker {
        case .vault: line = move.acceptedLine
        case .typed: line = "accepted \(move.count) on \(move.branch) that you ran from VibeSwitcher's window: " + commits
        case .you: line = "You accepted \(move.count) on \(move.branch) in VibeSwitcher: " + commits
        }
        log("lead: \(line) (\(move.from.prefix(8)) → \(move.to.prefix(8)))")
        let store = BoardStore(root: root)
        reads.async { _ in
            try? store.update { $0.updates.append(LeadUpdate(title: "Took \(move.count) on \(move.branch)", body: line)) }
            try? store.appendProgress(line)
        }
    }

    /// What the lead's merge says about the move (nil: nothing to say), written on the lead controller's queue.
    private func note(_ note: LeadVault.BaseMoveNote?, _ root: String) {
        reads.async { _ in
            if let note {
                try? note.save(root: root)
            } else {
                LeadVault.BaseMoveNote.clear(root: root)
                // Taken, or back where the lead left it: no merge waits on you.
                LeadVault.BaseMoveRefusal.clear(root: root)
            }
        }
    }

    /// The branch the lead merges into, as its tools resolve it.
    static func base(root: String) -> String {
        let store = BoardStore(root: root)
        return LeadWorkflow.load(from: workflow(root: root)).baseBranch ?? store.load().baseBranch ?? Worktrees.mainBranch(root: root)
    }

    static func workflow(root: String) -> String {
        (BoardStore(root: root).folder as NSString).appendingPathComponent("workflow.md")
    }

    /// Where git logs the branch's moves, in a main checkout.
    static func reflog(root: String, branch: String) -> String {
        (root as NSString).appendingPathComponent(".git/logs/refs/heads/\(branch)")
    }

    /// Each root whose files were stamped, on the thread that stamped them (for tests).
    var stamped: (String) -> Void = { _ in }

    private func stamps(root: String, branch: String) -> Stamps {
        stamped(root)
        return Self.stamps(root: root, branch: branch)
    }

    static func stamps(root: String, branch: String) -> Stamps {
        Stamps(reflog: LeadFiles.Stamp(reflog(root: root, branch: branch)), workflow: LeadFiles.Stamp(workflow(root: root)))
    }
}
