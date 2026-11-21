import Foundation
import VibeCore

/// Shell requests on a node (the app's `ShellDesk`, Sources/VibeSwitcher/Shell/ShellDesk.swift; `ShellAsk` shared): an
/// agent's `vs-shell run [--cwd DIR] -- COMMAND` files a request the session host stamped for the session it runs in
/// (`<root>/shell-requests/asked`); the engine shows each request the host's seal vouches for, from a session the host
/// runs, as a `shell` card naming the asking session, the exact folder and the exact command. Nothing starts until the
/// user answers it in a terminal: `vibeswitcher answer CARD run` or `decline`, the user's voice with the card's code
/// (`Requests.recorded`: the vault records it before it acts). A node has no "open shells without asking": every request
/// waits for the user. Run starts an ordinary shell session in that folder whose shell gets the command at launch
/// (`ShellAsk.spawnRequest`), never typed into a terminal; what was shown is what runs: the card's request, held in the
/// server's memory from the bytes the host stamped, never read again from the folder.
///
/// What became of a request (`ShellAsk.Answer`, beside it) is written before anything starts, so none starts twice, a
/// restart included; unanswered for 30 minutes it expires. The asking session is told each outcome as a message from
/// VibeSwitcher (again at a later look until it reached it or the session is gone), and once a started shell's command
/// ends, how it ended (`ShellAsk.ending`, from the host's capture). Looked at every 15 s on the engine's clock
/// (`watchRoom`) and after each answer; the folder and the host's seal are read on `shellWork`, never the engine's queue.
extension LeadEngine {
    /// How often the folder is looked at.
    static let shellLookEvery = 15
    /// A start that never finished (the server stopped in between) is called failed after this long.
    static let shellStartingFor: TimeInterval = 120
    /// Answered, told and this old: its files go.
    static let shellKeptFor: TimeInterval = 7 * 86_400
    /// A request dated this far ahead of the server's clock isn't shown (its 30 minutes would run late).
    static let shellAheadAtMost: TimeInterval = 120

    /// Where requests are filed: what `vs-shell` in this node's sessions writes (`ShellAsk.folder` under their
    /// `VIBESWITCHER_HOME`, this root).
    var shellFolder: URL { root.appendingPathComponent("shell-requests/asked", isDirectory: true) }

    /// Looks at the folder now: stamps checked with the host (once each), what's past its time expired, cards drawn,
    /// the askers told; `done` on `queue` once drawn (a look under way: at once). On `queue`.
    func lookAtShellRequests(done: (() -> Void)? = nil) {
        guard !shellLooking else { done?(); return }
        shellLooking = true
        let (folder, vault, trusted, now, note) = (shellFolder, cardVault, shellTrusted, shellNow(), self.note)
        shellWork.async { [weak self] in
            let found = Self.loadShellRequests(folder: folder, trusted: trusted, vault: vault, now: now, note: note)
            self?.queue.async {
                guard let self else { return }
                self.shellLooking = false
                self.shellTrusted = found.trusted
                self.drawShellCards(found.requests, now: now)
                done?()
            }
        }
    }

    /// Each stamped request with what became of it. Past its time unanswered: expired (written here). Starting too long:
    /// failed. Answered, told and old, or dismissed and its end told: removed. Blocks: on `shellWork`.
    static func loadShellRequests(folder: URL, trusted given: [String: WalletStamp], vault: LeadVault, now: Date,
                                  note: (String) -> Void) -> (requests: [(ShellRequest, ShellAsk.Answer?)], trusted: [String: WalletStamp]) {
        let (requests, stamps, refused) = ShellAsk.filed(in: folder)
        for (file, why) in refused { note("shell request not shown: \(file.lastPathComponent): \(why)") }
        var trusted = given.filter { stamps[$0.key] == $0.value }
        let unasked = requests.filter { trusted[$0.id] == nil }.compactMap { request in stamps[request.id].map { (request.id, $0) } }
        if !unasked.isEmpty {
            do {
                let valid = try vault.verifyWallet(unasked.map(\.1))
                for ((id, stamp), ok) in zip(unasked, valid) {
                    if ok { trusted[id] = stamp } else { note("shell request not shown: \(id): its stamp isn't the session host's") }
                }
            } catch {
                note("shell requests: the stamps weren't checked: \(error)")
            }
        }
        var found: [(ShellRequest, ShellAsk.Answer?)] = []
        for request in requests where trusted[request.id] != nil && trusted[request.id] == stamps[request.id] {
            guard request.created.timeIntervalSince(now) <= shellAheadAtMost else {
                note("shell request not shown: \(request.id): filed for \(request.created), ahead of this clock")
                continue
            }
            let kept = ShellAsk.answer(request.id, in: folder)
            var answer = kept
            if answer == nil, now >= request.expiresAt {
                note("shell request \(request.id) expired unanswered")
                answer = ShellAsk.Answer(state: .expired, at: now)
            } else if let started = answer, started.state == .starting, now.timeIntervalSince1970 - started.at > shellStartingFor {
                answer = ShellAsk.Answer(state: .failed, at: now, why: "the node's server stopped before the shell started; `vibeswitcher status` lists the sessions")
            }
            if let answer, answer != kept {
                do { try ShellAsk.record(answer, for: request.id, in: folder) } catch { note("shell request \(request.id): not recorded: \(error)") }
            }
            if let answer, answer.dismissed == true, !answer.awaitsEnd {
                ShellAsk.remove(request.id, in: folder)
                continue
            }
            if let answer, answer.told, !answer.awaitsEnd, now.timeIntervalSince1970 - answer.at > shellKeptFor {
                ShellAsk.remove(request.id, in: folder)
                continue
            }
            found.append((request, answer))
        }
        return (found, trusted)
    }

