import AppKit
import Combine
import Foundation
import VibeCore

/// The wallet requests agents filed (`WalletAsk`, `vs-wallet request`), as cards in the asking session's chat, and their
/// way to the Wallet Manager's Mac and back: nothing goes until the user presses Send to Wallet Manager on the card (`act(.send)`); Retry
/// sends again after Passage couldn't reach the Wallet Manager or stopped unsure; Discard drops the request (and forgets it, so
/// its answers are no longer listened for). Each result the Wallet Manager sends back updates the card and goes to the asking
/// session as a message (`deliver`), as does a request that expires before the user sent it. VibeSwitcher never signs
/// or judges: the card shows what the Wallet Manager said.
///
/// Every such message is kept on disk (`WalletOutbox`) until it reached the agent: one told while its session isn't
/// live, or before the session host's welcome (at launch), goes at a later look; one whose session ended for good says
/// so on its card, and goes with the request's results window. What marks a message as told (an expiry's, a browser
/// page's no answer) is written only once it went.
///
/// A request's record and browser mark are files any process of the user's can write. A card is drawn from one only
/// when it carries the session host's seal or equals the host-stamped filed request (`vouched`); otherwise the
/// request gets no card and no Retry, and the log says so without repeating what the copy says.
///
/// The fallback, while a request has never reached the Wallet Manager: Sign in browser wallet (`act(.browser)`) serves
/// the request on a local page (`WalletSignServer`) and opens it in the browser, whose wallet extension shows and signs
/// it; what it did comes back to the card and the asking session. A mark beside the filed request (`WalletBrowser.Mark`)
/// records that it went that way, so it can't also be sent to the Wallet Manager, nor the reverse. It needs no Wallet
/// Manager set up: with no peer chosen or no Passage found, cards still show, Send gives way to a line saying what's
/// missing and Open Settings (`openSettings`, Settings › Wallet), and Send comes back once Settings has what it needs.
///
/// With the Wallet Manager on this Mac chosen there (`WalletAsk.WalletManager.onThisMac`), the same cards and the
/// same Send go through the folder pair (`WalletLocalLink`) and never through Passage: nothing runs `passage`, and
/// with a Passage peer chosen nothing touches the folders. Its results show as the watch on the folder hears them.
///
/// Its state lives on a queue of its own (`work`), where Passage runs (a send blocks for seconds); `cards` is
/// published on the main thread.
final class WalletDesk: ObservableObject {
    /// Every card, oldest request first.
    @Published private(set) var cards: [WalletCardModel] = []
    /// The asking session's id (lower case) for each card's id.
    @Published private(set) var sessions: [String: String] = [:]
    /// The request each card was drawn from: a button sends only that one (a file rewritten since isn't sent unseen).
    private(set) var drawn: [String: WalletRequest] = [:]
    /// Every card drawn at the last look with its session and request, before `maxCards` cut them (oldest first, in
    /// filing order). Send all lists from these, so the cap on the cards shown never drops a waiting request from its
    /// list or reorders it; a card's buttons act through it too (`act`).
    struct Uncut: Equatable {
        var cards: [WalletCardModel] = []
        var sessions: [String: String] = [:]
        var drawn: [String: WalletRequest] = [:]
    }
    /// Published: the count Send all offers is read from it, and changes while the cards shown stay the same.
    @Published private(set) var uncut = Uncut()
    /// The cards the user took off the strip with Dismiss, by request id (`dismissedFile`, kept across launches).
    @Published private(set) var dismissed: Set<String> = []

    /// Where Passage is and which peer is the Wallet Manager's Mac: Settings › Wallet (read on the main thread).
    struct Config: Equatable {
        /// The `passage` command: an absolute path (`passage`, Passage.app or its binary), or empty to find it.
        var passage: String
        /// The Wallet Manager peer's ID; empty: none chosen; `WalletAsk.WalletManager.onThisMac`: the Wallet Manager on
        /// this Mac, through `localLink` and no Passage.
        var peer: String
    }

