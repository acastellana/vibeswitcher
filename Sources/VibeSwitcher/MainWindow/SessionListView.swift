import SwiftUI
import VibeCore

/// The left pane: sessions grouped by what they need from you (or by project), a filter and a summary.
struct SessionListView: View {
    @ObservedObject var model: WindowModel
    let actions: WindowActions
    @FocusState private var filterFocused: Bool

    var body: some View {
        let sections = model.displayedSections
        List(selection: $model.selectedID) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        WindowRowView(row: row, showProject: model.grouping == .attention)
                            .tag(row.id as String?)
                            .contextMenu { RowMenu(row: row, actions: actions) }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(section.project)
                        Text("\(section.rows.count)").foregroundStyle(.tertiary).monospacedDigit()
                        Spacer()
                        if model.grouping == .projects {
                            NewSessionMenu(folder: section.rows.first?.cwd, actions: actions)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if sections.isEmpty {
                if model.sections.isEmpty {
                    VStack(spacing: 8) {
                        Text("No sessions").foregroundStyle(.secondary)
                        NewSessionMenu(folder: nil, actions: actions, title: "New Session")
                    }
                } else {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Group", selection: $model.grouping) {
                Text("Attention").tag(WindowGrouping.attention)
                Text("Projects").tag(WindowGrouping.projects)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("Filter", text: $model.filter)
                        .textFieldStyle(.plain)
                        .focused($filterFocused)
                        .onExitCommand { model.filter = ""; filterFocused = false }
                    if !model.filter.isEmpty {
                        Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let summary = WindowGroups.summary(model.allRows, now: context.date)
                    Text(summary.isEmpty ? countText : summary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .onChange(of: model.filterFocusRequests) { filterFocused = true }
    }

    private var countText: String {
        let count = model.allRows.count
        return count == 1 ? "1 session" : "\(count) sessions"
    }
}

struct WindowRowView: View {
    let row: WindowRow
    /// The project on the second line (the Attention grouping mixes projects).
    let showProject: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let state = row.state(now: context.date)
            HStack(spacing: 9) {
                AgentMark(kind: row.markKind, status: row.statusColor, hollow: row.statusIsHollow)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let since = state.since {
                            Text(Durations.compact(context.date.timeIntervalSince(since)))
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    HStack(spacing: 4) {
                        if showProject {
                            Text(row.project).foregroundStyle(.secondary)
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Text(state.text).foregroundStyle(state.group == .needsYou ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        Spacer(minLength: 0)
                        if row.session?.inTerminalApp == true {
                            Image(systemName: "macwindow").foregroundStyle(.tertiary).help("Runs in Terminal")
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }
            }
            .padding(.vertical, 3)
            .opacity(row.isDimmed ? 0.55 : 1)
        }
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
            if MoveToWindow.canMove(session) { Button("Move to Window…") { actions.moveToWindow(session) } }
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
        if row.session?.agentSessionID != nil || actions.resumeCommand(row) != nil {
            Divider()
            if let id = row.session?.agentSessionID { Button("Copy Session ID") { Pasteboard.copy(id) } }
            if let command = actions.resumeCommand(row) { Button("Copy Resume Command") { Pasteboard.copy(command) } }
        }
        if let cwd = row.cwd {
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