    /// The cards for what was found: a waiting request from a session the host runs gets an open card; an answered one
    /// closes its card; the askers are told what's untold. On `queue`.
    private func drawShellCards(_ found: [(ShellRequest, ShellAsk.Answer?)], now: Date) {
        let live = Dictionary(link.sessions.filter(\.isLive).map { ($0.id.uuidString.lowercased(), $0) }) { first, _ in first }
        var seen: Set<String> = []
        for (request, answer) in found {
            seen.insert(request.id)
            if let answer, !answer.told, answer.state != .starting { tellShell(request, answer) }
            if let answer { tellShellEnd(request, answer, now: now) }
            let existing = shellCards[request.id].flatMap { cards.cards[$0] }
            guard let state = Self.shellState(answer) else { continue }
            if var card = existing {
                guard var shown = card.shell, shown.state != state || shown.shell != answer?.shell || shown.why != answer?.why else { continue }
                shown.state = state
                shown.shell = answer?.shell
                shown.name = answer?.name
                shown.why = answer?.why
                card.shell = shown
                if state != .waiting && state != .starting { card.closed = Self.shellClosed(request, answer) }
                cards.put(card)
                continue
            }
            // A card for a request still waiting, from a session the host runs; nothing for one answered before this server.
            guard state == .waiting, let asker = live[request.session] else { continue }
            var card = CardStore.Card(root: request.cwd, kind: .shell, at: request.created)
            card.shell = CardStore.ShellShown(request: request, asker: asker.label.isEmpty ? "session \(asker.tty)" : asker.label)
            shellCards[request.id] = card.id
            cards.put(card)
            note("shell request \(request.id): card \(card.id) for session \(request.session.prefix(8))")
        }
        // A request whose files went (removed, or never stamped): its open card closes.
        for (request, id) in shellCards where !seen.contains(request) {
            shellCards[request] = nil
            if var card = cards.cards[id], card.isOpen {
                card.closed = "the request is gone"
                cards.put(card)
            }
        }
    }

    static func shellState(_ answer: ShellAsk.Answer?) -> CardStore.ShellShown.State? {
        switch answer?.state {
        case nil: return .waiting
        case .starting?: return .starting
        case .started?: return .started
        case .declined?: return .declined
        case .expired?: return .expired
        case .failed?: return .failed
        }
    }

    static func shellClosed(_ request: ShellRequest, _ answer: ShellAsk.Answer?) -> String {
        switch answer?.state {
        case .started?: return "run: started in a new shell session \"\(answer?.name ?? ShellAsk.sessionLabel(request))\""
        case .declined?: return "declined"
        case .expired?: return "expired after 30 minutes unanswered"
        case .failed?: return "didn't start: \(answer?.why ?? "the session host refused it")"
        default: return "answered"
        }
    }

    /// The user's answer to a shell card (`answer CARD run|decline`): `run` starts its shell once, `decline` declines
    /// it; each written before anything starts. `then` hears on `queue` what came of it. On `queue`.
    func answerShell(_ card: CardStore.Card, text: String, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        guard let shown = card.shell else { return then(.failure(.gone("no shell request on card \(card.id)"))) }
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["run", "decline"].contains(word) else {
            return then(.failure(.badArgs("a shell card is answered run or decline (`vibeswitcher answer \(card.id) run`)")))
        }
        guard card.isOpen, shown.state == .waiting else { return then(.failure(.refused("card \(card.id) is answered already: \(card.closed ?? shown.state.rawValue)"))) }
        let (request, folder, now, note) = (shown.request, shellFolder, shellNow(), self.note)
        let decline = word == "decline"
        shellWork.async { [weak self] in
            let refusal: String? = {
                guard ShellAsk.answer(request.id, in: folder) == nil else { return "it was answered already" }
                guard decline || now < request.expiresAt else { return "it expired: nothing ran" }
                do {
                    try ShellAsk.record(ShellAsk.Answer(state: decline ? .declined : .starting, at: now), for: request.id, in: folder)
                } catch {
                    return "its answer couldn't be recorded, so nothing started: \(error)"
                }
                return nil
            }()
            self?.queue.async {
                guard let self else { return }
                if let refusal {
                    note("shell request \(request.id): not \(decline ? "declined" : "run"): \(refusal)")
                    return self.lookAtShellRequests { then(.failure(.refused(refusal))) }
                }
                if decline {
                    note("shell request \(request.id) declined")
                    return self.lookAtShellRequests { then(.success(.object(["outcome": .string("declined"), "notice": .null]))) }
                }
                self.startShell(request, at: now, then: then)
            }
        }
    }

