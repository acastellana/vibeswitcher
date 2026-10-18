import Foundation
import SwiftTerm
import Testing
@testable import VibeCore
@testable import VibeHost

/// Claude Code 2.1.302's screen at 120×40, fed to the host's headless terminal. Which is which:
///
/// Captured byte for byte from scratch PTYs (never a real session), the whole output replayed up to a moment
/// (`Capture`): `suggested`, a session after three one-word turns, its project's settings only plus
/// `promptSuggestionEnabled`; and `paintedCaret`, a logged-out session with a scratch HOME. Claude draws its
/// suggested next prompt faint (`ESC[2m…ESC[22m`, one run, spaces included), its placeholder faint too, a
/// `[Pasted text #N +M lines]` or `[Image #N]` pill plain like typed text. Either the terminal's cursor stands on
/// the box (`suggested`; the first letter shows inverted on screen, but that's the terminal) or Claude paints its
/// own caret, an inverted cell (`paintedCaret`: on the placeholder's first letter, after a pill).
/// `placeholder` and `typed` below are also captured, from a session's whole first frame, where Claude moves the
/// cursor between words (`ESC[<col>G`) instead of printing spaces.
///
/// Reconstructed, not captured: the 2026-10-17 incident's box. `incidentReplayed` is `suggested` with only the
/// suggestion's words swapped for the incident's; `incident`, `incidentNoCaret` and `typedCaretFirst` are
/// written by hand in a whole frame's encoding, `incident` with the caret painted on its first letter.
enum ClaudeScreens {
    static let e = "\u{1B}"
    static let rule = "\(e)[38;2;136;136;136m" + String(repeating: "─", count: 120) + "\(e)[39m"
    static let footer = "\(e)[3G\(e)[38;2;255;204;0m⏵⏵\(e)[6Gauto\(e)[11Gmode\(e)[16Gon\(e)[38;2;153;153;153m (shift+tab\(e)[30Gto"
        + "\(e)[33Gcycle)\(e)[101G◐\(e)[103Gmedium\(e)[110G·\(e)[112G/effort\(e)[39m"
    /// The end of the turn above the box.
    static let turn = "\(e)[38;2;255;255;255m⏺\(e)[3G\(e)[39mShould\(e)[10GI\(e)[12Gbring\(e)[18Gthe\(e)[22Gbranch\(e)[29Gup"
        + "\(e)[32Gto\(e)[35Gdate\(e)[40Gwith\(e)[45Gproject-lead\(e)[57Gmyself,\(e)[65Gor\(e)[68Gwill\(e)[73Gyou?\r\n\r\n"
        + "\(e)[38;2;153;153;153m✻\(e)[39m \(e)[38;2;153;153;153mCooked for 3s · done 9:41 PM\(e)[39m\r\n\r\n"

    static func idle(box: String) -> String { turn + rule + "\r\n❯\u{a0}" + box + "\r\n" + rule + "\r\n" + footer }

    /// Reconstructed: merges-name-the-failing's box after it asked the lead a question, with the caret painted.
    static let incident = idle(box: "\(e)[7mb\(e)[27m\(e)[2mring\(e)[9Gthe\(e)[13Gbranch\(e)[20Gup\(e)[23Gto\(e)[26Gdate"
                                    + "\(e)[31Gwith\(e)[36Gproject-lead\(e)[49Gyourself\(e)[22m")
    /// Reconstructed: the same, the terminal's cursor on the box.
    static let incidentNoCaret = idle(box: "\(e)[2mbring\(e)[9Gthe\(e)[13Gbranch\(e)[20Gup\(e)[23Gto\(e)[26Gdate"
                                           + "\(e)[31Gwith\(e)[36Gproject-lead\(e)[49Gyourself\(e)[22m")
    /// Captured: the placeholder in a new session's box.
    static let placeholder = idle(box: "\(e)[2mTry\(e)[7G\"how\(e)[12Gdoes\(e)[17G<filepath>\(e)[28Gwork?\"\(e)[22m")
    /// Captured: "hello draft" typed into the box.
    static let typed = idle(box: "hello\(e)[9Gdraft")
    /// Reconstructed: typed, with the caret painted back on its first character.
    static let typedCaretFirst = idle(box: "\(e)[7mh\(e)[27mello\(e)[9Gdraft")

