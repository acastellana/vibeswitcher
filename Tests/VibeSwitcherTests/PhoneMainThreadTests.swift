import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The phone's reads of a Terminal tab never wait on the main thread: the screen route and a tap on a menu's option
/// read the screen off it (`PhoneAccess.readTerminalScreen`), and go to the main thread only for the store's state.
/// A stand-in read that takes 2 s stands for a slow or hung Terminal: it never runs on the main thread, and main-queue
/// blocks timed during it run on time (< 0.1 s late; tried again when other tests held the main thread all through).
/// Phone Access is served in memory only (`serveForTests`), the session comes from a made-up process table and tab,
/// and the tap is for a menu that has changed, so nothing is typed anywhere.
@MainActor
@Suite(.serialized)
struct PhoneMainThreadTests {
    nonisolated static let host = "mac.tail1234.ts.net"
    nonisolated static let login = "me@example.com"
    nonisolated static let tty = "ttys982"
    nonisolated static let readTime: TimeInterval = 2
    nonisolated static let menuScreen = """
    Do you want to make this edit to notes.md?
    ❯ 1. Yes
      2. Yes, allow all edits during this session (shift+tab)
      3. No, and tell Claude what to do differently (esc)
    """

    /// The hook's state folder, under scratchRoot and removed with `scratch` (also the session's made-up folder).
    private let scratch = Scratch()
    private let stateDir: URL

    init() { stateDir = scratch.url("phone-main-thread") }

    private final class Box<Value>: @unchecked Sendable {
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
    }

