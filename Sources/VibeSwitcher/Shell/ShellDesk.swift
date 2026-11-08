import Combine
import Foundation
import VibeCore

/// The shells agents asked for (`ShellAsk`, `vs-shell run`), as cards in the asking session's chat: who asks, the
/// folder, the exact command, Run and Decline. Nothing starts until the user presses Run (`run`), unless
/// Settings › Agents lets agents open shells without asking (`atOnce`): then a request starts as it's first seen, and its
/// card records that. Run starts an ordinary New Shell session (`launch`, with `ShellAsk.spawnRequest`). A request
/// unanswered for 30 minutes expires. What became of each (started, with the new session's name; declined; expired;
/// couldn't start) goes to the asking session as a message (`deliver`), again at a later look until it reached it or the
/// session is gone.
///
/// Run follows the chat's one Run rule (`RunOutcome`, `RunRefusal`, `RunShown`): it ends in ran, or in a "Not run: …"
/// line that the card shows (`refused`) and its button's tooltip says, never in a bare sound. What it doesn't share is
/// the typing: the command is given to the new session's shell at launch, never typed into any terminal.
///
/// Only a request the session host stamped (`verifyStamps`) for a session it runs (`sessionNames`) gets a card, and
/// only such a request is ever started: what's written into the folder some other way is never shown nor run. What
/// became of a request is written beside it before anything starts, so none starts twice, a restart included.
final class ShellDesk: ObservableObject {
    struct Card: Identifiable, Equatable {
        enum State: Equatable {
            case waiting(until: Date)
            case starting
            case started(name: String, auto: Bool)
            case declined
            case expired
            case failed(String)
        }

        var id: String { request.id }
        let request: ShellRequest
        /// The asking session, as the window names it.
        let asker: String
        let state: State

        var isOpen: Bool { if case .waiting = state { return true } else { return false } }
    }

    enum Action { case run, decline, dismiss }

    @Published private(set) var cards: [Card] = []
    /// Why a card's last Run didn't go, by request id ("Not run: …", `RunRefusal`), shown on the card for a while
    /// (`RunShown.lasts`).
    @Published private(set) var refused: [String: String] = [:]

    let folder: URL
    /// The sessions the host runs, by lower-case id: the window's name for each (main thread).
    var sessionNames: () -> [String: String] = { [:] }
    /// Which of these stamps carry the host's seal (off the main thread).
    var verifyStamps: ([WalletStamp]) throws -> [Bool] = { $0.map { _ in false } }
    /// Tells the asking session what became of its request (main thread).
    var deliver: (_ session: String, _ text: String, _ then: @escaping (SessionDelivery) -> Void) -> Void = { _, _, then in then(.notYet) }
    /// Starts the request's shell session and selects it in the window (main thread); hears its id and name, or why not.
    var launch: (_ request: ShellRequest, _ then: @escaping (Result<(id: UUID, name: String), ShellAsk.Refusal>) -> Void) -> Void = { _, then in
        then(.failure(ShellAsk.Refusal("no session host to start it")))
    }
    /// Settings › Agents › Let agents open shells without asking (main thread).
    var atOnce: () -> Bool = { false }
    let now: () -> Date
    let log: (String) -> Void

