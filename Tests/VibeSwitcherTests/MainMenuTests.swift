import AppKit
import Testing
@testable import VibeCore
@testable import VibeSwitcher

@MainActor
struct MainMenuTests {
    /// Every item in the menu bar, with the path of menu titles that leads to it.
    func items(_ menu: NSMenu = MainMenu.build(), path: [String] = []) -> [(path: [String], item: NSMenuItem)] {
        menu.items.flatMap { item -> [(path: [String], item: NSMenuItem)] in
            let here = path + [item.title]
            return [(here, item)] + (item.submenu.map { items($0, path: here) } ?? [])
        }
    }

    func item(_ path: String...) -> NSMenuItem? { items().first { $0.path == path }?.item }

    /// "⇧⌘Z": an uppercase key counts as ⇧, as AppKit matches it; ⌫ is the same key as either delete character.
    func shortcut(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var key = item.keyEquivalent
        var flags = item.keyEquivalentModifierMask
        if key.lowercased() != key {
            key = key.lowercased()
            flags.insert(.shift)
        }
        if key == "\u{7f}" || key == "\u{8}" { key = "⌫" }
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { flags.contains($0.0) }.map(\.1).joined() + key.uppercased()
    }

    @Test func noTwoItemsShareAShortcut() {
        var owners: [String: [String]] = [:]
        for (path, item) in items() {
            if let key = shortcut(item) { owners[key, default: []].append(path.joined(separator: " › ")) }
        }
        let duplicates = owners.filter { $0.value.count > 1 }
        #expect(duplicates.isEmpty, "shortcuts used twice: \(duplicates)")
        #expect(owners.count > 30)   // the walk found the menus
    }

    @Test func commandWClosesTheWindowAndNeverEndsASession() {
        let close = item("File", "Close Window")
        #expect(close?.action == #selector(NSWindow.performClose(_:)))
        #expect(close.flatMap(shortcut) == "⌘W")
        let end = item("File", "End Session…")
        #expect(end?.action == #selector(MainWindowController.endSessionAction(_:)))
        #expect(end.flatMap(shortcut) == "⇧⌘⌫")
        for (path, item) in items() where shortcut(item)?.hasSuffix("W") == true {
            #expect(item.action == #selector(NSWindow.performClose(_:)), "\(path) uses W")
        }
    }

    @Test func editMenuHasTheStandardItems() {
        let expected: [(String, Selector, String?)] = [
            ("Undo", Selector(("undo:")), "⌘Z"),
            ("Redo", Selector(("redo:")), "⇧⌘Z"),
            ("Cut", #selector(NSText.cut(_:)), "⌘X"),
            ("Copy", #selector(NSText.copy(_:)), "⌘C"),
            ("Paste", #selector(NSText.paste(_:)), "⌘V"),
            ("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "⌥⇧⌘V"),
            ("Delete", #selector(NSText.delete(_:)), nil),
            ("Select All", #selector(NSText.selectAll(_:)), "⌘A"),
        ]
        for (title, action, key) in expected {
            let found = item("Edit", title)
            #expect(found?.action == action, "Edit › \(title)")
            #expect(found.flatMap(shortcut) == key, "Edit › \(title)")
        }
        #expect(item("Edit", "Find", "Find…").flatMap(shortcut) == "⌘F")
        #expect(item("Edit", "Find", "Find Next").flatMap(shortcut) == "⌘G")
        #expect(item("Edit", "Find", "Find Previous").flatMap(shortcut) == "⇧⌘G")
    }

    @Test func appAndWindowMenusFollowTheHIG() {
        let app: [(String, Selector, String?)] = [
            ("About VibeSwitcher", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), nil),
            ("Settings…", Selector(("showSettings:")), "⌘,"),
            ("Hide VibeSwitcher", #selector(NSApplication.hide(_:)), "⌘H"),
            ("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "⌥⌘H"),
            ("Show All", #selector(NSApplication.unhideAllApplications(_:)), nil),
            ("Quit VibeSwitcher", #selector(NSApplication.terminate(_:)), "⌘Q"),
        ]
        for (title, action, key) in app {
            #expect(item("VibeSwitcher", title)?.action == action, "\(title)")
            #expect(item("VibeSwitcher", title).flatMap(shortcut) == key, "\(title)")
        }
        #expect(item("VibeSwitcher", "Services")?.submenu != nil)
        #expect(item("Window", "Minimize")?.action == #selector(NSWindow.performMiniaturize(_:)))
        #expect(item("Window", "Minimize").flatMap(shortcut) == "⌘M")
        #expect(item("Window", "Zoom")?.action == #selector(NSWindow.performZoom(_:)))
        #expect(item("Window", "Bring All to Front")?.action == #selector(NSApplication.arrangeInFront(_:)))
        #expect(MainMenu.build().items.map(\.title) == ["VibeSwitcher", "File", "Edit", "View", "Session", "Window", "Help"])
    }

    /// The Edit items have no target: they must land on a text view (or its window) through the responder chain.
    @Test func editActionsReachATextView() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let text = NSTextView(frame: window.contentView!.bounds)
        text.allowsUndo = true
        window.contentView!.addSubview(text)
        window.makeFirstResponder(text)
        for item in items().map(\.item) where item.menu?.title == "Edit" && item.action != nil && item.submenu == nil {
            let action = try #require(item.action)
            #expect(text.responds(to: action) || window.responds(to: action), "\(item.title) reaches nothing")
        }
        // ⌘Z goes to the window, which undoes in the focused text view.
        text.undoManager?.groupsByEvent = false
        text.undoManager?.beginUndoGrouping()
        text.insertText("hello", replacementRange: text.selectedRange())
        text.undoManager?.endUndoGrouping()
        let undo = try #require(item("Edit", "Undo"))
        #expect(window.validateMenuItem(undo))
        window.perform(undo.action, with: nil)
        #expect(text.string == "")
    }

    func idle(host: UUID) -> WindowRow {
        var session = Session(tty: "ttys009", agent: .claude, pid: 1, startedAt: Date(), cwd: "/dev/app", project: "app",
                              task: "tidy up", status: .idle, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
        session.hostID = host
        return WindowRow(content: .agent(session), project: "app")
    }

    @Test func endSessionAlwaysAsksUnlessItEnded() {
        let row = idle(host: UUID())
        let question = AppDelegate.endSessionQuestion(row, live: true)
        #expect(question != nil)   // idle: asked too
        #expect(question?.detail.contains("idle") == true)
        #expect(AppDelegate.endSessionQuestion(row, live: false) == nil)
        let shell = WindowRow(content: .hosted(HostSession(id: UUID(), tty: "ttys010", childPID: 2, cwd: "/dev/app", command: nil,
                                                          label: "Shell", agent: nil, title: "", startedAt: Date(),
                                                          cols: 80, rows: 24, exit: nil)), project: "app")
        #expect(AppDelegate.endSessionQuestion(shell, live: true)?.message == "End “Shell”?")
    }
}
