import AppKit
import SwiftUI
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Only made-up session ids, ttys and a fake spawner: no host connection or real agent input.
@MainActor
struct LeadRotationTests {
    let temp = Scratch()

    final class RotationRuntime: LeadRuntime {
        let server = "/fake-mcp"
        func claudeCommand(root: String) -> String { "fake-claude" }
        func spawn(cwd: String, command: String, env: [String: String], label: String, agent: String) throws -> String { throw LeadVault.Refused("unused fake spawn") }
        func answerTrust(session: String, folder: String) {}
        func kill(_ session: String) throws { throw LeadVault.Refused("unused fake kill") }
        func forget(_ session: String) {}
        func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String, clearDraft: Bool) throws -> LeadDelivery.Delivered { throw LeadVault.Refused("unused fake steer") }
        func sessions() throws -> [LeadSessionInfo] { [] }
        func transcript(of session: String) throws -> String? { nil }
        func currentAgent() -> LeadAgent? { nil }
        func isRunning(_ agent: LeadAgent) -> Bool { false }
        func loadAverages() -> MacLoad.Averages? { nil }
        func agentEnding(_ session: LeadSessionInfo) -> String? { nil }
    }

    final class TransferFault: @unchecked Sendable {
        enum Mode { case none, before, lostReply, lostReplies, lostThenRefused }
        private let lock = NSLock()
        private var mode: Mode
        init(_ mode: Mode) { self.mode = mode }
        func take() -> Mode { lock.withLock { let value = mode; mode = value == .lostReplies ? .lostReply : (value == .lostThenRefused ? .before : .none); return value } }
    }

    @MainActor final class World {
        var now = Date().addingTimeInterval(1000)
        var mode = LeadRotationMode.context
        var handoverMarker = ""
        var requested = 0
        var checks = 0
        var cancelled = 0
        var spawns: [SpawnRequest] = []
        var failSpawn = false
        var retained = 0
        var queued = false
        var spawnHook: (() throws -> Void)?
        let root: String
        let path: URL
        let hook: URL
        let inbox: URL
        let old: HostSession
        let fresh: HostSession
        let book: LeadVault.Book
        let vault: LeadVault
        let controller: LeadController
        let home: String

        init(_ temp: Scratch, fault: TransferFault = TransferFault(.none)) throws {
            root = temp.url("project").path
            home = temp.url("home").path
            inbox = temp.url("inbox")
            hook = temp.url("hook.json")
            path = URL(fileURLWithPath: home + "/.claude/projects/fake/old.jsonl")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let projectRoot = root
            func session(_ tty: String) -> HostSession {
                HostSession(id: UUID(), tty: tty, childPID: 999991, cwd: projectRoot, command: "fake-claude", label: "Lead · fake",
                            agent: "claude", title: "", startedAt: Date().addingTimeInterval(-90000), cols: 80, rows: 24, exit: nil)
            }
            old = session("ttys981"); fresh = session("ttys982")
            book = LeadVault.Book()
            let direct = book.vault(folder: temp.url("vault"), as: { .app })
            vault = LeadVault(folder: direct.folder) { request in
                if case .rotateLead = request {
                    switch fault.take() {
                    case .none: break
                    case .before: return .refused("fake transfer error")
                    case .lostReply, .lostReplies, .lostThenRefused:
                        _ = try direct.ask(request)
                        throw LeadVault.Refused("fake lost reply")
                    }
                }
                return try direct.ask(request)
            }
            let grant = try vault.issue(role: .lead, root: root, task: nil)
            try vault.bind(grant, root: root, session: old.id.uuidString)
            let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { temp.url("states") }, cwd: { _ in nil }, arguments: { _ in [] }))
            let host = HostClient(socketPath: temp.url("no-host.sock").path, note: { _ in })
            controller = LeadController(host: host, store: store, vault: vault, inbox: inbox, home: home) { _ in "fake-claude" }
            controller.answersTrust = false
            controller.preflight = { _ in nil }
            controller.rotationObserver = LeadObserver(home: home, stateFile: { [unowned self] _ in self.hook })
            controller.rotationNow = { [unowned self] in self.now }
            controller.rotationMode = { [unowned self] in self.mode }
            controller.rotationUserQueued = { [unowned self] _ in self.queued }
            controller.rotationEvent = { [unowned self] event in
                if event == "checked" { self.checks += 1 }
                if event == "cancelled" { self.cancelled += 1 }
                if event == "retained" { self.retained += 1 }
            }
            controller.rotationRequest = { [unowned self] text, done in
                #expect(text.contains("open threads") && text.contains("timers due"))
                self.handoverMarker = text.components(separatedBy: .whitespacesAndNewlines).first { $0.hasPrefix("VIBESWITCHER_HANDOVER_") } ?? ""
                self.requested += 1; done(true)
            }
            controller.rotationSpawn = { [unowned self] request, done in
                self.spawns.append(request)
                do { try self.spawnHook?() } catch { Issue.record(error) }
                if self.failSpawn { done(.failure(HostClientError(message: "fake spawn failure"))) }
                else { done(.success(self.fresh)) }
            }
            try BoardStore(root: root).prepare()
            try BoardStore(root: root).update { board in
                board.leadSession = old.id.uuidString; board.leadPid = old.childPID; board.leadTTY = old.tty
                board.questions = [LeadQuestion(id: "open", text: "Which direction?", options: [])]
            }
            try transcript(note: false)
        }

        func transcript(note: Bool, event: String = "Stop", tokens: Int = 144000, user: Bool = true) throws {
            func line(_ object: [String: Any]) throws -> String {
                String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
            }
            let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(note ? 1 : -10))
            var text = user ? try line(["type": "user", "uuid": "u", "timestamp": stamp,
                                       "message": ["role": "user", "content": "keep my promise"]]) : ""
            text += try line(["type": "assistant", "uuid": note ? "note" : "reply", "timestamp": stamp,
                              "message": ["role": "assistant", "model": "claude-opus-4-6", "stop_reason": "end_turn",
                                          "usage": ["input_tokens": tokens],
                                          "content": [["type": "text", "text": note ? handoverMarker + "\nOpen threads: keep the promise; timer due tomorrow." : "I promised a result."]]]])
            try text.write(to: path, atomically: true, encoding: .utf8)
            LeadContextStore(root: inbox, home: home).record([
                "transcript_path": path.path,
                "context_window": ["context_window_size": 200000, "used_percentage": Double(tokens) / 200000 * 100] as [String: Any]
            ], now: now)
            _ = try #require(LeadContextStore(root: inbox, home: home).percent(transcript: path.path, started: old.startedAt),
                             "The fake status line must have recorded this session's context")
            var state = HookState(agent: .claude, tty: old.tty, lastEvent: event, lastEventAt: now.addingTimeInterval(2).timeIntervalSince1970)
            state.agentPid = old.childPID; state.transcriptPath = path.path
            try state.save(to: hook)
        }

        func tick() async {
            let before = checks
            controller.rotateIfDue(root: root, session: old)
            #expect(await until { self.checks > before })
        }
        var holder: String? { vault.current(.lead, root: root, task: nil)?.session }
    }

    @Test func fullQuietLeadHandsOverNoteLastTurnsAndOpenQuestions() async throws {
        let world = try World(temp)
        let lead = world.book.vault(folder: world.vault.folder, as: { .session(world.old.id.uuidString) })
        for role in [LeadLaunch.Role.worker, .verifier] {
            let grant = try lead.issue(role: role, root: world.root, task: "running-task")
            try lead.bind(grant, root: world.root, session: role.rawValue + "-still-running")
        }
        await world.tick()
        #expect(world.requested == 1 && world.spawns.isEmpty && world.holder == world.old.id.uuidString)
        try world.transcript(note: true)
        await world.tick()
        #expect(await until { world.controller.rotationNotices[world.fresh.id] != nil })
        #expect(world.holder == world.fresh.id.uuidString)
        #expect(world.spawns.count == 1)
        for role in [LeadLaunch.Role.worker, .verifier] {
            #expect(world.vault.current(role, root: world.root, task: "running-task")?.session == role.rawValue + "-still-running")
        }
        let spawn = try #require(world.spawns.first)
        #expect(spawn.command?.contains("scheduled rotation") == true && spawn.command?.contains("scheduled-lead-handover.md") == true)
        let note = try String(contentsOfFile: world.root + "/.vibeswitcher/scheduled-lead-handover.md", encoding: .utf8)
        #expect(note.contains("timer due tomorrow"))
        let turns = try String(contentsOfFile: LeadLaunch.turnsFile(root: world.root), encoding: .utf8)
        #expect(turns.contains("keep my promise"))
        #expect(BoardStore(root: world.root).load().openQuestions.count == 1)
        #expect(world.controller.rotationNotices[world.fresh.id]?.contains("72% full") == true)
    }

    @Test func aTurnOrQueuedReportWaitsForQuiet() async throws {
        let world = try World(temp)
        try world.transcript(note: false, event: "PreToolUse")
        await world.tick()
        #expect(world.requested == 0)
        try world.transcript(note: false)
        let message = SteerMessage(text: "report ready", from: .system("worker"), agentPid: world.old.childPID)
        _ = try SteerInbox.post(message, tty: world.old.tty, root: world.inbox)
        await world.tick()
        #expect(world.requested == 0)
        _ = SteerInbox.withdraw(id: message.id, tty: world.old.tty, root: world.inbox)
        await world.tick()
        #expect(world.requested == 1)
    }

    @Test func dailyNeverAndRecentTypingRespectTheSetting() async throws {
        let world = try World(temp)
        world.mode = .never
        world.controller.rotateIfDue(root: world.root, session: world.old)
        #expect(world.requested == 0)
        world.mode = .daily
        try world.transcript(note: false, tokens: 1000)
        world.controller.noteLeadInput(world.old.id)
        world.controller.rotateIfDue(root: world.root, session: world.old)
        #expect(world.requested == 0)
        world.now = world.now.addingTimeInterval(121)
        await world.tick()
        #expect(world.requested == 1)
        #expect(LeadRotation.reason(mode: .daily, started: world.now, percent: 99, now: world.now) == nil)
    }

    @Test func failedSpawnOrBusyToolKeepsOldLead() async throws {
        let world = try World(temp)
        let lock = try #require(FileLock.attempt(LeadRotation.gate(world.root)))
        await world.tick()
        #expect(world.requested == 0)
        lock.release()
        await world.tick()
        try world.transcript(note: true)
        world.failSpawn = true
        await world.tick()
        #expect(await until { world.cancelled == 1 })
        #expect(world.holder == world.old.id.uuidString)
        #expect(BoardStore(root: world.root).load().leadSession == world.old.id.uuidString)
    }

    @Test func aNewTurnDuringSpawnCancelsTheTransfer() async throws {
        let world = try World(temp)
        await world.tick()
        try world.transcript(note: true)
        world.spawnHook = { [unowned world] in try world.transcript(note: true, event: "PreToolUse") }
        await world.tick()
        #expect(await until { world.cancelled == 1 })
        #expect(world.holder == world.old.id.uuidString)
    }

    @Test func missingNoteTimesOutAndLeavesOldRole() async throws {
        let world = try World(temp)
        await world.tick()
        world.now = world.now.addingTimeInterval(61)
        await world.tick()
        #expect(world.cancelled == 1 && world.spawns.isEmpty && world.holder == world.old.id.uuidString)
    }

    @Test func transferErrorsRestoreTheOldLeadEvenIfTheReplyWasLost() async throws {
        for fault in [TransferFault.Mode.before, .lostReply] {
            let world = try World(temp, fault: TransferFault(fault))
            let originalGrant = world.vault.current(.lead, root: world.root, task: nil)?.id
            let oldTools = LeadToolset(root: world.root, runtime: RotationRuntime(),
                                      vault: world.book.vault(folder: world.vault.folder, as: { .session(world.old.id.uuidString) }))
            #expect(!oldTools.call("questions", [:]).isError)
            await world.tick()
            try world.transcript(note: true)
            await world.tick()
            #expect(await until { world.cancelled == 1 })
            #expect(world.holder == world.old.id.uuidString)
            #expect(BoardStore(root: world.root).load().leadSession == world.old.id.uuidString)
            #expect(world.controller.rotationNotices.isEmpty)
            #expect(world.vault.current(.lead, root: world.root, task: nil)?.id == originalGrant,
                    "The old MCP server must retain its original grant, not just the same session id")
            #expect(!oldTools.call("questions", [:]).isError, "The existing server must still authenticate")
        }
    }

    @Test func inputToAnotherSessionDoesNotCancelRotation() async throws {
        let world = try World(temp)
        await world.tick()
        try world.transcript(note: true)
        world.spawnHook = { [unowned world] in
            #expect(!world.controller.takeInput(Data("worker input".utf8), for: UUID()))
        }
        await world.tick()
        #expect(await until { world.cancelled > 0 })
        #expect(world.holder == world.fresh.id.uuidString)
    }

    @Test func rotatedLeadRegistersThePolicyInItsPrompt() async throws {
        let world = try World(temp)
        let policy = WorkingPolicy.load()
        let watch = LeadWitness.PolicyWatch(read: { policy }, file: temp.url("policy-told.json"))
        world.controller.policyWatch = watch
        await world.tick()
        try world.transcript(note: true)
        await world.tick()
        #expect(await until { world.cancelled > 0 })
        #expect(world.holder == world.fresh.id.uuidString)
        #expect(watch.look(running: [world.fresh.id.uuidString]) == nil,
                "The new lead already has the policy in its prompt")
        let changed = LeadWitness.PolicyWatch(read: { policy + "\nChanged rule" }, file: temp.url("policy-told.json"))
        #expect(changed.look(running: [world.fresh.id.uuidString])?.leads == [world.fresh.id.uuidString])
    }

    @Test func aLostRollbackReplyStillRestoresTheBoard() async throws {
        let world = try World(temp, fault: TransferFault(.lostReplies))
        await world.tick()
        try world.transcript(note: true)
        await world.tick()
        #expect(await until { world.cancelled > 0 })
        #expect(world.holder == world.old.id.uuidString)
        let board = BoardStore(root: world.root).load()
        #expect(board.leadSession == world.old.id.uuidString)
        #expect(board.leadPid == world.old.childPID && board.leadTTY == world.old.tty)
        #expect(world.controller.rotationNotices.isEmpty)
        #expect(world.retained == 0)
    }

    @Test func aFailedRoleRestoreKeepsTheFreshSessionAndReportsRecovery() async throws {
        let world = try World(temp, fault: TransferFault(.lostThenRefused))
        await world.tick()
        try world.transcript(note: true)
        await world.tick()
        #expect(await until { world.cancelled > 0 })
        #expect(world.holder == world.fresh.id.uuidString)
        #expect(world.retained == 1, "Keep the session that may still hold the lead role")
        let board = BoardStore(root: world.root).load()
        #expect(board.leadSession == world.old.id.uuidString)
        #expect(board.leadPid == world.old.childPID && board.leadTTY == world.old.tty)
        let report = try #require(board.reports?.first { $0.about == "scheduled rotation" })
        #expect(report.text.contains(world.old.id.uuidString) && report.text.contains(world.fresh.id.uuidString))
        #expect(report.text.contains("reconciliation"))
        #expect(world.controller.rotationNotices.isEmpty)
    }

    @Test func typingInvalidatesThePendingHandover() async throws {
        let world = try World(temp)
        await world.tick()
        world.controller.noteLeadInput(world.old.id)
        world.now = world.now.addingTimeInterval(121)
        try world.transcript(note: true) // An ordinary answer to the intervening user message.
        await world.tick()
        #expect(world.spawns.isEmpty && world.requested == 2,
                "After user input, ask for a fresh handover instead of accepting an unrelated reply")
    }

    @Test func aNoteWrittenAfterTheDeadlineCannotRotate() async throws {
        let world = try World(temp)
        await world.tick()
        world.now = world.now.addingTimeInterval(61)
        try world.transcript(note: true)
        await world.tick()
        #expect(world.cancelled == 1 && world.spawns.isEmpty)
    }

    @Test func aMissingAgentKeepsTheRunningLead() async throws {
        let world = try World(temp)
        world.controller.preflight = { _ in LaunchPreflight.Problem(missing: [.agent(program: "fake-claude", shell: "/bin/sh")]) }
        await world.tick()
        try world.transcript(note: true)
        await world.tick()
        #expect(await until { world.cancelled > 0 || !world.spawns.isEmpty })
        #expect(world.spawns.isEmpty && world.holder == world.old.id.uuidString)
    }

    @Test func aLeadWithNoUserTurnsCanStillHandOverItsNote() async throws {
        let world = try World(temp)
        await world.tick()
        try world.transcript(note: true, user: false)
        await world.tick()
        #expect(await until { world.cancelled > 0 || world.controller.rotationNotices[world.fresh.id] != nil })
        #expect(world.holder == world.fresh.id.uuidString)
    }

    @Test func theStatusLinesActualWindowDecidesWhetherContextIsLarge() async throws {
        let world = try World(temp)
        let input: [String: Any] = ["transcript_path": world.path.path,
            "context_window": ["context_window_size": 1000000, "current_usage": ["input_tokens": 144000]]]
        let context = LeadContextStore(root: world.inbox, home: world.home)
        UsageStatusLine.run(input: try JSONSerialization.data(withJSONObject: input),
                            store: AccountUsageStore(file: temp.url("usage.json")), home: world.home, now: world.now,
                            contextStore: context) { _ in }
        #expect(context.percent(transcript: world.path.path, started: world.old.startedAt) == 14)
        await world.tick()
        #expect(world.requested == 0, "144k is small in a 1M window even when the model name is the same")
        #expect(context.percent(transcript: world.path.path, started: world.now.addingTimeInterval(1)) == nil)
        try world.transcript(note: false)
        await world.tick()
        #expect(world.requested == 1)
    }

    @Test func toolsCanOverlapButRotationWaitsForEveryCall() throws {
        let file = LeadRotation.gate(temp.url("gate-project").path)
        let first = try #require(FileLock.attempt(file, shared: true))
        let second = try #require(FileLock.attempt(file, shared: true))
        #expect(FileLock.attempt(file) == nil)
        first.release()
        #expect(FileLock.attempt(file) == nil)
        second.release()
        let rotation = try #require(FileLock.attempt(file))
        #expect(FileLock.attempt(file, shared: true) == nil)
        rotation.release()
    }

    @Test func preferenceDefaultsToContextAndPersistsNever() {
        let defaults = temp.defaults("rotation")
        let presets = temp.url("presets")
        let preferences = Preferences(defaults: defaults, presetsFile: presets)
        #expect(preferences.leadRotation == .context)
        preferences.leadRotation = .never
        #expect(Preferences(defaults: defaults, presetsFile: presets).leadRotation == .never)
    }

    @Test func rotationNoticeDrawsInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = LeadRotationNotice(text: "Started a fresh lead session (the last one's context was 72% full)")
                .frame(width: 540).background(scheme == .dark ? Color.black : Color.white).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            #expect(image.size.width == 540 && image.size.height > 20)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            let folder = ProcessInfo.processInfo.environment["ROTATION_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) } ?? temp.url("shots")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("rotation-notice-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

}


@MainActor
struct LeadRotationToolGateTests {
    @Test func aRoutineContextReadDoesNotBlockLeadTools() async throws {
        let temp = Scratch()
        let world = try LeadRotationTests.World(temp)
        try world.transcript(note: false, tokens: 1000)
        let release = DispatchSemaphore(value: 0)
        let first = LeadRotationTests.TransferFault(.before)
        let hook = world.hook
        var reading = false
        world.controller.rotationObserver = LeadObserver(home: world.home, stateFile: { _ in
            if case .before = first.take() {
                DispatchQueue.main.async { reading = true }
                release.wait()
            }
            return hook
        })
        world.controller.rotateIfDue(root: world.root, session: world.old)
        #expect(await until { reading })
        let tool = FileLock.attempt(LeadRotation.gate(world.root), shared: true)
        #expect(tool != nil, "Looking at a small context must not claim the rotation's exclusive gate")
        release.signal()
        tool?.release()
        #expect(await until { world.checks > 0 })
        #expect(world.requested == 0)
    }

}
