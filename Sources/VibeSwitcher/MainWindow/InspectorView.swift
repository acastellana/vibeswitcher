import SwiftUI
import VibeCore

/// The right pane: Overview (facts about the selected session) and Activity (what the agent has been doing).
struct InspectorView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var host: HostClient
    @ObservedObject var leads: LeadController
    /// Brief me on the lead's project, over its Team tab (none in the benches).
    var briefing: BriefingModel? = nil
    @AppStorage("inspectorTab") private var tab = "overview"
    /// What the body would otherwise make on every draw, kept by its inputs: it's drawn again for every session the
    /// host changes (hang-20261028-171900, 174653).
    @State var cache = Cache()

    final class Cache {
        private var hostedKept: (sessions: [HostSession], listed: [MacLine.Session])?
        private var briefingKept: (briefing: BriefingModel, root: String, project: BriefingModel)?
        /// How many times the sessions were listed for the Mac-wide line, and a project's briefing looked up (for tests).
        private(set) var hostedMade = 0
        private(set) var briefingsLooked = 0

        /// Every session the host lists, as the Mac-wide line counts them, made once for each list the host gives.
        func hosted(_ sessions: [HostSession]) -> [MacLine.Session] {
            if let kept = hostedKept, kept.sessions.isSameStorage(as: sessions) { return kept.listed }
            hostedMade += 1
            let listed = sessions.map(MacLine.Session.init)
            hostedKept = (sessions, listed)
            return listed
        }

        /// Brief me on the project at `root` (`BriefingModel.project`), looked up once while it's the same lead.
        func briefing(_ briefing: BriefingModel, root: String) -> BriefingModel {
            if let kept = briefingKept, kept.briefing === briefing, kept.root == root { return kept.project }
            briefingsLooked += 1
            let project = briefing.project(root)
            briefingKept = (briefing, root, project)
            return project
        }
    }

    var body: some View {
        let selected = model.selectedRow
        let lead = selected.flatMap(leads.lead(for:))
        VStack(spacing: 0) {
            InspectorTabs(team: lead != nil)
            Divider()
            if let row = selected {
                if tab == "team", let lead {
                    if let briefing {
                        ProjectBriefingBar(model: cache.briefing(briefing, root: lead.root))
                        Divider()
                    }
                    // Only what the board's rows read: another session's change leaves the pane as it is.
                    let seen = leads.teamRows.seen(lead.root, board: lead.board, rows: model.allRows, now: Date())
                    LeadTeamPane(root: lead.root, board: lead.board, decisions: leads.decisions[lead.root] ?? [], seen: seen.members,
                                 rows: leads.teamRows.rows(lead.root, board: lead.board, seen: seen), open: { session in
                        if let id = UUID(uuidString: session) { model.select(hostID: id) }
                    }, answer: { question, text in leads.answer(question, root: lead.root, with: text) }, notices: leads.answerNotices,
                                 summaries: leads.summaries, keepAwake: leads.keepAwake, hosted: cache.hosted(host.sessions),
                                 recordsDir: leads.recordsDirs[lead.root] ?? LeadWorkflow.defaultRecordsDir)
                        .equatable()
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

/// The inspector's tabs: Team (a lead's), Overview, Activity. Its own view, so the segmented control is updated only
/// when a Team tab comes or goes, not each time the inspector is drawn again.
private struct InspectorTabs: View {
    let team: Bool
    @AppStorage("inspectorTab") private var tab = "overview"

    var body: some View {
        Picker("Inspector", selection: $tab) {
            if team { Text("Team").tag("team") }
            Text("Overview").tag("overview")
            Text("Activity").tag("activity")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

/// The ledger beside the chat: the files the agent changed, the commands it ran and what each turn took (see
/// `ActivityFeed`), from the end of its transcript, read again as it grows.
struct ActivityView: View {
    let session: Session?
    @State private var feed: ActivityFeed?
    @State private var message: String?
    nonisolated static let tailBytes = 256 * 1024

    private var key: String { "\(session?.transcriptPath ?? "")|\(session?.eventAt ?? 0)" }

    var body: some View {
        Group {
            if let feed, !feed.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(feed.rows) { ActivityRow(row: $0) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(12)
                    }
                    .onChange(of: feed) { proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            } else {
                VStack {
                    Spacer()
                    Text(message ?? (feed == nil ? "" : ActivityFeed.emptyExplanation))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: key) {
            // Hook events come in bursts while it works: read at most about once a second.
            if feed != nil { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            guard let path = session?.transcriptPath else {
                feed = nil
                message = session == nil ? "No agent runs in this session." : "No transcript for this session yet."
                return
            }
            let read = await Task.detached(priority: .userInitiated) { Self.read(path) }.value
            guard !Task.isCancelled else { return }
            if let read { feed = read; message = nil } else if feed == nil { message = "Couldn't read the transcript." }
        }
    }

    /// Off the main actor (a View's statics are on it): seeking, reading and parsing the transcript's tail.
    nonisolated static func read(_ path: String) -> ActivityFeed? {
        guard let (url, format) = TranscriptReader.checkedURL(path, home: VibePaths.home),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let plan = TranscriptWindow.plan(fileSize: Int(size), after: nil, sameFile: false, tailBytes: tailBytes)
        guard (try? handle.seek(toOffset: UInt64(plan.start))) != nil, let data = try? handle.readToEnd() else { return nil }
        return ActivityFeed.read(data, format: format, startsMidFile: plan.start > 0)
    }
}

/// One line of the ledger: a file with its +/− counts, a command with its exit code and time, or a turn's tokens and
/// cost. Icons and words are the chat's (`ToolStyle`, the tool's title), in plain text.
struct ActivityRow: View {
    let row: ActivityFeed.Row

    /// What the row shows, in words, and what VoiceOver reads.
    struct Lines: Equatable {
        var title: String
        /// Under the title: a command's first line, a file's action, a turn's counts.
        var detail: String?
        var trailing: [String]
        var spoken: String
    }

    var body: some View {
        let lines = Self.lines(row)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(failed ? Color.red : Color.secondary).frame(width: 14)
                .padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(lines.title).font(titleFont).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    trailing
                }
                if let detail = lines.detail {
                    // A turn's tokens and cost wrap rather than lose a number; a path or command keeps its ends.
                    Text(detail).font(detailFont).foregroundStyle(.secondary).lineLimit(isTurn ? 2 : 1).truncationMode(isTurn ? .tail : .middle)
                }
            }
        }
        .padding(.vertical, isTurn ? 6 : 0)
        .padding(.horizontal, isTurn ? 8 : 0)
        .background { if isTurn { RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)) } }
        .padding(.bottom, isTurn ? 6 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lines.spoken)
    }

    @ViewBuilder private var trailing: some View {
        switch row {
        case .file(let file):
            HStack(spacing: 4) {
                if file.added > 0 || file.action != .deleted { Text("+\(file.added)").foregroundStyle(.green) }
                if file.removed > 0 || file.action == .edited { Text("\u{2212}\(file.removed)").foregroundStyle(.red) }
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        case .command(let command):
            HStack(spacing: 6) {
                if command.running && !command.background { ProgressView().controlSize(.mini) }
                ForEach(Self.lines(row).trailing, id: \.self) { text in
                    Text(text).foregroundStyle(text.hasPrefix("exit") && command.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                }
            }
            .font(.system(size: 10.5).monospacedDigit())
        case .turn(let turn):
            if let at = turn.at { Text(at.formatted(date: .omitted, time: .shortened)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary) }
        }
    }

    private var isTurn: Bool { if case .turn = row { return true } else { return false } }

    private var failed: Bool { if case .command(let command) = row { return command.failed } else { return false } }

    private var symbol: String {
        switch row {
        case .file(let file): return file.action == .deleted ? "trash" : ToolStyle.symbol(file.tool)
        case .command(let command): return command.failed ? "xmark.octagon.fill" : ToolStyle.symbol(command.tool)
        case .turn: return "sum"
        }
    }

    private var titleFont: Font {
        switch row {
        case .file: return .system(size: 11.5, design: .monospaced)
        case .command: return .system(size: 12)
        case .turn: return .system(size: 11.5, weight: .semibold)
        }
    }

    private var detailFont: Font {
        if case .command = row { return .system(size: 11, design: .monospaced) }
        return .system(size: 10.5).monospacedDigit()
    }

    static func lines(_ row: ActivityFeed.Row) -> Lines {
        switch row {
        case .file(let file):
            let verb: String
            switch file.action {
            case .created: verb = "Created"
            case .edited: verb = "Edited"
            case .written: verb = "Written"
            case .deleted: verb = "Deleted"
            }
            let times = file.edits > 1 ? ", \(file.edits) times" : ""
            let counts = "\(file.added) line\(file.added == 1 ? "" : "s") added, \(file.removed) removed"
            return Lines(title: file.path, detail: verb + times, trailing: ["+\(file.added)", "\u{2212}\(file.removed)"],
                         spoken: "\(verb) \(file.path)\(times), \(counts)")
        case .command(let command):
            let line = command.command + (command.moreLines ? " …" : "")
            var trailing: [String] = []
            var spoken: [String] = []
            if let code = command.exitCode {
                trailing.append("exit \(code)")
                spoken.append("exit code \(code)")
            } else if command.background {
                // Not the glossary's "in background", which is a session's state.
                trailing.append("sent to background")
                spoken.append("running in the background")
            } else if command.running {
                spoken.append("running")
            } else {
                trailing.append(command.failed ? "failed" : "no exit code")
                spoken.append(command.failed ? "failed, exit code not reported" : "exit code not reported")
            }
            // A background command's result comes as it starts: its time says nothing.
            if let duration = command.duration, !command.background {
                let text = duration < 1 ? "<1s" : Durations.short(duration)
                trailing.append(text)
                spoken.append(duration < 1 ? "under a second" : "took \(text)")
            }
            let ran = command.title.map { "\($0), ran \(line)" } ?? "Ran \(line)"
            return Lines(title: command.title ?? line, detail: command.title == nil ? nil : line, trailing: trailing,
                         spoken: ([ran] + spoken).joined(separator: ", "))
        case .turn(let turn):
            var counts: [String] = []
            if turn.files > 0 { counts.append("\(turn.files) file\(turn.files == 1 ? "" : "s")") }
            if turn.commands > 0 { counts.append("\(turn.commands) command\(turn.commands == 1 ? "" : "s")") }
            let name = turn.partial ? "Turn total (the part read)" : "Turn total"
            let title = ([name] + counts).joined(separator: " · ")
            var parts: [String] = []
            if let tokens = turn.tokens {
                let cached = tokens.cached > 0 ? " (\(TokenCount.short(tokens.cached)) cached)" : ""
                parts.append("\(TokenCount.short(tokens.input)) in\(cached)")
                parts.append("\(TokenCount.short(tokens.output)) out")
            } else {
                parts.append("tokens not reported")
            }
            parts.append(turn.cost.map { String(format: "$%.2f", $0) } ?? "cost not reported")
            let detail = parts.joined(separator: " · ")
            let time = turn.at.map { ", started \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return Lines(title: title, detail: detail, trailing: [],
                         spoken: "\(name)\(time): " + (counts + parts).joined(separator: ", "))
        }
    }
}
