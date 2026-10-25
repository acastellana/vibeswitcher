import AppKit
import SwiftUI
import VibeCore

/// Selection shared between the SwiftUI list and the AppKit key monitor (arrows / 1–9 / return).
final class PopoverState: ObservableObject {
    @Published var selectedIndex = 0
    @Published var recentProjects: [RecentProjects.Candidate] = []
}

struct PopoverView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var state: PopoverState
    @ObservedObject var preferences: Preferences
    let onOpen: (Session) -> Void
    let onInstallHooks: () -> Void
    let onQuit: () -> Void
    var onRename: (Session) -> Void = { _ in }
    var onResetName: (Session) -> Void = { _ in }
    var onNewSession: (LaunchPreset, String?) -> Void = { _, _ in }
    /// A folder's presets, its default first (nil: other folder).
    var presetsFor: (String?) -> [LaunchPreset] = { _ in LaunchPresets.builtIns().global }
    var onEditCommands: () -> Void = {}
    var onPause: (Session, PauseStore.Duration) -> Void = { _, _ in }
    var onResume: (Session) -> Void = { _ in }
    /// Rendered as the docked sidebar instead of the menu bar popover.
    var isSidebar = false
    var onOpenWindow: () -> Void = {}
    var onSettings: () -> Void = {}
    /// The "Notifications are off" banner's button: macOS's prompt if it never asked, else System Settings.
    var onAllowNotifications: () -> Void = { Notifier.openSettings() }
    /// Brief me, in the header, and its panel under it (none in the sidebar and the snapshots).
    var briefing: BriefingModel? = nil
    @IncreasedContrast private var increased

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let briefing { BriefingStrip(model: briefing) }
            if store.sessions.isEmpty {
                Text("No Claude Code or Codex sessions running in a terminal.")
                    .font(.callout).foregroundStyle(.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(24)
            } else {
                ScrollView {
                    list(store.split)
                }
                .frame(maxHeight: isSidebar ? .infinity : 640)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !isSidebar, !store.today.projects.isEmpty {
                Divider()
                TodaySummary(ledger: store.today)
            }
            banners
            Divider()
            footer
        }
        .frame(width: isSidebar ? nil : 400)
        .frame(maxWidth: isSidebar ? .infinity : nil, maxHeight: isSidebar ? .infinity : nil, alignment: .top)
        .background {
            if isSidebar {
                Color.clear.contrastBackground(RoundedRectangle(cornerRadius: 12), edge: 0.1)
            } else if increased {
                // Increase Contrast: solid, not the popover's material.
                Rectangle().fill(.solidBackground)
            }
        }
    }

    /// The list: your own sessions, then each lead's workers and verifiers, numbered on from them (snapshots draw it
    /// outside the scroll view, which an image renderer leaves blank).
    func list(_ split: SessionTeams.Split) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(split.own.enumerated()), id: \.element.id) { index, session in
                row(session, index: index)
            }
            // Each lead's workers and verifiers, after your own sessions, numbered on from them.
            ForEach(Array(split.teams.enumerated()), id: \.element.project) { offset, team in
                TeamHeader(team: team)
                let first = split.own.count + split.teams[..<offset].reduce(0) { $0 + $1.members.count }
                ForEach(Array(team.members.enumerated()), id: \.element.id) { index, session in
                    row(session, index: first + index)
                }
            }
        }
        .padding(6)
    }

    private func row(_ session: Session, index: Int) -> some View {
        Button { onOpen(session) } label: {
            SessionRow(session: session, index: index, isSelected: index == state.selectedIndex, compact: isSidebar)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // "1, acme-web, needs input", then what it's doing; a team member by its team ("acme · worker fix-login").
        .accessibilityLabel(StatusSummary.spoken(number: index + 1, name: SessionTeams.name(of: session) ?? session.displayName,
                                                 status: session.status, paused: session.isPaused))
        .accessibilityValue(session.detail ?? session.task ?? "")
        .onHover { if $0 { state.selectedIndex = index } }
        .contextMenu {
            Button("Switch to Session") { onOpen(session) }
            Divider()
            if session.isPaused {
                Button("Resume") { onResume(session) }
            } else {
                Menu("Pause") {
                    Button("Until I Resume It") { onPause(session, .indefinitely) }
                    Button("For 1 Hour") { onPause(session, .hours(1)) }
                    Button("Until Tomorrow Morning") { onPause(session, .untilTomorrowMorning) }
                    Button("For 1 Week") { onPause(session, .hours(24 * 7)) }
                }
            }
            Divider()
            Button("Rename…") { onRename(session) }
            if session.customName != nil {
                Button("Reset Name to “\(session.project)”") { onResetName(session) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(isSidebar ? "Sessions" : "VibeSwitcher").font(.headline).lineLimit(1).fixedSize()
            newSessionMenu
            if let briefing { BriefMeButton(model: briefing) }
            Button { onOpenWindow() } label: { Image(systemName: "macwindow").accessibilityLabel("Open VibeSwitcher window") }
                .buttonStyle(.borderless)
                .help("Open the VibeSwitcher window (⌘-click the menu bar icon)")
            Spacer(minLength: 8)
            // With words ("2 background") when they fit; otherwise just the dots and numbers, so a busy
            // header can't make the list wider than the popover (it was clipped on both sides).
            ViewThatFits(in: .horizontal) {
                if !isSidebar { statusCounts(words: true) }
                statusCounts(words: false)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func statusCounts(words: Bool) -> some View {
        HStack(spacing: 12) {
            // Your own sessions: a lead's workers and verifiers are counted under their team's header.
            let own = store.split.own
            ForEach([SessionStatus.needsInput, .working, .background, .done], id: \.self) { status in
                let count = own.filter { $0.status == status && !$0.isPaused }.count
                if count > 0 {
                    HStack(spacing: 4) {
                        StatusMarkView(StatusMark(status: status), color: status.color, size: 9)
                        Text(words ? status.word.counted(count) : "\(count)")
                            .font(.caption).foregroundStyle(.secondaryInk).fixedSize()
                    }
                    .help(status.word.counted(count))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(status.word.counted(count))
                }
            }
            let paused = own.filter(\.isPaused).count
            if paused > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "pause.circle").imageScale(.small).accessibilityHidden(true)
                    Text(words ? StateWord.paused.counted(paused) : "\(paused)").fixedSize()
                }
                .font(.caption).foregroundStyle(.secondaryInk)
                .help("\(StateWord.paused.counted(paused)): no notifications until you resume them")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StateWord.paused.counted(paused))
            }
        }
    }

    private var newSessionMenu: some View {
        Menu {
            if !state.recentProjects.isEmpty {
                Section("Recent projects") {
                    ForEach(state.recentProjects, id: \.path) { project in
                        Menu(Self.menuLabel(for: project.path)) {
                            ForEach(presetsFor(project.path)) { preset in
                                Button(preset.name) { onNewSession(preset, project.path) }
                            }
                        }
                    }
                }
            }
            Menu("Other Folder…") {
                ForEach(presetsFor(nil)) { preset in
                    Button(preset.name) { onNewSession(preset, nil) }
                }
            }
            Divider()
            Button("Launch Presets…", action: onEditCommands)
        } label: {
            Image(systemName: "plus.circle").accessibilityLabel("New session")
        }

        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Start a new session")
    }

    /// "vibeswitcher — ~/dev"
    static func menuLabel(for path: String) -> String {
        let name = SessionNaming.name(forProjectRoot: path)
        var parent = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        if parent.hasPrefix(home) { parent = "~" + parent.dropFirst(home.count) }
        return "\(name) — \(parent)"
    }

    @ViewBuilder private var banners: some View {
        if store.terminalAccess == .denied {
            Banner(text: "Allow VibeSwitcher to control Terminal in System Settings › Privacy & Security › Automation to see tab titles and jump to tabs.")
        }
        if !preferences.notificationsAllowed {
            HStack {
                Text("Notifications are off, so you won't get a banner when a session needs you.")
                    .font(.caption).foregroundStyle(.secondaryInk)
                Spacer()
                Button("Turn on…", action: onAllowNotifications).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        if store.tabOrderUnavailable {
            HStack {
                Text("Some sessions are tabs of one window. Allow Accessibility so the list follows your tab order. Already on in Settings? Remove VibeSwitcher there (−) and add it again: macOS forgot it after an update.")
                    .font(.caption).foregroundStyle(.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Allow…") { TabOrder.requestTrust() }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        let missing = Agent.allCases.filter { store.hooksInstalled[$0] != true }
        if !missing.isEmpty {
            HStack {
                Text("Live status needs hooks for \(missing.map(\.displayName).joined(separator: " & ")).")
                    .font(.caption).foregroundStyle(.secondaryInk)
                Spacer()
                Button("Install hooks", action: onInstallHooks).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack {
            if isSidebar {
                Button("Exit Sidebar Mode") { preferences.sidebarMode = false }
                    .buttonStyle(.borderless).controlSize(.small)
            } else {
                Text("Click a dot to switch · ⌃⌥V for this list · 1–9 · P pauses").font(.caption2).foregroundStyle(.secondaryInk)
            }
            Spacer()
            Menu {
                // Quick toggles; Settings has these and everything else.
                Toggle("Notify when a session needs input", isOn: $preferences.notifyNeedsInput)
                Toggle("Notify when a session finishes", isOn: $preferences.notifyDone)
                Toggle("Sidebar mode", isOn: $preferences.sidebarMode)
                Divider()
                Button("Settings…", action: onSettings)
                Button("Quit VibeSwitcher", action: onQuit)
            } label: {
                Image(systemName: "gearshape").accessibilityLabel("Settings and options")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings and options")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Where today went: agent time vs. time sessions sat waiting on you, per project on demand.
private struct TodaySummary: View {
    let ledger: ActivityLedger
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").imageScale(.small)
                        .foregroundStyle(.secondaryInk).frame(width: 10).accessibilityHidden(true)
                    Text("Today").font(.caption.weight(.semibold))
                    Spacer()
                    stat(SessionStatus.working.color, ledger.agentsWorking, "agents working")
                    stat(SessionStatus.needsInput.color, ledger.waitingOnYou, "waiting on you")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            .help("Agents working: time at least one agent was in a turn. Waiting on you: time, while you were "
                  + "at the Mac, that at least one session needed your answer or had finished unseen "
                  + "(its first 30 min). Background jobs are listed per project.")
            if expanded {
                if ledger.waitedWhileAway >= 60 {
                    Text("Plus \(Durations.short(ledger.waitedWhileAway)) of waiting while you were away")
                        .font(.caption).foregroundStyle(.secondaryInk).padding(.leading, 16)
                }
                ForEach(ledger.byProject().prefix(8), id: \.project) { row in
                    HStack {
                        Text(row.project).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if row.background >= 60 {
                            Text("bg \(Durations.short(row.background))").foregroundStyle(.secondaryInk)
                                .help("Background jobs running after the turn ended")
                        }
                        Text("worked \(Durations.short(row.working))").foregroundStyle(.secondaryInk)
                        Text("waited \(Durations.short(row.waiting))")
                            .foregroundStyle(row.waiting > row.working ? AnyShapeStyle(SessionStatus.needsInput.color)
                                                                       : AnyShapeStyle(.secondaryInk))
                            .frame(minWidth: 84, alignment: .trailing)
                    }
                    .font(.caption)
                    .padding(.leading, 16)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func stat(_ color: Color, _ seconds: Double, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(Durations.short(seconds)) \(label)").font(.caption).foregroundStyle(.secondaryInk)
        }
    }
}

private struct Banner: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondaryInk)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12))
    }
}

struct SessionRow: View {
    let session: Session
    let index: Int
    let isSelected: Bool
    /// Narrow sidebar layout: name gets the whole first line; badge moves next to the task.
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// Increase Contrast: the task in full primary and paused rows undimmed, so their text keeps its 7:1.
    @IncreasedContrast private var increased

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NumberBadge(number: index + 1, status: session.status, isCurrent: session.isCurrent, isPaused: session.isPaused)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1).truncationMode(.middle)
                    if !compact { AgentBadge(agent: session.agent) }
                    if session.isTeamMember, let role = session.teamRole { RoleBadge(role: role) }
                    if session.customName != nil, !compact {
                        Text(session.project).font(.caption).foregroundStyle(.secondaryInk).lineLimit(1)
                    }
                    if !compact, let desktop = session.screenPosition?.desktop {
                        Text("Desktop \(desktop)").font(.caption).foregroundStyle(.secondaryInk).lineLimit(1)
                            .help("Mission Control desktop this session's Terminal window is on")
                    }
                    if session.isCurrent, !compact {
                        Label("Viewing", systemImage: "eye.fill")  // a11y: labelled by its title
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1).fixedSize()   // never "Viewi / ng": the desktop label gives way instead
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .help("The Terminal tab you're looking at right now")
                    }
                    if session.isPaused {
                        Label(StateWord.paused.label, systemImage: "pause.fill")  // a11y: labelled by its title
                            .labelStyle(PausedLabelStyle(compact: compact))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .help(Self.pauseHelp(session.pausedUntil))
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 4) {
                        // The status as a shape and a word, not just the badge's colour.
                        StatusMarkView(session: session, size: 9).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        // A team member waiting waits on its lead: not in the red that says you're needed.
                        Text(LeadTeams.label(of: session))
                            .foregroundStyle(session.isPaused || session.waitsOnLead ? Color.secondaryInk : session.status.color)
                            .lineLimit(1).fixedSize()
                        if session.statusSince > Date.distantPast.addingTimeInterval(1) {
                            TimelineView(.elapsed(since: session.statusSince, reduceMotion: reduceMotion, voiceOver: voiceOver)) { context in
                                Text(Durations.short(context.date.timeIntervalSince(session.statusSince)))
                                    .foregroundStyle(.secondaryInk)
                            }
                        }
                    }
                    .font(.caption.weight(.medium))
                }
                if compact {
                    HStack(spacing: 5) {
                        AgentBadge(agent: session.agent)
                        Text(session.task ?? session.project).font(.system(size: 12)).foregroundStyle(.primary.opacity(increased ? 1 : 0.85))
                            .lineLimit(1)
                    }
                } else if let task = session.task {
                    Text(task).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(increased ? 1 : 0.85)).lineLimit(1)
                }
                if let activity = session.activity, let since = session.activitySince {
                    // Live: what it's running and for how long; long calls turn orange so a hung one stands out.
                    TimelineView(.elapsed(since: since, reduceMotion: reduceMotion, voiceOver: voiceOver)) { context in
                        let seconds = context.date.timeIntervalSince(since)
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape.2").imageScale(.small).accessibilityHidden(true)
                            Text(activity).lineLimit(1).truncationMode(.middle)
                            Text("· " + Durations.short(context.date.timeIntervalSince(since)))
                                .foregroundStyle(seconds > 600 ? AnyShapeStyle(SessionStatus.working.color) : AnyShapeStyle(.secondaryInk))
                        }
                        .font(.caption).foregroundStyle(.secondaryInk)
                    }
                } else if let detail = session.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondaryInk)
                        .lineLimit(session.status == .needsInput ? 2 : 1)
                }
            }
            // Paused: still readable, clearly set aside.
            .opacity(session.isPaused && !increased ? 0.5 : 1)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.15) : .clear))
        .overlay {
            // The session(s) on the desktop you're looking at: framed and tinted.
            if session.onCurrentDesktop {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.85), lineWidth: 1.5))
                    .allowsHitTesting(false)
            }
        }
        .help("\(session.shortCwd ?? session.project) · \(session.agent.displayName) · \(session.tty)"
              + (session.onCurrentDesktop ? " · on this desktop" : ""))
    }

    static func pauseHelp(_ until: Date?) -> String {
        guard let until, until != .distantFuture else { return "Paused until you resume it (right-click › Resume, or P)" }
        let when = Calendar.current.isDateInToday(until)
            ? until.formatted(date: .omitted, time: .shortened)
            : until.formatted(date: .abbreviated, time: .shortened)
        return "Paused until \(when): no notifications or reminders"
    }
}

