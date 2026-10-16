import AppKit

/// The menu bar menus while the window is open (the app is a regular app then).
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                  tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            return item
        }
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))

        submenu("VibeSwitcher", [
            item("About VibeSwitcher", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", Selector(("showSettings:")), ","),
            .separator(),
            item("Hide VibeSwitcher", #selector(NSApplication.hide(_:)), "h"),
            item("Quit VibeSwitcher", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New Session", #selector(MainWindowController.newSessionAction(_:)), "n"),
            item("New Shell", #selector(MainWindowController.newShellAction(_:)), "n", [.command, .option]),
            .separator(),
            item("End Session…", #selector(MainWindowController.endSessionAction(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ])
        submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)),
            item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: Int(NSFindPanelAction.next.rawValue)),
            item("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift],
                 tag: Int(NSFindPanelAction.previous.rawValue)),
            item("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e",
                 tag: Int(NSFindPanelAction.setFindString.rawValue)),
        ])
        submenu("View", [
            item("Group by Attention", #selector(MainWindowController.groupByAttention(_:)), "1", [.command, .control]),
            item("Group by Project", #selector(MainWindowController.groupByProjects(_:)), "2", [.command, .control]),
            item("Filter Sessions", #selector(MainWindowController.focusFilterAction(_:)), "f", [.command, .option]),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Toggle Inspector", #selector(MainWindowController.toggleInspectorAction(_:)), "0", [.command, .option]),
            .separator(),
            item("Bigger", #selector(MainWindowController.biggerFont(_:)), "="),
            item("Smaller", #selector(MainWindowController.smallerFont(_:)), "-"),
            item("Default Size", #selector(MainWindowController.actualSizeFont(_:)), "0"),
            .separator(),
            item("Clear Scrollback", #selector(MainWindowController.clearScrollbackAction(_:)), "k", [.command, .shift]),
        ])
        submenu("Session", [
            item("Next Session", #selector(MainWindowController.nextSession(_:)), down, [.command, .option]),
            item("Previous Session", #selector(MainWindowController.previousSession(_:)), up, [.command, .option]),
            item("Next Needing You", #selector(MainWindowController.nextNeedingYou(_:)), "j"),
            item("Open in Terminal", #selector(MainWindowController.openInTerminalAction(_:)), "o"),
            item("Start Page", #selector(MainWindowController.showHomeAction(_:)), "h", [.command, .shift]),
            .separator(),
        ] + (1...9).map { item("Session \($0)", #selector(MainWindowController.selectSessionByTag(_:)), "\($0)", tag: $0) })
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        return main
    }
}
