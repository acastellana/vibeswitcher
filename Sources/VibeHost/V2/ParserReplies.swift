import Foundation
import SwiftTerm
import VibeCore

/// A parser's reply is typed only as a reply (the stage 2 plan's Task 9e, S2-D5; the security architecture document's
/// S6, and S11 item 11).
///
/// While no view is attached the host types its headless terminal's answers to the program's queries into the
/// session (`SessionParser`'s `.reply`). On Linux it types one only when it answers a query the host itself saw in
/// that session's output since the last reply of its kind, and only in that kind's reply grammar, one reply per
/// query; anything else from a parser is dropped, and the host's log says so. So a parser bug can't type into the
/// lead, and a process that writes a query to a session's `/dev/pts/N` gets nothing typed into the session but a reply.
///
/// - **The queries** (`Kind`) are those SwiftTerm 1.19.0's headless terminal answers, read off its responders (each
///   `sendResponse` in `Terminal.swift`; `swiftTermResponders` lists every one with what it answers or why it's left
///   out, and `ParserReplyTests.everyResponderInSwiftTermIsListed` reads the checkout, so a SwiftTerm bump that adds
///   one fails there first). Left out, their replies dropped: OSC 52 (the clipboard), the title reports (`OSC l`,
///   `OSC L`), DECRQCRA, the kitty graphics replies, and the reports of what a user does (the mouse, clicks, typing),
///   which a headless terminal never has. The focus report is answered only as the terminal makes it unasked: when
///   the program turns focus events on (DECSET 1004, which Claude Code does as it starts), SwiftTerm, as xterm does,
///   says at once that it has focus (`CSI I`), one report per 1004 the setting names (found by the stage 2 plan's
///   Task 12a, with a real Claude Code).
/// - **The output** is read for queries as SwiftTerm's parser reads it (`QueryScanner`, its state table cut to what
///   finds a query), on the session's queue before the parser is fed, so a query is pending before its reply can come.
/// - **A view attached** answers the program's queries itself and the parser's replies are skipped, as before; a
///   skipped reply still ends its query's wait, so a later reply of that kind finds nothing pending.
/// - **The program status query** (`OSC 7501 ; ?`), which the host answers itself when its parser forwards it (views
///   don't speak it), is answered only as often as the output asked it too (`admits`).
/// - **A new parser** (a handover's, or one replacing a stalled one) is fed its replay quietly and answers none of
///   it: the scanner reads the same replay without counting (`prime`), so it is where the parser is, and nothing
///   asked before it is pending.
///
/// The Mac: none of it. Every reply goes in while no view is attached, as before (`checks` false).
struct ParserReplies {
    /// A query the headless terminal answers, by the reply it makes.
    enum Kind: Hashable, CustomStringConvertible {
        /// DSR 5 (`CSI 5 n`): `CSI 0 n`.
        case status
        /// CPR (`CSI 6 n`): `CSI row ; col R`.
        case cursor
        /// DECXCPR (`CSI ? 6 n`): `CSI ? row ; col ; 1 R`.
        case decCursor
        /// The other DEC device status reports (`CSI ? Ps n`, Ps one of `decReports`).
        case decReport(Int)
        /// DA1 (`CSI c`, `CSI 0 c`): `CSI ? Ps ; … c`.
        case primaryAttributes
        /// DA2 (`CSI > c`, `CSI > 0 c`): `CSI > Pp ; Pv ; Pc c`.
        case secondaryAttributes
        /// DECRQM for a DEC mode (`CSI ? Pa $ p`): `CSI ? Pa ; Ps $ y`.
        case decMode
        /// DECRQM for an ANSI mode (`CSI Pa $ p`): `CSI Pa ; Ps $ y`.
        case ansiMode
        /// The kitty keyboard protocol's query (`CSI ? u`): `CSI ? flags u`.
        case kittyKeyboard
        /// DECRQSS (`DCS $ q Pt ST`): `DCS Ps $ r Pt ST`.
        case statusString
        /// XTVERSION (`CSI > q`, `CSI > 0 q`): `DCS > | name ST`.
        case version
        /// A window report (`CSI 14 t`, `CSI 14 ; 2 t`, `CSI 15 t`, `CSI 16 t`, `CSI 18 t`, `CSI 19 t`), by the number
        /// its reply starts with (4, 5, 6, 8, 9): `CSI n ; a ; b t`.
        case window(Int)
        /// A palette colour (`OSC 4 ; n ; ? ST`): `OSC 4 ; n ; rgb:… ST`.
        case paletteColor
        /// The foreground, background or cursor colour (`OSC 10/11/12 ; ? ST`): `OSC code ; rgb:… ST`.
        case dynamicColor(Int)
        /// The program status feature query (`OSC 7501 ; ? …`), which the host answers itself (`ProgramStatus.queryReply`)
        /// when the parser forwards it: no parser's `.reply` is one.
        case programStatusQuery
        /// Focus events turned on (DECSET 1004, `CSI ? … 1004 … h`), which the terminal answers with the focus it has
        /// (`sendFocusReport`): `CSI I` (or `CSI O`).
        case focus

