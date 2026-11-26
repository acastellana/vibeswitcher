import Darwin
import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// A process of your own account can't make itself a paired phone: it can write the devices file Phone Access reads
/// (~/.vibeswitcher/remote/devices.json is yours) and connect to the phone port on loopback with any
/// `Tailscale-User-Login` header it likes, but a device record the app didn't write itself isn't believed, so its
/// token types nothing and answers no lead's question. Security review 2026-11-26.
///
/// The real start path against a fake `tailscale` (`FakeTailscale`), on a loopback port of its own, with defaults and
/// files in scratch; the session is a made-up one and the Terminal typer and the lead's answer path are stand-ins that
/// count: nothing is typed into any terminal and no lead runs.
extension TailscaleFakeTests { @MainActor @Suite(.serialized) struct PhoneDevicesTrustTests {
    nonisolated static let tty = "ttys984"
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

    /// A loopback port nothing holds right now, below the range the system hands out for port 0 (as
    /// PhoneTailscaleFlowTests picks its own).
    private func freePort() throws -> UInt16 {
        for _ in 0..<100 {
            let port = UInt16.random(in: 40_000..<49_000)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            let length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
            }
            if bound == 0 { return port }
        }
        throw CancellationError()
    }

    /// A store with one Claude session in a Terminal tab on `tty`, waiting on input.
    private func store() async throws -> SessionStore {
        AppStatus.enabled = false
        let stateDir = scratch.url("phone-trust-state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let start = Date().addingTimeInterval(-600)
        let table = [ProcInfo(pid: 730, ppid: 1, tty: nil, comm: "Terminal", startTime: start, agent: nil),
                     ProcInfo(pid: 860, ppid: 730, tty: Self.tty, comm: "login", startTime: start, agent: nil),
                     ProcInfo(pid: 861, ppid: 860, tty: Self.tty, comm: "zsh", startTime: start, agent: nil),
                     ProcInfo(pid: 862, ppid: 861, tty: Self.tty, comm: "claude", startTime: start, agent: .claude)]
        var hook = HookState(agent: .claude, tty: Self.tty, lastEvent: "Notification",
                             lastEventAt: Date().addingTimeInterval(-30).timeIntervalSince1970)
        hook.agentPid = 862
        try hook.save(to: stateDir.appendingPathComponent("\(Self.tty).json"))
        let tabs = [Self.tty: TerminalTab(windowID: 1, title: "✳ Edit notes", position: nil, isSelected: true, windowOrder: 1)]
        let bridge = TerminalPoll<TerminalTab>.Bridge(tabs: { .tabs(tabs) }, screens: { _ in [:] })
        let store = SessionStore(scanner: SessionScanner(processes: { Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0) }) },
                                                         stateDir: { stateDir }, cwd: { _ in stateDir.path },
                                                         arguments: { _ in [] }),
                                 bridge: bridge)
        store.terminalFront = { (false, nil) }
        let before = store.scansApplied
        store.refresh()
        #expect(await until { store.scansApplied > before && store.sessions.contains { $0.tty == Self.tty } })
        return store
    }

    /// What the stand-ins were asked to do: text typed into a tty, answers given to a lead.
    final class Acted: @unchecked Sendable {
        let typed = Box<[String]>([])
        let answered = Box<[String]>([])
    }

    /// Phone Access as the app runs it (`enabled`, the real listener on a scratch port, a fake `tailscale serve`), over
    /// `devicesFile`, with replies on, the Mac unlocked and one lead with an open question: everything a planted phone
    /// needs to act, so only the device check stands in its way.
    private func running(_ store: SessionStore, devicesFile: URL, fake: FakeTailscale, acted: Acted,
                         question: LeadQuestion, root: String) async throws -> PhoneAccess {
        let defaults = scratch.defaults("phone-trust")
        defaults.set(true, forKey: "phoneInputAllowed")
        let access = PhoneAccess(store: store, defaults: defaults, devicesFile: devicesFile)
        access.listenPort = try freePort()
        access.screenLocked = { false }
        access.agentRunning = { _, _, _ in true }
        access.readTerminalScreen = { _ in "" }
        access.typeInTerminal = { _, _, text, _, _, _ in
            acted.typed.value.append(text ?? "")
            return nil
        }
        access.sendToWindow = { _, _, _, confirmed in confirmed(false) }
        var board = LeadBoard()
        board.questions = [question]
        access.leads = { [PhoneLeads.Lead(root: root, board: board, summary: nil, rows: [])] }
        access.answerLead = { _, _, _, text, done in
            acted.answered.value.append(text)
            done(.missing, nil)
        }
        fake.onServe(leaves: FakeTailscale.proxy("http://127.0.0.1:\(access.listenPort)"))
        access.enabled = true
        #expect(await until { access.state == .on })
        return access
    }

    private func finish(_ access: PhoneAccess, _ fake: FakeTailscale) async {
        access.enabled = false
        _ = await until { fake.ran("serve --https=8443 off") || !fake.ran("serve --bg") }
        fake.uninstall()
    }

    /// One request as a local process sends it: straight to the loopback port, with the owner's login header and the
    /// Mac's tailnet name typed in. The status line's code, and the body.
    nonisolated static func post(port: UInt16, path: String, token: String, body: String) throws -> (status: Int, body: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CancellationError() }
        defer { close(fd) }
        // A hang guard, not a timing: the server answers or closes long before.
        var limit = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let connected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw CancellationError() }
        var head = "POST \(path) HTTP/1.1\r\nHost: \(FakeTailscale.host):\(PhoneAccess.httpsPort)\r\n"
        head += "Tailscale-User-Login: \(FakeTailscale.login)\r\nAuthorization: Bearer \(token)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = Array(head.utf8)
        var sent = 0
        while sent < request.count {
            let n = request[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw CancellationError() }
            sent += n
        }
        var response = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            response += chunk[0..<n]
        }
        let text = String(decoding: response, as: UTF8.self)
        let status = text.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) } ?? -1
        let bodyText = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
        return (status, bodyText)
    }

    /// The reported route, end to end: a record with a token of the process's own, written into the devices file as
    /// the app writes it (plain JSON), then (the app started as at login) `POST /api/input` and `/api/lead/answer` with
    /// that token, on loopback, under the owner's login header. Neither acts: the record isn't one the app wrote.
    @Test func aDeviceRecordPlantedInTheDevicesFileDoesNotAct() async throws {
        let fake = try FakeTailscale(scratch: scratch)
        let store = try await store()
        let file = scratch.adopt(scratch.url("devices").appendingPathExtension("json"))
        let token = RemoteAuth.newToken()
        let planted = PairedDevice(id: "planted", name: "Planted", tokenHash: RemoteAuth.hash(token),
                                   tailscaleLogin: FakeTailscale.login, pairedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([planted]).write(to: file)
        let acted = Acted()
        let question = LeadQuestion(text: "Ship to the testers first?", options: ["Testers first", "Everyone"])
        let root = scratch.url("phone-trust-lead").path
        let access = try await running(store, devicesFile: file, fake: fake, acted: acted, question: question, root: root)
        let port = access.listenPort
        let sid = try #require(store.sessions.first { $0.tty == Self.tty }).identity

        let input = #"{"tty":"\#(Self.tty)","sid":"\#(sid)","text":"rm -rf build","submit":true}"#
        let typed = try await offPool { try Self.post(port: port, path: "/api/input", token: token, body: input) }
        let answer = #"{"lead":"\#(PhoneLeads.id(root: root))","question":"\#(question.id)","version":1,"text":"Everyone"}"#
        let answered = try await offPool { try Self.post(port: port, path: "/api/lead/answer", token: token, body: answer) }

        #expect(typed.status == 401, "\(typed)")
        #expect(answered.status == 401, "\(answered)")
        #expect(acted.typed.value.isEmpty, "the planted phone typed \(acted.typed.value)")
        #expect(acted.answered.value.isEmpty, "the planted phone answered \(acted.answered.value)")
        #expect(!access.devices.contains { $0.id == "planted" })
        await finish(access, fake)
    }
} }
