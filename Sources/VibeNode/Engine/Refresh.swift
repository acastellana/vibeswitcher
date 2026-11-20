import Foundation
import VibeCore

/// The engine's refresh (the engine plan's E7; the app's `LeadController.refresh`, `refreshed` and `sweepRoles`,
/// `LeadController.swift` 1469-1582): every 3 s on the engine's clock (the design's recorded exception to "never from a
/// timer", which stage 3's stores remove) and after each answer. The starts that waited go on and the role sweep looks
/// (every 6 s at most), and the posted questions' timers run from their cards (`fireTimers`, never the boards'); then,
/// on `reads`, the boards, which lead each board names, the base moves' refusals, the team readings and the finished
/// tasks' ended sessions are read; then `refreshed`, on the engine's queue, keeps the boards, marks the replaced leads,
/// looks at the two card stores, keeps the notices for `status` (`Requests.statusValue`), runs the witness for each
/// lead, drops the finished tasks' ended sessions and the wakes and waiting counts of leads that ended. Nothing the refresh reads is read on the engine's queue.
///
/// Not here, as the app has it: the power watch, not needed on Linux (2026-11-19, the parity table: a node runs on a
/// server or WSL on mains, and has no battery limit setting for a hold to be under): nothing writes `power.json` under
/// the node's root, so its leads' battery hold (`LeadToolset.checkBattery`, `LeadPipeline.Signals.batteryHold`, both
/// from `PowerState.load`) reads no state and never holds. Team activity and keep-awake (the Mac's, and after the bootstrap); the all-done watch
/// (after the bootstrap); the lead's rotation is here (`rotateIfDue`, `IdleHandover.swift`); the account watch (after the bootstrap). `keepRunningLeads` (E8's) runs at
/// the server's start, and again here only when the vault couldn't be asked then. The board's questions aren't told
/// from here (`AlertRules.look`): the user sees only the cards the lead's tool server posts (S3, E6), and the all-done
/// mark is after the bootstrap. The host's notes are asked by the server's housekeeping and at each `status`
/// (`Requests.refreshNotes`), not every 3 s.
extension LeadEngine {
    /// A refresh, on the engine's queue. From any thread.
    public func refresh() {
        queue.async { [weak self] in self?.refreshNow() }
    }

    /// The roots with a lead running now: the live lead sessions in the host's list (the app's `leadRoots`), and the
    /// leads the store has a session for.
    var leadRoots: Set<String> {
        Set(link.sessions.filter { $0.isLive && LeadTeams.role(label: $0.label) == .lead }.map { ($0.cwd as NSString).standardizingPath })
            .union(leads.leads.values.filter { $0.session != nil }.map(\.root))
    }