        var description: String {
            switch self {
            case .status: "device status"
            case .cursor: "cursor position"
            case .decCursor: "DEC cursor position"
            case .decReport(let number): "DEC status report \(number)"
            case .primaryAttributes: "device attributes"
            case .secondaryAttributes: "secondary device attributes"
            case .decMode: "DEC mode"
            case .ansiMode: "ANSI mode"
            case .kittyKeyboard: "kitty keyboard flags"
            case .statusString: "status string (DECRQSS)"
            case .version: "terminal version (XTVERSION)"
            case .window(let number): "window report \(number)"
            case .paletteColor: "palette colour"
            case .dynamicColor(let code): "colour \(code)"
            case .programStatusQuery: "program status"
            case .focus: "focus events (DECSET 1004)"
            }
        }
    }

    /// The `CSI ? Ps n` reports SwiftTerm answers (`cmdDeviceStatus`, beside 6), with each reply's grammar.
    static let decReports: [Int: String] = [
        15: #"\x1b\[\?10n"#, 25: #"\x1b\[\?21n"#, 26: #"\x1b\[\?27;1;0;0n"#, 55: #"\x1b\[\?53n"#, 56: #"\x1b\[\?57;1n"#,
        62: #"\x1b\[0\*\{"#, 63: #"\x1bP\d{1,9}!~0000\x1b\\"#, 75: #"\x1b\[\?70n"#, 85: #"\x1b\[\?83n"#,
    ]
    /// A window report's query (its parameters) to the number its reply starts with (`cmdWindowOptions`).
    static let windowReports: [[Int]: Int] = [[14]: 4, [14, 2]: 4, [15]: 5, [16]: 6, [18]: 8, [19]: 9]

    /// Each kind's reply grammar: a regular expression over the reply (C1 introducers written as their 7-bit forms),
    /// which must match it whole.
    static func grammar(_ kind: Kind) -> String {
        let rgb = "rgb:[0-9a-f]{4}/[0-9a-f]{4}/[0-9a-f]{4}"
        switch kind {
        case .status: return #"\x1b\[0n"#
        case .cursor: return #"\x1b\[\d{1,5};\d{1,5}R"#
        case .decCursor: return #"\x1b\[\?-?\d{1,5};\d{1,5};1R"#
        case .decReport(let number): return decReports[number] ?? "(?!)"
        case .primaryAttributes: return #"\x1b\[\?\d{1,3}(;\d{1,3}){0,15}c"#
        case .secondaryAttributes: return #"\x1b\[>\d{1,5};\d{1,5};\d{1,5}c"#
        case .decMode: return #"\x1b\[(\?\d{1,5})?;[0-4]\$y"#
        case .ansiMode: return #"\x1b\[(\d{1,5})?;[0-4]\$y"#
        case .kittyKeyboard: return #"\x1b\[\?\d{1,5}u"#
        // `DECRQSS.unhook`: what it reports of the margins, SGR, the cursor style and the conformance level.
        case .statusString: return #"\x1bP(0\$r|1\$r("q|65;1"p|\d{1,5};\d{1,5}[rs]|[0-9;:]{0,128}m?|\d q))\x1b\\"#
        // This build's own: the parser is this build's image (its SwiftTerm's `SwiftTermBuildInfo`, fixed at build time).
        case .version: return versionReply.isEmpty ? "(?!)" : NSRegularExpression.escapedPattern(for: String(decoding: versionReply, as: UTF8.self))
        case .window(let number): return #"\x1b\["# + String(number) + #";\d{1,6};\d{1,6}t"#
        case .paletteColor: return #"\x1b\]4;\d{1,3};"# + rgb + #"\x1b\\"#
        case .dynamicColor(let code): return #"\x1b\]"# + String(code) + ";" + rgb + #"\x1b\\"#
        case .programStatusQuery: return NSRegularExpression.escapedPattern(for: String(decoding: ProgramStatus.queryReply, as: UTF8.self))
        case .focus: return #"\x1b\[[IO]"#
        }
    }