    /// A scratch session's whole output, and the byte offsets of the moments the capture marked.
    struct Capture {
        let bytes: [UInt8]
        let marks: [String: Int]

        init(_ name: String, marks: [String: Int]) {
            let url = Bundle.module.url(forResource: name, withExtension: "raw", subdirectory: "Fixtures")!
            bytes = Array(try! Data(contentsOf: url))
            self.marks = marks
        }

        func upTo(_ mark: String) -> [UInt8] { Array(bytes[0..<marks[mark]!]) }
        func at(_ mark: String) -> LeadDelivery.Screen { ClaudeScreens.shown(upTo(mark)) }
    }

    /// Logged in: `turn1`–`turn3` the replies (apple, pear, plum); `suggestion` "Reply with only the word
    /// cherry."; `pasted` a 40-line paste; `pastedTyped` " and more" typed after it; `cleared` after ^C;
    /// `image` an image's path pasted.
    static let suggested = Capture("claude-2.1.302-suggestion", marks: [
        "ready": 1792, "turn3": 15941, "suggestion": 16026, "unfocused": 16038, "pasted": 16165, "pastedTyped": 16224,
        "cleared": 16462, "image": 16643, "end": 17381,
    ])
    /// Logged out, so no turn ends in a suggestion: `ready` the placeholder with the caret painted on it; `turn1`
    /// "Reply with only the word apple." sent; `pasted`, `cleared` and `image` as above.
    static let paintedCaret = Capture("claude-2.1.302-painted-caret", marks: [
        "ready": 4148, "turn1": 5808, "pasted": 7825, "cleared": 8010, "image": 8307,
    ])

    /// Reconstructed from `suggested`: the incident's suggestion drawn exactly as Claude drew cherry's.
    static var incidentReplayed: LeadDelivery.Screen {
        let drawn = String(decoding: suggested.bytes[suggested.marks["turn3"]!..<suggested.marks["suggestion"]!], as: UTF8.self)
        precondition(drawn.contains("\(e)[2mReply with only the word cherry.\(e)[22m"))
        let swapped = drawn.replacingOccurrences(of: "Reply with only the word cherry.", with: "bring the branch up to date with project-lead yourself")
        return shown(suggested.upTo("turn3") + Array(swapped.utf8))
    }

    static func shown(_ bytes: String) -> LeadDelivery.Screen { shown(Array(bytes.utf8)) }

    static func shown(_ bytes: [UInt8]) -> LeadDelivery.Screen {
        let terminal = Terminal(delegate: HeadlessDelegate(), options: TerminalOptions(cols: 120, rows: 40, scrollback: 100))
        terminal.feed(byteArray: bytes)
        let screen = HostedSession.styledScreen(of: terminal)
        return LeadDelivery.Screen(text: screen.text, runs: screen.runs)
    }
}

