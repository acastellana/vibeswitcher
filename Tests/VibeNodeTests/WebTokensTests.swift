import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The web page's pairing codes and tokens (the live plan's F1, LW-D4; the live wire contract's §2): a code of 16 random
/// bytes, 120 s, taken once, in the address's fragment; a token of 32 random bytes whose SHA-256 alone is at rest, in a
/// 0600 file in the 0700 folder, 24 h, at most 8; revoking closes the pages; `web.open` and `web.revoke` are the user's
/// voice. Every root is a scratch folder; every clock is the test's.
@Suite(.timeLimit(.minutes(5)))
struct WebTokensTests {
    private let scratch = Scratch()
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A clock the test sets.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var at = WebTokensTests.start
        var now: Date { lock.withLock { at } }
        func advance(_ seconds: TimeInterval) { lock.withLock { at = at.addingTimeInterval(seconds) } }
    }

    private func access(root: URL? = nil, clock: Clock = Clock(), note: @escaping @Sendable (String) -> Void = { _ in }) -> (WebAccess, Clock, URL) {
        let root = root ?? scratch.url("web-root")
        return (WebAccess(tokens: WebTokens(root: root), now: { clock.now }, note: note), clock, root)
    }

    private func tokensFile(_ root: URL) -> URL { root.appendingPathComponent("v2/web-tokens.json") }

    private static func mode(_ path: String) -> mode_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o7777 : 0
    }

    // MARK: Codes

    /// Each code and token is fresh randomness of its size, in base64url: 16 bytes (22 characters) and 32 (43).
    @Test func aCodeAndATokenAreFreshRandomBytes() throws {
        let (access, clock, _) = access()
        var codes = Set<String>(), tokens = Set<String>()
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for _ in 0..<50 {
            let code = access.openCode(now: clock.now)
            #expect(code.count == 22 && code.allSatisfy(alphabet.contains), "\(code)")
            codes.insert(code)
            let token = try access.tokens.issue(now: clock.now).token
            #expect(token.count == 43 && token.allSatisfy(alphabet.contains), "\(token)")
            tokens.insert(token)
        }
        #expect(codes.count == 50 && tokens.count == 50)
        let standard = try #require(codes.first).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        #expect(Data(base64Encoded: standard + "==")?.count == 16)
    }

    @Test func aCodeIsTakenOnce() throws {
        let (access, clock, _) = access()
        let code = access.openCode(now: clock.now)
        let admitted = try #require(access.admit(["pair": .string(code), "client": .string("webapp")]))
        #expect(admitted.rights == [.read, .draft])
        #expect(admitted.auth["token"]?.string == admitted.token)
        #expect(access.tokens.check(admitted.token, now: clock.now))
        #expect(access.admit(["pair": .string(code)]) == nil)
        // Another code is untouched by the first's use.
        let other = access.openCode(now: clock.now)
        #expect(access.admit(["pair": .string(other)]) != nil)
    }

    @Test func aLateCodeIsRefused() throws {
        let (access, clock, _) = access()
        let inTime = access.openCode(now: clock.now)
        let late = access.openCode(now: clock.now)
        clock.advance(WebAccess.codeLife - 0.1)
        #expect(access.admit(["pair": .string(inTime)]) != nil, "a code inside its 120 s")
        clock.advance(0.1)
        #expect(access.admit(["pair": .string(late)]) == nil, "a code at its 120 s")
        #expect(access.wanted == true, "the token issued keeps the listener wanted")
    }

    /// A wrong, a used and a late code, a token that isn't one, both at once, neither: each refused alike, nil, with
    /// the same one note, which names neither code nor token.
    @Test func theRefusalDoesntSayWhy() throws {
        let notes = Locked<[String]>([])
        let (access, clock, _) = access(note: { line in notes.mutate { $0.append(line) } })
        let used = access.openCode(now: clock.now)
        _ = try #require(access.admit(["pair": .string(used)]))
        let late = access.openCode(now: clock.now)
        let token = try access.tokens.issue(now: clock.now).token
        clock.advance(WebAccess.codeLife)
        notes.value = []
        let refusals: [[String: NodeWire.Value]] = [
            ["pair": .string(WebTokens.randomText(bytes: 16))], ["pair": .string(used)], ["pair": .string(late)],
            ["token": .string(WebTokens.randomText(bytes: 32))], ["pair": .string(used), "token": .string(token)], [:],
            ["pair": .int(1)], ["token": .string(String(repeating: "A", count: 100_000))],
        ]
        for args in refusals {
            #expect(access.admit(args) == nil, "\(args.keys.sorted())")
        }
        #expect(Set(notes.value).count == 1 && notes.value.count == refusals.count, "\(notes.value)")
        #expect(!notes.value.contains { $0.contains(used) || $0.contains(late) || $0.contains(token) })
    }

    @Test func theUrlCarriesTheCodeInItsFragment() throws {
        let (access, _, _) = access()
        access.listen = { .success(41234) }
        let opened = try access.open().get()
        let parts = try #require(URLComponents(string: opened.url))
        #expect(parts.scheme == "http" && parts.host == "127.0.0.1" && parts.port == 41234, "\(opened.url)")
        #expect(parts.path == "/" && parts.query == nil && parts.user == nil, "\(opened.url)")
        let fragment = try #require(parts.fragment)
        #expect(fragment.hasPrefix("pair="), "\(opened.url)")
        #expect(opened.expiresIn == 120)
        // What the fragment holds is the code the page sends.
        #expect(access.admit(["pair": .string(String(fragment.dropFirst("pair=".count)))]) != nil)
    }

    /// A port that can't be had refuses `web.open` with the listener's reason, and makes no code.
    @Test func aPortThatCantBeHadMakesNoCode() throws {
        let (access, _, _) = access()
        access.listen = { .failure(WebTokens.Refusal("127.0.0.1:47830 is taken by pid 4242")) }
        guard case .failure(let refusal) = access.open() else { Issue.record("opened"); return }
        #expect(refusal.description.contains("taken by pid 4242"))
        #expect(access.wanted == false)
    }

    // MARK: Tokens at rest

    @Test func onlyTheHashIsAtRest() throws {
        let (access, clock, root) = access()
        let code = access.openCode(now: clock.now)
        let token = try #require(access.admit(["pair": .string(code)])).token
        let text = try String(contentsOf: tokensFile(root), encoding: .utf8)
        #expect(!text.contains(token) && !text.contains(code), "\(text)")
        let file = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(file["format"] as? Int == 1)
        let entries = try #require(file["tokens"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["sha256"] as? String == WebTokens.hex(Array(SHA256.hash(data: Data(token.utf8)))))
        // Nothing in the whole folder holds the token.
        for name in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("v2").path) {
            let data = try Data(contentsOf: root.appendingPathComponent("v2/" + name))
            #expect(data.range(of: Data(token.utf8)) == nil, "\(name)")
        }
    }

    /// 0600 in a 0700 folder, even where an older folder or file was wider.
    @Test func theTokensFileIsOwnerOnly() throws {
        let root = scratch.url("web-root")
        let (fresh, clock, _) = access(root: root)
        _ = try fresh.tokens.issue(now: clock.now)
        #expect(Self.mode(tokensFile(root).path) == 0o600)
        #expect(Self.mode(root.appendingPathComponent("v2").path) == 0o700)
        chmod(root.appendingPathComponent("v2").path, 0o755)
        chmod(tokensFile(root).path, 0o644)
        let (again, _, _) = access(root: root, clock: clock)
        _ = try again.tokens.issue(now: clock.now)
        #expect(Self.mode(tokensFile(root).path) == 0o600)
        #expect(Self.mode(root.appendingPathComponent("v2").path) == 0o700)
    }

    @Test func aTokenRunsOut() throws {
        let (access, clock, _) = access()
        let code = access.openCode(now: clock.now)
        let admitted = try #require(access.admit(["pair": .string(code)]))
        #expect(admitted.auth["expiresAt"]?.string == NodeWire.dateText(WebTokensTests.start.addingTimeInterval(24 * 3600)))
        clock.advance(24 * 3600 - 1)
        #expect(access.admit(["token": .string(admitted.token)])?.auth["token"] == nil, "a reconnect isn't sent its token again")
        #expect(access.holds(admitted.token))
        clock.advance(1)
        #expect(access.admit(["token": .string(admitted.token)]) == nil)
        #expect(!access.holds(admitted.token))
        #expect(access.wanted == false, "nothing alive: the listener closes")
    }

    @Test func theNinthTokenDropsTheOldest() throws {
        let (access, clock, root) = access()
        var tokens: [String] = []
        for _ in 0..<9 {
            tokens.append(try access.tokens.issue(now: clock.now).token)
            clock.advance(1)
        }
        #expect(!access.tokens.check(tokens[0], now: clock.now))
        for token in tokens.dropFirst() { #expect(access.tokens.check(token, now: clock.now)) }
        #expect(access.tokens.live(now: clock.now) == 8)
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: tokensFile(root))) as? [String: Any]
        #expect((file?["tokens"] as? [Any])?.count == 8)
    }

    /// A page reconnects after the server restarts: the token's hash was at rest, and a new server's tokens read it.
    @Test func aTokenIsTakenAfterTheServerRestarts() throws {
        let (before, clock, root) = access()
        let code = before.openCode(now: clock.now)
        let token = try #require(before.admit(["pair": .string(code)])).token
        let (after, _, _) = access(root: root, clock: clock)
        #expect(after.wanted, "the restarted server binds the web again: a token is alive")
        let admitted = try #require(after.admit(["token": .string(token)]))
        #expect(admitted.rights == [.read, .draft] && admitted.token == token)
        // A code doesn't survive: it was memory only.
        #expect(after.admit(["pair": .string(code)]) == nil)
    }

    /// A newer build's file: no token taken from it, nothing issued or revoked over it, and the file left whole.
    @Test func aNewerTokensFormatIsRefused() throws {
        let root = scratch.url("web-root")
        let token = WebTokens.randomText(bytes: 32)
        try VibePaths.ensurePrivate(root.appendingPathComponent("v2"))
        let newer = Data(#"{"format":2,"tokens":[{"sha256":"\#(WebTokens.hex(WebTokens.digest(token)))","issuedAt":"2027-01-15T08:00:00.000Z","expiresAt":"2099-01-01T00:00:00.000Z"}]}"#.utf8)
        try VibePaths.writePrivate(newer, to: tokensFile(root))
        let (access, clock, _) = access(root: root)
        #expect(access.admit(["token": .string(token)]) == nil)
        #expect(throws: WebTokens.Refusal.self) { _ = try access.tokens.issue(now: clock.now) }
        access.listen = { .success(41234) }
        guard case .failure(let refusal) = access.open() else { Issue.record("opened over a newer file"); return }
        #expect(refusal.description.contains("format 2"))
        guard case .failure = access.revoke() else { Issue.record("revoked over a newer file"); return }
        #expect(try Data(contentsOf: tokensFile(root)) == newer)
    }

    @Test func aTokensFileThatCantBeReadIsNoTokens() throws {
        for garbage in ["not json", "{\"format\":1,\"tokens\":[{\"sha256\":12}]}", "[]", ""] {
            let root = scratch.url("web-root")
            try VibePaths.ensurePrivate(root.appendingPathComponent("v2"))
            try VibePaths.writePrivate(Data(garbage.utf8), to: tokensFile(root))
            let (access, clock, _) = access(root: root)
            #expect(access.tokens.live(now: clock.now) == 0, "\(garbage)")
            #expect(access.wanted == false, "\(garbage)")
            // The next issue writes a fresh file.
            let token = try access.tokens.issue(now: clock.now).token
            #expect(WebTokens(root: root).check(token, now: clock.now), "\(garbage)")
        }
    }

    // MARK: Revocation

    /// `web.revoke` drops every token and code, and each page's connection gets `bye` (`revoked`) and 4403; a page
    /// that comes back with its token is refused.
    @Test func revokingClosesTheConnections() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        rig.access.onRevoke = { [listener = rig.listener] in listener.closeAll(code: "revoked", reason: "every web token was dropped") }
        let pending = rig.access.openCode(now: rig.now)
        var pages: [(RawClient, String)] = []
        for _ in 0..<2 {
            let code = rig.access.openCode(now: rig.now)
            let page = try rig.upgraded()
            try page.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"pair":"\#(code)"}}"#)
            pages.append((page, try #require(try page.nextFrame()?.json?["auth"]?["token"]?.string)))
        }
        #expect(try rig.access.revoke().get() == 2)
        for (page, _) in pages {
            let frames = try page.framesUntilClosed()
            #expect(frames.first?.json?["code"]?.string == "revoked", "\(frames)")
            #expect(frames.last?.closeCode == 4403, "\(frames)")
        }
        #expect(rig.access.wanted == false)
        #expect(rig.access.tokens.live(now: rig.now) == 0)
        let back = try rig.upgraded()
        try back.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"token":"\#(pages[0].1)"}}"#)
        #expect(try back.framesUntilClosed().last?.closeCode == 4401)
        #expect(rig.access.admit(["pair": .string(pending)]) == nil, "a code made before the revoke is dropped too")
    }

    /// A revoke that lands between an `auth`'s code being taken and its token being issued leaves no token alive and
    /// admits nobody: the code was good when it was taken, but the user has since said "no page", and a token issued
    /// after that would outlive the revoke (and keep the listener up) until it ran out in 24 h.
    @Test func aRevokeBetweenTakeAndIssueLeavesNoLiveToken() throws {
        let (access, clock, _) = access()
        let code = access.openCode(now: clock.now)
        access.betweenTakeAndIssue = { _ = try? access.revoke().get() }
        #expect(access.admit(["pair": .string(code)]) == nil, "admitted after the revoke")
        #expect(access.tokens.live(now: clock.now) == 0, "a token outlived the revoke")
        #expect(access.wanted == false)
        // Without a revoke in between, the same path admits (the control).
        access.betweenTakeAndIssue = nil
        #expect(access.admit(["pair": .string(access.openCode(now: clock.now))]) != nil)
    }

    /// A connection admitted under a token the revoke dropped, after `admit` and before `hello`, is closed `revoked`:
    /// the listener asks `holds` once more before it says anything.
    @Test func aTokenRevokedBeforeHelloGetsNoHello() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        let issued = try rig.access.tokens.issue(now: rig.now)
        rig.access.afterAdmit = { _ = try? rig.access.revoke().get() }
        let page = try rig.upgraded()
        try page.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"token":"\#(issued.token)"}}"#)
        let frames = try page.framesUntilClosed()
        #expect(!frames.contains { $0.json?["kind"]?.string == "hello" }, "\(frames)")
        #expect(frames.first?.json?["code"]?.string == "revoked", "\(frames)")
        #expect(frames.last?.closeCode == 4403, "\(frames)")
        #expect(rig.handler.opened == 0)
    }

    // MARK: The user's voice

    /// `web.open` and `web.revoke` are the user's kinds, changing state; a WebSocket can send neither, whatever its
    /// rights; and through the server's requests a peer that isn't the user's voice is refused (`voice`) before
    /// anything is made.
    @Test(NodeTraits.linuxOnly) func openingTheWebNeedsTheUsersVoice() async throws {
        for kind in ["web.open", "web.revoke"] {
            #expect(NodeWire.kinds[kind] == .user, "\(kind)")
            #expect(NodeWire.changesState(kind), "\(kind)")
            #expect(WebAccess.refusal(for: NodeWire.Request(id: "1", kind: kind), rights: [.read, .draft])?.error?.code == NodeWire.Code.voice.rawValue)
            #expect(!WebAccess.kinds(for: [.read, .draft]).contains(kind))
        }
        let world = try await VoiceWorld(scratch)
        defer { world.stop() }
        // No controlling terminal, under the weaker rule: not the user's hands.
        var noTerminal = CardWorld.user
        noTerminal.terminal = .none
        for kind in ["web.open", "web.revoke"] {
            let reply = try #require(await world.ask(kind, from: noTerminal))
            #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(kind): \(reply)")
        }
        #expect(world.access.wanted == false)
        #expect(world.requests.queue.sync { world.requests.accepted }.isEmpty)
        // What the server's handler answers the user (I1 hands `act`'s case to it): the address, and a code it takes.
        world.access.listen = { .success(41234) }
        let opened = Locked<NodeWire.Reply?>(nil)
        world.requests.queue.sync {
            world.requests.webOpen(NodeWire.Request(id: "o", kind: "web.open", action: UUID().uuidString.lowercased()), web: world.access) { opened.value = $0 }
        }
        let url = try #require(opened.value?.result?["url"]?.string)
        #expect(url.hasPrefix("http://127.0.0.1:41234/#pair="), "\(url)")
        #expect(opened.value?.result?["expiresIn"]?.int == 120)
        #expect(world.access.wanted)
        let revoked = Locked<NodeWire.Reply?>(nil)
        world.requests.queue.sync {
            world.requests.webRevoke(NodeWire.Request(id: "r", kind: "web.revoke", action: UUID().uuidString.lowercased()), web: world.access) { revoked.value = $0 }
        }
        #expect(revoked.value?.result?["revoked"]?.int == 0)
        #expect(world.access.wanted == false)
    }

    /// A session's process (it carries the session's marker, or runs on a live session's terminal) can't open the web.
    @Test(NodeTraits.linuxOnly) func aSessionsProcessCantOpenTheWeb() async throws {
        let session = HostSession(id: UUID(), tty: "ttytest-session", childPID: 9_000_950, cwd: "/nonexistent/stub", command: "sleep 600",
                                  label: "Worker · parser", agent: nil, title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil)
        let world = try await VoiceWorld(scratch, sessions: [session])
        defer { world.stop() }
        var marked = CardWorld.user
        marked.sessionMarker = true
        var onItsTerminal = CardWorld.user
        onItsTerminal.terminal = .named(session.tty)
        var underIt = CardWorld.user
        underIt.ancestry = [.init(pid: CardWorld.userPID, startTicks: 5), .init(pid: session.childPID, startTicks: 3)]
        for (name, peer) in [("marked", marked), ("on its terminal", onItsTerminal), ("under its program", underIt)] {
            let reply = try #require(await world.ask("web.open", from: peer))
            #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(name): \(reply)")
        }
        #expect(world.access.wanted == false)
        #expect(world.requests.queue.sync { world.requests.accepted }.isEmpty)
    }

    /// `vibeswitcher web` with no controlling terminal is refused before it sends any request: the typed word's own
    /// refusal, no address, and nothing the server would have answered.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(10))) func webWithNoTerminalRefusesBeforeAnyRequest() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        for arguments in [["web"], ["web", "--revoke"]] {
            let ran = try await run(URL(fileURLWithPath: "/usr/bin/setsid"), ["--wait", commandLine.path] + arguments, environment: node.environment())
            #expect(ran.status == 77, "\(arguments): \(ran.output)\(ran.errors)")
            #expect(ran.errors.contains(TypedOutcome.noTerminal.refusal), "\(arguments): \(ran.errors)")
            #expect(ran.output.isEmpty, "\(arguments): \(ran.output)")
            let lines = ran.errors.split(separator: "\n").filter { !$0.hasPrefix("scratch node at ") }
            #expect(lines.count == 1, "\(arguments): only the refusal: \(ran.errors)")
        }
        #expect(!node.said.contains("web."), "\(node.said)")
        let usage = try await node.run(["web", "--open"])
        #expect(usage.status == 64, "\(usage.errors)")
    }
}

