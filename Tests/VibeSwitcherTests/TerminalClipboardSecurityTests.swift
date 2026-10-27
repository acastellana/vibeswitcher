import AppKit
import Foundation
import SwiftTerm
import Testing
import VibeCore
@testable import VibeSwitcher

@MainActor
struct TerminalClipboardSecurityTests {
    @Test func programOutputNeverReachesTheClipboardDelegate() {
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("original-synthetic-selection", forType: .string)
        let revision = clipboard.changeCount
        let pane = TerminalPaneController(host: HostClient(socketPath: "/unused-audit-socket"), clipboard: clipboard)
        let view = HostTerminalView(frame: .zero, font: nil, options: TerminalOptions())
        view.terminalDelegate = pane
        let payload = Data("SYNTHETIC_CLIPBOARD".utf8).base64EncodedString()
        // Initial output, repeated replay and hidden terminal all use the same parser path.
        for _ in 0..<3 { view.feed(text: "\u{1b}]52;c;\(payload)\u{7}") }
        #expect(clipboard.changeCount == revision)
        #expect(clipboard.string(forType: .string) == "original-synthetic-selection")
    }
}
