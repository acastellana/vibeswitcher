import AppKit
import SwiftTerm
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// A drag in a terminal pane selects, as in Terminal.app, while its session prints (2026-11-07: in a shell printing a
/// build's or a server's lines, every piece of output dropped the selection, so nothing could be copied or pasted),
/// and past a program that asked for the mouse with Option held. The mouse events go to the view as its window hands
/// them on; the window is never shown. The sessions are scratch programs on a scratch host (its own socket, lock and
/// key: `TerminalClipboardSecurityTests.Scene`), and nothing here touches the user's pasteboard.
@MainActor
@Suite(.serialized)
struct TerminalSelectionTests {
    typealias Scene = TerminalClipboardSecurityTests.Scene

    /// Mouse gestures on a terminal view, as its window hands them on.
    struct Mouse {
        let terminal: HostTerminalView
        var window: NSWindow { terminal.window! }

        var selected: String? { terminal.selection.active ? terminal.selection.getSelectedText() : nil }

        /// A press on screen row `row` at column `from`, a drag that selects up to column `to` (included: SwiftTerm's
        /// selection stops before the cell the drag ends on), and the release. Cells are taken as the view's size over
        /// its rows and columns, which is off by a fraction of the leftover margin each: keep to the screen's top left.
        func drag(row: Int, from: Int, to: Int, holding flags: NSEvent.ModifierFlags = []) {
            let screen = terminal.getTerminal()
            let cell = NSSize(width: terminal.bounds.width / CGFloat(screen.cols), height: terminal.bounds.height / CGFloat(screen.rows))
            func event(_ type: NSEvent.EventType, _ col: Int) -> NSEvent {
                let point = terminal.convert(NSPoint(x: (CGFloat(col) + 0.5) * cell.width, y: terminal.bounds.height - (CGFloat(row) + 0.5) * cell.height), to: nil)
                return NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: type == .leftMouseUp ? 0 : 1)!
            }
            terminal.mouseDown(with: event(.leftMouseDown, from))
            for col in from...to + 1 { terminal.mouseDragged(with: event(.leftMouseDragged, col)) }
            terminal.mouseUp(with: event(.leftMouseUp, to + 1))
        }

