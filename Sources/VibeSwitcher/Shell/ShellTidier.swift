import AppKit
import Foundation
import VibeCore

/// Ends the shells Run cards opened once they're finished and nobody uses them (`ShellTidy`): every `interval` it looks
/// at the host's sessions and ends, as End Session does, each Run-card shell whose command exited 0 ten minutes ago or
/// more, that is back at its prompt, wasn't typed into since and whose command left nothing running. The session then shows under Ended, its output still
/// there. A failed command's shell, one that was typed into, and any session no Run card started are left alone.
///
/// Typed into (`typed`, told by `HostClient.onInput` for everything sent to a session but the terminal's own answers):
/// kept in `file`, so a shell the user took over stays theirs across a restart of the app.
///
/// The sidebar's Close Finished Shells… (`close`): after one confirmation that lists them, ends every Run-card shell
/// of a project that is back at its prompt, a failed or typed-into one too.
final class ShellTidier {
    /// What Close Finished Shells… asks before it ends anything, or says when there's nothing to end (`button` nil).
    struct Question: Equatable {
        var message: String
        var detail: String
        var button: String?
    }

    /// A finished shell nobody touched is ended this long after its command went well.
    var endAfter = ShellTidy.idleFor
    /// The host's sessions (main thread).
    var sessions: () -> [HostSession] = { [] }
    /// The session's shell is at its prompt.
    var idle: (HostSession) -> Bool = ShellTidy.idle
    /// The session's command left something running (a server, a tunnel) that ending it would end too.
    var leftRunning: (HostSession, ShellTidy.Ending) -> Bool = ShellTidy.leftRunning
    /// Ends the session, as End Session does (main thread).
    var end: (UUID) -> Void = { _ in }
    /// Asks the question (main thread): whether to go on. One without a button only says something.
    var ask: (Question) -> Bool = ShellTidier.alert

    let file: URL
    let now: () -> Date
    let log: (String) -> Void
    /// The Run-card shells typed into since their command ended.
    private(set) var used: Set<UUID>
    private var timer: DispatchSourceTimer?
    /// A look from the timer is going on off the main thread (main thread): the next tick waits for it.
    private var looking = false
    private static let lookQueue = DispatchQueue(label: "vibeswitcher.shell-tidier.look", qos: .utility)

