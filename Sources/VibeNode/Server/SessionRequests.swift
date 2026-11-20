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
    /// session, its terminal, and whether its agent was working.
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
        let (link, queue, note) = (self.link, self.queue, self.note)
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
                    reply(.init(re: request.id, result: .object([
                        "session": .string(NodeIds.session(host: session.id)), "terminal": .string(session.tty),
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