        /// The screen row showing a line that starts with `text`.
        func row(of text: String) -> Int? {
            let screen = terminal.getTerminal()
            return (0..<screen.rows).first { row in
                screen.getLine(row: row)?.translateToString(trimRight: true).hasPrefix(text) == true
            }
        }
    }

    /// A session on the scene's host that prints each line it reads (not echoed), shown in its pane; returns once its
    /// view shows "<name> ready".
    func printer(_ scene: Scene, _ name: String) async throws -> (UUID, Mouse) {
        if scene.host.state != .connected {
            scene.host.connectIfRunning()
            #expect(await until { scene.host.state == .connected })
        }
        var result: Result<HostSession, HostClientError>?
        scene.host.spawn(SpawnRequest(cwd: scratchRoot.path, command: "stty -echo; echo '\(name) ready'; while IFS= read -r l; do echo \"$l\"; done",
                                      env: [:], cols: 100, rows: 30, keepShell: false, label: name, agent: nil)) { result = $0 }
        #expect(await until { result != nil })
        let id = try #require(result).get().id
        scene.pane.show(hostID: id)
        #expect(await until { scene.pane.screenLines(id).contains("\(name) ready") }, "\(name) never started")
        return (id, Mouse(terminal: try #require(scene.pane.terminalView(id))))
    }

    /// The session prints `lines`; returns once the last of them reached its view.
    func prints(_ lines: [String], in id: UUID, _ scene: Scene) async {
        scene.host.send(id, bytes: Data((lines.joined(separator: "\r") + "\r").utf8), reply: false)
        let last = lines.last!.trimmingCharacters(in: .whitespaces)
        #expect(await until { scene.pane.screenLines(id).contains(last) }, "\(last) never reached its view")
    }

    @Test func aSelectionStaysOnItsTextWhileTheSessionPrints() async throws {
        let scene = try Scene()
        let (id, mouse) = try await printer(scene, "build")
        await prints(["$ swift build", "Building for debugging..."], in: id, scene)
        mouse.drag(row: try #require(mouse.row(of: "Building")), from: 0, to: 7)
        #expect(mouse.selected == "Building")
        // The build goes on printing, past the screen's height: the selection scrolls up with its text.
        await prints((0..<60).map { "[\($0)/60] Compiling Module\($0).swift" }, in: id, scene)
        #expect(mouse.selected == "Building")
    }

    @Test func aFullScrollbackTakesTheSelectionWithItsTextAndDropsItWithIt() async throws {
        let scene = try Scene()
        scene.pane.scrollbackLines = 10
        let (id, mouse) = try await printer(scene, "server")
        // The scrollback full, and "pick me" near the screen's top.
        let rows = mouse.terminal.getTerminal().rows
        await prints((0..<rows + 20).map { "filler \($0)" } + ["pick me"] + (0..<rows - 4).map { "after \($0)" }, in: id, scene)
        let row = try #require(mouse.row(of: "pick me"))
        #expect(row < 4)
        mouse.drag(row: row, from: 0, to: 6)
        #expect(mouse.selected == "pick me")
        let trimmed = mouse.terminal.getTerminal().buffer.totalLinesTrimmed
        await prints((0..<3).map { "more \($0)" }, in: id, scene)
        #expect(mouse.terminal.getTerminal().buffer.totalLinesTrimmed > trimmed, "the scrollback wasn't full")
        #expect(mouse.selected == "pick me")
        // Its line leaves the scrollback: nothing else is selected in its place.
        await prints((0..<100).map { "later \($0)" }, in: id, scene)
        #expect(mouse.selected == nil)
    }

    /// The Edit menu's Copy and Paste have no target: from the pane's terminal, the first responder, they land on it,
    /// and Copy stays enabled on a selection while the session prints.
    @Test func theEditMenusCopyAndPasteReachThePaneWhileItPrints() async throws {
        let scene = try Scene()
        let (id, mouse) = try await printer(scene, "dev")
        func item(_ title: String) throws -> NSMenuItem {
            try #require(MainMenu.build().item(withTitle: "Edit")?.submenu?.item(withTitle: title))
        }
        func target(_ item: NSMenuItem) -> NSResponder? {
            var responder = scene.window.firstResponder
            while let next = responder, !next.responds(to: item.action) { responder = next.nextResponder }
            return responder
        }
        let copy = try item("Copy"), paste = try item("Paste")
        #expect(target(copy) === mouse.terminal && target(paste) === mouse.terminal)
        #expect(!mouse.terminal.validateUserInterfaceItem(copy), "Copy with nothing selected")
        #expect(mouse.terminal.validateUserInterfaceItem(paste))
        await prints(["  ready on http://localhost:3000"], in: id, scene)
        mouse.drag(row: try #require(mouse.row(of: "  ready")), from: 2, to: 6)
        await prints((0..<5).map { "GET /page/\($0) 200" }, in: id, scene)
        #expect(mouse.terminal.validateUserInterfaceItem(copy))
        #expect(mouse.selected == "ready")
    }

    @Test func anOptionDragSelectsPastAProgramThatAskedForTheMouse() throws {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let terminal = HostTerminalView(frame: window.contentView!.bounds, font: nil, options: TerminalOptions())
        window.contentView!.addSubview(terminal)
        var sent = Data()
        terminal.onReply = { sent.append($0) }
        let mouse = Mouse(terminal: terminal)
        // As Claude Code's fullscreen, vim or tmux ask: button tracking, SGR coordinates.
        terminal.feed(text: "\u{1b}[?1002h\u{1b}[?1006hhello world\r\n")
        let row = try #require(mouse.row(of: "hello"))
        // A plain drag is the program's, as in Terminal.app.
        mouse.drag(row: row, from: 0, to: 4)
        #expect(mouse.selected == nil)
        #expect(String(decoding: sent, as: UTF8.self).contains("\u{1b}[<0;1;\(row + 1)M"))
        // Option held: it selects, and the program hears nothing of it.
        sent = Data()
        mouse.drag(row: row, from: 0, to: 4, holding: .option)
        #expect(mouse.selected == "hello")
        #expect(sent.isEmpty)
        // Shift (SwiftTerm's own way past the program) selects too; from nothing selected, as a Shift-click extends a
        // selection.
        terminal.selection.selectNone()
        mouse.drag(row: row, from: 6, to: 10, holding: .shift)
        #expect(mouse.selected == "world")
        #expect(sent.isEmpty)
        // The next plain drag is the program's again.
        mouse.drag(row: row, from: 0, to: 4)
        #expect(!sent.isEmpty)
    }
}
