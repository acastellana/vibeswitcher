import Foundation
import SwiftTerm
import Testing
@testable import VibeCore
@testable import VibeHost

/// A parser's reply is typed only as a reply (`ParserReplies`; the stage 2 plan's Task 9e, the security architecture
/// document's S6): on Linux the host types a parser's `.reply` into a session only when it answers a query the host saw
/// in that session's output, in that query's reply grammar, one reply per query. Scratch programs only (`/bin/sh -c`).
@Suite(hostTestLimit) struct ParserReplyTests {
    /// A session's lines for the host's log (`onParserTrouble`), as the host would write them.
    final class Lines {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    /// A session of `command` whose parser takes the test hooks (`OSC 7599 ; reply:HEX` sends HEX as a reply), its
    /// output in `probe` and its log lines in `lines`.
    func start(_ command: String, probe: SessionProbe, lines: Lines) throws -> HostedSession {
        let request = SpawnRequest(cwd: scratchRoot.path, command: command, env: [:], cols: 80, rows: 24, keepShell: false, label: "Test", agent: nil)
        return try probe.queue.sync {
            let session = try HostedSession.spawn(request, shell: "/bin/sh", launcher: hostLauncher,
                                                  baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                                  ringCapacity: 1 << 20, queue: probe.queue, parser: ParserOptions(testHooks: true))
            probe.attach(session)
            session.onParserTrouble = { lines.add($0) }
            return session
        }
    }

    /// What `od -An -c` printed, without its spaces: `033[5;1R` for a cursor report.
    static func odBytes(_ text: String) -> String { text.filter { $0 != " " } }

