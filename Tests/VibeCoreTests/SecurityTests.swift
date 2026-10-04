import Foundation
import Testing
@testable import VibeCore

/// Findings from the security audit: typing that follows the focus away, sessions known only by tty,
/// secrets the masking missed, tab titles that forge other tabs, ambiguous request framing.
struct GuardedTypingTests {
    final class Recorder {
        var events: [String] = []
        var time: TimeInterval = 0
    }

    func chunks(_ count: Int) -> [[UInt16]] { (0..<count).map { [UInt16(65 + $0)] } }

    @Test func typesEverythingAndFinishesWhenFocusHolds() {
        let log = Recorder()
        let outcome = GuardedTyping.run(chunks: chunks(3), finish: [{ log.events.append("enter") }],
                                        stillFocused: { true }, stillFrontTab: { log.events.append("full"); return true },
                                        clock: { log.time }, fullCheckEvery: 0.4,
                                        post: { log.events.append("chunk\($0[0])") }, pause: { log.time += $0 })
        #expect(outcome == .done)
        #expect(log.events.filter { $0.hasPrefix("chunk") }.count == 3)
        // The front tab is checked again right before Enter.
        #expect(Array(log.events.suffix(2)) == ["full", "enter"])
    }

    @Test func stopsAsSoonAsTheFocusMovesAndNeverPressesEnter() {
        let log = Recorder()
        var checks = 0
        let outcome = GuardedTyping.run(chunks: chunks(5), finish: [{ log.events.append("enter") }],
                                        stillFocused: { checks += 1; return checks <= 2 }, stillFrontTab: { true },
                                        clock: { log.time }, fullCheckEvery: 0.4,
                                        post: { log.events.append("chunk\($0[0])") }, pause: { log.time += $0 })
        #expect(outcome == .stopped(typed: true))
        #expect(log.events == ["chunk65", "chunk66"])
    }

    @Test func aTabSwitchInsideTheSameWindowIsCaughtBeforeEnter() {
        // The cheap check (same window in front) can't see a tab switch; the full check before Enter can.
        let log = Recorder()
        let outcome = GuardedTyping.run(chunks: chunks(2), finish: [{ log.events.append("enter") }],
                                        stillFocused: { true }, stillFrontTab: { false },
                                        clock: { log.time }, fullCheckEvery: 10,
                                        post: { log.events.append("chunk\($0[0])") }, pause: { log.time += $0 })
        #expect(outcome == .stopped(typed: true))
        #expect(!log.events.contains("enter"))
    }

    @Test func longTextIsCheckedFullyAlongTheWay() {
        let log = Recorder()
        var full = 0
        _ = GuardedTyping.run(chunks: chunks(100), finish: [],
                              stillFocused: { true }, stillFrontTab: { full += 1; return true },
                              clock: { log.time }, fullCheckEvery: 0.2,
                              post: { _ in }, pause: { log.time += $0 })
        // 100 chunks × 10 ms = 1 s of typing: a full check at least every 0.2 s.
        #expect(full >= 4)
    }

    @Test func aKeyAloneIsStillCheckedFirst() {
        let log = Recorder()
        let outcome = GuardedTyping.run(chunks: [], finish: [{ log.events.append("escape") }],
                                        stillFocused: { true }, stillFrontTab: { false },
                                        clock: { log.time }, fullCheckEvery: 0.4, post: { _ in }, pause: { log.time += $0 })
        #expect(outcome == .stopped(typed: false))
        #expect(log.events.isEmpty)
    }

    @Test func chunksNeverSplitASurrogatePair() {
        let pieces = GuardedTyping.chunks("abcdefghijklmno😀xyz", size: 16)
        #expect(pieces.allSatisfy { !UTF16.isLeadSurrogate($0.last!) })
        #expect(String(decoding: pieces.flatMap { $0 }, as: UTF16.self) == "abcdefghijklmno😀xyz")
    }
}

struct SessionIdentityTests {
    @Test func aSessionIsItsProcessNotItsTTY() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let a = SessionIdentity.id(tty: "ttys004", pid: 4100, startedAt: start)
        #expect(a == SessionIdentity.id(tty: "ttys004", pid: 4100, startedAt: start))
        // A new agent in the same tab (or a reused tty) is another session.
        #expect(a != SessionIdentity.id(tty: "ttys004", pid: 4188, startedAt: start))
        #expect(a != SessionIdentity.id(tty: "ttys004", pid: 4100, startedAt: start.addingTimeInterval(5)))
        #expect(a != SessionIdentity.id(tty: "ttys005", pid: 4100, startedAt: start))
        #expect(a.count >= 12)
    }

    @Test func aRunningProcessIsRecognisedAndAReplacedOneIsNot() throws {
        let me = try #require(ProcessTable.info(pid: getpid()))
        #expect(SessionIdentity.isRunning(pid: me.pid, startedAt: me.startTime))
        #expect(!SessionIdentity.isRunning(pid: me.pid, startedAt: me.startTime.addingTimeInterval(-60)))
        #expect(!SessionIdentity.isRunning(pid: 999_999, startedAt: me.startTime))
    }
}

