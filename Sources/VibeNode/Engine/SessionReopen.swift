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
/// which conversation to resume where (`reopenable`): the folder must be one, the conversation an id whose transcript is
/// a Claude transcript inside the agents' folders, in Claude's folder for that very folder (so `--resume` finds it
/// there), and not a named agent's (a lead's or its team's: `vibeswitcher new` names none); a model only when it's a
/// model's name. The program is the node's `claude` link and the label the app's "Claude", never the record's command
/// or label.
extension LeadEngine {
    /// The user's own sessions the host runs, recorded in `engine.json` when they changed (their window sizes aside),
    /// while the host that runs them is the one `lastHostStart` names (a new host's empty list before `restartLook`
    /// saw it is no change). On `queue`.
    func noteOpenSessions() {
        guard link.state == .connected, let started = link.hostStartedAt?.timeIntervalSince1970,
              let last = lastHostStart, abs(last - started) <= 0.001 else { return }
        let replaced = Set(leads.leads.values.flatMap(\.replaced.keys))
        let hooked = sessions?.sessions ?? []
        let transcripts = Dictionary(hooked.compactMap { session in session.hostID.map { ($0, session.transcriptPath) } }, uniquingKeysWith: { $1 })
        let previous = openSessions.flatMap { abs($0.hostStartedAt - started) <= 0.001 ? $0.entries : nil } ?? []
        let entries = RestartReopen.entries(hosted: link.sessions, sessions: hooked, previous: previous, replacedLeads: replaced)
            .filter { $0.role == .user && $0.agent == .claude }
            .map { entry -> RestartReopen.Entry in
                guard entry.agentSessionID == nil, let path = transcripts[entry.id] ?? nil else { return entry }
                var entry = entry
                entry.agentSessionID = Self.conversation(ofTranscript: path)
                return entry
            }
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
        let names = sessions.prefix(5).map { "\(ConfigSeal.inert($0.name, limit: 60)) in \(ConfigSeal.inert($0.folder, limit: 120))" }
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
    /// session; its folder one (as the app's `RestartReopen.blocker` says); its conversation an id whose transcript,
    /// `<id>.jsonl` in Claude's folder for that folder, is a regular Claude transcript inside the agents' folders in `home`
    /// (`TranscriptReader.checkedURL`) and not a named agent's (`--name`: a lead, worker or verifier); its model, when the
    /// command it ran named one, a model's name (`Requests.isModelName`). Off the engine's queue (the disk).
    static func reopenable(_ entry: RestartReopen.Entry, home: String,
                           folderExists: (String) -> Bool = RestartReopen.isFolder) -> Result<Reopening, Refused> {
        let shown = ConfigSeal.inert(entry.folder, limit: 200)
        func refused(_ why: String) -> Result<Reopening, Refused> { .failure(Refused("\(ConfigSeal.inert(entry.name, limit: 60)) in \(shown): \(why)")) }
        guard entry.role == .user, entry.agent == .claude else { return refused("not one of your own Claude sessions") }
        guard entry.folder.hasPrefix("/") else { return refused("its folder isn't an absolute path") }
        if let blocker = RestartReopen.blocker(entry, folderExists: folderExists) { return refused(blocker.text.replacingOccurrences(of: "Can't reopen: ", with: "")) }
        guard let id = entry.agentSessionID, UUID(uuidString: id) != nil else { return refused("its conversation id isn't one") }
        let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects").resolvingSymlinksInPath()
        let spellings = [entry.folder, (entry.folder as NSString).standardizingPath, URL(fileURLWithPath: entry.folder).resolvingSymlinksInPath().path]
        let folders = Set(spellings.map { projects.appendingPathComponent(RecentProjects.claudeSlug(for: $0)).path })
        let candidates = folders.sorted().map { URL(fileURLWithPath: $0).appendingPathComponent("\(id).jsonl").path }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return refused("Claude keeps no conversation \(id) for that folder")
        }
        guard let (url, format) = TranscriptReader.checkedURL(path, home: home), format == .claude,
              folders.contains(url.deletingLastPathComponent().path) else {
            return refused("its transcript isn't a Claude transcript inside the agents' folders")
        }
        guard let ends = edges(of: url), ends.range(of: Data(#""agentName":""#.utf8)) == nil else {
            return refused("its conversation is a named agent's (a lead's or its team's), not one of yours")
        }
        var model: String?
        if let command = entry.command, let range = command.range(of: #"--model '?([^' ]*)'?"#, options: .regularExpression) {
            let said = command[range].dropFirst("--model ".count).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard Requests.isModelName(said) else { return refused("its recorded model \(ConfigSeal.inert(said, limit: 64)) isn't a model's name") }
            model = said
        }
        return .success(Reopening(folder: entry.folder, conversation: id.lowercased(), model: model,
                                  cols: (20...500).contains(entry.cols) ? entry.cols : 120, rows: (5...200).contains(entry.rows) ? entry.rows : 36))
    }
}
