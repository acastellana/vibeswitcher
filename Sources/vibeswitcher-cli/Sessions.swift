import Foundation
import VibeCore
import VibeNode

/// Driving an ordinary session from the command line (the parity table's gaps 1, 3 and 6, 2026-11-20): `send`, `new`,
/// `end` and `reply`. Each is the user's voice, as `tell` is: what it does shown (anything an agent or the user wrote,
/// inert), the command line's own typed code (EN-D5: from the action id, no card), then the request; the server records
/// it in the host's vault before it acts. The accepted request is written to the journal (ids only: no text, no folder).
enum SessionCommand {
    /// `kind` with `args`, after `what` is shown and the code typed; `say` prints the result. `lookup`: the session the
    /// command names, found first (`status`), so what is shown and sent can be its; `refuse`, given it, says the exit
    /// status when the command can't go on (nil: it can), before anything is shown or the code asked. Accepted (the
    /// voice passed and the server recorded it), a refusal of the server's (`refused`) comes after that, and is
    /// journaled too.
    static func act(_ kind: String, lookup: String? = nil, refuse: (NodeWire.Value) -> Int32? = { _ in nil },
                    args: (NodeWire.Value) -> [String: NodeWire.Value], what: (NodeWire.Value) -> String, timeout: TimeInterval = 120,
                    say: (NodeWire.Value) -> Void) -> Int32 {
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        var session = NodeWire.Value.null
        if let lookup {
            switch find(lookup, client: client) {
            case .failure(let failure): return Say.failed(failure)
            case .success(let found): session = found
            }
            if let status = refuse(session) { return status }
        }
        let action = UUID().uuidString.lowercased()
        let outcome = TypedWord.ask(code: NodeIds.code(action: action), what: what(session))
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        switch client.request(kind, args: args(session), action: action, timeout: timeout) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            if reply.ok || reply.error?.code == NodeWire.Code.refused.rawValue {
                context.writeJournal(NodeJournal.entry(event: "request", action: action, kind: kind, epoch: client.hello.epoch))
            }
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            say(result)
            return 0
        }
    }

    /// The session `wanted` names among those `status` lists: the node's id for it (`local:<uuid>`, `local:pts/9`), its
    /// host id, or a prefix of 4 or more of that id that only one has (as the page and `status` show it, 8).
    static func find(_ wanted: String, client: NodeClient) -> Result<NodeWire.Value, NodeClient.Failure> {
        switch client.request("status") {
        case .failure(let failure): return .failure(failure)
        case .success(let reply):
            guard reply.ok, let sessions = reply.result?["sessions"]?.array else {
                return .failure(.broken(reply.error.map { "\($0.code): \($0.message)" } ?? "the server listed no sessions"))
            }
            let given = wanted.lowercased()
            let prefix = NodeIds.node + ":"
            let bare = given.hasPrefix(prefix) ? String(given.dropFirst(prefix.count)) : given
            let exact = sessions.filter { $0["id"]?.string?.lowercased() == prefix + bare }
            let byPrefix = bare.count >= 4 && bare.allSatisfy({ $0.isHexDigit || $0 == "-" })
                ? sessions.filter { $0["hosted"]?.bool == true && ($0["id"]?.string ?? "").lowercased().dropFirst(prefix.count).hasPrefix(bare) } : []
            let matches = exact.isEmpty ? byPrefix : exact
            guard matches.count == 1, let session = matches.first else {
                return .failure(.refused(matches.isEmpty ? "no session \(ConfigSeal.inert(wanted, limit: 80)) on this node (`vibeswitcher status` lists them)"
                                                        : "\(ConfigSeal.inert(wanted, limit: 80)) begins \(matches.count) sessions' ids: give more of it"))
            }
            return .success(session)
        }
    }

    /// A session's id as the command line shows it: the first 8 characters of its host id.
    static func short(_ id: String?) -> String {
        let bare = (id ?? "?").replacingOccurrences(of: NodeIds.node + ":", with: "")
        return ConfigSeal.inert(String(bare.prefix(8)), limit: 8)
    }

    /// A session in a few words, for what a command shows: its id, what it's at (its task, else its project), its
    /// status and terminal, all inert.
    static func describe(_ session: NodeWire.Value) -> String {
        let about = session["task"]?.string ?? session["project"]?.string ?? session["cwd"]?.string ?? "?"
        return "session \(short(session["id"]?.string)) (\(ConfigSeal.inert(about, limit: 80)); \(ConfigSeal.inert(session["status"]?.string ?? "?", limit: 20)) "
            + "on \(ConfigSeal.inert(session["terminal"]?.string ?? "?", limit: 20)))"
    }
}