    /// Whether `od -An -c` printed a cursor report in `text` (the login shell's greeting may have moved the cursor).
    static func hasCursorReport(_ text: String) -> Bool { odBytes(text).range(of: #"033\[[0-9]+;[0-9]+R"#, options: .regularExpression) != nil }

    // MARK: Sessions (Linux)

    /// A session's program asks where its cursor is and reads the report on its stdin, with no view attached.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's reply check; the Mac passes every reply"))
    func aCursorQueryIsAnswered() async throws {
        let probe = SessionProbe(), lines = Lines()
        let session = try start("stty raw -echo; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -An -c; echo done; stty sane; \(keepRunning)",
                                probe: probe, lines: lines)
        defer { probe.end(session) }
        #expect(await eventually { probe.text.contains("done") }, "\(probe.diagnosis(session))")
        #expect(Self.hasCursorReport(probe.text), "\(probe.diagnosis(session))")
        #expect(lines.all.isEmpty, "\(lines.all)")
    }

    /// A parser sends a reply its session never asked for (a test hook, as a parser bug would): nothing reaches the
    /// program, and the host's log says it was dropped. A scratch host's, so the line is the host's own log's.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's reply check; the Mac passes every reply"))
    func aReplyWithNoQueryIsNotTyped() async throws {
        let host = try await ScratchHostProcess(arguments: ["--parser-test-hooks"])
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        // The hook's reply is a cursor report, ESC [ 1 ; 1 R, typed with no query before it.
        let session = try await client.spawn("stty raw -echo; printf '\\033]7599;reply:1b5b313b3152\\007'; echo asked; "
            + "dd bs=1 count=1 2>/dev/null | od -An -c; echo done; stty sane; \(keepRunning)")
        defer {
            if kill(session.childPID, 0) == 0 { kill(-session.childPID, SIGKILL) }
            host.stop()
        }
        let log = { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }
        #expect(await eventually { log().contains("reply dropped, no cursor position query is pending") }, "\(log())\n\(host.log)")
        // The program still waits for its byte: the first it reads is the one typed now.
        #expect(client.screen(session.id)?.contains("done") == false)
        client.send(.input(id: session.id, bytes: Data("Z".utf8), reply: false))
        #expect(await eventually { client.screen(session.id)?.contains("done") == true })
        let screen = client.screen(session.id) ?? ""
        #expect(Self.odBytes(screen).contains("Z") && !screen.contains("033"), "\(screen)")
    }

    /// A parser sends `\r` and then text after a real query, before that query's own reply: both are dropped, the
    /// first said in the log as no reply at all, and the query's proper reply still passes.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's reply check; the Mac passes every reply"))
    func aReplyOutsideTheGrammarIsDropped() async throws {
        let probe = SessionProbe(), lines = Lines()
        // One write: the host reads the query with the hooks before them, so it is pending when they are sent.
        let session = try start("stty raw -echo; printf '\\033]7599;reply:0d\\007\\033]7599;reply:68656c6c6f\\007\\033[6n'; "
            + "dd bs=1 count=6 2>/dev/null | od -An -c; echo done; stty sane; \(keepRunning)", probe: probe, lines: lines)
        defer { probe.end(session) }
        #expect(await eventually { probe.text.contains("done") }, "\(probe.diagnosis(session))")
        #expect(Self.hasCursorReport(probe.text), "\(probe.diagnosis(session))")
        #expect(!probe.text.contains("h   e   l   l   o") && !probe.text.contains("\\r"), "\(probe.diagnosis(session))")
        #expect(lines.all.first?.contains("reply dropped, it is no reply: 1 bytes, \\x0d") == true, "\(lines.all)")
    }

    /// Another process writes a cursor query to the session's terminal (`/dev/pts/N`), with text after it: the
    /// program receives a cursor report and nothing else (S11 item 11's limit: a reply is still typed).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's reply check; the Mac passes every reply"))
    func aQueryWrittenToTheSessionsTerminalFromOutsideIsAnsweredOnlyAsAReply() async throws {
        let probe = SessionProbe(), lines = Lines()
        // The cursor home with "ready", in one write: the report is ESC [ 1 ; 1 R, six bytes.
        let session = try start("stty raw -echo; tty; printf 'ready\\033[H'; dd bs=1 count=6 2>/dev/null | od -An -c; echo first; "
            + "dd bs=1 count=1 2>/dev/null | od -An -c; echo second; stty sane; \(keepRunning)", probe: probe, lines: lines)
        defer { probe.end(session) }
        #expect(await eventually { probe.text.contains("ready") }, "\(probe.diagnosis(session))")
        let device = try #require(HostedSessionTests.devicePaths(in: probe.text).first, "\(probe.diagnosis(session))")
        let terminal = open(device, O_WRONLY | O_NOCTTY | O_CLOEXEC)
        try #require(terminal >= 0, "open \(device): errno \(errno)")
        let written = Array("\u{1b}[6nrm -rf typed\r\u{1b}]7599;reply:0d\u{07}".utf8)
        #expect(write(terminal, written, written.count) == written.count)
        close(terminal)
        #expect(await eventually { probe.text.contains("first") }, "\(probe.diagnosis(session))")
        #expect(Self.odBytes(probe.text).contains("033[1;1R"), "\(probe.diagnosis(session))")
        probe.queue.sync { _ = session.write(Data("Z".utf8)) }
        #expect(await eventually { probe.text.contains("second") }, "\(probe.diagnosis(session))")
        let afterFirst = probe.text.components(separatedBy: "first").last ?? ""
        #expect(Self.odBytes(afterFirst).hasPrefix("\nZ") || Self.odBytes(afterFirst).contains("Z\n"), "\(afterFirst.debugDescription)")
    }

    /// With a view attached that answers `ESC[6n` (the parser's reply skipped), the query is answered: a later
    /// parser reply of that kind, once no view is attached, is dropped.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's reply check; the Mac passes every reply"))
    func aQueryAnsweredByAClientIsNoLongerPending() async throws {
        let probe = SessionProbe(), lines = Lines()
        let session = try start("stty raw -echo; echo WAITING; dd bs=1 count=1 >/dev/null 2>&1; printf '\\033[6n'; echo asked; "
            + "dd bs=1 count=1 >/dev/null 2>&1; printf '\\033]7599;reply:1b5b313b3152\\007'; echo hooked; "
            + "dd bs=1 count=1 2>/dev/null | od -An -c; echo done; stty sane; \(keepRunning)", probe: probe, lines: lines)
        defer { probe.end(session) }
        #expect(await eventually { probe.text.contains("WAITING") }, "\(probe.diagnosis(session))")
        probe.queue.sync {
            session.clientsAttached = true
            _ = session.write(Data("g".utf8))
        }
        // Read off the output before "asked" was: pending once "asked" is seen, until the parser's skipped reply.
        #expect(await eventually { probe.text.contains("asked") }, "\(probe.diagnosis(session))")
        #expect(await eventually { probe.queue.sync { session.parserReplies.pending.isEmpty } })
        probe.queue.sync {
            session.clientsAttached = false
            _ = session.write(Data("g".utf8))
        }
        #expect(await eventually { lines.all.contains { $0.contains("reply dropped, no cursor position query is pending") } }, "\(lines.all)")
        probe.queue.sync { _ = session.write(Data("Z".utf8)) }
        #expect(await eventually { probe.text.contains("done") }, "\(probe.diagnosis(session))")
        let afterHook = probe.text.components(separatedBy: "hooked").last ?? ""
        #expect(Self.odBytes(afterHook).contains("Z") && !afterHook.contains("033"), "\(afterHook.debugDescription)")
    }

    // MARK: The table (both)

    /// The Mac's form: every reply goes in while no view is attached, none while one is, and no query is read.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's form; Linux checks replies"))
    func theMacsParserRepliesAreTodays() {
        var replies = ParserReplies()
        #expect(!replies.checks)
        replies.noteQueries(in: Data("\u{1b}[6n".utf8))
        #expect(replies.pending.isEmpty)
        #expect(replies.admit(Data("\r".utf8), from: 1, clientsAttached: false, log: nil) == Data("\r".utf8))
        #expect(replies.admit(Data("\u{1b}[1;1R".utf8), from: 1, clientsAttached: true, log: nil) == nil)
    }

    /// Each query SwiftTerm answers, fed to a headless terminal as the parser has it and to the host's scanner: the
    /// scanner sees as many queries as the terminal makes replies, each reply in the grammar of the query seen, so
    /// each passes once and no more. What SwiftTerm doesn't answer, or whose reply is left out, the scanner doesn't
    /// count.
    @Test func everyQueryIsAnsweredInItsGrammar() {
        let answered = [
            "\u{1b}[5n", "\u{1b}[6n", "\u{1b}[?6n", "\u{1b}[?15n", "\u{1b}[?25n", "\u{1b}[?26n", "\u{1b}[?55n", "\u{1b}[?56n",
            "\u{1b}[?62n", "\u{1b}[?63;7n", "\u{1b}[?75n", "\u{1b}[?85n", "\u{1b}[c", "\u{1b}[0c", "\u{1b}[>c", "\u{1b}[>0c",
            "\u{1b}[?25$p", "\u{1b}[?2004$p", "\u{1b}[4$p", "\u{1b}[20$p", "\u{1b}[?u", "\u{1b}P$qm\u{1b}\\", "\u{1b}P$qr\u{1b}\\",
            "\u{1b}P$q\"p\u{1b}\\", "\u{1b}P$q q\u{1b}\\", "\u{1b}P$qs\u{1b}\\", "\u{1b}P$qzz\u{1b}\\", "\u{1b}[>q", "\u{1b}[>0q",
            "\u{1b}[14t", "\u{1b}[14;2t", "\u{1b}[15t", "\u{1b}[16t", "\u{1b}[18t", "\u{1b}[19t", "\u{1b}]4;1;?\u{1b}\\",
            "\u{1b}]4;1;?;2;?\u{07}", "\u{1b}]10;?\u{07}", "\u{1b}]11;?\u{1b}\\", "\u{1b}]12;?\u{07}", "\u{1b}]10;?;?\u{07}",
            // 8-bit controls: the replies' CSI is one byte.
            "\u{1b} G\u{1b}[6n\u{1b} F",
        ]
        let notCounted = [
            "\u{1b}[1c", "\u{1b}[=c", "\u{1b}[>1q", "\u{1b}[?53n", "\u{1b}[7n", "\u{1b}[20t", "\u{1b}[21t", "\u{1b}]52;c;?\u{07}",
            "\u{1b}[1;1;1;1;1;1*y", "\u{1b}[6;1H", "\u{1b}]0;title\u{07}", "plain text, \u{1b}[1mbold\u{1b}[0m",
        ]
        for (queries, counted) in [(answered, true), (notCounted, false)] {
            for query in queries {
                let delegate = HeadlessDelegate()
                var made: [Data] = []
                delegate.onReply = { made.append($0) }
                let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24, scrollback: 10))
                terminal.feed(buffer: Array(query.utf8)[...])
                var replies = ParserReplies(checks: true)
                replies.noteQueries(in: Data(query.utf8))
                let seen = replies.pending.values.reduce(0, +)
                #expect(seen == (counted ? made.count : 0), "\(query.debugDescription): \(seen) seen, \(made.count) replies \(made.map(ParserReplies.shown))")
                #expect(!counted || !made.isEmpty, "\(query.debugDescription): no reply")
                var dropped: [String] = []
                for reply in made {
                    let typed = replies.admit(reply, from: 1, clientsAttached: false, log: { dropped.append($0) })
                    #expect(typed == (counted ? reply : nil), "\(query.debugDescription): \(ParserReplies.shown(reply)) \(dropped)")
                }
                // One reply per query: the same again is dropped.
                for reply in made { #expect(replies.admit(reply, from: 1, clientsAttached: false, log: nil) == nil) }
                #expect(replies.pending.isEmpty, "\(query.debugDescription): \(replies.pending)")
            }
        }
    }

    /// A query split between two reads is seen once its last byte is; an OSC's query too.
    @Test func aQuerySplitBetweenReadsIsSeen() {
        var replies = ParserReplies(checks: true)
        for piece in ["text \u{1b}", "[", "?", "6", "n more", "\u{1b}]1", "1;", "?\u{1b}", "\\"] {
            replies.noteQueries(in: Data(piece.utf8))
        }
        #expect(replies.pending == [.decCursor: 1, .dynamicColor(11): 1])
        // A CAN ends a sequence unanswered.
        replies.noteQueries(in: Data("\u{1b}[6\u{18}n".utf8))
        #expect(replies.pending == [.decCursor: 1, .dynamicColor(11): 1])
    }

    /// The host's log gets one line a second at most about dropped replies, saying how many went unsaid.
    @Test func droppedRepliesAreLoggedOnceASecond() {
        var replies = ParserReplies(checks: true)
        var lines: [String] = []
        for _ in 0..<3 { _ = replies.admit(Data("x".utf8), from: 7, clientsAttached: false, log: { lines.append($0) }) }
        #expect(lines == ["parser (pid 7) reply dropped, it is no reply: 1 bytes, x"])
    }

    /// Every responder in SwiftTerm (each `sendResponse` call and direct `tdel?.send(source:…)` in its
    /// `Sources/SwiftTerm/*.swift`, in the resolved checkout) is in `ParserReplies.swiftTermResponders`, as often as it
    /// occurs, with what it answers or why it's left out: a SwiftTerm bump that adds or changes one fails here first.
    @Test func everyResponderInSwiftTermIsListed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".build/checkouts/SwiftTerm/Sources/SwiftTerm")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }.sorted()
        try #require(files.contains("Terminal.swift"), "no SwiftTerm checkout at \(folder.path)")
        var found: [String: Int] = [:]
        for file in files {
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for site in Self.responderSites(in: source) { found[site, default: 0] += 1 }
        }
        var listed: [String: Int] = [:]
        for responder in ParserReplies.swiftTermResponders { listed[responder.site, default: 0] += responder.count }
        let unlisted = found.filter { listed[$0.key] != $0.value }.keys.sorted()
        let gone = listed.filter { found[$0.key] != $0.value }.keys.sorted()
        #expect(unlisted.isEmpty, "in SwiftTerm, not listed so often: \(unlisted)")
        #expect(gone.isEmpty, "listed, not in SwiftTerm so often: \(gone)")
        #expect(found.values.reduce(0, +) > 50)
    }

    /// Each `sendResponse(…)` call and `tdel?.send(…)` in `source` (not their definitions), its text without white
    /// space, read to its closing parenthesis past the strings in it and their interpolations.
    static func responderSites(in source: String) -> [String] {
        let text = Array(source.unicodeScalars)
        var sites: [String] = []
        var index = 0
        func matches(_ word: String, at position: Int) -> Bool {
            let scalars = Array(word.unicodeScalars)
            return position + scalars.count <= text.count && Array(text[position..<position + scalars.count]) == scalars
        }
        while index < text.count {
            guard let name = ["sendResponse", "tdel?.send"].first(where: { matches($0, at: index) }) else {
                index += 1
                continue
            }
            let start = index
            var position = index + name.unicodeScalars.count
            while position < text.count, text[position] == " " { position += 1 }
            let before = String(String.UnicodeScalarView(text[max(0, start - 12)..<start]))
            guard position < text.count, text[position] == "(", !before.hasSuffix("func "), !before.hasSuffix("func") else {
                index = position
                continue
            }
            // Parentheses counted outside strings; `\(` in a string opens an interpolation, back to the string at its `)`.
            var depth = 1, interpolations: [Int] = [], inString = false
            position += 1
            while position < text.count, depth > 0 {
                let scalar = text[position]
                if inString {
                    if scalar == "\\" {
                        if position + 1 < text.count, text[position + 1] == "(" {
                            interpolations.append(depth)
                            depth += 1
                            inString = false
                        }
                        position += 2
                        continue
                    }
                    if scalar == "\"" { inString = false }
                } else if scalar == "\"" {
                    inString = true
                } else if scalar == "(" {
                    depth += 1
                } else if scalar == ")" {
                    depth -= 1
                    if let last = interpolations.last, depth == last {
                        interpolations.removeLast()
                        inString = true
                    }
                }
                position += 1
            }
            sites.append(String(String.UnicodeScalarView(text[start..<position].filter { !$0.properties.isWhitespace })))
            index = position
        }
        return sites
    }
}
