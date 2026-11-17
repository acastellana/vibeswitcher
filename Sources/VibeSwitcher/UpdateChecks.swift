import AppKit
import VibeCore

/// The app's update check, run: `AppUpdateWatch` on a queue of its own, ticked once a minute (about 2 minutes after
/// launch, then every 6 hours), and Check for Updates…; what it finds shows on the update card (`UpdateDesk`).
/// Install & Restart opens a shell session in the checkout running `AppUpdate.installCommand` (as a vs-shell card's
/// Run does), which asks for the signing keychain's password: nothing installs without that click.
///
/// Only AppDelegate makes one; the sandbox never does, so it never fetches GitHub.
final class UpdateChecks {
    let desk = UpdateDesk()
    private var card: UpdateCardWindowController?
    private let queue = DispatchQueue(label: "dev.vibeswitcher.update-check", qos: .utility)
    private var timer: Timer?
    /// On `queue` only.
    private var watch: AppUpdateWatch?
    private var roots: [String] = []
    /// The settings as last read on the main thread.
    private var limitNow = 0
    private var summariesNow = false

    /// The projects the app's leads run in (main thread).
    var leadRoots: () -> [String] = { [] }
    /// Settings › Performance's battery limit, in % (main thread).
    var batteryLimit: () -> Int = { 0 }
    /// Settings' AI summaries (main thread).
    var aiSummaries: () -> Bool = { true }
    /// Starts a shell session for the request and selects it; nil, or why it didn't start (main thread).
    var spawn: (_ request: SpawnRequest, _ then: @escaping (String?) -> Void) -> Void = { _, then in then("no session host") }
    /// A report to a project's lead (main thread).
    var tellLead: (_ root: String, _ text: String) -> Void = { _, _ in }
    let installed: ServerBuild?

    init(installed: ServerBuild? = ServerBuild.running) {
        self.installed = installed
        desk.show = { [weak self] in
            guard let self else { return }
            let card = card ?? UpdateCardWindowController(desk: desk)
            self.card = card
            card.show()
        }
        desk.close = { [weak self] in self?.card?.close() }
        desk.later = { [weak self] offer in self?.queue.async { self?.watch?.snooze(offer) } }
        desk.install = { [weak self] offer in self?.install(offer) }
    }