/// The row's number inside its status color: row 3 is the 3rd dot in the menu bar.
private struct NumberBadge: View {
    let number: Int
    let status: SessionStatus
    var isCurrent = false
    var isPaused = false

    var body: some View {
        ZStack {
            if isPaused {
                Circle().fill(Color(nsColor: Session.pausedNSColor))
            } else if status == .unknown {
                Circle().stroke(status.color, lineWidth: 1.5)
            } else {
                Circle().fill(status.color)
            }
            // White on light-mode fills, near-black on dark-mode ones: at least 4.5:1, and 7:1 with Increase
            // Contrast (StatusPalette).
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(status == .unknown && !isPaused ? Color.primary : SessionStatus.onInk)
        }
        .frame(width: 20, height: 20)
        .overlay {
            if isCurrent {
                Circle().stroke(Color.primary, lineWidth: 1.5).frame(width: 25, height: 25)
            }
        }
        .overlay {
            if status == .working, !isPaused {
                Circle().stroke(status.color.opacity(0.35), lineWidth: 3).frame(width: 25, height: 25)
            }
        }
    }
}

/// The paused tag: icon and word in the popover, icon only (still spoken as "Paused") in the narrow sidebar.
private struct PausedLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            if !compact { configuration.title }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StateWord.paused.label)
    }
}