    /// Starts the request's shell session (the host's spawn), records what came of it and looks again. On `queue`.
    private func startShell(_ request: ShellRequest, at: Date, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        var spawn = ShellAsk.spawnRequest(request)
        // A scratch node's hooks and tools keep to its root, as its sessions' do.
        if isScratch { spawn.env["VIBESWITCHER_HOME"] = root.path }
        let (folder, note) = (shellFolder, self.note)
        link.spawn(spawn) { [weak self] result in
            let answer: ShellAsk.Answer
            let reply: Result<NodeWire.Value, CardFailure>
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
            self?.shellWork.async {
                do { try ShellAsk.record(answer, for: request.id, in: folder) } catch { note("shell request \(request.id): not recorded: \(error)") }
                self?.queue.async { self?.lookAtShellRequests { then(reply) } ?? then(reply) }
            }
        }
    }

    /// Tells the asking session what became of its request, once it reached it (or the session is gone). On `queue`.
    private func tellShell(_ request: ShellRequest, _ answer: ShellAsk.Answer) {
        guard let text = ShellAsk.message(request, answer), let session = UUID(uuidString: request.session),
              shellTelling.insert(request.id).inserted else { return }
        let (folder, note) = (shellFolder, self.note)
        tell(text, from: .system("from New Shell"), session: session) { [weak self] delivery in
            guard let self else { return }
            self.shellTelling.remove(request.id)
            guard delivery != .notYet else { return }
            if delivery == .ended { note("shell request \(request.id): its session ended, so no one is told") }
            self.shellWork.async {
                guard var now = ShellAsk.answer(request.id, in: folder), now.state == answer.state else { return }
                now.told = true
                try? ShellAsk.record(now, for: request.id, in: folder)
            }
        }
    }

    /// Once the asker heard that its shell started: how the command ended, once, when the host's list shows it, or
    /// that the shell went first. A shell the host doesn't list yet just after it started isn't called gone. On `queue`.
    private func tellShellEnd(_ request: ShellRequest, _ answer: ShellAsk.Answer, now: Date) {
        guard answer.awaitsEnd, answer.told, link.state == .connected, !shellTellingEnd.contains(request.id),
              let asker = UUID(uuidString: request.session) else { return }
        let session = answer.shell.flatMap(UUID.init(uuidString:)).flatMap { id in link.sessions.first { $0.id == id } }
        if session == nil, now.timeIntervalSince1970 - answer.at < Self.shellStartingFor { return }
        guard let text = ShellAsk.ending(request, answer, session: session) else { return }
        shellTellingEnd.insert(request.id)
        let (folder, note) = (shellFolder, self.note)
        tell(text, from: .system("from New Shell"), session: asker) { [weak self] delivery in
            guard let self else { return }
            guard delivery != .notYet else { self.shellTellingEnd.remove(request.id); return }
            note("shell request \(request.id) ended: " + (session?.commandEnd.map { $0.ok ? "status 0" : "status \($0.status.map(String.init) ?? "not known")" } ?? "not captured")
                 + (delivery == .ended ? "; its asker's session ended, so no one is told" : "; told"))
            self.shellWork.async {
                if var kept = ShellAsk.answer(request.id, in: folder), kept.awaitsEnd {
                    kept.endTold = true
                    try? ShellAsk.record(kept, for: request.id, in: folder)
                }
                self.queue.async { self.shellTellingEnd.remove(request.id) }
            }
        }
    }

    /// `status`'s notice for each shell card waiting on the user. On `queue`.
    var shellNotices: [String] {
        cards.list().filter { $0.kind == .shell }.compactMap { card in
            guard let shown = card.shell, shown.state == .waiting else { return nil }
            let line = shown.request.command.split(separator: "\n").first.map(String.init) ?? ""
            let more = shown.request.command.contains("\n") || line.count > 100 ? " …" : ""
            return "a shell request waits for you: \(shown.asker) asks to run `\(ConfigSeal.inert(String(line.prefix(100)), limit: 120))\(more)` in "
                + "\(ConfigSeal.inert(shown.request.cwd, limit: 200)). `vibeswitcher answer \(card.id) run` shows it whole and runs it, "
                + "`decline` declines it; it expires at \(NodeWire.dateText(shown.request.expiresAt))"
        }
    }
}
