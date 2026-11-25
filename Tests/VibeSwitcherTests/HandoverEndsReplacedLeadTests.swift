import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// 2026-11-22: "just like replace the terminal by the new one… so the user doesn't have the replaced one". Once the new
/// lead holds the role and has ended its first turn, and the replaced one is between turns, VibeSwitcher ends the
/// replaced one by itself: one lead row, in the old one's place, selected if the old one was, nothing typed lost. A
/// scratch host (`ReplacedLeadRoutingTests.world`: its own socket, fake sessions running `cat` and `sleep`, never the
/// user's); what the agents are doing is told by `turnReading`, as their hooks and transcripts would tell it.
@MainActor
@Suite(.serialized)
struct HandoverEndsReplacedLeadTests {
    let routing = ReplacedLeadRoutingTests()
    typealias Reading = LeadController.TurnReading

    static let idle = Reading(activity: .idle(background: nil), asking: false, turnEnded: true)
    static let working = Reading(activity: .working("Bash"), asking: false, turnEnded: false)
    static let asking = Reading(activity: .needsInput("Which page first?"), asking: true, turnEnded: true)

    /// What each session's agent is doing, as the test says (read off the main thread); unknown when not said.
    final class Readings: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [UUID: Reading] = [:]
        subscript(id: UUID) -> Reading? {
            get { lock.withLock { readings[id] } }
            set { lock.withLock { readings[id] = newValue } }
        }
    }

    /// The controller's looks at the replaced leads to end, and what each ended.
    @MainActor
    final class Looks {
        var done = 0
        var ended: [UUID] = []
    }

    func watch(_ world: ReplacedLeadRoutingTests.World, _ readings: Readings) -> Looks {
        let looks = Looks()
        world.controller.turnReading = { session, _, _ in readings[session.id] ?? Reading(activity: .unknown, asking: false, turnEnded: false) }
        world.controller.endLooked = { ended in
            looks.done += 1
            looks.ended += ended
        }
        return looks
    }

    /// Two whole looks after now: the second began after the first ended, so it read what's true now.
    func twoLooks(_ world: ReplacedLeadRoutingTests.World, _ looks: Looks) async -> Bool {
        let target = looks.done + 2
        return await until {
            if looks.done < target { world.controller.refresh() }
            return looks.done >= target
        }
    }

    func live(_ id: UUID, _ world: ReplacedLeadRoutingTests.World) -> Bool {
        world.host.sessions.contains { $0.id == id && $0.isLive }
    }

    func spawn(_ label: String, in folder: String, _ world: ReplacedLeadRoutingTests.World, agent: String? = "claude") async throws -> HostSession {
        var result: Result<HostSession, HostClientError>?
        world.host.spawn(SpawnRequest(cwd: folder, command: "exec /bin/cat", env: [:], cols: 80, rows: 24, keepShell: false,
                                      label: label, agent: agent)) { result = $0 }
        #expect(await until { result != nil })
        return try #require(result).get()
    }

    /// You ask for a new lead (the old one holds no role): as `ReplacedLeadRoutingTests.replace`, with other sessions
    /// of the project running beside them.
    func replace(_ world: ReplacedLeadRoutingTests.World, old: HostSession) async throws -> HostSession {
        let before = Set(world.host.sessions.map(\.id))
        var asked: [String] = []
        world.controller.confirm = { title, _, buttons in asked.append(title); return buttons.count - 1 }
        world.controller.startLead(in: world.root)
        let started = { world.host.sessions.first { !before.contains($0.id) && $0.label == "Lead · \(world.project)" } }
        #expect(await until { asked.count == 1 && started() != nil })
        let new = try #require(started())
        #expect(await until { world.vault.current(.lead, root: world.root, task: nil)?.session == new.id.uuidString })
        #expect(await until { BoardStore(root: world.root).load().leadSession == new.id.uuidString })
        try BoardStore(root: world.root).update { board in
            board.leadPid = new.childPID
            board.leadTTY = new.tty
        }
        return new
    }

    /// A row for each session, as the scan finds a window session's agent: `status` (idle unless said).
    func rows(_ sessions: [HostSession], project: String, status: [UUID: SessionStatus] = [:]) -> [WindowRow] {
        sessions.filter(\.isLive).map { host in
            var session = Session(tty: host.tty, agent: .claude, pid: host.childPID, startedAt: host.startedAt, cwd: host.cwd, project: project,
                                  task: nil, status: status[host.id] ?? .idle, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
            session.hostID = host.id
            return WindowRow(content: .agent(session), project: project)
        }
    }

    @Test func theReplacedLeadEndsOnceTheNewOneHasEndedATurnAndItsPlaceAndSelectionGoToTheNewOne() async throws {
        let world = try routing.world()
        defer { world.stop() }
        let readings = Readings()
        let looks = watch(world, readings)
        let old = try await routing.oldLead(in: world)
        // The user's own session in the project, started after the old lead: the new lead goes before it, where the old was.
        let mine = try await spawn("Claude", in: world.root, world)
        readings[old.id] = Self.idle
        let new = try await replace(world, old: old)
        readings[new.id] = Self.working  // Its first turn, under way.
        #expect(await until { world.controller.replacedLeads[old.id]?.live == new.id })

        // The window: the old lead's row selected.
        let model = WindowModel(defaults: routing.temp.defaults("handover-window"))
        model.update(sessions: [], hosted: world.host.sessions, table: TableRead())
        model.select(hostID: old.id)
        #expect(model.sections.first?.rows.map(\.hostID) == [old.id, mine.id, new.id])
        var told: [(old: UUID, new: UUID, typed: String)] = []
        world.controller.handedOver = { old, new, typed in
            told.append((old, new, typed))
            model.handedOver(old, to: new)
        }

        // Typed into the old lead meanwhile: what's sent goes to the live lead, as before; what's only typed waits.
        #expect(world.controller.route("make the films page", typedInto: old.id))
        for key in Array("and the blog".utf8) { world.host.send(old.id, bytes: Data([key]), reply: false) }
        #expect(await until { world.controller.replacedLeads[old.id]?.draft == "and the blog" })
        let delivered = { SteerInbox.pending(tty: new.tty, root: world.inbox).filter { $0.agentPid == new.childPID } }
        #expect(await until { delivered().count == 1 })

        // The new lead hasn't ended its first turn: the old one stays, replaced, and Close Finished lists it.
        #expect(await twoLooks(world, looks))
        #expect(looks.ended.isEmpty && live(old.id, world))
        #expect(world.controller.replacedLeads[old.id] != nil)
        let before = CloseFinished.items(rows: rows(world.host.sessions, project: world.project), sessions: world.host.sessions,
                                         replaced: Set(world.controller.replacedLeads.keys))
        #expect(before.map(\.id) == [old.id])

        // Its turn ends: the old one ends by itself.
        readings[new.id] = Self.idle
        #expect(await until {
            world.controller.refresh()
            return !live(old.id, world)
        })
        #expect(looks.ended == [old.id])
        #expect(world.controller.replacedLeads[old.id] == nil)
        // The selection went to the new lead, with what was only typed into the old one.
        #expect(told.map(\.old) == [old.id] && told.map(\.new) == [new.id] && told.map(\.typed) == ["and the blog"])
        #expect(model.selectedID == "host:\(new.id)")
        // In the old one's place.
        #expect(world.controller.leadPlaces == [new.id: RowPlace(start: old.startedAt, tty: old.tty)])
        model.leadPlaces = world.controller.leadPlaces
        model.update(sessions: [], hosted: world.host.sessions, table: TableRead())
        #expect(model.sections.first?.rows.map(\.hostID) == [new.id, mine.id, old.id])
        #expect(model.foldsAway("host:\(old.id)"))
        // Close Finished no longer lists it; the new lead and the user's session were never ended.
        let after = CloseFinished.items(rows: rows(world.host.sessions, project: world.project), sessions: world.host.sessions,
                                        replaced: Set(world.controller.replacedLeads.keys))
        #expect(after.isEmpty)
        #expect(live(new.id, world) && live(mine.id, world))
        // Not marked replaced again while the host still lists it, nor ended twice.
        #expect(await twoLooks(world, looks))
        #expect(looks.ended == [old.id] && world.controller.replacedLeads.isEmpty)
    }

    @Test func theReplacedLeadStaysWhileItsTurnRunsOrItsQuestionIsOpenOrItsStateIsUnknown() async throws {
        let world = try routing.world()
        defer { world.stop() }
        let readings = Readings()
        let looks = watch(world, readings)
        let old = try await routing.oldLead(in: world)
        let new = try await replace(world, old: old)
        readings[new.id] = Self.idle
        #expect(await until { world.controller.replacedLeads[old.id]?.live == new.id })
        for reading in [Self.working, Self.asking, Reading(activity: .idle(background: "a monitor loop"), asking: false, turnEnded: true),
                        Reading(activity: .idle(background: nil), asking: true, turnEnded: true), nil] {
            readings[old.id] = reading
            #expect(await twoLooks(world, looks))
            #expect(looks.ended.isEmpty && live(old.id, world), "\(String(describing: reading))")
            #expect(world.controller.replacedLeads[old.id]?.live == new.id)
        }
        // Its turn over, its question answered: it ends.
        readings[old.id] = Self.idle
        #expect(await until {
            world.controller.refresh()
            return !live(old.id, world)
        })
        #expect(looks.ended == [old.id])
    }

    @Test func aNewLeadWhoseStartEndedBeforeItsFirstTurnEndsNothing() async throws {
        let world = try routing.world()
        defer { world.stop() }
        let readings = Readings()
        let looks = watch(world, readings)
        let old = try await routing.oldLead(in: world)
        readings[old.id] = Self.idle
        let new = try await replace(world, old: old)
        readings[new.id] = Self.working
        #expect(await until { world.controller.replacedLeads[old.id]?.live == new.id })
        // The new lead's session ends before its first turn did.
        world.host.kill(new.id)
        #expect(await until { !live(new.id, world) })
        readings[new.id] = Self.idle
        #expect(await twoLooks(world, looks))
        #expect(looks.ended.isEmpty && live(old.id, world))
    }

    @Test func theLeadTheBoardNamesAndEveryOtherSessionAreNeverEnded() async throws {
        let world = try routing.world()
        defer { world.stop() }
        let readings = Readings()
        let looks = watch(world, readings)
        let old = try await routing.oldLead(in: world)
        let new = try await replace(world, old: old)
        // Another project's lead, a worker, a verifier and a shell of this one: all between turns.
        let otherRoot = routing.temp.url("other").path
        try FileManager.default.createDirectory(atPath: otherRoot, withIntermediateDirectories: true)
        let others = [try await spawn("Lead · other", in: otherRoot, world), try await spawn("Worker: Films page", in: world.root, world),
                      try await spawn("Verifier: Films page", in: world.root, world), try await spawn("Shell", in: world.root, world, agent: nil)]
        // The old lead mid-turn until the board names it again: between turns while the board named the new one, it
        // would end, rightly, at any look (the 3 s refresh's too) before the board below is written.
        for session in [new] + others { readings[session.id] = Self.idle }
        readings[old.id] = Self.working
        #expect(await until { world.controller.replacedLeads[old.id]?.live == new.id })

        // The board names the old lead again: it holds the role and is never ended; the new one, replaced by it now,
        // isn't ended either (the vault gives it the role still: not known whose it is).
        try BoardStore(root: world.root).update { board in
            board.leadSession = old.id.uuidString
            board.leadPid = old.childPID
            board.leadTTY = old.tty
        }
        #expect(await until {
            world.controller.refresh()
            return world.controller.replacedLeads[new.id]?.live == old.id && world.controller.replacedLeads[old.id] == nil
        })
        // Its turn over: every session between turns, and the board naming it keeps it.
        readings[old.id] = Self.idle
        #expect(await twoLooks(world, looks))
        #expect(await twoLooks(world, looks))
        #expect(looks.ended.isEmpty && live(old.id, world) && live(new.id, world))

        // Named the new one again: only the old lead ends.
        try BoardStore(root: world.root).update { board in
            board.leadSession = new.id.uuidString
            board.leadPid = new.childPID
            board.leadTTY = new.tty
        }
        #expect(await until {
            world.controller.refresh()
            return !live(old.id, world)
        })
        #expect(await twoLooks(world, looks))
        #expect(looks.ended == [old.id])
        #expect(live(new.id, world) && others.allSatisfy { live($0.id, world) })
    }

    /// The board names the old lead again while a look reads its agent's state (hooks and transcripts, slow on a busy
    /// disk): the look goes by whom the board names after that, and keeps it. Read before, the board named the new
    /// lead and the lead the board names now was ended.
    @Test func aBoardThatNamesTheOldLeadWhileItsStateIsReadKeepsIt() async throws {
        let world = try routing.world()
        defer { world.stop() }
        let readings = Readings()
        let looks = watch(world, readings)
        let old = try await routing.oldLead(in: world)
        let new = try await replace(world, old: old)
        readings[new.id] = Self.idle
        #expect(await until { world.controller.replacedLeads[old.id]?.live == new.id })
        // From now on, the first read of the old lead's state names it on the board meanwhile (as its tool server
        // would), then finds it between turns.
        let renamed = Readings()
        let root = world.root
        world.controller.turnReading = { session, _, _ in
            if session.id == old.id, renamed[old.id] == nil {
                try? BoardStore(root: root).update { board in
                    board.leadSession = old.id.uuidString
                    board.leadPid = old.childPID
                    board.leadTTY = old.tty
                }
                renamed[old.id] = Self.idle
            }
            return session.id == old.id ? Self.idle : readings[session.id] ?? Reading(activity: .unknown, asking: false, turnEnded: false)
        }
        #expect(await until {
            world.controller.refresh()
            return renamed[old.id] != nil
        })
        #expect(await twoLooks(world, looks))
        #expect(await twoLooks(world, looks))
        #expect(looks.ended.isEmpty && live(old.id, world) && live(new.id, world))
        #expect(await until {
            world.controller.refresh()
            return world.controller.replacedLeads[new.id]?.live == old.id && world.controller.replacedLeads[old.id] == nil
        })
        #expect(looks.ended.isEmpty && live(old.id, world))

        // Named the new one again: the old one, between turns, ends.
        try BoardStore(root: world.root).update { board in
            board.leadSession = new.id.uuidString
            board.leadPid = new.childPID
            board.leadTTY = new.tty
        }
        #expect(await until {
            world.controller.refresh()
            return !live(old.id, world)
        })
        #expect(looks.ended == [old.id] && live(new.id, world))
    }

    /// What the decision takes: only all of it ends a replaced lead.
    @Test func theDecisionFailsClosed() {
        let (old, new) = (UUID(), UUID())
        let (named, holder, idle) = (new.uuidString, new.uuidString, Self.idle)
        struct Case { var named: String?; var holder: String?; var old: Reading?; var new: Reading?; var seen: Bool }
        func ends(_ c: Case) -> Bool {
            LeadController.endsReplaced(old: old, new: new, named: c.named, holder: c.holder, oldReading: c.old, newReading: c.new, newTurnEnded: c.seen)
        }
        #expect(ends(Case(named: named, holder: holder, old: idle, new: nil, seen: true)))
        #expect(ends(Case(named: named, holder: holder, old: idle, new: idle, seen: false)))
        #expect(!ends(Case(named: named, holder: holder, old: idle, new: Self.working, seen: false)))
        #expect(!ends(Case(named: named, holder: holder, old: idle, new: nil, seen: false)))
        // The board names the old one, or none (unreadable), or the vault doesn't bind the new one (its start failed).
        #expect(!ends(Case(named: old.uuidString, holder: holder, old: idle, new: idle, seen: true)))
        #expect(!ends(Case(named: nil, holder: holder, old: idle, new: idle, seen: true)))
        #expect(!ends(Case(named: named, holder: nil, old: idle, new: idle, seen: true)))
        #expect(!ends(Case(named: named, holder: old.uuidString, old: idle, new: idle, seen: true)))
        // The old one mid-turn, asking, waiting on its own background work, or not known.
        for reading in [Self.working, Self.asking, Reading(activity: .idle(background: nil), asking: true, turnEnded: true),
                        Reading(activity: .idle(background: "a monitor"), asking: false, turnEnded: true),
                        Reading(activity: .unknown, asking: false, turnEnded: false), nil] {
            #expect(!ends(Case(named: named, holder: holder, old: reading, new: idle, seen: true)), "\(String(describing: reading))")
        }
        #expect(!LeadController.endsReplaced(old: old, new: old, named: old.uuidString, holder: old.uuidString, oldReading: idle,
                                             newReading: idle, newTurnEnded: true))
    }

    /// Read from its hooks: a turn has ended only on Stop (a just-started agent's SessionStart is idle, but no turn of
    /// its has ended); a question of its own open is asking.
    @Test func theReadingTellsAnEndedTurnAndAnOpenQuestion() async throws {
        let world = try routing.world()
        defer { world.stop() }
        let session = try await routing.oldLead(in: world)
        let file = routing.temp.url("hook-state.json")
        let observer = LeadObserver(home: world.home, stateFile: { _ in file })
        func reading(_ event: String, tool: String? = nil, question: String? = nil) throws -> Reading {
            var hook = HookState(agent: .claude, tty: session.tty, lastEvent: event, lastEventAt: Date().timeIntervalSince1970)
            hook.agentPid = session.childPID
            hook.toolName = tool
            hook.openQuestion = question
            try hook.save(to: file)
            return Reading.read(observer, session, agentPid: session.childPID, background: nil)
        }
        #expect(try reading("Stop") == Self.idle)
        #expect(try reading("SessionStart") == Reading(activity: .idle(background: nil), asking: false, turnEnded: false))
        #expect(try reading("PreToolUse", tool: "Bash").activity == .working(nil))
        #expect(try reading("PreToolUse", tool: "Bash").turnEnded == false)
        let asked = try reading("Stop", question: "Which page first?")
        #expect(asked.asking && asked.activity != .idle(background: nil))
        #expect(Reading.read(observer, session, agentPid: session.childPID + 1, background: nil).activity == .unknown)
        try FileManager.default.removeItem(at: file)
        #expect(Reading.read(observer, session, agentPid: session.childPID, background: nil).activity == .unknown)
    }

    /// Before its first hook, a lead's turn is read from nothing: not from a transcript found by its folder and name,
    /// which may be the other lead's (the replaced one shares both, and its turn just ended).
    @Test func noHookReadsAsUnknownNotAsTheOtherLeadsTranscript() async throws {
        let world = try routing.world()
        defer { world.stop() }
        let session = try await routing.oldLead(in: world)
        let folder = URL(fileURLWithPath: world.home).appendingPathComponent(".claude/projects/\(RecentProjects.claudeSlug(for: world.root))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"make the films page"},"uuid":"u1","timestamp":"\#(stamp)"}"#,
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done: the films page is a task."}]},"uuid":"a1","timestamp":"\#(stamp)"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("other-lead.jsonl"), atomically: true, encoding: .utf8)
        let observer = LeadObserver(home: world.home, stateFile: { _ in routing.temp.url("no-hook-state.json") })
        // The name-and-folder lookup finds it, and it ends on a finished turn.
        let found = try #require(observer.transcript(session, hook: nil))
        #expect(TranscriptTail.read(url: URL(fileURLWithPath: found))?.state == .turnOver(apiError: nil))
        let read = Reading.read(observer, session, agentPid: session.childPID, background: nil)
        #expect(read == Reading(activity: .unknown, asking: false, turnEnded: false))
    }

    /// The old lead's unsent text goes to the new lead's box, ahead of what's there: nothing is dropped.
    @Test func theOldLeadsUnsentTextIsCarriedToTheNewLeadsBox() {
        let composer = ComposerDrafts()
        composer.drafts = ["host:old": "the composer's draft", "host:new": "the new lead's own"]
        composer.attachments = ["host:old": ["/scratch/a.png"], "host:new": ["/scratch/b.png", "/scratch/a.png"]]
        MainWindowController.carryDraft(composer, from: "host:old", to: "host:new", typed: "typed in its terminal")
        #expect(composer.drafts["host:new"] == "the composer's draft\ntyped in its terminal\nthe new lead's own")
        #expect(composer.drafts["host:old"] == nil)
        #expect(composer.attachments["host:new"] == ["/scratch/a.png", "/scratch/b.png"])
        #expect(composer.attachments["host:old"] == nil)
        // Nothing to carry: the new lead's box is as it was.
        MainWindowController.carryDraft(composer, from: "host:gone", to: "host:new", typed: "")
        #expect(composer.drafts["host:new"] == "the composer's draft\ntyped in its terminal\nthe new lead's own")
    }
}
