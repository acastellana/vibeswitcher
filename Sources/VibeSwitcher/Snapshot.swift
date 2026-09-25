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

        let icon = StatusIcon.image(for: store.sessions)
        let iconView = NSImageView(image: icon)
        iconView.frame = NSRect(x: 0, y: 0, width: icon.size.width + 16, height: 24)
        iconView.wantsLayer = true
        iconView.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        write(view: iconView, to: "\(outputDirectory)/menubar-icon.png")

        for session in store.sessions {
            print("\(session.status.rawValue)\t\(session.agent.rawValue)\t\(session.tty)\t\(session.project)\t\(session.task ?? "-")\t\(session.detail ?? "")")
        }
    }

    private static func write(view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