    /// SwiftTerm's XTVERSION reply (`DCS > | identity ST`) in this build, asked of a headless terminal once.
    static let versionReply: Data = {
        let delegate = HeadlessDelegate()
        var made = Data()
        delegate.onReply = { made.append($0) }
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 2, rows: 2, scrollback: 0))
        terminal.feed(buffer: Array("\u{1b}[>q".utf8)[...])
        return made
    }()

    /// Each kind a parser's reply can be, its grammar compiled once (a seized parser's flood of replies is read on the
    /// queue every session shares).
    private static let patterns: [Kind: NSRegularExpression] = {
        let kinds: [Kind] = [.status, .cursor, .decCursor, .primaryAttributes, .secondaryAttributes, .decMode, .ansiMode,
                             .kittyKeyboard, .statusString, .version, .paletteColor, .dynamicColor(10), .dynamicColor(11),
                             .dynamicColor(12), .focus]
            + decReports.keys.map(Kind.decReport) + Set(windowReports.values).map(Kind.window)
        var patterns: [Kind: NSRegularExpression] = [:]
        for kind in kinds {
            patterns[kind] = try? NSRegularExpression(pattern: #"\A(?:"# + grammar(kind) + #")\z"#)
        }
        return patterns
    }()

    /// No reply is longer (the longest grammar's is under 200 bytes, but for XTVERSION's, this build's own).
    static let longestReply = max(256, versionReply.count)

    /// Every kind a reply could be, by `grammar` (of those in `among`, if given): none for a reply outside every
    /// grammar (`CSI ; 0 $ y`, a mode report with no mode, is both modes').
    static func kinds(ofReply reply: Data, among: Set<Kind>? = nil) -> [Kind] {
        guard reply.count <= longestReply else { return [] }
        // The terminal may have been told to send 8-bit controls (S8C1T): CSI, DCS, OSC and ST as one byte each.
        var bytes: [UInt8] = []
        for byte in reply {
            switch byte {
            case 0x9b: bytes += [0x1b, 0x5b]
            case 0x90: bytes += [0x1b, 0x50]
            case 0x9d: bytes += [0x1b, 0x5d]
            case 0x9c: bytes += [0x1b, 0x5c]
            case 0x80...: return []
            default: bytes.append(byte)
            }
        }
        let candidates = candidates(for: bytes).filter { among?.contains($0) ?? true }
        guard !candidates.isEmpty else { return [] }
        let text = String(decoding: bytes, as: UTF8.self)
        return candidates.filter { kind in
            guard let pattern = patterns[kind] else { return false }
            return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// The kinds whose grammar a reply could match, by its first bytes.
    private static func candidates(for bytes: [UInt8]) -> [Kind] {
        guard bytes.count >= 3, bytes[0] == 0x1b else { return [] }
        switch bytes[1] {
        case 0x5b:
            return [.status, .cursor, .decCursor, .primaryAttributes, .secondaryAttributes, .decMode, .ansiMode, .kittyKeyboard, .focus]
                + decReports.keys.sorted().map(Kind.decReport) + Set(windowReports.values).sorted().map(Kind.window)
        case 0x50: return [.statusString, .version, .decReport(63)]
        case 0x5d: return [.paletteColor, .dynamicColor(10), .dynamicColor(11), .dynamicColor(12)]
        default: return []
        }
    }

    // MARK: A session's queries and its parser's replies

    /// Whether replies are checked: on Linux.
    let checks: Bool
    /// The queries seen and not yet answered, by kind.
    private(set) var pending: [Kind: Int] = [:]
    private var scanner = QueryScanner()
    /// The host's log gets a line a second at most about dropped replies: when the last went, and how many since.
    private var lastLogged = Date.distantPast
    private var unlogged = 0

    init(checks: Bool = !Platform.CodeIdentity.isAvailable) {
        self.checks = checks
    }

    /// The program printed `chunk`: its queries are pending from now (on Linux).
    mutating func noteQueries(in chunk: Data) {
        guard checks else { return }
        scanner.scan(chunk) { pending[$0, default: 0] += 1 }
    }

    /// A new parser is fed `replay` quietly (on Linux): the scanner reads it afresh too, counting none of its queries,
    /// so it ends where the parser does, and nothing asked before is pending (the new parser answers none of it).
    mutating func prime(with replay: Data) {
        guard checks else { return }
        scanner = QueryScanner()
        scanner.scan(replay) { _ in }
        pending = [:]
    }

    /// What of a parser's reply goes into the session: the reply, or nil. The Mac: the reply while no view is attached,
    /// as before. On Linux, also only when it is in the grammar of a kind with a query pending, which it then answers
    /// (with a view attached too, though it isn't typed then); otherwise a line for the host's log (`log`, the
    /// session's parser trouble) says it was dropped. `parser`: its pid, for that line.
    mutating func admit(_ reply: Data, from parser: pid_t, clientsAttached: Bool, log: ((String) -> Void)?) -> Data? {
        guard checks else { return clientsAttached ? nil : reply }
        // Only the kinds pending are matched (none: no matching at all); why a reply went is worked out for the log only.
        guard let kind = Self.kinds(ofReply: reply, among: Set(pending.keys)).first else {
            dropped(log: log) {
                let kinds = Self.kinds(ofReply: reply)
                let why = kinds.isEmpty ? "it is no reply" : "no \(kinds[0]) query is pending"
                return "parser (pid \(parser)) reply dropped, \(why): \(Self.shown(reply))"
            }
            return nil
        }
        answered(kind)
        return clientsAttached ? nil : reply
    }

    /// Whether the host answers a parser's program status report (`ProgramStatus.Report`). The Mac: always, as before.
    /// On Linux a query (`OSC 7501 ; ?`), which the host answers by typing `ProgramStatus.queryReply`, with a view
    /// attached too, only when it answers one pending in the output, once per query; otherwise a line for the host's
    /// log says it was dropped. A status report types nothing and goes through.
    mutating func admits(_ report: ProgramStatus.Report, from parser: pid_t, log: ((String) -> Void)?) -> Bool {
        guard checks, case .query = report else { return true }
        guard pending[.programStatusQuery] != nil else {
            dropped(log: log) {
                "parser (pid \(parser)) reply dropped, no \(Kind.programStatusQuery) query is pending: the host's answer, "
                    + Self.shown(ProgramStatus.queryReply)
            }
            return false
        }
        answered(.programStatusQuery)
        return true
    }

    /// One query of `kind`'s is answered: it waits no more.
    private mutating func answered(_ kind: Kind) {
        let left = pending[kind, default: 0] - 1
        pending[kind] = left > 0 ? left : nil
    }

    /// `line` goes to the log only once a second at most: it is made only then.
    private mutating func dropped(log: ((String) -> Void)?, now: Date = Date(), _ line: () -> String) {
        guard now.timeIntervalSince(lastLogged) >= 1 else {
            unlogged += 1
            return
        }
        let more = unlogged > 0 ? " (and \(unlogged) more dropped since the last line)" : ""
        lastLogged = now
        unlogged = 0
        log?(line() + more)
    }

    /// A reply for the log: printable ASCII as it is, ESC as `ESC`, any other byte in hex; at most 64 bytes.
    static func shown(_ reply: Data) -> String {
        let shown = reply.prefix(64).map { byte -> String in
            switch byte {
            case 0x1b: return "ESC"
            case 0x20..<0x7f: return String(UnicodeScalar(byte))
            default: return String(format: "\\x%02x", byte)
            }
        }.joined()
        return "\(reply.count) bytes, " + shown + (reply.count > 64 ? "…" : "")
    }

    // MARK: Test hooks

    /// What a parser with test hooks (`--parser-test-hooks`, a scratch host's tests only) sends when the program
    /// prints `OSC 7599 ; reply:HEX` (a reply) or `OSC 7599 ; status:HEX` (a program status payload): the bytes HEX
    /// names, as a parser bug or a seized parser would.
    static func testFrame(_ payload: ArraySlice<UInt8>) -> (frame: SessionParser.FromParser, bytes: Data)? {
        let text = String(decoding: payload, as: UTF8.self)
        for (prefix, frame) in [("reply:", SessionParser.FromParser.reply), ("status:", .programStatus)] where text.hasPrefix(prefix) {
            return testBytes(text.dropFirst(prefix.count)).map { (frame, $0) }
        }
        return nil
    }

    private static func testBytes(_ text: Substring) -> Data? {
        let hex = Array(text)
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    // MARK: SwiftTerm's responders

    /// What each of SwiftTerm 1.19.0's responders is to this table: every `sendResponse` call and every direct
    /// `tdel?.send(source:…)` in `Sources/SwiftTerm/*.swift`, its text without white space, how many times it occurs
    /// there, and the kinds it answers, or why it is left out (its replies are dropped).
    enum Responder {
        case answers([Kind])
        case leftOut(String)
    }

    static let swiftTermResponders: [(site: String, count: Int, use: Responder)] = [
        (#"sendResponse(cc.CSI,"0n")"#, 1, .answers([.status])),
        (#"sendResponse(cc.CSI,"\(y);\(x)R")"#, 1, .answers([.cursor])),
        (#"sendResponse(cc.CSI,"?\(y);\(x);1R")"#, 1, .answers([.decCursor])),
        (#"sendResponse(cc.CSI,"?10n")"#, 1, .answers([.decReport(15)])),
        (#"sendResponse(cc.CSI,"?21n")"#, 1, .answers([.decReport(25)])),
        (#"sendResponse(cc.CSI,"?27;1;0;0n")"#, 1, .answers([.decReport(26)])),
        (#"sendResponse(cc.CSI,"?53n")"#, 1, .answers([.decReport(55)])),
        (#"sendResponse(cc.CSI,"?57;1n")"#, 1, .answers([.decReport(56)])),
        (#"sendResponse(cc.CSI,"0*{")"#, 1, .answers([.decReport(62)])),
        (#"sendResponse(cc.DCS,"\(id)!~0000",cc.ST)"#, 1, .answers([.decReport(63)])),
        (#"sendResponse(cc.CSI,"?70n")"#, 1, .answers([.decReport(75)])),
        (#"sendResponse(cc.CSI,"?83n")"#, 1, .answers([.decReport(85)])),
        (#"sendResponse(cc.CSI,"?\(termVt525)\(sixel);\(cols132);\(printer);\(decsera);\(horizontalScrolling);\(ansiColor);\(terminalStateInterrogation);\(rectangularEditing)c")"#,
         1, .answers([.primaryAttributes])),
        (#"sendResponse(cc.CSI,"?\(cols132);\(printer)c")"#, 1, .answers([.primaryAttributes])),
        (#"sendResponse(cc.CSI,"?\(decsera)c")"#, 1, .answers([.primaryAttributes])),
        (#"sendResponse(cc.CSI,">\(vt525);20;\(kbd)c")"#, 1, .answers([.secondaryAttributes])),
        // `cmdSendDeviceAttributes`' second `>` branch, past the first one's return: never reached.
        (#"sendResponse(cc.CSI,">0;276;0c")"#, 1, .answers([.secondaryAttributes])),
        (#"sendResponse(cc.CSI,">85;95;0c")"#, 1, .answers([.secondaryAttributes])),
        (#"sendResponse(cc.CSI,">83;40003;0c")"#, 1, .answers([.secondaryAttributes])),
        (#"sendResponse("\(pars[0])c")"#, 1, .leftOut("the linux console's DA2 echo, unreached (after the first `>` branch's return), no escape")),
        (#"sendResponse(cc.CSI,"?\(mode);\(res)$y")"#, 1, .answers([.decMode])),
        (#"sendResponse(cc.CSI,"\(mode);\(res)$y")"#, 1, .answers([.ansiMode])),
        (#"sendResponse(cc.CSI,";0$y")"#, 1, .answers([.decMode, .ansiMode])),
        (#"sendResponse(cc.CSI,"?\(keyboardEnhancementFlags.rawValue)u")"#, 1, .answers([.kittyKeyboard])),
        (#"sendResponse(terminal.cc.DCS,"\(ok)$r\(result)",terminal.cc.ST)"#, 1, .answers([.statusString])),
        (#"sendResponse([ControlCodes.ESC,UInt8(ascii:"P")],">|\(identity)",[ControlCodes.ESC,UInt8(ascii:"\\")])"#,
         1, .answers([.version])),
        // `cmdWindowOptions`: the delegate's own answer first (none from the host's `HeadlessDelegate`), else these.
        (#"sendResponse(r)"#, 6, .answers([.window(4), .window(5), .window(6), .window(8), .window(9)])),
        (#"sendResponse(cc.CSI,"4;\(rows*cellSize.height);\(cols*cellSize.width)t")"#, 2, .answers([.window(4)])),
        (#"sendResponse(cc.CSI,"5;\(rows*cellSize.height);\(cols*cellSize.width)t")"#, 1, .answers([.window(5)])),
        (#"sendResponse(cc.CSI,"6;\(cellSize.height);\(cellSize.width)t")"#, 1, .answers([.window(6)])),
        (#"sendResponse(cc.CSI,"6;16;10t")"#, 1, .answers([.window(6)])),
        (#"sendResponse(cc.CSI,"8;\(rows);\(cols)t")"#, 1, .answers([.window(8)])),
        (#"sendResponse(cc.CSI,"9;\(rows);\(cols)t")"#, 1, .answers([.window(9)])),
        (#"sendResponse(cc.OSC,"4;\(color);\(ansiColors[color].formatAsXcolor())",cc.ST)"#, 1, .answers([.paletteColor])),
        (#"sendResponse(cc.OSC,"\(oscCode);\(color.formatAsXcolor())",cc.ST)"#, 1,
         .answers([.dynamicColor(10), .dynamicColor(11), .dynamicColor(12)])),
        (#"sendResponse(cc.OSC,"52;\(selectionChars);\(base64)",cc.ST)"#, 1, .leftOut("OSC 52, the clipboard")),
        (#"sendResponse(cc.OSC,"L",cc.ST)"#, 1, .leftOut("the icon title report (CSI 20 t)")),
        (#"sendResponse(cc.OSC,"l",cc.ST)"#, 1, .leftOut("the window title report (CSI 21 t)")),
        (#"sendResponse(cc.DCS,"\(rid)!~\(result)",cc.ST)"#, 1, .leftOut("DECRQCRA, a checksum of the screen")),
        (#"sendResponse(cc.APC,"\(controlData);OK",cc.ST)"#, 1, .leftOut("kitty graphics")),
        (#"sendResponse(cc.APC,"\(controlData);\(message)",cc.ST)"#, 1, .leftOut("kitty graphics")),
        (#"sendResponse(cc.CSI,"M",[UInt8(min(buttonFlags+32,255)),UInt8(min(32+x+1,255)),UInt8(min(32+y+1,255))])"#,
         1, .leftOut("a mouse report: a user's, never a headless terminal's")),
        (#"sendResponse(cc.CSI,"<\(bflags);\(x+1);\(y+1)\(m)")"#, 1, .leftOut("a mouse report")),
        (#"sendResponse(cc.CSI,"<\(bflags);\(pixelX);\(pixelY)\(m)")"#, 1, .leftOut("a mouse report")),
        (#"sendResponse(cc.CSI,"\(buttonFlags+32);\(x+1);\(y+1)M")"#, 1, .leftOut("a mouse report")),
        (#"sendResponse(cc.CSI,buffer)"#, 1, .leftOut("a mouse report")),
        (#"sendResponse("\u{1b}[<0;\(x);\(y)M")"#, 1, .leftOut("a semantic prompt's click: a user's")),
        (#"tdel?.send(source:self,data:data[...])"#, 1, .leftOut("a semantic prompt's click: a user's")),
        // `sendFocusReport`: a view's focus changing (never in a headless terminal), and DECSET 1004's report at once.
        (#"tdel?.send(source:self,data:data[0...])"#, 1, .answers([.focus])),
        (#"tdel?.send(source:self,data:data)"#, 1, .leftOut("a user's input (`sendUserInput`)")),
        (#"tdel?.send(source:self,data:([UInt8](text.utf8))[...])"#, 1, .leftOut("`sendResponse`'s own body")),
        (#"tdel?.send(source:self,data:buffer[...])"#, 1, .leftOut("`sendResponse`'s own body")),
    ]
}

/// A session's output read for the queries `ParserReplies.Kind` names, as SwiftTerm 1.19.0's parser reads it
/// (`EscapeSequenceParser`'s state table: its states, its "anywhere" rules, a CSI's parameters and collected bytes,
/// where an OSC or a DCS ends), cut to what finds a query; everything else passes by. Its state carries across chunks,
/// so a query split between two reads is still seen.
struct QueryScanner {
    private enum State {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case osc, apc, sosPmApc
        case dcsEntry, dcsParam, dcsIntermediate, dcsIgnore, dcsPassthrough
    }

    private var state = State.ground
    private var pars: [Int] = [0]
    private var collect: [UInt8] = []
    private var tooManyParameters = false
    private var osc: [UInt8] = []
    private var oscTooLong = false
    /// The DCS under way is a DECRQSS (`DCS $ q`): it is answered as it ends.
    private var statusString = false

    /// SwiftTerm's `maximumParameterCount`.
    static let maximumParameters = 24
    /// An OSC this long is no query of ours: its bytes aren't kept.
    static let maximumOSC = 4096

    /// Reads `chunk`, calling `found` with each query it completes.
    mutating func scan(_ chunk: Data, _ found: (ParserReplies.Kind) -> Void) {
        chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            while index < bytes.count {
                // SwiftTerm's ground state prints everything above 0x1f, and only ESC (and CAN, SUB: still ground)
                // leaves it.
                if state == .ground {
                    guard let escape = bytes[index...].firstIndex(of: 0x1b) else { return }
                    index = escape
                }
                step(bytes[index], found)
                index += 1
            }
        }
    }

    private mutating func clear() {
        pars = [0]
        collect = []
        tooManyParameters = false
        osc = []
        oscTooLong = false
        statusString = false
    }

    private mutating func step(_ byte: UInt8, _ found: (ParserReplies.Kind) -> Void) {
        // The ends of an OSC or a DCS, before the rules every state has.
        switch state {
        case .osc where [0x07, 0x1b, 0x9c, 0x18, 0x1a].contains(byte):
            if byte != 0x18, byte != 0x1a, !oscTooLong { oscEnded(found) }
            state = .ground
        case .apc where [0x07, 0x1b, 0x9c, 0x18, 0x1a].contains(byte):
            state = .ground
        case .dcsPassthrough where byte == 0x1b || byte == 0x9c:
            if statusString { found(.statusString) }
            state = .ground
        default:
            break
        }
        // Everywhere: ESC begins a sequence, CAN and SUB end one, and the C1 controls begin or end theirs.
        switch byte {
        case 0x1b:
            clear()
            state = .escape
            return
        case 0x18, 0x1a, 0x80...0x8f, 0x91...0x97, 0x99, 0x9a, 0x9c:
            if state != .ground { clear() }
            state = .ground
            return
        case 0x9b:
            clear()
            state = .csiEntry
            return
        case 0x90:
            clear()
            state = .dcsEntry
            return
        case 0x9d:
            clear()
            state = .osc
            return
        case 0x9f:
            clear()
            state = .apc
            return
        case 0x98, 0x9e:
            state = .sosPmApc
            return
        default:
            break
        }
        switch state {
        case .ground:
            return
        case .escape:
            switch byte {
            case 0x5b: clear(); state = .csiEntry
            case 0x5d: clear(); state = .osc
            case 0x50: clear(); state = .dcsEntry
            case 0x5f: state = .apc
            case 0x58, 0x5e: state = .sosPmApc
            case 0x20...0x2f: state = .escapeIntermediate
            case 0x30...0x7e: state = .ground
            default: return
            }
        case .escapeIntermediate:
            if (0x30...0x7e).contains(byte) { state = .ground }
        case .csiEntry, .csiParam:
            switch byte {
            case 0x30...0x39, 0x3b: parameter(byte); state = .csiParam
            case 0x3a: if state == .csiParam { parameter(byte) } else { state = .ground }
            case 0x3c...0x3f: if state == .csiEntry { collect.append(byte); state = .csiParam } else { state = .csiIgnore }
            case 0x20...0x2f: collect.append(byte); state = .csiIntermediate
            case 0x40...0x7e:
                if !tooManyParameters { Self.queries(final: byte, collect: collect, pars: pars).forEach(found) }
                state = .ground
            case 0xa0...: state = .ground
            default: return
            }
        case .csiIntermediate:
            switch byte {
            case 0x20...0x2f: collect.append(byte)
            case 0x30...0x3f: state = .csiIgnore
            case 0x40...0x7e:
                if !tooManyParameters { Self.queries(final: byte, collect: collect, pars: pars).forEach(found) }
                state = .ground
            case 0xa0...: state = .ground
            default: return
            }
        case .csiIgnore:
            if (0x40...0x7e).contains(byte) { state = .ground }
        case .osc:
            guard byte >= 0x20 else { return }
            if osc.count < Self.maximumOSC { osc.append(byte) } else { oscTooLong = true }
        case .apc, .sosPmApc, .dcsIgnore, .dcsPassthrough:
            return
        case .dcsEntry, .dcsParam, .dcsIntermediate:
            switch byte {
            case 0x30...0x39, 0x3b:
                if state == .dcsIntermediate { state = .dcsIgnore } else { parameter(byte); state = .dcsParam }
            case 0x3a: state = .dcsIgnore
            case 0x3c...0x3f:
                if state == .dcsEntry { collect.append(byte); state = .dcsParam } else { state = .dcsIgnore }
            case 0x20...0x2f: collect.append(byte); state = .dcsIntermediate
            case 0x40...0x7e:
                statusString = !tooManyParameters && collect == [0x24] && byte == 0x71
                state = .dcsPassthrough
            case 0xa0...: state = .ground
            default: return
            }
        }
    }

    /// A digit, or a `;` or `:` beginning the next parameter, as SwiftTerm counts them.
    private mutating func parameter(_ byte: UInt8) {
        guard byte == 0x3b || byte == 0x3a else {
            guard !tooManyParameters else { return }
            let value = pars[pars.count - 1]
            pars[pars.count - 1] = value > (Int(Int32.max) - 9) / 10 ? Int(Int32.max) : value * 10 + Int(byte - 0x30)
            return
        }
        if pars.count >= Self.maximumParameters { tooManyParameters = true } else if !tooManyParameters { pars.append(0) }
    }

    /// The queries a CSI is: `query`'s, or DECSET's focus events (`cmdSetMode`, one report for each 1004 it names).
    static func queries(final: UInt8, collect: [UInt8], pars: [Int]) -> [ParserReplies.Kind] {
        if final == 0x68, collect == [0x3f] { return pars.filter { $0 == 1004 }.map { _ in .focus } }
        return query(final: final, collect: collect, pars: pars).map { [$0] } ?? []
    }

    /// The query a CSI is, as SwiftTerm's handlers answer it: `cmdDeviceStatus`, `cmdSendDeviceAttributes`,
    /// `cmdDecRqm` (through `csiPHandler`), `handleKittyKeyboardProtocol`, `cmdXTVERSION`, `cmdWindowOptions`.
    static func query(final: UInt8, collect: [UInt8], pars: [Int]) -> ParserReplies.Kind? {
        let first = pars.first ?? 0
        switch (final, collect) {
        case (0x6e, []): return first == 5 ? .status : first == 6 ? .cursor : nil
        case (0x6e, [0x3f]):
            if first == 6 { return .decCursor }
            return ParserReplies.decReports[first] == nil ? nil : .decReport(first)
        case (0x63, []): return first > 0 ? nil : .primaryAttributes
        case (0x63, [0x3e]): return first > 0 ? nil : .secondaryAttributes
        case (0x70, [0x3f, 0x24]): return .decMode
        case (0x70, [0x24]): return .ansiMode
        case (0x75, [0x3f]): return .kittyKeyboard
        case (0x71, [0x3e]): return pars == [0] ? .version : nil
        case (0x74, []): return ParserReplies.windowReports[pars].map(ParserReplies.Kind.window)
        default: return nil
        }
    }

    /// The queries an OSC is, as `dispatchOsc` reads its code and `oscChangeOrQueryColorIndex` and `oscSetColors` their
    /// content, and the program status query as `ProgramStatus.parse` reads the payload the parser forwards.
    private func oscEnded(_ found: (ParserReplies.Kind) -> Void) {
        guard !osc.isEmpty else { return }
        let semicolon = osc.firstIndex(of: 0x3b)
        guard let code = Self.decimal(osc[..<(semicolon ?? osc.endIndex)]) else { return }
        let content = semicolon.map { osc[($0 + 1)...] } ?? []
        switch code {
        case 4:
            var position = content.startIndex
            while position <= content.endIndex {
                guard let separator = content[position...].firstIndex(of: 0x3b),
                      let color = Self.decimal(content[position..<separator]), color < 256 else { return }
                if separator + 1 < content.endIndex, content[separator + 1] == 0x3f {
                    found(.paletteColor)
                    position = separator + 2
                    if position < content.endIndex, content[position] == 0x3b { position += 1 }
                    continue
                }
                position = separator + 1
                position = (content[position...].firstIndex(of: 0x3b) ?? content.endIndex) + 1
            }
        case 10, 11, 12:
            for (offset, group) in content.split(separator: 0x3b).enumerated() where group.first == 0x3f {
                let target = code - 10 + offset
                if target <= 2 { found(.dynamicColor(10 + target)) }
            }
        case ProgramStatus.code:
            if content.first == 0x3f { found(.programStatusQuery) }
        default:
            return
        }
    }

    /// SwiftTerm's `parseDecimal`: digits only, at least one.
    private static func decimal(_ digits: ArraySlice<UInt8>) -> Int? {
        guard !digits.isEmpty, digits.count < 10, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }
}