/// `vibeswitcher send SESSION [TEXT]`: the user's words typed into a session the node's host runs, as the app's
/// composer types them (a working agent takes them after its turn). With no TEXT, the message a web page's composer
/// left for the session (its `draft`), shown whole first; what is sent is what was shown. Refused for a session the
/// host didn't start, a shell, and one with a question or picker open on its screen.
enum SendCommand {
    static let usage = "usage: vibeswitcher send SESSION [TEXT]  (no TEXT: the message drafted on the session's web page)"

    static func run(_ arguments: [String]) -> Int32 {
        guard (1...2).contains(arguments.count), !arguments[0].isEmpty, !arguments[0].hasPrefix("--") else { return Say.usage(usage) }
        if arguments.count == 1 { return takeDraft(arguments[0]) }
        let (session, text) = (arguments[0], arguments[1])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Say.usage(usage) }
        return SessionCommand.act("send", args: { _ in ["session": .string(session), "text": .string(text)] }, what: { _ in
            "This types into session \(ConfigSeal.inert(session, limit: 80)), as you: " + ConfigSeal.inert(text, limit: 400)
        }, say: said)
    }

    /// The session's draft, if it has one.
    static func draft(of session: NodeWire.Value) -> String? {
        guard let text = session["draft"]?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func takeDraft(_ wanted: String) -> Int32 {
        SessionCommand.act("send", lookup: wanted, refuse: { session in
            guard draft(of: session) == nil else { return nil }
            return Say.usage("\(usage)\n\(SessionCommand.describe(session)) has no draft: write it on its web page, or give TEXT")
        }, args: { session in
            ["session": session["id"] ?? .string(wanted), "text": .string(draft(of: session) ?? "")]
        }, what: { session in
            // Whole: this is what the agent will take as the user's.
            "This types into \(SessionCommand.describe(session)), as you, the message drafted on its web page: "
                + ConfigSeal.inert(draft(of: session) ?? "", limit: .max)
        }, say: said)
    }

    static func said(_ result: NodeWire.Value) {
        let short = SessionCommand.short(result["session"]?.string)
        let characters = result["characters"]?.int ?? 0
        Say.out(result["working"]?.bool == true
            ? "sent: \(characters) characters typed into session \(short); it was working, so it takes them after its turn"
            : "sent: \(characters) characters typed into session \(short)")
    }
}

/// `vibeswitcher new FOLDER [--agent claude|shell] [--model M]`: an ordinary session started in the node's host, as
/// the app's New Session starts its Claude or Shell preset.
enum NewCommand {
    static let usage = "usage: vibeswitcher new FOLDER [--agent claude|shell] [--model M]"

    static func run(_ arguments: [String]) -> Int32 {
        var folder: String?
        var agent = "claude"
        var model: String?
        var words = arguments[...]
        while let word = words.popFirst() {
            switch word {
            case "--agent":
                guard let value = words.popFirst(), ["claude", "shell"].contains(value) else { return Say.usage(usage) }
                agent = value
            case "--model":
                guard let value = words.popFirst(), !value.isEmpty, !value.hasPrefix("--") else { return Say.usage(usage) }
                model = value
            default:
                guard folder == nil, !word.isEmpty, !word.hasPrefix("--") else { return Say.usage(usage) }
                folder = word
            }
        }
        guard let given = folder, model == nil || agent == "claude" else { return Say.usage(usage) }
        let path = CardCommand.absolute(given)
        var args: [String: NodeWire.Value] = ["folder": .string(path), "agent": .string(agent)]
        if let model { args["model"] = .string(model) }
        let what = agent == "shell" ? "a shell" : "Claude" + (model.map { " (model \(ConfigSeal.inert($0, limit: 64)))" } ?? "")
        return SessionCommand.act("session.new", args: { _ in args }, what: { _ in
            "This starts \(what) in a new session in \(ConfigSeal.inert(path, limit: 200)), as you."
        }) { result in
            let short = SessionCommand.short(result["session"]?.string)
            Say.out("started: session \(short) on \(ConfigSeal.inert(result["terminal"]?.string ?? "?", limit: 20)) "
                + "(`vibeswitcher send \(short) TEXT` types into it; `vibeswitcher end \(short)` ends it)")
        }
    }
}

