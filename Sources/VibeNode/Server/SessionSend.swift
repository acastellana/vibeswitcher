import Foundation
import VibeCore

/// A message `send` took for a session while a question, picker or menu was open on its screen (or while messages sent
/// before it waited): typed in once it closes, oldest first, as the app's composer holds one (`ChatSync.releaseHeld`).
/// Kept in the server's memory only (the user's words, never written down): it goes with its session, and with the
/// server. A session's live value lists them as `queued`.
public struct HeldSend: Equatable, Sendable {
    /// What is typed: the words, then the images' paths (`Requests.message(text:images:)`).
    public var message: String
    public var text: String
    public var images: [String]
    public var at: Date
    /// The `send` request's action id.
    public var action: String

    public var value: NodeWire.Value {
        .object(["text": .string(text), "images": .int(images.count), "at": .date(at), "action": .string(action)])
    }
}

/// `send` (the parity table's gap 1 and the composer's lane, 2026-11-20). On the engine's queue, as `handle` calls it.
extension Requests {
    /// The most images one message carries.
    static let imagesLimit = 10
    /// The most messages a session holds behind an open question.
    static let heldLimit = 20
    /// How often a session's screen is read while it holds messages.
    static let heldEvery: TimeInterval = 1
    /// How long a message's Enter waits for Claude Code to show its pasted images, then goes anyway (the app's
    /// `ChatSync.imageWait`: within the host's hold between a unit's parts, `InputOrder.holdLimit`, 10 s).
    static let imageWait: TimeInterval = 8
    /// The most characters a steered message (`--now`) carries: what a hook hands Claude inline (the app's
    /// `ComposerLimits.maxSteerCharacters`).
    static let steerLimit = 8_000