    private let work = DispatchQueue(label: "dev.vibeswitcher.shell-desk", qos: .userInitiated)
    /// On `work`: the requests whose stamps the host confirmed (asked once each).
    private var trusted: [String: WalletStamp] = [:]
    /// On main: requests seen this run (one first seen while `atOnce` is on starts then), and messages under way.
    private var seen: Set<String> = []
    private var telling: Set<String> = []
    /// Which Run of its card each `refused` line is for: an earlier one's timer doesn't clear a later one's.
    private var refusals: [String: Int] = [:]
    /// Runs `clear` once a refusal has shown long enough (main thread); tests fire it themselves.
    var later: (_ after: TimeInterval, _ clear: @escaping () -> Void) -> Void = { after, clear in
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: clear)
    }
    private var watch: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?

    /// A request first seen this long after it was filed waits for the click even with `atOnce` on (one filed while
    /// the app was closed isn't started by its opening).
    static let atOnceWithin: TimeInterval = 120
    /// A start that never finished (the app quit in between) is called failed after this long.
    static let startingFor: TimeInterval = 120
    /// Answered, told and this old: its files go.
    static let keptFor: TimeInterval = 7 * 86_400

    init(folder: URL = ShellAsk.folder, now: @escaping () -> Date = { Date() },
         log: @escaping (String) -> Void = { Breadcrumbs.shared.note("shell: " + $0) }) {
        self.folder = folder
        self.now = now
        self.log = log
    }

    func cards(for session: UUID) -> [Card] {
        let id = session.uuidString.lowercased()
        return cards.filter { $0.request.session == id }
    }

    /// Shows filed requests as they're filed (a watch on `folder`), and every `interval` looks again (expiry).
    func start(interval: TimeInterval = 15) {
        guard watch == nil else { return }
        try? VibePaths.ensurePrivate(folder)
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.refresh() }
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

    func close() {
        watch?.cancel()
        timer?.cancel()
    }

    /// Reads the filed requests again (on `work`), expires what's past its time, starts what Settings let start, tells
    /// the asking sessions what's untold, and redraws the cards; `then` on the main thread once drawn.
    func refresh(then: @escaping () -> Void = {}) {
        let names = sessionNames()
        let time = now()
        work.async { [self] in
            let found = load(time)
            DispatchQueue.main.async { [self] in
                draw(found, names: names, time: time)
                then()
            }
        }
    }

    /// A card's Run: starts its shell session once, then answers what came of it (main thread, once the cards are
    /// redrawn): ran, or refused with why not in the chat's Run words (`RunRefusal`), which the card shows (`refused`).
    func run(_ id: String, done: @escaping (RunOutcome) -> Void = { _ in }) {
        let finish: (RunOutcome) -> Void = { [self] outcome in
            let mine = (refusals[id] ?? 0) + 1
            refusals[id] = mine
            if case .refused(let reason) = outcome {
                log("\(id): \(reason)")
                refused[id] = reason
                later(RunShown.refused(reason).lasts) { [weak self] in
                    guard let self, refusals[id] == mine else { return }
                    refused[id] = nil
                    refusals[id] = nil
                }
            } else {
                refused[id] = nil
                refusals[id] = nil
            }
            done(outcome)
        }
        guard let card = cards.first(where: { $0.id == id }) else { return finish(.refused(RunRefusal.shellGone)) }
        guard card.isOpen else { return finish(.refused(RunRefusal.shellAnswered)) }
        start(card.request, auto: false, done: finish)
    }

    /// A button on a card: Run (`run`) or Decline while it waits, Dismiss once answered.
    func act(_ action: Action, on id: String, then: @escaping () -> Void = {}) {
        if action == .run { return run(id) { _ in then() } }
        guard let card = cards.first(where: { $0.id == id }) else { return then() }
        switch action {
        case .run:
            break
        case .decline:
            guard card.isOpen else { return then() }
            log("\(id) declined")
            answer(card.request, ShellAsk.Answer(state: .declined, at: now()), then: then)
        case .dismiss:
            guard !card.isOpen, card.state != .starting else { return then() }
            work.async { [self] in
                ShellAsk.remove(id, in: folder)
                DispatchQueue.main.async { [self] in refresh(then: then) }
            }
        }
    }

    // MARK: Steps

    /// Each stamped request with what became of it (on `work`). Past its time unanswered: expired (written here).
    /// Starting for too long: failed. Answered, told and old: removed.
    private func load(_ time: Date) -> [(ShellRequest, ShellAsk.Answer?)] {
        let (requests, stamps, refused) = ShellAsk.filed(in: folder)
        for (file, why) in refused { log("not shown: \(file.lastPathComponent): \(why)") }
        let unasked = requests.filter { trusted[$0.id] == nil }.compactMap { request in stamps[request.id].map { (request.id, $0) } }
        if !unasked.isEmpty {
            do {
                let valid = try verifyStamps(unasked.map(\.1))
                for ((id, stamp), ok) in zip(unasked, valid) {
                    if ok { trusted[id] = stamp } else { log("not shown: \(id): its stamp isn't the session host's") }
                }
            } catch {
                log("stamps not checked: \(error)")
            }
        }
        var found: [(ShellRequest, ShellAsk.Answer?)] = []
        for request in requests where trusted[request.id] == stamps[request.id] && trusted[request.id] != nil {
            // Dated ahead of this clock (its 30 minutes would run late): not shown, never started.
            guard request.created.timeIntervalSince(time) <= Self.atOnceWithin else {
                log("not shown: \(request.id): filed for \(request.created), ahead of this clock")
                continue
            }
            var answer = ShellAsk.answer(request.id, in: folder)
            if answer == nil, time >= request.expiresAt {
                log("\(request.id) expired unanswered")
                answer = ShellAsk.Answer(state: .expired, at: time)
            } else if let started = answer, started.state == .starting, time.timeIntervalSince1970 - started.at > Self.startingFor {
                answer = ShellAsk.Answer(state: .failed, at: time, auto: started.auto, why: "VibeSwitcher stopped before the shell started; check the window for it")
            }
            if let answer, answer != ShellAsk.answer(request.id, in: folder) {
                do { try ShellAsk.record(answer, for: request.id, in: folder) } catch { log("couldn't record \(request.id): \(error)") }
            }
            if let answer, answer.told, time.timeIntervalSince1970 - answer.at > Self.keptFor {
                ShellAsk.remove(request.id, in: folder)
                continue
            }
            found.append((request, answer))
        }
        return found
    }

    private func draw(_ found: [(ShellRequest, ShellAsk.Answer?)], names: [String: String], time: Date) {
        var drawn: [Card] = []
        for (request, answer) in found {
            let firstSight = seen.insert(request.id).inserted
            if answer == nil, firstSight, atOnce(), time.timeIntervalSince(request.created) < Self.atOnceWithin,
               request.created.timeIntervalSince(time) < Self.atOnceWithin, names[request.session] != nil {
                log("\(request.id) starts at once (Settings › Agents)")
                start(request, auto: true)
            }
            if let answer, !answer.told, answer.state != .starting { tell(request, answer) }
            guard let asker = names[request.session] else { continue }
            let state: Card.State
            switch answer?.state {
            case nil: state = .waiting(until: request.expiresAt)
            case .starting?: state = .starting
            case .started?: state = .started(name: answer?.name ?? ShellAsk.sessionLabel(request), auto: answer?.auto ?? false)
            case .declined?: state = .declined
            case .expired?: state = .expired
            case .failed?: state = .failed(answer?.why ?? "it didn't start")
            }
            drawn.append(Card(request: request, asker: asker, state: state))
        }
        if drawn != cards { cards = drawn }
    }

    /// Writes that it's starting (so it never starts twice), then starts it; the outcome is written and told. `done`
    /// once redrawn: ran when its session started, else refused with why not.
    private func start(_ request: ShellRequest, auto: Bool, done: @escaping (RunOutcome) -> Void = { _ in }) {
        let time = now()
        work.async { [self] in
            let redraw = { [self] (outcome: RunOutcome) in
                DispatchQueue.main.async { [self] in refresh { done(outcome) } }
            }
            // Answered meanwhile (another click, Decline, expiry): nothing starts.
            guard ShellAsk.answer(request.id, in: folder) == nil else { return redraw(.refused(RunRefusal.shellAnswered)) }
            guard time < request.expiresAt else { return redraw(.refused(RunRefusal.shellExpired)) }
            do {
                try ShellAsk.record(ShellAsk.Answer(state: .starting, at: time, auto: auto), for: request.id, in: folder)
            } catch {
                log("\(request.id) not started: couldn't record it (\(error))")
                return redraw(.refused(RunRefusal.shellNotRecorded(error)))
            }
            DispatchQueue.main.async { [self] in
                launch(request) { [self] result in
                    switch result {
                    case .success(let shell):
                        log("\(request.id) started as \(shell.id)")
                        answer(request, ShellAsk.Answer(state: .started, at: now(), auto: auto, shell: shell.id.uuidString.lowercased(),
                                                        name: shell.name)) { done(.ran) }
                    case .failure(let why):
                        log("\(request.id) didn't start: \(why)")
                        answer(request, ShellAsk.Answer(state: .failed, at: now(), auto: auto, why: why.description)) {
                            done(.refused(RunRefusal.shellNotStarted(why.description)))
                        }
                    }
                }
            }
        }
    }

    /// Records `answer` (over none, or over its own start) and redraws, which tells the asker.
    private func answer(_ request: ShellRequest, _ answer: ShellAsk.Answer, then: @escaping () -> Void) {
        work.async { [self] in
            let before = ShellAsk.answer(request.id, in: folder)
            if before == nil || (before?.state == .starting && answer.state != .declined) {
                do { try ShellAsk.record(answer, for: request.id, in: folder) } catch { log("couldn't record \(request.id): \(error)") }
            }
            DispatchQueue.main.async { [self] in refresh(then: then) }
        }
    }

    private func tell(_ request: ShellRequest, _ answer: ShellAsk.Answer) {
        guard let text = ShellAsk.message(request, answer), telling.insert(request.id).inserted else { return }
        deliver(request.session, text) { [self] delivery in
            telling.remove(request.id)
            guard delivery != .notYet else { return }
            if delivery == .ended { log("\(request.id): its session ended, so no one is told") }
            work.async { [self] in
                guard var now = ShellAsk.answer(request.id, in: folder), now.state == answer.state else { return }
                now.told = true
                try? ShellAsk.record(now, for: request.id, in: folder)
            }
        }
    }
}
