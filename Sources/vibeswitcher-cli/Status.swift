import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher status [--json]`: the node as its server sees it (sessions, leads, cards, the user's-voice requests
/// it accepted, its notices, the host's notes), with what the command line reads itself (the engine plan's E1,
/// EN-D15): the machine's facts (`NodeFacts`, the standing plain-mode line first) and the journal (starts, stops and
/// server restarts nothing explains, until acknowledged; accepted requests the journal has no entry for; entries from
/// a cgroup that isn't a terminal's). With no node it exits 69, naming `status --probe`.
///
/// `vibeswitcher status --probe [--json]`: stage 1's local read, without the server: the agent sessions on this machine
/// (`LocalSessions`), one line each: terminal, agent, folder, status, since when.
///
/// `vibeswitcher status --ack`: acknowledges what the journal shows (a journal entry the command line writes after the
/// typed code), never a server request.
enum StatusCommand {
    static let usage = "usage: vibeswitcher status [--json] | status --probe [--json] | status --ack"

    /// The JSON form's version.
    static let format = 1

    static func run(_ arguments: [String]) -> Int32 {
        let words = Set(arguments)
        guard words.count == arguments.count, words.isSubset(of: ["--json", "--probe", "--ack"]),
              !(words.contains("--ack") && words.count > 1) else { return Say.usage(usage) }
        if words.contains("--probe") { return probe(json: words.contains("--json")) }
        if words.contains("--ack") { return acknowledge() }
        return throughServer(json: words.contains("--json"))
    }

    /// Stage 1's read, as it was.
    static func probe(json asJSON: Bool) -> Int32 {
        guard let sessions = LocalSessions().read() else {
            try? FileHandle.standardError.write(contentsOf: Data("vibeswitcher: the process table couldn't be read; try again\n".utf8))
            return 1
        }
        let text = asJSON ? json(sessions) : lines(sessions)
        do {
            try FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
        } catch {
            return 1
        }
        return 0
    }

    static func throughServer(json asJSON: Bool) -> Int32 {
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure):
            if case .notRunning = failure {
                Say.err("vibeswitcher: \(failure.message); `vibeswitcher status --probe` reads this machine's sessions without it")
                return 69
            }
            return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let result: NodeWire.Value
        switch client.request("status") {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let given = reply.result else { return Say.replyError(reply) }
            result = given
        }
        let facts = context.facts()
        let journal = journalLines(context, accepted: result["accepted"]?.array ?? [], restart: result["restart"])
        if asJSON {
            var report = result.object ?? [:]
            report["format"] = .int(format)
            report["facts"] = .array(facts.lines.map(NodeWire.Value.string))
            report["journal"] = .array(journal.map(NodeWire.Value.string))
            let data = NodeWire.line(NodeWire.Value.object(report))
            try? FileHandle.standardOutput.write(contentsOf: data)
            return 0
        }
        var out: [String] = []
        let server = result["server"], host = result["host"]
        out.append("node \(inert(result["node"]?.string)), server pid \(server?["pid"]?.int.map(String.init) ?? "?") since \(inert(server?["startedAt"]?.string)), build \(inert(server?["commit"]?.string))")
        let notes = host?["notes"]
        out.append("host since \(inert(host?["startedAt"]?.string)) (\(inert(host?["state"]?.string)))"
                   + (notes?.object != nil ? ", server restarts: \(notes?["serverRestarts"]?.int ?? 0), refused app connections: \(notes?["refusedAppConnections"]?.int ?? 0)" : ""))
        for path in notes?["replacedPaths"]?.array ?? [] { out.append("the host took back its path \(inert(path.string))") }
        out += facts.lines
        out.append("voice rule: \(inert(result["rule"]?["says"]?.string))")
        let sessions = result["sessions"]?.array ?? []
        out.append(sessions.isEmpty ? "No agent sessions." : "sessions:")
        for session in sessions {
            out.append("  \(inert(session["terminal"]?.string))  \(inert(session["agent"]?.string))  \(inert(session["cwd"]?.string))  \(inert(session["status"]?.string))")
        }
        out += CardText.statusLines(leads: result["leads"]?.array ?? [], cards: result["cards"])
        for accepted in result["accepted"]?.array ?? [] {
            out.append("accepted: \(inert(accepted["kind"]?.string)) at \(inert(accepted["at"]?.string)) from pid \(accepted["pid"]?.int.map(String.init) ?? "?") in \(inert(accepted["cgroup"]?.string)): \(inert(accepted["commandLine"]?.array?.compactMap(\.string).joined(separator: " ")))")
        }
        for notice in result["notices"]?.array ?? [] { out.append("notice: \(inert(notice.string))") }
        out += journal
        Say.out(out.joined(separator: "\n"))
        return 0
    }

    /// What the journal says that the user should see (EN-D15): a host restart the server saw (`restart`, E8) with how
    /// the host ended and whether a `vibeswitcher start` explains it, until acknowledged; unexplained starts, stops and
    /// server restarts not yet acknowledged, how the unit's last process ended, and `NodeJournal.marks`.
    static func journalLines(_ context: NodeContext, accepted: [NodeWire.Value], restart: NodeWire.Value? = nil) -> [String] {
        let entries: [JournalEntry]
        let state = context.unitState()
        let ended = state?.result.map { "it last ended \(inert($0)), status \(inert(state?.execMainStatus))" }
        switch context.journalEntries() {
        case .failure(let failure):
            // Without a journal the restart is still said, and that nothing here can say how the host ended.
            return restartLines(restart, ended: ended ?? "how it ended isn't known (\(failure.reason))", explained: nil, acknowledged: false)
                + ["journal: \(failure.reason)"]
        case .success(let read): entries = read
        }
        let rule = context.journalRule
        var lines: [String] = []
        if let at = restart?["at"]?.string.flatMap(NodeWire.date) {
            let event = NodeJournal.Event(kind: .start, at: at)
            lines += restartLines(restart, ended: ended ?? "how it ended isn't known (the node's unit says nothing)",
                                  explained: NodeJournal.unexplained(starts: [event], entries: entries, rule: rule).isEmpty,
                                  acknowledged: NodeJournal.acknowledged(event, entries: entries, rule: rule))
        }
        if let state, let result = state.result {
            lines.append("the node's unit last ended: \(inert(result)), status \(inert(state.execMainStatus)), started \(inert(state.execMainStartTimestamp))")
        }
        for event in NodeJournal.unexplained(starts: NodeJournal.events(entries), entries: entries, rule: rule)
            where !NodeJournal.acknowledged(event, entries: entries, rule: rule) {
            lines.append("journal: a \(event.kind.rawValue) at \(NodeWire.dateText(event.at)) that no `vibeswitcher start` or `stop` explains (`vibeswitcher status --ack` once read)")
        }
        let requests = accepted.map { ($0["kind"]?.string ?? "?", $0["action"]?.string, $0["at"]?.string.flatMap(NodeWire.date)) }
        lines += NodeJournal.marks(accepted: requests, entries: entries, rule: rule).map { "journal: " + $0 }
        return lines
    }

    /// The host restart the server saw (E8), until acknowledged: when, what it reset, how the host before ended
    /// (`ended`) and whether a `vibeswitcher start` or `stop` entry explains it (`explained`; nil: no journal to ask).
    static func restartLines(_ restart: NodeWire.Value?, ended: String, explained: Bool?, acknowledged: Bool) -> [String] {
        guard let restart, let at = restart["at"]?.string, !acknowledged else { return [] }
        let explains: String
        switch explained {
        case true?: explains = "a `vibeswitcher start` or `stop` entry in the journal explains it"
        case false?: explains = "no `vibeswitcher start` or `stop` entry in the journal explains it"
        case nil: explains = "whether you started it can't be read"
        }
        return ["restart: the session host restarted at \(inert(at)) (the one before started at \(inert(restart["before"]?.string))); \(ended); "
                + "\(explains). Its vault started over: \(inert(restart["reset"]?.string)) (`vibeswitcher status --ack` once read)"]
    }

    /// `status --ack`: the journal entry that clears what it shows, after the typed code.
    static func acknowledge() -> Int32 {
        let context = NodeContext.current()
        context.sayScratch()
        guard context.journalSocket != nil else { return Say.refused(NodeContext.noStandIn) }
        let action = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(code: NodeIds.code(action: action), what: "This acknowledges the starts, stops and restarts the journal shows.")
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        guard context.writeJournal(NodeJournal.entry(event: "ack", action: action)) else {
            Say.err("vibeswitcher: the acknowledgment couldn't be written to the journal")
            return 1
        }
        Say.out("acknowledged")
        return 0
    }

    /// Untrusted text for the terminal (`ConfigSeal.inert`, no length limit).
    static func inert(_ text: String?) -> String { ConfigSeal.inert(text ?? "?", limit: .max) }

    /// `{"format":1,"node":"local","sessions":[{"id","terminal","agent","cwd","status","since"}]}`: `cwd` null when
    /// it isn't known, `since` an ISO 8601 date.
    static func json(_ sessions: [LocalSession]) -> String {
        let dates = ISO8601DateFormatter()
        let report: [String: Any] = [
            "format": format,
            "node": LocalSessions.node,
            "sessions": sessions.map { session -> [String: Any] in
                ["id": session.id, "terminal": session.terminal, "agent": session.agent.rawValue,
                 "cwd": session.cwd ?? NSNull(), "status": session.statusWord, "since": dates.string(from: session.since)]
            },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// One line a session, in columns: `ttypts3  claude  /home/me/project  needs you  since 14:03:21`.
    static func lines(_ sessions: [LocalSession]) -> String {
        guard !sessions.isEmpty else { return "No agent sessions." }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = sessions.map { session in
            [session.terminal, session.agent.rawValue, session.cwd ?? "?", session.status.word.text,
             "since " + (Calendar.current.isDateInToday(session.since) ? clock : day).string(from: session.since)]
        }
        let widths = (0..<4).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, word in
                column < widths.count ? word.padding(toLength: widths[column], withPad: " ", startingAt: 0) : word
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
