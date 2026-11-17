import Combine
import CryptoKit
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// The restart card end to end in the app: a scratch session host (its own socket, lock and key; never the user's)
/// runs fake programs in place of agents, and the app's own client reads it as the app delegate wires it. Nothing is
/// typed into or resumed in a real session: a reopen goes to the test's closures.
@MainActor
@Suite(hostTestLimit) struct RestartOfferTests {
    let temp = Scratch()

    /// A program that only waits: a session that stays live until it's ended.
    static let waiting = "exec /bin/sleep 600"

    final class Host {
        let socket: String
        let key = SymmetricKey(size: .bits256)
        private(set) var server: HostServer?

        init(socket: String) { self.socket = socket }

        func start() throws {
            let launcher = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
            var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                           baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                           hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
            config.idleExit = nil
            config.appKey = key
            config.appExecutable = HostServer.executable(of: getpid())
            let server = HostServer(config: config)
            try server.start()
            self.server = server
        }

        func stop() {
            server?.stop(terminateSessions: true)
            server = nil
            unlink(socket + ".lock")
        }

        /// A client as the app makes one at launch (it never starts a host: `connectIfRunning`).
        /// Short reconnect waits: a host that's gone is called gone quickly.
        func client() -> HostClient { HostClient(socketPath: socket, appKey: { [key] in key }, reconnectDelays: [0.05, 0.05], note: { _ in }) }
    }

    func host() throws -> Host { Host(socket: try temp.shortFolder("vsh-rs") + "/h.sock") }

    func spawn(_ client: HostClient, label: String, agent: String? = "claude", cwd: String) async throws -> HostSession {
        var result: Result<HostSession, HostClientError>?
        client.spawn(SpawnRequest(cwd: cwd, command: Self.waiting, env: [:], cols: 80, rows: 24, keepShell: false, label: label, agent: agent)) {
            result = $0
        }
        #expect(await until { result != nil })
        return try #require(result).get()
    }

    func entry(_ name: String, role: RestartReopen.Role = .user, conversation: String? = "conv-\(UUID().uuidString.prefix(4))",
               folder: String, id: UUID = UUID()) -> RestartReopen.Entry {
        RestartReopen.Entry(id: id, folder: folder, agent: .claude, agentSessionID: conversation, role: role, project: name, name: name,
                            command: "claude", label: role == .lead ? "Lead · \(name)" : "Claude", cols: 120, rows: 36)
    }

    /// An offer on its own record file holding `entries`, its card's showing counted.
    func offer(_ entries: [RestartReopen.Entry]) throws -> (RestartOffer, () -> Int) {
        let file = temp.url("restart").appendingPathComponent("open-sessions.json")
        if !entries.isEmpty { try RestartReopen.save(entries, to: file) }
        let offer = RestartOffer(file: file)
        var shown = 0
        offer.show = { shown += 1 }
        return (offer, { shown })
    }