    func start(now: Date = Date()) {
        guard timer == nil else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let installed = installed
            watch = AppUpdateWatch(
                launched: now, file: AppUpdateWatch.file,
                checkout: { [weak self] in self.flatMap { AppUpdateWatch.Checkout.find(among: $0.roots, installed: installed) } },
                installed: { installed },
                fetch: { checkout in
                    let pin = try? LeadVault.standard.guardedSettings(root: checkout.root)?[LeadRemote.urlKey(checkout.remote)]
                    let scratch = VibePaths.root.appendingPathComponent("update-git", isDirectory: true)
                    do { try VibePaths.ensurePrivate(scratch) } catch {
                        return .failure(AppUpdate.Failure("couldn't make \(scratch.path): \(error)"))
                    }
                    return AppUpdate.fetch(root: checkout.root, remote: checkout.remote, base: checkout.base, pin: pin, scratch: scratch)
                },
                power: { PowerState.load() },
                batteryLimit: { [weak self] in self?.limitNow ?? 0 },
                summarize: { [weak self] prompt in self?.summariesNow == true ? AppUpdate.headless(prompt) : nil },
                tellLead: { [weak self] root, text in DispatchQueue.main.async { self?.tellLead(root, text) } })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 10
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() { look(asked: false) }

    /// Check for Updates…: at once; the card says what it found, nothing newer included.
    func checkNow() { look(asked: true) }

    private func look(asked: Bool) {
        let (roots, limit, summaries) = (leadRoots(), batteryLimit(), aiSummaries())
        queue.async { [weak self] in
            guard let self, let watch else { return }
            (self.roots, limitNow, summariesNow) = (roots, limit, summaries)
            let outcome = asked ? watch.checkNow(now: Date()) : watch.tick(now: Date())
            let root = watch.found?.root
            DispatchQueue.main.async { self.shown(outcome, asked: asked, root: root) }
        }
    }

    /// What the card was last shown for (main thread).
    private var memory = CardMemory()

    /// A version, and whether it's ready: what the schedule shows the card again for.
    static func key(_ offer: AppUpdate.Offer) -> String { offer.newest + (offer.ready ? " installable" : " merge first") }

    /// The version and state the schedule last showed (or found while the card was up), so a card the user closed
    /// isn't reopened for it; forgotten when Install & Restart's shell starts, so that if this build is still the one
    /// running at a later check (the build failed, or its password was cancelled), the card comes back.
    struct CardMemory {
        private(set) var presented: String?

        mutating func presentation(_ offer: AppUpdate.Offer, show: Bool, asked: Bool, up: AppUpdate.Offer?) -> Presentation {
            defer { presented = UpdateChecks.key(offer) }
            return UpdateChecks.presentation(offer, show: show, asked: asked, up: up, presented: presented)
        }

        /// A successful install relaunches the app, so a later check that still finds the version means it didn't take.
        mutating func installStarted() { presented = nil }
    }

    private func shown(_ outcome: AppUpdateWatch.Outcome, asked: Bool, root: String?) {
        if let root { desk.checkout = root }
        switch outcome {
        case .notDue, .held:
            break
        case .unavailable(let why):
            if asked { desk.presentNothing(why) }
        case .checked(nil, _):
            if asked { desk.presentNothing(nil) } else { desk.withdraw() }
        case .checked(let offer?, let show):
            switch memory.presentation(offer, show: show, asked: asked, up: desk.offer) {
            case .front: desk.present(offer)
            case .inPlace: desk.present(offer, front: false)
            case .not: break
            }
        }
    }

    enum Presentation: Equatable { case front, inPlace, not }

    /// How a check's `offer` shows: Check for Updates… brings it forward. A card already up (`up`) follows it in
    /// place, and comes forward only when it turns ready (the lead's merge landed): the minute's looks while it waits
    /// don't take the screen. No card up: shown when the schedule may (`show`: not snoozed), unless it's the version
    /// and state the user already closed the card on (`presented`).
    static func presentation(_ offer: AppUpdate.Offer, show: Bool, asked: Bool, up: AppUpdate.Offer?, presented: String?) -> Presentation {
        if asked { return .front }
        if let up { return offer.ready && !up.ready ? .front : .inPlace }
        return show && key(offer) != presented ? .front : .not
    }

    /// Install & Restart: checked again (the card may be hours old), then the shell.
    private func install(_ offer: AppUpdate.Offer) {
        queue.async { [weak self] in
            guard let self else { return }
            // The checkout the watch last used, whether a running lead's project or the one it remembered.
            guard let checkout = watch?.found else { return DispatchQueue.main.async { self.desk.refused("VibeSwitcher's checkout isn't known any more.") } }
            if let why = AppUpdate.installRefusal(root: checkout.root, base: checkout.base, offer: offer) {
                return DispatchQueue.main.async { self.desk.refused(why) }
            }
            let request = ShellRequest(session: UUID().uuidString.lowercased(), cwd: checkout.root, command: AppUpdate.installCommand(),
                                       label: "Install VibeSwitcher", createdAt: Date())
            Breadcrumbs.shared.note("update: Install & Restart of \(offer.newest.prefix(12)) in \(checkout.root)")
            DispatchQueue.main.async {
                self.spawn(ShellAsk.spawnRequest(request)) { failure in
                    if let failure { self.desk.refused("The shell didn't start: \(failure)") } else {
                        self.memory.installStarted()
                        self.desk.started()
                    }
                }
            }
        }
    }
}
