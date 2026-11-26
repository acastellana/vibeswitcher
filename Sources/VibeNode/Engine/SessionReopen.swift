import Foundation
import VibeCore

/// The user's own sessions reopened in their same conversations after a host restart (the app's restart card for your
/// own sessions, `RestartCard.swift` and `RestartReopen`'s user entries, for a node; the lead's half is
/// `RestartResume.swift`).
///
/// **The record.** While the host runs them, the engine keeps the user's own Claude sessions in `engine.json`
/// (`EngineState.OpenSessions`, from `RestartReopen.entries`, the app's: not a lead nor its team, not a plain shell),
/// each with its folder and Claude's conversation id once its hook said it, rewritten as they start and end. A host
/// restart (a reboot) ends them; the record moves to the restart (`EngineState.Restart.sessions`).
///
/// **The offer.** `status` says how many ended and lists them (`reopen`); `vibeswitcher reopen` shows them.
///
/// **The reopen.** `vibeswitcher reopen all|SESSION…`, in the user's voice (`session.reopen`, recorded in the vault
/// first), starts each as the app's Reopen does: Claude in its folder with `--resume <its conversation>`, labelled as an
/// ordinary Claude session. `vibeswitcher reopen --forget` puts the offer away.
///
/// **What the record can't do.** A worker of the user's uid can write `engine.json`, so the record is only a hint of
/// which conversation to resume where (`reopenable`): the folder must be one, spelled as itself (no `.`, `..` or empty
/// part, no link on the way: that canonical path is the session's folder and what's shown, in full), the conversation an
/// id whose transcript is a Claude transcript inside the agents' folders, in Claude's folder for that very folder (so
/// `--resume` finds it there), recording that folder as its `cwd` (Claude's folder names are a lossy slug), and not a
/// named agent's (a lead's or its team's: `vibeswitcher new` names none); a model only when it's a model's name. The
/// program is the node's `claude` link and the label the app's "Claude", never the record's command or label.
extension LeadEngine {
    /// The user's own sessions the host runs, recorded in `engine.json` when they changed (their window sizes aside),
    /// while the host that runs them is the one `lastHostStart` names (a new host's empty list before `restartLook`
    /// saw it is no change). One that ended stays recorded for the watch's grace first: a host going down (a reboot)
    /// ends every session and may say so before it goes, and those are the ones to offer back. On `queue`.
    func noteOpenSessions() {
        guard link.state == .connected, let started = link.hostStartedAt?.timeIntervalSince1970,
              let last = lastHostStart, abs(last - started) <= 0.001 else { return }
        let replaced = Set(leads.leads.values.flatMap(\.replaced.keys))
        if openSessionsWatch.record(started: started, hosted: link.sessions, hooked: sessions?.sessions ?? [], replaced: replaced, home: home) {
            saveState()
        }
    }

    /// What a host restart that ended the host started at `before` offers back: the sessions an earlier restart offered
    /// and nobody reopened, then those recorded under it (an id once, the newer entry kept). Nil: none.
    func endedSessions(before: Double) -> [RestartReopen.Entry]? {
        let ended = openSessions.flatMap { abs($0.hostStartedAt - before) <= 0.001 ? $0.entries : nil } ?? []
        let newer = Set(ended.map(\.id))
        let all = (hostRestart?.sessions ?? []).filter { !newer.contains($0.id) } + ended
        return all.isEmpty ? nil : all
    }

    /// The user's sessions the last host restart ended and nobody reopened yet, leads' order kept (`RestartReopen.ordered`).
    public var offeredSessions: [RestartReopen.Entry] { RestartReopen.ordered(hostRestart?.sessions ?? []) }

    /// `status`'s notice of them, while there are any.
    func sessionsNotice(_ restart: EngineState.Restart, at: String) -> [String] {
        guard let sessions = restart.sessions, !sessions.isEmpty else { return [] }
        let names = sessions.prefix(5).map { "\(ConfigSeal.inert($0.name, limit: 60)) in \(ConfigSeal.inert($0.folder, limit: .max))" }
            .joined(separator: ", ") + (sessions.count > 5 ? ", …" : "")
        return ["the node restarted at \(at): \(sessions.count) of your own session\(sessions.count == 1 ? "" : "s") ended with it "
                + "(\(names)). `vibeswitcher reopen` lists \(sessions.count == 1 ? "it" : "them") and reopens each in its same conversation; "
                + "`vibeswitcher reopen --forget` puts the offer away"]
    }