struct StyledScreenTests {
    let temp = Scratch()
    func scratch() -> URL {
        let root = temp.url("styled")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func theHostSaysWhatsDrawnFaint() {
        let screen = ClaudeScreens.shown(ClaudeScreens.incidentNoCaret)
        // Cells Claude skips over hold nothing (NUL), as on the plain screen.
        let lines = screen.text.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
        let row = lines.firstIndex { $0.hasPrefix("❯") }!
        #expect(lines[row].contains("bring the branch up to date with project-lead yourself"))
        let faint = screen.runs!.filter { $0.row == row && $0.faint }
        #expect(faint.first?.column == 2)
        // Word by word: Claude skips the cells between words, which stay plain.
        #expect(faint.map(\.length) == [5, 3, 6, 2, 2, 4, 4, 12, 8])
        // The text matches the plain screen's.
        let terminal = Terminal(delegate: HeadlessDelegate(), options: TerminalOptions(cols: 120, rows: 40, scrollback: 100))
        terminal.feed(byteArray: Array(ClaudeScreens.incidentNoCaret.utf8))
        let plain = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        #expect(screen.text == plain)
    }

    /// The incident: by its text the box held a draft, so the lead's answer waited in the inbox for good.
    @Test func claudesSuggestedPromptIsAnEmptyBox() {
        for bytes in [ClaudeScreens.incident, ClaudeScreens.incidentNoCaret, ClaudeScreens.placeholder] {
            #expect(LeadDelivery.box(in: ClaudeScreens.shown(bytes)) == .empty)
        }
        #expect(LeadDelivery.box(in: ClaudeScreens.shown(ClaudeScreens.incident).text) == .draft("bring the branch up to date with project-lead yourself"))
    }

    /// Captured: what Claude drew after a turn, focused or not, and again once ^C emptied the box.
    @Test func aCapturedSuggestionIsAnEmptyBox() {
        for mark in ["suggestion", "unfocused", "cleared", "end"] {
            #expect(LeadDelivery.box(in: ClaudeScreens.suggested.at(mark)) == .empty, "\(mark)")
        }
        let screen = ClaudeScreens.suggested.at("suggestion")
        let row = screen.text.components(separatedBy: "\n").lastIndex { $0.hasPrefix("❯") }!
        #expect(screen.runs?.filter { $0.row == row } == [ScreenRun(row: row, column: 2, length: 32, faint: true)])
        // By its text alone it's a draft: what held the incident's messages.
        #expect(LeadDelivery.box(in: screen.text) == .draft("Reply with only the word cherry."))
    }

    @Test func theIncidentDrawnAsClaudeDrawsASuggestionIsAnEmptyBox() {
        let screen = ClaudeScreens.incidentReplayed
        #expect(LeadDelivery.box(in: screen) == .empty)
        #expect(LeadDelivery.box(in: screen.text) == .draft("bring the branch up to date with project-lead yourself"))
    }

    /// Captured: a pasted text's or an image's pill is drawn plain, so a box holding only a pill holds a draft.
    @Test func aPillIsADraft() {
        for capture in [ClaudeScreens.suggested, ClaudeScreens.paintedCaret] {
            #expect(LeadDelivery.box(in: capture.at("pasted")) == .draft("[Pasted text #1 +39 lines]"))
            #expect(LeadDelivery.box(in: capture.at("image")) == .draft("[Image #2]"))
        }
        #expect(LeadDelivery.box(in: ClaudeScreens.suggested.at("pastedTyped")) == .draft("[Pasted text #1 +39 lines] and more"))
    }

    /// Captured: Claude's own caret painted on the placeholder's first letter, and alone in an empty box.
    @Test func aPaintedCaretIsntADraft() {
        let screen = ClaudeScreens.paintedCaret.at("ready")
        let row = screen.text.components(separatedBy: "\n").lastIndex { $0.hasPrefix("❯") }!
        #expect(screen.runs?.filter { $0.row == row }.prefix(2) == [ScreenRun(row: row, column: 2, length: 1, inverse: true),
                                                                     ScreenRun(row: row, column: 3, length: 2, faint: true)])
        #expect(LeadDelivery.box(in: screen) == .empty)
        #expect(LeadDelivery.box(in: ClaudeScreens.paintedCaret.at("cleared")) == .empty)
    }

    /// A wide character fills two cells, the second an empty character in the text: runs count cells, so what's
    /// drawn after it keeps its place.
    @Test func aWideCharacterBeforeTheSuggestion() {
        let e = ClaudeScreens.e
        let screen = ClaudeScreens.shown(ClaudeScreens.idle(box: "日本🙂\(e)[2m bring the branch up to date\(e)[22m"))
        let line = Array(screen.text.components(separatedBy: "\n").last { $0.hasPrefix("❯") }!)
        #expect(Array(line[2...5]) == ["日", "\u{0}", "本", "\u{0}"] && line[7] == "\u{0}")
        let faint = screen.runs!.filter(\.faint)
        #expect(faint.map(\.column) == [8] && faint.map(\.length) == [28])
        #expect(String(line[8..<36]) == " bring the branch up to date")
        // The empty cell after a wide character reads as a space, as on the plain screen (and SwiftTerm gives an
        // emoji's cell as a space).
        #expect(LeadDelivery.box(in: screen) == .draft("日 本"))
        #expect(LeadDelivery.box(in: ClaudeScreens.shown(ClaudeScreens.idle(box: "\(e)[2m日本 bring the branch\(e)[22m"))) == .empty)
    }

    @Test func typedTextIsADraft() {
        #expect(LeadDelivery.box(in: ClaudeScreens.shown(ClaudeScreens.typed)) == .draft("hello draft"))
        #expect(LeadDelivery.box(in: ClaudeScreens.shown(ClaudeScreens.typedCaretFirst)) == .draft("hello draft"))
    }

    @Test func messageTypesOverTheSuggestion() throws {
        for screen in [ClaudeScreens.incidentReplayed, ClaudeScreens.shown(ClaudeScreens.incident), ClaudeScreens.suggested.at("suggestion")] {
            let root = scratch()
            let agent = LeadAgent(pid: 7, tty: "ttys905", session: "s")
            var typed: [String] = []
            let delivered = try LeadDelivery.deliver("bring the branch up to date with project-lead yourself", from: .lead("lead of vibeswitcher"),
                                                     to: agent, activity: .idle(background: nil), styledScreen: { screen },
                                                     typeInto: { typed.append($0); return true }, root: root)
            #expect(delivered == .typed)
            #expect(typed.count == 1 && typed[0].hasSuffix("] bring the branch up to date with project-lead yourself"))
            #expect(SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
        }
    }

    @Test func messageWaitsBehindAPill() throws {
        let root = scratch()
        let agent = LeadAgent(pid: 7, tty: "ttys907", session: "s")
        var typed: [String] = []
        #expect(try LeadDelivery.deliver("a", from: .lead("lead"), to: agent, activity: .idle(background: nil),
                                         styledScreen: { ClaudeScreens.suggested.at("image") }, typeInto: { typed.append($0); return true },
                                         root: root) == .behindDraft("[Image #2]"))
        #expect(typed.isEmpty && SteerInbox.pending(tty: agent.tty, root: root).map(\.text) == ["a"])
    }

    @Test func messageStillWaitsBehindATypedDraft() throws {
        let root = scratch()
        let agent = LeadAgent(pid: 7, tty: "ttys906", session: "s")
        var typed: [String] = []
        let type: (String) -> Bool = { typed.append($0); return true }
        #expect(try LeadDelivery.deliver("a", from: .lead("lead"), to: agent, activity: .idle(background: nil),
                                         styledScreen: { ClaudeScreens.shown(ClaudeScreens.typed) }, typeInto: type, root: root)
                == .behindDraft("hello draft"))
        // clear_draft: one ^C empties the box, which may then show a suggestion again; the message goes in.
        var shown = ClaudeScreens.typed
        var cleared = 0
        #expect(try LeadDelivery.deliver("b", from: .lead("lead"), to: agent, activity: .idle(background: nil),
                                         styledScreen: { ClaudeScreens.shown(shown) }, typeInto: type, clearDraft: true,
                                         clear: { cleared += 1; shown = ClaudeScreens.incident; return true }, root: root) == .typed)
        #expect(cleared == 1 && typed.count == 1 && typed[0].hasSuffix("b"))
        #expect(SteerInbox.pending(tty: agent.tty, root: root).map(\.text) == ["a"])
    }
}

