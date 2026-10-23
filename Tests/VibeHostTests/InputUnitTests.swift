import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// `HostRequest.inputUnit` on a scratch host running a scratch program (never a real session): a unit's text and its
/// Enter go in together, whoever else types into the session meanwhile. Messaging audit 2026-10-22 #2: the app's
/// composer and the lead's tool server each wrote text, then Enter 60 ms later, on their own connections; at once,
/// that went text, text, Enter, Enter: one prompt, "first messagesecond message".
@Suite(.serialized)
struct InputUnitTests {
    let temp = Scratch()

    /// A session copying its lines, as the terminal hands them over (Enter ends one), to a file; returned once its
    /// terminal stopped echoing.
    func lineSession(_ client: TestClient) throws -> (session: HostSession, out: String) {
        let folder = temp.url("units")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent("out").path, ready = folder.appendingPathComponent("ready").path
        let session = try client.spawn("stty -echo && : > '\(ready)' && exec cat > '\(out)'")
        #expect(eventually { FileManager.default.fileExists(atPath: ready) })
        return (session, out)
    }

    static func lines(_ path: String) -> [String] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    static func unit(_ text: String) -> [HostInput.Write] {
        [HostInput.Write(bytes: Array(text.utf8), delay: 0), HostInput.Write(bytes: [13], delay: 0.06)]
    }