/// The server's requests on a stand-in host (`StubHost`), with a `WebAccess` on a scratch root: what `RequestsTests`
/// builds, for the voice of `web.open` and `web.revoke`.
private final class VoiceWorld: @unchecked Sendable {
    let stub: StubHost
    let requests: Requests
    let access: WebAccess

    init(_ scratch: Scratch, sessions: [HostSession] = []) async throws {
        stub = try StubHost(scratch, sessions: sessions)
        var timing = HostLink.Timing()
        timing.reconnectDelays = [0.05, 0.1, 0.2, 0.5, 1, 2]
        let link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), timing: timing, sweep: { _ in })
        link.start()
        try #require(await eventually { link.queue.sync { link.state == .connected } }, "the link was never welcomed")
        if !sessions.isEmpty {
            try #require(await eventually { link.queue.sync { link.sessions.count == sessions.count } }, "the stub's sessions never listed")
        }
        requests = Requests(link: link, sessions: nil, rule: CardWorld.rule, root: scratch.url("node-root"), hostSocket: stub.path,
                            commit: "test", hostPID: 1)
        requests.shutdown = { .error("not in this test") }
        access = WebAccess(tokens: WebTokens(root: requests.root))
    }

    func ask(_ kind: String, from peer: PeerFacts) async -> NodeWire.Reply? {
        let reply = Locked<NodeWire.Reply?>(nil)
        requests.queue.async { [requests] in
            requests.handle(NodeWire.Request(id: "r1", kind: kind, action: UUID().uuidString.lowercased()), from: peer) { answer in
                reply.mutate { $0 = answer }
            }
        }
        _ = await eventually(timeout: 60) { reply.value != nil }
        return reply.value
    }

    func stop() { stub.quit() }
}
