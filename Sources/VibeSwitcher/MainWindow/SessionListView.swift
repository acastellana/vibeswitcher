import SwiftUI
import VibeCore

/// The left pane: sessions grouped by project.
struct SessionListView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var host: HostClient
    let actions: WindowActions

    var body: some View {
        List(selection: $model.selectedID) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        WindowRowView(row: row, info: row.hostID.flatMap { id in host.sessions.first { $0.id == id } })
                            .tag(row.id as String?)
                            .contextMenu { RowMenu(row: row, actions: actions) }
                    }
                } header: {
                    HStack {
                        Text(section.project)
                        Spacer()
                        NewSessionMenu(folder: section.rows.first?.cwd, actions: actions)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.sections.isEmpty {
                VStack(spacing: 8) {
                    Text("No sessions").foregroundStyle(.secondary)
                    NewSessionMenu(folder: nil, actions: actions, title: "New Session")
                }
            }
        }
    }
}

struct WindowRowView: View {
    let row: WindowRow
    /// The session host's record, for window sessions.
    let info: HostSession?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 0)
                    if let agent = row.session?.agent ?? info?.agent.flatMap(Agent.init(rawValue:)) { AgentBadge(agent: agent).fixedSize() }
                    if row.session?.inTerminalApp == true {
                        Image(systemName: "terminal").font(.caption2).foregroundStyle(.secondary)
                            .help("Runs in Terminal")
                    }
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(isEnded || row.session?.isPaused == true ? 0.55 : 1)
    }

    private var isEnded: Bool { info?.isLive == false }

    private var title: String {
        if let session = row.session { return session.customName ?? session.task ?? session.displayName }
        if let info, !info.title.isEmpty { return info.title }
        return info?.label ?? "Session"
    }

    private var subtitle: String? {
        if let exit = info?.exit {
            return "ended \(Durations.short(Date().timeIntervalSince(exit.at))) ago · exit \(exit.status)"
        }
        if let session = row.session {
            if let activity = session.activity, let since = session.activitySince {
                return "⚙ \(activity) · \(Durations.short(Date().timeIntervalSince(since)))"
            }
            return session.detail ?? session.status.label
        }
        if info?.agent != nil { return "Starting…" }
        return info.map { SessionNaming.name(forProjectRoot: $0.cwd) }.map { "Shell · \($0)" }
    }

    private var dotColor: Color {
        if isEnded { return .gray.opacity(0.5) }
        if let session = row.session { return session.isPaused ? Color(nsColor: Session.pausedNSColor) : session.status.color }
        return info?.agent != nil ? .orange.opacity(0.6) : .secondary
    }
}

struct RowMenu: View {
    let row: WindowRow
    let actions: WindowActions

    var body: some View {
        if let session = row.session {
            Button("Rename…") { actions.rename(session) }
            if session.isPaused {
                Button("Resume Notifications") { actions.resumePaused(session) }
            } else {
                Menu("Pause") {
                    Button("Until I Resume It") { actions.pause(session, .indefinitely) }
                    Button("For 1 Hour") { actions.pause(session, .hours(1)) }
                    Button("Until Tomorrow Morning") { actions.pause(session, .untilTomorrowMorning) }
                    Button("For 1 Week") { actions.pause(session, .hours(24 * 7)) }
                }
            }
            if session.inTerminalApp { Button("Open in Terminal") { actions.openInTerminal(session) } }
        }
        if row.hostID != nil {
            Divider()
            if actions.isLive(row) {
                Button("End Session…") { actions.endSession(row) }
            } else {
                if actions.canResume(row) { Button("Resume") { actions.resume(row) } }
                Button("Remove") { actions.remove(row) }
            }
        }
        if let cwd = row.cwd {
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
        }
    }
}

/// ⊕: the folder's presets (its default first).
struct NewSessionMenu: View {
    let folder: String?
    let actions: WindowActions
    var title: String?

    var body: some View {
        Menu {
            ForEach(actions.presets(folder)) { preset in
                Button(preset.name) { actions.newSession(preset, folder) }
            }
        } label: {
            if let title { Text(title) } else { Image(systemName: "plus") }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New session in this project")
    }
}
