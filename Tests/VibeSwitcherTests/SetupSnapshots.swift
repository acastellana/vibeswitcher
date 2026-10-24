import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Pictures of each welcome step and each Settings tab, light and dark, drawn offscreen in real windows (so the
/// switches, pickers and grouped forms are AppKit's own) from fixed setup state: Claude Code's hooks installed and
/// Codex's not, Terminal control not asked yet, notifications not asked yet (welcome) or turned off (Settings). Only with `SETUP_SNAPSHOT_DIR=/some/folder`, and
/// only with `HOME` and `CFFIXED_USER_HOME` pointing at a scratch folder, so nothing reads or writes the real
/// preferences, presets or hook configs (see docs/eval/ux-fixes/first-run.md for the command).
@MainActor
struct SetupSnapshots {
    static let folder = ProcessInfo.processInfo.environment["SETUP_SNAPSHOT_DIR"]

    @Test(.enabled(if: folder != nil)) func drawWelcomeAndSettings() throws {
        let folder = try #require(Self.folder)
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], "point HOME and CFFIXED_USER_HOME at a scratch folder")
        func resolved(_ path: String?) -> String? { path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        let scratch = resolved(NSHomeDirectory()) == resolved(home) && resolved(ProcessInfo.processInfo.environment["HOME"]) == resolved(home)
        #expect(scratch, "home is \(NSHomeDirectory()), not \(home)")
        guard scratch else { return }

        let temp = Scratch()
        let defaults = temp.defaults("setup-snapshots")
        let preferences = Preferences(defaults: defaults, presetsFile: URL(fileURLWithPath: home).appendingPathComponent("presets.json"))
        preferences.notificationsAllowed = false
        let hooks: [Agent: Bool] = [.claude: true, .codex: false]
        let setup = SetupModel(preferences: preferences, system: .fixed(hooks: hooks, terminal: .notAsked, notifications: .off))
        setup.hooks = hooks
        setup.terminal = .notAsked
        setup.notifications = .off

        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = scheme == .darkAqua ? "dark" : "light"
            // On first run macOS hasn't asked about notifications yet; Settings is drawn after they were turned off.
            setup.notifications = .notAsked
            let flow = OnboardingFlow(openAtLogin: true)
            for step in OnboardingStep.allCases {
                flow.step = step
                // The steps before this one were skipped, as a user clicking through would (done ones show done).
                flow.skipped = Set(OnboardingStep.allCases.filter { $0.rawValue < step.rawValue && $0 != .welcome })
                let view = OnboardingView(setup: setup, flow: flow, finish: {})
                try write(render(view, size: OnboardingView.size, title: "Welcome to VibeSwitcher", transparentTitle: true, appearance: scheme)[0],
                          to: folder, name: "welcome-\(step.title.lowercased().replacingOccurrences(of: " ", with: "-"))-\(suffix).png")
            }
            setup.notifications = .off
            let selection = SettingsSelection()
            let phone = PhoneAccess.preview(store: SessionStore())
            for tab in SettingsTab.allCases {
                selection.tab = tab
                let view = SettingsView(preferences: preferences, setup: setup, phoneAccess: phone, selection: selection,
                                        recentProjects: { [] }, showWelcome: {})
                let pictures = try render(view, size: SettingsWindowController.size, title: "Settings", transparentTitle: false,
                                          appearance: scheme, alsoScrolledToEnd: true)
                for (index, picture) in pictures.enumerated() {
                    try write(picture, to: folder, name: "settings-\(tab.rawValue)\(index == 0 ? "" : "-end")-\(suffix).png")
                }
            }
        }
    }

    /// The window, title bar included, drawn into a bitmap while it sits far off every display. With
    /// `alsoScrolledToEnd`, a content that scrolls is drawn a second time scrolled to its end.
    private func render(_ view: some View, size: CGSize, title: String, transparentTitle: Bool,
                        appearance: NSAppearance.Name, alsoScrolledToEnd: Bool = false) throws -> [Data] {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if transparentTitle { style.insert(.fullSizeContentView) }
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        if transparentTitle {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
        window.appearance = NSAppearance(named: appearance)
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let frame = try #require(window.contentView?.superview)
        var pictures = [try draw(frame)]
        if alsoScrolledToEnd, let scroll = Self.scrollViews(in: frame).max(by: { $0.frame.height < $1.frame.height }),
           let document = scroll.documentView, document.frame.height > scroll.contentView.bounds.height + 1 {
            let end = document.isFlipped ? document.frame.height - scroll.contentView.bounds.height : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            pictures.append(try draw(frame))
        }
        return pictures
    }

    private func draw(_ frame: NSView) throws -> Data {
        frame.layoutSubtreeIfNeeded()
        frame.displayIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func write(_ data: Data, to folder: String, name: String) throws {
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }
}
