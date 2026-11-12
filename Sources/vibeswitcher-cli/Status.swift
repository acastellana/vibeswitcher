import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher status [--json]`: the agent sessions on this machine (`LocalSessions`), one line each: terminal,
/// agent, folder, status, since when. It reads the files directly, as a local probe; stage 3's protocol client
/// replaces it, and its output may change until then (the JSON's `format`, `node` and `id` are there from the start).
enum StatusCommand {
    static let usage = "usage: vibeswitcher status [--json]"

    /// The JSON form's version.
    static let format = 1

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.isEmpty || arguments == ["--json"] else {
            try? FileHandle.standardError.write(contentsOf: Data((usage + "\n").utf8))
            return 64
        }
        guard let sessions = LocalSessions().read() else {
            try? FileHandle.standardError.write(contentsOf: Data("vibeswitcher: the process table couldn't be read; try again\n".utf8))
            return 1
        }
        let text = arguments == ["--json"] ? json(sessions) : lines(sessions)
        do {
            try FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
        } catch {
            return 1
        }
        return 0
    }

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
