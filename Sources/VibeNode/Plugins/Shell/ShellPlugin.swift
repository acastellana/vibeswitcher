import Foundation
import VibeCore

/// Shell requests, as a feature plugin (the app's `ShellDesk`, Sources/VibeSwitcher/Shell/ShellDesk.swift; `ShellAsk`
/// shared): an agent's `vs-shell run [--cwd DIR] -- COMMAND` files a request the session host stamped for the session it
/// runs in (`<root>/shell-requests/asked`); the plugin shows each request the host's seal vouches for (the registry's
/// one reader, `PluginDesk.stamped`), from a session the host runs, as a card naming the asking session, the exact
/// folder and the exact command. Nothing starts until the user answers it in a terminal: `vibeswitcher answer CARD run`
/// or `decline`, the user's voice with the card's code (`Requests.voiced`: the vault records it before it acts; the
/// desk's checks, then `perform`). A node has no "open shells without asking": every request waits for the user. Run
/// starts an ordinary shell session in that folder whose shell gets the command at launch (`ShellAsk.spawnRequest`),
/// never typed into a terminal; what was shown is what runs: the request held in this plugin's memory from the bytes the
/// host stamped (`shown`), never read again from the folder. On by default.
///
/// What became of a request is the plugin's own (`answers`, in the engine's memory), set before anything starts, so a
/// card is never run twice; the answer files beside the requests (`.<id>.answer`, which any process of the uid can
/// write, the review of 2026-11-21) are written for the app's format and a restart, but never read for what they say:
/// one this server didn't write only keeps its request from being shown again (it was answered before this server, or
/// someone wants it hidden: never run, never told). So nothing a file says reaches a session as VibeSwitcher's words,
/// closes a card, or names the shell whose output an asker is told. A request whose card the core refuses (a character
/// that draws as blank, `PluginCard.refusal`) is never shown: its asker is told why.
///
/// Unanswered for 30 minutes a request expires. The asking session is told each outcome as a message from VibeSwitcher
/// (again at a later look until it reached it or the session is gone), and once a shell the plugin started ends its
/// command, how it ended (`ShellAsk.ending`, from the host's capture of that shell). Looked at every 15 s on the engine's
/// clock (`LeadEngine.lookAtPlugins`) and after each answer; the folder and the host's seal are read on the desk's
/// `work`, never the engine's queue. Everything else on the engine's queue.
public final class ShellPlugin: FeaturePlugin {
    public static let id = "shell"

    public let info = PluginInfo(
        id: ShellPlugin.id, title: "Shell requests",
        summary: "An agent asks for a new shell session running a command it names; nothing runs until you answer its card run in your terminal.",
        defaultOn: true,
        commands: [.init(name: "vs-shell", about: "vs-shell run [--cwd DIR] [--label TEXT] -- COMMAND…: asks the user for a shell session running COMMAND")],
        folder: "shell-requests/asked", life: ShellRequest.lifetime,
        brief: ["When something needs a real terminal, ask for it with `vs-shell run [--cwd DIR] [--label TEXT] -- COMMAND…`: the user runs or declines it from its card."])

    /// A start that never finished is called failed after this long.
    static let startingFor: TimeInterval = 120
    /// Answered, told and this old: its files go (and a request this server never answered, this long after it was filed).
    static let keptFor: TimeInterval = 7 * 86_400

    /// What became of each request, the plugin's own (never read from the folder's answer files).
    var answers: [String: ShellAsk.Answer] = [:]
    /// Each request a card was drawn for, as the host stamped it: what runs.
    var shown: [String: ShellRequest] = [:]
    /// The messages under way; the requests whose cards were withdrawn (the plugin turned off).
    var telling: Set<String> = []
    var tellingEnd: Set<String> = []
    var withdrawnRequests: Set<String> = []

    public init() {}

    // MARK: The look

