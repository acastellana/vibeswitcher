import AppKit
import SwiftUI
import VibeCore

/// One thing the palette can do: go to a session, start one, or run a window command.
struct PaletteItem: Identifiable {
    enum Icon {
        case mark(MarkKind, Color?)
        case symbol(String)
    }

    let id: String
    let title: String
    let subtitle: String
    let icon: Icon
    let run: () -> Void

    var searchText: String { "\(title) \(subtitle)" }
}

/// ⌘K: a floating search over sessions and commands, over the window.
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    var isShown: Bool { panel != nil }

    func show(over window: NSWindow, items: [PaletteItem]) {
        close()
        let size = NSSize(width: 620, height: 420)
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        let view = CommandPaletteView(items: items) { [weak self] item in
            self?.close()
            window.makeKey()
            item?.run()
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        let frame = window.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - 90 - size.height))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKey()
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct CommandPaletteView: View {
    let items: [PaletteItem]
    /// Closes the palette, running the chosen item (nil: just close).
    let finish: (PaletteItem?) -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        Array(FuzzyMatch.rank(items, query: query) { $0.searchText }.prefix(50))
    }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
                TextField("Go to a session or run a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { finish(results.indices.contains(selection) ? results[selection] : nil) }
                    .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
                    .onKeyPress(.downArrow) { selection = min(results.count - 1, selection + 1); return .handled }
                    .onKeyPress(.escape) { finish(nil); return .handled }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, selected: index == selection)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { finish(item) }
                        }
                        if results.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).padding(.top, 40)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .onChange(of: query) { selection = 0 }
        .onAppear { focused = true }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch item.icon {
            case .mark(let kind, let status):
                AgentMark(kind: kind, status: status, size: 22)
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 13)).frame(width: 22, height: 22)
                    .foregroundStyle(selected ? .white : .secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : .clear))
    }
}
