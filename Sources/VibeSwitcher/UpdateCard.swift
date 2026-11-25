import AppKit
import SwiftUI
import VibeCore

/// The update card's model: the newer VibeSwitcher the update check found (`AppUpdateWatch`), its changelog, and what
/// the buttons do. Nothing installs until Install & Restart is clicked; Later snoozes this version.
final class UpdateDesk: ObservableObject {
    /// What the card shows: a newer version, or (after Check for Updates…) that there's none.
    enum Shown: Equatable {
        case offer(AppUpdate.Offer)
        /// Up to date, or why it couldn't be checked.
        case nothing(String?)
    }

    @Published private(set) var shown: Shown?
    @Published var showAll = false
    /// Why the last Install & Restart didn't go, or what it's doing.
    @Published var note: String?
    @Published private(set) var installing = false

    /// The checkout it builds in, as the card says it.
    var checkout: String = ""
    var install: (AppUpdate.Offer) -> Void = { _ in }
    var later: (AppUpdate.Offer) -> Void = { _ in }
    var show: () -> Void = {}
    var close: () -> Void = {}

    var offer: AppUpdate.Offer? {
        if case .offer(let offer) = shown { return offer }
        return nil
    }

    /// Shows `offer` (the same card updated in place when it already shows a version); brings the window forward only
    /// with `front`: a scheduled look at a version waiting on the lead's merge mustn't take the screen each minute.
    func present(_ offer: AppUpdate.Offer, front: Bool = true) {
        if self.offer != offer {
            if self.offer?.newest != offer.newest { showAll = false }
            note = nil
            installing = false
            shown = .offer(offer)
        }
        if front { show() }
    }

    /// Check for Updates… found nothing newer (`why`: it couldn't look, and why).
    func presentNothing(_ why: String?) {
        note = nil
        shown = .nothing(why)
        show()
    }

    /// A check found nothing newer while the card showed a version (installed meanwhile): it goes.
    func withdraw() {
        guard offer != nil else { return }
        shown = nil
        close()
    }

    func installClicked() {
        guard let offer, offer.ready, !installing else { return }
        installing = true
        note = nil
        install(offer)
    }

    /// The install didn't start: why, on the card.
    func refused(_ why: String) {
        installing = false
        note = why
    }

    /// The shell started: the card goes.
    func started() {
        installing = false
        shown = nil
        close()
    }

    func laterClicked() {
        if let offer { later(offer) }
        shown = nil
        close()
    }

    func dismiss() {
        shown = nil
        close()
    }
}

/// The card: what's new (a short summary, then the changes grouped by area), Install & Restart, Later, and Show all
/// changes.
struct UpdateCardView: View {
    @ObservedObject var desk: UpdateDesk
    /// Changes listed before Show all changes.
    static let collapsed = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch desk.shown {
            case .offer(let offer): offerBody(offer)
            case .nothing(let why): nothingBody(why)
            case nil: EmptyView()
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    @ViewBuilder private func offerBody(_ offer: AppUpdate.Offer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: offer.ready ? "arrow.down.circle.fill" : "hourglass.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.ready ? "A new VibeSwitcher is ready" : "A new VibeSwitcher is on its way").font(.headline)
                Text(subtitle(offer)).font(.callout).foregroundStyle(.secondary)
            }
        }
        if let summary = offer.summary {
            Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        changes(offer)
        if !offer.ready {
            Label("Getting it ready: \(waitingText(offer)) on GitHub, and your project's lead merges them into this Mac's main first. Install & Restart turns on once it has.",
                  systemImage: "arrow.triangle.merge")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Install & Restart opens a shell in \(ProjectCreation.tildePath(desk.checkout)) that asks for your signing keychain's password, then builds, installs and relaunches VibeSwitcher.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let note = desk.note {
            Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button("Later") { desk.laterClicked() }
                .keyboardShortcut(.cancelAction)
                .help("Not this version: the card comes back when a newer one appears")
            if offer.changes.count > Self.collapsed {
                Button(desk.showAll ? "Show fewer" : "Show all changes") { desk.showAll.toggle() }
            }
            Spacer()
            Button(desk.installing ? "Opening…" : "Install & Restart") { desk.installClicked() }
                .keyboardShortcut(.defaultAction)
                .disabled(!offer.ready || desk.installing)
        }
    }

    @ViewBuilder private func nothingBody(_ why: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: why == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(why == nil ? Color.green : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(why == nil ? "VibeSwitcher is up to date" : "Couldn't check for updates").font(.headline)
                Text(why ?? "Nothing newer on this Mac's main or on GitHub.").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            Spacer()
            Button("OK") { desk.dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func subtitle(_ offer: AppUpdate.Offer) -> String {
        let count = offer.changes.count
        return "\(count) change\(count == 1 ? "" : "s") since your version (\(offer.installed.prefix(8)))."
    }

    private func waitingText(_ offer: AppUpdate.Offer) -> String {
        offer.waiting == offer.changes.count ? (offer.waiting == 1 ? "it is" : "they are")
            : "\(offer.waiting) of them \(offer.waiting == 1 ? "is" : "are")"
    }

    @ViewBuilder private func changes(_ offer: AppUpdate.Offer) -> some View {
        let listed = desk.showAll ? offer.changes : Array(offer.changes.prefix(Self.collapsed))
        let groups = AppUpdate.groups(listed)
        let list = VStack(alignment: .leading, spacing: 8) {
            ForEach(groups, id: \.area) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.area).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(group.changes, id: \.id) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                // Commit subjects are text from the repository: shown as plain text, never as markdown.
                                Text(verbatim: Self.shortSubject(change.subject, area: group.area))
                                    .font(.callout).lineLimit(desk.showAll ? nil : 2)
                                    .fixedSize(horizontal: false, vertical: true)
                                // Who pushed it to GitHub, when GitHub said (a change only GitHub has).
                                if let pusher = change.pusher {
                                    Text(verbatim: Self.pushedBy(pusher)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if !desk.showAll, offer.changes.count > listed.count {
                Text("and \(offer.changes.count - listed.count) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if desk.showAll {
                ScrollView { list }.frame(maxHeight: 320)
            } else {
                list
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    /// "pushed by @login": the GitHub handle that pushed a change.
    static func pushedBy(_ login: String) -> String { "pushed by @\(login)" }

    /// The subject without its area (the group's heading says it).
    static func shortSubject(_ subject: String, area: String) -> String {
        guard area != "Other", let colon = subject.range(of: ": ") else { return subject }
        let rest = subject[colon.upperBound...]
        // A name as it's written ("merge_remote …", "vs-shell …") keeps its case.
        let first = rest.prefix { !$0.isWhitespace }
        guard first.allSatisfy(\.isLetter) else { return String(rest) }
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }
}

/// The card's own small window. Closing it dismisses the card without the snooze: the schedule shows it again only
/// when the version or whether it's ready changes (`UpdateChecks.shown`), and Check for Updates… at once.
final class UpdateCardWindowController: NSWindowController, NSWindowDelegate {
    private let desk: UpdateDesk

    init(desk: UpdateDesk) {
        self.desk = desk
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "VibeSwitcher Update"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: UpdateCardView(desk: desk))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        if desk.shown != nil { desk.dismiss() }
    }

    func show() {
        showWindow(nil)
        window?.orderFrontRegardless()
    }
}