    /// `status`'s `reopen`: each offered session, its id, folder, name and conversation (null: unknown, so it can't be).
    var offeredValue: NodeWire.Value {
        .array(offeredSessions.map { entry in
            .object(["session": .string(NodeIds.session(host: entry.id)), "folder": .string(entry.folder), "name": .string(entry.name),
                     "conversation": entry.agentSessionID.map(NodeWire.Value.string) ?? .null, "agent": .string(entry.agent.rawValue)])
        })
    }

    /// `node`'s `reopenOffer` (the no-terminal inventory's C3, 2026-11-26): the offer as the page shows it, null while
    /// there is none (no host restart, none of the user's sessions ended with it, or all reopened or put away).
    var reopenOfferValue: NodeWire.Value { Self.reopenOffer(hostRestart) }

    /// The offer `restart` makes, as `node` carries it: when the host restarted (`at`) and each session it ended and
    /// nobody reopened yet, in the offer's order, by the id `session.reopen` takes and the names the page shows (its
    /// own name and its project's), never its folder, its conversation or its command. Null when it offers none.
    static func reopenOffer(_ restart: EngineState.Restart?) -> NodeWire.Value {
        guard let restart, let sessions = restart.sessions, !sessions.isEmpty else { return .null }
        return .object([
            "at": .date(Date(timeIntervalSince1970: restart.at)),
            "sessions": .array(RestartReopen.ordered(sessions).map { entry in
                .object(["session": .string(NodeIds.session(host: entry.id)), "name": .string(ConfigSeal.inert(entry.name, limit: 60)),
                         "project": .string(ConfigSeal.inert(entry.project, limit: 60)), "agent": .string(entry.agent.rawValue)])
            }),
        ])
    }

    /// The offered sessions taken for a reopen (gone from the offer, so a second ask can't start them twice), each
    /// named by `ids` (host ids), in the offer's order. On `queue`.
    func takeOffered(_ ids: Set<UUID>) -> [RestartReopen.Entry] {
        guard var restart = hostRestart else { return [] }
        let taken = restart.takeOffered(ids)
        guard !taken.isEmpty else { return [] }
        hostRestart = restart
        saveState()
        return taken
    }

    /// Entries taken for a reopen that didn't start, offered again (in front, as they were). On `queue`.
    func offerAgain(_ entries: [RestartReopen.Entry]) {
        guard !entries.isEmpty, var restart = hostRestart else { return }
        let back = Set(entries.map(\.id))
        restart.sessions = entries + (restart.sessions ?? []).filter { !back.contains($0.id) }
        hostRestart = restart
        saveState()
    }

    /// The offer put away (`vibeswitcher reopen --forget`): how many it held. On `queue`.
    func forgetOffered() -> Int {
        guard var restart = hostRestart, restart.sessions != nil else { return 0 }
        let count = restart.forgetOffered()
        hostRestart = restart
        saveState()
        return count
    }

    /// What a reopen starts, from an entry that checked out.
    struct Reopening: Equatable {
        /// `claude` or `codex` (the user's own Codex session, the feature review of 2026-11-22).
        var agent: String = "claude"
        var folder: String
        var conversation: String
        var model: String?
        var cols: Int
        var rows: Int
    }