    public func look(_ desk: PluginDesk, done: @escaping () -> Void) {
        desk.stamped({ try ShellRequest.parse($0) }) { [weak self] requests in
            guard let folder = desk.folder else { return done() }
            // Which have an answer file beside them (its contents never read): on the desk's work.
            desk.work.async {
                var answered: Set<String> = []
                for request in requests {
                    var info = stat()
                    if lstat(folder.appendingPathComponent(".\(request.id).answer").path, &info) == 0 { answered.insert(request.id) }
                }
                // Back on the engine's queue only while the engine lives (a look can outlive it).
                desk.later {
                    self?.draw(requests, answeredOnDisk: answered, desk: desk)
                    // Done once what the look wrote (answer files, on the same serial work) is written.
                    desk.work.async { desk.later(done) }
                }
            }
        }
    }

    /// Writes `answer` beside its request (for the app's format and a restart; never read back for what it says).
    private func recordFile(_ answer: ShellAsk.Answer, for id: String, desk: PluginDesk) {
        guard let folder = desk.folder else { return }
        let note = desk.note
        desk.work.async {
            do { try ShellAsk.record(answer, for: id, in: folder) } catch { note("shell request \(id): its answer file not written: \(error)") }
        }
    }

    private func removeFiles(_ id: String, desk: PluginDesk) {
        guard let folder = desk.folder else { return }
        answers[id] = nil
        desk.work.async { ShellAsk.remove(id, in: folder) }
    }

    /// The cards for what was found, from the plugin's own answers: a waiting request from a session the host runs gets
    /// an open card; an answered one closes its card; the askers are told what's untold.
    private func draw(_ found: [ShellRequest], answeredOnDisk: Set<String>, desk: PluginDesk) {
        let (live, now, note) = (desk.live, desk.now, desk.note)
        var seen: Set<String> = []
        for read in found {
            // What was drawn is what is told of: the request as its card showed it.
            let request = shown[read.id] ?? read
            seen.insert(request.id)
            var answer = answers[request.id]
            if answer == nil {
                // Answered before this server, or a file someone put there: never shown, run or told.
                if answeredOnDisk.contains(request.id) {
                    if now.timeIntervalSince(request.created) > Self.keptFor { removeFiles(request.id, desk: desk) }
                    continue
                }
                if now >= request.expiresAt {
                    note("shell request \(request.id) expired unanswered")
                    answer = ShellAsk.Answer(state: .expired, at: now)
                } else if let why = Self.card(request, asker: live[request.session].map(PluginDesk.asker) ?? "a session").refusal {
                    note("shell request \(request.id) not shown: \(why)")
                    answer = ShellAsk.Answer(state: .failed, at: now, why: why)
                }
                if let answer {
                    answers[request.id] = answer
                    recordFile(answer, for: request.id, desk: desk)
                }
            } else if let started = answer, started.state == .starting, now.timeIntervalSince1970 - started.at > Self.startingFor {
                answer = ShellAsk.Answer(state: .failed, at: now, why: "the session host didn't say it started the shell; `vibeswitcher status` lists the sessions")
                answers[request.id] = answer
                recordFile(answer!, for: request.id, desk: desk)
            }
            if let kept = answer, kept.told, !kept.awaitsEnd, now.timeIntervalSince1970 - kept.at > Self.keptFor {
                removeFiles(request.id, desk: desk)
                continue
            }
            if let answer, !answer.told, answer.state != .starting { tell(request, answer, desk: desk) }
            if let answer { tellEnd(request, answer, now: now, desk: desk) }
            let state = Self.state(answer)
            if desk.card(request: request.id) != nil {
                guard !withdrawnRequests.contains(request.id) else { continue }
                let settled = state != PluginCard.waitingState && state != "starting"
                desk.change(request: request.id, state: state, outcome: Self.outcome(answer), closed: settled ? Self.closed(request, answer) : nil)
                continue
            }
            // A card for a request still waiting, from a session the host runs.
            guard state == PluginCard.waitingState, let asker = live[request.session] else { continue }
            switch desk.draw(Self.card(request, asker: PluginDesk.asker(asker)), root: request.cwd, at: request.created) {
            case .success(let card):
                shown[request.id] = request
                note("shell request \(request.id): card \(card.id) for session \(request.session.prefix(8))")
            case .failure(let why):
                note("shell request \(request.id) not shown: \(why)")
            }
        }
        // A request whose files went (removed, or never stamped): its open card closes, and nothing can run it.
        for request in desk.carded where !seen.contains(request) {
            // Its shell starting: not called gone (the start says what became of it).
            if answers[request]?.state == .starting { continue }
            desk.forget(request: request, closed: "the request is gone")
            shown[request] = nil
            if answers[request] == nil { answers[request] = ShellAsk.Answer(state: .expired, at: now, told: true) }
        }
    }

