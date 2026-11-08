import Combine
import SwiftUI
import VibeCore

/// The bar above the terminal: what's selected, its state, where it runs, and what you can do with it.
///
/// It read the window's model and the session host, and every session the host changes publishes both: drawn again
/// for each, the bar remade its segmented picker, its menu and its 30 s clock on every event of any of 24 sessions, and
/// those updates showed in the week's freezes (hang-20261101-115308, hang-20261107-095327, hang-20261107-115633, its
/// body on top; the AttributeGraph and NSHostingView transactions of the rest). Now `SessionHeaderState` takes from
/// them only what the bar shows (`SessionHeaderBar.Shown`) and publishes it only when it changed. (An equatable bar
/// under a view observing both wasn't enough: SwiftUI drew it again on some runs with every value the same.)
struct SessionHeaderView: View {
    let model: WindowModel
    let host: HostClient
    let actions: WindowActions
    @StateObject private var state: SessionHeaderState
    private let drawn: SessionHeaderBar.Drawn?

    /// `drawn` counts the bar's draws and the state's reads (for tests).
    init(model: WindowModel, host: HostClient, actions: WindowActions, drawn: SessionHeaderBar.Drawn? = nil) {
        self.model = model
        self.host = host
        self.actions = actions
        self.drawn = drawn
        _state = StateObject(wrappedValue: SessionHeaderState(model: model, host: host, actions: actions, drawn: drawn))
    }

    var body: some View {
        SessionHeaderBar(shown: state.shown, actions: actions,
                         showsChat: Binding(get: { [model] in model.showsChat }, set: { [model] in model.showsChat = $0 }),
                         select: { [model] in model.select(hostID: $0) }, restart: { [host] in HostRestart.confirmAndRestart(host) },
                         drawn: drawn)
    }
}

/// What the header's bar shows of the window's model and the session host, published only when it changes: read again
/// after each change either makes (their `objectWillChange` comes before it, so the read waits a turn of the main run loop;
/// a burst of changes is read once).
final class SessionHeaderState: ObservableObject {
    @Published private(set) var shown: SessionHeaderBar.Shown
    private let read: () -> SessionHeaderBar.Shown
    private let drawn: SessionHeaderBar.Drawn?
    private var changes: AnyCancellable?

    init(model: WindowModel, host: HostClient, actions: WindowActions, drawn: SessionHeaderBar.Drawn? = nil) {
        read = { [unowned model, unowned host] in Self.shown(model: model, host: host, actions: actions) }
        self.drawn = drawn
        shown = Self.shown(model: model, host: host, actions: actions)
        changes = model.objectWillChange.merge(with: host.objectWillChange)
            .receiveLatest(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        drawn?.observed += 1
        let now = read()
        if now != shown { shown = now }
    }

    /// What the bar shows of the model and the host now.
    static func shown(model: WindowModel, host: HostClient, actions: WindowActions) -> SessionHeaderBar.Shown {
        let row = model.selectedRow
        return SessionHeaderBar.Shown(row: row, replaced: row.flatMap(model.replaced), hasChat: row.map { model.chatPath(for: $0) != nil } ?? false,
                                      showsChat: model.showsChat, isLive: row.map(actions.isLive) ?? false,
                                      canResume: row.map(actions.canResume) ?? false, refusal: host.proofRefusal, hostState: host.state,
                                      restartOffer: host.restartOffer)
    }
}

/// The header's bar itself, from the values it shows (`Shown`).
struct SessionHeaderBar: View {
    struct Shown: Equatable {
        var row: WindowRow?
        var replaced: ReplacedLead?
        /// The row has a transcript: the terminal/chat picker is shown.
        var hasChat: Bool
        var showsChat: Bool
        var isLive: Bool
        var canResume: Bool
        var refusal: String?
        var hostState: HostClient.State
        var restartOffer: HostClient.RestartPlan?
    }

    /// How many times the bar was drawn, and the state's reads of the model and host that hand it its values (for tests).
    final class Drawn {
        var count = 0
        var observed = 0
        /// What the bar showed at each draw.
        var shown: [Shown] = []
    }

    let shown: Shown
    let actions: WindowActions
    let showsChat: Binding<Bool>
    let select: (UUID) -> Void
    let restart: () -> Void
    var drawn: Drawn?
    @State private var branch: String?

    var body: some View {
        let _ = drawn.map { $0.count += 1; $0.shown.append(shown) }
        HStack(spacing: 10) {
            if let row = shown.row {
                // The mark works out "starting" from the clock as the pill does: drawn on the same 30 s tick, as the bar
                // is no longer drawn again for every event.
                TimelineView(.ticking(every: 30)) { context in
                  HStack(spacing: 10) {
                    AgentMark(kind: row.markKind, status: row.statusColor, hollow: row.statusIsHollow, size: 28, mark: row.statusMark, spoken: row.spokenStatus)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(Self.oneLine(row.title)).font(.system(size: 14, weight: .semibold)).lineLimit(1).layoutPriority(1)
                                .onTapGesture(count: 2) { if let session = row.session { actions.rename(session) } }
                                .help(row.session != nil ? "Double-click to rename" : "")
                            StatusPill(row: row, now: context.date, replaced: shown.replaced)
                        }
                        if let replaced = shown.replaced {
                            Text(Self.replacedLine(replaced)).font(.system(size: 11)).foregroundStyle(ReplacedLead.color).lineLimit(1)
                        } else {
                            details(row).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                  }
                }
                Spacer(minLength: 8)
                hostState
                if let replaced = shown.replaced, let live = replaced.live {
                    Button("Continue in \(replaced.liveName)") { select(live) }
                        .help("Go to the lead that holds the role now")
                        .accessibilityLabel("Continue in \(replaced.liveName)")
                }
                if shown.hasChat {
                    Picker("View", selection: showsChat) {
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
        // Re-read as the agent works (it may switch branches); set only when it changed, as each set draws the bar again.
        .task(id: "\(shown.row?.cwd ?? "")|\(shown.row?.session?.eventAt ?? 0)") {
            guard let cwd = shown.row?.cwd else { if branch != nil { branch = nil }; return }
            let found = await Task.detached(priority: .utility) { GitBranch.current(in: cwd) }.value
            if found != branch { branch = found }
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
            if shown.isLive {
                Button { actions.endSession(row) } label: { Image(systemName: "stop.circle").accessibilityLabel("End session") }
                    .help("End this session… (⇧⌘⌫)")
            } else {
                if shown.canResume {
                    Button { actions.resume(row) } label: { Image(systemName: "arrow.clockwise").accessibilityLabel("Resume") }
                        .help("Resume: start the agent again on this conversation")
                }
                Button { actions.remove(row) } label: { Image(systemName: "trash").accessibilityLabel("Remove from list") }
                    .help("Remove from the list")
            }
        }
    }

    @ViewBuilder private var hostState: some View {
        if let refusal = shown.refusal {
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
        switch shown.hostState {
        case .connecting:
            Text("Connecting…").font(.caption).foregroundStyle(.orange)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1)
        case .outdated:
            // Always on offer: a host that can hand over (its automatic one failed) keeps the sessions; any other,
            // even one that still speaks this app's protocol, ends them in all projects, after asking.
            if let plan = shown.restartOffer {
                HostRestartButton(plan: plan, action: restart)
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
        // Its own words, its texts left out (not combined: a combine merges them again on every update while an
        // accessibility client watches the app, and the duration changes with the clock).
        .accessibilityElement(children: .ignore)
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
