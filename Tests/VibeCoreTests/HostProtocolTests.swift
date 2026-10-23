import Foundation
import Testing
@testable import VibeCore

struct HostFrameTests {
    @Test func framesSurviveArbitrarySplits() throws {
        let a = HostFrame.encode(.control, Data("{\"x\":1}".utf8))
        let b = HostFrame.encode(.output, Data([1, 2, 3]))
        let stream = a + b
        var decoder = HostFrameDecoder()
        var frames: [(HostFrame.Kind, Data)] = []
        for byte in stream {   // one byte at a time: the worst split
            decoder.append(Data([byte]))
            while let frame = try decoder.next() { frames.append((frame.kind, frame.payload)) }
        }
        #expect(frames.count == 2)
        #expect(frames[0].0 == .control && frames[0].1 == Data("{\"x\":1}".utf8))
        #expect(frames[1].0 == .output && frames[1].1 == Data([1, 2, 3]))
    }

    @Test func severalFramesInOneRead() throws {
        var decoder = HostFrameDecoder()
        decoder.append(HostFrame.encode(.control, Data("a".utf8)) + HostFrame.encode(.control, Data("b".utf8)))
        #expect(try decoder.next()?.payload == Data("a".utf8))
        #expect(try decoder.next()?.payload == Data("b".utf8))
        #expect(try decoder.next() == nil)
    }

    @Test func oversizeAndBadKindAreErrors() {
        var big = HostFrameDecoder()
        var length = UInt32(HostFrame.maxPayload + 2).bigEndian
        big.append(Data(bytes: &length, count: 4) + Data([0]))
        #expect(throws: HostFrameDecoder.Failure.self) { try big.next() }

        var bad = HostFrameDecoder()
        var one = UInt32(1).bigEndian
        bad.append(Data(bytes: &one, count: 4) + Data([9]))
        #expect(throws: HostFrameDecoder.Failure.badKind(9)) { try bad.next() }

        var empty = HostFrameDecoder()
        empty.append(Data([0, 0, 0, 0]))
        #expect(throws: HostFrameDecoder.Failure.emptyFrame) { try empty.next() }
    }

    @Test func largeOutputIsSplitAndKeepsItsSession() throws {
        let id = UUID()
        let bytes = Data((0..<(HostFrame.maxPayload * 2 + 10)).map { UInt8($0 % 251) })
        let frames = HostFrame.output(session: id, bytes: bytes)
        #expect(frames.count == 3)
        var decoder = HostFrameDecoder()
        frames.forEach { decoder.append($0) }
        var joined = Data()
        while let frame = try decoder.next() {
            #expect(frame.kind == .output)
            let (session, chunk) = try #require(HostFrame.parseOutput(frame.payload))
            #expect(session == id)
            joined.append(chunk)
        }
        #expect(joined == bytes)
        #expect(HostFrame.output(session: id, bytes: Data()).isEmpty)
    }
}

