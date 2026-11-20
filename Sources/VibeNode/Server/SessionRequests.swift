import Foundation
import VibeCore

/// Driving an ordinary session from the node (the parity table's gaps 1, 3 and 6, 2026-11-20): `send` types the user's
/// words into a session the host runs, as the app's composer does. Each is a user's-voice kind (`NodeWire.kinds`), so
/// `Requests.handle` judges the voice (S3: never a session's process, nor branch code, nor the lead's tool server, nor a
/// web page) and records the request in the vault before it gets here; its typed code is the command line's, as
/// `tell`'s is (no card). On the engine's queue, as `handle` calls them.
extension Requests {
    /// The most a message may be, in bytes (the app's `ComposerLimits.maxBytes`): a larger one doesn't fit the host's
    /// frames once encoded.
    static let sendLimit = 200 * 1024

    /// A session the host runs and that is live, named by `wanted`: this node's id for it (`local:<uuid>`), its host
    /// id, or a prefix of 4 or more of that id that only one live session has; else the reply that refuses it (a
    /// session the host didn't start is never typed into, and the refusal says so).
    func hostedSession(_ wanted: String?, for kind: String, id: String) -> NamedSession {
        guard let given = wanted?.trimmingCharacters(in: .whitespaces).lowercased(), !given.isEmpty else {
            return .failure(.init(re: id, error: .init(.badArgs, "\(kind) needs session")))
        }
        let shown = ConfigSeal.inert(given, limit: 80)
        let bare = given.hasPrefix(NodeIds.node + ":") ? String(given.dropFirst(NodeIds.node.count + 1)) : given
        // A session in one of the user's own terminals: listed, and never typed into (`NodeSessions`' `hosted: false`).
        if sessions?.sessions.contains(where: { $0.hostID == nil && NodeSessions.id(of: $0).lowercased() == given }) == true {
            return .failure(.init(re: id, error: .init(.refused, "session \(shown) runs in a terminal of yours, not in the node's host: "
                                                       + "VibeSwitcher only drives the sessions it started")))
        }
        let live = link.sessions.filter(\.isLive)
        let matching: [HostSession]
        if let exact = UUID(uuidString: bare) {
            matching = live.filter { $0.id == exact }
        } else if bare.count >= 4, bare.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            matching = live.filter { $0.id.uuidString.lowercased().hasPrefix(bare) }
        } else {
            matching = []
        }
        guard matching.count < 2 else {
            return .failure(.init(re: id, error: .init(.badArgs, "\(matching.count) sessions start with \(shown): give more of its id")))
        }
        guard let session = matching.first else {
            let ended = UUID(uuidString: bare).map { wanted in link.sessions.contains { $0.id == wanted } } ?? false
            return .failure(.init(re: id, error: .init(.gone, ended ? "session \(shown) has ended"
                                                       : "no live session \(shown) on this node (`vibeswitcher status` lists them)")))
        }
        return .found(session)
    }

    /// A session found, or the reply that refuses it.
    enum NamedSession {
        case found(HostSession)
        case failure(NodeWire.Reply)
    }

    /// Whether `session` is a live lead that another lead of its project replaced (`LeadStore.Lead.replaced`): the app
    /// routes what's typed there to the live lead, never into it.
    func isReplacedLead(_ session: HostSession) -> Bool {
        engine?.leads.leads.values.contains { $0.replaced[session.id] != nil } ?? false
    }

    // MARK: send

    /// `send` with `session` and `text` (2026-11-20, the parity table's gap 1): the user's words typed into the session's
    /// agent the way the app's composer types them (`ComposerText.writes`: a bracketed paste, then Enter 60 ms later, as
    /// one unit of the host's: nothing else typed goes in between). A working agent takes them after its turn (Claude
    /// Code queues what's typed during one), as the app's ⌥↩ does; an idle one at once. Refused, nothing typed: a
    /// session the host didn't start, a plain shell (no agent: the app's composer refuses it too), one whose agent left
    /// its terminal, a lead another one replaced (`vibeswitcher tell` reaches the live lead), and one with a question,
    /// a picker or a slash-command menu open on its screen (typed there, the words would go into it as keys: the app
    /// holds the message until it closes; here the user answers it first, `vibeswitcher reply`). That screen is read in
    /// the unit's gate, right before its first write, so nothing typed meanwhile can come between. The reply names the
    /// session, its terminal, and whether its agent was working. A page's draft for the session that is the text sent goes.
    func send(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let text = request.args?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "send needs text")))
        }
        guard text.utf8.count <= Self.sendLimit else {
            return reply(.init(re: request.id, error: .init(.badArgs, "too long to type into a terminal (at most \(Self.sendLimit / 1024) KB): "
                                                            + "save it to a file and mention the file instead")))
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
        let working = sessions?.sessions.first { $0.hostID == session.id }?.status == .working
        let (link, queue, note, drafts) = (self.link, self.queue, self.note, sessionDrafts)
        let id = NodeIds.session(host: session.id)
        // Off the engine's queue: the agent's process is read from /proc.
        DispatchQueue.global(qos: .userInitiated).async {
            let runs = HostedAgents.agentPid(of: session) != nil
            queue.async {
                guard runs else {
                    return reply(.init(re: request.id, error: .init(.refused, "no agent runs in session \(short)'s terminal now (it quit, or ended): nothing typed")))
                }
                let stopped = Locked<String?>(nil)
                let writes = ComposerText.writes(text, bracketed: true)
                link.type(writes, into: session.id, gate: { index, go in
                    guard index == 0 else { return go(true) }
                    link.screen(session.id) { screen in
                        guard let screen else {
                            stopped.set("its screen couldn't be read, so whether a question is open there can't be told: try again")
                            return go(false)
                        }
                        if let open = Self.openMenu(screen) {
                            stopped.set(open)
                            return go(false)
                        }
                        go(true)
                    }
                }, confirmed: { typed in
                    // Nothing of the text in the log: it is the user's words.
                    note("send to session \(short): \(typed ? "typed in, \(text.count) characters" : "not typed: \(stopped.get() ?? "the host didn't take it")")")
                    guard typed else {
                        let why = stopped.get().map { "session \(short): \($0)" } ?? "the host didn't take all of it into session \(short): it may not have gone in"
                        return reply(.init(re: request.id, error: .init(.refused, why)))
                    }
                    // The page's draft it was is sent: it goes from beside the session.
                    if drafts.values[id]?.text == text { drafts.send(id, nil) }
                    reply(.init(re: request.id, result: .object([
                        "session": .string(id), "terminal": .string(session.tty),
                        "working": .bool(working), "characters": .int(text.count),
                    ])))
                })
            }
        }
    }

    /// What's open on `screen` that takes keys instead of the agent's prompt box, said for a refusal: an agent's
    /// question (a numbered menu: a permission prompt, a question, a plan to approve), a local command's picker or
    /// dialog, or the slash-command menu. Nil when none is (`ScreenMenu`'s readers, the app's `onScreenNow`).
    static func openMenu(_ screen: String) -> String? {
        let lines = Platform.lines(screen.replacingOccurrences(of: "\u{0}", with: " "))
        if ScreenMenu.parse(lines) != nil {
            return "a question is open on its screen: answer it first (`vibeswitcher reply SESSION CHOICE`), then send again"
        }
        if ScreenMenu.parsePicker(lines) != nil || ScreenMenu.parseCommands(lines) != nil {
            return "a picker or menu is open on its screen: close it in the session's terminal (Esc), then send again"
        }
        return nil
    }
}

