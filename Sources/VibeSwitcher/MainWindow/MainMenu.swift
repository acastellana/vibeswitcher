import AppKit

/// The menu bar menus while the window is open (the app is a regular app then). Standard items go to the first
/// responder (text views, the window, the app), so ⌘Z, ⌘X, ⌘W… work wherever the focus is.
enum MainMenu {
    /// End Session…: ⇧⌘⌫, well away from ⌘W (which only ever closes a window), and unbound in text views.
    static let endSessionKey = String(Character(UnicodeScalar(NSBackspaceCharacter)!))
    /// Retitled while the menu is open with what the restart does (`HostClient.RestartPlan.title`); off unless the
    /// host is outdated.
    static let restartHostTitle = "Restart Session Host"
    /// Retitled while the menu is open with the selected lead's project; off when no lead is selected.
    static let briefProjectTitle = "Brief Me on Project"

    /// Sets the menu bar, and the menus AppKit fills in itself (the window list, the help search).
    static func install() {
        let main = build()
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = main.item(withTitle: "Help")?.submenu
        NSApp.servicesMenu = main.item(withTitle: "VibeSwitcher")?.submenu?.item(withTitle: "Services")?.submenu
    }

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

        let services = item("Services", nil, "")
        services.submenu = NSMenu(title: "Services")
        submenu("VibeSwitcher", [
            item("About VibeSwitcher", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", Selector(("showSettings:")), ","),
            item(restartHostTitle, #selector(AppDelegate.restartSessionHost(_:))),
            .separator(),
            services,
            .separator(),
            item("Hide VibeSwitcher", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit VibeSwitcher", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New Session", #selector(MainWindowController.newSessionAction(_:)), "n"),
            item("New Shell", #selector(MainWindowController.newShellAction(_:)), "n", [.command, .option]),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            item("End Session…", #selector(MainWindowController.endSessionAction(_:)), endSessionKey, [.command, .shift]),
        ])
        let find = item("Find", nil, "")
        find.submenu = NSMenu(title: "Find")
        [
            item("Find…", #selector(MainWindowController.findAction(_:)), "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)),
            item("Find Next", #selector(MainWindowController.findNextAction(_:)), "g", tag: Int(NSFindPanelAction.next.rawValue)),
            item("Find Previous", #selector(MainWindowController.findPreviousAction(_:)), "g", [.command, .shift],
                 tag: Int(NSFindPanelAction.previous.rawValue)),
            item("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e",
                 tag: Int(NSFindPanelAction.setFindString.rawValue)),
        ].forEach(find.submenu!.addItem)
        // Titled "Edit": AppKit adds Writing Tools, AutoFill, Dictation and Emoji & Symbols to it.
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            find,
        ])
        submenu("View", [
            item("Terminal", #selector(MainWindowController.showTerminalAction(_:)), "1", [.command, .option]),
            item("Chat", #selector(MainWindowController.showChatAction(_:)), "2", [.command, .option]),
            .separator(),
            item("Group by Attention", #selector(MainWindowController.groupByAttention(_:)), "1", [.command, .control]),
            item("Group by Project", #selector(MainWindowController.groupByProjects(_:)), "2", [.command, .control]),
            item("Filter Sessions", #selector(MainWindowController.focusFilterAction(_:)), "f", [.command, .option]),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Toggle Inspector", #selector(MainWindowController.toggleInspectorAction(_:)), "0", [.command, .option]),
            // ⇧⌘↩, as Xcode's editor-only: the terminal takes the whole window.
            item("Focus Terminal", #selector(MainWindowController.focusTerminalAction(_:)), "\r", [.command, .shift]),
            .separator(),
            item("Bigger", #selector(MainWindowController.biggerFont(_:)), "="),
            item("Smaller", #selector(MainWindowController.smallerFont(_:)), "-"),
            item("Default Size", #selector(MainWindowController.actualSizeFont(_:)), "0"),
            .separator(),
            item("Clear Scrollback", #selector(MainWindowController.clearScrollbackAction(_:)), "k", [.command, .shift]),
        ])
        submenu("Session", [
            item("Command Palette…", #selector(MainWindowController.showPaletteAction(_:)), "k"),
            .separator(),
            item("Next Session", #selector(MainWindowController.nextSession(_:)), down, [.command, .option]),
            item("Previous Session", #selector(MainWindowController.previousSession(_:)), up, [.command, .option]),
            item("Next Needing You", #selector(MainWindowController.nextNeedingYou(_:)), "j"),
            item("Open in Terminal", #selector(MainWindowController.openInTerminalAction(_:)), "o"),
            item("Stop", #selector(MainWindowController.stopAction(_:)), "."),
            item("Export Chat…", #selector(MainWindowController.exportChatAction(_:)), "e", [.command, .shift]),
            item("Start Page", #selector(MainWindowController.showHomeAction(_:)), "h", [.command, .shift]),
            .separator(),
            // The briefings: across every led project (the toolbar's), then the selected lead's project alone.
            item("Brief Me", #selector(MainWindowController.briefMeAction(_:)), "b", [.command, .shift]),
            item(briefProjectTitle, #selector(MainWindowController.briefProjectAction(_:)), "b", [.command, .option, .shift]),
            .separator(),
        ] + (1...9).map { item("Session \($0)", #selector(MainWindowController.selectSessionByTag(_:)), "\($0)", tag: $0) })
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        // Empty: AppKit puts the menu search field in it.
        submenu("Help", [])
        return main
    }
}