/// "acme team · 3": over a lead's workers and verifiers in the list, apart from your own sessions.
struct TeamHeader: View {
    let team: SessionTeams.Team

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.3.fill").imageScale(.small).accessibilityHidden(true)
            Text("\(team.project) team").fontWeight(.semibold)
            Text("· \(team.members.count)")
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondaryInk)
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
        .help("Workers and verifiers \(team.project)'s lead started: not counted as your sessions, and they don't notify you: their lead answers them")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(team.project) team, \(team.members.count)")
    }
}

/// "Worker" or "Verifier", on a team member's row.
struct RoleBadge: View {
    let role: LeadLaunch.Role

    var body: some View {
        Text(role == .verifier ? "Verifier" : "Worker")
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(.secondaryInk)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
            .help("Started by its project's lead, which reads its reports")
    }
}

struct AgentBadge: View {
    let agent: Agent
    /// Claude's orange, darker in light mode and lighter in dark so the 9 pt name reads (5:1 on the popover, 7:1 with
    /// Increase Contrast).
    static let claude = Color(nsColor: NSColor(name: nil) {
        StatusPalette.claude(dark: $0.isDark, highContrast: $0.isHighContrast).nsColor
    })
    var body: some View {
        Text(agent == .claude ? "Claude" : "Codex")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(agent == .claude ? Self.claude : .primary)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.4)))
    }
}

