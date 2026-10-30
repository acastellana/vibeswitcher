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
                AgentMark(kind: row.markKind, status: row.statusColor, hollow: row.statusIsHollow, size: 28, mark: row.statusMark, spoken: row.spokenStatus)
                TimelineView(.ticking(every: 30)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(Self.oneLine(row.title)).font(.system(size: 14, weight: .semibold)).lineLimit(1).layoutPriority(1)
                                .onTapGesture(count: 2) { if let session = row.session { actions.rename(session) } }
                                .help(row.session != nil ? "Double-click to rename" : "")
                            StatusPill(row: row, now: context.date, replaced: model.replaced(row))
                        }
                        if let replaced = model.replaced(row) {
                            Text(Self.replacedLine(replaced)).font(.system(size: 11)).foregroundStyle(ReplacedLead.color).lineLimit(1)
                        } else {
                            details(row).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                hostState
                if let live = model.replaced(row)?.live {
                    Button("Continue in \(model.replaced(row)!.liveName)") { model.select(hostID: live) }
                        .help("Go to the lead that holds the role now")
                        .accessibilityLabel("Continue in \(model.replaced(row)!.liveName)")
                }
                if model.chatPath(for: row) != nil {
                    Picker("View", selection: $model.showsChat) {
                        Image(systemName: "terminal").accessibilityLabel("Terminal").help("Terminal (⌥⌘1)").tag(false)
                        Image(systemName: "bubble.left.and.text.bubble.right").accessibilityLabel("Chat").help("Chat (⌥⌘2)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                buttons(row)
                Menu { RowMenu(row: row, actions: actions) } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("More actions") }
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
        if let program = row.hosted?.liveProgramStatus, let said = StatusRules.detail(for: program) { parts.append(said) }
        return Text(Self.oneLine(parts.joined(separator: "  ·  ")))
    }

    /// A replaced lead's second line: where to continue, and where what's typed into it goes (or went).
    static func replacedLine(_ replaced: ReplacedLead) -> String {
        let typing = replaced.draft.isEmpty ? nil : "Enter sends to \(replaced.liveName): \(oneLine(replaced.draft).replacingOccurrences(of: "\n", with: " "))"
        let said = typing ?? replaced.notice
            ?? "What you type here goes to \(replaced.liveName) as your message: this session has no tools"
        return oneLine("\(replaced.label)  ·  \(said)")
    }

    /// The most a one-line text of the header is given: more than its width shows. A `lineLimit(1)` Text still lays out
    /// all of its string each time it's measured (a 200,000-character draft took 350 ms a measure, a few a layout).
    static let oneLineLimit = 400

    /// `text` as a one-line text of the header gets it: its first `oneLineLimit` characters, "…" after them when cut.
    static func oneLine(_ text: String) -> String {
        guard let end = text.index(text.startIndex, offsetBy: oneLineLimit, limitedBy: text.endIndex), end < text.endIndex else { return text }
        return String(text[..<end]) + "…"
    }

    @ViewBuilder private func buttons(_ row: WindowRow) -> some View {
        if let session = row.session, session.inTerminalApp {
            Button { actions.openInTerminal(session) } label: { Image(systemName: "arrow.up.forward.app").accessibilityLabel("Open in Terminal") }
                .help("Open in Terminal (⌘O)")
        }
        if row.hostID != nil {
            if actions.isLive(row) {
                Button { actions.endSession(row) } label: { Image(systemName: "stop.circle").accessibilityLabel("End session") }
                    .help("End this session… (⇧⌘⌫)")
            } else {
                if actions.canResume(row) {
                    Button { actions.resume(row) } label: { Image(systemName: "arrow.clockwise").accessibilityLabel("Resume") }
                        .help("Resume: start the agent again on this conversation")
                }
                Button { actions.remove(row) } label: { Image(systemName: "trash").accessibilityLabel("Remove from list") }
                    .help("Remove from the list")
            }
        }
    }

    @ViewBuilder private var hostState: some View {
        if let refusal = host.proofRefusal {
            // The host shows this app none of its sessions: say why the list is empty.
            Label("The session host doesn't recognise this app", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(1)
                .help(refusal + " Its sessions aren't shown, and new ones can't start, until it does.")
                .accessibilityLabel("The session host doesn't recognise this app: \(refusal)")
        } else {
            connectionState
        }
    }

    @ViewBuilder private var connectionState: some View {
        switch host.state {
        case .connecting:
            Text("Connecting…").font(.caption).foregroundStyle(.orange)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1)
        case .outdated:
            // Always on offer: a host that can hand over (its automatic one failed) keeps the sessions; any other,
            // even one that still speaks this app's protocol, ends them in all projects, after asking.
            if let plan = host.restartOffer {
                HostRestartButton(plan: plan) { HostRestart.confirmAndRestart(host) }
            }
        case .connected, .notRunning:
            EmptyView()
        }
    }
}

/// "Needs you · 4m" in the status color.
struct StatusPill: View {
    let row: WindowRow
    let now: Date
    var replaced: ReplacedLead?

    var body: some View {
        let state = replaced?.rowState ?? row.state(now: now)
        let color = replaced == nil ? row.statusColor : ReplacedLead.color
        HStack(spacing: 4) {
            if replaced != nil {
                Image(systemName: "arrow.turn.up.right").accessibilityHidden(true)  // a shape as well as the colour
            }
            Text(replaced == nil ? row.pillLabel(state) : "Replaced")
            if let since = state.since {
                Text("· \(Durations.short(now.timeIntervalSince(since)))").monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(color)
        .overlay(Capsule().strokeBorder(color.opacity(0.6)))  // a tinted fill took the text under 4.5:1
        .fixedSize()
        .help(replaced.map { "This lead was \($0.label)" } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(replaced.map { "Replaced: continue in \($0.liveName)" } ?? row.pillLabel(state))
    }
}

extension WindowRow {
    /// The header's word for the row's state, the glossary's (`StateWord`): "Needs you", "Working", "Ended"…; a window
    /// session with no agent's state says "Starting" or "Shell".
    func pillLabel(_ state: RowState) -> String {
        switch content {
        case .hosted(let info):
            if !info.isLive { return StateWord.ended.label }
            if let program = info.liveProgramStatus { return StatusRules.status(for: program).label }
            return state.group == .working ? "Starting" : "Shell"
        case .agent(let session):
            if session.isPaused { return StateWord.paused.label }
            // A worker or verifier asks its lead, not you.
            return LeadTeams.label(of: session)
        }
    }
}