    @Test func theRecordFollowsSessionsStartingAndEndingAndOutlivesTheHost() async throws {
        let host = try host()
        try host.start()
        defer { host.stop() }
        let folder = temp.url("project").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let client = host.client()
        let (offer, shown) = try offer([])
        let sessions = CurrentValueSubject<[Session], Never>([])
        // An ended session's grace, run by the test.
        var graces: [() -> Void] = []
        offer.later = { _, run in graces.append(run) }
        offer.watchRecord(client, sessions: sessions.eraseToAnyPublisher())
        client.connectIfRunning()
        offer.watchLaunch(client)
        #expect(await until { offer.decided })
        #expect(shown() == 0)
        func recorded() -> [RestartReopen.Entry] { RestartReopen.load(from: offer.file) }

        // Started: written at once, with no quit needed. A worker isn't recorded; nor is a plain shell.
        let mine = try await spawn(client, label: "Claude", cwd: folder)
        _ = try await spawn(client, label: "Worker: fix-login", cwd: folder)
        _ = try await spawn(client, label: "Shell", agent: nil, cwd: folder)
        #expect(await until { recorded().map(\.id) == [mine.id] })
        // Its conversation id, once the store has it from its hooks.
        var scanned = Session(tty: mine.tty, agent: .claude, pid: 1, startedAt: Date(), cwd: folder, project: "project", task: nil,
                              status: .idle, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
        scanned.hostID = mine.id
        scanned.agentSessionID = "conv-1"
        sessions.send([scanned])
        #expect(await until { recorded().first?.agentSessionID == "conv-1" })
        let lead = try await spawn(client, label: "Lead · project", cwd: folder)
        #expect(await until { recorded().map(\.id) == [mine.id, lead.id] })
        #expect(recorded().last?.role == .lead)

        // Ended: it leaves the record once its grace has passed with the Mac still running.
        client.kill(lead.id)
        #expect(await until { graces.count == 1 })
        offer.flushRecord()
        #expect(recorded().map(\.id) == [mine.id, lead.id])
        graces.forEach { $0() }
        #expect(await until { recorded().map(\.id) == [mine.id] })

        // The host goes away (as at a restart): its sessions are marked ended in the app, but the record keeps them.
        host.stop()
        #expect(await until { client.sessions.allSatisfy { !$0.isLive } && client.state == .notRunning })
        #expect(recorded().map(\.id) == [mine.id])
        #expect(recorded().first?.agentSessionID == "conv-1")
    }

    @Test func theMacShuttingDownFreezesTheRecord() throws {
        let (offer, _) = try offer([entry("mine", folder: "/f")])
        offer.decide(hostSessions: [])
        offer.freeze()
        // The sessions the shutdown ends: not yours ending them, so they stay.
        offer.record(hosted: [], sessions: [])
        #expect(RestartReopen.load(from: offer.file).count == 1)
    }

    func hosted(_ entry: RestartReopen.Entry, cols: Int = 120, ended: Bool = false) -> HostSession {
        HostSession(id: entry.id, tty: "/dev/ttys999", childPID: 1, cwd: entry.folder, command: entry.command, label: entry.label, agent: "claude",
                    title: "", startedAt: Date(), cols: cols, rows: 36, exit: ended ? HostSession.Exit(status: 129, at: Date(), signal: 1) : nil)
    }

    /// An Apple-menu Restart whose session exits reach the app before the Mac says it's shutting down: the record
    /// still names them when it freezes, and the next launch offers them.
    @Test func sessionsEndingBeforeThePowerOffNoticeStayInTheRecord() async throws {
        let mine = entry("mine", folder: "/f"), lead = entry("acme", role: .lead, folder: "/r")
        let (offer, _) = try offer([])
        // The ended sessions' graces, apart from the freeze's own wait (which passing means the shutdown was cancelled).
        var graces: [() -> Void] = []
        offer.later = { [limit = offer.freezeLimit] wait, run in if wait != limit { graces.append(run) } }
        offer.decide(hostSessions: [])
        offer.record(hosted: [hosted(mine), hosted(lead)], sessions: [])
        // The host ends them (they're listed ended, then not at all), and only then the power-off notice.
        offer.record(hosted: [hosted(mine, ended: true), hosted(lead, ended: true)], sessions: [])
        offer.record(hosted: [], sessions: [])
        offer.freeze()
        // Their graces pass before the app is ended: nothing leaves a frozen record.
        #expect(graces.count == 2)
        graces.forEach { $0() }
        offer.flushRecord()
        #expect(Set(RestartReopen.load(from: offer.file).map(\.id)) == [mine.id, lead.id])
        let relaunched = RestartOffer(file: offer.file)
        relaunched.decide(hostSessions: nil)
        #expect(await until { relaunched.offered.map(\.id) == [lead.id, mine.id] })
    }

    /// A lead its board no longer names (replaced, still live until closed) isn't recorded: reopened after a restart,
    /// its stale conversation could take the project back from the lead that replaced it.
    @Test func aReplacedLeadIsntRecorded() throws {
        let old = entry("acme", role: .lead, folder: "/r"), new = entry("acme", role: .lead, folder: "/r")
        let (offer, _) = try offer([])
        offer.decide(hostSessions: [])
        offer.record(hosted: [hosted(old), hosted(new)], sessions: [], replacedLeads: [old.id])
        offer.flushRecord()
        #expect(RestartReopen.load(from: offer.file).map(\.id) == [new.id])
    }

    /// Your quit settles the sessions still in their grace (no card for them at the next launch); a SIGTERM's (a
    /// shutdown sends one) keeps them.
    @Test func yourQuitSettlesEndedSessionsAndASignalsKeepsThem() throws {
        for yours in [true, false] {
            let mine = entry("mine", folder: "/f"), ended = entry("ended", folder: "/g")
            let (offer, _) = try offer([])
            offer.later = { _, _ in }
            offer.decide(hostSessions: [])
            offer.record(hosted: [hosted(mine), hosted(ended)], sessions: [])
            offer.record(hosted: [hosted(mine), hosted(ended, ended: true)], sessions: [])
            offer.atQuit(yours: yours)
            #expect(RestartReopen.load(from: offer.file).map(\.id) == (yours ? [mine.id] : [mine.id, ended.id]))
        }
    }

    /// A resize (each step of it) isn't written: only what reopening needs changing is.
    @Test func aResizeAloneDoesntRewriteTheRecord() throws {
        let mine = entry("mine", folder: "/f")
        let (offer, _) = try offer([])
        offer.decide(hostSessions: [])
        offer.record(hosted: [hosted(mine)], sessions: [])
        offer.flushRecord()
        offer.record(hosted: [hosted(mine, cols: 200)], sessions: [])
        offer.flushRecord()
        #expect(RestartReopen.load(from: offer.file).map(\.cols) == [120])
    }

    /// The heading says the Mac restarted only when it started after the record was written: a host that ended on
    /// its own (crashed, killed while the app was closed) is offered too, as sessions that ended.
    @Test func theCardSaysTheMacRestartedOnlyWhenItBootedAfterTheRecord() async throws {
        let file = temp.url("restart").appendingPathComponent("open-sessions.json")
        try RestartReopen.save([entry("mine", folder: "/f")], to: file, at: Date(timeIntervalSince1970: 0))
        let beforeBoot = RestartOffer(file: file)
        beforeBoot.decide(hostSessions: nil)
        #expect(await until { beforeBoot.offered.count == 1 })
        #expect(beforeBoot.macRestarted)
        try RestartReopen.save([entry("mine", folder: "/f")], to: file)
        let sinceBoot = RestartOffer(file: file)
        sinceBoot.decide(hostSessions: nil)
        #expect(await until { sinceBoot.offered.count == 1 })
        #expect(!sinceBoot.macRestarted)
    }

    @Test func aNewHostWithoutTheRecordedSessionsShowsTheCard() async throws {
        let host = try host()
        try host.start()
        defer { host.stop() }
        let lead = entry("acme", role: .lead, folder: "/r"), mine = entry("mine", folder: "/f")
        let (offer, shown) = try offer([mine, lead])
        let client = host.client()
        client.connectIfRunning()
        offer.watchLaunch(client)
        #expect(await until { offer.decided })
        #expect(await until { shown() == 1 })
        #expect(offer.offered.map(\.id) == [lead.id, mine.id])
    }

    @Test func noHostRunningShowsTheCard() async throws {
        let host = try host()   // never started: a Mac just restarted
        let mine = entry("mine", folder: "/f")
        let (offer, shown) = try offer([mine])
        let client = host.client()
        client.connectIfRunning()
        offer.watchLaunch(client)
        #expect(offer.decided)
        #expect(await until { shown() == 1 })
        #expect(offer.offered.map(\.id) == [mine.id])
    }

    @Test func anAppRelaunchedOntoItsRunningHostShowsNoCard() async throws {
        let host = try host()
        try host.start()
        defer { host.stop() }
        let folder = temp.url("project").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // The app before: a session open, recorded.
        let before = host.client()
        before.connectIfRunning()
        #expect(await until { before.state == .connected })
        let running = try await spawn(before, label: "Claude", cwd: folder)
        let ended = try await spawn(before, label: "Claude", cwd: folder)
        // One ended while the app was away: still no restart.
        before.kill(ended.id)
        #expect(await until { before.sessions.first { $0.id == ended.id }?.isLive == false })
        let (offer, shown) = try offer([entry("mine", folder: folder, id: running.id), entry("other", folder: folder, id: ended.id)])
        // The app relaunched: a new client reattaches to the same host.
        let client = host.client()
        client.connectIfRunning()
        offer.watchLaunch(client)
        #expect(await until { offer.decided })
        #expect(client.sessions.contains { $0.id == running.id && $0.isLive })
        #expect(shown() == 0)
        #expect(offer.offered.isEmpty)
    }

    /// A relaunch onto the running host that doesn't take this app's proof (its Keychain key denied or replaced): the
    /// host lists none of its sessions to the app, which is no restart. No card, and the record isn't emptied.
    @Test func aHostThatRefusesTheAppsProofShowsNoCardAndKeepsTheRecord() async throws {
        let host = try host()
        try host.start()
        defer { host.stop() }
        let folder = temp.url("project").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let before = host.client()
        before.connectIfRunning()
        #expect(await until { before.state == .connected })
        let running = try await spawn(before, label: "Claude", cwd: folder)
        let (offer, shown) = try offer([entry("mine", folder: folder, id: running.id)])
        // The relaunched app with another key.
        let client = HostClient(socketPath: host.socket, appKey: { SymmetricKey(size: .bits256) }, reconnectDelays: [0.05], note: { _ in })
        client.confirmKeyReset = { _, _ in false }
        offer.watchRecord(client, sessions: Just([]).eraseToAnyPublisher())
        client.connectIfRunning()
        offer.watchLaunch(client)
        #expect(await until { offer.decided })
        #expect(client.proofRefusal != nil)
        #expect(shown() == 0)
        #expect(offer.offered.isEmpty)
        // Its (empty) list doesn't reach the record.
        #expect(await until { client.state == .connected })
        // What the record's watch was handed by then (on the main queue, in order) has landed.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(RestartReopen.load(from: offer.file).map(\.id) == [running.id])
    }

    /// Asked once: answered (here dismissed) with no session opened since, a relaunch doesn't ask again.
    @Test func anAnsweredCardDoesntComeBackAtTheNextLaunch() async throws {
        let (offer, shown) = try offer([entry("mine", folder: "/f"), entry("acme", role: .lead, folder: "/r")])
        offer.decide(hostSessions: nil)
        #expect(await until { shown() == 1 })
        offer.dismiss()
        offer.flushRecord()
        // The app relaunched, still no host running.
        let relaunched = RestartOffer(file: offer.file)
        var shownAgain = 0
        relaunched.show = { shownAgain += 1 }
        relaunched.decide(hostSessions: nil)
        #expect(shownAgain == 0)
        #expect(relaunched.offered.isEmpty)
    }

    /// A shutdown that's cancelled (an app with unsaved work said no): the record follows the sessions again, from
    /// what they are by then.
    @Test func aCancelledShutdownThawsTheRecord() throws {
        let kept = entry("kept", folder: "/f")
        let (offer, _) = try offer([kept])
        var waits: [() -> Void] = []
        offer.later = { _, run in waits.append(run) }
        offer.decide(hostSessions: [])
        offer.freeze()
        // Closed while frozen: not recorded yet.
        offer.record(hosted: [], sessions: [])
        #expect(RestartReopen.load(from: offer.file).map(\.id) == [kept.id])
        // The shutdown never came.
        #expect(waits.count == 1)
        waits.forEach { $0() }
        #expect(!offer.frozen)
        offer.flushRecord()
        #expect(RestartReopen.load(from: offer.file).isEmpty)
    }

    @Test func anEmptyRecordShowsNoCard() async throws {
        let host = try host()
        let (offer, shown) = try offer([])
        let client = host.client()
        client.connectIfRunning()
        offer.watchLaunch(client)
        #expect(offer.decided)
        #expect(shown() == 0)
    }

    final class Reopened {
        var calls: [String] = []
    }

    func reopening(_ entries: [RestartReopen.Entry]) async throws -> (RestartOffer, Reopened) {
        let (offer, _) = try offer(entries)
        let reopened = Reopened()
        offer.resumeSession = { request in reopened.calls.append("session \(request.cwd) \(request.command ?? "")") }
        offer.reopenLead = { root, conversation in reopened.calls.append("lead \(root) \(conversation)") }
        var closed = 0
        offer.close = { closed += 1 }
        offer.folderExists = { $0 != "/gone" }
        offer.decide(hostSessions: nil)
        #expect(await until { offer.offered.count == entries.count })
        return (offer, reopened)
    }

    @Test func reopenAllResumesEachLeadsFirstAndSkipsWhatCantBeResumed() async throws {
        let mine = entry("mine", conversation: "c-1", folder: "/f"), lead = entry("acme", role: .lead, conversation: "c-2", folder: "/r")
        let noID = entry("no-id", conversation: nil, folder: "/f"), gone = entry("gone", conversation: "c-3", folder: "/gone")
        let (offer, reopened) = try await reopening([mine, noID, gone, lead])
        #expect(offer.offered.count == 4)
        #expect(offer.blocker(noID) == .noConversation && offer.blocker(gone) == .folderGone)
        // Choose starts with only those that can be reopened ticked.
        #expect(offer.chosen == [mine.id, lead.id])
        offer.reopenAll()
        #expect(reopened.calls == ["lead /r c-2", "session /f claude --resume 'c-1'"])
        #expect(offer.offered.isEmpty)
    }

    @Test func chooseResumesOnlyTheTickedOnes() async throws {
        let mine = entry("mine", conversation: "c-1", folder: "/f"), other = entry("other", conversation: "c-4", folder: "/g")
        let lead = entry("acme", role: .lead, conversation: "c-2", folder: "/r")
        let (offer, reopened) = try await reopening([mine, other, lead])
        offer.choosing = true
        offer.chosen = [other.id]
        offer.reopenChosen()
        #expect(reopened.calls == ["session /g claude --resume 'c-4'"])
    }

    @Test func dismissingReopensNothing() async throws {
        let (offer, reopened) = try await reopening([entry("mine", folder: "/f"), entry("acme", role: .lead, folder: "/r")])
        offer.dismiss()
        #expect(reopened.calls.isEmpty)
        #expect(offer.offered.isEmpty)
        // Asked once: a second launch decision in the same run doesn't ask again.
        offer.decide(hostSessions: nil)
        #expect(offer.offered.isEmpty)
    }
}

private final class Anchor {}
