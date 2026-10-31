import Combine
import Foundation
import VibeCore

/// The vault requests agents filed (`VaultAsk`, `vs-vault request`), as cards in the asking session's chat, and their
/// way to the vault Mac and back: nothing goes until the user presses Send to vault on the card (`act(.send)`); Retry
/// sends again after Passage couldn't reach the vault or stopped unsure; Discard drops the request (and forgets it, so
/// its answers are no longer listened for). Each result the vault sends back updates the card and goes to the asking
/// session as a message (`deliver`), as does a request that expires before the user sent it. VibeSwitcher never signs
/// or judges: the card shows what the vault said.
///
/// Its state lives on a queue of its own (`work`), where Passage runs (a send blocks for seconds); `cards` is
/// published on the main thread.
final class VaultDesk: ObservableObject {
    /// Every card, oldest request first.
    @Published private(set) var cards: [VaultCardModel] = []
    /// The asking session's id (lower case) for each card's id.
    @Published private(set) var sessions: [String: String] = [:]
    /// The request each card was drawn from: a button sends only that one (a file rewritten since isn't sent unseen).
    private(set) var drawn: [String: VaultRequest] = [:]

    /// Where Passage is and which peer is the vault Mac: Settings › Vault (read on the main thread).
    struct Config: Equatable {
        /// The `passage` command: an absolute path, or empty for `passage` on the PATH.
        var passage: String
        /// The vault peer's ID; empty: none chosen.
        var peer: String
    }

    let folder: URL
    let store: VaultStore
    let inbox: URL
    /// Settings › Vault, read on the main thread.
    var config: () -> Config
    /// `passage` found on the login shell's PATH (off the main thread): an absolute path, or nil.
    var findPassage: () -> String? = VaultPeerChoice.findPassage
    /// Hands a message to the asking session's agent (its id, lower case), on the main thread.
    var deliver: (_ session: String, _ text: String) -> Void = { _, _ in }
    let now: @Sendable () -> Date
    let log: @Sendable (String) -> Void

    private let work = DispatchQueue(label: "dev.vibeswitcher.vault-desk", qos: .userInitiated)
    // On `work` only:
    private var requests: [VaultRequest] = []
    /// Card states before or instead of a record: being sent, couldn't reach the vault, not sent.
    private var local: [String: VaultCardModel.State] = [:]
    /// What Passage said when it stopped unsure, per request.
    private var unsureWhy: [String: String] = [:]
    private var courier: VaultCourier?
    private var courierFor: (passage: String, peer: String)?
    /// `passage` on the PATH, once found.
    private var foundPassage: String?

    init(folder: URL = VaultAsk.folder, store: VaultStore = VaultStore(), inbox: URL = PassageLink.defaultInbox,
         config: @escaping () -> Config, now: @escaping @Sendable () -> Date = { Date() },
         log: @escaping @Sendable (String) -> Void = { Breadcrumbs.shared.note("vault: " + $0) }) {
        self.folder = folder
        self.store = store
        self.inbox = inbox
        self.config = config
        self.now = now
        self.log = log
    }

    /// The cards of one session's requests.
    func cards(for session: UUID) -> [VaultCardModel] {
        let id = session.uuidString.lowercased()
        return cards.filter { sessions[$0.id] == id }
    }

    /// Reads the filed requests again, takes the vault's new results while any is outstanding, and redraws the cards.
    /// `then` runs on the main thread once the cards are published.
    func refresh(polling: Bool = true, then: @escaping () -> Void = {}) {
        let config = self.config()
        work.async { [self] in
            reload()
            if (try? courier(config)) != nil, polling, !(courier?.outstanding.isEmpty ?? true),
               polledAt.map({ now().timeIntervalSince($0) >= 60 }) ?? true {
                polledAt = now()
                courier?.poll()
            }
            publish(then: then)
        }
    }

    /// Asks Passage for the vault's new results now (a test, the sandbox), then redraws.
    func poll(then: @escaping () -> Void = {}) {
        let config = self.config()
        work.async { [self] in
            if (try? courier(config)) != nil { courier?.poll() }
            publish(then: then)
        }
    }

