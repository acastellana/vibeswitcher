import Foundation
import VibeCore

/// What a Touch ID approval's dialog says (`ApprovalVoice.judge`'s `card`, the user's voice on the Mac), built by the
/// server for each kind from the request's arguments it validated and the cards and sessions it holds, never from what
/// the command line said (the review of 2026-11-21):
///
/// - **The request's word first**: `NodeIds.code(action:)` of its action id, the code the command line printed before
///   the request went (`TypedWord`): a dialog whose word the person's terminal didn't print is someone else's request.
/// - **The decisive part next, whole**: the words an answer sends with the commit and tasks it approves; a shell card's
///   command and folder; how many held items and guard rails a config accept takes; the setting and its value; the
///   folder and agent a session starts in. When the decisive part can't fit the dialog (`approvalBudget`), nothing is
///   asked: the reply says so.
/// - **Context after, bounded**: the project, a session by its terminal and folder (never a raw id), and words an agent
///   or a lead wrote marked as theirs (“…”) and cut, saying so.
/// - **No argument key is shown**, and an argument a kind doesn't take refuses the request before any dialog: a value
///   can't pass itself off as another field.
extension Requests {
    /// The dialog's text budget after the action phrase (`ApprovalVoice.reason` cuts at `ApprovalVoice.cardLimit`).
    static let approvalBudget = ApprovalVoice.cardLimit

    /// Each state-changing kind's arguments: what it takes (anything else refuses it).
    static let approvalArguments: [String: Set<String>] = [
        "answer": ["card", "code", "text", "version"], "hold": ["card", "code"], "config.accept": ["card", "code"],
        "base.accept": ["card", "code"], "base.keep": ["card", "code"],
        "start": [], "stop": [], "lead": ["folder", "goal", "resume", "replace", "takeHead"],
        "hooks.install": ["agents"], "hooks.remove": ["agents"], "build.switch": ["commit"], "approve": ["batch", "code"],
        "web.open": ["tailnet"], "web.revoke": [], "tell": ["folder", "text"],
        "send": ["session", "text", "images", "now"],
        "session.new": ["folder", "agent", "model", "preset", "digest", "values"],
        "session.end": ["session"], "session.reply": ["session", "choice", "text", "question", "options"],
        "set": ["key", "value", "folder"], "push": ["folder", "request"], "push.decline": ["folder", "request"],
        "session.reopen": ["all", "forget", "sessions"], "prompt-audit": ["folder", "do"],
        "session.rename": ["session", "name"], "session.pause": ["session", "for", "hours"], "session.resume": ["session"],
        "session.close-shells": ["folder", "sessions"],
        "presets.edit": ["op", "name", "kind", "args", "env", "unset", "keepShell", "default", "rename", "digest", "folder"],
    ]

    /// Why a dialog can't be shown for a request.
    struct ApprovalTextRefusal: Error, Equatable {
        let why: String
    }

