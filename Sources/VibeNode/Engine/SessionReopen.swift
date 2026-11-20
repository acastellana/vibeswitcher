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
    /// saw it is no change). One that ended stays recorded for `openGrace` first: a host going down (a reboot) ends
    /// every session and may say so before it goes, and those are the ones to offer back. On `queue`.
    func noteOpenSessions() {
        guard link.state == .connected, let started = link.hostStartedAt?.timeIntervalSince1970,
              let last = lastHostStart, abs(last - started) <= 0.001 else { return }
        let replaced = Set(leads.leads.values.flatMap(\.replaced.keys))
        let hooked = sessions?.sessions ?? []
        let transcripts = Dictionary(hooked.compactMap { session in session.hostID.map { ($0, session.transcriptPath) } }, uniquingKeysWith: { $1 })
        let previous = openSessions.flatMap { abs($0.hostStartedAt - started) <= 0.001 ? $0.entries : nil } ?? []
        let live = RestartReopen.entries(hosted: link.sessions, sessions: hooked, previous: previous, replacedLeads: replaced)
            .filter { $0.role == .user && $0.agent == .claude }
            .map { entry -> RestartReopen.Entry in
                guard entry.agentSessionID == nil, let path = transcripts[entry.id] ?? nil else { return entry }
                var entry = entry
                entry.agentSessionID = Self.conversation(ofTranscript: path)
                return entry
            }
        let now = openNow(), liveIDs = Set(live.map(\.id))
        for id in liveIDs { openEnded[id] = nil }
        let ended = previous.filter { entry in
            guard !liveIDs.contains(entry.id) else { return false }
            let since = openEnded[entry.id] ?? now
            openEnded[entry.id] = since
            return now.timeIntervalSince(since) < openGrace
        }
        let recorded = Set(ended.map(\.id))
        openEnded = openEnded.filter { recorded.contains($0.key) }
        let entries = previous.compactMap { entry in live.first { $0.id == entry.id } ?? (recorded.contains(entry.id) ? entry : nil) }
            + live.filter { entry in !previous.contains { $0.id == entry.id } }
        if let open = openSessions, abs(open.hostStartedAt - started) <= 0.001,
           open.entries.map(RestartReopen.withoutSize) == entries.map(RestartReopen.withoutSize) { return }
        if openSessions == nil, entries.isEmpty { return }
        openSessions = EngineState.OpenSessions(hostStartedAt: started, entries: entries)
        saveState()
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
        return ["the session host restarted at \(at): \(sessions.count) of your own session\(sessions.count == 1 ? "" : "s") ended with it "
                + "(\(names)). `vibeswitcher reopen` lists \(sessions.count == 1 ? "it" : "them") and reopens each in its same conversation; "
                + "`vibeswitcher reopen --forget` puts the offer away"]
    }

    /// `status`'s `reopen`: each offered session, its id, folder, name and conversation (null: unknown, so it can't be).
    var offeredValue: NodeWire.Value {
        .array(offeredSessions.map { entry in
            .object(["session": .string(NodeIds.session(host: entry.id)), "folder": .string(entry.folder), "name": .string(entry.name),
                     "conversation": entry.agentSessionID.map(NodeWire.Value.string) ?? .null])
        })
    }

    /// The offered sessions taken for a reopen (gone from the offer, so a second ask can't start them twice), each
    /// named by `ids` (host ids), in the offer's order. On `queue`.
    func takeOffered(_ ids: Set<UUID>) -> [RestartReopen.Entry] {
        guard var restart = hostRestart, let sessions = restart.sessions else { return [] }
        let taken = RestartReopen.ordered(sessions).filter { ids.contains($0.id) }
        guard !taken.isEmpty else { return [] }
        restart.sessions = sessions.filter { !ids.contains($0.id) }
        if restart.sessions?.isEmpty == true { restart.sessions = nil }
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
        guard var restart = hostRestart, let sessions = restart.sessions else { return 0 }
        restart.sessions = nil
        hostRestart = restart
        saveState()
        return sessions.count
    }

    /// What a reopen starts, from an entry that checked out.
    struct Reopening: Equatable {
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
        guard entry.role == .user, entry.agent == .claude else { return refused("not one of your own Claude sessions") }
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
        return .success(Reopening(folder: canonical, conversation: id.lowercased(), model: model,
                                  cols: (20...500).contains(entry.cols) ? entry.cols : 120, rows: (5...200).contains(entry.rows) ? entry.rows : 36))
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
}
