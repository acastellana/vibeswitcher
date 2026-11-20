import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The witness at each refresh (the engine plan's E7; the app's `LeadController.witness` and `witnessed`): what it reads
/// of a team (`TeamReading`), and what it does with what it finds, on a scratch host in the test process
/// (`DeliveryWorld`): a lead that's a `FakeClaude` mid-turn (so the witness's messages wait in its inbox, read there),
/// team sessions that run `sleep` or end at once, or a `FakeClaude` the node's scan sees. Each refresh is asked as the
/// engine's clock asks it (`refresh()`); what's waited for is the event itself.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct WitnessTests {
    private let scratch = Scratch()

    /// LeadFilesTests' fourth case: what the witness reads of a team off the engine's queue (`TeamReading`) is what it
    /// read on it before: a worker's transcript whatever it shows, a verifier's too (one at the usage limit shows
    /// working), none for an ended session or one the scan didn't take for an agent's.
    @Test func theWitnessReadsWhatItReadBefore() throws {
        let home = scratch.url("lead-files").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let states = (home as NSString).appendingPathComponent("state")
        let projects = (home as NSString).appendingPathComponent(".claude/projects/-r")
        try FileManager.default.createDirectory(atPath: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        let observer = LeadObserver(home: home, stateFile: { URL(fileURLWithPath: (states as NSString).appendingPathComponent("\($0).json")) })
        let started = Date().addingTimeInterval(-600)
        let finished = """
            {"type":"assistant","timestamp":"2026-10-19T09:00:00.250Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}
            {"type":"system","subtype":"turn_duration","timestamp":"2026-10-19T09:00:01Z"}

            """
        var hosted: [String: HostSession] = [:]
        var sessions: [String: Session] = [:]
        func member(_ index: Int, status: SessionStatus, live: Bool = true, scanned: Bool = true) throws -> String {
            let id = UUID()
            let tty = "ttypts\(900 + index)"
            hosted[id.uuidString] = HostSession(id: id, tty: tty, childPID: 1, cwd: "/r", command: "claude", label: "task-\(index)", agent: "claude",
                                                title: "", startedAt: started, cols: 120, rows: 40,
                                                exit: live ? nil : HostSession.Exit(status: 0, at: Date()))
            let transcript = (projects as NSString).appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
            try finished.write(toFile: transcript, atomically: true, encoding: .utf8)
            var hook = HookState(agent: .claude, tty: tty, lastEvent: "Stop", lastEventAt: Date().timeIntervalSince1970)
            hook.agentPid = Int32(7000 + index)
            hook.transcriptPath = transcript
            try hook.save(to: observer.stateFile(tty))
            if scanned {
                var session = Session(tty: tty, agent: .claude, pid: Int32(7000 + index), startedAt: started, cwd: "/r", project: "r", task: nil,
                                      status: status, statusSince: started, detail: nil, hasHooks: true, inTerminalApp: false)
                session.hostID = id
                sessions[id.uuidString] = session
            }
            return id.uuidString
        }
        let worker = try member(0, status: .working)
        let working = try member(1, status: .working)
        let ended = try member(2, status: .done, live: false)
        let verifier = try member(3, status: .done)
        let unscanned = try member(4, status: .done, scanned: false)
        var board = LeadBoard()
        for (index, pair) in [(worker, working), (ended, verifier), (unscanned, nil)].enumerated() {
            var task = LeadTask(slug: "task-\(index)", title: "Task \(index)", contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""),
                                status: .running)
            task.worker = pair.0
            task.verifier = pair.1
            board.tasks.append(task)
        }
        let team = TeamReading.read(root: home, board: board, hosted: hosted, sessions: sessions, observer: observer,
                                    inbox: URL(fileURLWithPath: home), lock: nil)
        #expect(Set(team.watched.keys) == [worker, working, verifier])
        for id in [worker, working, verifier] {
            let reading = observer.watching(try #require(hosted[id]), agentPid: try #require(sessions[id]).pid)
            #expect(team.watched[id]?.activity == reading.activity)
            #expect(team.watched[id]?.tail == reading.tail)
            #expect(team.watched[id]?.progress == reading.progress)
        }
        #expect(team.watched[worker]?.tail?.state == .turnOver(apiError: nil))
        #expect(team.watched[worker]?.progress?.lastWritten == ISO8601DateFormatter().date(from: "2026-10-19T09:00:01Z")?.timeIntervalSince1970)
        #expect(team.hosted == hosted && team.sessions == sessions)
    }

    /// MemberWatchReadTests' case: the witness watches each live member of a team task, not only its integrator. What it
    /// reads of the team off the engine's queue takes each member's session, and its shells, held messages and
    /// test-lock waits are read for it as for the task's worker (`TeamReading.workerSessions`). A member left out was
    /// never stall-checked, so one stuck went unnoticed.
    @Test func theWitnessReadsEachLiveMembersSession() throws {
        let home = scratch.url("member-watch").path
        let states = (home as NSString).appendingPathComponent("state")
        let projects = (home as NSString).appendingPathComponent(".claude/projects/-r")
        try FileManager.default.createDirectory(atPath: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        let observer = LeadObserver(home: home, stateFile: { URL(fileURLWithPath: (states as NSString).appendingPathComponent("\($0).json")) })
        let started = Date().addingTimeInterval(-600)
        let finished = """
            {"type":"assistant","timestamp":"2026-10-19T09:00:00.250Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}
            {"type":"system","subtype":"turn_duration","timestamp":"2026-10-19T09:00:01Z"}

            """
        var hosted: [String: HostSession] = [:]
        var sessions: [String: Session] = [:]
        func session(_ index: Int, live: Bool = true) throws -> String {
            let id = UUID()
            let tty = "ttypts\(950 + index)"
            hosted[id.uuidString] = HostSession(id: id, tty: tty, childPID: 1, cwd: "/r", command: "claude", label: "member-\(index)", agent: "claude",
                                                title: "", startedAt: started, cols: 120, rows: 40,
                                                exit: live ? nil : HostSession.Exit(status: 0, at: Date()))
            let transcript = (projects as NSString).appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
            try finished.write(toFile: transcript, atomically: true, encoding: .utf8)
            var hook = HookState(agent: .claude, tty: tty, lastEvent: "Stop", lastEventAt: Date().timeIntervalSince1970)
            hook.agentPid = Int32(7100 + index)
            hook.transcriptPath = transcript
            try hook.save(to: observer.stateFile(tty))
            var scanned = Session(tty: tty, agent: .claude, pid: Int32(7100 + index), startedAt: started, cwd: "/r", project: "r", task: nil,
                                  status: .done, statusSince: started, detail: nil, hasHooks: true, inTerminalApp: false)
            scanned.hostID = id
            sessions[id.uuidString] = scanned
            return id.uuidString
        }
        let integrator = try session(0)
        let ui = try session(1)
        let docs = try session(2)
        let ended = try session(3, live: false)
        var task = LeadTask(slug: "build-it", title: "Build it", contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""), status: .running)
        task.worker = integrator
        task.team = try LeadTeam.make(slug: "build-it", root: home, parts: [("core", "types"), ("ui", "views"), ("docs", "docs"), ("api", "tools")])
        for (index, worker) in [integrator, ui, docs, ended].enumerated() { task.team?[index].worker = worker }
        var board = LeadBoard()
        board.tasks = [task]
        func read(_ board: LeadBoard) -> TeamReading {
            TeamReading.read(root: home, board: board, hosted: hosted, sessions: sessions, observer: observer, inbox: URL(fileURLWithPath: home), lock: nil)
        }

        #expect(board.tasks[0].watched == [integrator, ui, docs, ended])
        #expect(TeamReading.workerSessions(board) == [integrator, ui, docs, ended])
        let team = read(board)
        // Every live member's transcript is read, as the integrator's; the ended one's isn't (`endedMembers` tells it).
        #expect(Set(team.watched.keys) == [integrator, ui, docs])
        for id in [ui, docs] {
            let reading = observer.watching(try #require(hosted[id]), agentPid: try #require(sessions[id]).pid)
            #expect(team.watched[id]?.activity == reading.activity)
            #expect(team.watched[id]?.progress == reading.progress)
        }
        // A plain task's reading is as before: its worker alone.
        var plain = board
        plain.tasks[0].team = nil
        #expect(Set(read(plain).watched.keys) == [integrator])
        #expect(TeamReading.workerSessions(plain) == [integrator])
    }

    // MARK: On a scratch host

    /// A task's worktree under the world's repository (made), where its team sessions run.
    private func worktree(_ world: DeliveryWorld, _ slug: String) throws -> String {
        let folder = (world.repo as NSString).appendingPathComponent(".vibeswitcher/worktrees/\(slug)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A task on the world's board, as `change` makes it.
    private func task(_ world: DeliveryWorld, _ slug: String, _ status: LeadTask.Status, _ change: (inout LeadTask) -> Void = { _ in }) throws {
        try BoardStore(root: world.repo).update { board in
            var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""), status: status)
            change(&task)
            board.tasks.removeAll { $0.slug == slug }
            board.tasks.append(task)
        }
    }

    /// The host's session `id` as the link has it now.
    private func listed(_ world: DeliveryWorld, _ id: UUID) -> HostSession? { world.queue.sync { world.link.sessions.first { $0.id == id } } }

    /// A team session that ends at once: once the link lists it ended.
    private func endedSession(_ world: DeliveryWorld, label: String, cwd: String) async throws -> HostSession {
        let session = try await world.host.spawn("exit 0", cwd: cwd, label: label)
        try #require(await eventually(timeout: 60) { listed(world, session.id)?.isLive == false })
        return session
    }

    /// A refresh, and everything it asked of the reads and engine queues run.
    private func refresh(_ world: DeliveryWorld) async {
        world.engine.refresh()
        await world.drained()
    }

    /// A refresh whose witness looked after this was called, with the disk look that witness asked of `reads` run too:
    /// `refresh`'s drain ends at the look's `witnessed`, before the disk watch's check it queues on `reads` (one hop
    /// more), and a free-space change made after that check had run would be what it reads (a load run's
    /// `lowDiskIsToldOncePerEpisode`: the back-up look read the low value again, so the episode never ended).
    private func looked(_ world: DeliveryWorld) async {
        let looks = { world.queue.sync { world.engine.witnessLooks.values.reduce(0, +) } }
        let before = looks()
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { looks() > before }, "no witness look")
        await world.drained()
    }

    /// What waits in the lead's inbox with `text` in it.
    private func told(_ world: DeliveryWorld, _ lead: NodeHarness, _ text: String) -> [SteerMessage] {
        world.pending(lead).filter { $0.text.contains(text) }
    }

    /// A worker or verifier bound to its role five minutes ago whose tool server never asked who it is only holds a
    /// slot: its session ends, and the lead is told once.
    @Test func aSessionWhoseToolsNeverConnectedIsEnded() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let worker = try await world.host.spawn("exec /bin/sleep 600", cwd: try worktree(world, "no-tools"), label: "Worker: no-tools")
        try task(world, "no-tools", .running) { $0.worker = worker.id.uuidString }
        let bound = Date().timeIntervalSince1970 - LeadWitness.toolsWithin - 60
        world.queue.sync { world.engine.toolTimes = [worker.id.uuidString: (bound: bound, tools: nil)] }
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { listed(world, worker.id)?.isLive == false }, "\(String(describing: listed(world, worker.id)))")
        #expect(await eventually(timeout: 60) { told(world, lead, "never got its tools").count == 1 }, "\(world.pending(lead).map(\.text))")
        await refresh(world)
        await refresh(world)
        #expect(told(world, lead, "never got its tools").count == 1, "\(world.pending(lead).map(\.text))")
    }

    /// A verifier that ended without a verdict, with auto_advance's loop running: the loop is nudged at the first sight
    /// of it, once, however many refreshes see it.
    @Test func anEndedVerifierNudgesAutoAdvanceOnce() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.lead(idle: false)
        let verifier = try await endedSession(world, label: "Verifier: audit-me", cwd: try worktree(world, "audit-me"))
        try task(world, "audit-me", .review) { $0.verifier = verifier.id.uuidString }
        // The lead's loop holds its lock, as its tool server does while auto_advance runs.
        let run = (BoardStore(root: world.repo).folder as NSString).appendingPathComponent("run")
        try FileManager.default.createDirectory(atPath: run, withIntermediateDirectories: true)
        let loop = try #require(FileLock.attempt((run as NSString).appendingPathComponent("advancing.lock")))
        defer { loop.release() }
        let nudged = Locked<[String]>([])
        world.queue.sync { world.engine.nudgeAdvance = { root in nudged.mutate { $0.append(root) } } }
        for _ in 0..<3 { await refresh(world) }
        #expect(nudged.value == [world.repo], "\(nudged.value)")
    }

    /// The E7 review: the disk watch's look (its statfs, its `disk-watch.json`) and the nudge of auto_advance's loop
    /// (a write into the project's `.vibeswitcher/`) are file work, done on the reads queue, never the engine's.
    @Test func theDiskWatchAndTheNudgeAreOffTheEngineQueue() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.lead(idle: false)
        let verifier = try await endedSession(world, label: "Verifier: off-queue", cwd: try worktree(world, "off-queue"))
        try task(world, "off-queue", .review) { $0.verifier = verifier.id.uuidString }
        let run = (BoardStore(root: world.repo).folder as NSString).appendingPathComponent("run")
        try FileManager.default.createDirectory(atPath: run, withIntermediateDirectories: true)
        let loop = try #require(FileLock.attempt((run as NSString).appendingPathComponent("advancing.lock")))
        defer { loop.release() }
        let calls = Locked<[(call: String, onEngine: Bool)]>([])
        world.queue.sync {
            world.engine.freeSpace = { _ in
                calls.mutate { $0.append(("free", world.onEngine)) }
                return nil
            }
            world.engine.nudgeAdvance = { _ in calls.mutate { $0.append(("nudge", world.onEngine)) } }
        }
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { calls.value.contains { $0.call == "free" } && calls.value.contains { $0.call == "nudge" } },
                "\(calls.value)")
        await refresh(world)
        #expect(!calls.value.contains { $0.onEngine }, "\(calls.value)")
    }

    /// The E7 review: the engine's role sweep (`Options.sweepsRoles`, as the server's engine has it) ends a finished
    /// task's live worker through the link, from the host's roster; it looks again only 6 s on; and what the roster says
    /// of the worker's tools reaches the witness, on the engine's queue.
    @Test func theEnginesRoleSweepEndsAFinishedTasksWorkerThroughTheLink() async throws {
        let world = try await DeliveryWorld.make(scratch, sweepsRoles: true)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let worker = try await world.host.spawn("exec /bin/sleep 600", cwd: try worktree(world, "swept"), label: "Worker: swept")
        let (book, folder, repo) = (world.host.book, world.host.folder, world.repo)
        let (leadID, workerID) = (lead.session.id.uuidString, worker.id.uuidString)
        let before = Date().timeIntervalSince1970
        try await offPool {
            // The lead's tool server asks for the worker's grant and binds it to the session it started.
            let tools = book.vault(folder: folder, as: { .session(leadID) })
            try tools.bind(try tools.issue(role: .worker, root: repo, task: "swept"), root: repo, session: workerID)
        }
        try task(world, "swept", .done) { $0.worker = workerID }
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { listed(world, worker.id)?.isLive != true }, "\(String(describing: listed(world, worker.id)))")
        #expect(await eventually(timeout: 60) {
            world.queue.sync { world.engine.toolTimes[workerID] != nil && !world.engine.sweeping }
        })
        let bound = try #require(world.queue.sync { world.engine.toolTimes[workerID]?.bound })
        // The roster's time for this bind (the host keeps it), not one from before.
        #expect(bound >= before, "\(bound) \(before)")
        // Asked again at once: the sweep waits its 6 s.
        let swept = world.queue.sync { world.engine.sweptAt }
        await refresh(world)
        #expect(world.queue.sync { world.engine.sweptAt } == swept)
    }

    /// The E7 review (the app's `ReportsWaiting.keep`): a lead that ended has no reports waiting in `status`.
    @Test func aLeadThatEndedHasNoReportsWaiting() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        try world.post("The worker on parser says it's done.", from: .system("witness"), to: lead, age: LeadWake.shownAfter + 30)
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { world.stored?.reportsWaiting == 1 }, "\(String(describing: world.stored))")
        world.queue.async { world.link.kill(lead.session.id) }
        #expect(await eventually(timeout: 60) { listed(world, lead.session.id)?.isLive != true && world.stored?.session == nil })
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { world.stored?.reportsWaiting == 0 }, "\(String(describing: world.stored))")
        #expect(world.stored?.value["reportsWaiting"]?.int == 0)
    }

    /// A worker that reached its task's time budget: it's told to stop and report over_budget (in its inbox, or typed
    /// in between turns), and the lead is told, once, however many refreshes see it. Nothing is ended.
    @Test func theTaskBudgetStopsTheWorkerAndTellsTheLeadOnce() async throws {
        let world = try await DeliveryWorld.make(scratch, scan: true)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let worker = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: try worktree(world, "budgeted"), label: "Worker: budgeted")
        let sessions = try #require(world.sessions)
        try #require(await eventually(timeout: 60) { world.queue.sync { sessions.sessions.contains { $0.hostID == worker.session.id } } })
        try task(world, "budgeted", .running) { task in
            task.worker = worker.session.id.uuidString
            task.budgetMin = 1
            task.worked = 120
        }
        world.engine.refresh()
        let stop = "has reached its time budget"
        #expect(await eventually(timeout: 60) {
            world.pending(worker).contains { $0.text.contains(stop) } || world.prompts(worker).contains { $0.contains(stop) }
        }, "\(world.pending(worker).map(\.text)) \(world.prompts(worker))")
        #expect(await eventually(timeout: 60) { told(world, lead, "has reached its 1 min time budget").count == 1 }, "\(world.pending(lead).map(\.text))")
        await refresh(world)
        await refresh(world)
        #expect(told(world, lead, "has reached its 1 min time budget").count == 1)
        #expect(listed(world, worker.session.id)?.isLive == true)
        #expect(BoardStore(root: world.repo).load().task("budgeted")?.overBudget?.minutes == 1)
    }

    /// The app's `noteWorking` (`03d03896`): the witness tells the vault which sessions it sees at work, so the vault's
    /// own count of a worker's time (what small_task_min goes by) runs on a node too.
    @Test func theWitnessTellsTheVaultWhichWorkersItSeesAtWork() async throws {
        let world = try await DeliveryWorld.make(scratch, scan: true)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let worker = try await NodeHarness.start(on: world.host, fake: world.fake, cwd: try worktree(world, "small"), label: "Worker: small")
        let sessions = try #require(world.sessions)
        try #require(await eventually(timeout: 60) { world.queue.sync { sessions.sessions.contains { $0.hostID == worker.session.id } } })
        let (book, folder, repo) = (world.host.book, world.host.folder, world.repo)
        let (leadID, workerID) = (lead.session.id.uuidString, worker.session.id.uuidString)
        try await offPool {
            let tools = book.vault(folder: folder, as: { .session(leadID) })
            try tools.bind(try tools.issue(role: .worker, root: repo, task: "small"), root: repo, session: workerID)
        }
        try task(world, "small", .running) { $0.worker = workerID }
        // Mid-turn, as its hooks say.
        try world.hook(worker, "PreToolUse")
        let vault = world.host.vault
        let counting = { (try? vault.smallTaskFacts(root: repo, task: "small"))??.workingSince != nil }
        #expect(!counting())
        #expect(await eventually(timeout: 60) { world.engine.refresh(); return counting() }, "\(String(describing: try? vault.smallTaskFacts(root: repo, task: "small")))")
        #expect(world.queue.sync { world.engine.workingTold[repo]?.sessions.contains(workerID) } == true)
    }

    /// The ended workers and verifiers of a finished task leave the host's list; an ended worker of a task still under
    /// way stays (why it died is worth a look).
    @Test func finishedTeamsEndedSessionsAreRemoved() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        _ = try await world.lead(idle: false)
        let done = try await endedSession(world, label: "Worker: merged", cwd: try worktree(world, "merged"))
        let checked = try await endedSession(world, label: "Verifier: merged", cwd: try worktree(world, "merged"))
        let running = try await endedSession(world, label: "Worker: going", cwd: try worktree(world, "going"))
        try task(world, "merged", .done) { task in
            task.worker = done.id.uuidString
            task.verifier = checked.id.uuidString
        }
        try task(world, "going", .running) { $0.worker = running.id.uuidString }
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { listed(world, done.id) == nil && listed(world, checked.id) == nil })
        await refresh(world)
        #expect(listed(world, running.id) != nil)
        #expect(try world.host.sessions().contains { $0.id == running.id })
        #expect(try !world.host.sessions().contains { $0.id == done.id })
    }

    /// Free space under the workflow's warning is told once per episode: not at each refresh while it stays low, and
    /// again only once it was back up and dropped again.
    @Test func lowDiskIsToldOncePerEpisode() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: false)
        let free = Locked<Int64>(DiskSpace.bytes(1))
        world.queue.sync { world.engine.freeSpace = { _ in free.value } }
        let low = "Disk space is low"
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { told(world, lead, low).count == 1 })
        await refresh(world)
        await refresh(world)
        #expect(told(world, lead, low).count == 1)
        // Back up, then low again: a new episode. The back-up look is waited for: a low read then would keep the
        // episode going.
        free.value = DiskSpace.bytes(100)
        await looked(world)
        #expect(told(world, lead, low).count == 1)
        free.value = DiskSpace.bytes(1)
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { told(world, lead, low).count == 2 }, "\(world.pending(lead).map(\.text))")
    }

    /// Ten reports from three workers over a minute, the lead idle and busy in turn: each reaches it once. Idle, the
    /// refresh wakes it (one prompt for what waits) and its prompt's hook hands them over; busy, its next step's hook
    /// does. The refresh is asked as the clock asks it, until what it's waited for happens.
    @Test func theLeadHearsEveryReport() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.lead(idle: true)
        let workers = ["parser", "lexer", "docs"]
        var reports: [String] = []
        for round in 0..<5 {
            let idle = round % 2 == 0
            try world.hook(lead, idle ? "Stop" : "PreToolUse")
            for index in 0..<2 {
                let worker = workers[(round * 2 + index) % workers.count]
                let report = "Report \(round * 2 + index + 1) from the worker on \(worker): step \(round) is done."
                reports.append(report)
                try world.post(report, from: .system("worker \(worker)"), to: lead)
            }
            if idle {
                // Woken: the refresh types one prompt for what waits (a wake-up typed a moment ago holds the next for
                // 10 s), and its prompt's hook hands the reports over.
                let typed = world.steps.value.compactMap(DeliveryWorld.typed).count
                var woken = false
                for _ in 0..<120 where !woken {
                    world.engine.refresh()
                    try await Task.sleep(nanoseconds: 500_000_000)
                    woken = world.steps.value.compactMap(DeliveryWorld.typed).count > typed
                }
                try #require(woken, "round \(round): never woken; the steps: \(world.steps.value.suffix(5))")
                try await lead.waitFor { world.prompts(lead).filter { $0.contains("new report") }.count == round / 2 + 1 }
                #expect(lead.hookTakes(event: "UserPromptSubmit"), "round \(round)")
            } else {
                // Busy: a refresh types nothing, and its next step's hook hands them over.
                await refresh(world)
                #expect(lead.hookTakes(), "round \(round)")
            }
            #expect(world.pending(lead).isEmpty, "round \(round): \(world.pending(lead).map(\.text))")
        }
        await refresh(world)
        let handed = world.handed(lead)
        for report in reports { #expect(handed.components(separatedBy: report).count == 2, "\(report): \(handed)") }
        #expect(world.prompts(lead).filter { $0.contains("new report") }.count == 3, "\(world.prompts(lead))")
    }
}
