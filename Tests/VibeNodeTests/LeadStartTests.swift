import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Starting a lead (the engine plan's E4), on a scratch host in the test process (`NodeTestHost`), the engine given
/// `FakeClaude`'s launcher as its `claude` link (EN-D13), its own root and its own engine queue: the app's start cases
/// (`LeadRelaunchTests`, `LeadStartsHostTests`, `ReplacedLeadRoutingTests`, `ProjectFolderStartTests`) restated on the
/// engine, where a dialog is a flag and an alert a refusal, and the security cases of S3 and S7.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct LeadStartTests {
    private let scratch = Scratch()

    /// A host, a repository with one commit, the fake as `claude`, a build folder holding the tool server, and the
    /// engine on a link to the host (welcomed unless `connect` is false).
    final class World: @unchecked Sendable {
        let host: NodeTestHost
        let fake: FakeClaude.Install
        let repo: String
        let link: HostLink
        let engine: LeadEngine
        let queue = DispatchQueue(label: "lead-start-tests.engine")
        let key = DispatchSpecificKey<Bool>()
        let spawns = Locked<[SpawnRequest]>([])

        init(host: NodeTestHost, fake: FakeClaude.Install, repo: String, options: LeadEngine.Options, timing: HostLink.Timing = HostLink.Timing()) throws {
            self.host = host
            self.fake = fake
            self.repo = repo
            queue.setSpecific(key: key, value: true)
            let nodeRoot = host.folder.appendingPathComponent("build", isDirectory: true)
            try FileManager.default.createDirectory(at: nodeRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: nodeRoot.appendingPathComponent("bin/vibeswitcher-mcp").path,
                                                        withDestinationPath: builtProducts.appendingPathComponent("vibeswitcher-mcp").path)
            link = HostLink(dialer: host.dialer, root: host.root, queue: queue, timing: timing)
            engine = LeadEngine(root: host.root, nodeRoot: nodeRoot, link: link, clock: nil, options: options)
            let (engine, spawns) = (engine, spawns)
            link.onWelcome = { _, _ in engine.welcomed() }
            queue.sync { engine.spawning = { request in spawns.mutate { $0.append(request) } } }
        }

        var project: String { NodeIds.project(root: repo) }
        var name: String { (repo as NSString).lastPathComponent }

        /// Whether the calling code runs on the engine's queue.
        var onEngine: Bool { DispatchQueue.getSpecific(key: key) == true }

        func connect() async {
            link.start()
            _ = await eventually(timeout: 60) { self.queue.sync { self.link.state == .connected } }
        }

        func start(_ folder: String? = nil, goal: String? = nil, takeHead: Bool = false, replace: Bool = false) async -> LeadEngine.StartOutcome {
            // Waited on, not awaited as a continuation: a start that never answers fails the test, it doesn't hang it.
            let answer = Locked<LeadEngine.StartOutcome?>(nil)
            engine.startLead(folder: folder ?? repo, goal: goal, takeHead: takeHead, replace: replace) { answer.value = $0 }
            _ = await eventually(timeout: 180) { answer.value != nil }
            return answer.value ?? .refused("the test: no answer to the start in 180 s")
        }

        /// The host's live lead sessions for the repository.
        func leads() -> [HostSession] {
            ((try? host.sessions()) ?? []).filter { $0.isLive && $0.label == "Lead · \(name)" }
        }

        /// The project's lead as the engine's store has it now.
        var stored: LeadStore.Lead? { queue.sync { engine.leads.leads[project] } }

        func held() -> [LeadStore.Held] { queue.sync { engine.leads.held[project] ?? [] } }

        /// The session the vault binds the lead's role to.
        func holder() -> String? { host.vault.current(.lead, root: repo, task: nil)?.session }

        func stop() { host.stop() }

        /// How many requests wait on the start of the repository under way (the first, and each that joined it).
        var waitingOnTheStart: Int { queue.sync { engine.starting[repo]?.count ?? 0 } }

        /// The repository's first board look (the start's, on the reads queue) waits until `gate` opens.
        func holdTheFirstLook(at gate: Gate) {
            let repo = self.repo
            queue.sync { engine.boardLooked = { root in if root == repo { gate.pass() } } }
        }
    }

    /// The first `pass` waits until `open` (at most 120 s, a guard); the others go through.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private let opened = DispatchSemaphore(value: 0)

        func pass() {
            let first = lock.withLock { () -> Bool in
                defer { entered = true }
                return !entered
            }
            if first { _ = opened.wait(timeout: .now() + 120) }
        }

        var reached: Bool { lock.withLock { entered } }
        func open() { opened.signal() }
    }

    /// `claudeLink`: nil for the fake's launcher through a link of its own; `connect`: welcome the link first.
    func world(holdsFirstLook: Bool = false, allowList: URL? = nil, claudeLink: String?? = nil, git: String? = nil, firstLook: Bool = false,
               connect: Bool = true, repository: Bool = true, timing: HostLink.Timing = HostLink.Timing()) async throws -> World {
        let host = try NodeTestHost(scratch, holdsFirstLook: holdsFirstLook, projectAllowList: allowList)
        let fake = try FakeClaude.install(in: host.folder.appendingPathComponent("fake", isDirectory: true))
        let repo = host.folder.appendingPathComponent("repo", isDirectory: true)
        if repository { try await scratchRepository(repo) } else { try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true) }
        var options = LeadEngine.Options()
        switch claudeLink {
        case .none:
            let link = host.folder.appendingPathComponent("claude-link").path
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fake.launcher.path)
            options.claudeLink = link
        case .some(let given):
            options.claudeLink = given
        }
        if let git { options.git = git }
        options.firstLook = firstLook
        options.answersTrust = false
        options.home = host.home.path
        let world = try World(host: host, fake: fake, repo: repo.resolvingSymlinksInPath().path, options: options, timing: timing)
        if connect { await world.connect() }
        return world
    }

    private func session(_ outcome: LeadEngine.StartOutcome) -> UUID? {
        switch outcome {
        case .started(let session, _, _), .shown(let session, _): return session
        default: return nil
        }
    }

    private func started(_ outcome: LeadEngine.StartOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> UUID {
        guard case .started(let session, _, _) = outcome else {
            Issue.record("not started: \(outcome)", sourceLocation: sourceLocation)
            throw HarnessError.timedOut
        }
        return session
    }

    // MARK: The plan and the host's welcome

    /// LeadRelaunchTests' first case: the plan is `.wait` before the host's welcome; then the start goes on after it.
    @Test func aStartAskedBeforeTheHostsWelcomeWaitsForItsSessions() async throws {
        let running = UUID()
        // Before the link's welcome the session list is empty: no lead start is decided on it.
        #expect(LeadEngine.plan(hostState: .connecting, running: nil, holdsRole: nil, fromUser: true) == .wait)
        #expect(LeadEngine.plan(hostState: .connected, running: nil, holdsRole: nil, fromUser: true) == .start)
        #expect(LeadEngine.plan(hostState: .connected, running: running, holdsRole: true, fromUser: true) == .show(running))
        // Without its role: replaced only when asked; never by a start not from the user, nor while the vault can't
        // be asked.
        #expect(LeadEngine.plan(hostState: .connected, running: running, holdsRole: false, fromUser: true) == .askToReplace(running))
        #expect(LeadEngine.plan(hostState: .connected, running: running, holdsRole: false, fromUser: false) == .show(running))
        #expect(LeadEngine.plan(hostState: .connected, running: running, holdsRole: nil, fromUser: true) == .show(running))

        let world = try await world(connect: false)
        defer { world.stop() }
        #expect(await world.start() == .waiting)
        #expect(world.leads().isEmpty)
        await world.connect()
        #expect(await eventually(timeout: 120) { world.leads().count == 1 }, "\(String(describing: world.stored))")
        #expect(await eventually(timeout: 60) { world.stored?.lastStart?.hasPrefix("started") == true }, "\(String(describing: world.stored))")
    }

    /// LeadStartsHostTests' `aStartWhileTheHostStartsWaitsForIt`, for the link: a second start asked while the link
    /// connects waits too, and one lead starts, not two.
    @Test func aStartWhileTheLinkConnectsWaitsForIt() async throws {
        let world = try await world(connect: false)
        defer { world.stop() }
        async let first = world.start()
        async let second = world.start(goal: "a goal asked meanwhile")
        #expect(await first == .waiting)
        #expect(await second == .waiting)
        // A second goal, asked after (the order the goals were asked in is the order they're taken in).
        #expect(await world.start(goal: "and another goal") == .waiting)
        await world.connect()
        #expect(await eventually(timeout: 120) { world.stored?.lastStart?.hasPrefix("started") == true || !world.held().isEmpty },
                "\(String(describing: world.stored))")
        // Neither goal is lost: the first is in the new lead's first prompt, the other held for it.
        #expect(await eventually(timeout: 120) { world.held().map(\.text) == ["New goal: and another goal"] }, "\(world.held())")
        #expect(world.stored?.starting == false)
        #expect(world.leads().count == 1)
        #expect(world.spawns.value.count == 1)
        #expect(world.spawns.value.first?.command?.contains("a goal asked meanwhile") == true, "\(world.spawns.value.first?.command ?? "")")
    }

    // MARK: A running lead

    @Test func aRunningLeadWithItsRoleIsShownAndGetsTheGoal() async throws {
        let world = try await world()
        defer { world.stop() }
        let lead = try started(await world.start())
        #expect(world.holder() == lead.uuidString)
        let again = await world.start(goal: "make the parser streaming")
        guard case .shown(let shown, let notes) = again else { Issue.record("not shown: \(again)"); return }
        #expect(shown == lead)
        #expect(notes.contains { $0.contains("held") }, "\(notes)")
        #expect(world.leads().map(\.id) == [lead])
        #expect(world.spawns.value.count == 1)
        // The goal is held for it (E5 delivers what's held), as from the command line, never as the user's.
        let held = world.held()
        #expect(held.map(\.text) == ["New goal: make the parser streaming"])
        #expect(held.first?.from != .user)
        #expect(world.stored?.held == 1)
    }

    /// LeadRelaunchTests' `aNewLeadWhileOneRunsIsAskedForAndTheOldOneIsSentToIt`: without `--replace` nothing starts;
    /// with it the new lead holds the role, the old one's waiting messages go to it, and the old session is marked
    /// replaced in `status`.
    @Test func aNewLeadWhileOneRunsIsRefusedWithoutReplaceAndTheOldOneIsSentToTheNewOne() async throws {
        let world = try await world()
        defer { world.stop() }
        let old = try started(await world.start())
        let oldSession = try #require(world.leads().first { $0.id == old })
        // The old lead named on its board (its tool server does that as it starts), and a message waiting for it.
        let harness = NodeHarness(found: oldSession, on: world.host, fake: world.fake)
        try await harness.waitFor { harness.agentPid != nil }
        let pid = try #require(harness.agentPid)
        try BoardStore(root: world.repo).update { board in
            board.leadPid = pid
            board.leadTTY = oldSession.tty
            board.leadSession = old.uuidString
        }
        try SteerInbox.post(SteerMessage(text: "a report for the lead", from: .system("worker a"), agentPid: pid), tty: oldSession.tty,
                            root: world.host.root)
        // Then the host's vault lost its grant: the session runs on without its role.
        let grant = try #require(world.host.vault.current(.lead, root: world.repo, task: nil)?.id)
        try world.host.vault.revoke(grant, root: world.repo)
        #expect(world.holder() == nil)

        // Without --replace: shown, nothing started, and the reply says how to replace it.
        let shown = await world.start()
        guard case .shown(let id, let notes) = shown else { Issue.record("not shown: \(shown)"); return }
        #expect(id == old)
        #expect(notes.contains { $0.contains("without its role") && $0.contains("--replace") }, "\(notes)")
        #expect(world.leads().count == 1)
        #expect(SteerInbox.pending(tty: oldSession.tty, root: world.host.root).count == 1)

        // With it: a new lead, which holds the role.
        let new = try started(await world.start(replace: true))
        #expect(new != old)
        #expect(await eventually(timeout: 60) { world.leads().count == 2 })
        #expect(world.holder() == new.uuidString)
        // The old lead is sent to the new one: its tools name the session that holds the role now.
        let asOld = world.host.book.answer(.whoami(root: world.repo), from: .session(old.uuidString))
        #expect(asOld == .member(nil), "\(asOld)")
        #expect(world.host.book.answer(.current(role: .lead, root: world.repo, task: nil), from: .session(old.uuidString))
                .member?.session == new.uuidString)
        // What waited for it went to the new one (held until E5 delivers it), out of the old one's inbox.
        #expect(SteerInbox.pending(tty: oldSession.tty, root: world.host.root).isEmpty)
        #expect(world.held().map(\.text) == ["a report for the lead"])
        // Marked replaced in what `status` shows.
        #expect(await eventually(timeout: 30) { world.stored?.replaced[old] == new }, "\(String(describing: world.stored))")
        #expect(world.stored?.session == new)
        let value = try #require(world.stored?.value)
        #expect(value["replaced"]?.array == [.string(NodeIds.session(host: old))])
    }

    /// The sweep's review: a `.user` message the server posted to the replaced lead, withdrawn by the handover (held for
    /// the new lead under a new id), is retired by name and no longer looked for, though the old inbox it left reads
    /// empty (which says nothing at a look: a rewriter of the inbox leaves it empty for a moment).
    @Test func aUserMessageTheHandoverTookIsRetiredByName() async throws {
        let world = try await world()
        defer { world.stop() }
        let old = try started(await world.start())
        let oldSession = try #require(world.leads().first { $0.id == old })
        let harness = NodeHarness(found: oldSession, on: world.host, fake: world.fake)
        try await harness.waitFor { harness.agentPid != nil }
        let pid = try #require(harness.agentPid)
        try BoardStore(root: world.repo).update { board in
            board.leadPid = pid
            board.leadTTY = oldSession.tty
            board.leadSession = old.uuidString
        }
        let words = "Name it the reader."
        let message = SteerMessage(text: words, from: .user, agentPid: pid)
        try SteerInbox.post(message, tty: oldSession.tty, root: world.host.root)
        world.queue.sync { world.engine.postedAsUser(message.id, tty: oldSession.tty, text: words, agentPid: pid) }
        let grant = try #require(world.host.vault.current(.lead, root: world.repo, task: nil)?.id)
        try world.host.vault.revoke(grant, root: world.repo)

        _ = try started(await world.start(replace: true))
        #expect(SteerInbox.pending(tty: oldSession.tty, root: world.host.root).isEmpty)
        #expect(world.held().map(\.text) == [words], "\(world.held())")
        #expect(await eventually(timeout: 60) { world.queue.sync { world.engine.postedUser[message.id] } == nil },
                "\(world.queue.sync { world.engine.postedUser })")
        let retired = world.host.book.v2 { $0?.retired[message.id] }
        #expect(retired != nil)
    }

    /// The security follow-ups' item 11: the board is the repository's, which any process of the user's can write. A
    /// board naming another project's session (its id, its terminal and its agent) replaces nothing when a lead starts:
    /// what waits in that session's inbox stays there, none of it is held for the new lead, and its conversation isn't
    /// read into the new lead's first prompt (nothing is handed as the replaced lead's last turns).
    @Test func aBoardNamingAnotherProjectsSessionHandsTheNewLeadNothingOfIt() async throws {
        let world = try await world()
        defer { world.stop() }
        let elsewhere = world.host.folder.appendingPathComponent("elsewhere", isDirectory: true)
        try await scratchRepository(elsewhere)
        let other = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: elsewhere.resolvingSymlinksInPath().path,
                                                label: "Lead · elsewhere")
        try await other.waitFor { other.agentPid != nil }
        let pid = try #require(other.agentPid)
        try SteerInbox.post(SteerMessage(text: "a report for the other project's lead", from: .system("worker a"), agentPid: pid),
                            tty: other.session.tty, root: world.host.root)
        try BoardStore(root: world.repo).prepare()
        try BoardStore(root: world.repo).update { board in
            board.leadSession = other.session.id.uuidString
            board.leadPid = pid
            board.leadTTY = other.session.tty
        }
        let new = try started(await world.start())
        #expect(SteerInbox.pending(tty: other.session.tty, root: world.host.root).map(\.text) == ["a report for the other project's lead"])
        #expect(world.held().isEmpty, "\(world.held())")
        #expect(world.stored?.replaced[other.session.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: LeadLaunch.turnsFile(root: world.repo)))
        #expect(world.holder() == new.uuidString)
    }

    /// The close-out review of item 11: a lead whose session ended (a crash) still hands what waits in its inbox to the
    /// next lead, when the vault binds this root's lead role to that session and the host listed it in this root on the
    /// board's terminal: the user's answer it never took isn't left behind.
    @Test func anEndedLeadTheVaultBindsHandsItsInboxToTheNextOne() async throws {
        let world = try await world()
        defer { world.stop() }
        let old = try started(await world.start())
        let oldSession = try #require(world.leads().first { $0.id == old })
        let harness = NodeHarness(found: oldSession, on: world.host, fake: world.fake)
        try await harness.waitFor { harness.agentPid != nil }
        let pid = try #require(harness.agentPid)
        try BoardStore(root: world.repo).update { board in
            board.leadPid = pid
            board.leadTTY = oldSession.tty
            board.leadSession = old.uuidString
        }
        try SteerInbox.post(SteerMessage(text: "a report for the lead", from: .system("worker a"), agentPid: pid), tty: oldSession.tty,
                            root: world.host.root)
        // Its agent ends; the host lists the session, ended.
        harness.tell(["op": "exit"])
        #expect(await eventually(timeout: 120) { world.queue.sync { world.link.sessions.first { $0.id == old }?.isLive == false } })
        #expect(world.holder() == old.uuidString)

        let new = try started(await world.start())
        #expect(new != old)
        #expect(SteerInbox.pending(tty: oldSession.tty, root: world.host.root).isEmpty)
        #expect(world.held().map(\.text) == ["a report for the lead"], "\(world.held())")
    }

    /// ReplacedLeadRoutingTests' `startsAndTheNoticesReadWhichLeadHoldsTheRoleOffTheMainThread`, the start's half: of
    /// two leads sharing the root (the replaced one and the one holding the role), a start finds the one holding the
    /// role off the engine's queue, shows it and starts nothing.
    @Test func aStartReadsWhichLeadHoldsTheRoleOffTheEngineQueue() async throws {
        let world = try await world()
        defer { world.stop() }
        let old = try started(await world.start())
        try world.host.vault.revoke(try #require(world.host.vault.current(.lead, root: world.repo, task: nil)?.id), root: world.repo)
        let new = try started(await world.start(replace: true))
        #expect(await eventually(timeout: 60) { world.leads().count == 2 })
        #expect(await eventually(timeout: 30) { world.stored?.replaced[old] == new }, "\(String(describing: world.stored))")
        let looks = Locked<[(root: String, onEngine: Bool)]>([])
        world.queue.sync { world.engine.boardLooked = { root in looks.mutate { $0.append((root, world.onEngine)) } } }
        #expect(await world.start() == .shown(session: new, notes: []))
        #expect(looks.value.contains { $0.root == world.repo && !$0.onEngine }, "\(looks.value)")
        #expect(!looks.value.contains { $0.onEngine }, "\(looks.value)")
        #expect(Set(world.leads().map(\.id)) == [old, new])
        #expect(world.spawns.value.count == 2)
    }

    /// A start asked while another of the same root is under way waits for it, then goes on with what it asked: its
    /// goal is held for the lead the first started (never dropped), and one lead starts.
    @Test func aStartAskedWhileOneIsUnderWayKeepsItsGoal() async throws {
        let world = try await world()
        defer { world.stop() }
        let gate = Gate()
        world.holdTheFirstLook(at: gate)
        async let first = world.start()
        try #require(await eventually(timeout: 60) { gate.reached })
        async let second = world.start(goal: "make the parser streaming")
        // Joined while the first still looks at the board.
        try #require(await eventually(timeout: 60) { world.waitingOnTheStart == 2 })
        gate.open()
        let lead = try started(await first)
        let joined = await second
        guard case .shown(let shown, let notes) = joined else { Issue.record("not shown: \(joined)"); return }
        #expect(shown == lead)
        #expect(notes.contains { $0.contains("held") }, "\(notes)")
        #expect(world.held().map(\.text) == ["New goal: make the parser streaming"])
        #expect(world.spawns.value.count == 1)
        #expect(world.leads().count == 1)
    }

    /// The link drops after the request was taken and before the lead is prepared (the welcome's capabilities are
    /// empty meanwhile): the start waits for the next welcome, not refused as from an older host, and goes on then.
    @Test func aStartWhoseLinkDropsWaitsForTheNextWelcome() async throws {
        let reconnects = Locked<[() -> Void]>([])
        var timing = HostLink.Timing()
        timing.reconnect = { _, fire in reconnects.mutate { $0.append(fire) } }
        let world = try await world(timing: timing)
        defer { world.stop() }
        let gate = Gate()
        world.holdTheFirstLook(at: gate)
        async let first = world.start()
        try #require(await eventually(timeout: 60) { gate.reached })
        world.queue.sync { world.link.connectAgain() }
        #expect(world.queue.sync { world.link.state } == .connecting)
        gate.open()
        #expect(await first == .waiting)
        #expect(world.spawns.value.isEmpty)
        // The next welcome: the start goes on.
        try #require(await eventually(timeout: 30) { !reconnects.value.isEmpty })
        reconnects.value.forEach { $0() }
        #expect(await eventually(timeout: 120) { world.stored?.lastStart?.hasPrefix("started") == true }, "\(String(describing: world.stored))")
        #expect(world.leads().count == 1)
    }

    /// `stop` under way when the lead is prepared: it isn't spawned, and the grant its start issued is revoked.
    @Test func aStopWhileALeadIsPreparedSpawnsNothingAndRevokesItsGrant() async throws {
        let world = try await world()
        defer { world.stop() }
        let gate = Gate()
        world.holdTheFirstLook(at: gate)
        async let first = world.start()
        try #require(await eventually(timeout: 60) { gate.reached })
        world.queue.sync { world.engine.stopStarting() }
        gate.open()
        #expect(await first == .refused(LeadEngine.stoppingRefusal))
        #expect(world.spawns.value.isEmpty)
        #expect(await eventually(timeout: 30) { world.host.vault.current(.lead, root: world.repo, task: nil) == nil })
        #expect(world.leads().isEmpty)
    }

    @Test func aLeadAskedForTwiceAtOnceStartsOnce() async throws {
        let world = try await world()
        defer { world.stop() }
        async let first = world.start()
        async let second = world.start()
        let outcomes = await [first, second]
        #expect(outcomes.filter { if case .started = $0 { return true } else { return false } }.count == 1, "\(outcomes)")
        #expect(Set(outcomes.compactMap(session)).count == 1, "\(outcomes)")
        #expect(world.leads().count == 1)
        #expect(world.spawns.value.count == 1)
    }

    // MARK: Refusals

    @Test func aFolderInNoRepositoryIsRefused() async throws {
        let world = try await world(repository: false)
        defer { world.stop() }
        let outcome = await world.start()
        guard case .refused(let why) = outcome else { Issue.record("not refused: \(outcome)"); return }
        #expect(why.contains("isn't in a git repository"), "\(why)")
        #expect(world.spawns.value.isEmpty)
    }

    /// The app's first-commit offer (`offerFirstCommit`) is a refusal.
    @Test func aRepositoryWithNoCommitsIsRefusedSayingItNeedsOne() async throws {
        let world = try await world(repository: false)
        defer { world.stop() }
        let ran = try await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", world.repo, "init", "-q", "-b", "main"],
                                environment: ["HOME": world.repo, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        try #require(ran.status == 0, "\(ran.errors)")
        let outcome = await world.start()
        #expect(outcome == .refused("\(world.repo) has no commits yet: workers branch from a commit; make one, then start the lead"))
        #expect(world.spawns.value.isEmpty)
    }

    /// ProjectFolderStartTests' `theControllersStartSaysWhatsMissingAndStartsNoLead`: a git path that doesn't exist and
    /// a `claude` link that names nothing are each named, and nothing starts. The look runs off the engine's queue and
    /// before git is asked about the folder (a repository with no commit, which git would have named).
    @Test func aMissingClaudeOrGitIsNamed() async throws {
        let missingLink = scratch.url("no-claude").path
        let missingGit = scratch.url("no-git").path
        let world = try await world(claudeLink: .some(missingLink), git: missingGit, repository: false)
        defer { world.stop() }
        let gitEnvironment = ["HOME": world.repo, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let made = try await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", world.repo, "init", "-q", "-b", "main"], environment: gitEnvironment)
        try #require(made.status == 0, "\(made.errors)")
        let looks = Locked<[Bool]>([])
        world.queue.sync { world.engine.preflightLooked = { looks.mutate { $0.append(world.onEngine) } } }
        let outcome = await world.start()
        guard case .refused(let why) = outcome else { Issue.record("not refused: \(outcome)"); return }
        #expect(looks.value == [false], "the look ran on the engine's queue: \(looks.value)")
        #expect(why.contains("claude: \(missingLink) names nothing"), "\(why)")
        #expect(why.contains("git: nothing runnable at \(missingGit)"), "\(why)")
        // Not refused for the folder: git wasn't asked about it (and still no commit there).
        #expect(!why.contains("no commits"), "\(why)")
        let head = try await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", world.repo, "rev-parse", "--verify", "--quiet", "HEAD"],
                                 environment: gitEnvironment)
        #expect(head.status != 0)
        #expect(world.spawns.value.isEmpty)
        #expect(world.leads().isEmpty)
        #expect(world.holder() == nil)
    }

    /// A `claude` the user's shell finds through `~/.bashrc`, with no link where the node reads it: refused, naming the
    /// link it read (the link a scratch node reads is `<root>/v2/test/claude`, which isn't there).
    @Test func aClaudeFoundOnlyThroughALoginShellIsRefused() async throws {
        let world = try await world(claudeLink: .some(nil))
        defer { world.stop() }
        let bin = world.host.folder.appendingPathComponent("login-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let copied = try await run(URL(fileURLWithPath: "/bin/cp"), [world.fake.launcher.path, bin.appendingPathComponent("claude").path],
                                   environment: ["PATH": "/usr/bin:/bin"])
        try #require(copied.status == 0)
        for startup in [".bashrc", ".profile", ".bash_profile"] {
            try "export PATH='\(bin.path)':\"$PATH\"\n".write(to: world.host.home.appendingPathComponent(startup), atomically: true, encoding: .utf8)
        }
        // Found through a login shell there.
        let login = try await run(URL(fileURLWithPath: "/bin/bash"), ["-l", "-i", "-c", "command -v claude"],
                                  environment: ["HOME": world.host.home.path, "PATH": "/usr/bin:/bin"])
        #expect(login.output.contains(bin.path), "\(login.output) \(login.errors)")
        let outcome = await world.start()
        guard case .refused(let why) = outcome else { Issue.record("not refused: \(outcome)"); return }
        let link = world.host.root.appendingPathComponent("v2/test/claude").path
        #expect(why.contains("claude: \(link) names nothing"), "\(why)")
        #expect(world.spawns.value.isEmpty)
    }

    /// EN-D13: the link points into a `versions/` folder holding only a file named `9.9.9`: the spawn's program is that
    /// file's absolute path, and the lead's `VIBESWITCHER_CLAUDE` is the same.
    @Test func aLeadIsLaunchedByClaudesResolvedPath() async throws {
        let folder = scratch.url("claude-install")
        let versions = folder.appendingPathComponent("share/claude/versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let version = versions.appendingPathComponent("9.9.9")
        let link = folder.appendingPathComponent("bin/claude").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "../share/claude/versions/9.9.9")
        let world = try await world(claudeLink: .some(link))
        defer { world.stop() }
        let made = try await run(URL(fileURLWithPath: "/bin/cp"), [world.fake.launcher.path, version.path], environment: ["PATH": "/usr/bin:/bin"])
        try #require(made.status == 0, "\(made.errors)")
        let resolved = version.resolvingSymlinksInPath().path
        let outcome = await world.start()
        guard case .started(let id, let program, _) = outcome else { Issue.record("not started: \(outcome)"); return }
        #expect(program == resolved)
        let request = try #require(world.spawns.value.first)
        let command = request.command ?? ""
        #expect(command.hasPrefix(RecentProjects.shellQuote(resolved) + " "), "\(command.prefix(200))")
        #expect(request.env[RoleProgram.variable] == resolved)
        // The session's own environment says so.
        let session = try #require(world.leads().first { $0.id == id })
        let harness = NodeHarness(found: session, on: world.host, fake: world.fake)
        try await harness.waitFor { harness.agentPid != nil }
        let pid = try #require(harness.agentPid)
        let environment = try #require(Self.environment(of: pid))
        #expect(environment[RoleProgram.variable] == resolved)
    }

    /// A process's environment, from `/proc/<pid>/environ`.
    static func environment(of pid: Int32) -> [String: String]? {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/environ") else { return nil }
        var environment: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return environment
    }

    /// `--take-head` (the app's `askToTakeHead`): without it a base moved since the lead last left it stays checked
    /// (the head the vault records stays where it was); with it the head is taken as it is.
    @Test func aMovedBaseIsKeptCheckedUnlessTakeHeadIsGiven() async throws {
        let world = try await world()
        defer { world.stop() }
        let git = { (arguments: [String]) async throws -> String in
            let ran = try await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", world.repo] + arguments,
                                    environment: ["HOME": world.repo, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                                                  "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                                                  "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.invalid"])
            try #require(ran.status == 0, "\(arguments): \(ran.errors)")
            return ran.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let left = try await git(["rev-parse", "main"])
        try world.host.vault.setHead(left, root: world.repo, branch: "main")
        _ = try await git(["commit", "-q", "--allow-empty", "-m", "moved by hand"])
        let moved = try await git(["rev-parse", "main"])

        let outcome = await world.start()
        guard case .started(let lead, _, let notes) = outcome else { Issue.record("not started: \(outcome)"); return }
        #expect(try world.host.vault.head(root: world.repo, branch: "main") == left)
        #expect(notes.contains { $0.contains("main moved since the lead last left it") && $0.contains("base accept") }, "\(notes)")

        // The lead ended; started again with --take-head, the branch is taken as it is.
        world.link.kill(lead)
        // Ended in the host's list and in the link's, which the start decides from.
        #expect(await eventually(timeout: 60) {
            world.leads().isEmpty && !world.queue.sync { world.link.sessions.contains { $0.id == lead && $0.isLive } }
        })
        _ = try started(await world.start(takeHead: true))
        #expect(try world.host.vault.head(root: world.repo, branch: "main") == moved)
    }

    @Test func aFailedSpawnRevokesTheGrant() async throws {
        // A list that names nothing refuses every spawn.
        let list = scratch.url("allow-nothing")
        try "# nothing allowed\n".write(to: list, atomically: true, encoding: .utf8)
        let world = try await world(allowList: list)
        defer { world.stop() }
        let outcome = await world.start()
        guard case .refused = outcome else { Issue.record("not refused: \(outcome)"); return }
        #expect(world.spawns.value.count == 1)
        // The grant the start issued is withdrawn: the role is no session's, and none waits to be bound.
        #expect(await eventually(timeout: 30) { world.host.vault.current(.lead, root: world.repo, task: nil) == nil })
        #expect(world.leads().isEmpty)
    }

    /// The vault binds the lead's role to its session: `whoami` asked as that session is the lead.
    @Test func theLeadsRoleIsBoundToItsSession() async throws {
        let world = try await world()
        defer { world.stop() }
        let lead = try started(await world.start())
        let answer = world.host.book.answer(.whoami(root: world.repo), from: .session(lead.uuidString))
        #expect(answer.member?.role == .lead, "\(answer)")
        #expect(answer.member?.session == lead.uuidString)
        #expect(world.stored?.bound == lead.uuidString)
    }

    /// S10: on Linux the lead's settings and MCP configuration are on its command line as JSON, and no file of them is
    /// left in its run folder.
    @Test func theLeadsLaunchSettingsAreInline() async throws {
        let world = try await world()
        defer { world.stop() }
        _ = try started(await world.start())
        let command = try #require(world.spawns.value.first?.command ?? nil)
        #expect(command.contains("--settings '{"), "\(command.prefix(300))")
        #expect(command.contains("--mcp-config '{"), "\(command.prefix(300))")
        let run = world.host.vault.runFolder(root: world.repo, name: "lead-\(Slug.make(world.name, taken: []))")
        for file in ["settings.json", "mcp.json"] {
            #expect(!FileManager.default.fileExists(atPath: run.appendingPathComponent(file).path), "\(file) in \(run.path)")
        }
        // Its tool server is the build folder's.
        #expect(command.contains(world.host.folder.appendingPathComponent("build/bin/vibeswitcher-mcp").path))
    }

    /// The lead starts on the run the app gives it (`LeadLaunch.leadRun`): with workflow.md naming neither, Fable and no
    /// advisor (lead_advisor is only for a lead on Opus).
    @Test func aLeadStartsOnFableByDefault() async throws {
        let world = try await world()
        defer { world.stop() }
        _ = try started(await world.start())
        let command = try #require(world.spawns.value.first?.command ?? nil)
        #expect(command.contains("--model 'fable'"), "\(command.prefix(400))")
        #expect(!command.contains("--advisor"), "\(command.prefix(400))")
    }

    /// workflow.md's lead_model and lead_advisor are on the lead's command line.
    @Test func aLeadStartsOnTheWorkflowsModelAndAdvisor() async throws {
        let world = try await world()
        defer { world.stop() }
        try Self.writeWorkflow("lead_model: opus\nlead_advisor: fable", repo: world.repo)
        _ = try started(await world.start())
        let command = try #require(world.spawns.value.first?.command ?? nil)
        #expect(command.contains("--model 'opus'"), "\(command.prefix(400))")
        #expect(command.contains("--advisor 'fable'"), "\(command.prefix(400))")
    }

    /// While the account's kept usage holds Fable back (under the node's root, where its tool servers keep it), a lead
    /// meant for Fable starts on Opus and its Fable advisor is dropped, as the app's.
    @Test func aLeadMeantForFableStartsOnOpusWhileFableIsHeldBack() async throws {
        let world = try await world()
        defer { world.stop() }
        let now = Date().timeIntervalSince1970
        AccountUsageStore(file: world.host.root.appendingPathComponent("account-usage.json"), home: world.host.home.path)
            .record([AccountUsage.Limit(name: "weekly", model: "fable", usedPercent: 100, resetsAt: now + 3600, at: now, reached: true)])
        _ = try started(await world.start())
        let command = try #require(world.spawns.value.first?.command ?? nil)
        #expect(command.contains("--model 'opus'"), "\(command.prefix(400))")
        #expect(!command.contains("--advisor"), "\(command.prefix(400))")
    }

    /// Writes the repository's workflow.md with `settings` as its front matter.
    static func writeWorkflow(_ settings: String, repo: String) throws {
        let file = URL(fileURLWithPath: BoardStore(root: repo).folder).appendingPathComponent("workflow.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\n\(settings)\n---\n\n# Workflow\n".utf8).write(to: file)
    }

    /// The lead's session gets its TMPDIR under the scratch node's root (`<root>/tmp`, as `HostLink`'s sweep reads it),
    /// never the shared temporary folder the user's node uses.
    @Test func theLeadsTemporaryFolderIsUnderTheScratchRoot() async throws {
        let world = try await world()
        defer { world.stop() }
        _ = try started(await world.start())
        let temporary = try #require(world.spawns.value.first?.env["TMPDIR"])
        #expect(temporary.hasPrefix(world.host.root.appendingPathComponent("tmp").path + "/"), "\(temporary)")
    }

    /// A scratch node's lead takes its test and build slots under the node's root (`<root>/tmp`, where its sessions'
    /// temporary folders are), never the account's `vibeswitcher-<uid>` in the shared temporary folder: its merges and
    /// audits don't wait on a slot the account's own work holds (a suite under `vs-heavy`, on a machine with one slot),
    /// and leave nothing among the account's. Its tool server finds them by its environment (`TestLock.standard`).
    @Test func theLeadsTestAndBuildSlotsAreUnderTheScratchRoot() async throws {
        let world = try await world()
        defer { world.stop() }
        let lead = try started(await world.start())
        let slots = world.host.root.appendingPathComponent("tmp").path
        #expect(world.spawns.value.first?.env[TestLock.directoryVariable] == slots)
        let session = try #require(world.leads().first { $0.id == lead })
        let harness = NodeHarness(found: session, on: world.host, fake: world.fake)
        try await harness.waitFor { harness.agentPid != nil }
        let pid = try #require(harness.agentPid)
        let environment = try #require(Self.environment(of: pid))
        #expect(environment[TestLock.directoryVariable] == slots)
        #expect(TestLock.standard(environment)?.directory == slots)
        #expect(slots != "\(Platform.Files.sharedTemporaryRoot)/vibeswitcher-\(getuid())")
    }

    /// The security document's decision 15: the lead's tool server starts no Codex worker.
    @Test func theLeadGetsNoCodexWorkers() async throws {
        let world = try await world()
        defer { world.stop() }
        let lead = try started(await world.start())
        #expect(world.spawns.value.first?.env["VIBESWITCHER_CODEX_WORKERS"] == "0")
        let session = try #require(world.leads().first { $0.id == lead })
        let harness = NodeHarness(found: session, on: world.host, fake: world.fake)
        try await harness.waitFor { harness.agentPid != nil }
        let pid = try #require(harness.agentPid)
        #expect(Self.environment(of: pid)?["VIBESWITCHER_CODEX_WORKERS"] == "0")
    }

    /// EN-D7: on a vault that doesn't hold its first look (so only the engine's leaving out `floor:` keeps it unset), no
    /// floor is seeded from workflow.md, where the app would have seeded one.
    @Test func noFloorIsSeededFromWorkflowOnLinux() async throws {
        let world = try await world()
        defer { world.stop() }
        _ = try started(await world.start())
        // The app would have recorded `LeadReviewFloor.starting(from: workflow)`; the engine records none.
        #expect(try world.host.vault.reviewFloor(root: world.repo) == nil)
    }

    /// Stage 2's Task 10d: a host whose allow-list doesn't hold the repository refuses the spawn, and the start says
    /// the host's reason.
    @Test func aSpawnOutsideTheAllowListIsRefusedWithTheHostsReason() async throws {
        let list = scratch.url("allow-other")
        let other = scratch.url("other-repository")
        try await scratchRepository(other)
        try (other.path + "\n").write(to: list, atomically: true, encoding: .utf8)
        let world = try await world(allowList: list)
        defer { world.stop() }
        let outcome = await world.start()
        guard case .refused(let why) = outcome else { Issue.record("not refused: \(outcome)"); return }
        #expect(why.contains("the session host didn't start the lead"), "\(why)")
        #expect(why.contains("isn't inside a repository on the project allow-list"), "\(why)")
        #expect(world.leads().isEmpty)
    }

    // MARK: Security (S3, S7)

    /// S7: a vault that holds its first look refuses the lead, naming `config held` and `base accept`, until the held
    /// config is accepted (`checkConfig(root:shown:)` with the card's hashes, as `config accept` will) and the head
    /// recorded (`setHead`, as `base accept` will); then it starts. The vault had never looked at the config: the
    /// start's own look holds it. E6 repeats the order through the command line.
    @Test func aLeadIsRefusedOnAFreshVaultUntilAccepted() async throws {
        let world = try await world(holdsFirstLook: true, firstLook: true)
        defer { world.stop() }
        let vault = world.host.vault
        #expect(ConfigSeal.held(in: try vault.guardedRecord(root: world.repo)).isEmpty, "looked at before the start")
        let refused = await world.start()
        guard case .refused(let why) = refused else { Issue.record("not refused: \(refused)"); return }
        #expect(why.contains("config held") && why.contains("base accept"), "\(why)")
        #expect(world.spawns.value.isEmpty)
        #expect(world.holder() == nil)

        // Accepted: the held hashes as shown, then the head.
        let shown = ConfigSeal.heldHashes(in: try vault.guardedRecord(root: world.repo))
        #expect(!shown.isEmpty)
        let check = try vault.checkConfig(root: world.repo, shown: shown)
        #expect(check.held.isEmpty, "\(check.held)")
        let stillHeadless = await world.start()
        guard case .refused(let headless) = stillHeadless else { Issue.record("not refused: \(stillHeadless)"); return }
        #expect(headless.contains("base accept") && !headless.contains("config held"), "\(headless)")
        let head = try await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", world.repo, "rev-parse", "main"], environment: ["PATH": "/usr/bin:/bin"])
        try vault.setHead(head.output.trimmingCharacters(in: .whitespacesAndNewlines), root: world.repo, branch: "main")
        _ = try started(await world.start())
    }

    /// S7: after the first accept, a change a look held (`config held`) stays held through a lead start: the start's
    /// own look shows no card, so it seals nothing the user didn't accept, and the start is refused.
    @Test func aStartAfterAHoldSealsNothingHeld() async throws {
        let world = try await world(holdsFirstLook: true, firstLook: true)
        defer { world.stop() }
        let vault = world.host.vault
        _ = try vault.checkConfig(root: world.repo, shown: [:])
        let shown = ConfigSeal.heldHashes(in: try vault.guardedRecord(root: world.repo))
        #expect(try vault.checkConfig(root: world.repo, shown: shown).held.isEmpty)
        let head = try await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", world.repo, "rev-parse", "main"], environment: ["PATH": "/usr/bin:/bin"])
        try vault.setHead(head.output.trimmingCharacters(in: .whitespacesAndNewlines), root: world.repo, branch: "main")

        // A worker's edit, held by a look as `config held` makes it.
        let file = world.host.home.appendingPathComponent(".claude/CLAUDE.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Run the hook.\n".utf8).write(to: file)
        _ = ConfigHoldStore.held(root: world.repo, vault: vault, home: world.host.home.path)
        let held = ConfigSeal.held(in: try vault.guardedRecord(root: world.repo))
        try #require(held == ["~/.claude/CLAUDE.md"], "\(held)")

        let refused = await world.start()
        guard case .refused(let why) = refused else { Issue.record("not refused: \(refused)"); return }
        #expect(why.contains("config held"), "\(why)")
        #expect(world.spawns.value.isEmpty)
        #expect(ConfigSeal.held(in: try vault.guardedRecord(root: world.repo)) == held)
    }

    /// The security follow-ups' item 20: a lead start's look never ends a root's held first look, though it finds
    /// nothing held: only your accept does. The project's config was sealed by an accept that left your home held (a
    /// home file changed after its card was drawn), and your home was then accepted through another root's first look,
    /// so this root's look judges both as sealed. workflow.md's floor is still not recorded for the root afterwards.
    @Test func aStartsLookLeavesTheFirstLookHeldWithNothingHeld() async throws {
        let world = try await world(holdsFirstLook: true, firstLook: true)
        defer { world.stop() }
        let vault = world.host.vault
        _ = try vault.checkConfig(root: world.repo, shown: [:])
        let card = ConfigSeal.heldHashes(in: try vault.guardedRecord(root: world.repo))
        // A home file changes after the card was drawn: its accept seals the project's, and your home stays held.
        let file = world.host.home.appendingPathComponent(".claude/CLAUDE.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Be brief.\n".utf8).write(to: file)
        let partly = try vault.checkConfig(root: world.repo, shown: card).held
        try #require(partly.contains("~/.claude/CLAUDE.md") && !partly.contains { $0.hasSuffix("(main checkout)") }, "\(partly)")
        // Your home accepted through another root's first look.
        let other = world.host.folder.appendingPathComponent("other", isDirectory: true)
        try await scratchRepository(other)
        let otherRoot = other.resolvingSymlinksInPath().path
        _ = try vault.checkConfig(root: otherRoot, shown: [:])
        let otherCard = ConfigSeal.heldHashes(in: try vault.guardedRecord(root: otherRoot))
        try #require(try vault.checkConfig(root: otherRoot, shown: otherCard).held.isEmpty)
        let floor = LeadReviewFloor.starting(from: LeadWorkflow())
        try #require(try vault.setReviewFloor(floor, root: world.repo, onlyIfUnset: true) == nil, "not held before the start")

        // The start's look finds nothing held here, and leaves the first look held: refused for the head alone.
        let refused = await world.start()
        guard case .refused(let why) = refused else { Issue.record("not refused: \(refused)"); return }
        #expect(why.contains("base accept") && !why.contains("config held"), "\(why)")
        #expect(try vault.setReviewFloor(floor, root: world.repo, onlyIfUnset: true) == nil)
        #expect(try vault.reviewFloor(root: world.repo) == nil)
        // Your accept of the card that showed nothing ends it (`config accept` sends its mark).
        #expect(try vault.checkConfig(root: world.repo, shown: [ConfigHoldStore.acceptMark: "1"]).held.isEmpty)
        #expect(try vault.setReviewFloor(floor, root: world.repo, onlyIfUnset: true) == floor)
    }

    /// S3: a session's process can't start a lead: the command line run in a scratch node's session, the code typed
    /// into its terminal, is refused for its voice by the server, and nothing starts.
    @Test func aSessionsProcessCannotStartALead() async throws {
        let node = try await ScratchNode(scratch)
        let repo = node.root.appendingPathComponent("repo")
        try await scratchRepository(repo)
        let out = node.root.appendingPathComponent("lead.out").path
        let command = "VIBESWITCHER_HOME='\(node.root.path)' '\(commandLine.path)' lead '\(repo.path)' >'\(out)' 2>&1; echo \"exit $?\" >>'\(out)'"
        let session = try await node.spawn(command)
        var code = ""
        let asked = await eventually(timeout: 60) {
            guard let screen = HostCall.styledScreen(session.id, socket: node.socket, appKey: nil)?.text,
                  let range = screen.range(of: #"Type ([A-Z]{4}) and Enter"#, options: .regularExpression) else { return false }
            code = String(screen[range].dropFirst(5).prefix(4))
            return true
        }
        try #require(asked, "the command line never asked: \(String(describing: HostCall.styledScreen(session.id, socket: node.socket, appKey: nil)?.text))")
        try HostCall.send(.input(id: session.id, bytes: Data((code + "\r").utf8), reply: false), socket: node.socket, appKey: nil)
        let ended = await eventually(timeout: 60) { ((try? String(contentsOfFile: out, encoding: .utf8)) ?? "").contains("exit ") }
        let said = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        #expect(ended, "\(said)")
        #expect(said.contains("exit 77"), "\(said)")
        #expect(said.contains("voice: not the user's voice"), "\(said)")
        let sessions = try node.sessions()
        #expect(!sessions.contains { $0.label.hasPrefix("Lead · ") }, "\(sessions.map(\.label))")
        let client = try WireClient(node)
        let status = try #require(WireClient.reply(client.request("status", action: nil))?.result)
        #expect(status["accepted"]?.array?.isEmpty == true)
        #expect(status["leads"]?.array?.isEmpty == true)
    }
}

extension LeadVault.Reply {
    /// The member a `.member` reply names.
    var member: LeadVault.Member? {
        if case .member(let member) = self { return member }
        return nil
    }
}
