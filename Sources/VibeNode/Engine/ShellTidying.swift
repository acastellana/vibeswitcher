import Foundation
import VibeCore

/// The node's Run-card shell tidier (the app's `ShellTidier`, the feature review of 2026-11-22): a shell an agent's Run
/// card opened (`ShellCards.swift`, `ShellTidy.opened`) stays open as an interactive shell when its command ends, so
/// every request left a session. Every `shellTidyEvery` s the engine ends, as `end` does, each Run-card shell of the
/// node's whose command exited 0 at least `ShellTidy.idleFor` ago, that is back at its prompt, that nothing was typed
/// into since its command ended, and whose command left nothing running (`ShellTidy.due`, the app's rules). A failed
/// command's shell, one typed into after its end, a lead's or its team's, and any session no Run card started are left
/// alone; it then shows under ended, its output there to read.
///
/// Typed into: what `HostLink.onTyped` tells (`send`, `reply`, an answer typed, a page's terminal): kept in
/// `<root>/shell-requests/used.json`, so a shell the user took over stays theirs across a restart of the server.
extension LeadEngine {
    static let shellTidyEvery = 30

    var shellUsedFile: URL { root.appendingPathComponent("shell-requests/used.json") }

    /// The record of typed-into shells, read once. On `queue`.
    func loadShellUsed() {
        guard !shellUsedLoaded else { return }
        shellUsedLoaded = true
        let kept = (try? Data(contentsOf: shellUsedFile)).flatMap { $0.count < 256 * 1024 ? try? JSONDecoder().decode([UUID].self, from: $0) : nil }
        shellUsed = Set(kept ?? [])
    }

    private func saveShellUsed() {
        let file = shellUsedFile
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(shellUsed.sorted { $0.uuidString < $1.uuidString }).write(to: file, options: .atomic)
        } catch {
            note("shell tidy: the record of shells typed into wasn't written: \(error)")
        }
    }

    /// Something is typed into `id` (`HostLink.onTyped`): a Run-card shell whose command has ended is the user's from
    /// then on. What's typed while the command runs is the command's. On `queue`.
    func shellTyped(_ id: UUID) {
        loadShellUsed()
        guard !shellUsed.contains(id), let session = link.sessions.first(where: { $0.id == id }), ShellTidy.ending(of: session) != nil else { return }
        shellUsed.insert(id)
        note("shell tidy: \(id.uuidString.prefix(8)) was typed into after its command ended: it stays until closed")
        saveShellUsed()
    }

    /// The tidier's look: the due shells found off `queue` (each reads the process table), then each still live and not
    /// typed into meanwhile ended. `done` on `queue` with those ended. A look under way: at once, none. On `queue`.
    func tidyShells(idle: @escaping (HostSession) -> Bool = ShellTidy.idle,
                    leftRunning: @escaping (HostSession, ShellTidy.Ending) -> Bool = ShellTidy.leftRunning,
                    done: (([UUID]) -> Void)? = nil) {
        loadShellUsed()
        guard !shellTidying else { done?([]); return }
        let sessions = link.sessions
        // A record of a session that has ended, or that the host no longer has, goes (not while it lists none).
        let live = Set(sessions.filter(\.isLive).map(\.id))
        if !sessions.isEmpty, !shellUsed.isSubset(of: live) {
            shellUsed.formIntersection(live)
            saveShellUsed()
        }
        let candidates = sessions.filter(Requests.isNodeShell)
        guard candidates.contains(where: { ShellTidy.ending(of: $0)?.ok == true }) else { done?([]); return }
        shellTidying = true
        let (used, now) = (shellUsed, shellNow())
        shellWork.async { [weak self] in
            let due = ShellTidy.due(candidates, used: used, now: now, idle: idle, leftRunning: leftRunning)
            self?.queue.async {
                guard let self else { return }
                self.shellTidying = false
                let still = due.filter { session in
                    !self.shellUsed.contains(session.id) && self.link.sessions.contains { $0.id == session.id && $0.isLive }
                }
                for session in still {
                    let ago = ShellTidy.ending(of: session).map { Durations.short(now.timeIntervalSince($0.at)) } ?? "a while"
                    self.note("shell tidy: \(session.id.uuidString.prefix(8)) (\(session.label)) ended by itself: its command went well \(ago) ago and nobody used it since")
                    self.link.kill(session.id)
                }
                done?(still.map(\.id))
            }
        }
    }
}
