import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// 2026-10-21: the user typed /mcp in the chat and saw nothing; the selector only showed after they sent another
/// message. Claude Code 2.1.306's pickers, captured byte for byte from a scratch PTY by
/// `Tests/Tools/capture-claude-pickers.py` (a scratch HOME with two scratch MCP servers and one allow rule, a scratch
/// project, a fake Messages API on 127.0.0.1: never a real session or account), fed to `SessionParser` as the host
/// runs it, and read as the chat reads them.
///
/// The capture's steps (its `.marks.json`): /mcp, ↓, Esc; /model, ↓, ↓, Esc; /permissions, ↓, ↓, ↩ (on the rule:
/// "Delete allowed tool?"), ↓, Esc ×3; /mcp, "hello", ↩ (what the user's next message did), Esc ×2.
struct PickerScreensTests {
    struct Capture {
        let bytes: [UInt8]
        let cols: Int
        let rows: Int
        let marks: [String: Int]

        init() throws {
            let name = "claude-2.1.306-pickers-110x40"
            let raw = try #require(Bundle.module.url(forResource: name, withExtension: "raw", subdirectory: "Fixtures"))
            let json = try #require(Bundle.module.url(forResource: name + ".marks", withExtension: "json", subdirectory: "Fixtures"))
            let marks = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
            bytes = Array(try Data(contentsOf: raw))
            cols = try #require(marks["cols"] as? Int)
            rows = try #require(marks["rows"] as? Int)
            self.marks = marks.compactMapValues { $0 as? Int }
        }

        /// The host's screen at `mark`: each line as the session parser has it (its indentation kept).
        func screen(_ mark: String) throws -> [String] {
            try StatusRowsTests.parsed(Array(bytes[0..<(try #require(marks[mark]))]), cols: cols, rows: rows)
        }
    }

    /// The pane's read of the same screen (`TerminalPaneController.screenText`): each line trimmed on both sides.
    static func paneRead(_ lines: [String]) -> [String] { lines.map { $0.trimmingCharacters(in: .whitespaces) } }

    @Test func theMCPServerListIsAPickerTheNumberedParseNeverSaw() throws {
        let capture = try Capture()
        let screen = try capture.screen("01-/mcp")
        // Why the chat stayed blank: no "1. …" rows, and no slash-command menu under a prompt box.
        #expect(ScreenMenu.parse(Self.paneRead(screen)) == nil)
        #expect(ScreenMenu.parseCommands(Self.paneRead(screen)) == nil)
        let menu = try #require(ScreenMenu.parsePicker(screen))
        #expect(menu.picker)
        #expect(menu.question == "Manage MCP servers\n2 servers")
        // The "User MCPs (…)" heading isn't a row.
        #expect(menu.options == ["✘ scratch-broken", "✔ scratch-notes"])
        #expect(menu.descriptions == [nil, "1 tool"])
        #expect(menu.selected == 0)
        #expect(menu.hint == "↑/↓ to navigate · Enter to confirm · Esc to cancel")
        // ↓: the highlight moved.
        let moved = try #require(ScreenMenu.parsePicker(try capture.screen("02-down")))
        #expect(moved.selected == 1)
        #expect(moved.sameQuestion(as: menu))
        // Esc: gone.
        #expect(ScreenMenu.parsePicker(try capture.screen("03-esc")) == nil)
    }

    @Test func theNextMessageWentIntoThePickerAndOpenedTheServersMenu() throws {
        let capture = try Capture()
        // "hello" and ↩ typed into the open list: ↩ opened the highlighted server, whose menu is numbered (the card the
        // user saw after their next message).
        let screen = try capture.screen("18-enter")
        let menu = try #require(ScreenMenu.parse(Self.paneRead(screen)))
        #expect(menu.options == ["Reconnect", "Disable"])
        #expect(menu.question.contains("Scratch-broken MCP Server"))
    }

    @Test func theModelPicker() throws {
        let capture = try Capture()
        let screen = try capture.screen("04-/model")
        // The pane's read (numbered rows): each row's label, its description from its own column and the line under it.
        let pane = try #require(ScreenMenu.parse(Self.paneRead(screen)))
        #expect(pane.options == ["Default (recommended) ✔", "Opus", "Fable", "Sonnet", "Haiku"])
        #expect(pane.selected == 0)
        #expect(pane.question == "Select model\nSwitch between Claude models. Your pick becomes the default for new sessions. For other/previous model\nnames, specify with --model.")
        #expect(pane.descriptions[2] == "Fable 5.1 · Most capable for your hardest and longest-running tasks · $10/$50 per Mtok")
        #expect(pane.descriptions[1] == "Opus 5.5 · Best for everyday, complex tasks · $4/$20 per Mtok")
        // The host's read says the same.
        let host = try #require(ScreenMenu.parsePicker(screen))
        #expect(host.options == pane.options)
        #expect(host.descriptions == pane.descriptions)
        #expect(host.question == pane.question)
        #expect(host.selected == 0)
        // ↓ ↓: Fable.
        let moved = try capture.screen("06-down")
        #expect(ScreenMenu.parse(Self.paneRead(moved))?.selected == 2)
        #expect(ScreenMenu.parsePicker(moved)?.selected == 2)
        let closed = try capture.screen("07-esc")
        #expect(ScreenMenu.parse(Self.paneRead(closed)) == nil)
        #expect(ScreenMenu.parsePicker(closed) == nil)
    }

    @Test func aYesNoDialogInItsBox() throws {
        let capture = try Capture()
        let screen = try capture.screen("11-enter")
        #expect(ScreenMenu.parse(Self.paneRead(screen)) == nil)
        let menu = try #require(ScreenMenu.parsePicker(screen))
        #expect(menu.options == ["Yes", "No"])
        #expect(menu.selected == 1)
        #expect(menu.question == """
            Delete allowed tool?
            Bash(ls:*)
            Any Bash command starting with ls
            From user settings
            Are you sure you want to delete this permission rule?
            """)
        #expect(menu.hint == "Enter to confirm · Esc to cancel")
        #expect(ScreenMenu.parsePicker(try capture.screen("12-down"))?.selected == 0)
    }

    @Test func noPickerOnTheIdleScreenOrOnceClosed() throws {
        let capture = try Capture()
        for mark in ["idle", "03-esc", "07-esc", "15-esc", "20-esc"] {
            let screen = try capture.screen(mark)
            #expect(ScreenMenu.parsePicker(screen) == nil, "\(mark)")
            #expect(ScreenMenu.parse(Self.paneRead(screen)) == nil, "\(mark)")
        }
    }

    /// A dialog with nothing to choose yet (/permissions before ↓ reaches its rows): its title and footer, no options.
    @Test func aDialogWithNothingMarkedIsItsTitle() throws {
        let capture = try Capture()
        let menu = try #require(ScreenMenu.parsePicker(try capture.screen("08-/permissions")))
        #expect(menu.options.isEmpty)
        #expect(menu.question.hasPrefix("Permissions"))
        #expect(!menu.question.contains("Add a new rule"))
        #expect(menu.hint?.contains("Esc to cancel") == true)
    }
}