    /// The dialog's text for `request`: its word, the decisive part, the context; or why nothing can be asked. On `queue`.
    func approvalCard(_ request: NodeWire.Request) -> Result<String, ApprovalTextRefusal> {
        let args = request.args ?? [:]
        guard let allowed = Self.approvalArguments[request.kind] else {
            return .failure(.init(why: "\(request.kind) has no dialog the Mac can show"))
        }
        if let stray = args.keys.sorted().first(where: { !allowed.contains($0) }) {
            return .failure(.init(why: "\(request.kind) carries a field it doesn't take (\(ConfigSeal.inert(stray, limit: 40))): nothing was asked"))
        }
        guard let action = request.action, UUID(uuidString: action) != nil else {
            return .failure(.init(why: "\(request.kind) has no action id, so its dialog would carry no word: nothing was asked"))
        }
        let parts: (decisive: String, context: String?)
        switch approvalParts(request.kind, args) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let made): parts = made
        }
        let head = "\(NodeIds.code(action: action.lowercased())) · \(parts.decisive)"
        guard head.count <= Self.approvalBudget else {
            return .failure(.init(why: "what \(request.kind) does is too long to show whole in the Mac's dialog (\(head.count) characters, at most \(Self.approvalBudget)): nothing was asked; make it shorter"))
        }
        guard let context = parts.context, !context.isEmpty else { return .success(head) }
        let room = Self.approvalBudget - head.count - 2
        guard room > 8 else { return .success(head) }
        return .success(head + "; " + (context.count <= room ? context : String(context.prefix(room - 1)) + "…"))
    }

    // MARK: Each kind

    private func approvalParts(_ kind: String, _ args: [String: NodeWire.Value]) -> Result<(decisive: String, context: String?), ApprovalTextRefusal> {
        let text = { (key: String) in args[key]?.string }
        // A decisive value is shown whole (`whole`): one too long for the dialog makes the request's text too long, and
        // nothing is asked (`approvalCard`'s budget). Only context is cut.
        func whole(_ value: String) -> String { Self.whole(value) }
        switch kind {
        case "answer", "hold", "config.accept", "base.accept", "base.keep":
            guard let wanted = text("card"), let card = engine?.cards.resolve(wanted) else {
                return .failure(.init(why: "no such card on this node: nothing was asked"))
            }
            return cardParts(kind, card: card, answer: text("text"))
        case "set":
            guard let key = text("key"), let setting = NodeSettings.setting(key), let value = text("value") else {
                return .failure(.init(why: "set needs a known key and a value: nothing was asked"))
            }
            return .success(("set \(setting.key) to \(whole(value))", text("folder").map { "in \(Self.place($0))" } ?? "for the whole node"))
        case "send":
            guard let session = text("session") else { return .failure(.init(why: "send needs a session: nothing was asked")) }
            let words = text("text") ?? ""
            let images = args["images"]?.array?.count ?? 0
            let what = words.isEmpty ? "no words" : whole(words)
            return .success(("type into \(sessionLabel(session)): \(what)" + (images > 0 ? " with \(images) image\(images == 1 ? "" : "s")" : ""),
                             args["now"]?.bool == true ? "now, at its agent's next step" : nil))
        case "session.new":
            guard let folder = text("folder") else { return .failure(.init(why: "session.new needs a folder: nothing was asked")) }
            var what = "start \(text("preset").map { "the preset \(whole($0))" } ?? whole(text("agent") ?? "claude")) in \(Self.place(folder))"
            if let model = text("model") { what += " on \(whole(model))" }
            return .success((what, nil))
        case "session.end": return session(args, "end")
        case "session.resume": return session(args, "resume")
        case "session.rename":
            guard let session = text("session") else { return .failure(.init(why: "session.rename needs a session: nothing was asked")) }
            return .success(("rename \(sessionLabel(session)) to \(text("name").map(whole) ?? "its own name")", nil))
        case "session.pause":
            guard let session = text("session") else { return .failure(.init(why: "session.pause needs a session: nothing was asked")) }
            let how = args["hours"]?.int.map { "for \($0) hours" } ?? text("for").map { ConfigSeal.inert($0, limit: 30) } ?? ""
            return .success(("pause the reminders of \(sessionLabel(session)) \(how)".trimmingCharacters(in: .whitespaces), nil))
        case "session.reply":
            guard let session = text("session"), let choice = args["choice"]?.int else {
                return .failure(.init(why: "session.reply needs a session and a choice: nothing was asked"))
            }
            let typed = text("text").map { " with the words \(whole($0))" } ?? ""
            return .success(("answer \(sessionLabel(session))'s question with option \(choice)\(typed)", nil))
        case "tell":
            guard let folder = text("folder"), let words = text("text") else { return .failure(.init(why: "tell needs a folder and words: nothing was asked")) }
            return .success(("tell the lead of \(Self.place(folder)): \(whole(words))", nil))
        case "lead":
            guard let folder = text("folder") else { return .failure(.init(why: "lead needs a folder: nothing was asked")) }
            let how = args["resume"]?.bool == true ? "reopen the lead of" : args["replace"]?.bool == true ? "replace the lead of" : "start a lead in"
            // The goal is told to the lead as the user's: decisive, whole.
            return .success(("\(how) \(Self.place(folder))" + (text("goal").map { " with the goal \(whole($0))" } ?? ""), nil))
        case "stop":
            let live = link.sessions.filter(\.isLive).count
            return .success(("stop the node, ending \(live) live session\(live == 1 ? "" : "s")", nil))
        case "start": return .success(("start the node", nil))
        case "hooks.install", "hooks.remove":
            let agents = (args["agents"]?.array ?? []).compactMap(\.string).filter { Agent(rawValue: $0) != nil }
            guard !agents.isEmpty else { return .failure(.init(why: "\(kind) needs claude or codex: nothing was asked")) }
            return .success(("\(kind == "hooks.install" ? "install" : "remove") the hooks for \(agents.joined(separator: " and "))", nil))
        case "approve":
            guard let id = text("batch"), let batch = approveBatches.first(where: { $0.id == id }) else {
                return .failure(.init(why: "approve needs a batch this server listed: nothing was asked"))
            }
            let shown = batch.items.map { "\($0.kind) \(Self.place($0.subject))" }.joined(separator: "; ")
            return .success(("do \(batch.items.count) listed accept\(batch.items.count == 1 ? "" : "s"): \(shown)", nil))
        case "build.switch":
            guard let commit = text("commit"), UpdateWatch.isCommit(commit) else { return .failure(.init(why: "build.switch needs a commit: nothing was asked")) }
            return .success(("switch the node to build \(commit.prefix(12))", nil))
        case "web.open": return .success(("open the web page to one browser \(args["tailnet"]?.bool == true ? "on your tailnet" : "on this machine")", nil))
        case "web.revoke": return .success(("revoke every web page's access", nil))
        case "push", "push.decline":
            guard let folder = text("folder") else { return .failure(.init(why: "\(kind) needs a folder: nothing was asked")) }
            let root = repositoryOf(folder)
            let pending = engine?.leads.leads.values.first { $0.root == root }?.push
            let what = pending.map { "\($0.branch) at \($0.commit.prefix(12)) (\($0.ahead) commit\($0.ahead == 1 ? "" : "s")) to \(PushText.displayURL($0.url))" } ?? "its branch"
            return .success(("\(kind == "push" ? "push" : "decline the push of") \(ConfigSeal.inert(what, limit: 120)) for \(LeadMail.project(of: root))", nil))
        case "session.reopen":
            if args["forget"]?.bool == true { return .success(("forget the sessions offered to reopen", nil)) }
            let count = args["sessions"]?.array?.count ?? 0
            return .success(("reopen \(args["all"]?.bool == true ? "every session offered" : "\(count) session\(count == 1 ? "" : "s")") in their conversations", nil))
        case "prompt-audit":
            guard let folder = text("folder"), let what = text("do"), ["snooze", "off", "on"].contains(what) else {
                return .failure(.init(why: "prompt-audit needs a folder and snooze, off or on: nothing was asked"))
            }
            return .success(("turn the prompt-audit reminder \(what == "snooze" ? "off for a week" : what) in \(Self.place(folder))", nil))
        case "session.close-shells":
            let count = args["sessions"]?.array?.count
            return .success(("close \(count.map { "\($0) finished shell\($0 == 1 ? "" : "s")" } ?? "the finished shells")", text("folder").map { "in \(Self.place($0))" }))
        case "presets.edit":
            guard let op = text("op"), let name = text("name") else { return .failure(.init(why: "presets.edit needs an op and a name: nothing was asked")) }
            // Every field that changes the preset, whole: its kind, its command, each variable set or unset, a new name,
            // whether it is the default and whether a shell stays.
            var what = "\(whole(op)) the launch preset \(whole(name))"
            if let kind = text("kind") { what += " (\(whole(kind)))" }
            if let rename = text("rename") { what += " renamed \(whole(rename))" }
            if let command = text("args") { what += ": runs \(whole(command))" }
            let env = (args["env"]?.object ?? [:]).sorted { $0.key < $1.key }.map { "\(whole($0.key))=\(whole($0.value.string ?? ""))" }
            if !env.isEmpty { what += " with \(env.joined(separator: " "))" }
            let unset = (args["unset"]?.array ?? []).compactMap(\.string)
            if !unset.isEmpty { what += " unsetting \(unset.map(whole).joined(separator: " "))" }
            if let isDefault = args["default"]?.bool { what += isDefault ? " as the folder's default" : " no longer the default" }
            if let keep = args["keepShell"]?.bool { what += keep ? ", a shell kept after it" : ", no shell after it" }
            return .success((what, text("folder").map { "for \(Self.place($0))" }))
        default:
            return .failure(.init(why: "\(kind) has no dialog the Mac can show"))
        }
    }

    private func session(_ args: [String: NodeWire.Value], _ verb: String) -> Result<(decisive: String, context: String?), ApprovalTextRefusal> {
        guard let session = args["session"]?.string else { return .failure(.init(why: "it needs a session: nothing was asked")) }
        return .success(("\(verb) \(sessionLabel(session))", nil))
    }

    /// A card's decisive part: the answer's words (and an approval's commit and tasks, or a shell card's command and
    /// folder), a config card's counts, a base move; then the lead's words, marked and bounded.
    private func cardParts(_ kind: String, card: CardStore.Card, answer: String?) -> Result<(decisive: String, context: String?), ApprovalTextRefusal> {
        let project = LeadMail.project(of: card.root)
        let asks = card.question.map { "the lead asks \(Self.quoted($0.text, limit: 200))" }
        switch kind {
        case "answer":
            if let shell = card.shell {
                // The same reading `answerShell` acts on (`ShellCards.answerWord`): run, decline, or nothing asked.
                switch ShellCards.answerWord(answer ?? "") {
                case nil: return .failure(.init(why: "a shell card is answered run or decline: nothing was asked"))
                case "decline"?: return .success(("decline an agent's shell request", "in \(Self.place(shell.request.cwd))"))
                default: break
                }
                // The command and the folder whole, or nothing asked.
                guard !shell.request.command.contains("\n") else {
                    return .failure(.init(why: "the shell request's command has more than one line, too much to show whole in the Mac's dialog: nothing was asked"))
                }
                return .success(("run an agent's command in your login shell: \(Self.whole(shell.request.command)) in \(Self.place(shell.request.cwd))", nil))
            }
            guard let words = answer, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.init(why: "an answer needs words: nothing was asked"))
            }
            if let approval = card.approval {
                let tasks = approval.tasks.isEmpty ? "" : " (task\(approval.tasks.count == 1 ? "" : "s") \(ConfigSeal.inert(approval.tasks.joined(separator: ", "), limit: 60)))"
                return .success(("answer \(Self.whole(words)) to merging \(approval.commit.prefix(12))\(tasks) in \(project)", asks))
            }
            return .success(("answer \(Self.whole(words)) in \(project)", asks))
        case "hold":
            return .success(("hold the timer of a question in \(project)", asks))
        case "config.accept":
            let config = card.config
            let items = config?.items.count ?? 0
            let rails = config?.guarded.filter { !($0.sinceAccept?.hasPrefix("the same") ?? false) }.count ?? 0
            let names = config?.items.map(\.name).joined(separator: ", ") ?? ""
            return .success(("accept \(items) held item\(items == 1 ? "" : "s") and \(rails) guard rail\(rails == 1 ? "" : "s") changed in \(project)",
                             names.isEmpty ? nil : "held: \(ConfigSeal.inert(names, limit: 200))"))
        default:
            guard let base = card.base else { return .failure(.init(why: "no base move on that card: nothing was asked")) }
            let move = "\(base.branch) from \(base.from.map { String($0.prefix(10)) } ?? "unknown") to \(base.to.prefix(10)) (\(base.commits.count) commit\(base.commits.count == 1 ? "" : "s"))"
            return .success(("\(kind == "base.accept" ? "accept" : "keep refused") the move of \(ConfigSeal.inert(move, limit: 120)) in \(project)", nil))
        }
    }

    // MARK: Words

    /// A session as the dialog names it: its terminal and folder (never its raw id), or the id's first part when the
    /// node lists none.
    func sessionLabel(_ id: String) -> String {
        if let session = sessions?.sessions.first(where: { NodeSessions.id(of: $0) == id }) {
            let folder = session.cwd.map { ($0 as NSString).lastPathComponent } ?? "?"
            return "the session on \(ConfigSeal.inert(session.tty, limit: 20)) in \(ConfigSeal.inert(folder, limit: 40))"
        }
        return "session \(ConfigSeal.inert(String(id.replacingOccurrences(of: NodeIds.node + ":", with: "").prefix(8)), limit: 8))"
    }

    /// A folder as the dialog names it: its last part, then where it is.
    static func place(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return "\(ConfigSeal.inert(name, limit: .max)) (\(ConfigSeal.inert(path, limit: .max)))"
    }

    /// A decisive value, marked “…”, on one line (a line break shown as ⏎), inert, never cut: too long, and the request's
    /// text doesn't fit the dialog, so nothing is asked.
    static func whole(_ text: String) -> String {
        "“" + ConfigSeal.inert(text.replacingOccurrences(of: "\n", with: " ⏎ "), limit: .max) + "”"
    }

    /// Words someone else wrote, marked as theirs: “…”, on one line, inert, cut at `limit` with an ellipsis.
    static func quoted(_ text: String, limit: Int) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        let inert = ConfigSeal.inert(line, limit: .max)
        return "“" + (inert.count <= limit ? inert : String(inert.prefix(limit - 1)) + "…") + "”"
    }

}
