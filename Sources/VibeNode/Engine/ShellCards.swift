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
/// What became of a request is the engine's own (`shellAnswers`, in its memory), set before anything starts, so a card
/// is never run twice; the answer files beside the requests (`.<id>.answer`, which any process of the uid can write, the
/// review of 2026-11-21) are written for the app's format and a restart, but never read for what they say: one this
/// server didn't write only keeps its request from being shown again (it was answered before this server, or someone
/// wants it hidden: never run, never told). So nothing a file says reaches a session as VibeSwitcher's words, closes a
/// card, or names the shell whose output an asker is told. A request whose command, label or folder holds a character
/// that draws as blank (`ShellCards.blankLooking`) is never shown: its asker is told why.
///
/// Unanswered for 30 minutes a request expires. The asking session is told each outcome as a message from VibeSwitcher
/// (again at a later look until it reached it or the session is gone), and once a shell the engine started ends its
/// command, how it ended (`ShellAsk.ending`, from the host's capture of that shell). Looked at every 15 s on the engine's
/// clock (`watchRoom`) and after each answer; the folder and the host's seal are read on `shellWork`, never the engine's
/// queue.
extension LeadEngine {
    /// How often the folder is looked at.
    static let shellLookEvery = 15
    /// A start that never finished is called failed after this long.
    static let shellStartingFor: TimeInterval = 120
    /// Answered, told and this old: its files go (and a request this server never answered, this long after it was filed).
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
                self.drawShellCards(found.requests, answeredOnDisk: found.answeredOnDisk, now: now)
                done?()
            }
        }
    }

    /// Each stamped request, and which of them have an answer file beside them (its contents never read). Blocks: on
    /// `shellWork`.
    static func loadShellRequests(folder: URL, trusted given: [String: WalletStamp], vault: LeadVault, now: Date,
                                  note: (String) -> Void) -> (requests: [ShellRequest], answeredOnDisk: Set<String>, trusted: [String: WalletStamp]) {
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
        var found: [ShellRequest] = []
        var answered: Set<String> = []
        for request in requests where trusted[request.id] != nil && trusted[request.id] == stamps[request.id] {
            guard request.created.timeIntervalSince(now) <= shellAheadAtMost else {
                note("shell request not shown: \(request.id): filed for \(request.created), ahead of this clock")
                continue
            }
            var info = stat()
            if lstat(folder.appendingPathComponent(".\(request.id).answer").path, &info) == 0 { answered.insert(request.id) }
            found.append(request)
        }
        return (found, answered, trusted)
    }

    /// Writes `answer` beside its request (for the app's format and a restart; never read back for what it says).
    private func recordShellFile(_ answer: ShellAsk.Answer, for id: String) {
        let (folder, note) = (shellFolder, self.note)
        shellWork.async {
            do { try ShellAsk.record(answer, for: id, in: folder) } catch { note("shell request \(id): its answer file not written: \(error)") }
        }
    }

    /// The cards for what was found, from the engine's own answers: a waiting request from a session the host runs gets
    /// an open card; an answered one closes its card; the askers are told what's untold. On `queue`.
    private func drawShellCards(_ found: [ShellRequest], answeredOnDisk: Set<String>, now: Date) {
        let live = Dictionary(link.sessions.filter(\.isLive).map { ($0.id.uuidString.lowercased(), $0) }) { first, _ in first }
        var seen: Set<String> = []
        for request in found {
            seen.insert(request.id)
            var answer = shellAnswers[request.id]
            if answer == nil {
                // Answered before this server, or a file someone put there: never shown, run or told.
                if answeredOnDisk.contains(request.id) {
                    if now.timeIntervalSince(request.created) > Self.shellKeptFor { removeShellFiles(request.id) }
                    continue
                }
                if now >= request.expiresAt {
                    note("shell request \(request.id) expired unanswered")
                    answer = ShellAsk.Answer(state: .expired, at: now)
                } else if let why = ShellCards.blankLooking(request) {
                    note("shell request \(request.id) not shown: \(why)")
                    answer = ShellAsk.Answer(state: .failed, at: now, why: why)
                }
                if let answer {
                    shellAnswers[request.id] = answer
                    recordShellFile(answer, for: request.id)
                }
            } else if let started = answer, started.state == .starting, now.timeIntervalSince1970 - started.at > Self.shellStartingFor {
                answer = ShellAsk.Answer(state: .failed, at: now, why: "the session host didn't say it started the shell; `vibeswitcher status` lists the sessions")
                shellAnswers[request.id] = answer
                recordShellFile(answer!, for: request.id)
            }
            if let kept = answer, kept.told, !kept.awaitsEnd, now.timeIntervalSince1970 - kept.at > Self.shellKeptFor {
                removeShellFiles(request.id)
                continue
            }
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
            // A card for a request still waiting, from a session the host runs.
            guard state == .waiting, let asker = live[request.session] else { continue }
            var card = CardStore.Card(root: request.cwd, kind: .shell, at: request.created)
            card.shell = CardStore.ShellShown(request: request, asker: asker.label.isEmpty ? "session \(asker.tty)" : asker.label)
            shellCards[request.id] = card.id
            cards.put(card)
            note("shell request \(request.id): card \(card.id) for session \(request.session.prefix(8))")
        }
        // A request whose files went (removed, or never stamped): its open card closes, and nothing can run it.
        for (request, id) in shellCards where !seen.contains(request) {
            shellCards[request] = nil
            if shellAnswers[request] == nil { shellAnswers[request] = ShellAsk.Answer(state: .expired, at: now, told: true) }
            if var card = cards.cards[id], card.isOpen {
                card.closed = "the request is gone"
                cards.put(card)
            }
        }
    }

    private func removeShellFiles(_ id: String) {
        let folder = shellFolder
        shellAnswers[id] = nil
        shellWork.async { ShellAsk.remove(id, in: folder) }
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

    /// The user's answer to a shell card (`answer CARD run|decline`): the engine's answer is set at once (a second
    /// answer finds it), then `run` starts its shell once, `decline` declines it. `then` hears on `queue` what came of it.
    /// On `queue`.
    func answerShell(_ card: CardStore.Card, text: String, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        guard var shown = card.shell else { return then(.failure(.gone("no shell request on card \(card.id)"))) }
        guard let word = ShellCards.answerWord(text) else {
            return then(.failure(.badArgs("a shell card is answered run or decline (`vibeswitcher answer \(card.id) run`)")))
        }
        let request = shown.request
        guard card.isOpen, shown.state == .waiting, shellAnswers[request.id] == nil else {
            return then(.failure(.refused("card \(card.id) is answered already: \(card.closed ?? shown.state.rawValue)")))
        }
        let (now, decline, folder, note) = (shellNow(), word == "decline", shellFolder, self.note)
        guard decline || now < request.expiresAt else { return then(.failure(.refused("it expired: nothing ran"))) }
        // The engine's answer and the card, before anything else: no second `run` can start it again.
        let answer = ShellAsk.Answer(state: decline ? .declined : .starting, at: now)
        shellAnswers[request.id] = answer
        shown.state = decline ? .declined : .starting
        var updated = card
        updated.shell = shown
        if decline { updated.closed = Self.shellClosed(request, answer) }
        cards.put(updated)
        shellWork.async { [weak self] in
            // An answer file this server didn't write (it saw none when it drew the card): someone wants it held. Nothing starts.
            var info = stat()
            let planted = !decline && lstat(folder.appendingPathComponent(".\(request.id).answer").path, &info) == 0
            let written: Error? = planted ? nil : { () -> Error? in
                do { try ShellAsk.record(answer, for: request.id, in: folder); return nil } catch { return error }
            }()
            self?.queue.async {
                guard let self else { return }
                if decline {
                    note("shell request \(request.id) declined")
                    return self.lookAtShellRequests { then(.success(.object(["outcome": .string("declined"), "notice": .null]))) }
                }
                if planted || written != nil {
                    let why = planted ? "an answer file appeared beside the request that this server didn't write"
                        : "its answer couldn't be recorded (\(written.map { "\($0)" } ?? ""))"
                    note("shell request \(request.id): not run: \(why)")
                    self.shellAnswers[request.id] = ShellAsk.Answer(state: .failed, at: Date(), why: "\(why): nothing ran")
                    return self.lookAtShellRequests { then(.failure(.refused("\(why): nothing ran"))) }
                }
                self.startShell(request, at: now, then: then)
            }
        }
    }

    /// Starts the request's shell session (the host's spawn), keeps what came of it (the shell the engine started, by
    /// the host's own answer) and looks again. On `queue`.
    private func startShell(_ request: ShellRequest, at: Date, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        var spawn = ShellAsk.spawnRequest(request)
        // A scratch node's hooks and tools keep to its root, as its sessions' do.
        if isScratch { spawn.env["VIBESWITCHER_HOME"] = root.path }
        let note = self.note
        link.spawn(spawn) { [weak self] result in
            guard let self else { return }
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
            self.queue.async {
                self.shellAnswers[request.id] = answer
                self.recordShellFile(answer, for: request.id)
                self.lookAtShellRequests { then(reply) }
            }
        }
    }

    /// Tells the asking session what became of its request (the engine's answer), once it reached it (or the session is
    /// gone). On `queue`.
    private func tellShell(_ request: ShellRequest, _ answer: ShellAsk.Answer) {
        guard let text = ShellAsk.message(request, answer), let session = UUID(uuidString: request.session),
              shellTelling.insert(request.id).inserted else { return }
        let note = self.note
        tell(text, from: .system("from New Shell"), session: session) { [weak self] delivery in
            guard let self else { return }
            self.shellTelling.remove(request.id)
            guard delivery != .notYet else { return }
            if delivery == .ended { note("shell request \(request.id): its session ended, so no one is told") }
            guard var now = self.shellAnswers[request.id], now.state == answer.state else { return }
            now.told = true
            self.shellAnswers[request.id] = now
            self.recordShellFile(now, for: request.id)
        }
    }

    /// Once the asker heard that its shell started: how the command ended in the shell the engine started (its id, from
    /// the host's answer to the spawn), once, when the host's list shows it, or that the shell went first. A shell the
    /// host doesn't list yet just after it started isn't called gone. On `queue`.
    private func tellShellEnd(_ request: ShellRequest, _ answer: ShellAsk.Answer, now: Date) {
        guard answer.awaitsEnd, answer.told, link.state == .connected, !shellTellingEnd.contains(request.id),
              let asker = UUID(uuidString: request.session) else { return }
        let session = answer.shell.flatMap(UUID.init(uuidString:)).flatMap { id in link.sessions.first { $0.id == id } }
        if session == nil, now.timeIntervalSince1970 - answer.at < Self.shellStartingFor { return }
        guard let text = ShellAsk.ending(request, answer, session: session) else { return }
        shellTellingEnd.insert(request.id)
        let note = self.note
        tell(text, from: .system("from New Shell"), session: asker) { [weak self] delivery in
            guard let self else { return }
            self.shellTellingEnd.remove(request.id)
            guard delivery != .notYet else { return }
            note("shell request \(request.id) ended: " + (session?.commandEnd.map { $0.ok ? "status 0" : "status \($0.status.map(String.init) ?? "not known")" } ?? "not captured")
                 + (delivery == .ended ? "; its asker's session ended, so no one is told" : "; told"))
            if var kept = self.shellAnswers[request.id], kept.awaitsEnd {
                kept.endTold = true
                self.shellAnswers[request.id] = kept
                self.recordShellFile(kept, for: request.id)
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

/// What a shell card won't show (the review of 2026-11-21): characters that draw as blank, or as nothing, which a
/// request could use to push part of its command out of the card's last screen or make two commands look alike.
public enum ShellCards {
    /// Whether `scalar` draws as blank or nothing: non-ASCII white space (U+00A0, U+2003, U+3000…), the Hangul fillers
    /// (U+115F, U+1160, U+3164, U+FFA0), the braille blank (U+2800), default-ignorable code points (U+034F, U+200B,
    /// U+E0100…) and variation selectors (U+FE0F…).
    public static func blank(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return false }
        let properties = scalar.properties
        return properties.isWhitespace || properties.isDefaultIgnorableCodePoint || properties.isVariationSelector
            || [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800].contains(scalar.value)
    }

    /// Why `request` isn't shown (nil: it may be): its command, label or folder holds a character that draws as blank.
    public static func blankLooking(_ request: ShellRequest) -> String? {
        for (name, text) in [("command", request.command), ("label", request.label), ("folder", request.cwd)] {
            if let scalar = text.unicodeScalars.first(where: blank) {
                return "its \(name) holds a character that draws as blank or nothing (U+\(String(format: "%04X", scalar.value))), "
                    + "which could hide part of it on the card: it wasn't shown, and nothing ran. File it again with plain spaces"
            }
        }
        return nil
    }

    /// How a shell card's answer is read, by `answerShell` and by the Mac's dialog alike (`Requests.approvalCard`): spaces
    /// and line breaks at its ends dropped, any case; `run` or `decline`, else nil (refused).
    public static func answerWord(_ text: String) -> String? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["run", "decline"].contains(word) ? word : nil
    }

    /// The command's size as the card and the code prompt say it: its lines and bytes.
    public static func size(_ command: String) -> String {
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(lines) line\(lines == 1 ? "" : "s"), \(command.utf8.count) bytes"
    }
}
