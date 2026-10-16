import SwiftUI
import VibeCore

/// Shown when no session is selected: recent projects with their presets, and the keys worth knowing.
struct StartPage: View {
    @ObservedObject var model: WindowModel
    let actions: WindowActions

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
                            ProjectRow(path: path, presets: actions.presets(path)) { actions.newSession($0, path) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
                }
                Button { actions.newSession(nil, nil) } label: { Label("Choose Folder…", systemImage: "folder.badge.plus") }
                Shortcuts()
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
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
    let start: (LaunchPreset) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
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
            HStack(spacing: 10) {
                Image(systemName: exit.status == 0 ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(exit.status == 0 ? Color.secondary : Color.orange)
                Text("Ended \(exit.at.formatted(date: .omitted, time: .shortened)) · exit \(exit.status)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
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