    /// A button on a card: Send to vault (only while it waits), Retry (after Passage couldn't reach the vault or
    /// stopped unsure), Discard. `then` runs on the main thread once it's done and the cards are redrawn.
    func act(_ action: VaultCardModel.Action, on id: String, then: @escaping () -> Void = {}) {
        guard let card = cards.first(where: { $0.id == id }), card.actions.contains(action), let shown = drawn[id] else { return then() }
        let config = self.config()
        work.async { [self] in
            // The request as recorded once sent, else as filed; only if it's still the one the card showed.
            guard let request = courier?.record(id)?.request ?? storedRecord(id)?.request ?? requests.first(where: { $0.id == id }),
                  request == shown else {
                log("\(action.rawValue) on \(id) not done: the request changed since its card was drawn")
                return publish(then: then)
            }
            switch action {
            case .send, .retry: send(request, config: config)
            case .discard: discard(request)
            }
            publish(then: then)
        }
    }

    /// Stops `passage listen` (the app quitting), and the watch. Doesn't wait for a send or a poll under way.
    func close() {
        watch?.cancel()
        timer?.cancel()
        liveLock.lock()
        let running = live
        liveLock.unlock()
        running?.close()
    }

    /// The courier made last, for `close` from the main thread while `work` may be busy with a send.
    private let liveLock = NSLock()
    private var live: VaultCourier?

    private var watch: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    /// The last time a refresh asked Passage for results (the listener's lines ask at once).
    private var polledAt: Date?