/// clear_draft against Claude's grey suggestion (genswap, 10-18: 8 refusals, 4 with clear_draft on, every one a
/// suggestion read through a session host too old to say what's dim).
struct ClearDraftTests {
    let temp = Scratch()
    func scratch() -> URL {
        let root = temp.url("clear")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The captured screen as an older host gives it: text only.
    func plain(_ screen: LeadDelivery.Screen) -> LeadDelivery.Screen { LeadDelivery.Screen(text: screen.text) }

    @Test func theCapturedSuggestionIsTypedOverOnAnOlderHost() throws {
        let root = scratch()
        let agent = LeadAgent(pid: 7, tty: "ttys908", session: "s")
        let shown = ClaudeScreens.suggested.at("suggestion")
        // The newer host says it's dim: the box is empty, nothing to clear.
        var typed: [String] = []
        #expect(try LeadDelivery.deliver("a", from: .lead("lead"), to: agent, activity: .idle(background: nil), styledScreen: { shown },
                                         typeInto: { typed.append($0); return true }, root: root) == .typed)
        // An older host shows it as text, and Claude draws it again after the ^C: typed over, once.
        #expect(LeadDelivery.box(in: plain(shown)) == .draft("Reply with only the word cherry."))
        var clears = 0
        #expect(try LeadDelivery.deliver("b", from: .lead("lead"), to: agent, activity: .idle(background: nil), styledScreen: { plain(shown) },
                                         typeInto: { typed.append($0); return true }, clearDraft: true,
                                         clear: { clears += 1; return true }, root: root) == .typed)
        #expect(clears == 1 && typed.count == 2 && typed[1].hasSuffix("] b"))
        // Without clear_draft it still waits, saying what it saw.
        #expect(try LeadDelivery.deliver("c", from: .lead("lead"), to: agent, activity: .idle(background: nil), styledScreen: { plain(shown) },
                                         typeInto: { typed.append($0); return true }, root: root) == .behindDraft("Reply with only the word cherry."))
    }

    /// A scratch program in a real host session draws Claude's box with a dim suggestion and draws it again on ^C;
    /// what's typed into it is written to a file.
    @Test func aScratchSessionsSuggestionIsClearedAndTypedOver() throws {
        let root = scratch()
        let typedFile = root.appendingPathComponent("typed").path
        let rule = String(repeating: "─", count: 40)
        let script = root.appendingPathComponent("box.sh").path
        try """
        draw() { printf '\\033[2J\\033[H* done\\r\\n%s\\r\\n\\342\\235\\257 \\033[2mopen rotate.html so I can try it\\033[22m\\r\\n%s\\r\\n' '\(rule)' '\(rule)'; }
        stty raw -echo
        draw
        while :; do
          c=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' ')
          if [ "$c" = "03" ]; then draw; echo cleared >> '\(typedFile).log'; else printf "\\x$c" >> '\(typedFile)'; fi
        done
        """.write(toFile: script, atomically: true, encoding: .utf8)
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("/bin/sh \(script)")
        let id = session.id
        let older = { () -> LeadDelivery.Screen? in
            if case .screenText(_, let text)? = try? HostCall.request(.screen(id: id), socket: host.socket) { return LeadDelivery.Screen(text: text) }
            return nil
        }
        #expect(eventually { older()?.text.contains("open rotate.html") == true })
        #expect(older().map(LeadDelivery.box(in:)) == .draft("open rotate.html so I can try it"))
        let typeInto = { (text: String) -> Bool in
            for write in ComposerText.writes(text, bracketed: true) {
                if write.delay > 0 { usleep(useconds_t(write.delay * 1_000_000)) }
                guard (try? HostCall.send(.input(id: id, bytes: Data(write.bytes), reply: false), socket: host.socket)) != nil else { return false }
            }
            return true
        }
        let agent = LeadAgent(pid: 7, tty: "ttys909", session: id.uuidString)
        let delivered = try LeadDelivery.deliver("go on with the tests", from: .lead("lead"), to: agent, activity: .idle(background: nil),
                                                 styledScreen: older, typeInto: typeInto, clearDraft: true, clear: {
            let sent = (try? HostCall.send(.input(id: id, bytes: Data(HostInput.bytes(forKey: "interrupt") ?? []), reply: false), socket: host.socket)) != nil
            usleep(300_000)
            return sent
        }, root: root)
        #expect(delivered == .typed)
        #expect(eventually { (try? String(contentsOfFile: typedFile, encoding: .utf8))?.contains("go on with the tests") == true })
        #expect((try? String(contentsOfFile: typedFile + ".log", encoding: .utf8)) == "cleared\n")
        // The host that says what's dim: the suggestion is an empty box, typed into without a ^C.
        let styled = try LeadDelivery.deliver("and then report", from: .lead("lead"), to: agent, activity: .idle(background: nil),
                                              styledScreen: { HostCall.styledScreen(id, socket: host.socket) }, typeInto: typeInto, root: root)
        #expect(styled == .typed)
        #expect(eventually { (try? String(contentsOfFile: typedFile, encoding: .utf8))?.contains("and then report") == true })
    }
}