    /// `send` with `session`, `text` and `images` (absolute paths of image files, optional; text may be empty when there
    /// are some) (2026-11-20, the parity table's gap 1): the user's words typed into the session's agent the way the
    /// app's composer types them (`ComposerText.writes`: a bracketed paste, then Enter, as one unit of the host's:
    /// nothing else typed goes in between); attached images go as their quoted paths on lines of their own after the
    /// words (`message(text:images:)`, the app's `ComposerSend.message`), and the Enter waits until Claude Code's box
    /// shows them taken (it drops an Enter that comes while it reads them). A working agent takes it after its turn
    /// (Claude Code queues what's typed during one), as the app's ⌥↩ does; an idle one at once. With a question, a
    /// picker or a slash-command menu open on its screen (typed there, the words would go into it as keys), the message
    /// is held, as the app's composer holds it, and typed once that closes (`HeldSend`, `pumpHeld`); so is one sent
    /// while others wait, behind them. Refused, nothing typed: a session the host didn't start, a plain shell (no
    /// agent: the app's composer refuses it too), one whose agent left its terminal, a lead another one replaced
    /// (`vibeswitcher tell` reaches the live lead), an image that isn't one Claude Code reads (png, jpg, jpeg, gif,
    /// webp) or isn't a file. The screen is read in the unit's gate, right before its first write, so nothing typed
    /// meanwhile can come between. The reply names the session, its terminal, whether its agent was working,
    /// `queued` for a held message (and why it `waits`), and what a `/` command `opened` on the screen (a picker). A page's draft for the session that is the message sent goes.
    ///
    /// With `now` (`vibeswitcher send SESSION TEXT --now`, 2026-11-20, the app's ↩ while its agent works): a Claude agent
    /// working by its hooks gets it mid-turn, through its steer inbox as the user's (`LeadEngine.steerAsUser`), at its
    /// next step and without stopping (`steered`); at most `steerLimit` characters. One between turns gets it typed, as
    /// above (the app does the same), and a Codex agent too (it takes typed input mid-turn as a steer). The reply names
    /// the `agent`.
    func send(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let text = (request.args?["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let images = request.args?["images"]?.array?.map { $0.string ?? "" } ?? []
        let now = request.args?["now"]?.bool == true
        guard !text.isEmpty || !images.isEmpty else { return reply(.init(re: request.id, error: .init(.badArgs, "send needs text or images"))) }
        guard images.count <= Self.imagesLimit else {
            return reply(.init(re: request.id, error: .init(.badArgs, "at most \(Self.imagesLimit) images a message")))
        }
        if let odd = images.first(where: { Self.imageRefusal($0, onDisk: false) != nil }) {
            return reply(.init(re: request.id, error: .init(.badArgs, Self.imageRefusal(odd, onDisk: false) ?? "")))
        }
        let message = Self.message(text: text, images: images)
        guard message.utf8.count <= Self.sendLimit else {
            return reply(.init(re: request.id, error: .init(.badArgs, "too long to type into a terminal (at most \(Self.sendLimit / 1024) KB): "
                                                            + "save it to a file and mention the file instead")))
        }
        guard !now || message.count <= Self.steerLimit else {
            return reply(.init(re: request.id, error: .init(.badArgs, "too long to steer (at most \(Self.steerLimit) characters, what a hook hands "
                                                            + "Claude at once): send it without --now (it goes after the turn), or save it to a file and mention the file")))
        }
        let session: HostSession
        switch hostedSession(request.args?["session"]?.string, for: "send", id: request.id) {
        case .failure(let refusal): return reply(refusal)
        case .found(let found): session = found
        }
        let short = String(session.id.uuidString.lowercased().prefix(8))
        guard HostedAgents.agent(of: session) != nil else {
            return reply(.init(re: request.id, error: .init(.refused, "session \(short) is a shell, not an agent's: send types only into Claude or Codex")))
        }
        guard !isReplacedLead(session) else {
            return reply(.init(re: request.id, error: .init(.refused, "session \(short) is a lead another one replaced: what you type there reaches "
                                                            + "no live lead (`vibeswitcher tell FOLDER TEXT` tells the running one)")))
        }
        guard !now || engine != nil else {
            return reply(.init(re: request.id, error: .init(.refused, "this server has no engine to steer through: send it without --now")))
        }
        let working = sessions?.sessions.first { $0.hostID == session.id }?.status == .working
        let (queue, drafts) = (self.queue, sessionDrafts)
        let id = NodeIds.session(host: session.id)
        let held = HeldSend(message: message, text: text, images: images, at: Date(), action: request.action ?? request.id)
        let answer = { (queued: String?, opened: String?, steered: Bool, answered: String?) in
            // The page's draft it was is sent (or waits to be): it goes from beside the session.
            if let draft = drafts.values[id], draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text, draft.images == images {
                drafts.send(id, nil)
            }
            var result: [String: NodeWire.Value] = ["session": .string(id), "terminal": .string(session.tty), "working": .bool(working),
                                                    "characters": .int(message.count), "queued": .bool(queued != nil)]
            if let queued { result["waits"] = .string(queued) }
            if let opened { result["opened"] = .string(opened) }
            if now { result["steered"] = .bool(steered) }
            if let answered { result["answered"] = .string(answered) }
            if let agent = HostedAgents.agent(of: session) { result["agent"] = .string(agent.rawValue) }
            reply(.init(re: request.id, result: .object(result)))
        }
        // Off the engine's queue: the agent's process is read from /proc, the images from the disk.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pid = HostedAgents.agentPid(of: session)
            let missing = images.lazy.compactMap { Self.imageRefusal($0, onDisk: true) }.first
            queue.async {
                guard let self else { return }
                if let missing { return reply(.init(re: request.id, error: .init(.refused, missing))) }
                guard let pid else {
                    return reply(.init(re: request.id, error: .init(.refused, "no agent runs in session \(short)'s terminal now (it quit, or ended): nothing typed")))
                }
                let typeIt = { [weak self] in
                    guard let self else { return }
                    // Behind the messages it holds already, in the order sent.
                    if !(self.heldSends.values[id] ?? []).isEmpty {
                        guard self.hold(held, for: session) else { return self.refuseHeldFull(request, short, reply) }
                        return answer("messages sent before it wait in session \(short)", nil, false, nil)
                    }
                    self.typeIn(held, into: session) { outcome in
                        switch outcome {
                        case .typed:
                            // A command may open a picker (`/model`, `/resume`): the reply says so, as the app's composer
                            // watches the screen for one.
                            guard text.hasPrefix("/"), images.isEmpty else { return answer(nil, nil, false, nil) }
                            Self.watchForMenu(session.id, link: self.link, queue: queue, until: Date().addingTimeInterval(Self.pickerWait)) { answer(nil, $0, false, nil) }
                        case .menuOpen(let open):
                            // A question that takes typed words: they go in as its free-text answer, as the app's composer
                            // sends them; else held until it closes.
                            self.answerFreeText(held, in: session) { outcome in
                                switch outcome {
                                case .answered(let field): answer(nil, nil, false, field)
                                case .partly:
                                    reply(.init(re: request.id, error: .init(.refused, "session \(short): its question's answer stopped after your words "
                                                                              + "went in (the host didn't take the rest): look at its terminal before you send it again")))
                                case .notTyped:
                                    guard self.hold(held, for: session) else { return self.refuseHeldFull(request, short, reply) }
                                    answer(open, nil, false, nil)
                                }
                            }
                        case .refused(let why):
                            reply(.init(re: request.id, error: .init(.refused, "session \(short): \(why)")))
                        }
                    }
                }
                // `--now` to a Claude agent: through its hook while it works (the app's steer). Codex takes what's typed
                // during its turn as a steer itself, so it's typed, as the app types it.
                guard now, HostedAgents.agent(of: session) == .claude, let engine = self.engine else { return typeIt() }
                engine.steerAsUser(message, session: session, agentPid: pid) { outcome in
                    switch outcome {
                    case .steered:
                        answer(nil, nil, true, nil)
                    case .idle:
                        // Its turn is over (or its hooks say nothing): a steer would wait for a step that never comes.
                        self.note("send to session \(short): --now, but its agent isn't working by its hooks: typed in instead")
                        typeIt()
                    case .refused(let why):
                        reply(.init(re: request.id, error: .init(.refused, "session \(short): \(why)")))
                    }
                }
            }
        }
    }

    private func refuseHeldFull(_ request: NodeWire.Request, _ short: String, _ reply: (NodeWire.Reply) -> Void) {
        reply(.init(re: request.id, error: .init(.refused, "session \(short) holds \(Self.heldLimit) messages already, waiting for its question: "
                                                 + "answer it first (`vibeswitcher reply`), or close what is open in its terminal")))
    }

    /// The message typed: the words, then a blank line and each image's quoted path on a line of its own (Claude Code
    /// takes a pasted image path for one when it's a line of its own; the app's `ComposerSend.message`).
    static func message(text: String, images: [String]) -> String {
        let paths = images.map(RecentProjects.shellQuote).joined(separator: "\n")
        return [text, paths].filter { !$0.isEmpty }.joined(separator: text.isEmpty ? "" : "\n\n")
    }

    /// Why `path` can't go as an attached image (nil: it can): not absolute, a character its quoting or Claude Code's
    /// reading of a pasted path would break on (a quote, a line break), not an image Claude Code reads by its
    /// extension; with `onDisk`, not a file.
    static func imageRefusal(_ path: String, onDisk: Bool) -> String? {
        let shown = ConfigSeal.inert(path, limit: 200)
        guard path.hasPrefix("/") else { return "an image is given by its absolute path, not \(shown)" }
        guard !path.contains(where: { $0 == "'" || $0 == "\"" || $0.isNewline || $0 == "\u{0}" }) else {
            return "the image path \(shown) has a quote or a line break in it, which Claude Code can't read pasted: copy or rename it"
        }
        guard ComposerText.pastedImageExtensions.contains((path as NSString).pathExtension.lowercased()) else {
            return "\(shown) isn't an image Claude Code reads (png, jpg, jpeg, gif, webp)"
        }
        guard onDisk else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue,
              FileManager.default.isReadableFile(atPath: path) else { return "no image file \(shown)" }
        return nil
    }

    enum TypeOutcome: Sendable {
        case typed
        /// Not typed: what's open on the screen.
        case menuOpen(String)
        case refused(String)
    }

    /// `held` typed into `session` as one unit whose gate reads the screen right before the first write (a menu open:
    /// nothing typed, `menuOpen`), and whose Enter waits for its images to show taken. `done` on the queue.
    func typeIn(_ held: HeldSend, into session: HostSession, done: @escaping (TypeOutcome) -> Void) {
        let (link, note, queue) = (self.link, self.note, self.queue)
        let short = String(session.id.uuidString.lowercased().prefix(8))
        let stopped = Locked<TypeOutcome?>(nil)
        let writes = ComposerText.writes(held.message, bracketed: true)
        let images = held.images
        link.type(writes, into: session.id, gate: { index, go in
            if index > 0 {
                guard !images.isEmpty else { return go(true) }
                return Self.waitForImages(images, in: session.id, link: link, queue: queue, until: Date().addingTimeInterval(Self.imageWait), go)
            }
            link.screen(session.id) { screen in
                guard let screen else {
                    stopped.set(.refused("its screen couldn't be read, so whether a question is open there can't be told: try again"))
                    return go(false)
                }
                if let open = Self.openMenu(screen) {
                    stopped.set(.menuOpen(open))
                    return go(false)
                }
                go(true)
            }
        }, confirmed: { typed in
            // Nothing of the text in the log: it is the user's words.
            let outcome: TypeOutcome = typed ? .typed : stopped.get() ?? .refused("the host didn't take all of it: it may not have gone in")
            switch outcome {
            case .typed: note("send to session \(short): typed in, \(held.message.count) characters, \(images.count) image(s)")
            case .menuOpen(let open): note("send to session \(short): held, \(open)")
            case .refused(let why): note("send to session \(short): not typed: \(why)")
            }
            done(outcome)
        })
    }

    /// How long the screen is watched for a picker after a `/` command went in.
    static let pickerWait: TimeInterval = 2

    /// Answers `found` with what opened on the session's screen (`openMenu`), or nil at `deadline`.
    static func watchForMenu(_ id: UUID, link: HostLink, queue: DispatchQueue, until deadline: Date, _ found: @escaping (String?) -> Void) {
        link.screen(id) { screen in
            queue.async {
                if let screen, let open = openMenu(screen) { return found(open) }
                guard Date() < deadline else { return found(nil) }
                queue.asyncAfter(deadline: .now() + 0.2) { watchForMenu(id, link: link, queue: queue, until: deadline, found) }
            }
        }
    }

    /// Answers `go` once the session's input box shows `images` taken (`ComposerText.imagesTaken`), or at `deadline`
    /// (the app's `ChatSync.waitForImages`).
    static func waitForImages(_ images: [String], in id: UUID, link: HostLink, queue: DispatchQueue, until deadline: Date,
                              _ go: @escaping (Bool) -> Void) {
        link.screen(id) { screen in
            queue.async {
                if let screen, case .draft(let typed) = LeadDelivery.box(in: screen), ComposerText.imagesTaken(typed, images: images) {
                    return go(true)
                }
                guard Date() < deadline else { return go(true) }
                queue.asyncAfter(deadline: .now() + 0.1) { waitForImages(images, in: id, link: link, queue: queue, until: deadline, go) }
            }
        }
    }

    // MARK: The question's free-text answer

    /// `held`'s words typed as the free-text answer of the question open on `session`'s screen, when it takes one (an
    /// option that takes typed words, `SessionPrompt.takesText`, the app's free-text row; not a multi-select, whose
    /// boxes are ticked in its terminal), as the app's composer sends a message then (`ChatSync.type`: `choose(field,
    /// typing:)`). Only words: not a `/` command (a command isn't an answer) nor images. As `session.reply` types an
    /// answer: one unit whose gate reads the screen right before the first key and goes only while the same question
    /// shows with its cursor where it was, and whose words wait for the cursor on the option. `done` with the option
    /// answered; `notTyped` when the words didn't go in (the message is then held, as before); `partly` when they did
    /// and the rest didn't (never typed again). On `queue`.
    func answerFreeText(_ held: HeldSend, in session: HostSession, done: @escaping (FreeTextOutcome) -> Void) {
        guard !held.text.isEmpty, held.images.isEmpty, !held.text.hasPrefix("/") else { return done(.notTyped) }
        let (link, queue, note) = (self.link, self.queue, self.note)
        let short = String(session.id.uuidString.lowercased().prefix(8))
        link.screen(session.id) { screen in
            queue.async {
                guard let screen, let menu = SessionPrompt.menu(on: screen), !menu.multiSelect,
                      let index = menu.options.indices.first(where: { SessionPrompt.takesText(menu, $0) }) else { return done(.notTyped) }
                let field = menu.options[index]
                let replacing = field.lowercased().hasPrefix("type something") ? 0 : field.count
                let writes = menu.keys(toChoose: index, typing: held.text, replacing: replacing)
                let moves = abs(index - menu.selected)
                // The write that carries the words: after the arrows and the erase.
                let wordsAt = moves + (replacing > 0 ? 1 : 0)
                let wordsWent = Locked(false)
                link.type(writes, into: session.id, gate: { step, go in
                    let going = { (ok: Bool) in
                        if ok, step >= wordsAt { wordsWent.set(true) }
                        go(ok)
                    }
                    if step == 0 {
                        return link.screen(session.id) { now in
                            guard now.flatMap(SessionPrompt.menu(on:)) == menu else { return go(false) }
                            if moves > 0 { return go(true) }
                            going(true)
                        }
                    }
                    guard step == moves else { return going(true) }
                    Self.cursorReaches(index, of: menu, in: session.id, link: link, since: Date(), done: going)
                }, confirmed: { typed in
                    queue.async {
                        let outcome: FreeTextOutcome = typed ? .answered(field) : wordsWent.get() ? .partly : .notTyped
                        note("send to session \(short): " + (typed ? "typed in as its question's free-text answer"
                                                              : wordsWent.get() ? "its question's answer stopped after the words" : "not typed as its question's answer: held"))
                        done(outcome)
                    }
                })
            }
        }
    }

    enum FreeTextOutcome: Equatable, Sendable {
        case answered(String)
        case notTyped
        case partly
    }

    // MARK: Held messages

    /// `held` kept for `session`, behind any it holds; false when it holds `heldLimit` already. The session's screen is
    /// then read every `heldEvery` until they're all typed in.
    @discardableResult
    func hold(_ held: HeldSend, for session: HostSession) -> Bool {
        let id = NodeIds.session(host: session.id)
        let list = heldSends.values[id] ?? []
        guard list.count < Self.heldLimit else { return false }
        heldSends.send(id, list + [held])
        recordHeld(held, session: session.id)
        queue.asyncAfter(deadline: .now() + Self.heldEvery) { [weak self] in self?.pumpHeld(session.id) }
        return true
    }

    /// The oldest message `hostID`'s session holds typed in, once nothing is open on its screen, then the next; again
    /// every `heldEvery` while one is open, or while its agent isn't running (they're never typed into a shell). Dropped,
    /// saying so in the log: those of a session that ended, and one the host didn't take whole (it may have gone in
    /// part: never typed twice). One pump a session at a time.
    func pumpHeld(_ hostID: UUID) {
        let id = NodeIds.session(host: hostID)
        guard !pumping.contains(hostID), let first = heldSends.values[id]?.first else { return }
        let short = String(hostID.uuidString.lowercased().prefix(8))
        guard let session = link.sessions.first(where: { $0.id == hostID && $0.isLive }) else {
            let gone = (heldSends.values[id] ?? []).map(\.action)
            note("send to session \(short): \(gone.count) held message(s) dropped: the session ended")
            heldSends.send(id, nil)
            heldGone(gone)
            return
        }
        pumping.insert(hostID)
        let later = { [weak self] (after: TimeInterval) in
            guard let self else { return }
            self.pumping.remove(hostID)
            self.queue.asyncAfter(deadline: .now() + after) { [weak self] in self?.pumpHeld(hostID) }
        }
        let queue = self.queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let runs = HostedAgents.agentPid(of: session) != nil
            queue.async {
                guard let self else { return }
                guard runs else { return later(Self.heldEvery) }
                self.typeIn(first, into: session) { outcome in
                    switch outcome {
                    case .menuOpen:
                        later(Self.heldEvery)
                    case .typed, .refused:
                        if case .refused(let why) = outcome { self.note("send to session \(short): a held message dropped: \(why)") }
                        let rest = Array((self.heldSends.values[id] ?? []).drop { $0.action == first.action })
                        self.heldSends.send(id, rest.isEmpty ? nil : rest)
                        self.heldGone([first.action])
                        // The next once the agent has taken this one's Enter.
                        later(0.5)
                    }
                }
            }
        }
    }
}