// MARK: session.new, session.end

extension Requests {
    /// How long `session.end` waits for the session it ended to be gone before it replies.
    static let endWait: TimeInterval = 10
    /// A model name `session.new` passes to Claude's `--model`: a word of letters, digits and `. _ : - [ ]` (`opus`,
    /// `claude-opus-5-5`, `sonnet[1m]`), never anything a shell reads otherwise.
    static func isModelName(_ model: String) -> Bool {
        model.count <= 64 && model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]*$"#, options: .regularExpression) != nil
    }

    /// The labels the app gives an ordinary session (its built-in presets' names): never a role's (`LeadTeams.role`).
    static let sessionLabels = ["claude": "Claude", "shell": "Shell"]

    /// `session.new` with `folder` (absolute), `agent` (`claude`, the default, or `shell`) and `model` (Claude's, optional)
    /// (2026-11-20, the parity table's gap 3): an ordinary session started in the node's host, as the app's New Session
    /// starts its built-in Claude or Shell preset: labelled as one, the agent recorded with it (`HostedAgents`), 120 by 36.
    /// Claude is the program the node's `claude` link names (`NodePreflight`, never a PATH or a login shell: EN-D13),
    /// with `--model` when given; a shell is the host's plain shell. Nothing answers its first questions (Claude's trust
    /// question shows as the session's prompt: `vibeswitcher reply`). Refused: a folder that isn't one, a model name
    /// that isn't a word, Claude with no `claude` link.
    func newSession(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let folder = request.args?["folder"]?.string, folder.hasPrefix("/") else {
            return reply(.init(re: request.id, error: .init(.badArgs, "session.new needs folder, an absolute path")))
        }
        let agent = request.args?["agent"]?.string ?? "claude"
        guard let label = Self.sessionLabels[agent] else {
            return reply(.init(re: request.id, error: .init(.badArgs, "session.new's agent is claude or shell, not \(ConfigSeal.inert(agent, limit: 40))")))
        }
        let model = request.args?["model"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if let model {
            guard agent == "claude" else { return reply(.init(re: request.id, error: .init(.badArgs, "a shell takes no model"))) }
            guard Self.isModelName(model) else {
                return reply(.init(re: request.id, error: .init(.badArgs, "\(ConfigSeal.inert(model, limit: 64)) isn't a model name (letters, digits, . _ : - [ ])")))
            }
        }
        let claudeLink = engine?.preflight.claudeLink ?? NodePreflight.claudeLink(root: root)
        let scratch = !VibePaths.isAccountRoot(root, accountHome: VibePaths.accountHome)
        let (link, queue, note, nodeRoot) = (self.link, self.queue, self.note, root)
        // Off the queue: the folder and the link are read from the disk.
        DispatchQueue.global(qos: .userInitiated).async {
            var isFolder: ObjCBool = false
            let standard = (folder as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: standard, isDirectory: &isFolder), isFolder.boolValue else {
                return queue.async { reply(.init(re: request.id, error: .init(.refused, "\(ConfigSeal.inert(folder, limit: 200)) isn't a folder"))) }
            }
            var command: String?
            if agent == "claude" {
                let found = NodePreflight.resolve(claudeLink)
                guard let program = found.path else {
                    return queue.async { reply(.init(re: request.id, error: .init(.refused, found.why ?? "no claude for this node"))) }
                }
                command = RecentProjects.shellQuote(program) + (model.map { " --model " + RecentProjects.shellQuote($0) } ?? "")
            }
            // A scratch node's hooks and tools keep to its root, as its leads' do.
            let environment = scratch ? ["VIBESWITCHER_HOME": nodeRoot.path] : [:]
            let spawn = SpawnRequest(cwd: standard, command: command, env: environment, cols: 120, rows: 36, keepShell: false,
                                     label: label, agent: agent == "claude" ? "claude" : nil)
            queue.async {
                link.spawn(spawn) { result in
                    queue.async {
                        switch result {
                        case .success(let session):
                            note("session.new: \(label) started in session \(session.id.uuidString.prefix(8)) (\(session.tty))")
                            reply(.init(re: request.id, result: .object([
                                "session": .string(NodeIds.session(host: session.id)), "terminal": .string(session.tty),
                                "agent": .string(agent), "folder": .string(standard), "model": model.map(NodeWire.Value.string) ?? .null,
                            ])))
                        case .failure(let failure):
                            reply(.init(re: request.id, error: .init(.refused, "the session host didn't start it: \(failure.message)")))
                        }
                    }
                }
            }
        }
    }

    /// `session.end` with `session` (2026-11-20, the parity table's gap 3): the app's End Session, for a session the
    /// node's host started: the host ends it (`HostLink.kill`), and the reply comes once it's gone (at most `endWait`;
    /// `ended` false: still live then). Refused, nothing ended: a session the host didn't start, a lead (`vibeswitcher
    /// lead FOLDER --replace` starts a new one; `stop` ends every session) and a lead's worker or verifier (its lead
    /// ends them: `vibeswitcher tell FOLDER TEXT` asks it).
    func endSession(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let session: HostSession
        switch hostedSession(request.args?["session"]?.string, for: "session.end", id: request.id) {
        case .failure(let refusal): return reply(refusal)
        case .found(let found): session = found
        }
        let short = String(session.id.uuidString.lowercased().prefix(8))
        let folder = ConfigSeal.inert(session.cwd, limit: 200)
        switch LeadTeams.role(label: session.label) {
        case .lead?:
            return reply(.init(re: request.id, error: .init(.refused, "session \(short) is a project's lead: `vibeswitcher lead \(folder) --replace` "
                                                            + "starts a new lead in its place, and `vibeswitcher stop` ends every session")))
        case .worker?, .verifier?:
            return reply(.init(re: request.id, error: .init(.refused, "session \(short) is on a lead's team: its lead ends it once its task is over "
                                                            + "(`vibeswitcher tell FOLDER TEXT` asks the lead)")))
        case nil:
            break
        }
        let waiting = Waiting()
        let finish = { (ended: Bool) in
            guard !waiting.answered else { return }
            waiting.answered = true
            waiting.watch = nil
            reply(.init(re: request.id, result: .object(["session": .string(NodeIds.session(host: session.id)),
                                                         "terminal": .string(session.tty), "ended": .bool(ended)])))
        }
        let gone = { [link] in !link.sessions.contains { $0.id == session.id && $0.isLive } }
        waiting.watch = link.changes.subscribe(on: queue) { _ in if gone() { finish(true) } }
        queue.asyncAfter(deadline: .now() + Self.endWait) { finish(gone()) }
        note("session.end: ending session \(short) (\(session.tty))")
        link.kill(session.id)
    }
}

