import SwiftUI
import VibeCore

/// The bar above the terminal: what's selected, its state, and End / Resume / Remove.
struct SessionHeaderView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var host: HostClient
    let actions: WindowActions

    var body: some View {
        HStack(spacing: 10) {
            if let row = model.selectedRow {
                let info = row.hostID.flatMap { id in host.sessions.first { $0.id == id } }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.session?.displayName ?? info?.label ?? "Session").font(.headline).lineLimit(1)
                    Text(details(row, info)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if row.hostID != nil {
                    if actions.isLive(row) {
                        Button("End") { actions.endSession(row) }
                    } else {
                        if actions.canResume(row) { Button("Resume") { actions.resume(row) } }
                        Button("Remove") { actions.remove(row) }
                    }
                }
            } else {
                Spacer()
            }
            hostState
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private func details(_ row: WindowRow, _ info: HostSession?) -> String {
        var parts: [String] = []
        if let cwd = row.cwd { parts.append(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        if let session = row.session { parts.append(session.status.label) }
        if let exit = info?.exit { parts.append("ended · exit \(exit.status)") }
        if let info, info.isLive { parts.append("up \(Durations.short(Date().timeIntervalSince(info.startedAt)))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var hostState: some View {
        switch host.state {
        case .connecting:
            Text("Connecting…").font(.caption).foregroundStyle(.orange)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1)
        case .outdated(let live, let compatible):
            if compatible {
                Text("Older session host until its \(live) session\(live == 1 ? "" : "s") end").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Restart Session Host (ends \(live))") { host.restartHost() }
            }
        case .connected, .notRunning:
            EmptyView()
        }
    }
}