    // MARK: The card

    /// The request as a card of data: the host's facts (the asking session, the folder), the command whole, the
    /// agent's label as its words.
    static func card(_ request: ShellRequest, asker: String) -> PluginCard {
        let folder = ConfigSeal.inert(request.cwd, limit: 200)
        return PluginCard(
            plugin: id, request: request.id, session: "\(NodeIds.node):\(request.session)", asker: asker,
            title: "A shell asked for", noun: "shell request", ask: "asks for a new shell session",
            facts: [.init(name: "folder", label: "in the folder", value: request.cwd, folder: true, decisive: true)],
            body: .init(name: "command", label: "running exactly this command", note: "by your login shell, which stays open after it",
                        text: request.command),
            context: request.label.isEmpty ? nil : .init(name: "label", label: "named", text: "Shell: " + request.label),
            severity: .important, expiresAt: request.expiresAt,
            actions: [
                .init(word: "run", label: "Run", acts: true, short: "runs it",
                      does: "runs the command above (\(PluginText.size(request.command))), exactly as shown, in a new shell session in \(folder), "
                        + "as you: it runs with everything your account can do",
                      verb: "run an agent's command in your login shell", marks: "starting"),
                .init(word: "decline", label: "Decline", acts: false, short: "declines it",
                      does: "declines this shell request: nothing runs, and the asking session is told",
                      verb: "decline an agent's shell request", marks: "declined"),
            ],
            waiting: "nothing runs until you answer run")
    }

    /// The card's state for what became of its request.
    static func state(_ answer: ShellAsk.Answer?) -> String {
        switch answer?.state {
        case nil: return PluginCard.waitingState
        case .starting?: return "starting"
        case .started?: return "started"
        case .declined?: return "declined"
        case .expired?: return "expired"
        case .failed?: return "failed"
        }
    }

    /// What the card says once its request is settled (nil while it waits).
    static func outcome(_ answer: ShellAsk.Answer?) -> String? {
        switch answer?.state {
        case nil: return nil
        case .starting?: return "Starting…"
        case .started?: return "Started" + (answer?.name.map { ": session “\($0)”" } ?? "")
        case .declined?: return "Declined"
        case .expired?: return "Expired unanswered"
        case .failed?: return "Didn’t start" + (answer?.why.map { ": \($0)" } ?? "")
        }
    }

    /// The card's closing words.
    static func closed(_ request: ShellRequest, _ answer: ShellAsk.Answer?) -> String {
        switch answer?.state {
        case .started?: return "run: started in a new shell session \"\(answer?.name ?? ShellAsk.sessionLabel(request))\""
        case .declined?: return "declined"
        case .expired?: return "expired after 30 minutes unanswered"
        case .failed?: return "didn't start: \(answer?.why ?? "the session host refused it")"
        default: return "answered"
        }
    }

    // MARK: Answers