/// A time on screen drawn again when `ElapsedTicks` says: every second only in the first minute since `start` (or the
/// last before a deadline) with neither Reduce Motion nor VoiceOver on, else on the minute. Made of fixed values, so
/// a redraw of the view holding it is the same schedule, not a new one (see `ticking(every:)`).
struct ElapsedSchedule: TimelineSchedule {
    enum Anchor: Equatable {
        case since(Date)
        case until(Date)
        /// Every `every` seconds on the clock, and every second while something fades (from, until).
        case fading(Date?, Date?, every: TimeInterval)
    }
    let anchor: Anchor
    let reduceMotion: Bool
    let voiceOver: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(schedule: self, upcoming: startDate)
    }

    func tick(after date: Date) -> Date {
        switch anchor {
        case .since(let start):
            return ElapsedTicks.next(after: date, since: start, reduceMotion: reduceMotion, voiceOverRunning: voiceOver)
        case .until(let deadline):
            return ElapsedTicks.next(after: date, until: deadline, reduceMotion: reduceMotion, voiceOverRunning: voiceOver)
        case .fading(let start, let end, let base):
            return ElapsedTicks.next(after: date, every: base, fadingFrom: start, until: end, reduceMotion: reduceMotion)
        }
    }

    struct Entries: Sequence, IteratorProtocol {
        let schedule: ElapsedSchedule
        var upcoming: Date

        mutating func next() -> Date? {
            defer { upcoming = schedule.tick(after: upcoming) }
            return upcoming
        }
    }
}

