import Foundation
import VibeCore

/// The node's Run-card shell tidier (the app's `ShellTidier`, the feature review of 2026-11-22): a shell an agent's Run
/// card opened (the shell plugin, `Plugins/Shell/ShellPlugin.swift`; `ShellTidy.opened`) stays open as an interactive shell when its command ends, so
/// every request left a session. Every `shellTidyEvery` s the engine ends, as `end` does, each Run-card shell of the
/// node's whose command exited 0 at least `ShellTidy.idleFor` ago, that is back at its prompt, that nothing was typed
/// into since its command ended, and whose command left nothing running (`ShellTidy.due`, the app's rules). A failed
/// command's shell, one typed into after its end, a lead's or its team's, and any session no Run card started are left
/// alone; it then shows under ended, its output there to read.
///
/// Typed into: what `HostLink.onTyped` tells (`send`, `reply`, an answer typed, a page's terminal): kept in
/// `<root>/shell-requests/used.json`, so a shell the user took over stays theirs across a restart of the server. Its state is its own, on the engine's
/// queue; the record is read and written on its own queue.
final class ShellTidyWatch {
    static let every = 30

    private let queue: DispatchQueue
    private let link: HostLink
    private let note: (String) -> Void
    /// The record's file: `<root>/shell-requests/used.json`.
    let file: URL
    /// Its file is read and written here.
    private let work = DispatchQueue(label: "vibenode.lead-engine.shell-tidying", qos: .userInitiated)
    /// The shells typed into since their command ended (read once), whether a look is under way, the 30 s look.
    private var typedInto: Set<UUID> = []
    private var loaded = false
    private var tidying = false
    private var timer: Subscription?
    /// The clock a shell's idle time is judged by (a test's later).
    var now: () -> Date = Date.init

    init(queue: DispatchQueue, link: HostLink, root: URL, clock: NodeClock?, note: @escaping (String) -> Void) {
        self.queue = queue
        self.link = link
        self.note = note
        file = root.appendingPathComponent("shell-requests/used.json")
        timer = clock?.every(Self.every) { [weak self] in self?.queue.async { self?.tidy() } }
    }

    /// The shells typed into since their command ended. On the engine's queue.
    var used: Set<UUID> {
        EngineWatch.assertOn(queue)
        return typedInto
    }

    /// The record read again from its file (a test's restart of the server). On the engine's queue.
    func reload() {
        EngineWatch.assertOn(queue)
        loaded = false
        typedInto = []
        load()
    }

    /// The record of typed-into shells, read once. On the engine's queue.
    private func load() {
        guard !loaded else { return }
        loaded = true
        let kept = (try? Data(contentsOf: file)).flatMap { $0.count < 256 * 1024 ? try? JSONDecoder().decode([UUID].self, from: $0) : nil }
        typedInto = Set(kept ?? [])
    }

    private func save() {
        do {
            try VibePaths.ensurePrivate(file.deletingLastPathComponent())
            try VibePaths.writePrivate(JSONEncoder().encode(typedInto.sorted { $0.uuidString < $1.uuidString }), to: file)
        } catch {
            note("shell tidy: the record of shells typed into wasn't written: \(error)")
        }
    }

    /// Something is typed into `id` (`HostLink.onTyped`): a Run-card shell whose command has ended is the user's from
    /// then on. What's typed while the command runs is the command's. On the engine's queue.
    func typed(_ id: UUID) {
        EngineWatch.assertOn(queue)
        load()
        guard !typedInto.contains(id), let session = link.sessions.first(where: { $0.id == id }), ShellTidy.ending(of: session) != nil else { return }
        typedInto.insert(id)
        note("shell tidy: \(id.uuidString.prefix(8)) was typed into after its command ended: it stays until closed")
        save()
    }

    /// The tidier's look: the due shells found off the engine's queue (each reads the process table), then each still
    /// live and not typed into meanwhile ended. `done` on the engine's queue with those ended. A look under way: at
    /// once, none. On the engine's queue.
    func tidy(idle: @escaping (HostSession) -> Bool = ShellTidy.idle,
              leftRunning: @escaping (HostSession, ShellTidy.Ending) -> Bool = ShellTidy.leftRunning,
              done: (([UUID]) -> Void)? = nil) {
        EngineWatch.assertOn(queue)
        load()
        guard !tidying else { done?([]); return }
        let sessions = link.sessions
        // A record of a session that has ended, or that the host no longer has, goes (not while it lists none).
        let live = Set(sessions.filter(\.isLive).map(\.id))
        if !sessions.isEmpty, !typedInto.isSubset(of: live) {
            typedInto.formIntersection(live)
            save()
        }
        let candidates = sessions.filter(Requests.isNodeShell)
        guard candidates.contains(where: { ShellTidy.ending(of: $0)?.ok == true }) else { done?([]); return }
        tidying = true
        let (used, now) = (typedInto, now())
        work.async { [weak self] in
            let due = ShellTidy.due(candidates, used: used, now: now, idle: idle, leftRunning: leftRunning)
            self?.queue.async {
                guard let self else { return }
                self.tidying = false
                let still = due.filter { session in
                    !self.typedInto.contains(session.id) && self.link.sessions.contains { $0.id == session.id && $0.isLive }
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

extension LeadEngine {
    /// Something is typed into `id` (`ShellTidyWatch.typed`). On `queue`.
    func shellTyped(_ id: UUID) { shellTidy.typed(id) }

    /// The tidier's look now (`ShellTidyWatch.tidy`). On `queue`.
    func tidyShells(idle: @escaping (HostSession) -> Bool = ShellTidy.idle,
                    leftRunning: @escaping (HostSession, ShellTidy.Ending) -> Bool = ShellTidy.leftRunning,
                    done: (([UUID]) -> Void)? = nil) {
        shellTidy.tidy(idle: idle, leftRunning: leftRunning, done: done)
    }
}