    init(file: URL = VibePaths.root.appendingPathComponent("shell-requests/used.json"), now: @escaping () -> Date = { Date() },
         log: @escaping (String) -> Void = { Breadcrumbs.shared.note("shell: " + $0) }) {
        self.file = file
        self.now = now
        self.log = log
        let kept = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([UUID].self, from: $0) }
        used = Set(kept ?? [])
    }

    func start(interval: TimeInterval = 30) {
        guard timer == nil else { return }
        let ticks = DispatchSource.makeTimerSource(queue: .main)
        ticks.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        ticks.setEventHandler { [weak self] in self?.lookOffMain() }
        ticks.resume()
        timer = ticks
    }

    func close() {
        timer?.cancel()
        timer = nil
    }

    /// Something was sent to the session's program (main thread): a Run-card shell whose command has ended is the
    /// user's from then on, and is never ended by itself. What's typed while the command runs is the command's.
    func typed(_ id: UUID) {
        guard !used.contains(id), let session = sessions().first(where: { $0.id == id }), ShellTidy.ending(of: session) != nil else { return }
        used.insert(id)
        log("\(id.uuidString.prefix(8)) was typed into after its command ended: it stays until closed")
        save()
    }

    /// What a look needs of the main thread's state: the sessions, as they were then.
    private func snapshot() -> (sessions: [HostSession], used: Set<UUID>, now: Date) {
        let all = sessions()
        // A record of a session that has ended, or that the host no longer has, is dropped (not while the host's
        // sessions aren't known: none listed).
        let live = Set(all.filter(\.isLive).map(\.id))
        if !all.isEmpty, !used.isSubset(of: live) {
            used.formIntersection(live)
            save()
        }
        return (all, used, now())
    }

    /// Ends `due` (main thread), as End Session does.
    private func endDue(_ due: [HostSession], at now: Date) {
        for session in due {
            log("\(session.id.uuidString.prefix(8)) (\(session.label)) ended by itself: its command went well "
                + "\(Durations.short(now.timeIntervalSince(ShellTidy.ending(of: session)?.at ?? now))) ago and nobody used it since")
            end(session.id)
        }
    }

    /// Ends what's due now, the look on the calling thread (main thread); the sessions it ended. The timer's looks go
    /// through `lookOffMain` instead: reading the process table is not for the main thread.
    @discardableResult
    func look() -> [UUID] {
        let seen = snapshot()
        let due = ShellTidy.due(seen.sessions, used: seen.used, now: seen.now, after: endAfter, idle: idle, leftRunning: leftRunning)
        endDue(due, at: seen.now)
        return due.map(\.id)
    }

    /// `look`, its process-table reads (`idle`, `leftRunning`: each walks the table) on a queue of their own; only the
    /// sessions' list and the ending come back to the main thread (main thread). Calls `done` there with the sessions
    /// it ended. A look still going on isn't started again.
    func lookOffMain(done: @escaping ([UUID]) -> Void = { _ in }) {
        guard !looking else { return done([]) }
        looking = true
        let seen = snapshot()
        let after = endAfter, idle = idle, leftRunning = leftRunning
        Self.lookQueue.async { [weak self] in
            let due = ShellTidy.due(seen.sessions, used: seen.used, now: seen.now, after: after, idle: idle, leftRunning: leftRunning)
            DispatchQueue.main.async {
                guard let self else { return done([]) }
                self.looking = false
                // Typed into, or ended some other way, while the table was read: not ended now.
                let current = self.sessions()
                let still = due.filter { session in !self.used.contains(session.id) && current.contains { $0.id == session.id && $0.isLive } }
                self.endDue(still, at: self.now())
                done(still.map(\.id))
            }
        }
    }

    /// The Run-card shells among `rows` that Close Finished Shells… would end now.
    func finished(among rows: [WindowRow]) -> [HostSession] {
        let ids = Set(rows.compactMap { row -> UUID? in if case .hosted(let info) = row.content { return info.id } else { return nil } })
        return ShellTidy.finished(sessions().filter { ids.contains($0.id) }, idle: idle)
    }

    /// Close Finished Shells… for `project`, whose sessions are `rows` (main thread): asks once, listing them, then
    /// ends each that is still finished then. The sessions it ended.
    @discardableResult
    func close(project: String, rows: [WindowRow]) -> [UUID] {
        let found = finished(among: rows)
        let question = Self.question(project: project, shells: found, opened: rows.filter { $0.hosted.map { $0.isLive && ShellTidy.opened($0) } == true }.count,
                                     names: Self.names(rows), now: now())
        guard ask(question), question.button != nil else { return [] }
        // Asked a while ago, perhaps: only what's still at its prompt.
        let still = Set(finished(among: rows).map(\.id))
        let ending = found.filter { still.contains($0.id) }
        for session in ending {
            log("\(session.id.uuidString.prefix(8)) (\(session.label)) ended by Close Finished Shells")
            end(session.id)
        }
        return ending.map(\.id)
    }

    static func names(_ rows: [WindowRow]) -> [UUID: String] {
        Dictionary(rows.compactMap { row in row.hostID.map { ($0, row.title) } }, uniquingKeysWith: { first, _ in first })
    }

    /// What's asked before `shells` are ended, each on a line with how its command ended; with none, what's said
    /// instead (`opened`: the project's live Run-card shells, busy ones included).
    static func question(project: String, shells: [HostSession], opened: Int, names: [UUID: String], now: Date) -> Question {
        guard !shells.isEmpty else {
            let busy = opened == 0 ? "No session here was opened from an agent's Run card."
                : opened == 1 ? "The one shell an agent opened here is running a program." : "The \(opened) shells agents opened here are each running a program."
            return Question(message: "No finished shells in “\(project)”", detail: busy + " Shells you opened yourself are never closed by this.", button: nil)
        }
        let lines = shells.map { session -> String in
            let name = names[session.id] ?? session.label
            guard let ending = ShellTidy.ending(of: session) else { return "\(name): at its prompt" }
            return "\(name): command \(ending.ok ? "finished" : "failed") \(Durations.short(now.timeIntervalSince(ending.at))) ago"
        }
        let count = shells.count == 1 ? "the finished shell" : "\(shells.count) finished shells"
        return Question(message: "Close \(count) in “\(project)”?",
                        detail: lines.joined(separator: "\n") + "\n\nEach was opened by an agent and is back at its prompt. Closing ends the shell and "
                            + "anything it left running; it stays under Ended, where its output can still be read.",
                        button: shells.count == 1 ? "Close Shell" : "Close \(shells.count) Shells")
    }

    /// The question as an alert; true when its button was pressed.
    static func alert(_ question: Question) -> Bool {
        let alert = NSAlert()
        alert.messageText = question.message
        alert.informativeText = question.detail
        if let button = question.button {
            alert.addButton(withTitle: button).hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn && question.button != nil
    }

    private func save() {
        do {
            try VibePaths.ensurePrivate(file.deletingLastPathComponent())
            try VibePaths.writePrivate(JSONEncoder().encode(used.sorted { $0.uuidString < $1.uuidString }), to: file)
        } catch {
            log("couldn't record the shells typed into: \(error)")
        }
    }
}
