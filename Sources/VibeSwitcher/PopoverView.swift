import SwiftUI
import VibeCore

/// Selection shared between the SwiftUI list and the AppKit key monitor (arrows / 1–9 / return).
final class PopoverState: ObservableObject {
    @Published var selectedIndex = 0
}

struct PopoverView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var state: PopoverState
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
                            SessionRow(session: session, index: index, isSelected: index == state.selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { onOpen(session) }
                                .onHover { if $0 { state.selectedIndex = index } }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 460)
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
            Text("⌃⌥V toggle · 1–9 jump · ↑↓ ⏎").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit", action: onQuit).buttonStyle(.borderless).controlSize(.small)
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
            ZStack {
                Circle().fill(session.status.color).frame(width: 12, height: 12)
                if session.status == .working {
                    Circle().stroke(session.status.color.opacity(0.35), lineWidth: 3).frame(width: 18, height: 18)
                }
            }
            .frame(width: 18, height: 18)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if index < 9 {
                        Text("\(index + 1)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    AgentBadge(agent: session.agent)
                    Text(session.status.label).foregroundStyle(session.status.color)
                    if session.statusSince > Date.distantPast.addingTimeInterval(1) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.elapsed(from: session.statusSince, to: context.date))
                        }
                    }
                    if let cwd = session.shortCwd {
                        Text(cwd).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let detail = session.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.15) : .clear))
        .help("\(session.agent.displayName) · \(session.tty) · pid \(session.pid)")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
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
