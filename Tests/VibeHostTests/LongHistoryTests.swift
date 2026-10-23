import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A session's parser keeps `SessionParser.scrollback` lines above its screen (a SwiftTerm line costs 3-5 KB); more
/// history, the phone's scroll-back, is read on demand from the session's replay buffer (see `HistoryRead`), as far
/// back as the 5,000 lines the parser kept before.
@Suite(.serialized) struct LongHistoryTests {
    /// `count` numbered lines, "line 1" up.
    static func numbered(_ count: Int) -> String { "seq 1 \(count) | sed 's/^/line /'" }

    /// The numbers of `text`'s lines, in order; nil for a line that isn't "line N".
    static func numbers(_ text: String) -> [Int?] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("line ") ? Int(line.dropFirst(5)) : nil
        }
    }

    /// Whether `numbers` count up by one, with no gap and no other line.
    static func consecutive(_ numbers: [Int?]) -> Bool {
        let all = numbers.compactMap { $0 }
        return all.count == numbers.count && zip(all, all.dropFirst()).allSatisfy { $1 == $0 + 1 }
    }

    /// The session's parser itself: asked for 5,000 lines, it has its 200.
    @Test func aParserKeepsOnlyItsShortScrollback() throws {
        let queue = DispatchQueue(label: "test.parser")
        let link = try #require(ParserLink.start(launcher: hostLauncher, cols: 80, rows: 24, options: ParserOptions(), queue: queue))
        defer { queue.sync { _ = link.stop() } }
        let output = (1...1_000).map { "line \($0)\r\n" }.joined()
        let answered = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var view: ParserView?
        queue.async {
            link.feed(Data(output.utf8))
            link.view(historyLines: 5_000) {
                view = $0
                answered.signal()
            }
        }
        #expect(answered.wait(timeout: .now() + hangGuard) == .success)
        let history = try #require(view?.history)
        let numbers = Self.numbers(history)
        #expect(numbers.count == SessionParser.scrollback)
        #expect(Self.consecutive(numbers), "\(history.suffix(300))")
    }

    /// The phone's request (`.history`, 5,000 lines) after 10,000 printed lines gets the same 5,000 lines the parser
    /// kept before: the ones right above the screen, none missing. Its read's parser is gone afterwards.
    @Test func historyBeyondTheParsersLinesIsServed() throws {
        let host = try ScratchHostProcess()
        let (client, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try client.spawn("\(Self.numbered(10_000)); echo printed; \(keepRunning)")
        defer {
            kill(-session.childPID, SIGKILL)
            host.stop()
        }
        #expect(eventually { client.screen(session.id)?.contains("printed") == true })
        #expect(eventually { ParserCostTests.parsers(of: host.pid).count == 1 })
        let seq = client.send(.history(id: session.id, lines: 5_000))
        #expect(eventually { client.reply(to: seq) != nil })
        guard case .historyText(_, let history, let screen) = client.reply(to: seq) else { Issue.record("no history reply"); return }
        let numbers = Self.numbers(history)
        #expect(numbers.count == 5_000)
        #expect(Self.consecutive(numbers), "\(history.prefix(300))")
        // The screen goes on from the history's last line.
        let next = (numbers.last ?? nil).map { $0 + 1 } ?? 0
        #expect(screen.split(separator: "\n").first.map(String.init) == "line \(next)", "\(screen)")
        #expect(eventually { ParserCostTests.parsers(of: host.pid).count == 1 }, "the history read's parser is left")
    }

    /// Lines printed before a clear (Ctrl-L) or a full-screen pager or editor (the alternate screen) still come back,
    /// as they did from the long-lived parser's scrollback: the read takes all the replay buffer holds, not only what
    /// follows its last reset.
    @Test(arguments: ["\\033[2J\\033[H", "\\033[?1049hin the pager\\n\\033[?1049l"])
    func linesBeforeAClearOrAPagerComeBack(reset: String) throws {
        let host = try ScratchHostProcess()
        let (client, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try client.spawn("\(Self.numbered(1_000)); printf '\(reset)'; printf 'after-%s\\n' 1 2 3; echo after-done; \(keepRunning)")
        defer {
            kill(-session.childPID, SIGKILL)
            host.stop()
        }
        #expect(eventually { client.screen(session.id)?.contains("after-done") == true })
        let seq = client.send(.history(id: session.id, lines: 5_000))
        #expect(eventually { client.reply(to: seq) != nil })
        guard case .historyText(_, let history, _) = client.reply(to: seq) else { Issue.record("no history reply"); return }
        // The lines the clear wiped off the screen are gone, as in any terminal; those above it are all there.
        let numbers = Self.numbers(history).compactMap { $0 }
        #expect(numbers.first == 1, "\(history.prefix(300))")
        #expect(numbers.count > SessionParser.scrollback && Self.consecutive(numbers), "\(numbers.count) lines: \(history.suffix(300))")
    }

    /// An ended session keeps its last 500 lines, more than its parser had.
    @Test func anEndedSessionKeepsItsLast500Lines() throws {
        let probe = SessionProbe()
        let request = SpawnRequest(cwd: scratchRoot.path, command: "\(Self.numbered(1_000)); exit 0", env: [:], cols: 80, rows: 24,
                                   keepShell: false, label: "Test", agent: nil)
        let session = try probe.queue.sync {
            let session = try HostedSession.spawn(request, shell: "/bin/sh", launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin"],
                                                  ringCapacity: 1 << 20, queue: probe.queue)
            probe.attach(session)
            return session
        }
        #expect(eventually { probe.lastChange?.exit != nil })
        let history = probe.queue.sync { session.historyText(lines: HostedSession.endedHistoryLines).history }
        let numbers = Self.numbers(history)
        #expect(numbers.count == HostedSession.endedHistoryLines)
        #expect(Self.consecutive(numbers), "\(history.suffix(300))")
        #expect(!probe.queue.sync { session.holdsLiveResources })
    }

    /// A history read whose parser traps or stalls on the session's output (a test hook) gives the parser's own lines,
    /// once the read is given up on; its parser doesn't stay.
    @Test(arguments: ["trap", "stall"]) func aFailedReadFallsBackOnTheParsersLines(hook: String) throws {
        let host = try ScratchHostProcess(arguments: ["--parser-test-hooks", "--parser-stall-limit", "1"])
        let (client, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try client.spawn("\(Self.numbered(1_000)); printf '\\033]7599;\(hook)\\007'; echo after-hook; \(keepRunning)")
        defer {
            kill(-session.childPID, SIGKILL)
            host.stop()
        }
        let short = HostServer.short(session.id)
        func log() -> String { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }
        // The session's parser, broken by the hook too, was replaced (from the replay, without what it hadn't parsed).
        #expect(eventually { log().contains("watchdog: session \(short)'s parser") }, "\(log())")
        #expect(eventually { client.screen(session.id) != nil })
        let seq = client.send(.history(id: session.id, lines: 5_000))
        #expect(eventually { client.reply(to: seq) != nil })
        guard case .historyText(_, let history, _) = client.reply(to: seq) else { Issue.record("no history reply"); return }
        let numbers = Self.numbers(history)
        #expect((1...SessionParser.scrollback).contains(numbers.count), "\(numbers.count) lines")
        #expect(Self.consecutive(numbers), "\(history.suffix(300))")
        #expect(eventually { ParserCostTests.parsers(of: host.pid).count == 1 }, "the history read's parser is left")
    }
}
