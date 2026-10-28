import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// "Needs you" on the phone means you, as on the Mac (`Session.shownStatus`): a worker or verifier waiting on input
/// is its lead's to answer, so `/api/state` says it waits on its lead and offers no menu of its prompt; a lead with a
/// question for you open needs you, its terminal idle or not.
///
/// Phone Access is served in memory only (`serveForTests`), the sessions are window sessions from a made-up process
/// table, and screens come from a stand-in reader: nothing is read from or typed into any terminal.
@MainActor
@Suite(.serialized)
struct PhoneNeedsYouTests {
    nonisolated static let host = "mac.tail1234.ts.net"
    nonisolated static let login = "me@example.com"
    nonisolated static let menuScreen = """
    Do you want to make this edit to notes.md?
    ❯ 1. Yes
      2. Yes, allow all edits during this session (shift+tab)
      3. No, and tell Claude what to do differently (esc)
    """

    private let scratch = Scratch()

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    struct Window {
        var tty: String
        var label: String
        var event: String
        var cwd: String
        /// Where the agent's hooks say it is now, when it `cd`'d away from `cwd` (its window session's folder).
        var hookCwd: String? = nil
    }

    /// A store with each of `windows` as a Claude window session, its hooks' last event `event`, labelled as the lead
    /// labels its team's windows.
    private func store(_ windows: [Window]) async throws -> SessionStore {
        AppStatus.enabled = false
        let stateDir = scratch.url("phone-needs-you")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let start = Date().addingTimeInterval(-600)
        var table: [ProcInfo] = []
        for (index, window) in windows.enumerated() {
            let shell = Int32(880 + index * 2)
            table += [ProcInfo(pid: shell, ppid: 1, tty: window.tty, comm: "zsh", startTime: start, agent: nil),
                      ProcInfo(pid: shell + 1, ppid: shell, tty: window.tty, comm: "claude", startTime: start, agent: .claude)]
            var hook = HookState(agent: .claude, tty: window.tty, lastEvent: window.event,
                                 lastEventAt: Date().addingTimeInterval(-30).timeIntervalSince1970)
            hook.agentPid = shell + 1
            hook.cwd = window.hookCwd
            try hook.save(to: stateDir.appendingPathComponent("\(window.tty).json"))
        }
        let cwds = Dictionary(uniqueKeysWithValues: table.map { proc in (proc.pid, windows.first { $0.tty == proc.tty }?.cwd ?? "/") })
        let bridge = TerminalPoll<TerminalTab>.Bridge(tabs: { .tabs([:]) }, screens: { _ in [:] })
        let store = SessionStore(scanner: SessionScanner(processes: { Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0) }) },
                                                         stateDir: { stateDir }, cwd: { cwds[$0] },
                                                         arguments: { _ in [] }),
                                 bridge: bridge)
        store.terminalFront = { (false, nil) }
        store.updateHosted(windows.enumerated().map { index, window in
            HostSession(id: UUID(), tty: window.tty, childPID: Int32(880 + index * 2), cwd: window.cwd, command: "claude",
                        label: window.label, agent: "claude", title: window.label, startedAt: start, cols: 80, rows: 24, exit: nil)
        })
        let before = store.scansApplied
        store.refresh()
        #expect(await until { store.scansApplied > before && windows.allSatisfy { w in store.sessions.contains { $0.tty == w.tty && $0.inWindow } } })
        return store
    }

    private func request(_ method: String, _ path: String, token: String? = nil, body: String = "") throws -> HTTPRequest {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(Self.host):\(PhoneAccess.httpsPort)\r\n"
            + "Tailscale-User-Login: \(Self.login)\r\nX-Forwarded-For: 100.64.0.7\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let parsed) = HTTPParser.parse(Data(head.utf8)) else { throw CancellationError() }
        return parsed
    }

    /// Phone Access served for `store`, one phone paired, screens read by `screen` (the tty asked for, counted in
    /// `reads`): its token. `done` unpairs it.
    private func serve(_ store: SessionStore, reads: Box<[String]>) throws -> (access: PhoneAccess, token: String, done: () -> Void) {
        let access = PhoneAccess(store: store)
        access.serveForTests(.init(dnsName: Self.host, login: Self.login, httpsAvailable: true))
        access.screenLocked = { false }
        access.readTerminalScreen = { tty in
            reads.value.append(tty)
            return Self.menuScreen
        }
        access.typeInTerminal = { _, _, _, _, _, _ in .notInTerminal }
        access.sendToWindow = { _, _, _, confirmed in confirmed(false) }
        access.startPairing()
        let code = try #require(access.pairing?.code)
        let paired = Box<[String: Any]>([:])
        access.handleForTests(try request("POST", "/api/pair", body: #"{"code":"\#(code)","name":"Needs-you phone"}"#)) {
            paired.value = ((try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]) ?? [:]
        }
        let token = try #require(paired.value["token"] as? String)
        return (access, token, { for device in access.devices { access.remove(device) } })
    }

    /// `GET path`'s answer, once it came.
    private func get(_ access: PhoneAccess, _ path: String, token: String) async throws -> [String: Any] {
        let answer = Box<[String: Any]?>(nil)
        access.handleForTests(try request("GET", path, token: token)) {
            answer.value = ((try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]) ?? [:]
        }
        #expect(await until { answer.value != nil })
        return try #require(answer.value)
    }

    private func row(_ state: [String: Any], _ tty: String) throws -> [String: Any] {
        let sessions = try #require(state["sessions"] as? [[String: Any]])
        return try #require(sessions.first { $0["tty"] as? String == tty })
    }

    @Test func aWorkerWaitingOnItsLeadIsntOfferedToYou() async throws {
        let worker = Window(tty: "ttys971", label: "Worker: fix-login", event: "Notification", cwd: "/r/acme/.vibeswitcher/worktrees/fix")
        let store = try await store([worker])
        #expect(store.sessions.first { $0.tty == worker.tty }?.waitsOnLead == true)
        let reads = Box<[String]>([])
        let (access, token, done) = try serve(store, reads: reads)
        defer { done() }

        // A state asks for the menus of the sessions waiting on you; the phone's view of the worker's screen reads it
        // (and notes the menu on it). One queue reads screens, so once the screen is answered any read the state
        // started is done too.
        _ = try await get(access, "/api/state", token: token)
        let screen = try await get(access, "/api/screen?tty=\(worker.tty)", token: token)
        #expect(screen["text"] as? String == Self.menuScreen)
        #expect(reads.value == [worker.tty], "only the screen the phone asked for is read: the worker's prompt isn't yours")

        let state = try await get(access, "/api/state", token: token)
        let row = try row(state, worker.tty)
        #expect(row["status"] as? String == SessionStatus.working.rawValue)
        #expect(row["statusLabel"] as? String == LeadTeams.waitsOnLeadLabel)
        #expect(row["menu"] == nil, "its lead answers the worker's prompt, not the phone")
    }

    @Test func aWorkerThatCdsAwayStillShowsItsTaskUnderItsLead() async throws {
        let worker = Window(tty: "ttys974", label: "Worker: fix-login", event: "PreToolUse", cwd: "/r/acme/.vibeswitcher/worktrees/fix-login",
                            hookCwd: "/tmp/scratch")
        let store = try await store([worker])
        #expect(store.sessions.first { $0.tty == worker.tty }?.cwd == "/tmp/scratch")
        let (access, token, done) = try serve(store, reads: Box([]))
        defer { done() }

        let row = try row(try await get(access, "/api/state", token: token), worker.tty)
        #expect(row["role"] as? String == "worker")
        #expect(row["lead"] as? String == PhoneLeads.id(root: "/r/acme"))
        #expect(row["teamTask"] as? String == "fix-login")
    }

    @Test func yourOwnSessionsPromptIsStillOffered() async throws {
        let own = Window(tty: "ttys972", label: "w", event: "Notification", cwd: "/r/acme")
        let store = try await store([own])
        let reads = Box<[String]>([])
        let (access, token, done) = try serve(store, reads: reads)
        defer { done() }

        _ = try await get(access, "/api/screen?tty=\(own.tty)", token: token)
        let state = try await get(access, "/api/state", token: token)
        let row = try row(state, own.tty)
        #expect(row["status"] as? String == SessionStatus.needsInput.rawValue)
        #expect(row["statusLabel"] as? String == SessionStatus.needsInput.label)
        let menu = try #require(row["menu"] as? [String: Any])
        #expect((menu["options"] as? [String])?.first == "Yes")
    }

    @Test func aLeadWithAQuestionForYouNeedsYouOnThePhone() async throws {
        let lead = Window(tty: "ttys973", label: "Lead · acme", event: "Stop", cwd: "/r/acme")
        let store = try await store([lead])
        #expect(store.sessions.first { $0.tty == lead.tty }?.status != .needsInput)
        store.leadsAsking = ["/r/acme"]
        let reads = Box<[String]>([])
        let (access, token, done) = try serve(store, reads: reads)
        defer { done() }

        let state = try await get(access, "/api/state", token: token)
        let row = try row(state, lead.tty)
        #expect(row["status"] as? String == SessionStatus.needsInput.rawValue)
        #expect(row["statusLabel"] as? String == SessionStatus.needsInput.label)
    }
}