/// `vibeswitcher end SESSION`: the app's End Session, for a session the node's host started. A lead and its team are
/// the lead commands'.
enum EndCommand {
    static let usage = "usage: vibeswitcher end SESSION"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 1, !arguments[0].isEmpty, !arguments[0].hasPrefix("--") else { return Say.usage(usage) }
        return SessionCommand.act("session.end", lookup: arguments[0], args: { session in
            ["session": session["id"] ?? .string(arguments[0])]
        }, what: { session in
            "This ends \(SessionCommand.describe(session)): its agent stops, with everything running in its terminal."
        }) { result in
            let short = SessionCommand.short(result["session"]?.string)
            Say.out(result["ended"]?.bool == false
                ? "asked to end: session \(short) still ran a while later; `vibeswitcher status` shows when it's gone"
                : "ended: session \(short)")
        }
    }
}

/// `vibeswitcher reply SESSION CHOICE [TEXT]`: the session's own question (a permission prompt, Claude's question, a
/// plan to approve) answered as the app's answer card answers it. The question and its options are shown first, the
/// chosen one marked; the server types the answer only while that same question is on the session's screen.
enum ReplyCommand {
    static let usage = "usage: vibeswitcher reply SESSION CHOICE [TEXT]  (CHOICE: the option's number; TEXT: for an option that takes words)"

    static func run(_ arguments: [String]) -> Int32 {
        guard (2...3).contains(arguments.count), !arguments[0].hasPrefix("--"), let choice = Int(arguments[1]), choice >= 1 else {
            return Say.usage(usage)
        }
        let text = arguments.count == 3 ? arguments[2] : nil
        return SessionCommand.act("session.reply", lookup: arguments[0], refuse: { session in
            guard let prompt = session["prompt"], prompt != .null else {
                return Say.refused("\(SessionCommand.describe(session)) asks nothing now (no question is open on its screen)")
            }
            let count = prompt["options"]?.array?.count ?? 0
            guard choice <= count else { return Say.refused("its question has \(count) options, not \(choice)") }
            return nil
        }, args: { session in
            // Bound to what was shown: the server types nothing while another question, or other options, are open.
            var args: [String: NodeWire.Value] = ["session": session["id"] ?? .string(arguments[0]), "choice": .int(choice),
                                                  "question": session["prompt"]?["question"] ?? .null,
                                                  "options": session["prompt"]?["options"] ?? .null]
            if let text { args["text"] = .string(text) }
            return args
        }, what: { session in
            let prompt = session["prompt"] ?? .null
            let options = (prompt["options"]?.array ?? []).enumerated().map { index, option in
                "  \(index + 1 == choice ? "❯" : " ") \(index + 1). \(ConfigSeal.inert(option.string ?? "", limit: 200))"
            }
            return "\(SessionCommand.describe(session)) asks:\n" + ConfigSeal.inert(prompt["question"]?.string ?? "", limit: 2000) + "\n"
                + options.joined(separator: "\n") + "\nThis answers it with option \(choice)"
                + (text.map { ", typing: " + ConfigSeal.inert($0, limit: 400) } ?? "") + ", as you."
        }) { result in
            Say.out("answered: option \(result["choice"]?.int ?? choice) (\(ConfigSeal.inert(result["option"]?.string ?? "", limit: 80))) "
                + "typed into session \(SessionCommand.short(result["session"]?.string))")
        }
    }
}
