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
                            Text(row.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).layoutPriority(1)
                                .onTapGesture(count: 2) { if let session = row.session { actions.rename(session) } }
                                .help(row.session != nil ? "Double-click to rename" : "")
                            StatusPill(row: row, now: context.date)
                        }
                        details(row).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                hostState
                if model.chatPath(for: row) != nil {
                    Picker("View", selection: $model.showsChat) {
                        Image(systemName: "terminal").help("Terminal (⌥⌘1)").tag(false)
                        Image(systemName: "bubble.left.and.text.bubble.right").help("Chat (⌥⌘2)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                buttons(row)
                Menu { RowMenu(row: row, actions: actions) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
            } else {
                Label("Start page", systemImage: "house").font(.system(size: 14, weight: .semibold))
                Spacer()
                hostState
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        // Re-read as the agent works (it may switch branches).
        .task(id: "\(model.selectedRow?.cwd ?? "")|\(model.selectedRow?.session?.eventAt ?? 0)") {
            guard let cwd = model.selectedRow?.cwd else { return branch = nil }
            branch = await Task.detached(priority: .utility) { GitBranch.current(in: cwd) }.value
        }
    }

    private func details(_ row: WindowRow) -> some View {
        var parts: [String] = []
        if let cwd = row.cwd { parts.append(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        if let branch { parts.append("⎇ \(branch)") }
        if row.session?.inTerminalApp == true { parts.append("in Terminal") }
        if let activity = row.session?.activity { parts.append(activity) }
        return Text(parts.joined(separator: "  ·  "))
    }

    @ViewBuilder private func buttons(_ row: WindowRow) -> some View {
        if let session = row.session, session.inTerminalApp {
            Button { actions.openInTerminal(session) } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Open in Terminal (⌘O)")
        }
        if row.hostID != nil {
            if actions.isLive(row) {
                Button { actions.endSession(row) } label: { Image(systemName: "stop.circle") }
                    .help("End this session… (⇧⌘⌫)")
            } else {
                if actions.canResume(row) {
                    Button { actions.resume(row) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Resume: start the agent again on this conversation")
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
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .help(live == 1 ? "An older session host runs this window's session; it's replaced once that session ends."
                                        : "An older session host runs this window's \(live) sessions; it's replaced once they end.")
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
            return state.group == .working ? "Starting" : "Shell"
        case .agent(let session):
            return session.isPaused ? "Paused" : session.status.label
        }
    }
}
