import AppKit
import SwiftUI
import VibeCore

/// Selection shared between the SwiftUI list and the AppKit key monitor (arrows / 1–9 / return).
final class PopoverState: ObservableObject {
    @Published var selectedIndex = 0
    @Published var recentProjects: [RecentProjects.Candidate] = []
}

struct PopoverView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var state: PopoverState
    @ObservedObject var preferences: Preferences
    let onOpen: (Session) -> Void
    let onInstallHooks: () -> Void
    let onQuit: () -> Void
    var onRename: (Session) -> Void = { _ in }
    var onResetName: (Session) -> Void = { _ in }
    var onNewSession: (Agent, String?) -> Void = { _, _ in }
    var onEditCommands: () -> Void = {}
    /// Rendered as the docked sidebar instead of the menu bar popover.
    var isSidebar = false

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
                                SessionRow(session: session, index: index, isSelected: index == state.selectedIndex, compact: isSidebar)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { state.selectedIndex = index } }
                            .contextMenu {
                                Button("Switch to Session") { onOpen(session) }
                                Divider()
                                Button("Rename…") { onRename(session) }
                                if session.customName != nil {
                                    Button("Reset Name to “\(session.project)”") { onResetName(session) }
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: isSidebar ? .infinity : 640)
                .fixedSize(horizontal: false, vertical: true)
            }
            banners
            Divider()
            footer
        }
        .frame(width: isSidebar ? nil : 400)
        .frame(maxWidth: isSidebar ? .infinity : nil, maxHeight: isSidebar ? .infinity : nil, alignment: .top)
        .background {
            if isSidebar {
                RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(isSidebar ? "Sessions" : "VibeSwitcher").font(.headline).lineLimit(1).fixedSize()
            newSessionMenu
            Spacer()
            ForEach([SessionStatus.needsInput, .working, .background, .done], id: \.self) { status in
                let count = store.sessions.filter { $0.status == status }.count
                if count > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(status.color).frame(width: 8, height: 8)
                        Text(isSidebar ? "\(count)" : "\(count) \(status.label.lowercased())")
                            .font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                    .help("\(count) \(status.label.lowercased())")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var newSessionMenu: some View {
        Menu {
            if !state.recentProjects.isEmpty {
                Section("Recent projects") {
                    ForEach(state.recentProjects, id: \.path) { project in
                        Menu(Self.menuLabel(for: project.path)) {
                            Button("Claude Code") { onNewSession(.claude, project.path) }
                            Button("Codex") { onNewSession(.codex, project.path) }
                        }
                    }
                }
            }
            Menu("Other Folder…") {
                Button("Claude Code") { onNewSession(.claude, nil) }
                Button("Codex") { onNewSession(.codex, nil) }
            }
            Divider()
            Button("Launch Commands…", action: onEditCommands)
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Start a new session")
    }

    /// "vibeswitcher — ~/dev"
    static func menuLabel(for path: String) -> String {
        let name = SessionNaming.name(forProjectRoot: path)
        var parent = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        if parent.hasPrefix(home) { parent = "~" + parent.dropFirst(home.count) }
        return "\(name) — \(parent)"
    }

    @ViewBuilder private var banners: some View {
        if store.terminalAccess == .denied {
            Banner(text: "Allow VibeSwitcher to control Terminal in System Settings › Privacy & Security › Automation to see tab titles and jump to tabs.")
        }
        if !preferences.notificationsAllowed {
            HStack {
                Text("Notifications are off, so you won't get a banner when a session needs you.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Turn on…") { Notifier.openSettings() }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
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
            if isSidebar {
                Button("Exit Sidebar Mode") { preferences.sidebarMode = false }
                    .buttonStyle(.borderless).controlSize(.small)
            } else {
                Text("Click a dot to switch · right-click or ⌃⌥V for this list · 1–9").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Toggle("Notify when a session needs input", isOn: $preferences.notifyNeedsInput)
                Toggle("Notify when a session finishes", isOn: $preferences.notifyDone)
                Toggle("Play sound when a session needs input", isOn: $preferences.playSound)
                Toggle("Sidebar mode", isOn: $preferences.sidebarMode)
                Toggle("Auto-hide sidebar (show at right edge)", isOn: $preferences.sidebarAutoHide)
                    .disabled(!preferences.sidebarMode)
                Divider()
                Picker("Order sessions", selection: $preferences.sessionOrder) {
                    ForEach(SessionOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Floating dots panel", selection: $preferences.floatingPanel) {
                    ForEach(FloatingPanelMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
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
    /// Narrow sidebar layout: name gets the whole first line; badge moves next to the task.
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NumberBadge(number: index + 1, status: session.status, isCurrent: session.isCurrent)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1).truncationMode(.middle)
                    if !compact { AgentBadge(agent: session.agent) }
                    if session.customName != nil, !compact {
                        Text(session.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !compact, let desktop = session.screenPosition?.desktop {
                        Text("Desktop \(desktop)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help("Mission Control desktop this session's Terminal window is on")
                    }
                    if session.isCurrent, !compact {
                        Label("Viewing", systemImage: "eye.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .help("The Terminal tab you're looking at right now")
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 4) {
                        if !compact { Text(session.status.label).foregroundStyle(session.status.color) }
                        if session.statusSince > Date.distantPast.addingTimeInterval(1) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Self.elapsed(from: session.statusSince, to: context.date))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption.weight(.medium))
                }
                if compact {
                    HStack(spacing: 5) {
                        AgentBadge(agent: session.agent)
                        Text(session.task ?? session.project).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                    }
                } else if let task = session.task {
                    Text(task).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
                }
                if let activity = session.activity, let since = session.activitySince {
                    // Live: what it's running and for how long; long calls turn orange so a hung one stands out.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = context.date.timeIntervalSince(since)
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape.2").imageScale(.small)
                            Text(activity).lineLimit(1).truncationMode(.middle)
                            Text("· " + Self.elapsed(from: since, to: context.date))
                                .foregroundStyle(seconds > 600 ? AnyShapeStyle(SessionStatus.working.color) : AnyShapeStyle(.secondary))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let detail = session.detail {
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
    var isCurrent = false

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
            if isCurrent {
                Circle().stroke(Color.primary, lineWidth: 1.5).frame(width: 25, height: 25)
            }
        }
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
