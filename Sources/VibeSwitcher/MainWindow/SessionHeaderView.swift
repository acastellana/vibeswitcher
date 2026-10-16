import SwiftUI
import VibeCore

/// The bar above the terminal: what's selected, its state, where it runs, and what you can do with it.
struct SessionHeaderView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var host: HostClient
    let actions: WindowActions
    @State private var branch: String?

    var body: some View {
        HStack(spacing: 10) {
            if let row = model.selectedRow {
                AgentMark(kind: row.markKind, status: row.statusColor, hollow: row.statusIsHollow, size: 28)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(row.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                .onTapGesture(count: 2) { if let session = row.session { actions.rename(session) } }
                                .help(row.session != nil ? "Double-click to rename" : "")
                            StatusPill(row: row, now: context.date)
                        }
                        details(row).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                hostState
                buttons(row)
                Menu { RowMenu(row: row, actions: actions) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
            } else {
                Spacer()
                hostState
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .task(id: model.selectedRow?.cwd) {
            guard let cwd = model.selectedRow?.cwd else { return branch = nil }
            branch = await Task.detached(priority: .utility) { GitBranch.current(in: cwd) }.value
        }
    }

    private func details(_ row: WindowRow) -> some View {
        HStack(spacing: 6) {
            if let cwd = row.cwd {
                Text(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")).truncationMode(.head)
            }
            if let branch {
                Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
            }
            if let activity = row.session?.activity {
                Label(activity, systemImage: "gearshape").labelStyle(.titleAndIcon)
            }
            if row.session?.inTerminalApp == true {
                Label("Terminal", systemImage: "macwindow").labelStyle(.titleAndIcon)
            }
        }
    }

    @ViewBuilder private func buttons(_ row: WindowRow) -> some View {
        if let session = row.session, session.inTerminalApp {
            Button { actions.openInTerminal(session) } label: { Label("Open in Terminal", systemImage: "arrow.up.forward.app") }
                .help("Go to its Terminal tab (⌘O)")
        }
        if row.hostID != nil {
            if actions.isLive(row) {
                Button { actions.endSession(row) } label: { Image(systemName: "stop.circle") }
                    .help("End this session (⌘W)")
            } else {
                if actions.canResume(row) {
                    Button { actions.resume(row) } label: { Label("Resume", systemImage: "arrow.clockwise") }
                        .help("Start the agent again on this conversation")
                }
                Button { actions.remove(row) } label: { Image(systemName: "trash") }
                    .help("Remove from the list")
            }
        }
    }

    @ViewBuilder private var hostState: some View {
        switch host.state {
        case .connecting:
            Text("Connecting…").font(.caption).foregroundStyle(.orange)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1)
        case .outdated(_, let compatible):
            let live = host.sessions.filter(\.isLive).count
            if compatible {
                if live > 0 {
                    Text(live == 1 ? "Older session host until its session ends" : "Older session host until its \(live) sessions end")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Restart Session Host (ends \(live))") { host.restartHost() }
            }
        case .connected, .notRunning:
            EmptyView()
        }
    }
}

/// "Needs input · 4m" in the status color.
struct StatusPill: View {
    let row: WindowRow
    let now: Date

    var body: some View {
        let state = row.state(now: now)
        let color = row.statusColor
        HStack(spacing: 4) {
            Text(label(state))
            if let since = state.since {
                Text("· \(Durations.compact(now.timeIntervalSince(since)))").monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.15)))
        .fixedSize()
    }

    private func label(_ state: RowState) -> String {
        switch row.content {
        case .hosted(let info):
            if !info.isLive { return "Ended" }
            return info.agent != nil ? "Starting" : "Shell"
        case .agent(let session):
            return session.isPaused ? "Paused" : session.status.label
        }
    }
}