struct HostMessageTests {
    @Test func requestsAndEventsRoundTrip() throws {
        let id = UUID()
        let session = HostSession(id: id, tty: "ttys012", childPID: 42, cwd: "/tmp", command: "claude", label: "Claude",
                                  agent: "claude", title: "✳ Fix", startedAt: Date(timeIntervalSince1970: 1_000),
                                  cols: 120, rows: 40, exit: .init(status: 0, at: Date(timeIntervalSince1970: 2_000)))
        let requests: [HostRequest] = [
            .hello(protocolVersion: HostProtocol.version, app: "test"),
            .spawn(SpawnRequest(cwd: "/tmp", command: nil, env: ["A": "1"], cols: 80, rows: 24, keepShell: true,
                                label: "Shell", agent: nil)),
            .attach(id: id, cols: 80, rows: 24), .detach(id: id),
            .input(id: id, bytes: Data([0x1b, 0x5b, 0x41]), reply: false), .resize(id: id, cols: 100, rows: 30),
            .inputUnit(id: id, writes: [HostInput.Write(bytes: Array("hi".utf8), delay: 0), HostInput.Write(bytes: [13], delay: 0.06)], more: true),
            .screen(id: id), .styledScreen(id: id), .history(id: id, lines: 500), .kill(id: id), .remove(id: id), .shutdown,
            .handover(executable: "/Applications/VibeSwitcher.app/Contents/MacOS/vibeswitcher-host"),
            .proveApp(answer: Data(repeating: 1, count: 32)), .enrollApp(key: Data(repeating: 2, count: 32)), .replaceAppKey(key: Data(repeating: 6, count: 32)),
        ]
        for request in requests {
            let data = try HostCoding.encode(HostRequestEnvelope(seq: 7, request: request))
            #expect(try HostCoding.decode(HostRequestEnvelope.self, from: data) == HostRequestEnvelope(seq: 7, request: request))
        }
        let events: [HostEvent] = [
            .welcome(protocolVersion: 1, hostBuild: 123, sessions: [session]),
            .welcome(protocolVersion: 1, hostBuild: 123, sessions: [session], capabilities: ["styledScreen"], pid: 4242,
                     startedAt: Date(timeIntervalSince1970: 1_500)),
            .spawned(session), .attached(id: id),
            .screenText(id: id, text: "hi"),
            .styledScreenText(id: id, text: "❯ hi", runs: [ScreenRun(row: 0, column: 2, length: 2, faint: true),
                                                         ScreenRun(row: 0, column: 0, length: 1, inverse: true, color: .rgb(153, 153, 153)),
                                                         ScreenRun(row: 1, column: 0, length: 3, color: .palette(244))]),
            .historyText(id: id, history: "a\nb", screen: "c"),
            .sessionChanged(session), .sessionRemoved(id: id), .resync(id: id), .bell(id: id), .error("nope"), .ok,
            .challenge(Data(repeating: 3, count: 32), keyless: true), .vault(.startedOver(1_234)),
        ]
        // A unit's bytes go as base64, not an array of numbers.
        let unit = try HostCoding.encode(HostRequest.inputUnit(id: id, writes: [HostInput.Write(bytes: Array("hi".utf8), delay: 0)], more: false))
        #expect(String(decoding: unit, as: UTF8.self).contains(#""aGk=""#))
        for event in events {
            let data = try HostCoding.encode(HostEventEnvelope(replyTo: 3, event: event))
            #expect(try HostCoding.decode(HostEventEnvelope.self, from: data) == HostEventEnvelope(replyTo: 3, event: event))
        }
    }

    /// The Exit an app before `signal` knew: status and time only.
    private struct OlderExit: Codable, Equatable {
        var status: Int32
        var at: Date
    }

