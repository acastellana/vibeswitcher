import SwiftUI
import VibeCore

/// The left pane: sessions grouped by what they need from you (or by project), a filter and a summary.
struct SessionListView: View {
    @ObservedObject var model: WindowModel
    /// Leads' boards, for their team's summary.
    @ObservedObject var leads: LeadController
    let actions: WindowActions
    @FocusState private var filterFocused: Bool
    /// The list's selection, passed on to the model once the list's update is over. A click sets it while SwiftUI
    /// updates views: the model publishing right then is a fault ("Publishing changes from within view updates"),
    /// one for each view that watches it.
    @State private var selection: String?

    init(model: WindowModel, leads: LeadController, actions: WindowActions) {
        self.model = model
        self.leads = leads
        self.actions = actions
        _selection = State(initialValue: model.selectedID)
    }

    var body: some View {
        let arranged = model.arranged
        let (sections, ended) = model.folded(arranged)
        // The groups' headers are rows of their own, not Sections: AppKit keeps the sidebar group row under the pointer
        // (its Show/Hide button's) without retaining it and never forgets it when the row goes, so a group that left
        // the list while hovered (the attention grouping moving its rows, a project's last session ending) was looked
        // up again once freed: the crash of 2026-10-23, in NSOutlineView rowForItem: under SwiftUI's diff expanding a
        // group. Without group rows there's nothing for it to keep (SidebarDiffTests).
        List(selection: $selection) {
            ForEach(sections) { section in
                HStack(spacing: 6) {
                    Text(section.project).accessibilityAddTraits(.isHeader)
                    Text("\(section.rows.count)").foregroundStyle(.tertiary).monospacedDigit()
                    Spacer()
                    if model.grouping == .projects {
                        NewSessionMenu(folder: section.rows.first?.cwd, actions: actions)
                    }
                }
                .groupHeader()
                // Ended sessions of finished tasks leave with them (WL-1).
                ForEach(section.rows.filter { !arranged.nested.contains($0.id) || !TeamRows.isHistory($0, boards: leads.boards, now: Date()) }) { row in
                    rowView(row, arranged: arranged)
                }
            }
            // Ended sessions fold away at the end (WL-1); Resume and Remove are in their menu, as anywhere.
            if !ended.isEmpty {
                EndedHeader(count: ended.count, open: $model.endedOpen).groupHeader()
                if model.endedOpen {
                    ForEach(ended) { row in rowView(row, arranged: arranged, showProject: true) }  // from any project
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if sections.isEmpty, ended.isEmpty {
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
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Filter", text: $model.filter)
                        .textFieldStyle(.plain)
                        .focused($filterFocused)
                        .onExitCommand { model.filter = ""; filterFocused = false }
                    if !model.filter.isEmpty {
                        Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill").accessibilityLabel("Clear filter") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Clear the filter")
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                TimelineView(.ticking(every: 30)) { context in
                    let summary = WindowGroups.summary(model.allRows, now: context.date)
                    Text(summary.isEmpty ? countText : summary)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .onChange(of: model.filterFocusRequests) { filterFocused = true }
        .onChange(of: selection) { if model.selectedID != selection { model.selectedID = selection } }
        .onChange(of: model.selectedID) { if selection != model.selectedID { selection = model.selectedID } }
    }

    private func rowView(_ row: WindowRow, arranged: LeadTeams.Arranged, showProject: Bool? = nil) -> some View {
        WindowRowView(row: row, showProject: showProject ?? (model.grouping == .attention), role: model.role(of: row),
                      team: arranged.teams[row.id], teamSummary: teamSummary(row, team: arranged.teams[row.id]),
                      questions: model.role(of: row) == .lead ? leads.lead(for: row).map { ($0.board.openQuestions.count, $0.board.blockingQuestions) } : nil,
                      allDone: model.role(of: row) == .lead && leads.lead(for: row)?.board.hasUnseenAllDone == true,
                      label: model.label(of:), replaced: model.replaced(row), nested: arranged.nested.contains(row.id),
                      teamOpen: model.expandedTeams.contains(row.id)) { model.toggleTeam(row.id) }
            .tag(row.id as String?)
            .contextMenu { RowMenu(row: row, actions: actions) }
    }

    /// The lead row's "team: 2 working · 1 in review", from the board's tasks as their rows read them (a worker that
    /// hasn't begun isn't idle); nil without a board. Made again only when the board or its team's sessions change
    /// (`TeamRowsCache`), never as the row's clock ticks.
    private func teamSummary(_ row: WindowRow, team: [WindowRow]?) -> String? {
        guard let team, !team.isEmpty, let lead = leads.lead(for: row) else { return nil }
        let key = "sidebar|" + lead.root
        let seen = leads.teamRows.seen(key, board: lead.board, rows: team, now: Date())
        return TeamRows.summary(leads.teamRows.rows(key, board: lead.board, seen: seen))
    }

    private var countText: String {
        let count = model.allRows.count
        return count == 1 ? "1 session" : "\(count) sessions"
    }
}

private extension View {
    /// A group's header as a row of the sidebar: a section header's type, never selected.
    func groupHeader() -> some View {
        font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .selectionDisabled()
    }
}

extension SessionEnd {
    /// A failed end's orange: the status palette's, at least 4.5:1 in light and dark (the system orange isn't on a
    /// light sidebar).
    static var failureColor: Color { SessionStatus.working.color }
    var color: Color { isFailure ? Self.failureColor : .secondary }
}

/// "› Ended 3": the header of the fold that holds ended sessions, in the sidebar and on Home.
struct EndedHeader: View {
    let count: Int
    @Binding var open: Bool
    var font: Font = .system(size: 11, weight: .semibold)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
                Text(StateWord.ended.label)
                Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
                Spacer(minLength: 0)
            }
            .font(font)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(open ? "Hide the ended sessions" : "Show the ended sessions")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(StateWord.ended.label), \(count == 1 ? "1 session" : "\(count) sessions")")
        .accessibilityValue(open ? "expanded" : "collapsed")
        .accessibilityHint(open ? "Hides the ended sessions" : "Shows the ended sessions")
        .accessibilityAddTraits([.isHeader, .isButton])
    }
}

struct WindowRowView: View {
    let row: WindowRow
    /// The project on the second line (the Attention grouping mixes projects).
    let showProject: Bool
    var role: LeadLaunch.Role?
    /// A lead's team (folded under it).
    var team: [WindowRow]?
    /// The lead's "team: 2 working · 1 in review", from its board (nil: from the team's rows alone).
    var teamSummary: String?
    /// A lead's open questions for you, and how many of them block.
    var questions: (open: Int, blocking: Int)?
    /// A lead whose board cleared (every task finished) since you last opened it: a green check.
    var allDone = false
    /// Window sessions' labels (who's a verifier).
    var label: (WindowRow) -> String? = { $0.hosted?.label }
    /// A lead another session replaced: it says where to continue instead of its status.
    var replaced: ReplacedLead?
    /// A team row shown under its lead.
    var nested = false
    var teamOpen = false
    var toggleTeam: () -> Void = {}

    var body: some View {
        TimelineView(.ticking(every: 30)) { context in
            // A normal end (VibeSwitcher's, or exit 0) doesn't read as a failure (`SessionEnd`).
            let state = replaced?.rowState ?? row.state(now: context.date)
            HStack(spacing: 9) {
                if nested {
                    Image(systemName: role == .verifier ? "checkmark.seal" : "hammer").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .accessibilityLabel(role == .verifier ? "Verifier" : "Worker")
                        .frame(width: 12).padding(.leading, 8)
                }
                AgentMark(kind: row.markKind, status: row.statusColor, hollow: row.statusIsHollow, size: nested ? 18 : 22, mark: row.statusMark,
                          spoken: row.spokenStatus, statusFirst: true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if role == .lead {
                            Text("LEAD").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                                .foregroundStyle(.white).background(Capsule().fill(replaced == nil ? Color.accentColor : Color.gray))
                        }
                        Text(row.title).font(.system(size: nested ? 12 : 13, weight: .medium)).lineLimit(1)
                        if allDone {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(SessionStatus.done.color)
                                .help("All tasks finished")
                                .accessibilityLabel("All tasks finished")
                        }
                        Spacer(minLength: 4)
                        if let since = state.since {
                            Text(Durations.short(context.date.timeIntervalSince(since)))
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    HStack(spacing: 4) {
                        if showProject, !nested {
                            Text(row.project).foregroundStyle(.secondary)
                            Text("·").foregroundStyle(.tertiary)
                        }
                        if replaced != nil {
                            // A shape as well as the colour; the words beside it say "replaced".
                            Image(systemName: "arrow.turn.up.right").foregroundStyle(ReplacedLead.color).accessibilityHidden(true)
                        }
                        let failed = replaced == nil && row.end?.isFailure == true
                        if failed, let end = row.end {
                            // A shape as well as the colour; the words beside it say the exit code.
                            Image(systemName: end.symbol).foregroundStyle(SessionEnd.failureColor).accessibilityHidden(true)
                        }
                        Text(state.text).foregroundStyle(replaced != nil ? AnyShapeStyle(ReplacedLead.color)
                            : failed ? AnyShapeStyle(SessionEnd.failureColor)
                            : state.group == .needsYou ? AnyShapeStyle(SessionStatus.needsInput.color) : AnyShapeStyle(.secondary))
                        if let questions, questions.open > 0 {
                            Text("·").foregroundStyle(.tertiary)
                            Label("\(questions.open)", systemImage: "questionmark.bubble.fill")
                                .labelStyle(.titleAndIcon).fontWeight(.medium)
                                .foregroundStyle(questions.blocking > 0 ? Color.red : Color.orange)
                                .help(questionCount(questions.open) + (questions.blocking > 0 ? " (\(questions.blocking) blocking)" : ""))
                        }
                        if let team, !team.isEmpty {
                            Text("·").foregroundStyle(.tertiary)
                            Button(action: toggleTeam) {
                                HStack(spacing: 2) {
                                    // From the board's tasks where there's one (a worker that hasn't begun isn't idle).
                                    Text(teamSummary ?? LeadTeams.summary(team, label: label, board: nil, now: context.date))
                                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(teamOpen ? 90 : 0))
                                        .accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            .help(teamOpen ? "Hide the team" : "Show the team")
                        }
                        Spacer(minLength: 0)
                        if row.session?.inTerminalApp == true {
                            Image(systemName: "macwindow").foregroundStyle(.tertiary).help("Runs in Terminal")
                                .accessibilityLabel("Runs in Terminal")
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }
            }
            .padding(.vertical, 3)
            // A failed end stays at full strength: it's worth a look.
            .opacity(row.isDimmed && row.end?.isFailure != true ? 0.55 : 1)
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
            Divider()
            let lead = Self.leadItem(folder: folder, actions: actions)
            Button(lead.title, action: lead.action)
        } label: {
            if let title {
                Text(title)
            } else {
                Image(systemName: "plus")
                    .accessibilityLabel(folder.map { "New session in \(($0 as NSString).lastPathComponent)" } ?? "New session")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New session in this project")
    }

    /// The menu's lead: the folder's, or with no folder (the empty sidebar) one you choose, as Home's Choose Folder….
    static func leadItem(folder: String?, actions: WindowActions) -> (title: String, action: () -> Void) {
        guard let folder else { return ("Project Lead…", actions.chooseFolderForLead) }
        return ("Project Lead", { actions.startLead(folder) })
    }
}
