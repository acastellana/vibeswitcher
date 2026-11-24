import Foundation

/// When the app checks for a newer VibeSwitcher (`AppUpdate`): about 2 minutes after launch, then every 6 hours, and
/// when you choose Check for Updates…. A scheduled check waits while the Mac is on battery under your limit
/// (Settings › Performance). A failed fetch (offline, signed out) is logged once until one succeeds, and the check goes
/// on with what this Mac has (its main, and GitHub's as last fetched); the next try is the next slot, never an error
/// card. Commits only GitHub has go to the project's lead once per GitHub tip, asking for merge_remote.
///
/// Not thread-safe: the app calls it on one serial queue. Everything it reads of the world is injected, so tests drive
/// it with their own clock, scratch repositories and power readings.
public final class AppUpdateWatch {
    public static let firstDelay: TimeInterval = 120
    public static let interval: TimeInterval = 6 * 60 * 60
    /// While a card waits on the lead's merge, this Mac's main is looked at again this often (no fetch) to offer the
    /// install as soon as the merge lands.
    public static let waitingLook: TimeInterval = 60
    /// The lead's report's sender.
    public static let sender = "update check"

    /// The checkout VibeSwitcher is built from, and its workflow's remote and base branch.
    public struct Checkout: Equatable, Sendable {
        public var root: String
        public var remote: String
        public var base: String
        public init(root: String, remote: String = LeadRemote.defaultRemote, base: String = "main") {
            self.root = root
            self.remote = remote
            self.base = base
        }

        /// VibeSwitcher's checkout among `roots` (`AppUpdate.sourceCheckout`), with its workflow.md's remote and base
        /// branch (origin and main unless set).
        public static func find(among roots: [String], installed: ServerBuild?) -> Checkout? {
            guard let root = AppUpdate.sourceCheckout(among: roots, installed: installed) else { return nil }
            let workflow = LeadWorkflow.load(from: (BoardStore(root: root).folder as NSString).appendingPathComponent("workflow.md"))
            return Checkout(root: root, remote: workflow.remoteName, base: workflow.base)
        }
    }

    public enum Outcome: Equatable {
        /// Not time yet.
        case notDue
        /// On battery under the user's limit: tried again at the next tick.
        case held
        /// Nothing to compare (no checkout found, a build that can't be compared): said why.
        case unavailable(String)
        /// Looked: the newer version (nil: up to date), and whether it's one to show (not snoozed).
        case checked(AppUpdate.Offer?, show: Bool)
    }

    /// What's kept across launches: the version Later snoozed, and the GitHub tip the lead was told about.
    struct State: Codable, Equatable {
        var snoozed: String?
        var reported: String?
        /// The checkout last found: looked at while no lead of it runs (the leads' projects are where it's found).
        var root: String?
    }

    public var checkout: () -> Checkout?
    public var installed: () -> ServerBuild?
    /// The fetch (`AppUpdate.fetch`, with the vault's pin): the remote's tip, or why not.
    public var fetch: (Checkout) -> Result<String, AppUpdate.Failure>
    public var power: () -> PowerState?
    /// The user's battery limit, in %.
    public var batteryLimit: () -> Int
    /// The headless summary (`AppUpdate.headless`); nil while AI summaries are off.
    public var summarize: ((String) -> String?)?
    /// Who pushed GitHub's changes, given the remote's tip and their ids (`GitHubPushers.Lookup`, cached per tip, a
    /// few seconds at most, from the remote's URL only when it's the lead's pinned one, as `fetch`); empty: no names.
    public var pushers: (_ checkout: Checkout, _ tip: String, _ commits: [String]) -> [String: String]
    /// Tells the project's lead (a report on its board).
    public var tellLead: (_ root: String, _ text: String) -> Void
    public var log: (String) -> Void

    private let file: URL
    private var state: State
    public private(set) var next: Date
    /// The last offer found, with its summary (asked once per version).
    public private(set) var offer: AppUpdate.Offer?
    private var lastLook: Date?
    private var fetchFailing = false
    private var unavailable: String?
    /// The checkout the last check used (a lead's project, or the one remembered): what Install & Restart builds in.
    public private(set) var found: Checkout?

