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
    /// `fetch`, without `lookup`: what the command shows, asked of the server some other way (a preset).
    static func act(_ kind: String, lookup: String? = nil, fetch: ((NodeClient) -> Result<NodeWire.Value, NodeClient.Failure>)? = nil,
                    refuse: (NodeWire.Value) -> Int32? = { _ in nil },
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
        } else if let fetch {
            switch fetch(client) {
            case .failure(let failure): return Say.failed(failure)
            case .success(let found): session = found
            }
            if let status = refuse(session) { return status }
        }
        let action = UUID().uuidString.lowercased()
        let said = TypedWord.said(approval: client.approvalRule, action: action, what: what(session))
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        switch client.change(kind, args: args(session), action: action, typed: typed, timeout: timeout) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            say(result)
            return 0
        }
    }

    /// The session `wanted` names among those `status` lists (`SessionLookup.match`): its id, the terminal name
    /// `status` prints (`ttypts4`), or a prefix of its host id only one has; a name two answer to is refused, naming them.
    static func find(_ wanted: String, client: NodeClient) -> Result<NodeWire.Value, NodeClient.Failure> {
        switch client.request("status") {
        case .failure(let failure): return .failure(failure)
        case .success(let reply):
            guard reply.ok, let sessions = reply.result?["sessions"]?.array else {
                return .failure(.broken(reply.error.map { "\($0.code): \($0.message)" } ?? "the server listed no sessions"))
            }
            return SessionLookup.match(wanted, in: sessions).mapError { .refused($0.description) }
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
        let about = session["name"]?.string ?? session["task"]?.string ?? session["project"]?.string ?? session["cwd"]?.string ?? "?"
        return "session \(short(session["id"]?.string)) (\(ConfigSeal.inert(about, limit: 80)); \(ConfigSeal.inert(session["status"]?.string ?? "?", limit: 20)) "
            + "on \(ConfigSeal.inert(session["terminal"]?.string ?? "?", limit: 20)))"
    }
}

/// `vibeswitcher send SESSION [TEXT] [--image PATH]...`: the user's words, and images by their paths, typed into a
/// session the node's host runs, as the app's composer types them (a working agent takes them after its turn; with a
/// question open on its screen the node holds them, as the app does, and types them once it closes). With no TEXT and
/// no image, the message a web page's composer left for the session (its `draft`, its images too), shown whole first;
/// what is sent is what was shown. Refused for a session the host didn't start and a shell. `--now` (the app's ↩ while
/// its agent works): a working Claude agent gets it mid-turn, at its next step and without stopping, through its hook;
/// one between turns gets it typed in (`Requests.send`'s `now`). A draft the page left to go now goes so.
enum SendCommand {
    static let usage = "usage: vibeswitcher send SESSION [TEXT] [--image PATH]... [--now]  (neither: the message drafted on the session's web page)"