    let folder: URL
    let store: WalletRequestStore
    let inbox: URL
    /// The folder pair to a Wallet Manager on this Mac, used only while Settings › Wallet has it chosen.
    let localLink: WalletLocalLink
    /// The messages not delivered yet: `undelivered/` beside the store's records.
    let outbox: WalletOutbox
    /// Settings › Wallet, read on the main thread.
    var config: () -> Config
    /// Passage found when no path is set (off the main thread): `passage` on the login shell's PATH, else Passage.app
    /// in /Applications or ~/Applications; nil when there's none.
    var findPassage: () -> PassageCommand? = { PassageCommand.resolve(setting: "", onPath: WalletPeerChoice.findPassage) }
    /// Hands a message to the asking session's agent (its id, lower case), on the main thread; `then` says whether it
    /// reached it (any thread). Until it says `.delivered`, the message stays in the outbox and is tried again.
    var deliver: (_ session: String, _ text: String, _ then: @escaping (SessionDelivery) -> Void) -> Void = { _, _, then in then(.notYet) }
    /// The sessions the session host runs, each id (lower case) with its name as the window shows it, read on the main
    /// thread. A filed request whose `requestedBy.session` isn't among them gets no card, so nothing can be sent from
    /// it: the folder is a file anyone's shell can write, and a card names its asker as VibeSwitcher knows it, never
    /// as the request says. Fail closed: none until the host's sessions are known.
    var sessionNames: () -> [String: String] = { [:] }
    /// Asks the session host which of these stamps carry its seal (`LeadVault.verifyWallet`), on `work`: a filed
    /// request gets a card only once the host confirms it stamped those bytes for the session the request names, the
    /// one the filing process ran in. One it says no to is refused and removed; while it can't be asked, none gets a
    /// card. Fail closed: none until set.
    var verifyStamps: ([WalletStamp]) throws -> [Bool] = { $0.map { _ in false } }
    /// The session host's seal on an outbox entry (`WalletOutbox.Entry.sealed`, VibeSwitcher's own message: `LeadVault.seal`),
    /// on `work`. Throws while the host can't be asked: the entry is kept in memory and sealed at a later look.
    var sealMessage: (SteerMessage) throws -> String = { _ in throw WalletAsk.Refusal("no session host to seal it") }
    /// Which of these outbox entries carry the host's seal (`LeadVault.verify`), on `work`. An entry read from disk is
    /// handed over only once the host says so; one it says no to is removed. Throws while it can't be asked: nothing
    /// read from disk goes, and nothing is removed. Fail closed: it can't be asked until set.
    var verifyMessages: ([SteerMessage]) throws -> [Bool] = { _ in throw WalletAsk.Refusal("no session host to check it") }
    /// Opens Settings › Wallet (a card's Open Settings), on the main thread.
    var openSettings: () -> Void = {}
    /// Opens the local page in the browser, on the main thread (a test catches it instead: never the user's browser).
    var openBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }
    let now: @Sendable () -> Date
    let log: @Sendable (String) -> Void

    private let work = DispatchQueue(label: "dev.vibeswitcher.wallet-desk", qos: .userInitiated)
    // On `work` only:
    private var requests: [WalletRequest] = []
    /// `sessionNames` as last read.
    private var names: [String: String] = [:]
    /// The filed requests that got no card for their session, each logged once.
    private var unknownSession: Set<String> = []
    /// The stamps the host confirmed, by request id.
    private var stamped: [String: WalletStamp] = [:]
    /// Whether the host couldn't be asked about stamps last time (logged once until it can).
    private var stampsUnasked = false
    /// Card states before or instead of a record: being sent, couldn't reach the Wallet Manager, not sent.
    private var local: [String: WalletCardModel.State] = [:]
    /// What Passage said when it stopped unsure, per request.
    private var unsureWhy: [String: String] = [:]
    private var courier: WalletCourier?
    /// What `courier` was made for: the Passage it runs (nil for the Wallet Manager on this Mac) and the peer setting.
    private var courierFor: (passage: PassageCommand?, peer: String)?
    /// Whether the Wallet Manager on this Mac is the one chosen, from the last time a courier was asked for.
    private var onThisMac = false
    /// Passage found with no path set, once found.
    private var foundPassage: PassageCommand?
    /// The requests that went to the browser wallet, as their marks say (read from `folder`, written through).
    private var marks: [String: WalletBrowser.Mark] = [:]
    /// The local pages open now, and until when each is served.
    private var pages: [String: (server: WalletSignServer, until: Date)] = [:]
    /// When the Wallet Manager's Mac took each request that has no answer yet (or when this run first saw it so).
    private var sentSince: [String: Date] = [:]
    /// What Settings › Wallet lacks for the Wallet Manager, as the cards say it (`WalletCardModel.setupNeeded`), from the
    /// last time a courier was asked for; nil when it has a peer and a Passage.
    private var setupNeeded: String?
    /// The outbox as on disk, by request id (read at the first look, written through).
    private var undelivered: [String: [WalletOutbox.Entry]]?
    /// The messages handed to `deliver` whose answer hasn't come back yet ("<id>|<key>"): not handed again meanwhile.
    private var handing: Set<String> = []
    /// The outbox entries that may be handed over ("<id>|<key>"): told in this run (made here, in memory), or read from
    /// disk with a seal the host confirmed. Anything else on disk is someone else's writing until the host says so.
    private var trusted: Set<String> = []
    /// Whether the host couldn't be asked about the outbox's seals last time (logged once until it can).
    private var outboxUnasked = false
    /// The cards not shown last time, over `maxCards` (logged when that changes).
    private var overCap: Set<String> = []
    /// `dismissed`, with when each was dismissed: read from `dismissedFile` at the first publish, written through.
    private var dismissedAt: [String: Date]?
    /// The requests with a record or browser mark that may not speak for them (`vouched`): no card, no Retry, logged once.
    private var refusedCopies: Set<String> = []
    /// What the host said of the last sealed copy asked about, of each kind and request ("<kind>/<id>").
    private var checkedCopies: [String: (copy: WalletRequest, seal: String, valid: Bool)] = [:]
    /// Whether the host couldn't be asked about a copy's seal last time (logged once until it can).
    private var copiesUnasked = false
    /// Results taken while the host couldn't say whether their record may speak: told at a later look, once it can.
    private var heldResults: [WalletResult] = []

    init(folder: URL = WalletAsk.folder, store: WalletRequestStore = WalletRequestStore(), inbox: URL = PassageLink.defaultInbox,
         local: WalletLocalLink = WalletLocalLink(), config: @escaping () -> Config, now: @escaping @Sendable () -> Date = { Date() },
         log: @escaping @Sendable (String) -> Void = { Breadcrumbs.shared.note("wallet: " + $0) }) {
        self.folder = folder
        self.store = store
        self.inbox = inbox
        self.localLink = local
        self.outbox = WalletOutbox(folder: store.folder.appendingPathComponent("undelivered", isDirectory: true))
        self.config = config
        self.now = now
        self.log = log
    }

    /// `sessionNames` from the host's sessions and the window's rows: each session's row title (its name in the list), else
    /// its title or preset as the host has it.
    static func names(hosted: [HostSession], rows: [WindowRow]) -> [String: String] {
        var titles: [UUID: String] = [:]
        for row in rows { if let id = row.hostID, titles[id] == nil { titles[id] = row.title } }
        var names: [String: String] = [:]
        for session in hosted {
            names[session.id.uuidString.lowercased()] = titles[session.id] ?? (session.title.isEmpty ? session.label : session.title)
        }
        return names
    }

    #if DEBUG
    /// Debug aid (the sandbox's soak): how many of each thing it keeps, as one line. Waits for `work`.
    var census: String {
        let shown = "cards \(cards.count) drawn \(drawn.count)"
        return work.sync {
            let kept = courier?.kept
            return shown + " requests \(requests.count) local \(local.count) unsure \(unsureWhy.count) marks \(marks.count) "
                + "pages \(pages.count) sent-since \(sentSince.count) undelivered \(undelivered?.values.joined().count ?? 0) trusted \(trusted.count) records \(kept?.records ?? 0) handled \(kept?.handled ?? 0)"
        }
    }
    #endif

    /// The cards of one session's requests that its strip shows (`shows`): those that need the user.
    func cards(for session: UUID) -> [WalletCardModel] {
        let id = session.uuidString.lowercased()
        return cards.filter { sessions[$0.id] == id && Self.shows($0, dismissed: dismissed) }
    }

    /// Whether the strip shows `card`: its state needs the user (`State.showsOnStrip`), or it was sent and the
    /// Wallet Manager hasn't picked it up in 5 minutes (`notPickedUp`: the card asks whether it runs); and it isn't
    /// one they dismissed. Only a card that offers Dismiss can be dismissed, so an entry in `dismissedFile` (any
    /// process of the user's can write it) never hides a card that waits for Send or Retry.
    static func shows(_ card: WalletCardModel, dismissed: Set<String>) -> Bool {
        guard card.state.showsOnStrip || (card.state == .sent && card.notPickedUp) else { return false }
        return !(dismissed.contains(card.id) && WalletCardModel.actions(for: card.state).contains(.dismiss))
    }

    /// The record of the cards dismissed: `dismissed.json` beside the request records (0600). Not a record's name, so
    /// the store passes it by.
    var dismissedFile: URL { store.folder.appendingPathComponent("dismissed.json") }
    /// How long a dismissal is kept: past a request's results window and its record's 30 days, it has no card anyway.
    static let dismissedKept: TimeInterval = 60 * 86_400

    /// Reads the filed requests again, takes the Wallet Manager's new results while any is outstanding, and redraws the cards.
    /// `then` runs on the main thread once the cards are published.
    func refresh(polling: Bool = true, then: @escaping () -> Void = {}) {
        let config = self.config()
        let names = sessionNames()
        work.async { [self] in
            self.names = names
            reload()
            let held = heldResults
            heldResults = []
            if !held.isEmpty { taken(held) }
            redeliver()
            // The folder on this Mac is looked at each tick (the watch on it is what shows a result at once; this is
            // for a watch that ended): listing it runs nothing.
            if (try? courier(config)) != nil, polling, !(courier?.outstanding.isEmpty ?? true),
               polledAt.map({ now().timeIntervalSince($0) >= (onThisMac ? Self.localLookEvery : 60) }) ?? true {
                polledAt = now()
                courier?.poll()
            }
            publish(then: then)
        }
    }

    /// Asks Passage for the Wallet Manager's new results now (a test, the sandbox), then redraws.
    func poll(then: @escaping () -> Void = {}) {
        let config = self.config()
        let names = sessionNames()
        work.async { [self] in
            self.names = names
            if (try? courier(config)) != nil { courier?.poll() }
            publish(then: then)
        }
    }

    /// A button on a card: Send to Wallet Manager (only while it waits), Retry (after Passage couldn't reach the Wallet Manager or
    /// stopped unsure), Discard. `then` runs on the main thread once it's done and the cards are redrawn.
    func act(_ action: WalletCardModel.Action, on id: String, then: @escaping () -> Void = {}) {
        // As drawn, shown or over `maxCards` (Send all sends the oldest first, which the cap may not show).
        guard let card = uncut.cards.first(where: { $0.id == id }), let shown = uncut.drawn[id] else { return then() }
        guard card.actions.contains(action) else {
            // Sign in browser wallet on a request the browser wallet can't sign (one marked LOCAL FORK ONLY, a wallet id):
            // its card never offers it, and a press that comes all the same does nothing, and says why.
            if action == .browser, let why = WalletBrowser.whyNot(shown) { log("browser on \(id) not done: \(why)") }
            return then()
        }
        if action == .settings {
            openSettings()
            return then()
        }
        if action == .dismiss {
            // Only the strip forgets it: the request's files stay, and nothing more is told.
            return work.async { [self] in
                dismiss(id)
                publish(then: then)
            }
        }
        let config = self.config()
        let names = sessionNames()
        work.async { [self] in
            self.names = names
            // The request as recorded once sent, or as opened in the browser wallet, else as filed; only if it's still the
            // one the card showed, and a copy on disk may still speak for it.
            guard let filed = requests.first(where: { $0.id == id }), let request = spoken(for: filed, record: record(id)), request == shown else {
                log("\(action.rawValue) on \(id) not done: the request changed since its card was drawn")
                return publish(then: then)
            }
            switch action {
            case .send, .retry:
                // Never both ways: a request that went to the browser wallet doesn't go to the Wallet Manager.
                guard marks[id] == nil, pages[id] == nil else {
                    log("\(action.rawValue) on \(id) not done: it went to the browser wallet")
                    return publish(then: then)
                }
                send(request, config: config)
            case .browser: browse(request)
            case .discard: discard(request)
            case .settings, .dismiss: break
            }
            publish(then: then)
        }
    }

    /// Stops `passage listen` (the app quitting), and the watch. Doesn't wait for a send or a poll under way.
    func close() {
        watch?.cancel()
        timer?.cancel()
        work.async { [self] in
            for page in pages.values { page.server.stop() }
            pages = [:]
        }
        liveLock.lock()
        let running = live
        liveLock.unlock()
        running?.close()
    }

    /// The courier made last, for `close` from the main thread while `work` may be busy with a send.
    private let liveLock = NSLock()
    private var live: WalletCourier?

    /// Whether a courier listens for results now: `passage listen` runs, or the folder on this Mac is watched (a
    /// test's look). Waits for `work`.
    var isListening: Bool { work.sync { courier?.isListening ?? false } }

    /// The least time between two looks at the folder on this Mac that a refresh asks for.
    static let localLookEvery: TimeInterval = 10

    private var watch: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    /// The last time a refresh asked Passage for results (the listener's lines ask at once).
    private var polledAt: Date?

    /// Shows filed requests as they're filed (a watch on `folder`), and every `interval` looks again: expiry, Settings ›
    /// Wallet's changes, and the Wallet Manager's results while one is outstanding (Passage asked at most once a minute this way).
    func start(interval: TimeInterval = 15) {
        guard watch == nil else { return }
        // At launch, before any courier: the `passage listen` a crash left is ended, and records long past their
        // results window go.
        work.async { [self] in
            WalletCourier.ListenRecord.endOrphan(in: store.folder, log: log)
            store.prune(now: now(), log: log)
        }
        try? VibePaths.ensurePrivate(folder)
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.refresh(polling: false) }
            source.setCancelHandler { Darwin.close(descriptor) }
            source.resume()
            watch = source
        }
        let ticks = DispatchSource.makeTimerSource(queue: .main)
        ticks.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
        ticks.setEventHandler { [weak self] in self?.refresh() }
        ticks.resume()
        timer = ticks
        refresh()
    }

    // MARK: On `work`

    private func reload() {
        let (all, stamps, refused) = WalletAsk.filed(in: folder)
        for (file, why) in refused {
            log("refused filed request \(file.lastPathComponent): \(why)")
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: WalletAsk.stampFile(file.deletingPathExtension().lastPathComponent, in: folder))
        }
        let time = now()
        // A createdAt more than 5 minutes ahead of this Mac's clock: refused, as one that doesn't parse. One over 7 days
        // ago gets no card (below); its expiry is still told, and it goes with its results window.
        let timely = all.filter { request in
            guard request.createdAt.timeIntervalSince(time) > WalletRequest.maxAheadOfClock, let why = request.implausibleTime(now: time) else { return true }
            log("refused filed request \(request.id).json: \(why)")
            WalletAsk.remove(request.id, in: folder)
            return false
        }
        let filed = confirmed(timely, stamps)
        for request in filed where marks[request.id] == nil {
            marks[request.id] = WalletBrowser.mark(request.id, in: folder)
        }
        // A page past its time, or one an earlier run opened (its page stopped with it): no answer came back. Told from
        // the copy the page was made from, also when the filed request is gone since (its mark then goes too).
        for (id, mark) in marks.sorted(by: { $0.key < $1.key }) where mark.state == .opened && pages[id].map({ time >= $0.until }) ?? true {
            // A mark read from disk is told from only if it may speak for its request; a page of this run's copy is in memory.
            if pages[id] == nil, let copy = mark.request,
               !believed(vouched(copy, seal: mark.seal, .browserMark, id: id, filed: filed.first { $0.id == id }), id, "browser mark") {
                continue
            }
            let page = pages.removeValue(forKey: id)
            page?.server.stop()
            log("\(id): no answer from the browser wallet")
            let isFiled = filed.contains { $0.id == id }
            if let request = mark.request ?? filed.first(where: { $0.id == id }) {
                // Kept as opened on disk until the agent heard it (`delivered`): a restart before then tells it again.
                settle(request, WalletBrowser.Mark(state: .noAnswer, at: time), recordNow: false)
            }
            // Its files go; a page of this run keeps the copy in memory, so an answer it took in this same instant is
            // still told (`heard`).
            if !isFiled {
                if page == nil { forgetMark(id) } else { WalletAsk.remove(id, in: folder) }
            }
        }
        // Expired with nothing sent (no record of a send, nor a send under way, nor the browser wallet): the asking agent
        // hears it, once. Before the card goes below, so an app that wasn't running at the time still tells it.
        for request in filed where request.isExpired(now: time) && local[request.id] != .sent && marks[request.id] == nil
            && !WalletAsk.toldExpired(request.id, in: folder)
            && courier?.record(request.id) == nil && !FileManager.default.fileExists(atPath: store.file(request.id).path) {
            // Marked told once it reached the agent (`delivered`); noticed again before then, it's the one queued.
            tell(request, WalletAsk.expiredUnsent(request), key: "expired", marker: .toldExpired)
        }
        // Past the time any answer can come: its card goes (the record of what was sent stays in the store).
        for request in filed where time >= request.expiresAt.addingTimeInterval(WalletCourier.resultGrace) {
            pages.removeValue(forKey: request.id)?.server.stop()
            WalletAsk.remove(request.id, in: folder)
            local[request.id] = nil
            marks[request.id] = nil
            sentSince[request.id] = nil
            refusedCopies.remove(request.id)
            for kind in [WalletRequest.CopyKind.record, .browserMark] { checkedCopies["\(kind.rawValue)/\(request.id)"] = nil }
        }
        requests = filed.filter { time < $0.expiresAt.addingTimeInterval(WalletCourier.resultGrace) && $0.implausibleTime(now: time) == nil }
    }

    /// The requests of `filed` whose stamp the session host confirms (asked only about the ones not confirmed yet). One
    /// it says no to is removed; while it can't be asked, the unconfirmed ones wait for the next look.
    private func confirmed(_ filed: [WalletRequest], _ stamps: [String: WalletStamp]) -> [WalletRequest] {
        stamped = stamped.filter { stamps[$0.key] == $0.value }
        let unconfirmed = filed.filter { stamped[$0.id] == nil }
        if !unconfirmed.isEmpty {
            let asked = unconfirmed.compactMap { stamps[$0.id] }
            do {
                let valid = try verifyStamps(asked)
                guard valid.count == asked.count else { throw WalletAsk.Refusal("it answered for \(valid.count) of \(asked.count)") }
                stampsUnasked = false
                for (request, ok) in zip(unconfirmed, valid) {
                    if ok {
                        stamped[request.id] = stamps[request.id]
                    } else {
                        log("refused filed request \(request.id).json: the session host didn't stamp it for the session it names")
                        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(request.id).json"))
                        try? FileManager.default.removeItem(at: WalletAsk.stampFile(request.id, in: folder))
                    }
                }
            } catch {
                if !stampsUnasked { log("couldn't ask the session host whether it stamped \(asked.count) filed request(s) (\(error)): no card until it answers") }
                stampsUnasked = true
            }
        } else {
            stampsUnasked = false
        }
        return filed.filter { stamped[$0.id] != nil }
    }

    /// The courier for Settings › Wallet as it is now: made, or made again when the settings changed. Throws why there
    /// is none (no peer chosen, no passage), and notes what's missing for the cards (`setupNeeded`).
    @discardableResult
    private func courier(_ config: Config) throws -> WalletCourier {
        onThisMac = config.peer == WalletAsk.WalletManager.onThisMac
        // The Wallet Manager on this Mac: the folder pair, and no Passage looked for or run.
        if onThisMac {
            setupNeeded = nil
            if let courier, courierFor?.passage == nil, courierFor?.peer == config.peer { return courier }
            return adopt(localLink, for: (nil, config.peer))
        }
        // No longer chosen, whatever is in its place (none, a peer, a peer with no Passage to run): its courier and
        // its watch on the folder go now, so nothing reads from-wm from here on.
        retireLocal()
        guard !config.peer.isEmpty else {
            setupNeeded = WalletCardModel.noPeerNote
            throw WalletAsk.Refusal("no Wallet Manager peer is chosen in Settings › Wallet")
        }
        // Only spaces is no path, as Settings reads it.
        let unset = config.passage.trimmingCharacters(in: .whitespaces).isEmpty
        if unset, foundPassage == nil { foundPassage = findPassage() }
        // A path set runs only when it names an existing executable or Passage.app: never a missing or half-typed one.
        let passage = unset ? foundPassage : PassageCommand.runnable(config.passage)
        guard let passage else {
            let absolute = config.passage.trimmingCharacters(in: .whitespaces).hasPrefix("/")
            setupNeeded = unset ? WalletCardModel.noPassageNote : absolute ? WalletCardModel.passageNotRunnableNote : WalletCardModel.passageNotAbsoluteNote
            throw WalletAsk.Refusal(unset
                ? "Passage isn't found (no passage on the PATH, no Passage.app in /Applications or ~/Applications): set its path in Settings › Wallet"
                : absolute ? "nothing at the passage path in Settings › Wallet can run" : "the passage path in Settings › Wallet isn't absolute")
        }
        setupNeeded = nil
        if let courier, courierFor?.passage == passage, courierFor?.peer == config.peer { return courier }
        guard let link = PassageLink(command: passage, walletPeer: config.peer, inboxFolder: inbox) else {
            throw WalletAsk.Refusal("the Wallet Manager peer \(config.peer) isn't a Passage peer ID")
        }
        return adopt(link, for: (passage, config.peer))
    }

    /// Drops the courier of the Wallet Manager on this Mac, if that is the one there is: its watch on the folder is
    /// stopped here, on `work` (a cancel: nothing to wait for), and it looks for no more results. Its records stay in
    /// the store; the cards read them from there (`storedRecord`) until a courier is made again.
    private func retireLocal() {
        guard let local = courier, let made = courierFor, made.passage == nil, made.peer == WalletAsk.WalletManager.onThisMac else { return }
        // What a look under way still takes is told as ever (`taken`); none starts after this.
        local.retire()
        courier = nil
        courierFor = nil
        liveLock.lock()
        live = nil
        liveLock.unlock()
        log("the Wallet Manager on this Mac is no longer chosen in Settings › Wallet: its folder is no longer watched or read")
    }

    /// A courier over `link`, in place of the one there was.
    private func adopt(_ link: any WalletTransport, for made: (passage: PassageCommand?, peer: String)) -> WalletCourier {
        // The one it replaces stops its `passage listen` on a thread of its own: that may take seconds, and `work`
        // carries on meanwhile.
        // What it still takes meanwhile isn't told again: only the new one's results reach the cards and the agents.
        if let replaced = courier {
            replaced.onTaken(nil)
            DispatchQueue.global(qos: .utility).async { replaced.close() }
        }
        let fresh = WalletCourier(link: link, store: store, log: log, now: now)
        fresh.onTaken { [weak self] results in self?.work.async { self?.taken(results) } }
        courier = fresh
        courierFor = made
        liveLock.lock()
        live = fresh
        liveLock.unlock()
        return fresh
    }

    private func send(_ request: WalletRequest, config: Config) {
        let id = request.id
        let courier: WalletCourier
        // A record that stayed (an earlier send was unsure) decides the card: a Retry that can't go leaves it as it is,
        // so the Wallet Manager's answers to the earlier send still show.
        let recorded = record(id) != nil
        do {
            courier = try self.courier(config)
        } catch {
            if recorded { return log("retry on \(id) not done: \(error)") }
            local[id] = .unreachable(message: "\(error)")
            return
        }
        guard !request.isExpired(now: now()) else {
            if recorded { return log("retry on \(id) not done: it expired") }
            local[id] = .expired
            return
        }
        // Shown as sent while Passage runs.
        local[id] = .sent
        unsureWhy[id] = nil
        publish()
        // Sealed if the host can be asked: a record with no seal still works while it equals the filed request.
        let outcome = courier.send(request, seal: try? sealMessage(request.sealedCopy(.record)))
        log("sent \(id) from its card: \(outcome)")
        local[id] = nil
        // What Passage said, and the card's state when no record stayed (it didn't go).
        let said: String?
        let notGone: WalletCardModel.State
        func text(_ said: String) -> String? { said.isEmpty ? nil : said }
        switch outcome {
        case .refused(let why): (said, notGone) = (why, .notSent(reason: why))
        case .passage(.sent):
            (said, notGone) = (nil, .sent)
            sentSince[id] = sentSince[id] ?? now()
        case .passage(.failed(let what)), .passage(.unexpected(let what)): (said, notGone) = (text(what), .unreachable(message: text(what)))
        case .passage(.noSuchPeer(let what)), .passage(.peerNotListening(let what)): (said, notGone) = (text(what), .unreachable(message: text(what)))
        case .passage(.usage(let what)):
            (said, notGone) = (text(what), .notSent(reason: "passage didn't take the command" + (what.isEmpty ? "" : " (\(what))")))
        case .passage(.refusedAsSecret(let what)):
            (said, notGone) = (text(what), .notSent(reason: "Passage refused it as looking like a secret" + (what.isEmpty ? "" : " (\(what))")))
        case .passage(.notSent(let what)): (said, notGone) = (text(what), .notSent(reason: what))
        }
        // A record that stayed (sent, or unsure: this send or an earlier one may have reached the Wallet Manager) decides the card.
        if courier.record(id) != nil { unsureWhy[id] = said } else { local[id] = notGone }
    }

    /// Sign in browser wallet: only while it never reached the Wallet Manager (no record of a send, none under way) and
    /// never went this way before. The mark is written before the browser opens; the page is served until its answer,
    /// `WalletBrowser.pageLifetime` or the request's expiry, whichever comes first.
    private func browse(_ request: WalletRequest) {
        let id = request.id
        let time = now()
        guard marks[id] == nil, pages[id] == nil, WalletBrowser.mark(id, in: folder) == nil else {
            return log("browser on \(id) not done: it went to the browser wallet already")
        }
        guard courier?.record(id) == nil, !FileManager.default.fileExists(atPath: store.file(id).path), local[id] != .sent else {
            return log("browser on \(id) not done: it went to the Wallet Manager")
        }
        guard !request.isExpired(now: time) else {
            local[id] = .expired
            return
        }
        guard let name = names[request.requestedBy.session.lowercased()] else {
            return log("browser on \(id) not done: its session isn't one the session host runs")
        }
        guard let page = WalletSignPage.html(for: request, requestedBy: name) else {
            return log("browser on \(id) not done: \(WalletBrowser.whyNot(request) ?? "no page could be made for it")")
        }
        let server = WalletSignServer(page: page)
        let url: URL
        // Sealed if the host can be asked: a mark with no seal still works while it equals the filed request.
        let seal = try? sealMessage(request.sealedCopy(.browserMark))
        do {
            url = try server.start { [weak self] outcome in self?.work.async { self?.heard(outcome, for: id) } }
            try WalletBrowser.setMark(.init(state: .opened, at: time, request: request, seal: seal), for: id, in: folder)
        } catch {
            server.stop()
            return log("browser on \(id) not done: \(error)")
        }
        marks[id] = WalletBrowser.Mark(state: .opened, at: time, request: request, seal: seal)
        pages[id] = (server, min(time.addingTimeInterval(WalletBrowser.pageLifetime), request.expiresAt))
        local[id] = nil
        unsureWhy[id] = nil
        log("opened \(id) in the browser wallet")
        DispatchQueue.main.async { [weak self] in self?.openBrowser(url) }
    }

    /// What the page posted back: the card shows it and the asking session hears it, drawn from the copy the page was
    /// made from. Taken also when it came in the same instant as the page's cutoff (the mark already says no answer: the
    /// page was told it was taken), and when the filed request is gone since (the session hears it, then the mark goes).
    private func heard(_ outcome: WalletBrowser.Outcome, for id: String) {
        pages.removeValue(forKey: id)?.server.stop()
        guard let mark = marks[id], mark.state == .opened || mark.state == .noAnswer,
              let request = mark.request ?? requests.first(where: { $0.id == id }) else {
            return log("\(id) from the browser wallet, with no open page for it: \(outcome)")
        }
        let time = now()
        switch outcome {
        case .sent(let hash): settle(request, WalletBrowser.Mark(state: .sent, txHash: hash, at: time))
        case .rejected: settle(request, WalletBrowser.Mark(state: .rejected, at: time))
        }
        log("\(id) from the browser wallet: \(outcome)")
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(id).json").path) {
            log("\(id): its filed request is gone; its browser mark goes too")
            forgetMark(id)
        }
        publish()
    }

    /// A mark whose filed request is gone: nothing shows it any more.
    private func forgetMark(_ id: String) {
        marks[id] = nil
        WalletAsk.remove(id, in: folder)
        requests.removeAll { $0.id == id }
    }

    /// How it ended in the browser: recorded, and told to the asking session.
    /// `request`: what the page was made from (the mark's copy), never a version filed since. `recordNow` false (no
    /// answer came back): the mark on disk is written once the agent heard it.
    private func settle(_ request: WalletRequest, _ mark: WalletBrowser.Mark, recordNow: Bool = true) {
        var mark = mark
        mark.request = mark.request ?? marks[request.id]?.request
        mark.seal = mark.seal ?? marks[request.id]?.seal
        marks[request.id] = mark
        if recordNow {
            do { try WalletBrowser.setMark(mark, for: request.id, in: folder) } catch { log("couldn't record \(request.id)'s browser answer: \(error)") }
        }
        var text = WalletBrowser.message(mark, request: request, summary: WalletCardModel.summary(request))
        if let filed = requests.first(where: { $0.id == request.id }), filed != request {
            text += " Its filed request was changed after the user opened it in the browser wallet: the above is what the browser wallet was given."
        }
        tell(request, text, key: "browser-\(mark.state.rawValue)", marker: recordNow ? nil : .noAnswer)
    }

    private func discard(_ request: WalletRequest) {
        pages.removeValue(forKey: request.id)?.server.stop()
        let browser = marks.removeValue(forKey: request.id)
        var wasSent = courier?.forget(request.id) ?? false
        // A record of an earlier run, with no courier now (no peer chosen): forgotten all the same, so a courier made
        // later doesn't listen for it.
        if !wasSent, FileManager.default.fileExists(atPath: store.file(request.id).path) {
            store.remove(request.id)
            wasSent = true
        }
        WalletAsk.remove(request.id, in: folder)
        requests.removeAll { $0.id == request.id }
        local[request.id] = nil
        unsureWhy[request.id] = nil
        sentSince[request.id] = nil
        let text = "Wallet request \(request.id) was discarded by the user. "
            + (browser?.state == .rejected ? "It was rejected in their browser wallet; nothing was sent."
               : browser != nil ? "It had been opened in their browser wallet and no answer came back: it may or may not have been sent from there."
               : wasSent ? "VibeSwitcher stopped waiting for its answer; it may have reached the Wallet Manager, which may still act on it."
               : "It was not sent to the Wallet Manager.")
        tell(request, text, key: "discarded")
    }

    /// New results the courier took: each goes to the asking session as a message.
    private func taken(_ results: [WalletResult]) {
        for result in results {
            // The record and its results decide the card now.
            local[result.id] = nil
            let filed = requests.first { $0.id == result.id }
            // A record that may not speak for its request says nothing to any session; one the host can't say about
            // yet waits for it (the courier won't hand this result over again).
            if let record = courier?.record(result.id) {
                switch vouched(record.request, seal: record.seal, .record, id: result.id, filed: filed) {
                case .yes: break
                case .no:
                    refuseCopy(result.id, "record")
                    continue
                case .unasked:
                    heldResults.append(result)
                    continue
                }
            }
            guard let request = courier?.record(result.id)?.request ?? filed else { continue }
            tell(request, WalletCardModel.message(for: result, request: request), key: "result-\(result.sequence)")
        }
        publish()
    }

    /// Tells the asking session: kept in the outbox first, sealed by the session host (a message with this `key` told
    /// already is the one that goes), then handed over. `marker` is recorded once it reached the agent.
    private func tell(_ request: WalletRequest, _ text: String, key: String, marker: WalletOutbox.Marker? = nil) {
        // What's on disk is checked first: an entry planted under this key mustn't stand in for this message.
        verifyRead()
        var entries = queued(request.id)
        guard !entries.contains(where: { $0.key == key && isTrusted($0, of: request.id) }) else { return }
        entries.removeAll { $0.key == key }
        var entry = WalletOutbox.Entry(key: key, session: request.requestedBy.session.lowercased(), text: text,
                                       until: request.expiresAt.addingTimeInterval(WalletCourier.resultGrace), marker: marker)
        // Sealed now if the host can be asked (before its welcome it can't: sealed at a later look, from memory).
        entry.seal = try? sealMessage(entry.sealed(for: request.id))
        trusted.insert("\(request.id)|\(key)")
        entries.append(entry)
        keep(entries, for: request.id)
        // The request's older messages still kept go first, in order (`hand` skips one already on its way): a result
        // taken just after the host's welcome doesn't overtake one held from before it.
        for queued in entries { hand(queued, of: request.id) }
    }

    /// A request's messages in the outbox (read from disk the first time).
    private func queued(_ id: String) -> [WalletOutbox.Entry] {
        if undelivered == nil { undelivered = outbox.load(log: log) }
        return undelivered?[id] ?? []
    }

    private func isTrusted(_ entry: WalletOutbox.Entry, of id: String) -> Bool { trusted.contains("\(id)|\(entry.key)") }

    private func keep(_ entries: [WalletOutbox.Entry], for id: String) {
        undelivered?[id] = entries.isEmpty ? nil : entries
        do { try outbox.save(entries, for: id) } catch { log("couldn't keep \(id)'s undelivered messages on disk: \(error)") }
    }

    /// The outbox entries read from disk that aren't trusted yet: the host is asked about their seals. One it confirms
    /// may go; one with no seal, or a seal it says no to (planted, or changed since it was sealed), is removed and
    /// logged. While it can't be asked, they stay as they are, and none goes.
    private func verifyRead() {
        _ = queued("")
        let unchecked = (undelivered ?? [:]).sorted { $0.key < $1.key }.flatMap { id, entries in
            entries.filter { !isTrusted($0, of: id) }.map { (id: id, entry: $0) }
        }
        guard !unchecked.isEmpty else { return }
        // All of them, unsealed ones too (the host says no to those): while it can't be asked, nothing is removed.
        let valid: [Bool]
        do {
            valid = try verifyMessages(unchecked.map { item in
                var message = item.entry.sealed(for: item.id)
                message.seal = item.entry.seal
                return message
            })
            guard valid.count == unchecked.count else { throw WalletAsk.Refusal("it answered for \(valid.count) of \(unchecked.count)") }
        } catch {
            if !outboxUnasked { log("couldn't ask the session host about \(unchecked.count) undelivered message(s) on disk (\(error)): none goes until it answers") }
            outboxUnasked = true
            return
        }
        outboxUnasked = false
        var refused: [String: Set<String>] = [:]
        for (item, ok) in zip(unchecked, valid) {
            if ok { trusted.insert("\(item.id)|\(item.entry.key)") } else { refused[item.id, default: []].insert(item.entry.key) }
        }
        for (id, keys) in refused.sorted(by: { $0.key < $1.key }) {
            log("removed \(id)'s undelivered message(s) \(keys.sorted().joined(separator: ", ")) from disk: not sealed by the session host")
            keep(queued(id).filter { !keys.contains($0.key) || isTrusted($0, of: id) }, for: id)
        }
    }

    /// The entries told in this run that the host couldn't seal then (before its welcome): sealed now, from memory.
    private func sealTold() {
        for (id, entries) in (undelivered ?? [:]).sorted(by: { $0.key < $1.key }) where entries.contains(where: { $0.seal == nil }) {
            var sealed = entries
            for index in sealed.indices where sealed[index].seal == nil && isTrusted(sealed[index], of: id) {
                guard let seal = try? sealMessage(sealed[index].sealed(for: id)) else { return }
                sealed[index].seal = seal
            }
            if sealed != entries { keep(sealed, for: id) }
        }
    }

    private func hand(_ entry: WalletOutbox.Entry, of id: String) {
        guard isTrusted(entry, of: id), handing.insert("\(id)|\(entry.key)").inserted else { return }
        let (session, text) = (entry.session, entry.text)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliver(session, text) { [weak self] outcome in self?.work.async { self?.handed(entry.key, of: id, outcome) } }
        }
    }

    /// What became of a message handed over: gone from the outbox once it reached the agent (and its marker recorded
    /// then), else kept for the next look, noting whether its session ended (its card says so).
    private func handed(_ key: String, of id: String, _ outcome: SessionDelivery) {
        handing.remove("\(id)|\(key)")
        var entries = queued(id)
        guard let index = entries.firstIndex(where: { $0.key == key }), isTrusted(entries[index], of: id) else { return }
        let entry = entries[index]
        switch outcome {
        case .delivered:
            entries.remove(at: index)
            trusted.remove("\(id)|\(key)")
            keep(entries, for: id)
            log("told \(id)'s session (\(key))")
            if let marker = entry.marker { record(marker, for: id) }
        case .notYet, .ended:
            let ended = outcome == .ended
            if !entry.tried || entry.ended != ended {
                if !entry.tried || ended { log("\(id)'s message (\(key)) not delivered: " + (ended ? "its session ended" : "its session isn't live; kept for later")) }
                entries[index].tried = true
                entries[index].ended = ended
                keep(entries, for: id)
                publish()
            }
        }
    }

    /// Records that the agent heard what `marker` stands for, where the request still has its files (a request gone
    /// since, past its window or discarded, gets none back).
    private func record(_ marker: WalletOutbox.Marker, for id: String) {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(id).json").path) else { return }
        switch marker {
        case .toldExpired:
            if !WalletAsk.markToldExpired(id, in: folder) { log("couldn't record that \(id)'s expiry was told") }
        case .noAnswer:
            // Only over the opened mark it stands in for: an answer recorded since stays.
            guard let disk = WalletBrowser.mark(id, in: folder), disk.state == .opened else { return }
            var mark = marks[id]?.state == .noAnswer ? marks[id]! : WalletBrowser.Mark(state: .noAnswer, at: now())
            mark.request = mark.request ?? disk.request
            mark.seal = mark.seal ?? disk.seal
            do { try WalletBrowser.setMark(mark, for: id, in: folder) } catch { log("couldn't record \(id)'s browser answer: \(error)") }
        }
    }

    /// Each look: the outbox's messages are handed over again (oldest first), but those whose session ended for good
    /// (their last try said so) past their request's results window, which are dropped. One that couldn't go yet (no
    /// welcome from the host, not live) stays until it goes or its session is found ended, past its window too: an
    /// expiry told an hour late, before the welcome, still reaches the agent.
    private func redeliver() {
        verifyRead()
        sealTold()
        let time = now()
        for (id, entries) in (undelivered ?? [:]).sorted(by: { $0.key < $1.key }) {
            // Only a trusted entry is dropped this way: one the host hasn't confirmed yet waits for it (removed if it says no).
            let kept = entries.filter { !$0.ended || time < $0.until || handing.contains("\(id)|\($0.key)") || !isTrusted($0, of: id) }
            for gone in entries where !kept.contains(gone) {
                trusted.remove("\(id)|\(gone.key)")
                log("dropped \(id)'s undelivered message (\(gone.key)): its results window is over" + (gone.ended ? ", its session ended" : ""))
            }
            if kept != entries { keep(kept, for: id) }
            for entry in kept { hand(entry, of: id) }
        }
    }

    /// `dismissedAt` from `dismissedFile`, once: only request ids, and only those dismissed within `dismissedKept`.
    private func loadDismissed() -> [String: Date] {
        if let dismissedAt { return dismissedAt }
        var loaded: [String: Date] = [:]
        if let data = try? Data(contentsOf: dismissedFile), data.count <= Self.maxDismissedBytes,
           let read = try? JSONDecoder().decode([String: Date].self, from: data) {
            let time = now()
            loaded = read.filter { WalletRequestFormat.isID($0.key) && time.timeIntervalSince($0.value) < Self.dismissedKept }
        }
        dismissedAt = loaded
        return loaded
    }

    static let maxDismissedBytes = 1 << 20

    private func dismiss(_ id: String) {
        var all = loadDismissed()
        all[id] = now()
        dismissedAt = all
        do {
            try VibePaths.ensurePrivate(store.folder)
            try VibePaths.writePrivate(JSONEncoder().encode(all), to: dismissedFile)
        } catch {
            log("dismissed \(id), not kept for the next launch: \(error)")
        }
    }

    private func publish(then: @escaping () -> Void = {}) {
        let time = now()
        let dismissed = Set(loadDismissed().keys)
        var cards: [WalletCardModel] = []
        var sessions: [String: String] = [:]
        var drawn: [String: WalletRequest] = [:]
        for filed in requests {
            // Once sent, the card shows what was sent, whatever the file says now.
            // Opened in the browser wallet, the card shows the copy the page was made from.
            let record = self.record(filed.id)
            let mark = marks[filed.id]
            guard let request = spoken(for: filed, record: record) else { continue }
            let by = request.requestedBy
            // Named as the host runs it, or no card at all.
            guard let name = names[by.session.lowercased()] else {
                if unknownSession.insert(request.id).inserted {
                    log("\(request.id): no card, its session \(by.session) isn't one the session host runs")
                }
                continue
            }
            unknownSession.remove(request.id)
            drawn[request.id] = request
            if let mark {
                var card = WalletCardModel(request: request, requestedBy: name, label: by.label, state: WalletCardModel.state(mark, chainId: request.chainId))
                card.fileChanged = request != filed
                cards.append(card)
            } else if let record, local[request.id] != .sent {
                // A stored record (and its results) decides the card over any state of this run, but for a send under way.
                let (state, checks, wallet) = WalletCardModel.state(of: record, unsure: unsureWhy[request.id], now: time)
                var card = WalletCardModel(request: request, requestedBy: name, label: by.label, state: state, checks: checks, wallet: wallet)
                // Delivered, and not a word from the Wallet Manager since: after 5 minutes the card asks if it's running,
                // counted from the send the record keeps (so a restart doesn't start it again).
                if state == .sent, record.state == .sent {
                    let since = record.sentAt ?? sentSince[request.id] ?? time
                    sentSince[request.id] = since
                    card.notPickedUp = time.timeIntervalSince(since) >= WalletCardModel.notPickedUpAfter
                }
                cards.append(card)
            } else if let state = local[request.id] {
                cards.append(WalletCardModel(request: request, requestedBy: name, label: by.label, state: state))
            } else {
                cards.append(WalletCardModel(request: request, requestedBy: name, label: by.label, state: request.isExpired(now: time) ? .expired : .waiting))
            }
            cards[cards.count - 1].setupNeeded = setupNeeded
            cards[cards.count - 1].onThisMac = onThisMac
            cards[cards.count - 1].agentMissed = undelivered?[request.id]?.contains { $0.ended && isTrusted($0, of: request.id) } ?? false
            sessions[request.id] = by.session.lowercased()
        }
        // At most `maxCards`: past that the oldest finished ones give way first, then the oldest. Their files stay; a
        // card shows again once others go.
        let uncut = Uncut(cards: cards, sessions: sessions, drawn: drawn)
        let shown = Self.capped(cards, hidden: Set(cards.filter { !Self.shows($0, dismissed: dismissed) }.map(\.id)))
        if shown.count < cards.count {
            let hidden = Set(cards.map(\.id)).subtracting(shown.map(\.id))
            if !hidden.isSubset(of: overCap) { log("\(hidden.count) card(s) not shown: over \(Self.maxCards)") }
            overCap = hidden
            cards = shown
            sessions = sessions.filter { !hidden.contains($0.key) }
            drawn = drawn.filter { !hidden.contains($0.key) }
        } else {
            overCap = []
        }
        DispatchQueue.main.async { [weak self] in
            if self?.cards != cards { self?.cards = cards }
            if self?.sessions != sessions { self?.sessions = sessions }
            if self?.dismissed != dismissed { self?.dismissed = dismissed }
            self?.drawn = drawn
            if self?.uncut != uncut { self?.uncut = uncut }
            then()
        }
    }

    /// The most cards shown at once, across sessions.
    static let maxCards = 30

    /// `cards` (oldest first) cut to `limit`: the oldest of those the strip doesn't show (`hidden`) go first, then the
    /// oldest finished ones, then the oldest still waiting for Send, then the oldest; the order kept. A waiting one
    /// over the cap is still in Send all's count and list (`uncut`), oldest first; one a send stopped at (not
    /// reachable, unsure, not sent) has only its card to say so and to retry from, so it outlasts the waiting ones.
    static func capped(_ cards: [WalletCardModel], limit: Int = maxCards, hidden: Set<String> = []) -> [WalletCardModel] {
        guard cards.count > limit else { return cards }
        var excess = cards.count - limit
        var dropped = Set<String>()
        for card in cards where excess > 0 && hidden.contains(card.id) {
            dropped.insert(card.id)
            excess -= 1
        }
        for card in cards where excess > 0 && !dropped.contains(card.id) && card.state.isFinished {
            dropped.insert(card.id)
            excess -= 1
        }
        for card in cards where excess > 0 && !dropped.contains(card.id) && card.state == .waiting {
            dropped.insert(card.id)
            excess -= 1
        }
        for card in cards where excess > 0 && !dropped.contains(card.id) {
            dropped.insert(card.id)
            excess -= 1
        }
        return cards.filter { !dropped.contains($0.id) }
    }

    /// The request a card for `filed` is drawn from and its buttons act on: the sent or opened copy when it may speak
    /// for `filed` (`vouched`), else nil (no card, no Retry, one line in the log, naming no field of the copy).
    private func spoken(for filed: WalletRequest, record: WalletRequestStore.Record?) -> WalletRequest? {
        if let record, !believed(vouched(record.request, seal: record.seal, .record, id: filed.id, filed: filed), filed.id, "record") {
            return nil
        }
        let mark = marks[filed.id]
        if let copy = mark?.request, !believed(vouched(copy, seal: mark?.seal, .browserMark, id: filed.id, filed: filed), filed.id, "browser mark") {
            return nil
        }
        refusedCopies.remove(filed.id)
        return record?.request ?? mark?.request ?? filed
    }

    /// Whether a record's or browser mark's copy of a request may speak for it. Any process of the user's can write those
    /// files: a copy is believed when it equals the host-stamped filed request, or carries a seal the session host
    /// confirms (`WalletRequest.sealedCopy`, what this app wrote, so a rewrite of the filed file can't hide what was sent),
    /// and only under its own request's id (`id`: the file it was read from). `.unasked` while the host can't say: not
    /// believed yet, not refused either.
    private func vouched(_ copy: WalletRequest, seal: String?, _ kind: WalletRequest.CopyKind, id: String, filed: WalletRequest?) -> Vouch {
        guard copy.id == id else { return .no }
        if copy == filed { return .yes }
        guard let seal else { return filed == nil && stampsUnasked ? .unasked : .no }
        let key = "\(kind.rawValue)/\(copy.id)"
        if let known = checkedCopies[key], known.copy == copy, known.seal == seal { return known.valid ? .yes : .no }
        var message = copy.sealedCopy(kind)
        message.seal = seal
        do {
            let valid = try verifyMessages([message])
            guard valid.count == 1 else { throw WalletAsk.Refusal("it answered for \(valid.count) of 1") }
            copiesUnasked = false
            checkedCopies[key] = (copy, seal, valid[0])
            return valid[0] ? .yes : .no
        } catch {
            if !copiesUnasked { log("couldn't ask the session host about a saved copy's seal (\(error)): no card from it until it answers") }
            copiesUnasked = true
            return .unasked
        }
    }

    /// What `vouched` found: `.no` is refused and logged (`refuseCopy`), and only `.yes` is believed.
    private func believed(_ verdict: Vouch, _ id: String, _ what: String) -> Bool {
        if verdict == .no { refuseCopy(id, what) }
        return verdict == .yes
    }

    private enum Vouch { case yes, no, unasked }

    /// Notes, once per request, that `what` (its record or browser mark) may not speak for it: its id and the kind of
    /// copy only, nothing the copy says.
    private func refuseCopy(_ id: String, _ what: String) {
        guard refusedCopies.insert(id).inserted else { return }
        log("\(id): no card and no Retry: its \(what) isn't the request the session host stamped and has no seal the host confirmed")
    }

    /// The record of a send: the courier's, else one an earlier run stored.
    private func record(_ id: String) -> WalletRequestStore.Record? { courier?.record(id) ?? storedRecord(id) }

    /// A record from an earlier run while no courier is made yet (no peer chosen now).
    private func storedRecord(_ id: String) -> WalletRequestStore.Record? {
        guard courier == nil, FileManager.default.fileExists(atPath: store.file(id).path) else { return nil }
        return store.load().first { $0.request.id == id }
    }
}
