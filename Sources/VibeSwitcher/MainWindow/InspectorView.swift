import SwiftUI
import VibeCore

/// The right pane: Overview (facts about the selected session) and Activity (what the agent has been doing).
struct InspectorView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var host: HostClient
    @ObservedObject var leads: LeadController
    @AppStorage("inspectorTab") private var tab = "overview"

    var body: some View {
        let lead = model.selectedRow.flatMap(leads.lead(for:))
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                if lead != nil { Text("Team").tag("team") }
                Text("Overview").tag("overview")
                Text("Activity").tag("activity")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let row = model.selectedRow {
                if tab == "team", let lead {
                    LeadTeamPane(root: lead.root, board: lead.board, decisions: leads.decisions[lead.root] ?? [],
                                 seen: TeamRows.seen(model.allRows, now: Date()), open: { session in
                        if let id = UUID(uuidString: session) { model.select(hostID: id) }
                    }, answer: { question, text in leads.answer(question, root: lead.root, with: text) }, notices: leads.answerNotices,
                                 summaries: leads.summaries, keepAwake: leads.keepAwake, hosted: host.sessions)
                } else if tab == "activity" {
                    ActivityView(session: row.session).id(row.id)
                } else {
                    OverviewView(row: row, info: row.hostID.flatMap { id in host.sessions.first { $0.id == id } })
                }
            } else {
                Spacer()
                Text("No session selected").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

private struct OverviewView: View {
    let row: WindowRow
    let info: HostSession?
    @State private var branch: String?

    var body: some View {
        TimelineView(.ticking(every: 30)) { context in
            Form {
                Section("Status") {
                    LabeledContent("State") { StatusPill(row: row, now: context.date) }
                    if let session = row.session {
                        LabeledContent("Since", value: session.statusSince.formatted(date: .omitted, time: .shortened))
                        if let activity = session.activity { LabeledContent("Running", value: activity) }
                        if let detail = session.detail, !detail.isEmpty {
                            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4)
                        }
                    }
                    if let exit = info?.exit {
                        LabeledContent("Exit", value: "\(exit.status) at \(exit.at.formatted(date: .omitted, time: .shortened))")
                    }
                }
                Section("Place") {
                    if let cwd = row.cwd {
                        LabeledContent("Folder") {
                            Button {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                            } label: {
                                Text(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.head)
                            }
                            .buttonStyle(.link)
                            .help("Reveal \(cwd) in Finder")
                        }
                    }
                    if let branch { LabeledContent("Branch", value: branch) }
                    LabeledContent("Runs in", value: row.hostID != nil ? "This window" : (row.session?.inTerminalApp == true ? "Terminal" : "Another app"))
                }
                Section("Time") {
                    let started = info?.startedAt ?? row.session?.startedAt
                    if let started {
                        LabeledContent("Started", value: started.formatted(date: .abbreviated, time: .shortened))
                        if info?.exit == nil {
                            LabeledContent("Running for", value: Durations.short(context.date.timeIntervalSince(started)))
                        }
                    }
                }
                Section("Agent") {
                    LabeledContent("Agent", value: row.markKind.name)
                    if let id = row.session?.agentSessionID {
                        LabeledContent("Session") {
                            HStack(spacing: 4) {
                                Text(id.prefix(8) + "…").textSelection(.enabled).help(id)
                                Button { Pasteboard.copy(id) } label: { Image(systemName: "doc.on.doc").accessibilityLabel("Copy session ID") }
                                    .buttonStyle(.borderless).help("Copy session ID")
                            }
                        }
                    }
                    if let session = row.session { LabeledContent("Process", value: "\(session.pid) on \(session.tty)") }
                    if let info {
                        LabeledContent("Command", value: info.command ?? "Shell")
                        LabeledContent("Size", value: "\(info.cols) × \(info.rows)")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .task(id: row.cwd) {
            guard let cwd = row.cwd else { return branch = nil }
            branch = await Task.detached(priority: .utility) { GitBranch.current(in: cwd) }.value
        }
    }
}

/// The last entries of the agent's transcript: your prompts, its replies, the tools it ran.
struct ActivityView: View {
    let session: Session?
    @State private var entries: [TranscriptEntry] = []
    @State private var message: String?
    nonisolated static let tailBytes = 256 * 1024

    private var key: String { "\(session?.transcriptPath ?? "")|\(session?.eventAt ?? 0)" }

    var body: some View {
        Group {
            if let message, entries.isEmpty {
                VStack { Spacer(); Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(); Spacer() }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(entries, id: \.id) { ActivityRow(entry: $0) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(12)
                    }
                    .onChange(of: entries) { proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: key) {
            // Hook events come in bursts while it works: read at most about once a second.
            if !entries.isEmpty { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            guard let path = session?.transcriptPath else {
                entries = []
                message = session == nil ? "No agent runs in this session." : "No transcript for this session yet."
                return
            }
            let read = await Task.detached(priority: .userInitiated) { Self.read(path) }.value
            guard !Task.isCancelled else { return }
            if let read { entries = read; message = read.isEmpty ? "Nothing yet." : nil } else { message = "Couldn't read the transcript." }
        }
    }

    /// Off the main actor (a View's statics are on it): seeking, reading and parsing the transcript's tail.
    nonisolated private static func read(_ path: String) -> [TranscriptEntry]? {
        guard let (url, format) = TranscriptReader.checkedURL(path, home: VibePaths.home),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let plan = TranscriptWindow.plan(fileSize: Int(size), after: nil, sameFile: false, tailBytes: tailBytes)
        guard (try? handle.seek(toOffset: UInt64(plan.start))) != nil, let data = try? handle.readToEnd() else { return nil }
        let chunk = TranscriptWindow.chunk(data, plan: plan, fileSize: Int(size), format: format)
        return ActivityFeed.rows(chunk.entries, limit: 60)
    }
}

private struct ActivityRow: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(iconColor).frame(width: 14).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                switch entry.kind {
                case .prompt:
                    Text(entry.text).font(.system(size: 12, weight: .semibold)).lineLimit(4)
                case .reply:
                    Text(entry.text).font(.system(size: 12)).lineLimit(3)
                case .tool, .toolResult:
                    HStack(spacing: 6) {
                        Text(entry.tool ?? "Tool").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Spacer(minLength: 0)
                        if let duration = entry.duration, duration >= 1 {
                            Text(Durations.short(duration)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    Text(entry.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var icon: String {
        switch entry.kind {
        case .prompt: return "person.fill"
        case .reply: return "text.bubble"
        case .tool, .toolResult: return entry.failed ? "xmark.octagon.fill" : "wrench.and.screwdriver"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .prompt: return .accentColor
        case .tool, .toolResult: return entry.failed ? .red : .secondary
        case .reply: return .secondary
        }
    }
}