extension TimelineSchedule where Self == ElapsedSchedule {
    /// A time counted from `start` ("Working · 12m").
    static func elapsed(since start: Date, reduceMotion: Bool, voiceOver: Bool) -> ElapsedSchedule {
        ElapsedSchedule(anchor: .since(start), reduceMotion: reduceMotion, voiceOver: voiceOver)
    }

    /// A countdown to `deadline` ("Going with A in 8 min").
    static func countdown(to deadline: Date, reduceMotion: Bool, voiceOver: Bool) -> ElapsedSchedule {
        ElapsedSchedule(anchor: .until(deadline), reduceMotion: reduceMotion, voiceOver: voiceOver)
    }

    /// Every `base` seconds, and every second while something fades out between `start` and `end` (not with Reduce
    /// Motion: nothing fades then).
    static func fading(from start: Date?, until end: Date?, every base: TimeInterval, reduceMotion: Bool) -> ElapsedSchedule {
        ElapsedSchedule(anchor: .fading(start, end, every: base), reduceMotion: reduceMotion, voiceOver: false)
    }
}

/// Hosting view that reacts to the first click even when VibeSwitcher is not the active app.
/// Without this, macOS 14+ often leaves the popover non-key and the first click on a row only
/// focuses the popover instead of opening the session.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The menu bar's briefing panel, under the header: while one is written or after, until closed.
private struct BriefingStrip: View {
    @ObservedObject var model: BriefingModel

    var body: some View {
        if !model.panelHidden, model.phase == .writing || model.briefing != nil {
            BriefingPanel(model: model) { model.panelHidden = true }
            Divider()
        }
    }
}