    /// A store holding one Claude session in a Terminal tab (`tty`), waiting on you.
    private func storeWithATerminalSession() async throws -> SessionStore {
        AppStatus.enabled = false
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let start = Date().addingTimeInterval(-600)
        let proc = { (pid: Int32, ppid: Int32, comm: String, tty: String?, agent: Agent?) in
            ProcInfo(pid: pid, ppid: ppid, tty: tty, comm: comm, startTime: start, agent: agent)
        }
        let table = [proc(730, 1, "Terminal", nil, nil), proc(860, 730, "login", Self.tty, nil),
                     proc(861, 860, "zsh", Self.tty, nil), proc(862, 861, "claude", Self.tty, .claude)]
        var hook = HookState(agent: .claude, tty: Self.tty, lastEvent: "Notification",
                             lastEventAt: Date().addingTimeInterval(-30).timeIntervalSince1970)
        hook.agentPid = 862
        try hook.save(to: stateDir.appendingPathComponent("\(Self.tty).json"))
        let bridge = TerminalPoll<TerminalTab>.Bridge(tabs: {
            .tabs([Self.tty: TerminalTab(windowID: 1, title: "✳ Edit notes", position: nil, isSelected: true, windowOrder: 1)])
        }, screens: { _ in [:] })
        let dir = stateDir
        let store = SessionStore(scanner: SessionScanner(processes: { Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0) }) },
                                                         stateDir: { dir }, cwd: { _ in dir.path },
                                                         arguments: { _ in [] }),
                                 bridge: bridge)
        store.terminalFront = { (false, nil) }
        let before = store.scansApplied
        store.refresh()
        #expect(await until { store.scansApplied > before })
        let session = try #require(store.sessions.first { $0.tty == Self.tty })
        #expect(session.inTerminalApp && !session.inWindow)
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

    private func pair(_ access: PhoneAccess) throws -> String {
        access.startPairing()
        let code = try #require(access.pairing?.code)
        var answer: Answer?
        access.handleForTests(try request("POST", "/api/pair", body: #"{"code":"\#(code)","name":"Test phone"}"#)) {
            answer = Answer(status: $0.status, body: $0.body)
        }
        return try #require(answer?.json["token"] as? String)
    }

    /// What the main thread did while a stand-in Terminal read of `readTime` went on.
    struct Waited {
        var answer: Answer
        /// Whether any read ran on the main thread.
        var readOnMain: Bool
        /// How late each main-queue block due while the read went on (and not in its last 0.15 s) ran.
        var lateness: [TimeInterval]
    }

    /// Sends `request` with the Terminal read replaced by one that takes `readTime`; main-queue blocks are timed every
    /// 0.1 s from just before it goes out.
    ///
    /// Each block due during the read is noted with how late it ran. A read done on the main thread, or one the main
    /// thread waits for, holds every one of them until the read is over: at least 0.15 s late, as the read's last
    /// 0.15 s aren't counted. Off the main thread they run on time, unless other tests running at once (the suite is
    /// parallel) keep the main thread busy, and that can't hold all of them.
    private func whileReading(_ access: PhoneAccess, _ request: HTTPRequest) async throws -> Waited {
        let started = Box<Date?>(nil), finished = Box<Date?>(nil), onMain = Box(false)
        access.readTerminalScreen = { tty in
            if Thread.isMainThread { onMain.value = true }
            started.value = Date()
            Thread.sleep(forTimeInterval: Self.readTime)
            finished.value = Date()
            return tty == Self.tty ? Self.menuScreen : nil
        }
        var answer: Answer?
        // Timed before the request goes out: a read done on the main thread would hold them all until it's over.
        var ran: [(due: Date, at: Date)] = []
        let origin = Date(), steps = Int(Self.readTime * 10)
        for step in 1...steps {
            let delay = 0.1 * Double(step)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { ran.append((origin + delay, Date())) }
        }
        access.handleForTests(request) { answer = Answer(status: $0.status, body: $0.body) }
        #expect(await until(timeout: 15) { answer != nil && ran.count == steps })
        let start = try #require(started.value), end = try #require(finished.value)
        #expect(end.timeIntervalSince(start) >= Self.readTime - 0.05)
        // Only the blocks due while the read went on count (a read that ended early would prove nothing): most are.
        let during = ran.filter { $0.due > start && $0.due < end - 0.15 }
        #expect(during.count >= steps / 2, "only \(during.count) blocks were due during the read")
        return Waited(answer: try #require(answer), readOnMain: onMain.value,
                      lateness: during.map { $0.at.timeIntervalSince($0.due) })
    }

    /// `whileReading`, up to `attempts` times until a main-queue block due during the read ran on time (< 0.1 s late).
    /// Other tests running at once can keep the main thread busy for seconds, through a whole read; a read on the main
    /// thread, or one it waits for, makes every attempt late. Each attempt's answer goes to `check`, and no read may
    /// run on the main thread in any of them.
    private func mainStaysFree(_ access: PhoneAccess, attempts: Int = 4, pause: TimeInterval = 0,
                               _ request: () throws -> HTTPRequest, check: (Answer) -> Void) async throws {
        var seen: [[TimeInterval]] = []
        for attempt in 1...attempts {
            if attempt > 1 { try await Task.sleep(nanoseconds: UInt64(pause * 1e9)) }
            let waited = try await whileReading(access, try request())
            check(waited.answer)
            #expect(!waited.readOnMain)
            seen.append(waited.lateness)
            if waited.lateness.contains(where: { $0 < 0.1 }) { return }
        }
        Issue.record("main-queue blocks ran late through every read: \(seen)")
    }

    @Test func theScreenRouteReadsATerminalTabOffTheMainThread() async throws {
        let store = try await storeWithATerminalSession()
        let access = PhoneAccess(store: store)
        access.serveForTests(.init(dnsName: Self.host, login: Self.login, httpsAvailable: true))
        let token = try pair(access)
        defer { access.remove(access.devices[0]) }

        // Apart, so each read isn't answered from the screen kept for 0.8 s.
        try await mainStaysFree(access, pause: 1, { try request("GET", "/api/screen?tty=\(Self.tty)", token: token) }) { answer in
            #expect(answer.status == 200)
            #expect((answer.json["text"] as? String)?.contains("Do you want to make this edit") == true)
        }
    }

    @Test func aTapOnAMenuReadsATerminalTabOffTheMainThread() async throws {
        let store = try await storeWithATerminalSession()
        let access = PhoneAccess(store: store)
        access.serveForTests(.init(dnsName: Self.host, login: Self.login, httpsAvailable: true))
        let token = try pair(access)
        let wasAllowed = access.inputAllowed
        access.inputAllowed = true
        defer {
            access.inputAllowed = wasAllowed
            access.remove(access.devices[0])
        }
        let sid = try #require(store.sessions.first { $0.tty == Self.tty }).identity

        // A tap on a menu the phone drew earlier, now gone from the screen: refused once read, nothing typed.
        let body = #"{"tty":"\#(Self.tty)","sid":"\#(sid)","choose":1,"fingerprint":"an-older-menu"}"#
        try await mainStaysFree(access, { try request("POST", "/api/input", token: token, body: body) }) { answer in
            #expect(answer.status == 409)
            #expect(String(decoding: answer.body, as: UTF8.self).contains(PhoneAccess.menuChanged))
        }
    }
}

