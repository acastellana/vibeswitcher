import AppKit
import SwiftUI
import VibeCore

/// A small always-on-top pill with the same clickable dots as the menu bar icon, for when the menu bar
/// is too crowded to show it (macOS hides overflowing status items under the notch without telling anyone).
/// Drag it by its background; it remembers where you put it and follows you across Spaces.
final class FloatingPanelController {
    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>
    /// Mounted only while the panel is visible, so a hidden panel costs nothing.
    private var content: AnyView = AnyView(EmptyView())

    init(store: SessionStore, onOpen: @escaping (Session) -> Void, onShowList: @escaping (NSView) -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        var anchor: NSView?
        let view = FloatingDotsView(store: store, onOpen: onOpen, onShowList: { if let anchor { onShowList(anchor) } })
        hostingView = FirstMouseHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = hostingView
        anchor = hostingView
        content = AnyView(view)

        if !panel.setFrameUsingName("VibeSwitcherFloatingPanel") { placeUnderMenuBar() }
        panel.setFrameAutosaveName("VibeSwitcherFloatingPanel")
    }

    var isShown: Bool { panel.isVisible }
    var anchorView: NSView { hostingView }

    func setShown(_ shown: Bool) {
        guard shown != panel.isVisible else { return }
        if shown {
            hostingView.rootView = content
            fit()
            panel.orderFrontRegardless()
            DispatchQueue.main.async { self.fit() } // SwiftUI may only settle its size after the first display
        } else {
            panel.orderOut(nil)
            hostingView.rootView = AnyView(EmptyView())
        }
    }

    /// Resize to the content, keeping the right edge fixed (it usually sits in the top-right corner),
    /// and keep the whole pill on screen.
    func fit() {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        frame.origin.x = frame.maxX - size.width
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - size.width - 4)
            frame.origin.y = min(max(frame.minY, visible.minY + 4), visible.maxY - size.height - 4)
        }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func placeUnderMenuBar() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - 200, y: visible.maxY - 8))
    }
}

struct FloatingDotsView: View {
    @ObservedObject var store: SessionStore
    let onOpen: (Session) -> Void
    let onShowList: () -> Void

    // Your own sessions: a lead's workers and verifiers are in the list, under their team.
    var body: some View { FloatingDots(sessions: store.split.own, onOpen: onOpen, onShowList: onShowList) }
}

/// The pill's content for a list of sessions: a dot each, up to the menu bar's `MenuBarDots.maxDots`, then "+N" (the
/// list has the rest), so it never grows across the screen.
struct FloatingDots: View {
    let sessions: [Session]
    let onOpen: (Session) -> Void
    let onShowList: () -> Void
    @IncreasedContrast private var increased

    var body: some View {
        HStack(spacing: 7) {
            if sessions.isEmpty {
                Image(systemName: "terminal").foregroundStyle(.secondaryInk).accessibilityLabel("No sessions")
            }
            ForEach(Array(sessions.prefix(MenuBarDots.maxDots).enumerated()), id: \.element.id) { index, session in
                Button { onOpen(session) } label: {
                    ZStack {
                        if session.dotIsHollow {
                            Circle().stroke(session.dotColor, lineWidth: 1.5)
                        } else {
                            Circle().fill(session.dotColor)
                        }
                        // White on light-mode fills, near-black on dark-mode ones: at least 4.5:1, and 7:1 with Increase
                        // Contrast (StatusPalette).
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(session.dotIsHollow ? Color.primary : SessionStatus.onInk)
                    }
                    .frame(width: 17, height: 17)
                    .padding(2)
                    .overlay {
                        if session.isCurrent { Circle().stroke(Color.primary, lineWidth: 1.5) }
                    }
                    // The status's shape on the corner, so it reads without colour.
                    .overlay(alignment: .bottomTrailing) {
                        StatusMarkView(session: session, size: 8)
                            .padding(1)
                            .background(Circle().fill(increased ? .solidBackground
                                                                                     : Color(nsColor: .windowBackgroundColor)))
                            .offset(x: 2, y: 2)
                    }
                }
                .buttonStyle(.plain)
                .help("\(index + 1). \(session.title) · \(session.status.label)" + (session.isPaused ? " · paused" : ""))
                .accessibilityLabel(StatusSummary.spoken(number: index + 1, name: session.title, status: session.status,
                                                         paused: session.isPaused))
            }
            if sessions.count > MenuBarDots.maxDots {
                let more = sessions.count - MenuBarDots.maxDots
                Text("+\(more)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondaryInk)
                    .help("\(more) more in the list").accessibilityLabel("\(more) more sessions")
            }
            Button(action: onShowList) {
                Image(systemName: "list.bullet").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondaryInk)
                    .accessibilityLabel("Show all sessions")
            }
            .buttonStyle(.plain)
            .help("Show all sessions")
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .contrastBackground(Capsule(), edge: 0.12)
        .fixedSize()
    }
}