    static func run(_ arguments: [String]) -> Int32 {
        var words = arguments[...]
        guard let session = words.popFirst(), !session.isEmpty, !session.hasPrefix("--") else { return Say.usage(usage) }
        var text: String?
        var images: [String] = []
        var now = false
        while let word = words.popFirst() {
            if word == "--now" {
                guard !now else { return Say.usage(usage) }
                now = true
            } else if word == "--image" {
                guard let path = words.popFirst(), !path.isEmpty else { return Say.usage(usage) }
                images.append(CardCommand.absolute(path))
            } else {
                guard text == nil, !word.hasPrefix("--") else { return Say.usage(usage) }
                text = word
            }
        }
        if text == nil && images.isEmpty { return takeDraft(session, now: now) }
        let typed = text ?? ""
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return Say.usage(usage) }
        // The session found first (its id, its terminal name, or a prefix only one has), so what is shown names it. One
        // `status` doesn't list yet (its scan runs every 2 s, a session just started) goes to the server as given, which
        // finds it in its host's list, as before; a name two sessions answer to is refused.
        return SessionCommand.act("send", fetch: { client in
            switch client.request("status") {
            case .failure(let failure): return .failure(failure)
            case .success(let reply):
                guard reply.ok, let sessions = reply.result?["sessions"]?.array else {
                    return .failure(.broken(reply.error.map { "\($0.code): \($0.message)" } ?? "the server listed no sessions"))
                }
                switch SessionLookup.match(session, in: sessions) {
                case .success(let found): return .success(found)
                case .failure(let refusal) where refusal.ambiguous: return .failure(.refused(refusal.description))
                case .failure: return .success(.object(["id": .string(session)]))
                }
            }
        }, args: { found in
            var args: [String: NodeWire.Value] = ["session": found["id"] ?? .string(session), "text": .string(typed)]
            if !images.isEmpty { args["images"] = .array(images.map(NodeWire.Value.string)) }
            if now { args["now"] = .bool(true) }
            return args
        }, what: { found in
            // "session <short>" first, as before the lookup (SteerNowTests), then what the node lists of it.
            let named = "session \(SessionCommand.short(found["id"]?.string ?? session))"
            let about = found["status"] == nil ? "" : " " + String(SessionCommand.describe(found).drop { $0 != "(" })
            return (now ? "This steers \(named) now, as you (\(steerWhen))\(about): " : "This types into \(named)\(about), as you: ")
                + ConfigSeal.inert(typed, limit: 400) + attached(images)
        }, say: said)
    }

    /// What `--now` does, as what is shown says it.
    static let steerWhen = "a working agent gets it at its next step, without stopping; one between turns gets it typed in"

    /// The images a message carries, as what is shown says them.
    static func attached(_ images: [String]) -> String {
        images.isEmpty ? "" : "\n  with \(images.count == 1 ? "the image" : "\(images.count) images"): "
            + images.map { ConfigSeal.inert($0, limit: 200) }.joined(separator: ", ")
    }

    /// The session's draft (its words and images, and whether the page left it to go now), if it has one.
    static func draft(of session: NodeWire.Value) -> (text: String, images: [String], now: Bool)? {
        let text = session["draft"]?["text"]?.string ?? ""
        let images = session["draft"]?["images"]?.array?.compactMap(\.string) ?? []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return nil }
        return (text, images, session["draft"]?["now"]?.bool == true)
    }

    /// `now`: `--now` given, or the page left the draft to go now.
    private static func takeDraft(_ wanted: String, now: Bool) -> Int32 {
        SessionCommand.act("send", lookup: wanted, refuse: { session in
            guard draft(of: session) == nil else { return nil }
            return Say.usage("\(usage)\n\(SessionCommand.describe(session)) has no draft: write it on its web page, or give TEXT")
        }, args: { session in
            let drafted = draft(of: session)
            var args: [String: NodeWire.Value] = ["session": session["id"] ?? .string(wanted), "text": .string(drafted?.text ?? "")]
            if let images = drafted?.images, !images.isEmpty { args["images"] = .array(images.map(NodeWire.Value.string)) }
            if now || drafted?.now == true { args["now"] = .bool(true) }
            return args
        }, what: { session in
            // Whole: this is what the agent will take as the user's.
            let drafted = draft(of: session)
            return (now || drafted?.now == true
                    ? "This steers \(SessionCommand.describe(session)) now, as you (\(steerWhen)), with the message drafted on its web page: "
                    : "This types into \(SessionCommand.describe(session)), as you, the message drafted on its web page: ")
                + ConfigSeal.inert(drafted?.text ?? "", limit: .max) + attached(drafted?.images ?? [])
        }, say: said)
    }

    static func said(_ result: NodeWire.Value) {
        let short = SessionCommand.short(result["session"]?.string)
        let characters = result["characters"]?.int ?? 0
        if result["queued"]?.bool == true {
            Say.out("queued: \(ConfigSeal.inert(result["waits"]?.string ?? "a question is open on its screen", limit: 200)); the node types your "
                + "message into session \(short) once that closes (`vibeswitcher reply \(short) CHOICE` answers a question). "
                + "It is kept across a restart of the node's server or a switch, while the session lives")
            return
        }
        if let answered = result["answered"]?.string {
            Say.out("answered: your words went in as the answer to the question open in session \(short) "
                + "(its option “\(ConfigSeal.inert(answered, limit: 80))”, the one that takes typed words), as the app's composer sends them")
            return
        }
        if result["steered"]?.bool == true {
            Say.out("steered: \(characters) characters into session \(short)'s steer inbox; its agent gets them at its next step, without stopping "
                + "(typed in if its turn ends first)")
            return
        }
        if result["steered"]?.bool == false {
            Say.out(result["agent"]?.string == "codex"
                ? "sent: \(characters) characters typed into session \(short); Codex takes what is typed during its turn as a steer"
                : "sent: \(characters) characters typed into session \(short); its agent wasn't working by its hooks, so it takes them now as its prompt")
        } else {
            Say.out(result["working"]?.bool == true
                ? "sent: \(characters) characters typed into session \(short); it was working, so it takes them after its turn "
                    + "(`--now` steers it mid-turn)"
                : "sent: \(characters) characters typed into session \(short)")
        }
        if let opened = result["opened"]?.string {
            Say.out("\(ConfigSeal.inert(opened, limit: 200)) now: choose in the session's terminal, or close it there (Esc); "
                + "what you send meanwhile waits for it")
        }
    }
}

