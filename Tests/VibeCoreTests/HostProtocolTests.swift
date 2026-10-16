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
            .screen(id: id), .history(id: id, lines: 500), .kill(id: id), .remove(id: id), .shutdown,
        ]
        for request in requests {
            let data = try HostCoding.encode(HostRequestEnvelope(seq: 7, request: request))
            #expect(try HostCoding.decode(HostRequestEnvelope.self, from: data) == HostRequestEnvelope(seq: 7, request: request))
        }
        let events: [HostEvent] = [
            .welcome(protocolVersion: 1, hostBuild: 123, sessions: [session]), .spawned(session), .attached(id: id),
            .screenText(id: id, text: "hi"), .historyText(id: id, history: "a\nb", screen: "c"),
            .sessionChanged(session), .sessionRemoved(id: id), .resync(id: id), .bell(id: id), .error("nope"), .ok,
        ]
        for event in events {
            let data = try HostCoding.encode(HostEventEnvelope(replyTo: 3, event: event))
            #expect(try HostCoding.decode(HostEventEnvelope.self, from: data) == HostEventEnvelope(replyTo: 3, event: event))
        }
    }

    @Test func liveMeansNotExited() {
        var session = HostSession(id: UUID(), tty: "ttys001", childPID: 1, cwd: "/", command: nil, label: "Shell",
                                  agent: nil, title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil)
        #expect(session.isLive)
        session.exit = .init(status: 1, at: Date())
        #expect(!session.isLive)
    }
}
