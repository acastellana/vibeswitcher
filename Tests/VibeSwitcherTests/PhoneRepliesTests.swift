import Foundation
import Network
import Testing
import VibeCore
@testable import VibeSwitcher

/// A phone reply is typed once, and the phone hears ok only once it went in: two quick sends of one reply type it once,
/// a window reply is answered after the session host confirmed every write (an error when it didn't, or there's no
/// host), an arrow meant for a menu is sent only while that menu is up, and a restart of Phone Access keeps the
/// pairing (503, not 401). Messaging audit 2026-10-22 #4, UI audit #7.
///
/// Phone Access is served in memory only (`serveForTests`), sessions come from a made-up process table, and the
/// Terminal typer and the window writer are stand-ins that count: nothing is typed into any terminal.
@MainActor
@Suite(.serialized)
struct PhoneRepliesTests {
    nonisolated static let host = "mac.tail1234.ts.net"
    nonisolated static let login = "me@example.com"
    nonisolated static let tty = "ttys983"
    nonisolated static let menuScreen = """
    Do you want to make this edit to notes.md?
    ❯ 1. Yes
      2. Yes, allow all edits during this session (shift+tab)
      3. No, and tell Claude what to do differently (esc)
    """

    private let scratch = Scratch()
    private let stateDir: URL
    /// The time the Mac's reply dedupe is measured in (`PhoneAccess.replyClock`): still unless a test moves it on, so
    /// how long a loaded Mac takes between two sends never decides whether they're one reply.
    private let clock = Box(Date(timeIntervalSince1970: 1_000_000))

