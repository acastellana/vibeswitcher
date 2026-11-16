import AppKit
import Combine
import SwiftUI
import VibeCore

/// The restart card's model (see `RestartReopen`): keeps the record of the live window sessions as they start and end,
/// decides once at launch whether they went with a restart, and reopens what you click, never anything on its own.
final class RestartOffer: ObservableObject {
    /// The sessions the card lists, leads first; empty once answered (or when there's nothing to offer).
    @Published private(set) var offered: [RestartReopen.Entry] = []
    /// Choose: the ticked sessions (those that can be reopened, all ticked to start with).
    @Published var chosen: Set<UUID> = []
    @Published var choosing = false

    /// Where the record lives; a test's own.
    let file: URL
    /// Whether a session's folder is still there; a test's own.
    var folderExists: (String) -> Bool = RestartReopen.isFolder
    /// Resumes one of your own sessions: the sidebar's Resume (`LaunchPlan.resumeRequest`).
    var resumeSession: (SpawnRequest) -> Void = { _ in }
    /// Reopens a lead in its repository, carrying on its conversation (`LeadController.reopenLead`).
    var reopenLead: (_ root: String, _ conversation: String) -> Void = { _, _ in }
    /// The card has sessions to show, or none any more.
    var show: () -> Void = {}
    var close: () -> Void = {}

    /// The record as last written (or read at launch).
    private(set) var recorded: [RestartReopen.Entry]
    /// Launch's decision is made: from then on the record follows the live sessions.
    private(set) var decided = false
    /// The Mac is shutting down or logging out: the sessions ending now are the restart's, not yours, so the record
    /// keeps them. Until `freezeLimit` has passed with the app still running (the shutdown was cancelled).
    private(set) var frozen = false
    /// How long a shutdown may take to end the app before it's taken as cancelled; how that wait runs (a test's own).
    var freezeLimit: TimeInterval = 180
    var later: (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }
    /// Each freeze counts up: a cancelled shutdown's wait says nothing about a later one.
    private var freezes = 0
    /// The live sessions as last seen from a host that welcomed this app (frozen or not): what a thaw records.
    private var lastSeen: (hosted: [HostSession], sessions: [Session])?
    private var watching: Set<AnyCancellable> = []

    init(file: URL = RestartReopen.file) {
        self.file = file
        recorded = RestartReopen.load(from: file)
    }

    /// Once, at launch, after the app tried to reattach to a running host (`HostClient.connectIfRunning`): no host
    /// running, or its welcome, decides.
    func watchLaunch(_ host: HostClient) {
        host.$state.sink { [weak self, weak host] state in
            guard let self, let host, !self.decided else { return }
            switch state {
            // A host that didn't take this app's proof (`HostClient.proofRefusal`, told before its welcome) lists none
            // of its sessions to it: that's no sign they're gone, so no card, and the record stays as it is.
            case .connected, .outdated:
                if host.proofRefusal != nil { self.decideUnknown() } else { self.decide(hostSessions: host.sessions) }
            case .notRunning, .failed: self.decide(hostSessions: nil)
            case .connecting: break
            }
        }.store(in: &watching)
    }