    public init(launched: Date, file: URL, checkout: @escaping () -> Checkout?, installed: @escaping () -> ServerBuild?,
                fetch: @escaping (Checkout) -> Result<String, AppUpdate.Failure>, power: @escaping () -> PowerState? = { nil },
                batteryLimit: @escaping () -> Int = { 0 }, summarize: ((String) -> String?)? = nil,
                pushers: @escaping (_ checkout: Checkout, _ tip: String, _ commits: [String]) -> [String: String] = { _, _, _ in [:] },
                tellLead: @escaping (_ root: String, _ text: String) -> Void = { _, _ in },
                log: @escaping (String) -> Void = { Breadcrumbs.shared.note("update: " + $0) }) {
        self.file = file
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: file))) ?? State()
        next = launched.addingTimeInterval(Self.firstDelay)
        self.checkout = checkout
        self.installed = installed
        self.fetch = fetch
        self.power = power
        self.batteryLimit = batteryLimit
        self.summarize = summarize
        self.pushers = pushers
        self.tellLead = tellLead
        self.log = log
    }

    /// The app's own file for it.
    public static var file: URL { VibePaths.root.appendingPathComponent("update-check.json") }

    public var snoozed: String? { state.snoozed }

    /// Whether the Mac is on battery under the user's limit.
    public static func held(_ power: PowerState?, limit: Int) -> Bool {
        guard let power, power.onBattery else { return false }
        return power.percent < limit
    }

    /// The scheduled check, once a minute: looks when it's due (fetching first), or, while the offer waits on the
    /// lead's merge, at this Mac's main alone every `waitingLook`.
    public func tick(now: Date) -> Outcome {
        if now >= next {
            if Self.held(power(), limit: batteryLimit()) { return .held }
            // No checkout found yet (its lead not started): tried again at the next tick, the slot kept.
            guard let checkout = findCheckout() else { return unavailable("no VibeSwitcher checkout among the leads' projects") }
            next = now.addingTimeInterval(Self.interval)
            return look(now: now, fetching: true, asked: false, checkout: checkout)
        }
        if let offer, !offer.ready, lastLook.map({ now.timeIntervalSince($0) >= Self.waitingLook }) ?? true {
            return look(now: now, fetching: false, asked: false)
        }
        return .notDue
    }

    /// Check for Updates…: at once, whatever the schedule and the battery, and shown even when snoozed. The next
    /// scheduled check is a full interval after it.
    public func checkNow(now: Date) -> Outcome {
        next = now.addingTimeInterval(Self.interval)
        return look(now: now, fetching: true, asked: true)
    }

    /// Later: this version (its newest commit) isn't shown again by the schedule until a newer one appears.
    public func snooze(_ offer: AppUpdate.Offer) {
        state.snoozed = offer.newest
        save()
    }

    /// The checkout among the leads' projects, else the one last found (kept across launches) while it's still one.
    private func findCheckout() -> Checkout? {
        if let current = checkout() {
            if state.root != current.root {
                state.root = current.root
                save()
            }
            found = current
        } else {
            found = state.root.flatMap { Checkout.find(among: [$0], installed: installed()) }
        }
        return found
    }

    private func look(now: Date, fetching: Bool, asked: Bool, checkout found: Checkout? = nil) -> Outcome {
        lastLook = now
        guard let checkout = found ?? findCheckout() else { return unavailable("no VibeSwitcher checkout among the leads' projects") }
        if fetching {
            switch fetch(checkout) {
            case .success:
                if fetchFailing { log("fetching \(checkout.remote)/\(checkout.base) works again") }
                fetchFailing = false
            case .failure(let error):
                // Once until it works again; the check goes on with what this Mac has.
                if !fetchFailing { log("fetching \(checkout.remote)/\(checkout.base) failed (tried again at the next check): \(error)") }
                fetchFailing = true
            }
        }
        let pushers = self.pushers
        let named = { (tip: String, commits: [String]) in pushers(checkout, tip, commits) }
        switch AppUpdate.find(root: checkout.root, remote: checkout.remote, base: checkout.base, installed: installed(), pushers: named) {
        case .failure(let error):
            return unavailable(error.description)
        case .success(nil):
            unavailable = nil
            offer = nil
            return .checked(nil, show: false)
        case .success(var found?):
            unavailable = nil
            if let offer, offer.newest == found.newest, offer.changes == found.changes {
                found.summary = offer.summary
            } else if let summarize {
                found.summary = AppUpdate.summarize(found.changes, ask: summarize)
            }
            offer = found
            report(found, checkout: checkout)
            return .checked(found, show: asked || !isSnoozed(found, root: checkout.root))
        }
    }

    /// Snoozed: Later was chosen on this version or a newer one.
    func isSnoozed(_ offer: AppUpdate.Offer, root: String) -> Bool {
        guard let snoozed = state.snoozed else { return false }
        return snoozed == offer.newest || Git.run(["merge-base", "--is-ancestor", offer.newest, snoozed], in: root).ok
    }

    /// Commits only GitHub has: the lead is asked for merge_remote, once per GitHub tip.
    private func report(_ offer: AppUpdate.Offer, checkout: Checkout) {
        guard !offer.ready, let tip = offer.tip, state.reported != tip else { return }
        state.reported = tip
        save()
        tellLead(checkout.root, Self.reportText(offer, checkout: checkout))
    }

    static func reportText(_ offer: AppUpdate.Offer, checkout: Checkout) -> String {
        let label = "\(checkout.remote)/\(checkout.base)"
        // GitHub's own, not this Mac's: what main lacks.
        let waiting = offer.tip.flatMap { AppUpdate.changes(root: checkout.root, from: offer.installed, to: [$0], excluding: [offer.head]) }
            ?? Array(offer.changes.prefix(offer.waiting))
        let subjects = waiting.prefix(5).map { LeadToolset.clip($0.subject, 100) }.joined(separator: "; ")
            + (offer.waiting > 5 ? "; … and \(offer.waiting - 5) more" : "")
        return "\(label) (\((offer.tip ?? "").prefix(8))) has \(LeadToolset.commits(offer.waiting)) for the app that \(checkout.base) lacks (\(subjects)). "
            + "The user's update card waits on them: run fetch_remote, then merge_remote, and the card offers Install & Restart once \(checkout.base) holds them. "
            + "(The app's update check fetched \(label) itself, so its remote-tracking ref may be past what fetch_remote recorded: fetch_remote takes it again.)"
    }

    private func unavailable(_ why: String) -> Outcome {
        if unavailable != why { log("no update check: \(why)") }
        unavailable = why
        return .unavailable(why)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? VibePaths.writePrivate(data, to: file)
    }
}