/// `vibeswitcher new FOLDER [--agent claude|codex|shell | --preset NAME] [--model M]`: an ordinary session started in the
/// node's host, as the app's New Session starts its Claude or Shell preset, or the launch preset named (`vibeswitcher
/// presets FOLDER` lists them): what it runs and the names of the variables it sets are shown before the code.
enum NewCommand {
    static let usage = "usage: vibeswitcher new FOLDER [--agent claude|codex|shell | --preset NAME] [--model M]"

    static func run(_ arguments: [String]) -> Int32 {
        var folder: String?
        var agent: String?
        var preset: String?
        var model: String?
        var words = arguments[...]
        while let word = words.popFirst() {
            switch word {
            case "--agent":
                guard agent == nil, let value = words.popFirst(), ["claude", "codex", "shell"].contains(value) else { return Say.usage(usage) }
                agent = value
            case "--preset":
                guard preset == nil, let value = words.popFirst(), !value.isEmpty, !value.hasPrefix("--") else { return Say.usage(usage) }
                preset = value
            case "--model":
                guard let value = words.popFirst(), !value.isEmpty, !value.hasPrefix("--") else { return Say.usage(usage) }
                model = value
            default:
                guard folder == nil, !word.isEmpty, !word.hasPrefix("--") else { return Say.usage(usage) }
                folder = word
            }
        }
        guard let given = folder, agent == nil || preset == nil, model == nil || agent != "shell" else { return Say.usage(usage) }
        let path = CardCommand.absolute(given)
        let withModel = model.map { " (model \(ConfigSeal.inert($0, limit: 64)))" } ?? ""
        if let preset { return start(preset: preset, in: path, model: model, withModel: withModel) }
        let chosen = agent ?? "claude"
        var args: [String: NodeWire.Value] = ["folder": .string(path), "agent": .string(chosen)]
        if let model { args["model"] = .string(model) }
        let what = chosen == "shell" ? "a shell" : (chosen == "codex" ? "Codex" : "Claude") + withModel
        return SessionCommand.act("session.new", args: { _ in args }, what: { _ in
            "This starts \(what) in a new session in \(ConfigSeal.inert(path, limit: 200)), as you."
        }, say: started)
    }