struct RedactionGapTests {
    @Test func privateKeysAreMaskedWhole() {
        let text = "here:\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\nAAAAMwAAAAtzc2gtZW\n-----END OPENSSH PRIVATE KEY-----\ndone"
        let masked = Redaction.secrets(in: text)
        #expect(!masked.contains("b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ"))
        #expect(!masked.contains("AAAAMwAAAAtzc2gtZW"))
        #expect(masked.hasPrefix("here:\n"))
        #expect(masked.hasSuffix("\ndone"))
        let rsa = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----"
        #expect(!Redaction.secrets(in: rsa).contains("MIIEow"))
    }

    @Test func quotedValuesAreMaskedToTheClosingQuote() {
        #expect(Redaction.secrets(in: #"password="two words here" next"#) == #"password="•••" next"#)
        #expect(Redaction.secrets(in: #"{"api_key": "abc def", "user": "me"}"#) == #"{"api_key": "•••", "user": "me"}"#)
        #expect(Redaction.secrets(in: "secret='a b'") == "secret='•••'")
        // Unquoted values still stop at the first space.
        #expect(Redaction.secrets(in: "TOKEN=abc123 rest") == "TOKEN=••• rest")
    }
}

struct AppleScriptStringsTests {
    @Test func parsesASourceFormListOfStrings() {
        let output = "{\"a\\\"b\", \"line1\nline2\", \"x\\\\y\", \"\u{1F}u\", \"\"}\n"
        #expect(AppleScriptStrings.parse(output) == ["a\"b", "line1\nline2", "x\\y", "\u{1F}u", ""])
        #expect(AppleScriptStrings.parse("{}") == [])
    }

    @Test func refusesAnythingElse() {
        #expect(AppleScriptStrings.parse("{\"a\", 3}") == nil)
        #expect(AppleScriptStrings.parse("{\"unterminated}") == nil)
        #expect(AppleScriptStrings.parse("\"a\"") == nil)
        #expect(AppleScriptStrings.parse("{\"a\"} trailing") == nil)
    }
}

struct TerminalTabRecordsTests {
    func record(_ tty: String, title: String = "zsh") -> [String] {
        ["101", "1", "/dev/\(tty)", "true", "1", "0, 0, 800, 600", "window", title]
    }

    @Test func eachTabIsEightFields() {
        let records = TerminalTabRecords.parse(record("ttys001") + record("ttys002", title: "with\nnewline\u{1F}and separators"))
        #expect(records?.map(\.tty) == ["ttys001", "ttys002"])
        #expect(records?.last?.title == "with\nnewline\u{1F}and separators")
        #expect(TerminalTabRecords.parse(Array(record("ttys001").prefix(7))) == nil)
    }

    @Test func aTTYListedTwiceIsDroppedAndBadOnesIgnored() {
        let records = TerminalTabRecords.parse(record("ttys001") + record("ttys002") + record("ttys001") + record("tty-bad"))
        #expect(records?.map(\.tty) == ["ttys002"])
    }
}

struct RequestFramingTests {
    let me = "Tailscale-User-Login: me@example.com\r\nCookie: vs_preview_8444=T\r\n"

    func decide(_ raw: String) -> PreviewGate.Decision {
        PreviewGate.decide(requestHead(raw), owner: "me@example.com", ownOrigin: "https://mac.example.ts.net:8444",
                           siblingOrigins: [], publicPort: 8444)
    }

    @Test func ambiguousBodiesAreRefused() {
        let bad = PreviewGate.Decision.reject(status: 400, message: PreviewGate.badRequestMessage)
        #expect(decide("POST / HTTP/1.1\r\n\(me)Content-Length: 5\r\nTransfer-Encoding: chunked\r\n") == bad)
        #expect(decide("POST / HTTP/1.1\r\n\(me)Content-Length: 5\r\nContent-Length: 6\r\n") == bad)
        #expect(decide("POST / HTTP/1.1\r\n\(me)Content-Length: 5, 6\r\n") == bad)
        #expect(decide("POST / HTTP/1.1\r\n\(me)Content-Length: -1\r\n") == bad)
        #expect(decide("POST / HTTP/1.1\r\n\(me)Transfer-Encoding: gzip, chunked\r\n") == bad)
        #expect(decide("POST / HTTP/1.1\r\n\(me)Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n") == bad)
        // The usual shapes pass.
        #expect(decide("POST / HTTP/1.1\r\n\(me)Content-Length: 5\r\n") == .forward(sessionToken: "T"))
        #expect(decide("POST / HTTP/1.1\r\n\(me)Transfer-Encoding: chunked\r\n") == .forward(sessionToken: "T"))
        #expect(decide("GET / HTTP/1.1\r\n\(me)") == .forward(sessionToken: "T"))
    }
}