    @Test func anExitSaysWhetherASignalEndedItAndOlderAppsStillReadIt() throws {
        let at = Date(timeIntervalSince1970: 2_000)
        let killed = HostSession.Exit(status: 143, at: at, signal: 15, core: false)
        let exited = HostSession.Exit(status: 143, at: at)
        #expect(killed.cause == "killed by SIGTERM")
        #expect(exited.cause == "exited 143")
        #expect(HostSession.Exit(status: 129, at: at, signal: 1, killedBy: 4242, killedByName: "vibeswitcher-mcp").cause
                == "killed by SIGHUP from pid 4242 (vibeswitcher-mcp)")
        #expect(HostSession.Exit(status: 139, at: at, signal: 11, core: true).cause == "killed by SIGSEGV (core dumped)")
        #expect(HostSession.Exit(status: 158, at: at, signal: 30).cause == "killed by signal 30")
        #expect(HostSession.Exit(status: -1, at: at).cause == "lost with the session host")
        // Through the protocol both ways: the new fields survive, an older app reads what it knows, and an older
        // host's Exit has no signal.
        let session = HostSession(id: UUID(), tty: "ttys001", childPID: 1, cwd: "/", command: nil, label: "Shell",
                                  agent: nil, title: "", startedAt: at, cols: 80, rows: 24, exit: killed)
        let data = try HostCoding.encode(HostEventEnvelope(replyTo: nil, event: .sessionChanged(session)))
        #expect(try HostCoding.decode(HostEventEnvelope.self, from: data) == HostEventEnvelope(replyTo: nil, event: .sessionChanged(session)))
        let older = try HostCoding.decode(OlderExit.self, from: try HostCoding.encode(killed))
        #expect(older == OlderExit(status: 143, at: at))
        let fromOlderHost = try HostCoding.decode(HostSession.Exit.self, from: try HostCoding.encode(older))
        #expect(fromOlderHost == exited && fromOlderHost.signal == nil)
    }

    /// The welcome's capabilities, pid and start time are additions: an older app reads a newer host's welcome, and
    /// this app reads an older host's.
    @Test func welcomeAdditionsKeepTheOldShapeReadable() throws {
        enum OldEvent: Codable, Equatable { case welcome(protocolVersion: Int, hostBuild: Int, sessions: [HostSession]) }
        struct OldEnvelope: Codable, Equatable { var replyTo: Int?; var event: OldEvent }
        let started = Date(timeIntervalSince1970: 1_500)
        let new = HostEventEnvelope(replyTo: 1, event: .welcome(protocolVersion: 1, hostBuild: 7, sessions: [],
                                                                capabilities: ["styledScreen", "handover"], pid: 99, startedAt: started))
        #expect(try HostCoding.decode(OldEnvelope.self, from: HostCoding.encode(new))
                == OldEnvelope(replyTo: 1, event: .welcome(protocolVersion: 1, hostBuild: 7, sessions: [])))
        let old = try HostCoding.encode(OldEnvelope(replyTo: 1, event: .welcome(protocolVersion: 1, hostBuild: 7, sessions: [])))
        #expect(try HostCoding.decode(HostEventEnvelope.self, from: old)
                == HostEventEnvelope(replyTo: 1, event: .welcome(protocolVersion: 1, hostBuild: 7, sessions: [], capabilities: nil, pid: nil, startedAt: nil)))
    }

    @Test func liveMeansNotExited() {
        var session = HostSession(id: UUID(), tty: "ttys001", childPID: 1, cwd: "/", command: nil, label: "Shell",
                                  agent: nil, title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil)
        #expect(session.isLive)
        session.exit = .init(status: 1, at: Date())
        #expect(!session.isLive)
    }
}

struct HostSessionSpinnerTests {
    private func session(title: String, cols: Int = 120) -> HostSession {
        HostSession(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, tty: "ttys012", childPID: 42, cwd: "/tmp",
                    command: "claude", label: "Claude", agent: "claude", title: title, startedAt: Date(timeIntervalSince1970: 1_000),
                    cols: cols, rows: 40, exit: nil)
    }

    /// A working agent's spinner changes the title many times a second: that alone isn't news to the app.
    @Test func aSpinnerFrameAloneReadsTheSame() {
        #expect(session(title: "⠙ Fix login").differsOnlyBySpinner(from: session(title: "⠋ Fix login")))
        #expect(session(title: "✶ Fix login").differsOnlyBySpinner(from: session(title: "✻ Fix login")))
    }

    @Test func anythingElseIsAChange() {
        #expect(!session(title: "✳ Fix login").differsOnlyBySpinner(from: session(title: "⠋ Fix login")))   // the turn ended
        #expect(!session(title: "⠋ Fix signup").differsOnlyBySpinner(from: session(title: "⠋ Fix login")))
        #expect(!session(title: "⠙ Fix login", cols: 100).differsOnlyBySpinner(from: session(title: "⠋ Fix login")))
        #expect(!session(title: "~/dev/b").differsOnlyBySpinner(from: session(title: "~/dev/a")))
        #expect(!session(title: "⠋ Fix login").differsOnlyBySpinner(from: session(title: "⠋ Fix login")))     // nothing changed
    }
}
