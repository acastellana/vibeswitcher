import Foundation
import SwiftTerm
import Testing
@testable import VibeCore
@testable import VibeHost

/// Claude Code's idle screen as a scratch Claude Code 2.1.302 PTY drew it (120 columns), fed to the host's headless
/// terminal. Claude moves the cursor between words (`ESC[<col>G`) instead of printing spaces, and draws its
/// placeholder and its suggested next prompt with `chalk.dim` (SGR 2), inverting the first character when it paints
/// its caret there; what's typed is plain.
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

    /// 2026-10-17: merges-name-the-failing's box after it asked the lead a question, with the caret painted.
    static let incident = idle(box: "\(e)[7mb\(e)[27m\(e)[2mring\(e)[9Gthe\(e)[13Gbranch\(e)[20Gup\(e)[23Gto\(e)[26Gdate"
                                    + "\(e)[31Gwith\(e)[36Gproject-lead\(e)[49Gyourself\(e)[22m")
    /// The same, unfocused: no caret.
    static let incidentNoCaret = idle(box: "\(e)[2mbring\(e)[9Gthe\(e)[13Gbranch\(e)[20Gup\(e)[23Gto\(e)[26Gdate"
                                           + "\(e)[31Gwith\(e)[36Gproject-lead\(e)[49Gyourself\(e)[22m")
    /// Captured byte for byte: the placeholder in a new session's box.
    static let placeholder = idle(box: "\(e)[2mTry\(e)[7G\"how\(e)[12Gdoes\(e)[17G<filepath>\(e)[28Gwork?\"\(e)[22m")
    /// Captured: "hello draft" typed into the box.
    static let typed = idle(box: "hello\(e)[9Gdraft")
    /// Typed with the caret back on its first character.
    static let typedCaretFirst = idle(box: "\(e)[7mh\(e)[27mello\(e)[9Gdraft")

    static func shown(_ bytes: String) -> LeadDelivery.Screen {
        let terminal = Terminal(delegate: HeadlessDelegate(), options: TerminalOptions(cols: 120, rows: 40, scrollback: 100))
        terminal.feed(byteArray: Array(bytes.utf8))
        let screen = HostedSession.styledScreen(of: terminal)
        return LeadDelivery.Screen(text: screen.text, runs: screen.runs)
    }
}

struct StyledScreenTests {
    func scratch() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("styled-\(UUID().uuidString)")
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

    @Test func typedTextIsADraft() {
        #expect(LeadDelivery.box(in: ClaudeScreens.shown(ClaudeScreens.typed)) == .draft("hello draft"))
        #expect(LeadDelivery.box(in: ClaudeScreens.shown(ClaudeScreens.typedCaretFirst)) == .draft("hello draft"))
    }

    @Test func messageTypesOverTheSuggestion() throws {
        let root = scratch()
        let agent = LeadAgent(pid: 7, tty: "ttys905", session: "s")
        var typed: [String] = []
        let delivered = try LeadDelivery.deliver("bring the branch up to date with project-lead yourself", from: .lead("lead of vibeswitcher"),
                                                 to: agent, activity: .idle(background: nil),
                                                 styledScreen: { ClaudeScreens.shown(ClaudeScreens.incident) },
                                                 typeInto: { typed.append($0); return true }, root: root)
        #expect(delivered == .typed)
        #expect(typed.count == 1 && typed[0].hasSuffix("] bring the branch up to date with project-lead yourself"))
        #expect(SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
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
                                         clear: { cleared += 1; shown = ClaudeScreens.incident }, root: root) == .typed)
        #expect(cleared == 1 && typed.count == 1 && typed[0].hasSuffix("b"))
        #expect(SteerInbox.pending(tty: agent.tty, root: root).map(\.text) == ["a"])
    }
}
