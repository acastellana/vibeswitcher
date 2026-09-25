import AppKit
import SwiftUI
import VibeCore

/// `VibeSwitcher --snapshot <dir>`: renders the popover and menu bar icon from live data into PNGs.
/// Handy for checking the UI without Screen Recording permission.
enum Snapshot {
    static func run(outputDirectory: String) {
        let store = SessionStore()
        store.refreshHookStatus()
        store.refreshNow()

        let view = PopoverView(store: store, state: PopoverState(), preferences: Preferences(), onOpen: { _ in }, onInstallHooks: {}, onQuit: {})
        for (name, appearance) in [("popover-light", NSAppearance.Name.aqua), ("popover-dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            write(view: host, to: "\(outputDirectory)/\(name).png")
        }

        for (name, appearance) in [("panel-light", NSAppearance.Name.aqua), ("panel-dark", .darkAqua)] {
            let host = NSHostingView(rootView: FloatingDotsView(store: store, onOpen: { _ in }, onShowList: {})
                .padding(10).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            write(view: host, to: "\(outputDirectory)/\(name).png")
        }

        var sidebarView = PopoverView(store: store, state: PopoverState(), preferences: Preferences(),
                                      onOpen: { _ in }, onInstallHooks: {}, onQuit: {})
        sidebarView.isSidebar = true
        let sidebarHost = NSHostingView(rootView: sidebarView.padding(8).background(Color(nsColor: .windowBackgroundColor)))
        sidebarHost.appearance = NSAppearance(named: .darkAqua)
        sidebarHost.frame = NSRect(x: 0, y: 0, width: SidebarController.width, height: 900)
        let sidebarWindow = NSWindow(contentRect: sidebarHost.frame, styleMask: .borderless, backing: .buffered, defer: false)
        sidebarWindow.contentView = sidebarHost
        sidebarHost.layoutSubtreeIfNeeded()
        write(view: sidebarHost, to: "\(outputDirectory)/sidebar.png")

        let icon = StatusIcon.image(for: store.sessions)
        for (name, appearance, gray) in [("menubar-icon-dark", NSAppearance.Name.darkAqua, 0.15),
                                         ("menubar-icon-light", .aqua, 0.92)] {
            let iconView = NSImageView(image: icon)
            iconView.appearance = NSAppearance(named: appearance)
            iconView.frame = NSRect(x: 0, y: 0, width: icon.size.width + 16, height: 26)
            iconView.wantsLayer = true
            iconView.layer?.backgroundColor = NSColor(white: gray, alpha: 1).cgColor
            write(view: iconView, to: "\(outputDirectory)/\(name).png")
        }

        for session in store.sessions {
            print("\(session.status.rawValue)\t\(session.agent.rawValue)\t\(session.tty)\t\(session.displayName)\t\(session.task ?? "-")\t\(session.detail ?? "")")
        }
    }

    private static func write(view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