    /// The record kept up to date from the host's live sessions and the store's (`sessions`), written as they change,
    /// only while the host has welcomed this app: a host that's gone (or not yet answered) says nothing about them.
    func watchRecord(_ host: HostClient, sessions: AnyPublisher<[Session], Never>) {
        host.$sessions.combineLatest(sessions, host.$state, host.$proofRefusal)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hosted, sessions, state, refusal in
                // Nor a host that didn't take this app's proof: it shows the app none of its sessions.
                guard refusal == nil else { return }
                switch state {
                case .connected, .outdated: self?.record(hosted: hosted, sessions: sessions)
                case .notRunning, .connecting, .failed: break
                }
            }
            .store(in: &watching)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willPowerOffNotification)
            .sink { [weak self] _ in self?.freeze() }
            .store(in: &watching)
    }

    /// The host's sessions at launch (nil: none runs): what the card offers, if anything.
    func decide(hostSessions: [HostSession]?) {
        guard !decided else { return }
        decided = true
        offered = RestartReopen.offer(record: recorded, hostSessions: hostSessions)
        chosen = Set(offered.filter { blocker($0) == nil }.map(\.id))
        if !offered.isEmpty {
            Breadcrumbs.shared.note("restart: \(offered.count) session(s) that were open are gone with the host; the card offers them")
            show()
        }
    }

    /// Launch's decision when the host's sessions can't be known: no card.
    func decideUnknown() {
        guard !decided else { return }
        decided = true
        Breadcrumbs.shared.note("restart: the session host didn't take this app's proof; no restart card, the record kept")
    }

    /// The live sessions from a host that welcomed this app.
    func record(hosted: [HostSession], sessions: [Session]) {
        lastSeen = (hosted, sessions)
        guard decided, !frozen else { return }
        let fresh = RestartReopen.entries(hosted: hosted, sessions: sessions, previous: recorded)
        guard fresh != recorded else { return }
        recorded = fresh
        do { try RestartReopen.save(fresh, to: file) } catch {
            Breadcrumbs.shared.note("restart: the open sessions' record wasn't written: \(error)")
        }
    }

    func freeze() {
        guard !frozen else { return }
        frozen = true
        freezes += 1
        let freeze = freezes
        Breadcrumbs.shared.note("restart: the Mac is shutting down; the open sessions' record is kept as it is")
        later(freezeLimit) { [weak self] in
            guard let self, self.frozen, self.freezes == freeze else { return }
            self.thaw()
        }
    }

    /// The shutdown didn't come (cancelled): the record follows the live sessions again, from what they are now.
    func thaw() {
        guard frozen else { return }
        frozen = false
        Breadcrumbs.shared.note("restart: the shutdown was cancelled; the open sessions' record follows them again")
        if let lastSeen { record(hosted: lastSeen.hosted, sessions: lastSeen.sessions) }
    }

    func blocker(_ entry: RestartReopen.Entry) -> RestartReopen.Blocker? {
        RestartReopen.blocker(entry, folderExists: folderExists)
    }

    func reopenAll() { reopen(chosen: nil) }
    func reopenChosen() { reopen(chosen: chosen) }

    /// Reopens nothing.
    func dismiss() {
        Breadcrumbs.shared.note("restart: the card was dismissed; nothing reopened")
        finish()
    }

    private func reopen(chosen: Set<UUID>?) {
        let reopening = RestartReopen.toReopen(offered, chosen: chosen, folderExists: folderExists)
        Breadcrumbs.shared.note("restart: reopening \(reopening.count) of \(offered.count) session(s)")
        for entry in reopening {
            guard let conversation = entry.agentSessionID else { continue }
            switch entry.role {
            case .lead: reopenLead(entry.folder, conversation)
            case .user: RestartReopen.spawnRequest(entry).map(resumeSession)
            }
        }
        finish()
    }

    /// Answered: asked once. A record no welcoming host has rewritten since launch still names the sessions offered;
    /// emptied, so a relaunch before any session opens doesn't ask again (the reopened ones are recorded as they start).
    private func finish() {
        offered = []
        choosing = false
        if lastSeen == nil, !recorded.isEmpty {
            recorded = []
            do { try RestartReopen.save([], to: file) } catch {
                Breadcrumbs.shared.note("restart: the open sessions' record wasn't emptied: \(error)")
            }
        }
        close()
    }
}

/// The card: what was open before the restart, each with its project, name and agent, and Reopen all or Choose.
struct RestartCardView: View {
    @ObservedObject var offer: RestartOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The Mac restarted").font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(offer.offered) { entry in
                    row(entry)
                    if entry.id != offer.offered.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            Text("Leads reopen first, and each is told to restart its workers.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Dismiss") { offer.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if offer.choosing {
                    Button("Cancel") { offer.choosing = false }
                    Button("Reopen \(offer.chosen.count)") { offer.reopenChosen() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(offer.chosen.isEmpty)
                } else {
                    Button("Choose…") { offer.choosing = true }
                        .disabled(reopenable == 0)
                    Button("Reopen all") { offer.reopenAll() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(reopenable == 0)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private var reopenable: Int { offer.offered.filter { offer.blocker($0) == nil }.count }

    private var subtitle: String {
        let count = offer.offered.count
        return "\(count) session\(count == 1 ? " was" : "s were") open. Reopen \(count == 1 ? "it" : "them") where \(count == 1 ? "it" : "they") left off?"
    }

    @ViewBuilder private func row(_ entry: RestartReopen.Entry) -> some View {
        let blocker = offer.blocker(entry)
        HStack(spacing: 10) {
            if offer.choosing {
                Toggle(isOn: Binding(get: { offer.chosen.contains(entry.id) },
                                     set: { on in if on { offer.chosen.insert(entry.id) } else { offer.chosen.remove(entry.id) } })) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(blocker != nil)
                .accessibilityLabel("Reopen \(entry.name)")
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    if entry.role == .lead {
                        Text("Lead").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                }
                Text(blocker?.text ?? detail(entry))
                    .font(.caption)
                    .foregroundStyle(blocker == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            Text(entry.agent.displayName).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .opacity(blocker == nil ? 1 : 0.7)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ entry: RestartReopen.Entry) -> String {
        entry.name == entry.project ? ProjectCreation.tildePath(entry.folder) : "\(entry.project) · \(ProjectCreation.tildePath(entry.folder))"
    }
}

/// The card's own small window, shown once at launch when there's something to offer. Closing it dismisses the card.
final class RestartCardWindowController: NSWindowController, NSWindowDelegate {
    private let offer: RestartOffer

    init(offer: RestartOffer) {
        self.offer = offer
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Reopen Sessions"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RestartCardView(offer: offer))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        if !offer.offered.isEmpty { offer.dismiss() }
    }

    func show() {
        showWindow(nil)
        window?.orderFrontRegardless()
    }
}
