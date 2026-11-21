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
/// of a project that is back at its prompt, a failed or typed-into one too. The sidebar's Close Finished (N)…
/// (`closeFinished`): the same, in every project, and the replaced leads between turns too (`CloseFinished`).
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
    /// The session's board names it as its project's lead (main thread): never ended as a replaced lead.
    var holdsRole: (UUID) -> Bool = { _ in false }

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

    /// What the sidebar's Close Finished (N)… would end now (`CloseFinished.items`): in every project, the finished
    /// Run-card shells and the replaced leads (`replaced`, by window session) between turns, among `rows`.
    func closable(rows: [WindowRow], replaced: Set<UUID>) -> [CloseFinished.Item] {
        CloseFinished.items(rows: rows, sessions: sessions(), replaced: replaced, holdsRole: holdsRole, idle: idle)
    }

    /// The sidebar's Close Finished (N)… (main thread): asks once, listing what it found in `rows()` (every project's
    /// rows) with `replaced()` the replaced leads, then ends, as End Session does, each that is still to close when
    /// the question is answered (both read again then): what changed since is skipped. The sessions it ended.
    @discardableResult
    func closeFinished(rows: () -> [WindowRow], replaced: () -> Set<UUID>) -> [UUID] {
        let found = closable(rows: rows(), replaced: replaced())
        let question = Self.question(closing: found, sessions: sessions(), now: now())
        guard ask(question), question.button != nil else { return [] }
        // Asked a while ago, perhaps: only what's still finished, and still a replaced lead between turns.
        let ending = CloseFinished.still(found, now: closable(rows: rows(), replaced: replaced()))
        for item in found where !ending.contains(item) {
            log("\(item.id.uuidString.prefix(8)) (\(item.name)) not closed by Close Finished: it changed since the question")
        }
        for item in ending {
            log("\(item.id.uuidString.prefix(8)) (\(item.name)) ended by Close Finished (\(item.kind == .shell ? "a finished shell" : "a replaced lead"))")
            end(item.id)
        }
        return ending.map(\.id)
    }

    /// What Close Finished (N)… asks before `items` are ended: grouped by project, its finished shells (each with how
    /// its command ended) and its replaced leads apart, each a bullet (an alert drops a line's leading spaces); with
    /// none, what's said instead.
    static func question(closing items: [CloseFinished.Item], sessions: [HostSession], now: Date) -> Question {
        guard !items.isEmpty else {
            return Question(message: "Nothing finished to close",
                            detail: "No shell an agent opened is back at its prompt, and no replaced lead is between turns. "
                                + "Shells you opened yourself, the leads holding their role, workers and verifiers are never closed by this.",
                            button: nil)
        }
        let hosted = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var projects: [String] = []
        for item in items where !projects.contains(item.project) { projects.append(item.project) }
        let groups = projects.map { project -> String in
            let mine = items.filter { $0.project == project }
            var lines = [project]
            let shells = mine.filter { $0.kind == .shell }, leads = mine.filter { $0.kind == .replacedLead }
            if !shells.isEmpty {
                lines.append(shells.count == 1 ? "Finished shell:" : "Finished shells:")
                lines += shells.map { item in
                    guard let ending = hosted[item.id].flatMap(ShellTidy.ending(of:)) else { return "• \(item.name): at its prompt" }
                    return "• \(item.name): command \(ending.ok ? "finished" : "failed") \(Durations.short(now.timeIntervalSince(ending.at))) ago"
                }
            }
            if !leads.isEmpty {
                lines.append(leads.count == 1 ? "Replaced lead:" : "Replaced leads:")
                lines += leads.map { "• \($0.name): between turns" }
            }
            return lines.joined(separator: "\n")
        }
        let shells = items.filter { $0.kind == .shell }.count, leads = items.count - shells
        let what = [shells == 0 ? nil : shells == 1 ? "1 finished shell" : "\(shells) finished shells",
                    leads == 0 ? nil : leads == 1 ? "1 replaced lead" : "\(leads) replaced leads"].compactMap { $0 }.joined(separator: " and ")
        var why: [String] = []
        if shells > 0 { why.append("Each shell was opened by an agent and is back at its prompt; closing it ends anything it left running too.") }
        if leads > 0 { why.append("Each replaced lead's role went to a newer lead, and its agent isn't in a turn.") }
        why.append("Anything that changed by the time you confirm stays. Ended sessions show under Ended, where their output can still be read.")
        return Question(message: "Close \(what)?", detail: groups.joined(separator: "\n\n") + "\n\n" + why.joined(separator: " "),
                        button: items.count == 1 ? "Close 1 Session" : "Close \(items.count) Sessions")
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
        let alert = makeAlert(question)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn && question.button != nil
    }

    /// The question's alert, not shown yet (the sandbox draws it).
    static func makeAlert(_ question: Question) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = question.message
        alert.informativeText = question.detail
        if let button = question.button {
            alert.addButton(withTitle: button).hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        return alert
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