    /// Shows filed requests as they're filed (a watch on `folder`), and every `interval` looks again: expiry, Settings ›
    /// Vault's changes, and the vault's results while one is outstanding (Passage asked at most once a minute this way).
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
        let (filed, refused) = VaultAsk.filed(in: folder)
        for (file, why) in refused {
            log("refused filed request \(file.lastPathComponent): \(why)")
            try? FileManager.default.removeItem(at: file)
        }
        let time = now()
        // Expired with nothing sent (no record of a send, nor a send under way): the asking agent hears it, once. Before
        // the card goes below, so an app that wasn't running at the time still tells it.
        for request in filed where request.isExpired(now: time) && local[request.id] != .sent && !VaultAsk.toldExpired(request.id, in: folder)
            && courier?.record(request.id) == nil && !FileManager.default.fileExists(atPath: store.file(request.id).path) {
            guard VaultAsk.markToldExpired(request.id, in: folder) else {
                log("couldn't record that \(request.id) expired unsent; its agent hears it at the next look")
                continue
            }
            log("\(request.id) expired unsent: telling its session")
            tell(request, VaultAsk.expiredUnsent(request))
        }
        // Past the time any answer can come: its card goes (the record of what was sent stays in the store).
        for request in filed where time >= request.expiresAt.addingTimeInterval(VaultCourier.resultGrace) {
            VaultAsk.remove(request.id, in: folder)
            local[request.id] = nil
        }
        requests = filed.filter { time < $0.expiresAt.addingTimeInterval(VaultCourier.resultGrace) }
    }

    /// The courier for Settings › Vault as it is now: made, or made again when the settings changed. Throws why there
    /// is none (no peer chosen, no passage).
    @discardableResult
    private func courier(_ config: Config) throws -> VaultCourier {
        guard !config.peer.isEmpty else { throw VaultAsk.Refusal("no vault peer is chosen in Settings › Vault") }
        if config.passage.isEmpty, foundPassage == nil { foundPassage = findPassage() }
        let passage = config.passage.isEmpty ? foundPassage : config.passage
        guard let passage, passage.hasPrefix("/") else {
            throw VaultAsk.Refusal(config.passage.isEmpty ? "passage isn't on the PATH: set its path in Settings › Vault" : "the passage path in Settings › Vault isn't absolute")
        }
        if let courier, courierFor?.passage == passage, courierFor?.peer == config.peer { return courier }
        guard let link = PassageLink(executable: passage, vaultPeer: config.peer, inboxFolder: inbox) else {
            throw VaultAsk.Refusal("the vault peer \(config.peer) isn't a Passage peer ID")
        }
        courier?.close()
        let made = VaultCourier(link: link, store: store, log: log, now: now)
        made.onTaken { [weak self] results in self?.work.async { self?.taken(results) } }
        courier = made
        courierFor = (passage, config.peer)
        liveLock.lock()
        live = made
        liveLock.unlock()
        return made
    }

    private func send(_ request: VaultRequest, config: Config) {
        let id = request.id
        let courier: VaultCourier
        do {
            courier = try self.courier(config)
        } catch {
            local[id] = .unreachable(message: "\(error)")
            return
        }
        guard !request.isExpired(now: now()) else {
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
        let notGone: VaultCardModel.State
        func text(_ said: String) -> String? { said.isEmpty ? nil : said }
        switch outcome {
        case .refused(let why): (said, notGone) = (why, .notSent(reason: why))
        case .passage(.sent): (said, notGone) = (nil, .sent)
        case .passage(.failed(let what)), .passage(.unexpected(let what)): (said, notGone) = (text(what), .unreachable(message: text(what)))
        case .passage(.noSuchPeer(let what)), .passage(.peerNotListening(let what)): (said, notGone) = (text(what), .unreachable(message: text(what)))
        case .passage(.usage(let what)):
            (said, notGone) = (text(what), .notSent(reason: "passage didn't take the command" + (what.isEmpty ? "" : " (\(what))")))
        case .passage(.refusedAsSecret(let what)):
            (said, notGone) = (text(what), .notSent(reason: "Passage refused it as looking like a secret" + (what.isEmpty ? "" : " (\(what))")))
        }
        // A record that stayed (sent, or unsure: this send or an earlier one may have reached the vault) decides the card.
        if courier.record(id) != nil { unsureWhy[id] = said } else { local[id] = notGone }
    }

    private func discard(_ request: VaultRequest) {
        var wasSent = courier?.forget(request.id) ?? false
        // A record of an earlier run, with no courier now (no peer chosen): forgotten all the same, so a courier made
        // later doesn't listen for it.
        if !wasSent, FileManager.default.fileExists(atPath: store.file(request.id).path) {
            store.remove(request.id)
            wasSent = true
        }
        VaultAsk.remove(request.id, in: folder)
        requests.removeAll { $0.id == request.id }
        local[request.id] = nil
        unsureWhy[request.id] = nil
        let text = "Vault request \(request.id) was discarded by the user. "
            + (wasSent ? "VibeSwitcher stopped waiting for its answer; it may have reached the vault, which may still act on it."
                       : "It was not sent to the vault.")
        tell(request, text)
    }

    /// New results the courier took: each goes to the asking session as a message.
    private func taken(_ results: [VaultResult]) {
        for result in results {
            guard let request = courier?.record(result.id)?.request ?? requests.first(where: { $0.id == result.id }) else { continue }
            tell(request, VaultCardModel.message(for: result, request: request))
        }
        publish()
    }

    private func tell(_ request: VaultRequest, _ text: String) {
        let session = request.requestedBy.session.lowercased()
        DispatchQueue.main.async { [weak self] in self?.deliver(session, text) }
    }

    private func publish(then: @escaping () -> Void = {}) {
        let time = now()
        var cards: [VaultCardModel] = []
        var sessions: [String: String] = [:]
        var drawn: [String: VaultRequest] = [:]
        for filed in requests {
            // Once sent, the card shows what was sent, whatever the file says now.
            let record = courier?.record(filed.id) ?? storedRecord(filed.id)
            let request = record?.request ?? filed
            drawn[request.id] = request
            let by = request.requestedBy
            let name = by.label.isEmpty ? "an agent in \(by.project)" : by.label
            if let state = local[request.id] {
                cards.append(VaultCardModel(request: request, requestedBy: name, state: state))
            } else if let record {
                let (state, checks, wallet) = VaultCardModel.state(of: record, unsure: unsureWhy[request.id], now: time)
                cards.append(VaultCardModel(request: request, requestedBy: name, state: state, checks: checks, wallet: wallet))
            } else {
                cards.append(VaultCardModel(request: request, requestedBy: name, state: request.isExpired(now: time) ? .expired : .waiting))
            }
            sessions[request.id] = by.session.lowercased()
        }
        DispatchQueue.main.async { [weak self] in
            if self?.cards != cards { self?.cards = cards }
            if self?.sessions != sessions { self?.sessions = sessions }
            self?.drawn = drawn
            then()
        }
    }

    /// A record from an earlier run while no courier is made yet (no peer chosen now).
    private func storedRecord(_ id: String) -> VaultStore.Record? {
        guard courier == nil, FileManager.default.fileExists(atPath: store.file(id).path) else { return nil }
        return store.load().first { $0.request.id == id }
    }
}
