import Foundation
import VibeCore

/// A replaced lead ends (2026-11-22: on the real node three replaced lead sessions of one project lived beside the
/// current lead, each with its tool server, two on an older build, all left by rotations and resumes; their auto_advance
/// still posted on the board, and one on an old build could have merged or audited through that build's gate). A
/// rotation (`IdleHandover`), a start that replaces the lead (`lead --replace`, a resume) and the board naming another
/// session all leave the old one marked replaced (`LeadStore.Lead.replaced`). This build's tool server refuses a
/// replaced lead's calls and its auto_advance passes (the vault no longer names its session: `LeadToolset.authenticate`,
/// `withdrawn`), but an older build's may not, and its session keeps memory, a slot and its tool server.
///
/// So once the project's current lead is up (live, and the vault binds the lead's role to it, asked at that refresh), each
/// session still live that is marked replaced is ended, with its tool server (the host ends the session's processes).
/// Under the rotation gate, taken exclusively (`LeadRotation.gate`, which every merge, audit, revert and remote merge
/// holds shared for its whole call): never while any of them is under way; tried again at the next refresh. Each once,
/// said in the log and in the project's progress.md; the gate is let go once the ended sessions are no longer live, or
/// `endLimit` later.
extension LeadEngine {
    /// How long the gate stays taken after the replaced sessions were asked to end.
    static let replacedEndLimit: TimeInterval = 5

    /// Ends each project's replaced lead sessions once its current lead is up. On `queue`, at each refresh: the vault is
    /// asked who holds each such project's lead role off the queue (`reads`), and the sessions end back on it.
    func endReplacedLeads() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !replacedEndsHeld else { return }
        let live = Set(link.sessions.filter(\.isLive).map(\.id))
        endingReplaced.formIntersection(live)
        let due = leads.leads.values.filter { lead in
            guard let current = lead.session, live.contains(current) else { return false }
            return lead.replaced.keys.contains { $0 != current && live.contains($0) && !endingReplaced.contains($0) }
        }.map(\.root)
        guard !due.isEmpty else { return }
        let vault = cardVault
        reads.async({ _ in
            Dictionary(due.map { root in (root, vault.current(.lead, root: root, task: nil)?.session?.lowercased()) }, uniquingKeysWith: { first, _ in first })
        }) { [weak self] holders in
            self?.endReplaced(holders: holders)
        }
    }

    /// `holders`: who holds each project's lead role, as the vault said. On `queue`.
    private func endReplaced(holders: [String: String?]) {
        let live = Set(link.sessions.filter(\.isLive).map(\.id))
        for (root, holder) in holders {
            guard let lead = leads.leads[NodeIds.project(root: root)], let current = lead.session, live.contains(current),
                  holder == current.uuidString.lowercased() else { continue }
            let replaced = lead.replaced.keys.filter { $0 != current && live.contains($0) && !endingReplaced.contains($0) }.sorted { $0.uuidString < $1.uuidString }
            guard !replaced.isEmpty else { continue }
            let project = LeadMail.project(of: root)
            guard let gate = FileLock.attempt(LeadRotation.gate(root), shared: false) else {
                note("lead: \(project)'s replaced lead sessions wait to end: a merge or audit holds the rotation gate")
                continue
            }
            for id in replaced {
                endingReplaced.insert(id)
                link.kill(id)
                note("lead: ended \(project)'s replaced lead session \(id.uuidString.prefix(8)) and its tool server (the lead is session \(current.uuidString.prefix(8)))")
            }
            let ended = replaced.map { String($0.uuidString.prefix(8)) }.joined(separator: ", ")
            reads.async({ _ in
                try? BoardStore(root: root).appendProgress("Ended the replaced lead session\(replaced.count == 1 ? "" : "s") \(ended) and \(replaced.count == 1 ? "its tool server" : "their tool servers"): only the current lead acts")
            }) { _ in }
            releaseWhenEnded(gate, sessions: Set(replaced), until: Date().addingTimeInterval(Self.replacedEndLimit))
        }
    }

    private func releaseWhenEnded(_ gate: FileLock, sessions: Set<UUID>, until: Date) {
        if Date() >= until || !link.sessions.contains(where: { sessions.contains($0.id) && $0.isLive }) { return gate.release() }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return gate.release() }
            self.releaseWhenEnded(gate, sessions: sessions, until: until)
        }
    }
}