    /// On `queue`.
    func refreshNow() {
        startPending()
        if !promptAuditLooked { lookAtPromptAudits() }
        // A running lead the vault couldn't be asked about at the server's start is bound again now (E8).
        if rebindAgain { keepRunningLeads() }
        sweepRoles()
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        let roots = leadRoots
        let timerRoots = self.timerRoots.union(roots)
        // The sessions as they are now, for the witness to read its teams' transcripts with (see `TeamReading`).
        let hosted = Dictionary(link.sessions.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let scanned = Dictionary((sessions?.sessions ?? []).compactMap { session in session.hostID.map { ($0.uuidString, session) } },
                                 uniquingKeysWith: { first, _ in first })
        let (observer, inbox, lock) = (observer, root, options.lock)
        // The posted questions' timers, from their cards (never the boards': S3).
        fireTimers(now: timersNow())
        reads.async({ files -> Refreshed in
            var read = Refreshed()
            for root in roots { read.loaded[root] = files.board(root) }
            // Which lead each board names, through the names' own read (the replaced leads' marks).
            for root in roots { read.named[root] = files.names.board(root).leadSession.flatMap(UUID.init(uuidString:)) }
            read.refusals = Dictionary(uniqueKeysWithValues: roots.compactMap { root in LeadVault.BaseMoveRefusal.load(root: root).map { (root, $0) } })
            files.keep(roots.union(timerRoots))
            read.teams = Dictionary(uniqueKeysWithValues: read.loaded.map { root, board in
                (root, TeamReading.read(root: root, board: board, hosted: hosted, sessions: scanned, observer: observer, inbox: inbox, lock: lock))
            })
            read.finished = Set(read.loaded.flatMap { root, board in LeadTeams.finished(Array(hosted.values), root: root, board: board) })
            return read
        }) { [weak self] read in
            guard let self else { return }
            self.markReplaced(read.named, roots: roots)
            self.refreshed(roots: roots, loaded: read.loaded, teams: read.teams, refusals: read.refusals, finished: read.finished)
            self.refreshing = false
            if self.refreshAgain {
                self.refreshAgain = false
                self.refreshNow()
            }
        }
    }

    /// What a refresh's reads found.
    struct Refreshed {
        var loaded: [String: LeadBoard] = [:]
        var named: [String: UUID?] = [:]
        var refusals: [String: LeadVault.BaseMoveRefusal] = [:]
        var teams: [String: TeamReading] = [:]
        var finished: Set<UUID> = []
    }

    /// The lead sessions marked replaced, from which session each root's board names (the app's `markReplaced`,
    /// 1291-1329): the store's marks, with what the start of a root under way keeps as it is. On `queue`.
    func markReplaced(_ named: [String: UUID?], roots: Set<String>) {
        for root in roots where starting[root] == nil {
            let holder = named[root] ?? nil
            holders[root] = holder
            if leads.leads[NodeIds.project(root: root)]?.named != holder?.uuidString { leads.lead(root: root) { $0.named = holder?.uuidString } }
        }
        leads.update(sessions: link.sessions, holders: holders)
        noteKnownLeads()
    }

    /// What a refresh read, on the engine's queue (the app's `refreshed`, 1526-1562). `finished`: the ended sessions of
    /// the boards' finished tasks, among the sessions as they were when the read began (see `forgetFinished`).
    func refreshed(roots: Set<String>, loaded: [String: LeadBoard], teams: [String: TeamReading],
                   refusals: [String: LeadVault.BaseMoveRefusal], finished: Set<UUID> = []) {
        noteAllDone(previous: boards, loaded: loaded)
        if loaded != boards { boards = loaded }
        // A lead with a question or approval card open needs the user (`Session.leadAsks`).
        cardsChanged()
        lookAtBases()
        lookAtConfig()
        retireTaken()
        // A base move that refused one of the lead's merges waits on the user: in `status` while it does (the app's
        // alert), and in the log once per move while it stands.
        var standing: [String: [String]] = [:]
        var keys: Set<String> = []
        for (root, board) in loaded.sorted(by: { $0.key < $1.key }) {
            if case .broken(let title, let body, _, let key)? = AlertRules.baseMoved(baseMoves.asking[root], refused: refusals[root], root: root,
                                                                                    leadTTY: board.leadTTY) {
                let said = ConfigSeal.inert(title + ": " + body, limit: 400)
                standing[root, default: []].append(said)
                keys.insert(key ?? title)
                if !noticed.contains(key ?? title) { note("lead: \(said)") }
            }
            witness(root: root, board: board, team: teams[root] ?? TeamReading())
            rotateIfDue(root: root)
        }
        // A push the lead asked for (push_remote): in `status` while it's open, saying the commands that settle it.
        for (root, request) in pushAsked where roots.contains(root) {
            standing[root, default: []].append(Self.pushNotice(request, root: root))
        }
        if standing != notices { notices = standing }
        noticed = keys
        lookAtPushes(roots: roots)
        forgetFinished(finished)
        // A lead that ended, or another agent on its terminal now: its wake-ups and its waiting count go (the app's
        // `ReportsWaiting.keep`).
        let live = Set(loaded.values.compactMap { board in board.leadTTY.flatMap { tty in board.leadPid.map { "\(tty)#\($0)" } } })
        wakes = wakes.filter { live.contains($0.key) }
        for lead in leads.leads.values where lead.reportsWaiting != 0 && loaded[lead.root]?.leadTTY == nil {
            reportsWaiting(0, root: lead.root)
        }
    }

    /// Every 6 s at most, off the engine's queue: the finished tasks' role sessions end, in every project (`RoleSweep`).
    /// On `queue`.
    func sweepRoles(now: Date = Date()) {
        guard let roleSweep, !sweeping, now.timeIntervalSince(sweptAt) >= 6 else { return }
        sweeping = true
        sweptAt = now
        let hosted = link.sessions
        let agents = Dictionary((sessions?.sessions ?? []).compactMap { session in session.hostID.map { ($0, session) } },
                                uniquingKeysWith: { first, _ in first })
        roleSweep.queue.async { [weak self] in
            roleSweep.look(hosted: hosted, idleSince: { hosted in
                // Idle since its turn ended; with no agent known on it (its shell left), since it started.
                guard let agent = agents[hosted.id] else { return hosted.startedAt.timeIntervalSince1970 }
                return agent.status == .working ? nil : agent.statusSince.timeIntervalSince1970
            }, agent: { hosted in
                let pid = agents[hosted.id]?.pid ?? hosted.childPID
                return (pid, ProcessTable.residentBytes(pid: pid))
            })
            guard let engine = self else { return }
            engine.queue.async { engine.sweeping = false }
        }
    }

    /// The role sweep on the host's vault and the link: its ends through `HostLink.kill`, what it can't end told to
    /// every running lead, and the roster's times handed to the witness, on the engine's queue.
    func makeRoleSweep() -> RoleSweep {
        let vault = link.vault
        let sweep = RoleSweep(roster: { try vault.roster() }, end: { [weak self] session in
            self?.link.kill(session.id)
        }, tell: { [weak self] text in
            guard let engine = self else { return }
            engine.queue.async { engine.tellStranded(text) }
        })
        sweep.note = note
        sweep.submitted = { [weak self] submitted in
            guard let engine = self else { return }
            engine.queue.async { engine.submitted = submitted }
        }
        sweep.tools = { [weak self] tools in
            guard let engine = self else { return }
            engine.queue.async { engine.toolTimes = tools }
        }
        return sweep
    }
}