    init() { stateDir = scratch.url("phone-replies") }

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    struct Answer {
        var status: Int
        var body: Data
        var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:] }
        var error: String { json["error"] as? String ?? "" }
    }

    /// A store with one Claude session on `tty`, waiting on you: in a Terminal tab, or (`window`) in the window.
    private func store(window: Bool = false) async throws -> SessionStore {
        AppStatus.enabled = false
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let start = Date().addingTimeInterval(-600)
        let proc = { (pid: Int32, ppid: Int32, comm: String, tty: String?, agent: Agent?) in
            ProcInfo(pid: pid, ppid: ppid, tty: tty, comm: comm, startTime: start, agent: agent)
        }
        let table = window
            ? [proc(870, 1, "zsh", Self.tty, nil), proc(871, 870, "claude", Self.tty, .claude)]
            : [proc(730, 1, "Terminal", nil, nil), proc(860, 730, "login", Self.tty, nil),
               proc(861, 860, "zsh", Self.tty, nil), proc(862, 861, "claude", Self.tty, .claude)]
        var hook = HookState(agent: .claude, tty: Self.tty, lastEvent: "Notification",
                             lastEventAt: Date().addingTimeInterval(-30).timeIntervalSince1970)
        hook.agentPid = window ? 871 : 862
        try hook.save(to: stateDir.appendingPathComponent("\(Self.tty).json"))
        let tabs: [String: TerminalTab] = window ? [:]
            : [Self.tty: TerminalTab(windowID: 1, title: "✳ Edit notes", position: nil, isSelected: true, windowOrder: 1)]
        let bridge = TerminalPoll<TerminalTab>.Bridge(tabs: { .tabs(tabs) }, screens: { _ in [:] })
        let dir = stateDir
        let store = SessionStore(scanner: SessionScanner(processes: { Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0) }) },
                                                         stateDir: { dir }, cwd: { _ in dir.path },
                                                         arguments: { _ in [] }),
                                 bridge: bridge)
        store.terminalFront = { (false, nil) }
        if window {
            store.updateHosted([HostSession(id: UUID(), tty: Self.tty, childPID: 870, cwd: dir.path, command: "claude", label: "w",
                                            agent: "claude", title: "w", startedAt: start, cols: 80, rows: 24, exit: nil)])
        }
        let before = store.scansApplied
        store.refresh()
        #expect(await until { store.scansApplied > before && store.sessions.contains { $0.tty == Self.tty } })
        let session = try #require(store.sessions.first { $0.tty == Self.tty })
        #expect(window ? session.inWindow : session.inTerminalApp && !session.inWindow)
        return store
    }

    /// A request as `tailscale serve` relays it, parsed as the server would.
    private func request(_ method: String, _ path: String, token: String? = nil, body: String = "") throws -> HTTPRequest {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(Self.host):\(PhoneAccess.httpsPort)\r\n"
            + "Tailscale-User-Login: \(Self.login)\r\nX-Forwarded-For: 100.64.0.7\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let parsed) = HTTPParser.parse(Data(head.utf8)) else { throw CancellationError() }
        return parsed
    }

    /// Phone Access served for `store`, replies on, one phone paired: its token. `done` undoes it. `before` runs before
    /// that phone pairs.
    private func serve(_ store: SessionStore, before: (PhoneAccess) throws -> Void = { _ in }) throws
        -> (access: PhoneAccess, token: String, done: () -> Void) {
        let access = PhoneAccess(store: store)
        access.serveForTests(.init(dnsName: Self.host, login: Self.login, httpsAvailable: true))
        access.screenLocked = { false }
        let clock = clock
        access.replyClock = { clock.value }
        access.agentRunning = { _, _, _ in true }
        access.readTerminalScreen = { _ in "" }
        access.typeInTerminal = { _, _, _, _, _, _ in .notInTerminal }
        access.sendToWindow = { _, _, _, confirmed in confirmed(false) }
        try before(access)
        let token = try pair(access, name: "Test phone")
        let wasAllowed = access.inputAllowed
        access.inputAllowed = true
        return (access, token, {
            access.inputAllowed = wasAllowed
            unpair(access, token: token)
        })
    }

    /// Removes the phone `token` belongs to, if it's still paired, and no other: the devices file is the same for every
    /// suite in the run (~/.vibeswitcher/remote), and the others pair their own phones in it at the same time.
    private func unpair(_ access: PhoneAccess, token: String) {
        if let device = access.devices.first(where: { $0.tokenHash == RemoteAuth.hash(token) }) { access.remove(device) }
    }

    /// Pairs a phone named `name` with `access`, as a phone does: its token.
    private func pair(_ access: PhoneAccess, name: String) throws -> String {
        access.startPairing()
        let code = try #require(access.pairing?.code)
        var answer: Answer?
        access.handleForTests(try request("POST", "/api/pair", body: #"{"code":"\#(code)","name":"\#(name)"}"#)) {
            answer = Answer(status: $0.status, body: $0.body)
        }
        return try #require(answer?.json["token"] as? String)
    }

    private func sid(_ store: SessionStore) throws -> String {
        try #require(store.sessions.first { $0.tty == Self.tty }).identity
    }

    /// Sends a request; the answer lands in the returned box.
    private func send(_ access: PhoneAccess, _ request: HTTPRequest) -> Box<Answer?> {
        let box = Box<Answer?>(nil)
        access.handleForTests(request) { box.value = Answer(status: $0.status, body: $0.body) }
        return box
    }

    // MARK: - Typed once

    @Test func aReplySentTwiceWithinASecondIsTypedOnce() async throws {
        let store = try await store()
        let (access, token, done) = try serve(store)
        defer { done() }
        let typed = Box<[String]>([])
        // The first reply types until the test lets it finish (off the main thread, on the typing queue).
        let release = DispatchSemaphore(value: 0)
        let holding = Box(true)
        access.typeInTerminal = { _, _, text, _, _, stillAllowed in
            if holding.value { release.wait() }
            guard stillAllowed() else { return .notAllowed }
            typed.value.append(text ?? "")
            return nil
        }
        let body = #"{"tty":"\#(Self.tty)","sid":"\#(try sid(store))","text":"fix the login bug","submit":true}"#
        // A second Enter while the first is typing: refused, not queued behind it.
        let first = send(access, try request("POST", "/api/input", token: token, body: body))
        let second = send(access, try request("POST", "/api/input", token: token, body: body))
        #expect(await until { second.value != nil })
        #expect(first.value == nil, "the first is still typing")
        holding.value = false
        release.signal()
        #expect(await until { first.value != nil })
        #expect(first.value?.status == 200)
        #expect(second.value?.status == 409)
        #expect(second.value?.error == PhoneAccess.stillTyping)
        // Once typed, the same again within the second (the clock hasn't moved): answered as typed, not typed again.
        let third = send(access, try request("POST", "/api/input", token: token, body: body))
        #expect(await until { third.value != nil })
        #expect(third.value?.status == 200)
        #expect(third.value?.json["duplicate"] as? Bool == true)
        #expect(typed.value == ["fix the login bug"])
        // Just inside the second, still the same; once it's over, a new reply.
        clock.value += PhoneAccess.replyMemory.withoutID - 0.05
        let inside = send(access, try request("POST", "/api/input", token: token, body: body))
        #expect(await until { inside.value != nil })
        #expect(inside.value?.json["duplicate"] as? Bool == true)
        clock.value += 0.1
        let later = send(access, try request("POST", "/api/input", token: token, body: body))
        #expect(await until { later.value != nil })
        #expect(later.value?.status == 200 && later.value?.json["duplicate"] == nil)
        #expect(typed.value.count == 2)
    }

    @Test func aReplySentAgainWithItsIDIsTypedOnceAndKeysAreNotKept() async throws {
        let store = try await store()
        let (access, token, done) = try serve(store)
        defer { done() }
        let typed = Box<[String]>([])
        access.typeInTerminal = { _, _, text, _, key, _ in
            typed.value.append(text ?? key?.rawValue ?? "")
            return nil
        }
        let sid = try sid(store)
        let reply = #"{"tty":"\#(Self.tty)","sid":"\#(sid)","text":"yes","submit":true,"request":"r-1"}"#
        let first = send(access, try request("POST", "/api/input", token: token, body: reply))
        #expect(await until { first.value != nil })
        // Sent again after "check the screen", well past a second: the Mac knows it by its id, for a minute.
        clock.value += 30
        let again = send(access, try request("POST", "/api/input", token: token, body: reply))
        #expect(await until { again.value != nil })
        #expect(again.value?.json["duplicate"] as? Bool == true)
        clock.value += PhoneAccess.replyMemory.withID
        let muchLater = send(access, try request("POST", "/api/input", token: token, body: reply))
        #expect(await until { muchLater.value != nil })
        #expect(muchLater.value?.status == 200 && muchLater.value?.json["duplicate"] == nil)
        // ↓ twice means twice.
        let down = #"{"tty":"\#(Self.tty)","sid":"\#(sid)","key":"down"}"#
        for _ in 0..<2 {
            let pressed = send(access, try request("POST", "/api/input", token: token, body: down))
            #expect(await until { pressed.value != nil })
            #expect(pressed.value?.status == 200)
        }
        #expect(typed.value == ["yes", "yes", "down", "down"])
    }

    @Test func aReplyThatFailedMayBeSentAgain() async throws {
        let store = try await store()
        let (access, token, done) = try serve(store)
        defer { done() }
        let attempts = Box(0)
        access.typeInTerminal = { _, _, _, _, _, _ in
            attempts.value += 1
            return attempts.value == 1 ? .focusFailed : nil
        }
        let body = #"{"tty":"\#(Self.tty)","sid":"\#(try sid(store))","text":"go","submit":true}"#
        let first = send(access, try request("POST", "/api/input", token: token, body: body))
        #expect(await until { first.value != nil })
        #expect(first.value?.status == 409)
        let second = send(access, try request("POST", "/api/input", token: token, body: body))
        #expect(await until { second.value != nil })
        #expect(second.value?.status == 200 && second.value?.json["duplicate"] == nil)
        #expect(attempts.value == 2)
    }

    // MARK: - ✓ only once it went in

    /// A stand-in for the session host's queue of units (`HostClient.send(_:writes:gate:confirmed:)`): before each write
    /// the gate is asked, then the write is noted and `confirm` says whether it went in (at once, by default).
    final class FakeHost: @unchecked Sendable {
        var writes: [[UInt8]] = []
        var confirm: (Int, @escaping (Bool) -> Void) -> Void = { _, done in done(true) }

        func send(_ unit: [HostInput.Write], gate: ((Int, @escaping (Bool) -> Void) -> Void)?,
                  confirmed: @escaping (Bool) -> Void) {
            func step(_ index: Int) {
                guard index < unit.count else { return confirmed(true) }
                let write = {
                    self.writes.append(unit[index].bytes)
                    self.confirm(index) { went in went ? step(index + 1) : confirmed(false) }
                }
                guard let gate else { return write() }
                gate(index) { go in DispatchQueue.main.async { go ? write() : confirmed(false) } }
            }
            step(0)
        }
    }

    private func useHost(_ access: PhoneAccess) -> FakeHost {
        let host = FakeHost()
        access.sendToWindow = { _, writes, gate, confirmed in host.send(writes, gate: gate, confirmed: confirmed) }
        return host
    }

    @Test func aWindowReplyIsAnsweredOnlyOnceEveryWriteWentIn() async throws {
        let store = try await store(window: true)
        let (access, token, done) = try serve(store)
        defer { done() }
        let host = useHost(access)
        let pending = Box<[(Bool) -> Void]>([])
        // The host confirms only when the test says so.
        host.confirm = { _, done in pending.value.append(done) }
        let body = #"{"tty":"\#(Self.tty)","sid":"\#(try sid(store))","text":"hello","submit":true}"#
        let answer = send(access, try request("POST", "/api/input", token: token, body: body))
        #expect(await until { host.writes.count == 1 })
        try await Task.sleep(nanoseconds: 300_000_000)
        // The text is written, not confirmed: no Enter yet, and no answer.
        #expect(host.writes == [Array("hello".utf8)])
        #expect(answer.value == nil)
        pending.value.removeFirst()(true)
        #expect(await until { host.writes.count == 2 })
        #expect(host.writes.last == [13])
        #expect(answer.value == nil)
        pending.value.removeFirst()(true)
        #expect(await until { answer.value != nil })
        #expect(answer.value?.status == 200)
    }

    @Test func aWindowReplyThatDidntGoInIsAnErrorAndItsEnterIsntSent() async throws {
        let store = try await store(window: true)
        let (access, token, done) = try serve(store)
        defer { done() }
        let host = useHost(access)
        host.confirm = { _, done in done(false) }
        let sid = try sid(store)
        let body = #"{"tty":"\#(Self.tty)","sid":"\#(sid)","text":"hello","submit":true}"#
        let answer = send(access, try request("POST", "/api/input", token: token, body: body))
        #expect(await until { answer.value != nil })
        #expect(answer.value?.status == 503)
        #expect(answer.value?.error == PhoneAccess.didntGoIn)
        #expect(host.writes == [Array("hello".utf8)])

        // With no session host at all (the default sender, `hostClient` nil): not confirmed, never ok.
        let plain = PhoneAccess(store: store)
        let went = Box<Bool?>(nil)
        plain.sendToWindow(UUID(), HostInput.writes(text: "x", submit: true, key: nil), nil) { went.value = $0 }
        #expect(went.value == false)
        access.sendToWindow = plain.sendToWindow
        let hostless = send(access, try request("POST", "/api/input", token: token,
                                                body: #"{"tty":"\#(Self.tty)","sid":"\#(sid)","key":"down"}"#))
        #expect(await until { hostless.value != nil })
        #expect(hostless.value?.status == 503)
    }

    /// The gate shuts between the text and Enter: the text went in, Enter didn't, and the phone is told so. Sent again,
    /// it isn't typed a second time into the box that holds it: the same answer.
    @Test func aReplyCutBetweenItsTextAndEnterIsntTypedAgain() async throws {
        let store = try await store(window: true)
        let (access, token, done) = try serve(store)
        defer { done() }
        let host = useHost(access)
        host.confirm = { _, done in
            access.inputAllowed = false
            done(true)
        }
        let sid = try sid(store)
        for body in [#"{"tty":"\#(Self.tty)","sid":"\#(sid)","text":"again","submit":true}"#,
                     #"{"tty":"\#(Self.tty)","sid":"\#(sid)","text":"with id","submit":true,"request":"r-9"}"#] {
            access.inputAllowed = true
            host.writes = []
            let cut = send(access, try request("POST", "/api/input", token: token, body: body))
            #expect(await until { cut.value != nil })
            #expect(cut.value?.status == 409)
            #expect(cut.value?.error == PhoneAccess.partlyWent)
            #expect(host.writes.count == 1)
            access.inputAllowed = true
            host.confirm = { _, done in done(true) }
            let resend = send(access, try request("POST", "/api/input", token: token, body: body))
            #expect(await until { resend.value != nil })
            #expect(resend.value?.status == 409)
            #expect(resend.value?.error == PhoneAccess.partlyWent)
            #expect(host.writes.count == 1, "nothing typed again")
            host.confirm = { _, done in
                access.inputAllowed = false
                done(true)
            }
        }

        // A Terminal reply cut short after some of its text, by another tab coming to the front or by the Mac locking, is
        // kept the same way; one stopped before any text went in may be sent again.
        let terminal = try await self.store()
        let (tab, tabToken, tabDone) = try serve(terminal)
        defer { tabDone() }
        let terminalSid = try self.sid(terminal)
        for (index, cut) in [RemoteInput.Failure.focusMoved(typed: true), .lockedAfterTyping, .locked].enumerated() {
            let attempts = Box(0)
            tab.typeInTerminal = { _, _, _, _, _, _ in
                attempts.value += 1
                return cut
            }
            let body = #"{"tty":"\#(Self.tty)","sid":"\#(terminalSid)","text":"go on \#(index)","submit":true}"#
            let first = send(tab, try request("POST", "/api/input", token: tabToken, body: body))
            #expect(await until { first.value != nil })
            #expect(first.value?.status == (cut.isLocked ? 423 : 409))
            let second = send(tab, try request("POST", "/api/input", token: tabToken, body: body))
            #expect(await until { second.value != nil })
            if cut.typedSome {
                #expect(second.value?.status == 409 && second.value?.error == PhoneAccess.partlyWent, "\(cut)")
                #expect(attempts.value == 1, "\(cut): not typed again")
            } else {
                #expect(second.value?.status == 423, "\(cut)")
                #expect(attempts.value == 2, "\(cut): nothing went in, so it may go again")
            }
        }
    }

    @Test func anArrowForAMenuInTheWindowWaitsItsTurnAndChecksTheMenuThen() async throws {
        let store = try await store(window: true)
        let (access, token, done) = try serve(store)
        defer { done() }
        let host = useHost(access)
        let sid = try sid(store)
        let shown = try #require(PhoneMenu.read(screen: Self.menuScreen, needsInput: true))
        let fingerprint = PhoneMenu.fingerprint(shown, sid: sid)
        // The screen as read when the arrow's turn comes (with no `hostClient`, `readScreen` reads it as a tab's).
        let screen = Box<String?>(Self.menuScreen)
        access.readTerminalScreen = { _ in screen.value }
        let down = #"{"tty":"\#(Self.tty)","sid":"\#(sid)","key":"down","fingerprint":"\#(fingerprint)"}"#
        let sent = send(access, try request("POST", "/api/input", token: token, body: down))
        #expect(await until { sent.value != nil })
        #expect(sent.value?.status == 200)
        #expect(host.writes == [[27, 91, 66]])
        // Another question is up by then: nothing is sent.
        screen.value = Self.menuScreen.replacingOccurrences(of: "notes.md", with: "secrets.md")
        let stale = send(access, try request("POST", "/api/input", token: token, body: down))
        #expect(await until { stale.value != nil })
        #expect(stale.value?.status == 409)
        #expect(stale.value?.error == PhoneAccess.menuChanged)
        #expect(host.writes == [[27, 91, 66]])
    }

    // MARK: - Arrows meant for a menu

    @Test func anArrowForAMenuIsSentOnlyWhileThatMenuIsUp() async throws {
        let store = try await store()
        let (access, token, done) = try serve(store)
        defer { done() }
        let screen = Box<String?>(Self.menuScreen)
        access.readTerminalScreen = { _ in screen.value }
        let keys = Box<[String]>([])
        access.typeInTerminal = { _, _, _, _, key, _ in
            keys.value.append(key?.rawValue ?? "")
            return nil
        }
        let sid = try sid(store)
        let shown = try #require(PhoneMenu.read(screen: Self.menuScreen, needsInput: true))
        let fingerprint = PhoneMenu.fingerprint(shown, sid: sid)
        let down = #"{"tty":"\#(Self.tty)","sid":"\#(sid)","key":"down","fingerprint":"\#(fingerprint)"}"#
        let sent = send(access, try request("POST", "/api/input", token: token, body: down))
        #expect(await until { sent.value != nil })
        #expect(sent.value?.status == 200)
        #expect(keys.value == ["down"])
        // Another question is up now: nothing is sent.
        screen.value = Self.menuScreen.replacingOccurrences(of: "notes.md", with: "secrets.md")
        let stale = send(access, try request("POST", "/api/input", token: token, body: down))
        #expect(await until { stale.value != nil })
        #expect(stale.value?.status == 409)
        #expect(stale.value?.error == PhoneAccess.menuChanged)
        #expect(keys.value == ["down"])
        // Only arrows carry a fingerprint.
        let bad = send(access, try request("POST", "/api/input", token: token,
                                           body: #"{"tty":"\#(Self.tty)","sid":"\#(sid)","key":"enter","fingerprint":"\#(fingerprint)"}"#))
        #expect(await until { bad.value != nil })
        #expect(bad.value?.status == 400)
        #expect(keys.value == ["down"])
    }

    /// ⏎ on the phone picks what's highlighted when its turn comes, not what the phone last heard: after ↓ the phone's
    /// copy of the cursor is seconds behind, and an index from it moved the cursor back and picked the option the arrow
    /// had just left. Enter goes alone, the phone hears which option it took, and a cursor that moved between the read
    /// and Enter stops it.
    @Test func enterPicksWhatsHighlightedWhenItsTurnComes() async throws {
        let store = try await store()
        let (access, token, done) = try serve(store)
        defer { done() }
        let moved = Self.menuScreen.replacingOccurrences(of: "❯ 1. Yes\n", with: "  1. Yes\n")
            .replacingOccurrences(of: "  2. Yes, allow", with: "❯ 2. Yes, allow")
        let reads = Box<[String?]>([moved, moved])
        access.readTerminalScreen = { _ in
            var left = reads.value
            let next = left.isEmpty ? moved : left.removeFirst()
            reads.value = left
            return next
        }
        let keys = Box<[String]>([])
        access.typeInTerminal = { _, _, _, _, key, _ in
            keys.value.append(key?.rawValue ?? "")
            return nil
        }
        let sid = try sid(store)
        let fingerprint = PhoneMenu.fingerprint(try #require(PhoneMenu.read(screen: moved, needsInput: true)), sid: sid)
        let enter = #"{"tty":"\#(Self.tty)","sid":"\#(sid)","choose":"highlighted","fingerprint":"\#(fingerprint)"}"#
        let answer = send(access, try request("POST", "/api/input", token: token, body: enter))
        #expect(await until { answer.value != nil })
        #expect(answer.value?.status == 200)
        #expect(keys.value == ["enter"], "Enter alone: the cursor is already on the option")
        #expect(answer.value?.json["chose"] as? String == "Yes, allow all edits during this session (shift+tab)")
    }

    @Test func enterStopsWhenTheCursorMovesBeforeItGoes() async throws {
        let store = try await store()
        let (access, token, done) = try serve(store)
        defer { done() }
        let onTwo = Self.menuScreen.replacingOccurrences(of: "❯ 1. Yes\n", with: "  1. Yes\n")
            .replacingOccurrences(of: "  2. Yes, allow", with: "❯ 2. Yes, allow")
        let reads = Box<[String?]>([onTwo, Self.menuScreen])
        access.readTerminalScreen = { _ in
            var left = reads.value
            let next = left.isEmpty ? Self.menuScreen : left.removeFirst()
            reads.value = left
            return next
        }
        let keys = Box<[String]>([])
        access.typeInTerminal = { _, _, _, _, key, _ in
            keys.value.append(key?.rawValue ?? "")
            return nil
        }
        let sid = try sid(store)
        let fingerprint = PhoneMenu.fingerprint(try #require(PhoneMenu.read(screen: onTwo, needsInput: true)), sid: sid)
        let enter = #"{"tty":"\#(Self.tty)","sid":"\#(sid)","choose":"highlighted","fingerprint":"\#(fingerprint)"}"#
        let answer = send(access, try request("POST", "/api/input", token: token, body: enter))
        #expect(await until { answer.value != nil })
        #expect(answer.value?.status == 409)
        #expect(answer.value?.error == PhoneAccess.menuMoved)
        #expect(keys.value.isEmpty, "the cursor moved under it: Enter isn't pressed")
    }

    /// A paused session's menu has no buttons on the phone: the refusal says how to get them, instead of "use its options".
    @Test func aKeyRefusedOnAPausedSessionsMenuSaysResume() async throws {
        let store = try await store()
        store.minimizeOnPause = false
        let (access, token, done) = try serve(store)
        defer { done() }
        access.readTerminalScreen = { _ in Self.menuScreen }
        let typed = Box(0)
        access.typeInTerminal = { _, _, _, _, _, _ in
            typed.value += 1
            return nil
        }
        let session = try #require(store.sessions.first { $0.tty == Self.tty })
        store.pause(session, for: .hours(1))
        defer { store.resume(session) }
        #expect(await until { store.sessions.first { $0.tty == Self.tty }?.pausedUntil != nil })
        let body = #"{"tty":"\#(Self.tty)","sid":"\#(try sid(store))","text":"1","submit":false}"#
        let answer = send(access, try request("POST", "/api/input", token: token, body: body))
        #expect(await until { answer.value != nil })
        #expect(answer.value?.status == 409)
        #expect(answer.value?.error.contains("Tap Resume") == true)
        #expect(typed.value == 0)
    }

    @Test func aRefusalNamesTheWayOutEachSessionHas() throws {
        let start = Date()
        var session = Session(tty: Self.tty, agent: .claude, pid: 1, startedAt: start, cwd: nil, project: "p", task: nil,
                              status: .needsInput, statusSince: start, detail: nil, hasHooks: true, inTerminalApp: true)
        #expect(PhoneAccess.menuOpen(in: session) == PhoneAccess.menuOpen)
        session.pausedUntil = .distantFuture
        #expect(PhoneAccess.menuOpen(in: session).contains("Tap Resume"))
        session.teamRole = .worker
        #expect(PhoneAccess.menuOpen(in: session).contains("Its lead answers it"))
    }

    // MARK: - A menu the phone didn't mean it for

    /// A reply, a digit or a bare Enter reaching a screen with a menu on it: its Enter would pick the highlighted option
    /// (Yes, on a permission prompt) and a digit picks that option. Refused, nothing typed, on both paths; Esc still
    /// goes (it's how you close one), and with no menu up the reply goes as usual. Run from a screen read at its turn:
    /// the phone may have drawn no menu because none was up then.
    @Test(arguments: [false, true]) func aReplyDigitOrEnterIsntTypedIntoAMenuThatIsUp(window: Bool) async throws {
        let store = try await store(window: window)
        let (access, token, done) = try serve(store)
        defer { done() }
        let host = useHost(access)
        let typed = Box<[String]>([])
        access.typeInTerminal = { _, _, text, _, key, _ in
            typed.value.append(text ?? key?.rawValue ?? "")
            return nil
        }
        let screen = Box<String?>(Self.menuScreen)
        access.readTerminalScreen = { _ in screen.value }
        let sid = try sid(store)
        let wentIn = { window ? host.writes.count : typed.value.count }
        let post = { (fields: String) throws -> Box<Answer?> in
            self.send(access, try self.request("POST", "/api/input", token: token, body: #"{"tty":"\#(Self.tty)","sid":"\#(sid)",\#(fields)}"#))
        }
        for fields in [#""text":"no, use the other file","submit":true,"request":"r1""#, #""text":"1","submit":false"#, #""key":"enter""#] {
            let answer = try post(fields)
            #expect(await until { answer.value != nil })
            #expect(answer.value?.status == 409, "\(fields)")
            #expect(answer.value?.error.contains("a question is open") == true, "\(fields)")
            #expect(wentIn() == 0, "\(fields): nothing typed")
        }
        // Nothing went in, so the same reply, once the menu is gone, goes in (it wasn't remembered as typed).
        screen.value = "❯ "
        let reply = try post(#""text":"no, use the other file","submit":true,"request":"r1""#)
        #expect(await until { reply.value != nil })
        #expect(reply.value?.status == 200 && reply.value?.json["duplicate"] == nil)
        let afterReply = wentIn()
        #expect(afterReply > 0)
        // An unreadable screen isn't taken for an empty one.
        screen.value = nil
        let unread = try post(#""text":"and again","submit":true"#)
        #expect(await until { unread.value != nil })
        #expect(unread.value?.status == 503)
        #expect(wentIn() == afterReply)
        // Esc is how a menu is closed: it isn't an answer to it.
        screen.value = Self.menuScreen
        let escape = try post(#""key":"escape""#)
        #expect(await until { escape.value != nil })
        #expect(escape.value?.status == 200)
        #expect(wentIn() == afterReply + 1)
    }

    /// With the cursor on a question's "Type something." row, text is what that row takes: you moved there on purpose.
    /// Not a bare Enter (nothing typed), not a row that isn't the free-text one, and not a multi-select's (Enter would
    /// untick it).
    @Test(arguments: [false, true]) func textGoesIntoAQuestionsFreeTextRowOnlyWithTheCursorOnIt(window: Bool) async throws {
        let store = try await store(window: window)
        let (access, token, done) = try serve(store)
        defer { done() }
        let host = useHost(access)
        let typed = Box<[String]>([])
        access.typeInTerminal = { _, _, text, _, key, _ in
            typed.value.append(text ?? key?.rawValue ?? "")
            return nil
        }
        let onField = """
        Which database?
          1. Postgres
          2. SQLite
        ❯ 3. Type something.
          4. Chat about this
        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        let screen = Box<String?>(onField)
        access.readTerminalScreen = { _ in screen.value }
        let sid = try sid(store)
        let wentIn = { window ? host.writes.count : typed.value.count }
        let post = { (fields: String) throws -> Box<Answer?> in
            self.send(access, try self.request("POST", "/api/input", token: token, body: #"{"tty":"\#(Self.tty)","sid":"\#(sid)",\#(fields)}"#))
        }
        let answer = try post(#""text":"MariaDB, it's what we run","submit":true"#)
        #expect(await until { answer.value != nil })
        #expect(answer.value?.status == 200)
        let afterAnswer = wentIn()
        #expect(afterAnswer > 0)
        let enter = try post(#""key":"enter""#)
        #expect(await until { enter.value != nil })
        #expect(enter.value?.status == 409)
        #expect(wentIn() == afterAnswer)
        // The same question with the cursor on another row, and a multi-select's field.
        let onOption = onField.replacingOccurrences(of: "❯ 3.", with: "  3.").replacingOccurrences(of: "  1. Postgres", with: "❯ 1. Postgres")
        let multi = """
        Which toppings?
          1. [ ] Cream
          2. [ ] Nuts
        ❯ 3. [ ] Type something.
          Submit
        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        for other in [onOption, multi] {
            screen.value = other
            let refused = try post(#""text":"MariaDB","submit":true"#)
            #expect(await until { refused.value != nil })
            #expect(refused.value?.status == 409, "\(other)")
            #expect(wentIn() == afterAnswer, "\(other)")
        }
    }

    // MARK: - A restart keeps the pairing

    @Test func aRestartMidRequestAnswers503AndKeepsThePairing() async throws {
        let store = try await store()
        // Another phone paired first, as one in the devices file the access loads may be (~/.vibeswitcher/remote, the
        // same for every suite in the run: another one pairs its own beside this one).
        var other = ""
        let (access, token, done) = try serve(store) { other = try pair($0, name: "Another phone") }
        defer {
            done()
            #expect(access.devices.contains { $0.tokenHash == RemoteAuth.hash(other) }, "serve's cleanup removed another phone")
            unpair(access, token: other)
        }
        // The read goes on until the test lets it end (off the main thread, on the reads queue).
        let reading = Box(false)
        let release = DispatchSemaphore(value: 0)
        access.readTerminalScreen = { _ in
            reading.value = true
            release.wait()
            return Self.menuScreen
        }
        let answer = send(access, try request("GET", "/api/screen?tty=\(Self.tty)", token: token))
        #expect(await until { reading.value })
        // Two failed health checks restart it while the read goes on.
        access.restartForTests()
        release.signal()
        #expect(await until { answer.value != nil })
        #expect(answer.value?.status == 503)
        #expect(answer.value?.error.contains("restarting") == true)
        // While it's starting, a new request hears the same.
        let meanwhile = send(access, try request("GET", "/api/state", token: token))
        #expect(meanwhile.value?.status == 503)
        // Back on: the phone's token still works.
        access.serveForTests(.init(dnsName: Self.host, login: Self.login, httpsAvailable: true))
        let state = send(access, try request("GET", "/api/state", token: token))
        #expect(await until { state.value != nil })
        #expect(state.value?.status == 200)
        // A removed phone, though, hears 401 (and forgets its token); the other one is still paired.
        access.remove(try #require(access.devices.first { $0.tokenHash == RemoteAuth.hash(token) }))
        let removed = send(access, try request("GET", "/api/state", token: token))
        #expect(removed.value?.status == 401)
        #expect(removed.value?.error == PhoneAccess.unpaired)
        #expect(send(access, try request("GET", "/api/state", token: other)).value?.status == 200)
    }

    // MARK: - The server's cut

    /// The server gives a client 15 s (here 0.3 s) to send its request, not to have it answered: an answer that takes
    /// longer (a reply typed behind a jump) still reaches the phone instead of Tailscale's bare 502. A real listener on
    /// a loopback port; nothing else is served.
    @Test func aSlowAnswerIsntCutByTheReceiveTimeout() async throws {
        let server = RemoteServer { _, respond in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { respond(.json(["ok": true])) }
        }
        server.receiveLimit = 0.3
        let port = UInt16.random(in: 47_000...48_999)
        let ready = Box<Bool?>(nil)
        server.start(port: port, onReady: { ready.value = true }, onFailure: { _ in ready.value = false })
        defer { server.stop() }
        #expect(await until { ready.value != nil })
        try #require(ready.value == true)
        let received = Box<String?>(nil)
        DispatchQueue.global().async {
            received.value = Self.exchange(port: port, request: "POST /api/input HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}")
        }
        #expect(await until(timeout: 10) { received.value != nil })
        #expect(received.value?.hasPrefix("HTTP/1.1 200") == true, "got \(received.value ?? "nothing")")

        // A request that never finishes arriving is still cut at the receive limit.
        let hung = Box<String?>(nil)
        DispatchQueue.global().async {
            hung.value = Self.exchange(port: port, request: "POST /api/input HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n{")
        }
        #expect(await until(timeout: 10) { hung.value != nil })
        #expect(hung.value == "")
    }

    /// Writes `request` to 127.0.0.1:`port` and reads until the server closes (at most 5 s): what came back.
    nonisolated static func exchange(port: UInt16, request: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "no socket" }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return "no connection" }
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
