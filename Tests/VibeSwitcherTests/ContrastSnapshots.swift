import AppKit
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// The popover, sidebar and pill in light and dark, with Increase Contrast off and on (`Contrast.override`, so the
/// system setting stays as it is). Only with `CONTRAST_SNAPSHOT_DIR=/some/folder scripts/test.sh --filter
/// ContrastSnapshots`: contrast-light.png, contrast-light-increased.png, contrast-dark.png, contrast-dark-increased.png.
@MainActor
@Suite(.serialized)
struct ContrastSnapshots {
    static let folder = ProcessInfo.processInfo.environment["CONTRAST_SNAPSHOT_DIR"]
    let temp = Scratch()

    @Test(.enabled(if: folder != nil)) func drawContrast() throws {
        let folder = try #require(Self.folder)
        defer { Contrast.override = nil }
        let sessions = StatusSnapshots.sessions()
        for dark in [false, true] {
            for increased in [false, true] {
                Contrast.override = increased
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let bar = StatusSnapshots.rasterize(StatusIcon.image(for: sessions), appearance)
                let none = temp.url("state")
                let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { none }, cwd: { _ in nil },
                                                                 arguments: { _ in [] }))
                let picture = ContrastPicture(store: store, sessions: sessions, bar: bar, increased: increased)
                let host = NSHostingView(rootView: picture.environment(\.contrastOverride, increased))
                host.appearance = appearance
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = appearance
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                let name = "contrast-\(dark ? "dark" : "light")\(increased ? "-increased" : "").png"
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
    }
}

/// The real popover and sidebar (no sessions: header, banner, footer), their rows, the pill and the menu bar dots.
private struct ContrastPicture: View {
    let store: SessionStore
    let sessions: [Session]
    let bar: NSImage
    let increased: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Increase Contrast \(increased ? "on" : "off") · \(scheme == .dark ? "dark" : "light")").font(.headline)
            HStack(spacing: 24) {
                Image(nsImage: bar).resizable().interpolation(.high)
                    .frame(width: bar.size.width * 2, height: bar.size.height * 2)
                FloatingDots(sessions: sessions, onOpen: { _ in }, onShowList: {})
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 48)
            .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.93))
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 2) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            SessionRow(session: session, index: index, isSelected: index == 0)
                        }
                    }
                    .padding(6)
                    popover(sidebar: false)
                }
                .frame(width: 400)
                // The popover's own background: the material normally (drawn here as the window), solid when increased.
                .background(increased ? Color.solidBackground : Color(nsColor: .windowBackgroundColor))
                VStack(spacing: 0) {
                    VStack(spacing: 2) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            SessionRow(session: session, index: index, isSelected: false, compact: true)
                        }
                    }
                    .padding(6)
                    .contrastBackground(RoundedRectangle(cornerRadius: 12), edge: 0.1)
                    popover(sidebar: true).frame(height: 220).padding(.top, 8)
                }
                .frame(width: 280)
            }
        }
        .padding(16)
        .frame(width: 740, alignment: .leading)
        .background(scheme == .dark ? Color(white: 0.3) : Color(white: 0.8))
    }

    private func popover(sidebar: Bool) -> PopoverView {
        var view = PopoverView(store: store, state: PopoverState(), preferences: Preferences(), onOpen: { _ in },
                               onInstallHooks: {}, onQuit: {})
        view.isSidebar = sidebar
        return view
    }
}