    /// The user's answer (`answer CARD run|decline`), after the desk's checks marked the card: the plugin's answer is set
    /// at once (a second answer finds it), then `run` starts its shell once, `decline` declines it.
    public func perform(_ word: String, on card: CardStore.Card, desk: PluginDesk, act: PluginAct,
                        then: @escaping (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void) {
        guard let id = card.plugin?.request, let request = shown[id] else {
            return then(.failure(.gone("no shell request on card \(card.id)")))
        }
        guard answers[id] == nil else {
            return then(.failure(.refused("card \(card.id) is answered already: \(card.closed ?? Self.state(answers[id]))")))
        }
        let (now, decline, folder, note) = (desk.now, word == "decline", desk.folder, desk.note)
        // The plugin's answer and the card, before anything else: no second `run` can start it again.
        let answer = ShellAsk.Answer(state: decline ? .declined : .starting, at: now)
        answers[id] = answer
        desk.change(request: id, state: Self.state(answer), outcome: Self.outcome(answer), closed: decline ? Self.closed(request, answer) : nil)
        desk.work.async { [weak self] in
            // An answer file this server didn't write (it saw none when it drew the card): someone wants it held. Nothing starts.
            var info = stat()
            let planted = !decline && folder.map { lstat($0.appendingPathComponent(".\(id).answer").path, &info) == 0 } == true
            let written: Error? = planted ? nil : { () -> Error? in
                guard let folder else { return nil }
                do { try ShellAsk.record(answer, for: id, in: folder); return nil } catch { return error }
            }()
            desk.later {
                guard let self else { return }
                if decline {
                    note("shell request \(id) declined")
                    return self.lookAgain(desk) { then(.success(.object(["outcome": .string("declined"), "notice": .null]))) }
                }
                if planted || written != nil {
                    let why = planted ? "an answer file appeared beside the request that this server didn't write"
                        : "its answer couldn't be recorded (\(written.map { "\($0)" } ?? ""))"
                    note("shell request \(id): not run: \(why)")
                    self.answers[id] = ShellAsk.Answer(state: .failed, at: Date(), why: "\(why): nothing ran")
                    return self.lookAgain(desk) { then(.failure(.refused("\(why): nothing ran"))) }
                }
                self.start(request, desk: desk, act: act, then: then)
            }
        }
    }

    /// Looks again through the engine (one look at a time), then `done`.
    private func lookAgain(_ desk: PluginDesk, done: @escaping () -> Void) {
        desk.lookAgain(done: done)
    }

    /// Starts the request's shell session (the host's spawn), keeps what came of it (the shell the plugin started, by
    /// the host's own answer) and looks again.
    private func start(_ request: ShellRequest, desk: PluginDesk, act: PluginAct,
                       then: @escaping (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void) {
        var spawn = ShellAsk.spawnRequest(request)
        // A scratch node's hooks and tools keep to its root, as its sessions' do.
        if desk.isScratch { spawn.env["VIBESWITCHER_HOME"] = desk.root.path }
        let note = desk.note
        act.spawn(spawn) { [weak self] result in
            let answer: ShellAsk.Answer
            let reply: Result<NodeWire.Value, LeadEngine.CardFailure>
            switch result {
            case .success(let session):
                note("shell request \(request.id) started as session \(session.id.uuidString.prefix(8)) (\(session.tty))")
                answer = ShellAsk.Answer(state: .started, at: Date(), shell: session.id.uuidString.lowercased(), name: session.label, endTold: false)
                reply = .success(.object(["outcome": .string("started"), "session": .string(NodeIds.session(host: session.id)),
                                          "terminal": .string(session.tty), "notice": .null]))
            case .failure(let failure):
                note("shell request \(request.id) didn't start: \(failure.message)")
                answer = ShellAsk.Answer(state: .failed, at: Date(), why: failure.message)
                reply = .failure(.refused("the session host didn't start it: \(failure.message)"))
            }
            desk.later {
                guard let self else { return }
                self.answers[request.id] = answer
                self.recordFile(answer, for: request.id, desk: desk)
                self.lookAgain(desk) { then(reply) }
            }
        }
    }

    // MARK: Telling

    /// Tells the asking session what became of its request (the plugin's answer), once it reached it (or the session is
    /// gone).
    private func tell(_ request: ShellRequest, _ answer: ShellAsk.Answer, desk: PluginDesk) {
        guard let text = ShellAsk.message(request, answer), telling.insert(request.id).inserted else { return }
        let note = desk.note
        desk.tell(text, from: "from New Shell", request: request.id) { [weak self] delivery in
            guard let self else { return }
            self.telling.remove(request.id)
            guard delivery != .notYet else { return }
            if delivery == .ended { note("shell request \(request.id): its session ended, so no one is told") }
            guard var now = self.answers[request.id], now.state == answer.state else { return }
            now.told = true
            self.answers[request.id] = now
            self.recordFile(now, for: request.id, desk: desk)
        }
    }

    /// Once the asker heard that its shell started: how the command ended in the shell the plugin started (its id, from
    /// the host's answer to the spawn), once, when the host's list shows it, or that the shell went first. A shell the
    /// host doesn't list yet just after it started isn't called gone.
    private func tellEnd(_ request: ShellRequest, _ answer: ShellAsk.Answer, now: Date, desk: PluginDesk) {
        guard answer.awaitsEnd, answer.told, desk.connected, !tellingEnd.contains(request.id) else { return }
        let session = answer.shell.flatMap(UUID.init(uuidString:)).flatMap(desk.session)
        if session == nil, now.timeIntervalSince1970 - answer.at < Self.startingFor { return }
        guard let text = ShellAsk.ending(request, answer, session: session) else { return }
        tellingEnd.insert(request.id)
        let note = desk.note
        desk.tell(text, from: "from New Shell", request: request.id) { [weak self] delivery in
            guard let self else { return }
            self.tellingEnd.remove(request.id)
            guard delivery != .notYet else { return }
            note("shell request \(request.id) ended: " + (session?.commandEnd.map { $0.ok ? "status 0" : "status \($0.status.map(String.init) ?? "not known")" } ?? "not captured")
                 + (delivery == .ended ? "; its asker's session ended, so no one is told" : "; told"))
            if var kept = self.answers[request.id], kept.awaitsEnd {
                kept.endTold = true
                self.answers[request.id] = kept
                self.recordFile(kept, for: request.id, desk: desk)
            }
        }
    }

    // MARK: Off

    /// Turned off with this card open: the desk closed it and told its asker; nothing more comes of it here, after a
    /// restart either (its answer file says it was settled).
    public func withdrawn(_ card: PluginCard, desk: PluginDesk) -> String? {
        withdrawnRequests.insert(card.request)
        let answer = ShellAsk.Answer(state: .declined, at: desk.now, told: true)
        answers[card.request] = answer
        recordFile(answer, for: card.request, desk: desk)
        return nil
    }

    /// Turned off: each asker whose shell started and whose command's end it hasn't heard of yet hears that it won't
    /// (no look follows the shell while off). Kept as told, so turning it on again doesn't tell it late.
    public func turnedOff(_ desk: PluginDesk) -> [(session: UUID, text: String)] {
        var said: [(session: UUID, text: String)] = []
        for (id, answer) in answers where answer.awaitsEnd && answer.told {
            guard let request = shown[id], let asker = UUID(uuidString: request.session) else { continue }
            said.append((asker, "[VibeSwitcher] Your shell request \(id) started in session \"\(answer.name ?? ShellAsk.sessionLabel(request))\", "
                         + "but the user turned Shell requests off on this node, so you won't be told how its command ends. "
                         + "Look at that session's output yourself if you need it, or ask the user."))
            var kept = answer
            kept.endTold = true
            answers[id] = kept
            recordFile(kept, for: id, desk: desk)
        }
        return said
    }
}

/// A shell request is one the session host stamped for the session it was filed from (`ShellAsk.file`).
extension ShellRequest: StampedAsk {}