    /// What `entry` reopens, or why it can't: the record is only a hint (`SessionReopen.swift`'s header). A user's Claude
    /// session; its folder an absolute path that is already its own canonical spelling (no `.` or `..` component, no
    /// empty one, no link on the way: `realpath` gives it back unchanged), which is then both the session's folder and
    /// what is shown; its conversation an id whose transcript, `<id>.jsonl` in Claude's folder for that canonical folder,
    /// is a regular Claude transcript inside the agents' folders in `home` (`TranscriptReader.checkedURL`), not a named
    /// agent's (`--name`: a lead, worker or verifier), and records that very folder as its `cwd` (Claude's folder names
    /// are a lossy slug: `/a/b-c` and `/a/b/c` share one, so the slug alone isn't the folder); its model, when the command
    /// it ran named one, a model's name (`Requests.isModelName`). Off the engine's queue (the disk).
    static func reopenable(_ entry: RestartReopen.Entry, home: String) -> Result<Reopening, Refused> {
        let shown = ConfigSeal.inert(entry.folder, limit: .max)
        func refused(_ why: String) -> Result<Reopening, Refused> { .failure(Refused("\(ConfigSeal.inert(entry.name, limit: 60)) in \(shown): \(why)")) }
        guard entry.role == .user, entry.agent == .claude || entry.agent == .codex else { return refused("not one of your own Claude or Codex sessions") }
        guard entry.folder.hasPrefix("/") else { return refused("its folder isn't an absolute path") }
        let parts = entry.folder.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard entry.folder == "/" || !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return refused("its folder is spelled with an empty, . or .. part: only its own plain spelling is reopened")
        }
        guard let resolved = realpath(entry.folder, nil) else { return refused("its folder is gone") }
        let canonical = String(cString: resolved)
        free(resolved)
        guard RestartReopen.isFolder(canonical) else { return refused("its folder isn't a folder") }
        guard canonical == entry.folder else {
            return refused("its folder is reached through a link (it is \(ConfigSeal.inert(canonical, limit: .max))): only a folder's own spelling is reopened")
        }
        guard let id = entry.agentSessionID, !id.isEmpty else { return refused("its conversation id wasn't known") }
        guard UUID(uuidString: id) != nil else { return refused("its conversation id isn't one") }
        let size = (cols: (20...500).contains(entry.cols) ? entry.cols : 120, rows: (5...200).contains(entry.rows) ? entry.rows : 36)
        if entry.agent == .codex {
            if let why = codexRefusal(conversation: id, folder: canonical, home: home) { return refused(why) }
            return .success(Reopening(agent: "codex", folder: canonical, conversation: id.lowercased(), model: nil, cols: size.cols, rows: size.rows))
        }
        let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects").resolvingSymlinksInPath()
        let folder = projects.appendingPathComponent(RecentProjects.claudeSlug(for: canonical)).path
        let path = URL(fileURLWithPath: folder).appendingPathComponent("\(id).jsonl").path
        guard FileManager.default.fileExists(atPath: path) else { return refused("Claude keeps no conversation \(id) for that folder") }
        guard let (url, format) = TranscriptReader.checkedURL(path, home: home), format == .claude,
              url.deletingLastPathComponent().path == folder else {
            return refused("its transcript isn't a Claude transcript inside the agents' folders")
        }
        guard let ends = edges(of: url), ends.range(of: Data(#""agentName":""#.utf8)) == nil else {
            return refused("its conversation is a named agent's (a lead's or its team's), not one of yours")
        }
        guard let recorded = recordedFolder(in: ends) else { return refused("its transcript records no folder it ran in") }
        guard recorded == canonical else {
            return refused("its transcript ran in \(ConfigSeal.inert(recorded, limit: .max)), not in this folder")
        }
        var model: String?
        if let command = entry.command, let range = command.range(of: #"--model '?([^' ]*)'?"#, options: .regularExpression) {
            let said = command[range].dropFirst("--model ".count).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard Requests.isModelName(said) else { return refused("its recorded model \(ConfigSeal.inert(said, limit: 64)) isn't a model's name") }
            model = said
        }
        return .success(Reopening(folder: canonical, conversation: id.lowercased(), model: model, cols: size.cols, rows: size.rows))
    }