/// No `DispatchQueue.main.sync` on the phone's paths wraps a Terminal read, a host call or a process: the main thread
/// is asked synchronously only for the store's state, each such hop listed here with why. A new one fails until it's
/// added; one that reads a screen, types or runs anything fails whatever the list says.
struct PhoneMainSyncLintTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/VibeSwitcher")
    /// The phone's read and input paths.
    static let files = ["PhoneAccess.swift", "RemoteInput.swift", "RemoteServer.swift"]

    /// Each allowed hop, by what its block says, how many there are, and why.
    static let allowed: [(body: String, count: Int, why: String)] = [
        ("self.state == .on && self.inputAllowed", 2,
         "a Terminal reply's or tap's stillAllowed, before each key: replies on, the phone paired, the tty the same session (the store's state, nothing read)"),
        ("decide(raw)", 1, "a tap decided against the store and noted (menus, answered), the screen already read off the main thread"),
    ]

    /// What a main-thread hop may never wrap: reading a screen, the session host, typing, running something, waiting.
    static let forbidden = ["TerminalBridge", "readTerminalScreen", "readTab", "hostClient", "RemoteInput.send", "Process(",
                            "osascript", "AppleScript", "screens(", "history(", "usleep", "sleep(", ".wait("]

    /// The block of each `DispatchQueue.main.sync` in `text` (comments left out), braces balanced.
    static func mainSyncBlocks(in text: String) -> [String] {
        let code = text.components(separatedBy: "\n").map { $0.components(separatedBy: "//").first ?? $0 }.joined(separator: "\n")
        var blocks: [String] = []
        var rest = code[...]
        while let hop = rest.range(of: "DispatchQueue.main.sync") {
            guard let open = rest[hop.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0, end = open
            for index in rest[open...].indices {
                if rest[index] == "{" { depth += 1 } else if rest[index] == "}" { depth -= 1 }
                if depth == 0 { end = index; break }
            }
            blocks.append(String(rest[open...end]))
            rest = rest[rest.index(after: end)...]
        }
        return blocks
    }

    @Test func noMainSyncOnThePhonesPathsWrapsARead() throws {
        var blocks: [String] = []
        for file in Self.files {
            let url = Self.sources.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            blocks += Self.mainSyncBlocks(in: try String(contentsOf: url, encoding: .utf8))
        }
        for block in blocks {
            let wrapped = Self.forbidden.filter(block.contains)
            #expect(wrapped.isEmpty, "a main.sync wraps \(wrapped): \(block)")
        }
        for entry in Self.allowed {
            #expect(blocks.filter { $0.contains(entry.body) }.count == entry.count, "\(entry.body): \(entry.why)")
        }
        let unlisted = blocks.filter { block in !Self.allowed.contains { block.contains($0.body) } }
        #expect(unlisted.isEmpty, "main.sync not on the list (add it with why, or make it async): \(unlisted)")
    }

    @Test func theLintFindsTheReadThatHeldTheWindow() {
        // The tap's old read, inside the hop: caught.
        let old = """
            let tap = DispatchQueue.main.sync { decide(TerminalBridge.screens(for: [tty])[tty]) }
            let ok = DispatchQueue.main.sync {
                self.state == .on // a comment's { brace
            }
            """
        let blocks = Self.mainSyncBlocks(in: old)
        #expect(blocks.count == 2)
        #expect(Self.forbidden.contains(where: blocks[0].contains))
        #expect(!Self.forbidden.contains(where: blocks[1].contains))
    }
}