// MARK: session.reply

extension Requests {
    /// `session.reply` with `session`, `choice` (an option's number, from 1), `text` (for a free-text option only) and
    /// `question` (the question as the user was shown it: `prompt.question` of the session's value, optional)
    /// (2026-11-20, the parity table's gap 6): the session's own question answered as the app's answer card answers it
    /// (`ChatSync.keys`: arrows from its cursor to the option, then Enter; for free text, the words then Enter). The
    /// screen is read, the question found there (`SessionPrompt.menu(on:)`), and the keys typed as one unit of the host's whose
    /// gate reads the screen again right before the first key: unless the same question shows with its cursor where it
    /// was, nothing is typed. Refused, nothing typed: a session the host didn't start, a shell, no question on its
    /// screen, a question other than the one shown (`question`), a choice it hasn't, a multi-select (its boxes are
    /// ticked one by one: answer it in its terminal), and words for an option that takes none (or none for one that
    /// does).
    func replySession(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let choice = request.args?["choice"]?.int, choice >= 1 else {
            return reply(.init(re: request.id, error: .init(.badArgs, "session.reply needs choice, an option's number from 1")))
        }
        let text = request.args?["text"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let text, text.utf8.count > Self.sendLimit {
            return reply(.init(re: request.id, error: .init(.badArgs, "too long to type as an answer")))
        }
        let shown = request.args?["question"]?.string
        let session: HostSession
        switch hostedSession(request.args?["session"]?.string, for: "session.reply", id: request.id) {
        case .failure(let refusal): return reply(refusal)
        case .found(let found): session = found
        }
        let short = String(session.id.uuidString.lowercased().prefix(8))
        guard HostedAgents.agent(of: session) != nil else {
            return reply(.init(re: request.id, error: .init(.refused, "session \(short) is a shell: it asks no agent's questions")))
        }
        let (link, queue, note) = (self.link, self.queue, self.note)
        let refuse = { (why: String) in reply(.init(re: request.id, error: .init(.refused, "session \(short): \(why)"))) }
        link.screen(session.id) { screen in
            queue.async {
                guard let screen, let menu = SessionPrompt.menu(on: screen) else { return refuse("no question is open on its screen") }
                if let shown, shown != menu.question {
                    return refuse("the question on its screen isn't the one you were shown; it asks now: " + ConfigSeal.inert(menu.question, limit: 400))
                }
                guard !menu.multiSelect else { return refuse("its question takes several ticks: answer it in the session's terminal") }
                let index = choice - 1
                guard menu.options.indices.contains(index) else {
                    return refuse("its question has \(menu.options.count) options, not \(choice)")
                }
                let writes: [HostInput.Write]
                if SessionPrompt.takesText(menu, index) {
                    guard let text else { return refuse("option \(choice) takes your words: give them after the choice") }
                    writes = menu.keys(toChoose: index, typing: text)
                } else {
                    guard text == nil else { return refuse("option \(choice) takes no words (\(ConfigSeal.inert(menu.options[index], limit: 80)))") }
                    writes = menu.keys(toChoose: index)
                }
                let stopped = Locked<String?>(nil)
                link.type(writes, into: session.id, gate: { step, go in
                    guard step == 0 else { return go(true) }
                    link.screen(session.id) { now in
                        guard let now, SessionPrompt.menu(on: now) == menu else {
                            stopped.set("its question changed or was answered meanwhile: nothing typed")
                            return go(false)
                        }
                        go(true)
                    }
                }, confirmed: { typed in
                    note("session.reply to session \(short): \(typed ? "option \(choice) typed" : "not typed: \(stopped.get() ?? "the host didn't take it")")")
                    guard typed else { return refuse(stopped.get() ?? "the host didn't take all of the keys: the answer may not have gone in") }
                    reply(.init(re: request.id, result: .object([
                        "session": .string(NodeIds.session(host: session.id)), "terminal": .string(session.tty),
                        "choice": .int(choice), "option": .string(menu.options[index]), "question": .string(menu.question),
                    ])))
                })
            }
        }
    }
}

// MARK: session.draft, session.draft.clear

extension Requests {
    /// `session.draft` with `session` (the node's whole id for it, as a page holds it) and `text`, and
    /// `session.draft.clear` with `session`, from a web page whose token drafts (2026-11-20, the parity table's gap 1):
    /// the message the page's composer left for the session, kept beside it (`sessionDrafts`, the session's `draft`) or
    /// taken off, and told to nobody, as a card's draft is (`draft`, LW-D6): nothing is typed, nothing recorded.
    /// `vibeswitcher send SESSION` types it, in the user's voice. Only for a session the host started (one in a
    /// terminal of the user's is never typed into); a session that's gone is `gone`. The reply carries `applied`, the
    /// `sessions` stream's `seq` with the change in it (two turns later: a card draft's one, and the merge's). `draft`'s preamble (the
    /// action id, a repeat answered as before, a stopping node) came first.
    func sessionDraft(_ request: NodeWire.Request, action: String, done: @escaping (NodeWire.Reply) -> Void) {
        guard let id = request.args?["session"]?.string, !id.isEmpty else {
            return done(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs session")))
        }
        guard let session = sessions?.sessions.first(where: { NodeSessions.id(of: $0) == id }) else {
            return done(.init(re: request.id, error: .init(.gone, "no session \(ConfigSeal.inert(id, limit: 80)) on this node")))
        }
        guard session.hostID != nil else {
            return done(.init(re: request.id, error: .init(.refused, "that session runs in a terminal of yours: VibeSwitcher only types into the sessions it started")))
        }
        if request.kind == "session.draft" {
            guard let text = request.args?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return done(.init(re: request.id, error: .init(.badArgs, "session.draft needs text")))
            }
            guard text.utf8.count <= Self.sendLimit else {
                return done(.init(re: request.id, error: .init(.badArgs, "a message is at most \(Self.sendLimit / 1024) KB")))
            }
            sessionDrafts.send(id, SessionDraft(text: text, at: Date(), action: action))
        } else {
            sessionDrafts.send(id, nil)
        }
        // Nothing of the text in the log: it is the user's words.
        note("\(request.kind) on \(id) from a web page (action \(action)): kept beside the session, told to nobody")
        // Two turns: the draft reaches the merged values (`SessionLiveValues`) in one, and the stream in the next.
        queue.async { [weak self] in
            self?.queue.async {
                guard let self else { return }
                done(.init(re: request.id, result: .object(["applied": .object(["sessions": .int(self.liveSeq?("sessions") ?? 0)]), "session": .string(id)])))
            }
        }
    }
}