    /// Why the Codex conversation `id` can't be resumed in `folder` (nil: it can), the record being only a hint: its
    /// rollout must be in Codex's sessions folder in `home` (`<home>/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`, one
    /// file, found by its name only in those three levels), a regular Codex transcript there (`TranscriptReader
    /// .checkedURL`), whose first line is its `session_meta` naming that same id and `folder` as its `cwd`. A cold
    /// rollout Codex compressed (`.jsonl.zst`) isn't resumed here: the line to resume it by hand is `vibeswitcher
    /// resume`'s. Off the engine's queue (the disk).
    static func codexRefusal(conversation id: String, folder: String, home: String) -> String? {
        let lower = id.lowercased()
        let sessions = URL(fileURLWithPath: home).appendingPathComponent(".codex/sessions").resolvingSymlinksInPath()
        let manager = FileManager.default
        func folders(_ url: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.count <= 4 && $0.allSatisfy(\.isNumber) }.sorted().suffix(400)
                .map { url.appendingPathComponent($0) }
        }
        var found: [URL] = []
        for year in folders(sessions) {
            for month in folders(year) {
                for day in folders(month) {
                    for name in (try? manager.contentsOfDirectory(atPath: day.path)) ?? []
                    where name.hasPrefix("rollout-") && name.lowercased().hasSuffix("-\(lower).jsonl") {
                        found.append(day.appendingPathComponent(name))
                    }
                }
            }
        }
        guard found.count == 1, let rollout = found.first else {
            return found.isEmpty ? "Codex keeps no conversation \(lower) in its sessions folder (or only a compressed one: `codex resume \(lower)` in that folder resumes it)"
                : "Codex keeps \(found.count) rollouts for conversation \(lower): it isn't resumed from a hint that names more than one"
        }
        guard let (url, format) = TranscriptReader.checkedURL(rollout.path, home: home), format == .codex,
              url.path.hasPrefix(sessions.path + "/") else {
            return "its rollout isn't a Codex transcript inside Codex's sessions folder"
        }
        guard let ends = edges(of: url), let first = ends.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any] else {
            return "its rollout doesn't start with Codex's session record"
        }
        guard (payload["id"] as? String)?.lowercased() == lower else { return "its rollout's session record names another conversation" }
        guard let cwd = payload["cwd"] as? String, cwd == folder else {
            return "its rollout ran in \(ConfigSeal.inert(payload["cwd"] as? String ?? "no folder", limit: .max)), not in this folder"
        }
        return nil
    }

    /// The folder a Claude transcript says it ran in: the first line of `data` (its first and last 64 KB, `edges`) that is
    /// a JSON object with a `cwd` string. Nil: none says one.
    static func recordedFolder(in data: Data) -> String? {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: Data(#""cwd""#.utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = object["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    // MARK: Ended sessions (`vibeswitcher resume`)

    /// `status`'s `ended` and `ending` (`OpenSessionsWatch`).
    var endedValue: NodeWire.Value { openSessionsWatch.endedValue }
    var endingValue: NodeWire.Value { openSessionsWatch.endingValue }

    /// The ended session `id` names (its host id), out of the list for a resume. On `queue`.
    func takeEnded(_ id: UUID) -> RestartReopen.Entry? {
        guard let entry = openSessionsWatch.takeEnded(id) else { return nil }
        saveState()
        return entry
    }

    /// Entries taken for a resume that didn't start, back in the list (first). On `queue`.
    func endedAgain(_ entries: [RestartReopen.Entry]) {
        guard !entries.isEmpty else { return }
        openSessionsWatch.endedAgain(entries)
        saveState()
    }

    /// The user's own sessions live in the host, as last recorded, and those that ended lately (`OpenSessionsWatch`).
    public internal(set) var openSessions: EngineState.OpenSessions? {
        get { openSessionsWatch.open }
        set { openSessionsWatch.open = newValue }
    }
    public internal(set) var endedSessions: [EngineState.Ended] {
        get { openSessionsWatch.ended }
        set { openSessionsWatch.ended = newValue }
    }
}

/// The user's own sessions as the engine records them (`SessionReopen.swift`'s header): the record of those the host
/// runs, those that ended lately (`vibeswitcher resume`), when each recorded one was first seen ended. Its state is its
/// own, on the engine's queue; `engine.json` is the engine's to write (each change that needs it says so).
final class OpenSessionsWatch {
    /// How many ended sessions are kept.
    static let endedKept = 20

    private let queue: DispatchQueue
    private var recorded: EngineState.OpenSessions?
    private var endedList: [EngineState.Ended] = []
    /// When each recorded session was first seen ended (or gone from the host's list): kept in the record for `grace`.
    private var endedSince: [UUID: Date] = [:]
    /// How long an ended session stays in the record (a test's shorter), and the clock it's judged by.
    var grace: TimeInterval = 30
    var now: () -> Date = Date.init

    init(queue: DispatchQueue) { self.queue = queue }

    /// What `engine.json` kept, taken back as the engine starts (its init, before anything runs on its queue).
    func restore(open: EngineState.OpenSessions?, ended: [EngineState.Ended]) {
        recorded = open
        endedList = ended
    }

    /// The record of the sessions the host runs. On the engine's queue.
    var open: EngineState.OpenSessions? {
        get { EngineWatch.assertOn(queue); return recorded }
        set { EngineWatch.assertOn(queue); recorded = newValue }
    }

    /// The sessions that ended lately, newest first. On the engine's queue.
    var ended: [EngineState.Ended] {
        get { EngineWatch.assertOn(queue); return endedList }
        set { EngineWatch.assertOn(queue); endedList = newValue }
    }

    /// The user's own sessions `hosted` (the host's list, under the host started at `started`) and `hooked` (what their
    /// hooks said), recorded: an ended one kept for `grace`, then listed as ended. True when the record changed and
    /// `engine.json` is to be written. On the engine's queue.
    func record(started: Double, hosted: [HostSession], hooked: [Session], replaced: Set<UUID>, home: String) -> Bool {
        EngineWatch.assertOn(queue)
        let transcripts = Dictionary(hooked.compactMap { session in session.hostID.map { ($0, session.transcriptPath) } }, uniquingKeysWith: { $1 })
        let previous = recorded.flatMap { abs($0.hostStartedAt - started) <= 0.001 ? $0.entries : nil } ?? []
        let live = RestartReopen.entries(hosted: hosted, sessions: hooked, previous: previous, replacedLeads: replaced)
            .filter { $0.role == .user && ($0.agent == .claude || $0.agent == .codex) }
            .map { entry -> RestartReopen.Entry in
                guard entry.agentSessionID == nil, let path = transcripts[entry.id] ?? nil else { return entry }
                var entry = entry
                // Claude's by the transcript's name; the user's own Codex session's by its rollout's, Codex's alone.
                entry.agentSessionID = entry.agent == .codex ? LeadEngine.conversation(ofCodexRollout: path, home: home)
                    : LeadEngine.conversation(ofTranscript: path)
                return entry
            }
        let now = now(), liveIDs = Set(live.map(\.id))
        for id in liveIDs { endedSince[id] = nil }
        let ended = previous.filter { entry in
            guard !liveIDs.contains(entry.id) else { return false }
            let since = endedSince[entry.id] ?? now
            endedSince[entry.id] = since
            return now.timeIntervalSince(since) < grace
        }
        let kept = Set(ended.map(\.id))
        endedSince = endedSince.filter { kept.contains($0.key) }
        // Ended for good (past the grace): offered to `vibeswitcher resume` from now on.
        let gone = previous.filter { !liveIDs.contains($0.id) && !kept.contains($0.id) }
        if !gone.isEmpty {
            let exits = Dictionary(hosted.compactMap { session in session.exit.map { (session.id, $0) } }, uniquingKeysWith: { $1 })
            noteEnded(gone, at: now, exits: exits)
        }
        let entries = previous.compactMap { entry in live.first { $0.id == entry.id } ?? (kept.contains(entry.id) ? entry : nil) }
            + live.filter { entry in !previous.contains { $0.id == entry.id } }
        if let open = recorded, abs(open.hostStartedAt - started) <= 0.001,
           open.entries.map(RestartReopen.withoutSize) == entries.map(RestartReopen.withoutSize) { return false }
        if recorded == nil, entries.isEmpty { return false }
        recorded = EngineState.OpenSessions(hostStartedAt: started, entries: entries)
        return true
    }

    /// `entries` ended at `at`: first in the ended list, an entry once (by its host id, and by its conversation), the
    /// newest `endedKept` kept, each with how it ended where the host still says (`exits`, by host id). The caller saves.
    /// On the engine's queue.
    func noteEnded(_ entries: [RestartReopen.Entry], at: Date, exits: [UUID: HostSession.Exit] = [:]) {
        let fresh = entries.map { EngineState.Ended(entry: $0, at: at.timeIntervalSince1970, exit: exits[$0.id]) }
        let ids = Set(entries.map(\.id)), conversations = Set(entries.compactMap(\.agentSessionID))
        let kept = endedList.filter { !ids.contains($0.entry.id) && !($0.entry.agentSessionID.map(conversations.contains) ?? false) }
        endedList = Array((fresh + kept).prefix(Self.endedKept))
    }

    /// `status`'s `ended`: each ended session, its id, folder, name, conversation (null: unknown, so it can't be resumed),
    /// when it ended, and how (`exit`: its status, the host's words for it and when; null where the host didn't say).
    var endedValue: NodeWire.Value {
        .array(endedList.map { ended in
            .object(["session": .string(NodeIds.session(host: ended.entry.id)), "folder": .string(ended.entry.folder),
                     "name": .string(ended.entry.name), "conversation": ended.entry.agentSessionID.map(NodeWire.Value.string) ?? .null,
                     "agent": .string(ended.entry.agent.rawValue),
                     "at": .date(Date(timeIntervalSince1970: ended.at)),
                     "exit": ended.exit.map { exit in
                         .object(["status": .int(Int(exit.status)), "cause": .string(exit.cause), "at": .date(exit.at)])
                     } ?? .null])
        })
    }

    /// The user's own sessions that ended within `grace`, not listed for `resume` yet (`status`'s `ending`): each
    /// with its session, folder and name, when it ended, and when it will be listed (`vibeswitcher resume` says so
    /// rather than "none ended"). On the engine's queue.
    var endingValue: NodeWire.Value {
        let entries = recorded?.entries ?? []
        return .array(endedSince.sorted { $0.value > $1.value }.compactMap { id, since in
            guard let entry = entries.first(where: { $0.id == id }) else { return nil }
            return .object(["session": .string(NodeIds.session(host: id)), "folder": .string(entry.folder), "name": .string(entry.name),
                            "at": .date(since), "listedAt": .date(since.addingTimeInterval(grace))])
        })
    }

    /// The ended session `id` names (its host id), out of the list for a resume. On the engine's queue.
    func takeEnded(_ id: UUID) -> RestartReopen.Entry? {
        EngineWatch.assertOn(queue)
        guard let found = endedList.first(where: { $0.entry.id == id }) else { return nil }
        endedList.removeAll { $0.entry.id == id }
        return found.entry
    }

    /// Entries taken for a resume that didn't start, back in the list (first). On the engine's queue.
    func endedAgain(_ entries: [RestartReopen.Entry]) {
        EngineWatch.assertOn(queue)
        noteEnded(entries, at: now())
    }
}

/// `vibeswitcher resume`'s words for the sessions that ended within the grace (`status`'s `ending`): "a session ended
/// 4 s ago (notes in /home/u/notes); it is listed in 26 s: run `vibeswitcher resume` again then".
public enum ResumeText {
    public static func endingLines(_ ending: [NodeWire.Value], now: Date) -> [String] {
        ending.map { session in
            let at = session["at"]?.string.flatMap(NodeWire.date) ?? now
            let listed = session["listedAt"]?.string.flatMap(NodeWire.date) ?? now
            let ago = max(0, Int(now.timeIntervalSince(at).rounded())), wait = max(1, Int(listed.timeIntervalSince(now).rounded(.up)))
            let name = ConfigSeal.inert(session["name"]?.string ?? "a session", limit: 80)
            let folder = ConfigSeal.inert(session["folder"]?.string ?? "?", limit: 300)
            return "a session ended \(ago) s ago (\(name) in \(folder)); it is listed in \(wait) s: run `vibeswitcher resume` again then"
        }
    }

    /// `vibeswitcher resume`'s list: the sessions within their grace first (`endingLines`), whenever there are any, then
    /// the ended ones, newest first, each its `line` and how to resume it by hand; "none ended" only when neither. On
    /// 2026-11-23 the grace line showed only while no other session was listed, so a session just ended went unsaid.
    public static func listing(ended: [NodeWire.Value], ending: [NodeWire.Value], now: Date, line: (NodeWire.Value) -> String) -> [String] {
        var lines = endingLines(ending, now: now)
        guard !ended.isEmpty else { return lines.isEmpty ? ["no session of yours ended lately"] : lines }
        lines.append("ended lately, newest first:")
        for session in ended {
            lines.append("  " + line(session) + "  ended \(ConfigSeal.inert(session["at"]?.string ?? "?", limit: 40))")
            if let conversation = session["conversation"]?.string {
                // Codex resumes as `codex resume <id>` (the app's `LaunchPlan.resumeCommand`), Claude with --resume.
                let resume = session["agent"]?.string == "codex" ? "codex resume " : "claude --resume "
                lines.append("      by hand: cd \(RecentProjects.shellQuote(ConfigSeal.inert(session["folder"]?.string ?? "", limit: .max))) && \(resume)"
                    + RecentProjects.shellQuote(ConfigSeal.inert(conversation, limit: 40)))
            }
        }
        lines.append("`vibeswitcher resume SESSION` starts one again on the node, in its same conversation")
        return lines
    }
}

extension EngineState.Restart {
    /// The offered sessions named by `ids` (host ids) taken out of the offer, in its order (`session.reopen`'s); the
    /// offer gone once none is left.
    mutating func takeOffered(_ ids: Set<UUID>) -> [RestartReopen.Entry] {
        guard let offered = sessions else { return [] }
        let taken = RestartReopen.ordered(offered).filter { ids.contains($0.id) }
        guard !taken.isEmpty else { return [] }
        sessions = offered.filter { !ids.contains($0.id) }
        if sessions?.isEmpty == true { sessions = nil }
        return taken
    }

    /// The offer put away (`session.reopen` with `forget`): how many it held.
    mutating func forgetOffered() -> Int {
        let count = sessions?.count ?? 0
        sessions = nil
        return count
    }
}
