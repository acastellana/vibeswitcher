import AppKit
import SwiftUI
import VibeCore

/// Selection shared between the SwiftUI list and the AppKit key monitor (arrows / 1–9 / return).
final class PopoverState: ObservableObject {
    @Published var selectedIndex = 0
}

struct PopoverView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var state: PopoverState
    @ObservedObject var preferences: Preferences
    let onOpen: (Session) -> Void
    let onInstallHooks: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.sessions.isEmpty {
                Text("No Claude Code or Codex sessions running in a terminal.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                            Button { onOpen(session) } label: {
                                SessionRow(session: session, index: index, isSelected: index == state.selectedIndex)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { state.selectedIndex = index } }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 640)
                .fixedSize(horizontal: false, vertical: true)
            }
            banners
            Divider()
            footer
        }
        .frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("VibeSwitcher").font(.headline)
            Spacer()
            ForEach([SessionStatus.needsInput, .working, .done], id: \.self) { status in
                let count = store.sessions.filter { $0.status == status }.count
                if count > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(status.color).frame(width: 8, height: 8)
                        Text("\(count) \(status.label.lowercased())").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    @ViewBuilder private var banners: some View {
        if store.terminalAccess == .denied {
            Banner(text: "Allow VibeSwitcher to control Terminal in System Settings › Privacy & Security › Automation to see tab titles and jump to tabs.")
        }
        let missing = Agent.allCases.filter { store.hooksInstalled[$0] != true }
        if !missing.isEmpty {
            HStack {
                Text("Live status needs hooks for \(missing.map(\.displayName).joined(separator: " & ")).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Install hooks", action: onInstallHooks).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack {
            Text("Click a dot to switch · right-click or ⌃⌥V for this list · 1–9").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Menu {
                Toggle("Notify when a session needs input", isOn: $preferences.notifyNeedsInput)
                Toggle("Notify when a session finishes", isOn: $preferences.notifyDone)
                Divider()
                Toggle("Launch at login", isOn: Binding(get: { preferences.launchAtLogin },
                                                        set: { preferences.setLaunchAtLogin($0) }))
                Divider()
                Button("Reinstall hooks", action: onInstallHooks)
                Button("Quit VibeSwitcher", action: onQuit)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct Banner: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12))
    }
}

struct SessionRow: View {
    let session: Session
    let index: Int
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NumberBadge(number: index + 1, status: session.status)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.project)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1).truncationMode(.middle)
                    AgentBadge(agent: session.agent)
                    Spacer(minLength: 6)
                    HStack(spacing: 4) {
                        Text(session.status.label).foregroundStyle(session.status.color)
                        if session.statusSince > Date.distantPast.addingTimeInterval(1) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Self.elapsed(from: session.statusSince, to: context.date))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption.weight(.medium))
                }
                if let task = session.task {
                    Text(task).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
                }
                if let detail = session.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(session.status == .needsInput ? 2 : 1)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.15) : .clear))
        .help("\(session.shortCwd ?? session.project) · \(session.agent.displayName) · \(session.tty)")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

/// The row's number inside its status color: row 3 is the 3rd dot in the menu bar.
private struct NumberBadge: View {
    let number: Int
    let status: SessionStatus

    var body: some View {
        ZStack {
            if status == .unknown {
                Circle().stroke(status.color, lineWidth: 1.5)
            } else {
                Circle().fill(status.color)
            }
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(status == .unknown || status == .idle ? Color.primary : Color.white)
        }
        .frame(width: 20, height: 20)
        .overlay {
            if status == .working {
                Circle().stroke(status.color.opacity(0.35), lineWidth: 3).frame(width: 25, height: 25)
            }
        }
    }
}

private struct AgentBadge: View {
    let agent: Agent
    var body: some View {
        Text(agent == .claude ? "Claude" : "Codex")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(agent == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : .primary)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.4)))
    }
}

/// Hosting view that reacts to the first click even when VibeSwitcher is not the active app.
/// Without this, macOS 14+ often leaves the popover non-key and the first click on a row only
/// focuses the popover instead of opening the session.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