/// Scratch programs only (`/bin/sh -c …`).
struct StyledScreenHostTests {
    @Test func theHostAnswersWithHowTheScreenIsDrawn() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("printf 'typed \\033[2mfaint\\033[22m\\n'; \(keepRunning)")
        var screen: LeadDelivery.Screen?
        #expect(eventually {
            screen = HostCall.styledScreen(session.id, socket: host.socket)
            return screen?.text.contains("faint") == true
        })
        let row = screen?.text.components(separatedBy: "\n").firstIndex { $0.hasPrefix("typed faint") }
        #expect(screen?.runs?.contains(ScreenRun(row: row ?? -1, column: 6, length: 5, faint: true)) == true)
        #expect(screen?.runs?.contains { $0.row == row && $0.column < 6 } == false)
    }

    /// A host older than `styledScreen` says it doesn't know the request: the plain screen is read.
    @Test func anOlderHostGivesThePlainScreen() throws {
        let path = scratchSocketPath()
        let listener = try UnixSocket.listen(path: path)
        // It answers every connection until the test is done (a busy Mac can make a call give up and ask again), and
        // closes its socket itself then, so it never accepts on a number handed out again since.
        let testDone = Flag()
        defer { testDone.set() }
        Thread.detachNewThread {
            defer {
                close(listener)
                unlink(path)
            }
            while !testDone.isSet {
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else {
                    usleep(5_000)
                    continue
                }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                func answer(_ seq: Int, _ event: HostEvent) {
                    guard let payload = try? HostCoding.encode(HostEventEnvelope(replyTo: seq, event: event)) else { return }
                    let frame = HostFrame.encode(.control, payload)
                    _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                }
                var decoder = HostFrameDecoder()
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var done = false
                while !done {
                    let count = read(fd, &buffer, buffer.count)
                    guard count > 0 else { break }
                    decoder.append(Data(buffer[0..<count]))
                    while let frame = try? decoder.next() {
                        guard let envelope = try? HostCoding.decode(HostRequestEnvelope.self, from: frame.payload) else { continue }
                        switch envelope.request {
                        case .hello: answer(envelope.seq, .welcome(protocolVersion: HostProtocol.version, hostBuild: 0, sessions: []))
                        case .styledScreen:
                            answer(envelope.seq, .error("This session host doesn't know that request; it may be older than the app."))
                            done = true
                        case .screen(let id):
                            answer(envelope.seq, .screenText(id: id, text: "❯ plain"))
                            done = true
                        default: break
                        }
                    }
                }
                // Closed once the caller has hung up: closing with its request unread could reset the answer away.
                while read(fd, &buffer, buffer.count) > 0 {}
                close(fd)
            }
        }
        // Each call gives up after its own 10 s; it's asked until one is answered.
        #expect(eventually { HostCall.styledScreen(UUID(), socket: path) == LeadDelivery.Screen(text: "❯ plain", runs: nil) })
    }
}

/// A flag set from one thread and read from another.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
