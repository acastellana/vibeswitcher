import SwiftUI
import VibeCore

/// The right pane. Part 1: facts about the selected session (parts 2–3 add changes, files, transcript, previews).
struct InspectorView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var host: HostClient

    var body: some View {
        Form {
            if let row = model.selectedRow {
                let info = row.hostID.flatMap { id in host.sessions.first { $0.id == id } }
                Section("Session") {
                    if let cwd = row.cwd { LabeledContent("Folder", value: cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
                    if let session = row.session {
                        LabeledContent("Agent", value: session.agent.displayName)
                        LabeledContent("Status", value: session.status.label)
                        LabeledContent("Process", value: "\(session.pid) on \(session.tty)")
                        if let id = session.agentSessionID {
                            LabeledContent("Session ID") { Text(id).textSelection(.enabled) }
                        }
                    }
                    if let info {
                        LabeledContent("Started", value: info.startedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Command", value: info.command ?? "Shell")
                        LabeledContent("Size", value: "\(info.cols) × \(info.rows)")
                        if let exit = info.exit { LabeledContent("Exit", value: "\(exit.status)") }
                    } else if row.session?.inTerminalApp == true {
                        LabeledContent("Runs in", value: "Terminal")
                    }
                }
            } else {
                Text("Nothing selected").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
