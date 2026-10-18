import Foundation
import VibeCore

/// Each lead's base, watched: when it moved since the lead last left it, and not through its merges, the session host's
/// vault is asked to take the move as the user's own (`LeadVault.judge`). When it can't (a commit no session of yours
/// is seen making, a rewrite, a team member's), the window asks you, once per move, listing what came in: Accept
/// takes the base as it is in the vault, with the lead and its team running on; Keep Refused leaves the lead's merges
/// refused. Only this, the app's own process, takes a move on your word.
final class BaseMoves: ObservableObject {
    /// The move waiting for your answer, by repository root.
    @Published private(set) var asking: [String: LeadVault.BaseMove] = [:]
    /// What went wrong taking one you accepted, by root.
    @Published private(set) var failures: [String: String] = [:]

    enum Outcome: Equatable {
        /// Where the lead left it (or nothing to tell).
        case still
        /// The vault took it as yours.
        case taken(LeadVault.BaseMove)
        /// A command of yours that may account for it is still running.
        case waiting
        case ask(LeadVault.BaseMove)
    }

    private let vault: LeadVault
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    /// A move to ask about appeared (to tell you once, outside the window too).
    var onAsk: (String, LeadVault.BaseMove) -> Void = { _, _ in }
    /// A move was taken, by the vault or by you: the lead hears it (its merges go ahead now).
    var onTaken: (String, LeadVault.BaseMove, _ byYou: Bool) -> Void = { _, _, _ in }
    /// app.log.
    var log: (String) -> Void = { Breadcrumbs.shared.note($0) }

    /// Each root's base branch and its reflog's stamp at the last look: looked at again only when that changed, a
    /// command was still running, or (every 30 s) while it asks or the reflog can't be found.
    private var branches: [String: String] = [:]
    private var stamps: [String: LeadFiles.Stamp] = [:]
    private var lookedAt: [String: Date] = [:]
    private var looking: Set<String> = []
    /// The moves you kept refused (root → the commit it moved to): not asked again.
    private var kept: [String: String] = [:]

    init(vault: LeadVault = .standard,
         background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.vault = vault
        self.background = background
        self.main = main
    }

    /// The leads' roots, every few seconds (the lead controller's refresh).
    func look(_ roots: Set<String>, now: Date = Date()) {
        if !Set(asking.keys).isSubset(of: roots) { asking = asking.filter { roots.contains($0.key) } }
        for root in roots where !looking.contains(root) {
            let stamp = branches[root].flatMap { LeadFiles.Stamp(Self.reflog(root: root, branch: $0)) }
            let due = lookedAt[root].map { now.timeIntervalSince($0) >= 30 } ?? true
            guard stamp == nil || stamp != stamps[root] || (asking[root] != nil && due) else { continue }
            if stamp == nil, !due { continue }
            looking.insert(root)
            lookedAt[root] = now
            background { [vault] in
                let branch = Self.base(root: root)
                let outcome = Self.check(vault: vault, root: root, branch: branch)
                self.main { self.looked(root, branch: branch, outcome) }
            }
        }
    }

    /// Asks the vault about the base's move, if it moved.
    static func check(vault: LeadVault, root: String, branch: String) -> Outcome {
        guard vault.headMoved(root: root, branch: branch) != nil, let move = try? vault.acceptMove(root: root, branch: branch) else { return .still }
        if move.accepted { return move.from == move.to ? .still : .taken(move) }
        return move.waiting == true ? .waiting : .ask(move)
    }

    func looked(_ root: String, branch: String, _ outcome: Outcome) {
        looking.remove(root)
        branches[root] = branch
        // Still running: look again at the next refresh, whatever the reflog says.
        guard outcome != .waiting else { return }
        stamps[root] = LeadFiles.Stamp(Self.reflog(root: root, branch: branch))
        switch outcome {
        case .still, .waiting:
            asking[root] = nil
        case .taken(let move):
            asking[root] = nil
            tell(root, move, byYou: false)
            onTaken(root, move, false)
        case .ask(let move):
            guard kept[root] != move.to, asking[root] != move else { return }
            let new = asking[root]?.to != move.to
            asking[root] = move
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
                    self.tell(root, move, byYou: true)
                    self.onTaken(root, move, true)
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
        log("lead: you kept \(move.branch) at \(move.to.prefix(8)) refused")
    }

    /// The board's updates and progress, and app.log, say what was taken.
    private func tell(_ root: String, _ move: LeadVault.BaseMove, byYou: Bool) {
        let line = byYou ? "You accepted \(move.count) on \(move.branch) in VibeSwitcher: "
            + move.commits.prefix(3).map { "\($0.sha.prefix(7)) \($0.subject)" }.joined(separator: "; ") + (move.commits.count > 3 ? "; …" : "")
            : move.acceptedLine
        log("lead: \(line) (\(move.from.prefix(8)) → \(move.to.prefix(8)))")
        let store = BoardStore(root: root)
        try? store.update { $0.updates.append(LeadUpdate(title: "Took \(move.count) on \(move.branch)", body: line)) }
        try? store.appendProgress(line)
    }

    /// The branch the lead merges into, as its tools resolve it.
    static func base(root: String) -> String {
        let store = BoardStore(root: root)
        return LeadWorkflow.load(from: (store.folder as NSString).appendingPathComponent("workflow.md")).baseBranch
            ?? store.load().baseBranch ?? Worktrees.mainBranch(root: root)
    }

    /// Where git logs the branch's moves, in a main checkout.
    static func reflog(root: String, branch: String) -> String {
        (root as NSString).appendingPathComponent(".git/logs/refs/heads/\(branch)")
    }
}