    /// The preset `name` for `path`, as the server lists it, shown whole (its variables by name) and started.
    private static func start(preset name: String, in path: String, model: String?, withModel: String) -> Int32 {
        SessionCommand.act("session.new", fetch: { client in
            switch client.request("session.presets", args: ["folder": .string(path), "values": .bool(true)]) {
            case .failure(let failure): return .failure(failure)
            case .success(let reply):
                guard reply.ok, let list = reply.result?["presets"]?.array else {
                    return .failure(.broken(reply.error.map { "\($0.code): \($0.message)" } ?? "the server listed no presets"))
                }
                guard let found = PresetsCommand.named(name, in: list) else {
                    let names = list.compactMap { $0["name"]?.string }.map { ConfigSeal.inert($0, limit: 40) }.joined(separator: ", ")
                    return .failure(.refused("no preset \(ConfigSeal.inert(name, limit: 80)) for \(ConfigSeal.inert(path, limit: 200)); it has: \(names)"))
                }
                return .success(found)
            }
        }, refuse: { preset in
            if let why = preset["refused"]?.string { return Say.refused("preset \(ConfigSeal.inert(name, limit: 80)) can't start here: \(ConfigSeal.inert(why, limit: 400))") }
            if model != nil, preset["kind"]?.string == "shell" { return Say.usage(usage + "\n(preset \(ConfigSeal.inert(name, limit: 80)) starts a shell: no model)") }
            return nil
        }, args: { preset in
            var args: [String: NodeWire.Value] = ["folder": .string(path), "preset": preset["name"] ?? .string(name), "digest": preset["digest"] ?? .null]
            if let model { args["model"] = .string(model) }
            return args
        }, what: { preset in
            "This starts preset " + PresetsCommand.describe(preset) + withModel + " in a new session in \(ConfigSeal.inert(path, limit: 200)), as you."
        }, say: started)
    }

    static func started(_ result: NodeWire.Value) {
        let short = SessionCommand.short(result["session"]?.string)
        Say.out("started: session \(short) on \(ConfigSeal.inert(result["terminal"]?.string ?? "?", limit: 20)) "
            + "(`vibeswitcher send \(short) TEXT` types into it; `vibeswitcher end \(short)` ends it)")
    }
}

/// `vibeswitcher presets [FOLDER]`: the launch presets `new --preset` takes for a folder (the current one when none is
/// given), its default first, as the app's New Session lists them; those the node can't start say why.
enum PresetsCommand {
    static let usage = "usage: vibeswitcher presets [FOLDER]"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count <= 1, !(arguments.first?.hasPrefix("--") ?? false) else { return Say.usage(usage) }
        let path = CardCommand.absolute(arguments.first ?? FileManager.default.currentDirectoryPath)
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        switch client.request("session.presets", args: ["folder": .string(path), "values": .bool(true)]) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let list = reply.result?["presets"]?.array else { return Say.replyError(reply) }
            for problem in reply.result?["problems"]?.array ?? [] { Say.err("presets: \(ConfigSeal.inert(problem.string ?? "", limit: 400))") }
            for preset in list {
                let why = preset["refused"]?.string.map { "\n    can't start here: " + ConfigSeal.inert($0, limit: 400) } ?? ""
                Say.out(describe(preset) + why)
            }
            Say.out("(`vibeswitcher new \(ConfigSeal.inert(path, limit: 200)) --preset NAME` starts one)")
            return 0
        }
    }

    /// The preset `name` names among the server's list: the same name, else the same ignoring case (the server's rule).
    static func named(_ name: String, in list: [NodeWire.Value]) -> NodeWire.Value? {
        list.first { $0["name"]?.string == name } ?? list.first { $0["name"]?.string?.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A preset in one line: its name, what it runs, the variables it sets (by name), and where it's from. Inert.
    static func describe(_ preset: NodeWire.Value) -> String {
        let kind = preset["kind"]?.string ?? "?"
        let command = preset["command"]?.string ?? ""
        let runs = kind == "shell" ? "a shell" : "\(kind == "claude" ? "Claude" : kind): `\(command.isEmpty ? kind : command)`"
        var notes: [String] = []
        if preset["default"]?.bool == true { notes.append("the folder's default") }
        if preset["project"]?.bool == true { notes.append("this project's") }
        // Each variable with its value as the node shows it to a terminal (a secret-looking one `<set>`); by name alone
        // from a node that sends no values.
        let env = (preset["env"]?.array ?? []).compactMap(\.string)
        let values = preset["values"]?.object ?? [:]
        if !env.isEmpty { notes.append("sets " + env.map { name in values[name]?.string.map { "\(name)=\($0)" } ?? name }.joined(separator: ", ")) }
        if preset["keepShell"]?.bool == true { notes.append("a shell stays when it ends") }
        let tail = notes.isEmpty ? "" : "; " + notes.joined(separator: "; ")
        return ConfigSeal.inert("\(preset["name"]?.string ?? "?") (\(runs)\(tail))", limit: 600)
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
