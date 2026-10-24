import SwiftUI
import VibeCore

/// Shown when no session is selected: recent projects with their presets, and the keys worth knowing.
struct StartPage: View {
    @ObservedObject var model: WindowModel
    let actions: WindowActions
    @State private var newProject = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start a session").font(.system(size: 26, weight: .bold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                if !model.recentProjects.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(model.recentProjects.prefix(8).enumerated()), id: \.element) { index, path in
                            if index > 0 { Divider().padding(.leading, 44) }
                            ProjectRow(path: path, presets: actions.presets(path), startLead: { actions.startLead(path) }) { actions.newSession($0, path) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
                }
                HStack(spacing: 10) {
                    Button { actions.newSession(nil, nil) } label: { Label("Choose Folder…", systemImage: "folder.badge.plus") }
                    Button { newProject = true } label: { Label("New Project…", systemImage: "plus.rectangle.on.folder") }
                        .accessibilityLabel("New project")
                        .help("Make a project in your projects folder (Settings › General), with git and a first commit")
                }
                let ended = model.endedRows
                if !ended.isEmpty {
                    EndedSessions(rows: ended, open: $model.homeEndedOpen, model: model, actions: actions)
                }
                Shortcuts()
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $newProject) {
            NewProjectSheet(model: NewProjectModel(location: actions.projectsFolder()),
                            created: actions.projectCreated, close: { newProject = false })
        }
    }

    private var subtitle: String {
        let summary = WindowGroups.summary(model.allRows)
        return summary.isEmpty ? "Pick a project, or press ⌘K to jump anywhere." : "\(summary.prefix(1).uppercased())\(summary.dropFirst()). ⌘J goes to the next one waiting on you."
    }
}

private struct ProjectRow: View {
    let path: String
    let presets: [LaunchPreset]
    let startLead: () -> Void
    let start: (LaunchPreset) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: startLead) { Label("Lead", systemImage: "person.3") }.controlSize(.small)
                .help("Start the project lead: you talk to it, it runs workers and merges what passes review")
            ForEach(Array(presets.prefix(3).enumerated()), id: \.element.id) { index, preset in
                if index == 0 {
                    Button(preset.name) { start(preset) }.buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button(preset.name) { start(preset) }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct Shortcuts: View {
    private let keys: [(String, String)] = [
        ("⌘K", "Jump to any session or command"), ("⌘J", "Next session needing you"), ("⌘1–9", "Go to a session"),
        ("⌘N", "New session in this project"), ("⌥⌘F", "Filter the list"), ("⇧⌘H", "This page"),
        ("Lead", "A project lead: tell it what to build; it runs workers, checks their work, merges"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(keys, id: \.0) { key, text in
                GridRow {
                    Text(key).font(.system(size: 12, weight: .medium).monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(.tertiary))
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Along the bottom of an ended window session's terminal: how it ended, and Resume / Remove.
struct EndedBar: View {
    @ObservedObject var model: WindowModel
    let actions: WindowActions

    var body: some View {
        if let row = model.selectedRow, let info = row.hosted, let exit = info.exit {
            let end = SessionEnd(status: exit.status)
            let at = exit.at.formatted(date: .omitted, time: .shortened)
            HStack(spacing: 10) {
                Image(systemName: end.symbol)
                    .foregroundStyle(end.color)
                    .accessibilityHidden(true)  // the line next to it says how it ended
                // "Ended 14:02", "Finished 14:02", "Ended 14:02 · exit 1" (orange).
                (Text("\(end.isFailure ? "Ended" : end.text.capitalized) \(at)").foregroundStyle(.secondary)
                    + (end.isFailure ? Text(" · \(end.text)").foregroundStyle(SessionEnd.failureColor) : Text("")))
                    .font(.system(size: 12))
                Spacer()
                if actions.canResume(row) {
                    Button { actions.resume(row) } label: { Label("Resume", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button("Remove") { actions.remove(row) }.controlSize(.small)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(.bar)
        }
    }
}

/// Home's "Ended (n)": the ended window sessions (a lead's team's aside), folded until opened; each opens on a click,
/// with Resume and Remove beside it.
struct EndedSessions: View {
    let rows: [WindowRow]
    @Binding var open: Bool
    @ObservedObject var model: WindowModel
    let actions: WindowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EndedHeader(count: rows.count, open: $open, font: .system(size: 13, weight: .semibold))
            if open {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 44) }
                        EndedSessionRow(row: row, select: { model.selectedID = row.id }, actions: actions)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
            }
        }
    }
}

struct EndedSessionRow: View {
    let row: WindowRow
    let select: () -> Void
    let actions: WindowActions

    var body: some View {
        HStack(spacing: 12) {
            AgentMark(kind: row.markKind, size: 20)
            Button(action: select) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(row.project).foregroundStyle(.secondary)
                        if let end = row.end {
                            Text("·").foregroundStyle(.tertiary)
                            Image(systemName: end.symbol).foregroundStyle(end.color)
                                .accessibilityHidden(true)  // the words beside it say how it ended
                            Text(end.text).foregroundStyle(end.color)
                        }
                        if let at = row.hosted?.exit?.at {
                            Text("·").foregroundStyle(.tertiary)
                            Text(at.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show this session")
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if actions.canResume(row) {
                Button { actions.resume(row) } label: { Label("Resume", systemImage: "arrow.clockwise") }.controlSize(.small)
            }
            Button("Remove") { actions.remove(row) }.controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
