import Foundation
import VibeCore

/// When `send`'s words reach the agent (2026-11-24, the user's ask; the agents' own keys, from their docs):
///
/// - `step`: at its next step. A Claude working by its hooks gets them through its steer inbox as the user's
///   (`LeadEngine.steerAsUser`), else typed; a Codex gets them typed with Enter (its steer).
/// - `now`: a Claude Code from 2.1.275 on: typed and Enter (queued), then its send-now, Ctrl+X Ctrl+S (0x18 0x13: plain
///   bytes in a pty, unlike Ctrl+Enter), only while it works: what it runs goes to the background, or its turn stops, and
///   it reads them in the same turn. Codex: typed and Enter, as `step`. An older Claude, or one whose version the node
///   can't tell, falls back to `step`, said.
/// - `after`: after this turn. Codex: typed and Tab (its queue). Claude has no such key: `step`, said.
/// - `interrupt`: Esc (only while it works), its idle prompt waited for, then typed and Enter, one unit.
///
/// The reply says what was done (`when`) and, when that isn't what was asked, why (`said`).
public enum SendWhen: String, CaseIterable, Sendable {
    case step, now, after, interrupt

    /// The first Claude Code with its send-now keys.
    public static let claudeSendNow = [2, 1, 275]

    /// What is done for `asked` on `agent` at `version` (nil: not known): the way and, when it isn't what was asked, why.
    public static func resolve(_ asked: SendWhen, agent: Agent?, version: [Int]?) -> (way: SendWhen, said: String?) {
        switch (agent, asked) {
        case (.claude?, .now):
            guard let version, version.lexicographicallyPrecedes(claudeSendNow) == false else {
                let which = version.map { "Claude Code \($0.map(String.init).joined(separator: ".")), before 2.1.275" } ?? "a Claude Code whose version the node can't tell"
                return (.step, "now fell back to step: \(which) has no send-now")
            }
            return (.now, nil)
        case (.claude?, .after): return (.step, "Claude Code has no key for after this turn: sent at its next step")
        default: return (asked, nil)
        }
    }

    /// The ways `agent` at `version` takes, as a session's `sendWays` lists them for a page.
    public static func ways(agent: Agent?, version: [Int]?) -> [SendWhen] {
        switch agent {
        case .claude?: return version.map { !$0.lexicographicallyPrecedes(claudeSendNow) } == true ? [.step, .now, .interrupt] : [.step, .interrupt]
        case .codex?: return [.step, .now, .after, .interrupt]
        default: return []
        }
    }

    /// The words the user's consent shows for each (the terminal's prompt, the Mac's dialog, a page's line before a click).
    public var consent: String {
        switch self {
        case .step: return "at its next step"
        case .now: return "now: what it runs goes to the background, or its turn stops, and it reads them in this turn"
        case .after: return "after its turn"
        case .interrupt: return "stopping its turn first (Esc), then typed in"
        }
    }

    /// Claude Code's send-now (Ctrl+X Ctrl+S).
    public static let sendNowBytes: [UInt8] = [0x18, 0x13]
}

/// An agent's version as the node launched it: the path its program resolves to (Claude Code's
/// `…/claude/versions/2.1.331`), from the agent's process, else from the session's command; nil when neither names one.
public enum AgentVersion {
    /// `2.1.331` → [2, 1, 331]; nil for anything else.
    public static func parse(_ name: String) -> [Int]? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }

    /// The version a path names by its last component: the path itself, the link it is, or what it resolves to (Claude
    /// Code's `~/.local/bin/claude` links to `…/versions/2.1.331`), the first that reads as a version.
    public static func of(path: String) -> [Int]? {
        let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)).map { link -> String in
            link.hasPrefix("/") ? link : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(link)
        }
        let candidates: [String] = [path, link, URL(fileURLWithPath: path).resolvingSymlinksInPath().path].compactMap { $0 }
        for candidate in candidates {
            if let found = parse(URL(fileURLWithPath: candidate).lastPathComponent) { return found }
        }
        return nil
    }

    /// The version of the agent in `session`: its process's program (`/proc/<pid>/exe`), else the first absolute path
    /// of the session's command. Reads /proc and the disk: never on a server queue.
    public static func of(session: HostSession, pid: Int32?) -> [Int]? {
        if let pid, let found = of(path: "/proc/\(pid)/exe") { return found }
        let words = (session.command ?? "").split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        guard let program = words.first(where: { $0.hasPrefix("/") }) else { return nil }
        return of(path: program)
    }
}

extension AgentVersion {
    private struct Process: Hashable {
        var pid: Int32
        var started: Date
    }

    private static let kept = Locked<[Process: [Int]?]>([:])

    /// `of(session:pid:)`, read once per agent process: by its pid and its start time (a pid reused by a later process,
    /// an update's Claude among them, is read again). A process whose start can't be read is read each time.
    public static func cached(session: HostSession, pid: Int32) -> [Int]? {
        guard let started = ProcessTable.info(pid: pid)?.startTime else { return of(session: session, pid: pid) }
        let process = Process(pid: pid, started: started)
        if let found = kept.get()[process] { return found }
        let found = of(session: session, pid: pid)
        var all = kept.get()
        if all.count > 512 { all.removeAll() }
        all[process] = found
        kept.set(all)
        return found
    }
}
