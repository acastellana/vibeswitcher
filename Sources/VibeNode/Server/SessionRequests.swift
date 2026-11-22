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

    /// What's open on `screen` that takes keys instead of the agent's prompt box, said for a held message: an agent's
    /// question (a numbered menu: a permission prompt, a question, a plan to approve), a local command's picker or
    /// dialog, or the slash-command menu. Nil when none is (`ScreenMenu`'s readers, the app's `onScreenNow`).
    static func openMenu(_ screen: String) -> String? {
        let lines = Platform.lines(screen.replacingOccurrences(of: "\u{0}", with: " "))
        if ScreenMenu.parse(lines) != nil {
            return "a question is open on its screen"
        }
        if ScreenMenu.parsePicker(lines) != nil || ScreenMenu.parseCommands(lines) != nil {
            return "a picker or menu is open on its screen"
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

    /// The command line an ordinary Claude session runs: the node's Claude, with `--model` and `--resume` when given
    /// (each checked by its caller: a model's name, a conversation id), every word quoted.
    static func claudeCommand(program: String, model: String?, resume: String? = nil) -> String {
        RecentProjects.shellQuote(program) + (model.map { " --model " + RecentProjects.shellQuote($0) } ?? "")
            + (resume.map { " --resume " + RecentProjects.shellQuote($0) } ?? "")
    }

    /// The labels the app gives an ordinary session (its built-in presets' names): never a role's (`LeadTeams.role`).
    static let sessionLabels = ["claude": "Claude", "codex": "Codex", "shell": "Shell"]

    /// `session.new` with `folder` (absolute), `agent` (`claude`, the default, or `shell`) or `preset` (a launch
    /// preset's name, with the `digest` `session.presets` gave for it), and `model` (Claude's, optional)
    /// (2026-11-20, the parity table's gap 3): an ordinary session started in the node's host, as the app's New Session
    /// starts its built-in Claude or Shell preset, or the preset named (`SessionPresets`: its environment, whether a
    /// shell stays): labelled as one, the agent recorded with it (`HostedAgents`), 120 by 36.
    /// Claude is the program the node's `claude` link names (`NodePreflight`, never a PATH or a login shell: EN-D13),
    /// with a preset's arguments and `--model` when given; a shell is the host's plain shell. Nothing answers its first
    /// questions (Claude's trust question shows as the session's prompt: `vibeswitcher reply`). Refused: a folder that
    /// isn't one, a model name that isn't a word, Claude with no `claude` link, a preset the folder hasn't or the node
    /// can't start, and one whose digest isn't the one shown (it changed since).
    func newSession(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let folder = request.args?["folder"]?.string, folder.hasPrefix("/") else {
            return reply(.init(re: request.id, error: .init(.badArgs, "session.new needs folder, an absolute path")))
        }
        let presetName = request.args?["preset"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let shownDigest = request.args?["digest"]?.string
        if presetName != nil {
            guard request.args?["agent"] == nil else { return reply(.init(re: request.id, error: .init(.badArgs, "session.new takes agent or preset, not both"))) }
            guard shownDigest != nil else {
                return reply(.init(re: request.id, error: .init(.badArgs, "session.new with a preset needs its digest, as `session.presets` gave it")))
            }
        }
        let agent = request.args?["agent"]?.string ?? "claude"
        guard Self.sessionLabels[agent] != nil else {
            return reply(.init(re: request.id, error: .init(.badArgs, "session.new's agent is claude, codex or shell, not \(ConfigSeal.inert(agent, limit: 40))")))
        }
        let model = request.args?["model"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if let model {
            guard agent != "shell" else { return reply(.init(re: request.id, error: .init(.badArgs, "a shell takes no model"))) }
            guard Self.isModelName(model) else {
                return reply(.init(re: request.id, error: .init(.badArgs, "\(ConfigSeal.inert(model, limit: 64)) isn't a model name (letters, digits, . _ : - [ ])")))
            }
        }
        let claudeLink = engine?.preflight.claudeLink ?? NodePreflight.claudeLink(root: root)
        let scratch = !NodeFolders.isUsersRoot(root, accountHome: VibePaths.accountHome)
        let (link, queue, note, nodeRoot) = (self.link, self.queue, self.note, root)
        // The vault that keeps the user's accepted config, and the home the config seal reads: a preset of the file
        // starts only while the file is as an accept sealed it.
        let (vault, home) = (engine?.cardVault, engine?.home ?? self.home)
        let refuse = { (why: String) in queue.async { reply(.init(re: request.id, error: .init(.refused, why))) } }
        // Off the queue: the folder, the presets and the link are read from the disk.
        DispatchQueue.global(qos: .userInitiated).async {
            var isFolder: ObjCBool = false
            let standard = (folder as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: standard, isDirectory: &isFolder), isFolder.boolValue else {
                return refuse("\(ConfigSeal.inert(folder, limit: 200)) isn't a folder")
            }
            // The built-in Claude or Shell, else the preset named.
            var preset = agent == "shell" ? LaunchPreset(name: "Shell", kind: .shell, command: "")
                : agent == "codex" ? LaunchPreset(name: "Codex", kind: .codex, command: "") : LaunchPreset(name: "Claude", kind: .claude, command: "")
            if let presetName {
                // One read of the file: what is checked against the seal below is what starts (`PresetsFile`).
                let file = SessionPresets.read(root: nodeRoot)
                let listed = SessionPresets.list(file.presets, folder: standard)
                let shown = ConfigSeal.inert(presetName, limit: 80)
                guard let found = SessionPresets.named(presetName, in: listed) else {
                    return refuse("no preset \(shown) for \(ConfigSeal.inert(standard, limit: 200)) (`vibeswitcher presets \(ConfigSeal.inert(standard, limit: 200))` lists them)")
                }
                if let why = found.refusal { return refuse("preset \(shown) can't start here: \(why)") }
                guard SessionPresets.matches(found.preset, digest: shownDigest) else {
                    return refuse("preset \(shown) changed since it was shown (or the node's server restarted since): nothing started; "
                                  + "run the command again to see it as it is now")
                }
                guard model == nil || found.preset.kind != .shell else { return refuse("preset \(shown) starts a shell, which takes no model") }
                // Fail closed: a preset of the file (not a built-in) only from a file the user's accept sealed.
                if !found.builtIn, let why = Self.presetsBaselineRefusal(vault: vault, home: home, nodeRoot: nodeRoot, file: file, folder: standard) {
                    return refuse("preset \(shown) can't start: " + why)
                }
                preset = found.preset
            }
            var command: String?
            if preset.kind == .claude {
                let found = NodePreflight.resolve(claudeLink)
                guard let program = found.path else { return refuse(found.why ?? "no claude for this node") }
                command = SessionPresets.command(preset, program: program).map { $0 + (model.map { " --model " + RecentProjects.shellQuote($0) } ?? "") }
            } else if preset.kind == .codex {
                // The user's own Codex session, as typing `codex` in their terminal (decision 15 keeps Codex workers off,
                // not this): the Codex its link names, never one a shell finds.
                let found = NodePreflight.codex(root: nodeRoot)
                guard let program = found.path else { return refuse(found.why ?? "no codex for this node") }
                command = SessionPresets.command(preset, program: program).map { $0 + (model.map { " --model " + RecentProjects.shellQuote($0) } ?? "") }
            }
            // A scratch node's hooks and tools keep to its root, as its leads' do.
            var environment = preset.env
            if scratch { environment["VIBESWITCHER_HOME"] = nodeRoot.path }
            let kind = preset.kind == .claude ? "claude" : preset.kind == .codex ? "codex" : "shell"
            let label = preset.name
            let spawn = SpawnRequest(cwd: standard, command: command, env: environment, cols: 120, rows: 36, keepShell: preset.keepShell,
                                     label: preset.name, agent: kind == "shell" ? nil : kind)
            queue.async {
                link.spawn(spawn) { result in
                    queue.async {
                        switch result {
                        case .success(let session):
                            note("session.new: \(presetName == nil ? kind : "a preset's \(kind)") started in session \(session.id.uuidString.prefix(8)) (\(session.tty))")
                            reply(.init(re: request.id, result: .object([
                                "session": .string(NodeIds.session(host: session.id)), "terminal": .string(session.tty),
                                "agent": .string(kind), "folder": .string(standard), "model": model.map(NodeWire.Value.string) ?? .null,
                                "preset": presetName.map { _ in .string(label) } ?? .null,
                            ])))
                        case .failure(let failure):
                            reply(.init(re: request.id, error: .init(.refused, "the session host didn't start it: \(failure.message)")))
                        }
                    }
                }
            }
        }
    }

    /// Why a preset of the node's presets file can't start now (nil: it can), failing closed (the security reviews of
    /// 2026-11-20): `file` (the one read of it, `SessionPresets.read`) must be a regular file, the one the config seal
    /// watches in the home (`SessionPresets.sealName`); the vault's home-wide record (asked under the node's own
    /// `acceptRoot`, so no project's record stands in) must hold a sealed hash of it equal to the hash of the bytes read,
    /// no change to it held, and the marker the user's explicit `config accept` of it recorded
    /// (`SessionPresets.acceptedKey`) equal to that hash too: a seal a look made alone starts nothing. A vault that can't
    /// be asked, or holds no record, refuses. Asks the vault: never on the engine's queue.
    static func presetsBaselineRefusal(vault: LeadVault?, home: String, nodeRoot: URL, file: SessionPresets.PresetsFile, folder: String) -> String? {
        let accept = "accept the presets first (`vibeswitcher config held \(ConfigSeal.inert(folder, limit: 200))`, then `config accept CARD`)"
        let path = nodeRoot.appendingPathComponent("presets.json").standardizedFileURL.path
        guard let watched = ConfigSeal.homeWatched(home: home).first(where: { $0.name == SessionPresets.sealName }),
              URL(fileURLWithPath: watched.path).standardizedFileURL.path == path else {
            return "this node's presets file (\(ConfigSeal.inert(path, limit: 200))) isn't the one the config seal watches, so no accept covers it"
        }
        guard let fingerprint = file.fingerprint else {
            return (file.problems.first.map { ConfigSeal.inert($0, limit: 200) } ?? "there is no presets file") + "; nothing of it starts"
        }
        guard let vault else { return "this node keeps no vault to accept them in" }
        let record: [String: String]?
        do { record = try vault.guardedRecord(root: SessionPresets.acceptRoot(nodeRoot: nodeRoot)) } catch {
            return "the vault couldn't be asked (\(ConfigSeal.inert("\(error)", limit: 200))): " + accept
        }
        guard let record, let sealed = record[ConfigSeal.keyPrefix + SessionPresets.sealName] else { return "the vault holds no accepted presets: " + accept }
        if ConfigSeal.held(in: record).contains(SessionPresets.sealName) { return "the vault holds a change to the presets file: " + accept }
        guard sealed == fingerprint else { return "the presets file changed since you accepted it: " + accept }
        guard record[SessionPresets.acceptedKey] == fingerprint else {
            return "the presets file as it is was never accepted by you (a look alone sealed it): " + accept
        }
        return nil
    }

    /// `session.presets` with `folder` (absolute, optional) and `values` (a terminal's), a read (the parity table's launch presets, 2026-11-20): the
    /// launch presets the node keeps for that folder (`SessionPresets.list`: its default first), each with the `digest`
    /// `session.new` takes back, and the lines about what in the file couldn't be read. Off the queue: the file is read.
    func presets(_ request: NodeWire.Request, terminal: Bool = false, reply: @escaping (NodeWire.Reply) -> Void) {
        // The variables' values (a secret-looking one masked) only to a process of the uid asking for them, for its
        // confirmation: never to a web page, whatever it asks.
        let values = terminal && request.args?["values"]?.bool == true
        let folder = request.args?["folder"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if let folder, !folder.hasPrefix("/") {
            return reply(.init(re: request.id, error: .init(.badArgs, "session.presets' folder is an absolute path")))
        }
        let (queue, nodeRoot) = (self.queue, root)
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = SessionPresets.load(root: nodeRoot)
            let listed = SessionPresets.list(loaded.presets, folder: folder)
            queue.async {
                reply(.init(re: request.id, result: .object([
                    "presets": .array(listed.map { SessionPresets.value($0, values: values) }),
                    "problems": .array(loaded.problems.map(NodeWire.Value.string)),
                ])))
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
    /// `session.reply` with `session`, `choice` (an option's number, from 1), `text` (for a free-text option only), and
    /// `question` and `options` (the question and its options as the user was shown them: the session's `prompt`, each
    /// optional)
    /// (2026-11-20, the parity table's gap 6): the session's own question answered as the app's answer card answers it
    /// (`ChatSync.keys`: arrows from its cursor to the option, then Enter; for free text, the words then Enter). The
    /// screen is read, the question found there (`SessionPrompt.menu(on:)`), and the keys typed as one unit of the host's whose
    /// gate reads the screen again right before the first key: unless the same question shows with its cursor where it
    /// was, nothing is typed; and the key after the arrows waits for the screen to show the cursor on the option
    /// (`cursorReaches`), else the unit stops there, nothing chosen. Refused, nothing typed: a session the host didn't start, a shell, no question on its
    /// screen, a question or options other than those shown, a choice it hasn't, a multi-select (its boxes are
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
        let shownOptions = request.args?["options"]?.array?.map { $0.string ?? "" }
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
                if let shownOptions, shownOptions != menu.options {
                    return refuse("its options aren't the ones you were shown; they are now: "
                                  + ConfigSeal.inert(menu.options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "; "), limit: 400))
                }
                guard !menu.multiSelect else { return refuse("its question takes several ticks: answer it in the session's terminal") }
                let index = choice - 1
                guard menu.options.indices.contains(index) else {
                    return refuse("its question has \(menu.options.count) options, not \(choice)")
                }
                guard !SessionPrompt.toggles(menu, index) else {
                    return refuse("option \(choice) is a setting toggled with Space (\(ConfigSeal.inert(menu.options[index], limit: 80))): "
                                  + "set it in the session's terminal, or choose its Continue")
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
                // The arrows' count: the key after them (Enter, or the words) goes only once the screen shows the cursor
                // on the option, as `TrustPrompt.answer` waits: an arrow lost on a menu not yet taking keys would put
                // Enter on the row the cursor was on ("No, exit" on Claude's trust question ends the session).
                let moves = abs(index - menu.selected)
                link.type(writes, into: session.id, gate: { step, go in
                    if step == 0 {
                        return link.screen(session.id) { now in
                            guard let now, SessionPrompt.menu(on: now) == menu else {
                                stopped.set("its question changed or was answered meanwhile: nothing typed")
                                return go(false)
                            }
                            go(true)
                        }
                    }
                    guard step == moves else { return go(true) }
                    Self.cursorReaches(index, of: menu, in: session.id, link: link, since: Platform.Clock.steadyDate()) { reached in
                        if !reached {
                            stopped.set("the cursor didn't reach option \(choice) on its screen (a key lost?): nothing chosen, answer again")
                        }
                        go(reached)
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

extension Requests {
    /// How long `session.reply` waits for the screen to show its arrows' cursor on the option, and how often it looks.
    static let replyCursorWait: TimeInterval = 5
    static let replyCursorEvery: TimeInterval = 0.1

    /// Reads `id`'s screen until it shows `menu`'s question with its cursor on option `index` (`done(true)`), or
    /// `replyCursorWait` passes (`done(false)`; a read taken mid-redraw may show no question for a moment).
    static func cursorReaches(_ index: Int, of menu: ScreenMenu, in id: UUID, link: HostLink, since: Date,
                              done: @escaping (Bool) -> Void) {
        link.screen(id) { screen in
            let now = screen.flatMap(SessionPrompt.menu(on:))
            if let now, now.sameQuestion(as: menu), now.selected == index { return done(true) }
            guard Platform.Clock.steadyDate().timeIntervalSince(since) < replyCursorWait else { return done(false) }
            link.queue.asyncAfter(deadline: .now() + replyCursorEvery) {
                cursorReaches(index, of: menu, in: id, link: link, since: since, done: done)
            }
        }
    }
}

// MARK: session.draft, session.draft.clear

extension Requests {
    /// `session.draft` with `session` (the node's whole id for it, as a page holds it), `text` and `images` (the paths
    /// `session.attach` gave, optional; text may be empty when there are some; `now`, optional: to go mid-turn, as
    /// `send`'s `--now`), and
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
            let text = request.args?["text"]?.string ?? ""
            let images = request.args?["images"]?.array?.map { $0.string ?? "" } ?? []
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
                return done(.init(re: request.id, error: .init(.badArgs, "session.draft needs text or images")))
            }
            guard text.utf8.count <= Self.sendLimit else {
                return done(.init(re: request.id, error: .init(.badArgs, "a message is at most \(Self.sendLimit / 1024) KB")))
            }
            guard images.count <= Self.imagesLimit else {
                return done(.init(re: request.id, error: .init(.badArgs, "at most \(Self.imagesLimit) images a message")))
            }
            // Only images a page attached (`session.attach`): a page names no other file for `send` to paste.
            if let odd = images.first(where: { !SessionAttachments.isAttached($0, root: root) }) {
                return done(.init(re: request.id, error: .init(.badArgs, "\(ConfigSeal.inert(odd, limit: 200)) isn't an image attached on this node")))
            }
            sessionDrafts.send(id, SessionDraft(text: text, images: images, at: Date(), action: action, now: request.args?["now"]?.bool == true))
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
