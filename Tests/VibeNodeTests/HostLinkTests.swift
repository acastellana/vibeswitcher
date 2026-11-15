import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The engine's link to the session host (`HostLink`, the engine plan's E2), against a scratch host (`NodeTestHost`:
/// the test process its app through the connector) or a stand-in (`StubHost`) where the case needs one: the app's
/// `HostClient` cases the port map lists (`HostClientReplyTimerTests`, `HostClientHandoverTests`' two request cases,
/// `InputUnitDeliveryTests`, `PasteDeliveryTests`' units, `ComposerDeliveryTests`' unit cases), their assertions kept.
/// What a case calls on the link it calls on the link's queue (`on`), where the engine calls it.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct HostLinkTests {
    private let scratch = Scratch()

    /// A link on `dialer` with `root` (a scratch one by default), started; returned once welcomed unless `welcomed` is
    /// false.
    private func link(_ dialer: HostDialer, root: URL? = nil, timing: HostLink.Timing = HostLink.Timing(), welcomed: Bool = true,
                      sweep: (([HostSession]) -> Void)? = { _ in }) async throws -> HostLink {
        let link = HostLink(dialer: dialer, root: root ?? scratch.url("link-root"), queue: DispatchQueue(label: "engine"), timing: timing,
                            sweep: sweep)
        link.start()
        if welcomed { try #require(await eventually { on(link) { link.state == .connected } }, "the link was never welcomed") }
        return link
    }

    /// Short reconnect delays (real time), so a case that drops the connection gets the next one at once.
    private static var quick: HostLink.Timing {
        var timing = HostLink.Timing()
        timing.reconnectDelays = [0.05, 0.1, 0.2, 0.5, 1, 2]
        return timing
    }

    /// `body` on the link's queue, where its state is read and its calls made.
    private func on<T>(_ link: HostLink, _ body: () throws -> T) rethrows -> T { try link.queue.sync(execute: body) }

    /// A session copying its lines (Enter ends one) to `out`, started by the link; returned once its terminal stopped
    /// echoing.
    private func spawnLines(_ link: HostLink, _ folder: URL) async throws -> (session: HostSession, out: String) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent("out").path, ready = folder.appendingPathComponent("ready").path
        let result = Locked<Result<HostSession, HostLink.Failure>?>(nil)
        link.spawn(SpawnRequest(cwd: folder.path, command: "stty -echo && : > '\(ready)' && exec cat > '\(out)'", env: [:], cols: 80, rows: 24,
                                keepShell: false, label: "Lines", agent: nil)) { result.value = $0 }
        #expect(await eventually { result.value != nil })
        let session = try #require(result.value).get()
        #expect(await eventually { FileManager.default.fileExists(atPath: ready) })
        return (session, out)
    }

    /// A program that reads nothing until `go` exists (`waits`) or for 2 s (`!waits`), then copies its input as is to
    /// `out` (or only its first `keep` bytes, then ends); returned once its terminal is raw (before, the line discipline
    /// keeps 1,024 bytes of a line and drops the rest).
    private func spawnReader(_ host: NodeTestHost, waits: Bool = true, keep: Int? = nil) async throws -> (session: HostSession, out: String, go: String) {
        let folder = host.folder.appendingPathComponent("reader-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent("out").path, go = folder.appendingPathComponent("go").path
        let raw = folder.appendingPathComponent("raw").path
        let wait = waits ? "while [ ! -e '\(go)' ]; do sleep 0.05; done" : "sleep 2"
        let copy = keep.map { "exec head -c \($0) > '\(out)'" } ?? "exec cat > '\(out)'"
        let session = try await host.spawn("stty raw -echo && : > '\(raw)'; \(wait); \(copy)", cwd: folder.path, label: "Reader")
        #expect(await eventually { FileManager.default.fileExists(atPath: raw) })
        return (session, out, go)
    }

    private static func contents(_ path: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data() }

    /// What the program got, once it got all of `expected` or something else (a byte missing, misplaced or extra).
    private static func received(_ path: String, _ expected: Data) async -> Data {
        let got = Locked(Data())
        _ = await eventually {
            got.value = contents(path)
            return got.value.count >= expected.count || !expected.starts(with: got.value)
        }
        return got.value
    }

    private static func lines(_ path: String) -> [String] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// The prompts the fake took, in order (its transcript's user messages).
    private static func prompts(_ h: NodeHarness) -> [String] {
        h.transcript.compactMap { line in
            guard line["type"] as? String == "user", line["isMeta"] == nil else { return nil }
            return (line["message"] as? [String: Any])?["content"] as? String
        }
    }

    // MARK: The welcome and the sessions

    @Test func theWelcomeListsTheSessionsAndChangesFollow() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let session = try await host.spawn("sleep 30")
        let link = HostLink(dialer: host.dialer, root: host.root, queue: DispatchQueue(label: "engine"))
        let seen = Locked<[String: HostSession?]>([:])
        let subscription = link.changes.subscribe { deltas in seen.mutate { for delta in deltas { $0[delta.id] = delta.value } } }
        defer { subscription.cancel() }
        link.start()
        #expect(await eventually { on(link) { link.state == .connected } })
        let listed = try #require(on(link) { link.sessions.first { $0.id == session.id } })
        #expect(listed.tty.hasPrefix("ttypts") && listed.isLive, "\(listed)")
        let id = NodeIds.session(host: session.id)
        #expect(await eventually { seen.value[id].flatMap { $0 }?.isLive == true })
        #expect(on(link) { link.hostStartedAt } != nil)

        link.kill(session.id)
        #expect(await eventually { seen.value[id].flatMap { $0 }?.exit != nil }, "\(seen.value)")
        let exit = try #require(on(link) { link.sessions.first { $0.id == session.id }?.exit })
        #expect(exit.status != -1, "\(exit)")
    }

    // MARK: Reply timers (HostClientReplyTimerTests)

    /// A link on a scratch host with its reply timers in the test's hand, which had `asking` requests in flight when
    /// its connection dropped and is connected again. Their timers, by the number each request had.
    private func reconnected(_ host: NodeTestHost, asking: Int = 64) async throws -> (link: HostLink, clock: ManualClock, timers: [Int: () -> Void]) {
        let clock = ManualClock()
        var timing = Self.quick
        timing.reply = clock.schedule
        let link = try await link(host.dialer, root: host.root, timing: timing)
        let dropped = Locked(0)
        let timers = try on(link) { () -> [Int: () -> Void] in
            var timers: [Int: () -> Void] = [:]
            for _ in 0..<asking {
                let before = Set(link.replies.keys)
                link.screen(UUID()) { screen in
                    #expect(screen == nil)
                    dropped.mutate { $0 += 1 }
                }
                let seq = try #require(Set(link.replies.keys).subtracting(before).first)
                timers[seq] = clock.armed.last
            }
            // No reply can come first: replies come on this queue, and this runs through without giving it up.
            link.connectAgain()
            return timers
        }
        #expect(dropped.value == asking)
        #expect(await eventually { on(link) { link.state == .connected } })
        return (link, clock, timers)
    }

    @Test func anOldTimerDoesntErrorTheRequestHoldingItsNumberOnTheNewConnection() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let (link, _, timers) = try await reconnected(host)
        let session = try await host.spawn("sleep 600")
        let answers = Locked<[String?]>([])
        let early = try on(link) { () -> [String?] in
            let before = Set(link.replies.keys)
            link.screen(session.id) { text in answers.mutate { $0.append(text) } }
            let seq = try #require(Set(link.replies.keys).subtracting(before).first)
            let oldTimer = try #require(timers[seq], "seq \(seq) wasn't used on the dropped connection")
            // Fired on the link's queue, before the reply can come: a timer that speaks for this request answers now.
            oldTimer()
            return answers.value
        }
        #expect(early.isEmpty, "the dropped connection's timer answered this request")
        #expect(await eventually { !answers.value.isEmpty })
        #expect(answers.value.count == 1 && answers.value.first.flatMap { $0 } != nil, "\(answers.value)")
    }

    @Test func anOldTimerDoesntEndAUnitOnTheNewConnection() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let (link, _, timers) = try await reconnected(host)
        let (session, out, go) = try await spawnReader(host)
        #expect(FileManager.default.createFile(atPath: go, contents: nil))
        let piece = Data((0..<4_096).map { UInt8(ascii: "a") + UInt8($0 % 26) })
        let done = Locked<Bool?>(nil)
        try on(link) {
            let before = Set(link.replies.keys)
            link.type([HostInput.Write(bytes: Array(piece), delay: 0)], into: session.id, confirmed: { done.value = $0 })
            // The unit's one part.
            let sent = Set(link.replies.keys).subtracting(before).sorted()
            #expect(sent.count == 1, "\(sent)")
            let seq = try #require(sent.first)
            let oldTimer = try #require(timers[seq], "the unit's seq wasn't used on the dropped connection")
            oldTimer()
        }
        #expect(await eventually { done.value != nil })
        #expect(done.value == true)
        // The end mark comes after whatever the host took: a unit sent twice shows before it.
        let end = Data("END".utf8)
        link.type([HostInput.Write(bytes: Array(end), delay: 0)], into: session.id)
        #expect(await Self.received(out, piece + end) == piece + end)
    }

    // MARK: Requests across a reconnect (HostClientHandoverTests' two request cases)

    /// The link has lost its connection and makes the next one: a kill and a read asked meanwhile aren't lost, they go
    /// out once on the new connection.
    @Test func requestsAskedWhileTheLinkReconnectsGoOutOnTheNewConnection() async throws {
        let session = StubHost.session()
        let stub = try StubHost(scratch, sessions: [session])
        defer { stub.quit() }
        let link = try await link(stub.dialer, timing: Self.quick)
        let history = Locked<Bool?>(nil)
        on(link) {
            link.connectAgain()
            #expect(link.state == .connecting)
            link.kill(session.id)
            link.history(session.id, lines: 10) { history.value = ($0 != nil) }
        }
        #expect(await eventually { on(link) { link.state == .connected } && stub.requests.contains { if case .history = $0 { true } else { false } } })
        let kills = stub.requests.filter { if case .kill = $0 { true } else { false } }
        let reads = stub.requests.filter { if case .history = $0 { true } else { false } }
        #expect(kills == [.kill(id: session.id)], "\(stub.requests)")
        #expect(reads == [.history(id: session.id, lines: 10)], "\(stub.requests)")
        #expect(await eventually { history.value != nil })
        #expect(history.value == true)
        #expect(stub.connections == 2)
    }

    /// A request still gets its 15 s while the link reconnects: no less, and no more. One asked on the connection gets
    /// them from when it's asked; one asked while the link reconnects, from when it goes out on the new one. On a clock
    /// the test moves.
    @Test func otherRequestsKeepTheirTimersDuringAReconnect() async throws {
        let stub = try StubHost(scratch)
        defer { stub.quit() }
        stub.answersScreens = false
        let clock = ManualClock()
        var timing = Self.quick
        timing.reply = clock.schedule
        let link = try await link(stub.dialer, timing: timing)
        let first = Locked<(text: String?, after: TimeInterval)?>(nil)
        on(link) {
            let asked = clock.now
            link.screen(UUID()) { first.value = ($0, clock.now - asked) }
        }
        on(link) { clock.advance(14) }
        #expect(first.value == nil)
        on(link) { clock.advance(1) }
        let unanswered = try #require(first.value)
        #expect(unanswered.text == nil && unanswered.after == 15, "\(unanswered)")

        let second = Locked<(text: String?, after: TimeInterval)?>(nil)
        on(link) {
            link.connectAgain()
            link.screen(UUID()) { second.value = ($0, clock.now) }
        }
        #expect(await eventually { on(link) { link.state == .connected } && stub.requests.filter { if case .screen = $0 { true } else { false } }.count == 2 })
        let sent = clock.now
        on(link) { clock.advance(14) }
        #expect(second.value == nil)
        on(link) { clock.advance(1) }
        let held = try #require(second.value)
        #expect(held.text == nil && held.after - sent == 15, "\(held)")
    }

    /// The connection has ended on the host's side and the link hasn't been told yet: a kill asked then is held, and
    /// sent once on the next connection.
    @Test func aRequestHeldWhileTheConnectionGoesIsSentOnceOnTheNext() async throws {
        let session = StubHost.session()
        let stub = try StubHost(scratch, sessions: [session])
        defer { stub.quit() }
        let link = try await link(stub.dialer, timing: Self.quick)
        try on(link) {
            let connection = try #require(link.connection)
            stub.dropConnections()
            let deadline = MacTime.real.awake() + hangGuard
            while !connection.isClosed, MacTime.real.awake() < deadline { usleep(1_000) }
            try #require(connection.isClosed, "the connection never ended")
            // The close is on its way to this queue, behind this block.
            #expect(link.state == .connected)
            link.kill(session.id)
        }
        #expect(await eventually { on(link) { link.state == .connected } && stub.connections == 2 && stub.requests.contains(.kill(id: session.id)) })
        // Sent by the next connection's welcome, and only then: once.
        #expect(stub.requests.filter { $0 == .kill(id: session.id) }.count == 1, "\(stub.requests)")
    }

    // MARK: Units (InputUnitDeliveryTests, ComposerDeliveryTests, PasteDeliveryTests)

    @Test func theEnginesUnitsAndTheToolServersAtOnceGoInWhole() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let link = try await link(host.dialer, root: host.root)
        let (session, out) = try await spawnLines(link, host.folder.appendingPathComponent("lines"))
        let count = 20
        let engine = (0..<count).map { "engine message \($0)" }, tools = (0..<count).map { "tool server message \($0)" }
        let socket = host.socket, id = session.id
        // The tool server's, as `HostRuntime.type` sends them: each on a connection of its own, off the engine's queue.
        let typing = Task.detached {
            tools.filter { text in
                (try? HostCall.type(HostInput.writes(text: text, submit: true, key: nil), into: id, socket: socket, appKey: nil, timeout: hangGuard)) != nil
            }.count
        }
        // The engine's, as its wake-ups: one unit each.
        let confirmed = Locked(0)
        on(link) {
            for text in engine { link.type(HostInput.writes(text: text, submit: true, key: nil), into: id, confirmed: { if $0 { confirmed.mutate { $0 += 1 } } }) }
        }
        let typed = await typing.value
        #expect(await eventually { confirmed.value == count && Self.lines(out).count >= 2 * count })
        let got = Self.lines(out)
        #expect(on(link) { link.capabilities.contains(HostProtocol.Capability.inputUnits) })
        #expect(typed == tools.count)
        #expect(got.sorted() == (engine + tools).sorted(), "\(got)")
        #expect(got.filter { $0.hasPrefix("engine") } == engine)
        #expect(got.filter { $0.hasPrefix("tool") } == tools)
    }

    /// Three clients' units to one session (the app's case had them on one client: the composer, a phone reply, a lead's
    /// wake-up): the link's (a bracketed paste and Enter), a second app connection's (`HostInput.writes`; another
    /// `HostConnection` to the same path, through the registry: one by the path would be `.unknown`, and refused for
    /// that), and the tool server's (`HostCall.type`). Each sent once the host took the one before (its connection's
    /// next answer, a screen read, says so), while that one is still going in: three prompts, in the order sent.
    @Test func threeClientsUnitsDontInterleave() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let h = try await NodeHarness.start(on: host)
        let link = try await link(host.dialer, root: host.root)
        let id = h.session.id
        let linkTook = Locked(false)
        on(link) {
            link.type(ComposerText.writes("from the lead", bracketed: true), into: id)
            link.screen(id) { _ in linkTook.value = true }
        }
        #expect(await eventually { linkTook.value })
        let queue = DispatchQueue(label: "second-app-connection")
        let replies = Locked<Set<Int>>([])
        let other = try queue.sync { () throws -> HostConnection in
            let connection = try HostConnection(path: host.socket, queue: queue, appKey: nil)
            connection.onEvent = { envelope in if let seq = envelope.replyTo { replies.mutate { _ = $0.insert(seq) } } }
            return connection
        }
        defer { queue.sync { other.close() } }
        let read = try queue.sync { () throws -> Int in
            try other.send(.hello(protocolVersion: HostProtocol.version, app: "HostLinkTests"))
            try other.send(.inputUnit(id: id, writes: HostInput.writes(text: "from the phone", submit: true, key: nil), more: false))
            return try other.send(.screen(id: id))
        }
        #expect(await eventually { replies.value.contains(read) })
        let socket = host.socket
        try await offPool {
            try HostCall.type(ComposerText.writes("from the tool server", bracketed: false), into: id, socket: socket, appKey: nil, timeout: hangGuard)
        }
        try await h.waitFor { Self.prompts(h).count >= 3 }
        #expect(Self.prompts(h) == ["from the lead", "from the phone", "from the tool server"], "\(Self.prompts(h))")
    }

    @Test func aUnitStoppedByItsGateSendsNoEnterAndTheNextOneStillGoes() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let h = try await NodeHarness.start(on: host)
        let link = try await link(host.dialer, root: host.root)
        let stopped = Locked<Bool?>(nil)
        on(link) {
            // A reply whose sender changed its mind between its text and its Enter: the Enter isn't sent.
            link.type(HostInput.writes(text: "half", submit: true, key: nil), into: h.session.id, gate: { index, go in go(index == 0) }) {
                stopped.value = !$0
            }
            link.type(HostInput.writes(text: "whole", submit: true, key: nil), into: h.session.id)
        }
        try await h.waitFor { Self.prompts(h).contains { $0.hasSuffix("whole") } }
        #expect(stopped.value == true)
        // "half" was left in the box, and the next unit's Enter took it along: what matters is that the next unit still
        // went in after it, not before or in its middle.
        #expect(Self.prompts(h) == ["halfwhole"], "\(Self.prompts(h))")
    }

    @Test func aGateAnsweredLaterHoldsTheNextUnitAndARefusedOneSendsNoEnter() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let h = try await NodeHarness.start(on: host)
        let link = try await link(host.dialer, root: host.root)
        // A menu answer: Enter only once the screen, read again, still shows the question. The next unit waits for that
        // read; it doesn't go in between the keys and the Enter.
        let asked = Locked<[Int]>([])
        let answer = Locked<((Bool) -> Void)?>(nil)
        let answered = Locked<Bool?>(nil)
        on(link) {
            link.type(HostInput.writes(text: "tapped", submit: true, key: nil), into: h.session.id, gate: { index, go in
                asked.mutate { $0.append(index) }
                if index == 0 { go(true) } else { answer.value = go }
            }) { answered.value = $0 }
            link.type(HostInput.writes(text: "after", submit: true, key: nil), into: h.session.id)
        }
        try await h.waitFor { answer.value != nil }
        try await h.screenShows { $0.contains("tapped") }
        #expect(!h.screen.contains("after"), "\(h.screen)")
        #expect(Self.prompts(h).isEmpty, "\(Self.prompts(h))")
        // The menu moved: no Enter, and the next unit goes in after it.
        answer.value?(false)
        try await h.waitFor { Self.prompts(h).contains { $0.hasSuffix("after") } }
        #expect(asked.value == [0, 1])
        #expect(answered.value == false)
        #expect(Self.prompts(h) == ["tappedafter"], "\(Self.prompts(h))")
    }

    @Test func aLongMessageGoesInWholeOnceTheProgramReads() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let link = try await link(host.dialer, root: host.root)
        // It reads nothing for its first 2 s: the host's buffer fills, and the rest waits instead of being lost.
        let (session, out, _) = try await spawnReader(host, waits: false)
        let message = Data((0..<200_000).map { UInt8(ascii: "A") + UInt8(($0 / 1_000) % 26) })
        let done = Locked<Bool?>(nil)
        link.type([HostInput.Write(bytes: Array(message), delay: 0)], into: session.id, confirmed: { done.value = $0 })
        #expect(await Self.received(out, message) == message)
        #expect(await eventually { done.value != nil })
        #expect(done.value == true)
    }

    /// 3 MB and an Enter to a program that reads its first 100,000 bytes and ends: the unit is confirmed as not
    /// delivered, and what the program got is the start of it, with no Enter.
    @Test func aUnitIntoASessionThatEndsIsConfirmedNotDelivered() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let link = try await link(host.dialer, root: host.root)
        let keep = 100_000
        let (session, out, go) = try await spawnReader(host, keep: keep)
        let paste = Data((0..<(3 << 20)).map { UInt8(ascii: "A") + UInt8(($0 / 1_000) % 26) })
        let confirmed = Locked<Bool?>(nil)
        link.type([HostInput.Write(bytes: Array(paste), delay: 0), HostInput.Write(bytes: [0x0D], delay: 0.05)], into: session.id, confirmed: {
            confirmed.value = $0
        })
        #expect(FileManager.default.createFile(atPath: go, contents: nil))
        #expect(await eventually { confirmed.value != nil })
        #expect(confirmed.value == false)
        let got = Self.contents(out)
        #expect(got == paste.prefix(keep), "\(got.count) bytes")
        #expect(!got.contains(0x0D))
    }

    @Test func aHostWithoutInputUnitsIsRefused() async throws {
        let stub = try StubHost(scratch, capabilities: [HostProtocol.Capability.handover])
        defer { stub.quit() }
        let gone = Locked<[String]>([])
        let link = HostLink(dialer: stub.dialer, root: scratch.url("link-root"), queue: DispatchQueue(label: "engine"), timing: Self.quick)
        on(link) { link.onGone = { reason in gone.mutate { $0.append(reason) } } }
        link.start()
        #expect(await eventually { on(link) { if case .gone = link.state { true } else { false } } })
        let reason = on(link) { () -> String in if case .gone(let reason) = link.state { reason } else { "" } }
        #expect(reason.contains("input units"), "\(reason)")
        #expect(gone.value == [reason])
        let confirmed = Locked<Bool?>(nil)
        on(link) { link.type(HostInput.writes(text: "never", submit: true, key: nil), into: UUID(), confirmed: { confirmed.value = $0 }) }
        #expect(await eventually { confirmed.value != nil })
        #expect(confirmed.value == false)
        // Nothing typed piece by piece, and no other connection tried.
        #expect(!stub.requests.contains { if case .input = $0 { true } else if case .inputUnit = $0 { true } else { false } }, "\(stub.requests)")
        #expect(stub.connections == 1)
    }

    // MARK: The host's notes

    @Test func notesAreAskedOnlyOfAHostThatListsThem() async throws {
        let listing = try StubHost(scratch, capabilities: [HostProtocol.Capability.inputUnits, HostProtocol.Capability.hostNotes])
        let silent = try StubHost(scratch, capabilities: [HostProtocol.Capability.inputUnits])
        defer {
            listing.quit()
            silent.quit()
        }
        for (stub, lists) in [(listing, true), (silent, false)] {
            let link = try await link(stub.dialer)
            let notes = Locked<HostNotes??>(nil)
            link.notes { notes.value = .some($0) }
            #expect(await eventually { notes.value != nil })
            #expect(notes.value == .some(lists ? stub.notes : nil))
            #expect(stub.requests.contains(.hostNotes) == lists, "\(stub.requests)")
            #expect(on(link) { link.hostStartedAt } == stub.startedAt)
        }
        // A scratch host on Linux lists them, and answers its app.
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let link = try await link(host.dialer, root: host.root)
        let notes = Locked<HostNotes??>(nil)
        link.notes { notes.value = .some($0) }
        #expect(await eventually { notes.value != nil })
        let answered = try #require(notes.value.flatMap { $0 })
        #expect(answered.serverRestarts == 0)
    }

    // MARK: The host gone

    @Test func aHostThatIsGoneEndsTheLink() async throws {
        let session = StubHost.session()
        let stub = try StubHost(scratch, sessions: [session])
        let link = try await link(stub.dialer, timing: Self.quick)
        let gone = Locked(0)
        let seen = Locked<[String: HostSession?]>([:])
        let subscription = link.changes.subscribe { deltas in seen.mutate { for delta in deltas { $0[delta.id] = delta.value } } }
        defer { subscription.cancel() }
        on(link) { link.onGone = { _ in gone.mutate { $0 += 1 } } }
        stub.quit()
        #expect(await eventually { on(link) { if case .gone = link.state { true } else { false } } })
        #expect(on(link) { link.sessions.map { $0.exit?.status } } == [-1])
        #expect(await eventually { seen.value[NodeIds.session(host: session.id)].flatMap { $0 }?.exit?.status == -1 }, "\(seen.value)")
        // Every reconnect delay was waited before it was called gone, and it's told once.
        #expect(on(link) { link.reconnectAttempt } == Self.quick.reconnectDelays.count)
        #expect(gone.value == 1)
        let history = Locked<Bool?>(nil)
        link.history(session.id, lines: 1) { history.value = ($0 != nil) }
        #expect(await eventually { history.value != nil })
        #expect(history.value == false)
    }

    // MARK: Changes

    @Test func aSpinnerOnlyChangeIsNotSent() async throws {
        var session = StubHost.session(title: "⠋ Fix login")
        let stub = try StubHost(scratch, sessions: [session])
        defer { stub.quit() }
        let link = try await link(stub.dialer)
        let id = NodeIds.session(host: session.id)
        #expect(link.changes.values[id]?.title == "⠋ Fix login")
        session.title = "⠙ Fix login"
        stub.push(.sessionChanged(session))
        // Answered after the change was handled: the host sends a connection's events in order.
        let read = Locked(false)
        link.screen(session.id) { _ in read.value = true }
        #expect(await eventually { read.value })
        #expect(on(link) { link.sessions.first?.title } == "⠋ Fix login")
        #expect(link.changes.values[id]?.title == "⠋ Fix login")
        session.title = "Done"
        stub.push(.sessionChanged(session))
        #expect(await eventually { link.changes.values[id]?.title == "Done" })
        #expect(on(link) { link.sessions.first?.title } == "Done")
    }

    // MARK: The sessions' TMPDIRs

    @Test func sessionTemporaryFoldersAreSweptOnlyWhileConnected() async throws {
        var first = StubHost.session(tty: "ttypts1"), second = StubHost.session(tty: "ttypts2")
        let stub = try StubHost(scratch, sessions: [first, second])
        defer { stub.quit() }
        let sweeps = Locked<[[HostSession]]>([])
        let later = ManualClock(), reconnect = ManualClock()
        var timing = HostLink.Timing()
        timing.sweep = later.schedule
        timing.reconnect = reconnect.schedule
        timing.reconnectDelays = [1, 1, 1]
        let link = try await link(stub.dialer, timing: timing, sweep: { sessions in sweeps.mutate { $0.append(sessions) } })
        // At the welcome, by its whole list.
        #expect(sweeps.value.map { $0.map(\.id) } == [[first.id, second.id]])

        // A session that ends while connected: swept once it has settled.
        first.exit = HostSession.Exit(status: 0, at: Date())
        stub.push(.sessionChanged(first))
        #expect(await eventually { on(link) { link.sessions.first?.exit != nil } })
        on(link) { later.advance(SessionTemp.settle) }
        #expect(sweeps.value.count == 1)
        on(link) { later.advance(1) }
        #expect(sweeps.value.count == 2)
        #expect(sweeps.value.last?.first?.exit != nil)

        // One that ends just before the connection goes: its sweep comes while the link reconnects, and does nothing.
        second.exit = HostSession.Exit(status: 0, at: Date())
        stub.push(.sessionChanged(second))
        #expect(await eventually { on(link) { link.sessions.last?.exit != nil } })
        on(link) {
            link.connectAgain()
            later.advance(SessionTemp.settle + 1)
        }
        #expect(sweeps.value.count == 2)

        // The next welcome sweeps again.
        on(link) { reconnect.advance(1) }
        #expect(await eventually { sweeps.value.count == 3 })
        #expect(on(link) { link.state } == .connected)
    }

    // MARK: The vault and the dialer

    /// The link's vault asks the host on a fresh connection through the dialer for each call (as `HostCall.vault` does by
    /// a path): through the connector, the app's, so a lead's grant is issued.
    @Test func theVaultAsksTheHostThroughTheDialer() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let repository = host.folder.appendingPathComponent("repository")
        try await scratchRepository(repository)
        let link = try await link(host.dialer, root: host.root)
        #expect(link.vault.folder == host.root.appendingPathComponent("lead", isDirectory: true))
        let vault = link.vault
        let grant = try await offPool { try vault.issue(role: .lead, root: repository.path, task: nil) }
        #expect(!grant.isEmpty)
        // A host that isn't there: refused, saying so, not a hang.
        let stub = try StubHost(scratch)
        let path = stub.path
        stub.quit()
        let lost = HostLink(dialer: StubDialer(path: path), root: scratch.url("link-root"), queue: DispatchQueue(label: "engine")).vault
        #expect(throws: LeadVault.Refused.self) { try lost.issue(role: .lead, root: repository.path, task: nil) }
    }

    /// The server's dialer reaches only a path a connector is registered for, through it; any other path it never dials,
    /// even with a host listening there.
    @Test func theConnectorDialerNeverDialsByPath() async throws {
        let stub = try StubHost(scratch)
        defer { stub.quit() }
        #expect(throws: ConnectorDialer.Unregistered.self) { _ = try ConnectorDialer(path: stub.path).connect(queue: DispatchQueue(label: "dial")) }
        #expect(stub.connections == 0)

        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let session = try await host.spawn("sleep 600")
        // Through the connector: the app's, shown the host's sessions (a client by the path is shown none).
        let link = try await link(ConnectorDialer(path: host.socket), root: host.root)
        #expect(on(link) { link.sessions.map(\.id) }.contains(session.id))
    }

    private struct StubDialer: HostDialer {
        let path: String
        func connect(queue: DispatchQueue) throws -> HostConnection {
            try HostConnection(path: path, queue: queue, appKey: nil, viaConnector: false)
        }
    }
}
