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
/// The fallback, while a request has never reached the Wallet Manager: Sign in browser wallet (`act(.browser)`) serves
/// the request on a local page (`WalletSignServer`) and opens it in the browser, whose wallet extension shows and signs
/// it; what it did comes back to the card and the asking session. A mark beside the filed request (`WalletBrowser.Mark`)
/// records that it went that way, so it can't also be sent to the Wallet Manager, nor the reverse. It needs no Wallet
/// Manager set up: with no peer chosen or no Passage found, cards still show, Send gives way to a line saying what's
/// missing and Open Settings (`openSettings`, Settings › Wallet), and Send comes back once Settings has what it needs.
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

    /// Where Passage is and which peer is the Wallet Manager's Mac: Settings › Wallet (read on the main thread).
    struct Config: Equatable {
        /// The `passage` command: an absolute path (`passage`, Passage.app or its binary), or empty to find it.
        var passage: String
        /// The Wallet Manager peer's ID; empty: none chosen.
        var peer: String
    }

    let folder: URL
    let store: WalletRequestStore
    let inbox: URL
    /// Settings › Wallet, read on the main thread.
    var config: () -> Config
    /// Passage found when no path is set (off the main thread): `passage` on the login shell's PATH, else Passage.app
    /// in /Applications or ~/Applications; nil when there's none.
    var findPassage: () -> PassageCommand? = { PassageCommand.resolve(setting: "", onPath: WalletPeerChoice.findPassage) }
    /// Hands a message to the asking session's agent (its id, lower case), on the main thread.
    var deliver: (_ session: String, _ text: String) -> Void = { _, _ in }
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
    private var courierFor: (passage: PassageCommand, peer: String)?
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

    init(folder: URL = WalletAsk.folder, store: WalletRequestStore = WalletRequestStore(), inbox: URL = PassageLink.defaultInbox,
         config: @escaping () -> Config, now: @escaping @Sendable () -> Date = { Date() },
         log: @escaping @Sendable (String) -> Void = { Breadcrumbs.shared.note("wallet: " + $0) }) {
        self.folder = folder
        self.store = store
        self.inbox = inbox
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
                + "pages \(pages.count) sent-since \(sentSince.count) records \(kept?.records ?? 0) handled \(kept?.handled ?? 0)"
        }
    }
    #endif

    /// The cards of one session's requests.
    func cards(for session: UUID) -> [WalletCardModel] {
        let id = session.uuidString.lowercased()
        return cards.filter { sessions[$0.id] == id }
    }

    /// Reads the filed requests again, takes the Wallet Manager's new results while any is outstanding, and redraws the cards.
    /// `then` runs on the main thread once the cards are published.
    func refresh(polling: Bool = true, then: @escaping () -> Void = {}) {
        let config = self.config()
        let names = sessionNames()
        work.async { [self] in
            self.names = names
            reload()
            if (try? courier(config)) != nil, polling, !(courier?.outstanding.isEmpty ?? true),
               polledAt.map({ now().timeIntervalSince($0) >= 60 }) ?? true {
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
        guard let card = cards.first(where: { $0.id == id }), card.actions.contains(action), let shown = drawn[id] else { return then() }
        if action == .settings {
            openSettings()
            return then()
        }
        let config = self.config()
        let names = sessionNames()
        work.async { [self] in
            self.names = names
            // The request as recorded once sent, or as opened in the browser wallet, else as filed; only if it's still the
            // one the card showed.
            guard let request = record(id)?.request ?? marks[id]?.request ?? requests.first(where: { $0.id == id }),
                  request == shown else {
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
            case .settings: break
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

    private var watch: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    /// The last time a refresh asked Passage for results (the listener's lines ask at once).
    private var polledAt: Date?

    /// Shows filed requests as they're filed (a watch on `folder`), and every `interval` looks again: expiry, Settings ›
    /// Wallet's changes, and the Wallet Manager's results while one is outstanding (Passage asked at most once a minute this way).
    func start(interval: TimeInterval = 15) {
        guard watch == nil else { return }
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
        let filed = confirmed(all, stamps)
        let time = now()
        for request in filed where marks[request.id] == nil {
            marks[request.id] = WalletBrowser.mark(request.id, in: folder)
        }
        // A page past its time, or one an earlier run opened (its page stopped with it): no answer came back. Told from
        // the copy the page was made from, also when the filed request is gone since (its mark then goes too).
        for (id, mark) in marks.sorted(by: { $0.key < $1.key }) where mark.state == .opened && pages[id].map({ time >= $0.until }) ?? true {
            let page = pages.removeValue(forKey: id)
            page?.server.stop()
            log("\(id): no answer from the browser wallet")
            let isFiled = filed.contains { $0.id == id }
            if let request = mark.request ?? filed.first(where: { $0.id == id }) {
                settle(request, WalletBrowser.Mark(state: .noAnswer, at: time))
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
            guard WalletAsk.markToldExpired(request.id, in: folder) else {
                log("couldn't record that \(request.id) expired unsent; its agent hears it at the next look")
                continue
            }
            log("\(request.id) expired unsent: telling its session")
            tell(request, WalletAsk.expiredUnsent(request))
        }
        // Past the time any answer can come: its card goes (the record of what was sent stays in the store).
        for request in filed where time >= request.expiresAt.addingTimeInterval(WalletCourier.resultGrace) {
            pages.removeValue(forKey: request.id)?.server.stop()
            WalletAsk.remove(request.id, in: folder)
            local[request.id] = nil
            marks[request.id] = nil
            sentSince[request.id] = nil
        }
        requests = filed.filter { time < $0.expiresAt.addingTimeInterval(WalletCourier.resultGrace) }
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
        }
        return filed.filter { stamped[$0.id] != nil }
    }

    /// The courier for Settings › Wallet as it is now: made, or made again when the settings changed. Throws why there
    /// is none (no peer chosen, no passage), and notes what's missing for the cards (`setupNeeded`).
    @discardableResult
    private func courier(_ config: Config) throws -> WalletCourier {
        guard !config.peer.isEmpty else {
            setupNeeded = WalletCardModel.noPeerNote
            throw WalletAsk.Refusal("no Wallet Manager peer is chosen in Settings › Wallet")
        }
        // Only spaces is no path, as Settings reads it.
        let unset = config.passage.trimmingCharacters(in: .whitespaces).isEmpty
        if unset, foundPassage == nil { foundPassage = findPassage() }
        let passage = unset ? foundPassage : PassageCommand.forPath(config.passage)
        guard let passage else {
            setupNeeded = unset ? WalletCardModel.noPassageNote : WalletCardModel.passageNotAbsoluteNote
            throw WalletAsk.Refusal(unset
                ? "Passage isn't found (no passage on the PATH, no Passage.app in /Applications or ~/Applications): set its path in Settings › Wallet"
                : "the passage path in Settings › Wallet isn't absolute")
        }
        setupNeeded = nil
        if let courier, courierFor?.passage == passage, courierFor?.peer == config.peer { return courier }
        guard let link = PassageLink(command: passage, walletPeer: config.peer, inboxFolder: inbox) else {
            throw WalletAsk.Refusal("the Wallet Manager peer \(config.peer) isn't a Passage peer ID")
        }
        courier?.close()
        let made = WalletCourier(link: link, store: store, log: log, now: now)
        made.onTaken { [weak self] results in self?.work.async { self?.taken(results) } }
        courier = made
        courierFor = (passage, config.peer)
        liveLock.lock()
        live = made
        liveLock.unlock()
        return made
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
        let outcome = courier.send(request)
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
        guard let page = WalletSignPage.html(for: request, requestedBy: name) else { return log("browser on \(id) not done: its from isn't an 0x address") }
        let server = WalletSignServer(page: page)
        let url: URL
        do {
            url = try server.start { [weak self] outcome in self?.work.async { self?.heard(outcome, for: id) } }
            try WalletBrowser.setMark(.init(state: .opened, at: time, request: request), for: id, in: folder)
        } catch {
            server.stop()
            return log("browser on \(id) not done: \(error)")
        }
        marks[id] = WalletBrowser.Mark(state: .opened, at: time, request: request)
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
    /// `request`: what the page was made from (the mark's copy), never a version filed since.
    private func settle(_ request: WalletRequest, _ mark: WalletBrowser.Mark) {
        var mark = mark
        mark.request = mark.request ?? marks[request.id]?.request
        marks[request.id] = mark
        do { try WalletBrowser.setMark(mark, for: request.id, in: folder) } catch { log("couldn't record \(request.id)'s browser answer: \(error)") }
        var text = WalletBrowser.message(mark, request: request, summary: WalletCardModel.summary(request))
        if let filed = requests.first(where: { $0.id == request.id }), filed != request {
            text += " Its filed request was changed after the user opened it in the browser wallet: the above is what the browser wallet was given."
        }
        tell(request, text)
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
        tell(request, text)
    }

    /// New results the courier took: each goes to the asking session as a message.
    private func taken(_ results: [WalletResult]) {
        for result in results {
            // The record and its results decide the card now.
            local[result.id] = nil
            guard let request = courier?.record(result.id)?.request ?? requests.first(where: { $0.id == result.id }) else { continue }
            tell(request, WalletCardModel.message(for: result, request: request))
        }
        publish()
    }

    private func tell(_ request: WalletRequest, _ text: String) {
        let session = request.requestedBy.session.lowercased()
        DispatchQueue.main.async { [weak self] in self?.deliver(session, text) }
    }

    private func publish(then: @escaping () -> Void = {}) {
        let time = now()
        var cards: [WalletCardModel] = []
        var sessions: [String: String] = [:]
        var drawn: [String: WalletRequest] = [:]
        for filed in requests {
            // Once sent, the card shows what was sent, whatever the file says now.
            // Opened in the browser wallet, the card shows the copy the page was made from.
            let record = self.record(filed.id)
            let mark = marks[filed.id]
            let request = record?.request ?? mark?.request ?? filed
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
            sessions[request.id] = by.session.lowercased()
        }
        DispatchQueue.main.async { [weak self] in
            if self?.cards != cards { self?.cards = cards }
            if self?.sessions != sessions { self?.sessions = sessions }
            self?.drawn = drawn
            then()
        }
    }

    /// The record of a send: the courier's, else one an earlier run stored.
    private func record(_ id: String) -> WalletRequestStore.Record? { courier?.record(id) ?? storedRecord(id) }

    /// A record from an earlier run while no courier is made yet (no peer chosen now).
    private func storedRecord(_ id: String) -> WalletRequestStore.Record? {
        guard courier == nil, FileManager.default.fileExists(atPath: store.file(id).path) else { return nil }
        return store.load().first { $0.request.id == id }
    }
}
