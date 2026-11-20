import Foundation
import VibeCore

/// A running lead the vault gives no role (`LeadEngine.roleless`): its session, and what `status` says of it.
public struct Roleless: Equatable, Sendable {
    public var session: UUID
    public var text: String
}

/// The engine across restarts (the engine plan's E8; the app's `keepRunningLeads` and `keepRunning`,
/// `LeadController.swift` 960-993, and the rebind of `startLead(root:running:)`, 915-950, which `LeadStart` keeps).
///
/// **At every server start** the engine reads `engine.json` (`restoreState`): the held messages (a `.user` one the
/// user's only when the vault's record of the user's actions holds its action, EN-D9), the witness's told keys and
/// auto_advance's first sightings (so nothing is told or nudged twice), the last host start it saw and the roots with a
/// lead under that host. At its first welcome each live lead session the vault binds the role to is bound to it again
/// (`keepRunningLeads`); one it doesn't bind is left as it is and `status` says so. The cards were in the old server's
/// memory, so each lead is told which of its open questions the user no longer sees (`tellUnshownQuestions`), and asks
/// again those it needs. Answers and holds are taken only from the user at the command line (E6): nothing at rest is.
///
/// **After a host restart** (the welcome's start time isn't the one `engine.json` holds) every project's lead and team
/// ended with the old host, and its vault started over: `status` says the team is gone, project by project, until a lead
/// starts there again, and gives the restart for the command line to show with how the host ended and whether a
/// `vibeswitcher start` explains it (the journal's, EN-D15). What the user then runs (`config held`, `config accept`,
/// `base show`, `base accept`) is E6's, with the snapshot of the last accept (`AcceptedSnapshot`) as a diff aid.
extension LeadEngine {
    /// Takes back what `engine.json` holds (at the engine's start, before anything is asked of it).
    func restoreState() {
        let loaded = EngineState.load(root: root)
        if let problem = loaded.problem { note("engine state: \(problem)") }
        let state = loaded.state
        restoreHeld(state.held)
        told = Set(state.told ?? [])
        advanceSeen = (state.firstSightings ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
        lastHostStart = state.hostStartedAt
        knownLeads = Set(state.leads ?? [])
        hostRestart = state.restart
        reopen = state.reopen ?? [:]
        openSessions = state.open
        endedSessions = state.ended ?? []
    }

    /// Everything `engine.json` keeps, as it is now. On `queue`.
    func stateAtRest() -> EngineState {
        EngineState(held: heldAtRest(), told: told.sorted(), firstSightings: advanceSeen.mapValues(\.timeIntervalSince1970),
                    hostStartedAt: lastHostStart, leads: knownLeads.sorted(), restart: hostRestart,
                    reopen: reopen.isEmpty ? nil : reopen, open: openSessions,
                    ended: endedSessions.isEmpty ? nil : endedSessions)
    }

    /// `engine.json` written on `reads` (in order with every other write there). On `queue`.
    func saveState() {
        let (state, root) = (stateAtRest(), self.root)
        reads.async({ _ in Result { try state.save(root: root) } }) { [weak self] saved in
            if case .failure(let error) = saved { self?.note("engine state: \(EngineState.url(root: root).path) not written: \(error)") }
        }
    }

    /// The roots with a lead running now join those `engine.json` keeps (a host restart ends them). On `queue`.
    func noteKnownLeads() {
        noteReopen()
        noteOpenSessions()
        let running = Set(leads.leads.values.filter { $0.session != nil }.map(\.root))
        guard !running.isSubset(of: knownLeads) else { return }
        knownLeads.formUnion(running)
        saveState()
    }

    /// At each welcome (`welcomed`): a host start other than the one `engine.json` holds is a host restart; this engine's
    /// first welcome is the server's start, where the running leads are bound again and, when the same host welcomed
    /// the server before it, told which questions the user no longer sees. On `queue`.
    func restartLook() {
        let first = !welcomedOnce
        welcomedOnce = true
        if let started = link.hostStartedAt?.timeIntervalSince1970 {
            if let last = lastHostStart, abs(last - started) > 0.001 {
                hostRestarted(at: started, before: last)
            } else if first, lastHostStart != nil {
                tellUnshownQuestions()
            }
            if lastHostStart.map({ abs($0 - started) > 0.001 }) ?? true {
                lastHostStart = started
                saveState()
            }
        }
        if first || rebindAgain { keepRunningLeads() }
    }

    /// The host that welcomed the engine isn't the one before (`at`, `before`): every project's lead and team ended with
    /// the old one, and its vault started over. Said in the log and, project by project, in `status`. What was held for
    /// a lead that ended with it is dropped, project by project in the log: a lead started later never gets the old
    /// team's news or an answer to a question it didn't ask. On `queue`.
    func hostRestarted(at: Double, before: Double) {
        let gone = knownLeads.union(hostRestart?.gone ?? []).union(heldAtRest().map(\.root))
        hostRestart = EngineState.Restart(at: at, before: before, gone: gone.sorted(), sessions: endedSessions(before: before))
        openSessions = nil
        knownLeads = Set(leads.leads.values.filter { $0.session != nil }.map(\.root))
        for root in gone.sorted() {
            let dropped = leads.takeHeld(project: NodeIds.project(root: root))
            guard !dropped.isEmpty else { continue }
            note("the session host restarted: dropped \(dropped.count) message(s) held for the lead of \(LeadMail.project(of: root)), "
                 + "which ended with it")
        }
        note("the session host restarted (it started at \(NodeWire.dateText(Date(timeIntervalSince1970: at))), the one before at "
             + "\(NodeWire.dateText(Date(timeIntervalSince1970: before)))): "
             + (gone.isEmpty ? "no lead ran under the old one" : "the leads and teams of \(gone.sorted().map { LeadMail.project(of: $0) }.joined(separator: ", ")) ended with it")
             + "; its vault started over")
        saveState()
    }

    /// A lead started in `root`: a host restart's notice for it is over, and so is a notice of a lead without its role
    /// there. On `queue`.
    func teamStarted(root: String) {
        roleless[root] = nil
        guard var restart = hostRestart, restart.gone.contains(root) else { return }
        restart.gone.removeAll { $0 == root }
        hostRestart = restart
        saveState()
    }

    /// What `status` says of a host restart, one notice per project whose team it ended, until a lead starts there.
    var restartNotices: [String] {
        guard let restart = hostRestart else { return [] }
        let at = NodeWire.dateText(Date(timeIntervalSince1970: restart.at))
        return restart.gone.map { root in
            "the session host restarted at \(at): the lead and team of \(LeadMail.project(of: root)) (\(root)) ended with the host before it, "
                + "and its vault started over (" + Self.resetByRestart + "). Run `vibeswitcher config held \(root)`, `config accept CARD`, "
                + "`base show \(root)` and `base accept CARD`, reading the values, then " + reopenStep(root: root)
        } + sessionsNotice(restart, at: at)
    }

    /// What a host restart resets (the security document's S7).
    public static let resetByRestart = "the team's roles and grants, verdicts, audits, approvals, the recorded heads, the guard rails' hashes, "
        + "the review floor, the config seal and the user's sealing key"

    /// `status`'s `restart`: the last host restart, while a project's notice stands. On `queue`.
    var restartValue: NodeWire.Value {
        guard let restart = hostRestart else { return .null }
        return .object(["at": .date(Date(timeIntervalSince1970: restart.at)), "before": .date(Date(timeIntervalSince1970: restart.before)),
                        "gone": .array(restart.gone.map(NodeWire.Value.string)), "reset": .string(Self.resetByRestart),
                        "sessions": .int(restart.sessions?.count ?? 0)])
    }

    // MARK: The server's start

    /// Each live lead session the vault binds its project's lead role to, bound to it again (the app's
    /// `keepRunningLeads`, `LeadController` 960-993): which lead holds each root is read from its board on `reads`, the
    /// vault asked off the engine's queue. One the vault gives no role (it binds the role to no session, or another) is
    /// left as it is: `status` says so while it runs. Each session once; one the vault couldn't be asked about, or a
    /// pass the link dropped under (before its board read or after it), is tried again at the next refresh or welcome.
    /// On `queue`.
    func keepRunningLeads() {
        guard !keepingRunning else { return }
        guard link.state == .connected else {
            rebindAgain = true
            return
        }
        keepingRunning = true
        rebindAgain = false
        let sessions = link.sessions
        reads.async({ files in LeadStore.leadSessions(sessions) { files.names.board($0).leadSession } }) { [weak self] running in
            guard let self else { return }
            self.keepingRunning = false
            guard self.link.state == .connected else {
                self.rebindAgain = true
                return
            }
            self.keepRunning(running)
        }
    }

    private func keepRunning(_ running: [String: HostSession]) {
        let vault = link.vault
        for (root, session) in running.sorted(by: { $0.key < $1.key }) where adopting.insert(session.id).inserted {
            let project = LeadMail.project(of: root)
            work.async { [weak self] in
                let kept: Result<LeadVault.Member?, Error> = Result { try vault.rebindLead(root: root, session: session.id.uuidString) }
                guard let self else { return }
                self.queue.async {
                    switch kept {
                    case .failure(let error):
                        self.note("lead: couldn't bind the running lead of \(project) again: \(error)")
                        self.adopting.remove(session.id)
                        self.rebindAgain = true
                    case .success(.some):
                        self.note("lead: kept the running lead of \(project) (session \(session.id.uuidString.prefix(8)))")
                        self.roleless[root] = nil
                        self.leads.lead(root: root) { $0.bound = session.id.uuidString }
                    case .success(.none):
                        self.note("lead: the running lead of \(project) (session \(session.id.uuidString.prefix(8))) holds no role in the vault; left as it is")
                        self.roleless[root] = Roleless(session: session.id, text:
                            "the lead of \(project) runs (session \(session.id.uuidString.prefix(8))) but the vault binds its role to no session or "
                            + "another, so its tools are off and nothing is sent to it: `vibeswitcher lead \(root) --replace` starts a lead that takes the role")
                    }
                }
            }
        }
    }

    /// `status`'s notices for the running leads without their role, while each runs. On `queue`.
    var rolelessNotices: [String] {
        let live = Set(link.sessions.filter(\.isLive).map(\.id))
        return roleless.sorted { $0.key < $1.key }.filter { live.contains($0.value.session) }.map(\.value.text)
    }

    /// The server restarted under the same host: the cards were in the old server's memory, so each running lead is told
    /// which of its open questions the user no longer sees (its board's open questions with no card here), once, to
    /// withdraw them and ask again those it still needs. The boards are read on `reads`. On `queue`.
    func tellUnshownQuestions() {
        let roots = leadRoots
        guard !roots.isEmpty else { return }
        reads.async({ files in
            Dictionary(uniqueKeysWithValues: roots.map { root in (root, files.board(root).questions.filter { $0.state == .open }) })
        }) { [weak self] open in
            guard let self else { return }
            for (root, questions) in open.sorted(by: { $0.key < $1.key }) {
                let unshown = questions.filter { self.cards.card(question: $0.id, root: root) == nil }
                guard !unshown.isEmpty else { continue }
                self.note("lead: told \(LeadMail.project(of: root))'s lead that the user no longer sees \(unshown.count) of its open questions (the server restarted)")
                let text = Self.unshownText(unshown)
                self.deliver(built: { text }, from: .system("vibeswitcher"), root: root, action: nil)
            }
        }
    }

    /// What a lead is told of its open questions the user no longer sees after a server restart.
    static func unshownText(_ questions: [LeadQuestion]) -> String {
        let listed = questions.map { "\($0.short) “\(ConfigSeal.inert($0.text, limit: 200))” (id \($0.id))" }.joined(separator: "; ")
        return "This node's server restarted, and the cards the user answers were in its memory: the user no longer sees your open "
            + "question\(questions.count == 1 ? "" : "s") \(listed). \(questions.count == 1 ? "It's" : "They're") still on your board, but no answer "
            + "can come. For each you still need, withdraw it (withdraw_question, saying it's asked again) and ask it again with ask_user; "
            + "withdraw the rest."
    }
}
