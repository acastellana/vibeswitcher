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

    var body: some View {
        HStack(spacing: 5) {
            if store.sessions.isEmpty {
                Image(systemName: "terminal").foregroundStyle(.secondary)
            }
            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                Button { onOpen(session) } label: {
                    ZStack {
                        if session.status == .unknown {
                            Circle().stroke(session.status.color, lineWidth: 1.5)
                        } else {
                            Circle().fill(session.status.color)
                        }
                        Text("\(index + 1)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(session.status == .unknown || session.status == .idle ? Color.primary : Color.white)
                    }
                    .frame(width: 17, height: 17)
                    .padding(2)
                    .overlay {
                        if session.isCurrent { Circle().stroke(Color.primary, lineWidth: 1.5) }
                    }
                }
                .buttonStyle(.plain)
                .help("\(index + 1). \(session.title) · \(session.status.label)")
            }
            Button(action: onShowList) {
                Image(systemName: "list.bullet").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show all sessions")
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
        .fixedSize()
    }
}