    @Test func unitsFromTwoClientsAtOnceGoInWhole() throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let (session, out) = try lineSession(app)
        let count = 12
        let app_ = (0..<count).map { "app message \($0)" }, tools = (0..<count).map { "tool server message \($0)" }
        // The app's units on its one connection, the tool server's each on a connection of its own (as `HostCall`).
        let done = DispatchGroup()
        var seqs: [Int] = [], typed = 0
        DispatchQueue.global().async(group: done) {
            seqs = app_.map { app.send(.inputUnit(id: session.id, writes: Self.unit($0), more: false)) }
        }
        DispatchQueue.global().async(group: done) {
            typed = tools.filter { (try? HostCall.type(Self.unit($0), into: session.id, socket: host.socket, timeout: hangGuard)) != nil }.count
        }
        #expect(done.wait(timeout: .now() + hangGuard) == .success)
        #expect(typed == count)
        #expect(eventually { seqs.allSatisfy { app.reply(to: $0) == .ok } })
        #expect(eventually { Self.lines(out).count >= 2 * count })
        let got = Self.lines(out)
        #expect(got.sorted() == (app_ + tools).sorted(), "\(got)")
        // Each sender's in the order it sent them.
        #expect(got.filter { $0.hasPrefix("app") } == app_)
        #expect(got.filter { $0.hasPrefix("tool") } == tools)
    }

    @Test func inputWaitsBehindAHeldUnitUntilItsEnterIsIn() throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let other = try TestClient(host, asApp: false)
        let (session, out) = try lineSession(app)
        // The app's unit, held between its text and its Enter (its sender reads the screen in between, say).
        let first = app.send(.inputUnit(id: session.id, writes: [HostInput.Write(bytes: Array("first".utf8), delay: 0)], more: true))
        #expect(eventually { app.reply(to: first) == .ok })
        // Meanwhile another client's keys and another's unit: neither goes in yet.
        try HostCall.send(.input(id: session.id, bytes: Data("second\r".utf8), reply: false), socket: host.socket, timeout: hangGuard)
        let third = other.send(.inputUnit(id: session.id, writes: Self.unit("third"), more: false))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(Self.lines(out).isEmpty)
        #expect(other.reply(to: third) == nil)
        let enter = app.send(.inputUnit(id: session.id, writes: [HostInput.Write(bytes: [13], delay: 0.06)], more: false))
        #expect(eventually { other.reply(to: third) == .ok })
        #expect(app.reply(to: enter) == .ok)
        #expect(eventually { Self.lines(out).count >= 3 })
        #expect(Self.lines(out) == ["first", "second", "third"])
    }

    @Test func aHeldUnitIsOverWhenItsSenderGoesOrNeverSendsTheRest() throws {
        let host = try TestHost(inputUnitHold: 0.5)
        let app = try TestClient(host)
        let (session, out) = try lineSession(app)
        // Its connection closed between the parts: the others' units go on at once.
        let gone = try TestClient(host)
        let half = gone.send(.inputUnit(id: session.id, writes: [HostInput.Write(bytes: Array("gone".utf8), delay: 0)], more: true))
        #expect(eventually { gone.reply(to: half) == .ok })
        gone.close()
        try HostCall.type(Self.unit(" next"), into: session.id, socket: host.socket, timeout: hangGuard)
        // What did go in stays typed, as a person's would: the next Enter takes it along.
        #expect(eventually { Self.lines(out) == ["gone next"] })
        // No next part within the hold: over, and the next unit goes in.
        let quiet = app.send(.inputUnit(id: session.id, writes: [HostInput.Write(bytes: Array("quiet".utf8), delay: 0)], more: true))
        #expect(eventually { app.reply(to: quiet) == .ok })
        let started = Date()
        try HostCall.type(Self.unit(" after"), into: session.id, socket: host.socket, timeout: hangGuard)
        #expect(Date().timeIntervalSince(started) > 0.4)
        #expect(eventually { Self.lines(out) == ["gone next", "quiet after"] })
        // A part with no writes ends a held unit at once (a sender whose check said no).
        let held = app.send(.inputUnit(id: session.id, writes: [HostInput.Write(bytes: Array("stopped".utf8), delay: 0)], more: true))
        #expect(eventually { app.reply(to: held) == .ok })
        let release = app.send(.inputUnit(id: session.id, writes: [], more: false))
        #expect(eventually { app.reply(to: release) == .ok })
        try HostCall.type(Self.unit(" last"), into: session.id, socket: host.socket, timeout: 0.4)
        #expect(eventually { Self.lines(out) == ["gone next", "quiet after", "stopped last"] })
    }

    /// Audit F1: input that waits behind another's unit was answered as taken (the screen read sent after it is its
    /// receipt) and only refused once the unit was over: the app's paced paste had gone on to its next piece, and
    /// the refused one was lost. What waits is counted against the session's room now, and refused before its receipt.
    @Test func inputBehindAUnitIsRefusedBeforeItsReceiptWhenThereIsNoRoom() throws {
        let host = try TestHost()
        let app = try TestClient(host)
        // A program that reads nothing.
        let session = try app.spawn(keepRunning)
        let holder = try TestClient(host, asApp: false)
        let held = holder.send(.inputUnit(id: session.id, writes: [HostInput.Write(bytes: Array("x".utf8), delay: 0)], more: true))
        #expect(eventually { holder.reply(to: held) == .ok })
        // A paste, as `HostClient` paces one: a piece, then a screen read for its receipt. Four fit the host's 1 MB.
        let piece = Data(repeating: 0x61, count: HostedSession.maxPendingInput / 4)
        let sent = (0..<5).map { _ in (input: app.send(.input(id: session.id, bytes: piece, reply: false)), receipt: app.send(.screen(id: session.id))) }
        #expect(eventually { sent.allSatisfy { app.reply(to: $0.receipt) != nil } })
        for (index, pair) in sent.enumerated() {
            guard index == 4 else {
                #expect(app.reply(to: pair.input) == nil, "piece \(index): \(String(describing: app.reply(to: pair.input)))")
                continue
            }
            guard case .error? = app.reply(to: pair.input), let refused = app.position(ofReplyTo: pair.input),
                  let receipt = app.position(ofReplyTo: pair.receipt) else {
                Issue.record("the fifth piece wasn't refused: \(String(describing: app.reply(to: pair.input)))")
                continue
            }
            #expect(refused < receipt)
        }
        // The unit over, what was taken goes in (to the host's buffer: the program still reads nothing), and none of
        // it is refused after its receipt.
        let release = holder.send(.inputUnit(id: session.id, writes: [], more: false))
        #expect(eventually { holder.reply(to: release) == .ok })
        let after = app.send(.screen(id: session.id))
        #expect(eventually { app.reply(to: after) != nil })
        Thread.sleep(forTimeInterval: InputOrder.unitGap + 0.2)
        #expect(sent.prefix(4).allSatisfy { app.reply(to: $0.input) == nil })
    }

    /// Re-audit F3: a refusal behind a unit with nothing of its own waiting (the session's buffer was full) left
    /// the order refusing for good: behind every later unit, plain input was refused with room for it.
    @Test func aRefusalBehindOneUnitDoesntRefuseInputBehindTheNext() throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let folder = temp.url("stale")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ready = folder.appendingPathComponent("ready").path, go = folder.appendingPathComponent("go").path
        // Reads nothing until `go` exists (its terminal raw: nothing of a paste is dropped unread), then everything.
        let session = try app.spawn("stty raw -echo && : > '\(ready)'; while [ ! -e '\(go)' ]; do sleep 0.05; done; exec cat > /dev/null")
        #expect(eventually { FileManager.default.fileExists(atPath: ready) })
        // The host's buffer for it full: the session itself refuses more until it drained.
        let big = Data(repeating: 0x61, count: 600 << 10)
        let fills = (0..<3).map { _ in app.send(.input(id: session.id, bytes: big, reply: false)) }
        let filled = app.send(.screen(id: session.id))
        #expect(eventually { app.reply(to: filled) != nil })
        #expect(fills.contains { if case .error? = app.reply(to: $0) { true } else { false } })
        // Behind unit A: refused (no room), with nothing of its own waiting.
        let holder = try TestClient(host, asApp: false)
        let a = holder.send(.inputUnit(id: session.id, writes: [], more: true))
        #expect(eventually { holder.reply(to: a) == .ok })
        let refused = app.send(.input(id: session.id, bytes: Data("r".utf8), reply: false))
        let told = app.send(.screen(id: session.id))
        #expect(eventually { app.reply(to: told) != nil })
        guard case .error? = app.reply(to: refused) else { Issue.record("not refused behind A: \(String(describing: app.reply(to: refused)))"); return }
        let endA = holder.send(.inputUnit(id: session.id, writes: [], more: false))
        #expect(eventually { holder.reply(to: endA) == .ok })
        // The program reads now, and the session's buffer drains: plain input goes in again.
        FileManager.default.createFile(atPath: go, contents: nil)
        #expect(eventually {
            let probe = app.send(.input(id: session.id, bytes: Data("p".utf8), reply: false)), receipt = app.send(.screen(id: session.id))
            guard eventually({ app.reply(to: receipt) != nil }) else { return false }
            return app.reply(to: probe) == nil
        })
        // Behind unit B, with room: taken, and never refused.
        let b = holder.send(.inputUnit(id: session.id, writes: [], more: true))
        #expect(eventually { holder.reply(to: b) == .ok })
        let behindB = app.send(.input(id: session.id, bytes: Data("y".utf8), reply: false))
        let receipt = app.send(.screen(id: session.id))
        #expect(eventually { app.reply(to: receipt) != nil })
        #expect(app.reply(to: behindB) == nil, "\(String(describing: app.reply(to: behindB)))")
        let endB = holder.send(.inputUnit(id: session.id, writes: [], more: false))
        #expect(eventually { holder.reply(to: endB) == .ok })
        Thread.sleep(forTimeInterval: InputOrder.unitGap + 0.2)
        #expect(app.reply(to: behindB) == nil)
    }

    @Test func anOlderHostGetsTheUnitAsPlainInput() throws {
        let host = try TestHost(capabilities: HostServer.capabilities.filter { $0 != HostProtocol.Capability.inputUnits })
        let app = try TestClient(host)
        let (session, out) = try lineSession(app)
        // Such a host doesn't take the request…
        let refused = app.send(.inputUnit(id: session.id, writes: Self.unit("not this"), more: false))
        #expect(eventually { app.reply(to: refused) != nil })
        guard case .error(let message)? = app.reply(to: refused) else { Issue.record("taken: \(String(describing: app.reply(to: refused)))"); return }
        #expect(message.contains("doesn't know that request"))
        // …and the tool server, seeing its welcome, types as before.
        try HostCall.type(Self.unit("the old way"), into: session.id, socket: host.socket, timeout: hangGuard)
        #expect(eventually { Self.lines(out) == ["the old way"] })
    }

    @Test func aUnitForASessionThatEndsIsAnError() throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let (session, _) = try lineSession(app)
        let held = app.send(.inputUnit(id: session.id, writes: [HostInput.Write(bytes: Array("held".utf8), delay: 0)], more: true))
        #expect(eventually { app.reply(to: held) == .ok })
        let other = try TestClient(host, asApp: false)
        let waiting = other.send(.inputUnit(id: session.id, writes: Self.unit("waits"), more: false))
        app.send(.kill(id: session.id))
        #expect(eventually { app.latest(session.id)?.isLive == false })
        let removed = app.send(.inputUnit(id: session.id, writes: [], more: false))
        #expect(eventually { app.reply(to: removed) != nil })
        app.send(.remove(id: session.id))
        #expect(eventually { other.reply(to: waiting) != nil })
        guard case .error? = other.reply(to: waiting) else { Issue.record("\(String(describing: other.reply(to: waiting)))"); return }
    }
}
