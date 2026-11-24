import Foundation
import VibeCore

/// `settings` and `set` (the parity table's gap 9; `NodeSettings`).
///
/// - `settings [folder]`: a read (anyone of the uid, no code; a web page's token reads it): the node's settings and,
///   with a folder, those of the project holding it (its repository's top), each with its value, its default, where it
///   lives and whether it is a guard rail; and what the app has that a node leaves out. A folder no lead has worked in
///   is `gone`. And the account's usage as the node keeps it (`NodeUsage`), read-only.
/// - `set [folder] key value`: the user's voice, recorded in the vault before it acts (`Requests.recorded`), its typed
///   code the command line's (as `tell`'s: no card). A page never sets: it drafts the `vibeswitcher set …` line for a
///   terminal. The change is written where the app writes it; a guard rail's hash recorded as the user's; then the
///   engine tells: the policy to every running lead, a project's change to its lead, and boost and the room looked at
///   again after a limit's.
extension Requests {
    func settings(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let files = NodeSettings.Files(root: root)
        let folder: String?
        switch request.typedArgs(WireKinds.Settings.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let typed): folder = typed.folder
        }
        if let folder, !folder.hasPrefix("/") { return reply(.init(re: request.id, error: .init(.badArgs, "folder is an absolute path"))) }
        let (find, vault, home, queue) = (repositoryOf, link.vault, self.home, self.queue)
        // Read off the queue, answered on it (`Requests` answers on `queue`: the server writes the reply from there). It
        // answered from the reading queue until 2026-11-22, racing the server's own writes on the connection: the
        // server crashed under load ("Can't remove more items", `NodeServer.flush`), and the CLI found it gone.
        let reply = { (answer: NodeWire.Reply) in queue.async { reply(answer) } }
        // The plugins that are on add their own sections (`PluginSettings.swift`); an off one's are absent.
        let plugins = engine?.pluginSettingsShown ?? []
        let acting = self.actingPages
        (engine?.work ?? DispatchQueue.global(qos: .userInitiated)).async {
            // Acting from the page as the vault says (asked here, off the queue), never a file.
            let actingNow = acting.map { $0.refreshLater(); $0.settled(); return $0.state?.on == true ? "on" : "off" } ?? "off"
            let node = NodeSettings.node(files: files).map { shown in
                var shown = shown
                if shown.setting.home == .acting { shown.value = actingNow }
                return shown
            }
            var result = WireKinds.Settings.Result(
                node: .init(root: files.root.path, settings: (node + plugins).map(\.typed)), project: nil,
                leftOut: NodeSettings.leftOut.map { .init(title: $0.title, why: $0.why) },
                // The account's usage, read here (off the engine's queue) as the account watch reads it.
                usage: NodeUsage.value(NodeUsage.read(files: files, home: home)))
            if let folder {
                let root = find(folder)
                let path = NodeSettings.workflowPath(project: root)
                guard FileManager.default.fileExists(atPath: path) else {
                    let shown = ConfigSeal.inert(root, limit: 200)
                    return reply(.init(re: request.id, error: .init(.gone, "no lead has worked in \(shown) yet: `vibeswitcher lead \(shown)` starts one")))
                }
                let floor = Result { try vault.reviewFloor(root: root) }
                let problem: String? = { if case .failure(let error) = floor { return "\(error)" } else { return nil } }()
                let shown = NodeSettings.project(root: root, workflow: LeadWorkflow.load(from: path), floor: (try? floor.get()) ?? nil,
                                                 floorProblem: problem, workerModel: Self.workerModel(home: home), files: files)
                result.project = .init(project: NodeIds.project(root: root), root: root, settings: shown.map(\.typed))
            }
            reply(.init(re: request.id, typed: result))
        }
    }

    /// The setting `set` takes `key` for: the node's (an alias its own key), else an on plugin's (`<plugin>_<name>`); nil
    /// for none. The one resolution: `set` and an acting page's refusal (`pageSetRefusal`) both ask it. On `queue`.
    func setting(named key: String) -> NodeSettings.Setting? {
        if let setting = NodeSettings.setting(key) { return setting }
        return engine?.pluginSetting(key).map { LeadEngine.catalogSetting($0.plugin, $0.setting) }
    }

    func set(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let refuse = { (code: NodeWire.Code, why: String) in reply(.init(re: request.id, error: .init(code, why))) }
        // Asked again here for a request an acting page made (its mark kept while it is done): the same resolution as
        // the refusal before its record, so no spelling gets past.
        if let action = request.action?.lowercased(), pageMarks[action] != nil, let why = pageSetRefusal(request) {
            return refuse(.voice, why)
        }
        // A plugin's setting (one that is on): kept in the vault (`LeadEngine.setPluginSetting`).
        if let asked = request.args?["key"]?.string, NodeSettings.setting(asked) == nil, let engine, engine.pluginSetting(asked) != nil {
            guard request.args?["folder"] == nil else { return refuse(.badArgs, "\(asked) is the node's, for every project: name no folder") }
            guard let given = request.args?["value"]?.string else { return refuse(.badArgs, "set needs value (default puts it back)") }
            return engine.setPluginSetting(asked, given: given) { result in
                switch result {
                case .failure(.badArgs(let why)): refuse(.badArgs, why)
                case .failure(.gone(let why)), .failure(.refused(let why)): refuse(.refused, why)
                case .success(let applied):
                    reply(.init(re: request.id, typed: WireKinds.SetSetting.Result(key: asked, value: Self.capped(applied.value), was: Self.capped(applied.was),
                                                                                scope: "node", project: nil, told: nil)))
                }
            }
        }
        guard let asked = request.args?["key"]?.string, let setting = NodeSettings.setting(asked) else {
            return refuse(.badArgs, "set needs key, one of `vibeswitcher settings`'s")
        }
        // An alias (`NodeSettings.aliases`: the app's mac_… names) is the setting's own key from here on.
        let key = setting.key
        if setting.home == .acting { return setActing(request, reply: reply) }
        guard let given = request.args?["value"]?.string else { return refuse(.badArgs, "set needs value (default puts it back)") }
        let folder = request.args?["folder"]?.string
        switch (setting.scope, folder) {
        case (.project, nil): return refuse(.badArgs, "\(key) is a project's: name its folder (`vibeswitcher set FOLDER \(key) VALUE`)")
        case (.node, _?): return refuse(.badArgs, "\(key) is the node's, for every project: name no folder")
        case (.project, let folder?) where !folder.hasPrefix("/"): return refuse(.badArgs, "folder is an absolute path")
        default: break
        }
        let value: String?
        switch NodeSettings.parse(setting, given) {
        case .failure(let refusal): return refuse(.badArgs, refusal.description)
        case .success(let taken): value = taken
        }
        let files = NodeSettings.Files(root: root)
        let (find, vault, home, engine, queue, note) = (repositoryOf, link.vault, self.home, self.engine, self.queue, self.note)
        (engine?.work ?? DispatchQueue.global(qos: .userInitiated)).async {
            let root = folder.map(find)
            let applied = Result {
                try root.map { try NodeSettings.setProject(setting, to: value, root: $0, vault: vault, workerModel: Self.workerModel(home: home), files: files) }
                    ?? NodeSettings.setNode(setting, to: value, files: files)
            }
            queue.async {
                switch applied {
                case .failure(let error):
                    note("set \(key): not changed: \(error)")
                    refuse(.refused, ConfigSeal.inert("\(error)", limit: 2_000))
                case .success(let applied):
                    note("set \(key)" + (root.map { " in \(LeadMail.project(of: $0))" } ?? "") + ": changed")
                    var result = WireKinds.SetSetting.Result(key: key, value: Self.capped(applied.value), was: Self.capped(applied.was),
                                                             scope: setting.scope.rawValue, project: root.map { NodeIds.project(root: $0) }, told: nil)
                    guard let engine else { return reply(.init(re: request.id, typed: result)) }
                    engine.settingChanged(key, root: root, told: applied.told) { told in
                        result.told = told ? (setting.scope == .node ? "leads" : "lead") : nil
                        reply(.init(re: request.id, typed: result))
                    }
                }
            }
        }
    }

    /// The model the workers start with, as the floor compares a verifier with: `home`'s Claude settings' (the lead's
    /// tool server reads its command's), else nil (Claude's default, which the floor counts as opus).
    static func workerModel(home: String) -> String? { LeadWorkflow.claudeModel(command: "claude", home: home) }

    /// A value as sent: at most the working policy's limit.
    static func capped(_ text: String) -> String { String(text.prefix(NodeSettings.policyLimit)) }

    /// `set web_acts on|off` (the user's voice, recorded first): kept in the vault (`ActingPages.set`), never a file. On
    /// says what it means; off closes the acting pages' connections and drops their tokens' acting, so on again needs a
    /// new pairing. A page never turns it on (`pageSetRefusal`). On `queue`.
    func setActing(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let refuse = { (code: NodeWire.Code, why: String) in reply(.init(re: request.id, error: .init(code, why))) }
        guard request.args?["folder"] == nil else { return refuse(.badArgs, "web_acts is the node's: name no folder") }
        guard let given = request.args?["value"]?.string, ["on", "off", "default"].contains(given) else {
            return refuse(.badArgs, "web_acts is on or off (default: off)")
        }
        guard let acting = actingPages else { return refuse(.refused, "this server has no web page") }
        let on = given == "on", queue = self.queue, note = self.note
        let was = acting.state?.on == true ? "on" : "off"
        DispatchQueue.global(qos: .userInitiated).async {
            let kept = Result { try acting.set(on: on) }
            queue.async {
                switch kept {
                case .failure(let error):
                    note("set web_acts: not changed: \(error)")
                    refuse(.refused, ConfigSeal.inert("\(error)", limit: 2_000))
                case .success(let acts):
                    var result = WireKinds.SetSetting.Result(key: "web_acts", value: acts.on ? "on" : "off", was: was, scope: "node", project: nil, told: nil)
                    result.say = acts.on ? Self.actingOnSaid : Self.actingOffSaid
                    reply(.init(re: request.id, typed: result))
                }
            }
        }
    }

    /// What turning acting from the page on means, said to the terminal that turns it on (the user's decision of
    /// 2026-11-23, and what it costs).
    static let actingOnSaid = [
        "Acting from the page is on. A page on this machine (http://127.0.0.1), paired from now on with `vibeswitcher web`, may do",
        "everything the command line does, as you, with no code typed: answer and approve, accept, send, tell, start and end sessions,",
        "settings, stop. Each act is recorded in the host's vault as yours, marked as the page's.",
        "What it costs: any process that reaches a paired page's token can act as you, a team's own session included (it could",
        "approve its own merge). A page reached over the tailnet still only reads and drafts.",
        "Pages paired before now don't act: run `vibeswitcher web` and open its address. `vibeswitcher set web_acts off` ends it.",
    ]

    static let actingOffSaid = [
        "Acting from the page is off: every acting page's connection was closed, and no page token acts any more.",
        "Pages still read and draft. Turning it on again needs a new pairing (`vibeswitcher web`).",
    ]
}

extension NodeSettings.Shown {
    /// As the wire carries it (`WireSchema`'s `setting`): every string from the files capped (a session can write
    /// workflow.md), shown as text, never markup.
    public var wire: NodeWire.Value { NodeWire.Value(wire: typed) }

    /// As `settings` gives it (`WireKinds.Settings.Setting`).
    public var typed: WireKinds.Settings.Setting {
        let limits: String? = {
            switch setting.form {
            case .count: return setting.range.map { "\($0.lowerBound) to \($0.upperBound)" }
            case .number: return "above 0" + (setting.ceiling.map { ", at most \(MacLoad.number($0))" } ?? "")
            case .flag: return "on or off"
            case .choice: return setting.choices.joined(separator: ", ")
            case .model: return "a model's name as claude --model takes it"
            case .paths: return "globs, comma-separated; none for no paths"
            case .text: return "at most \(NodeSettings.policyLimit) characters"
            case .folder: return "a full path, or one under ~"
            }
        }()
        return .init(key: setting.key, title: setting.title, about: setting.about, section: setting.section, scope: setting.scope.rawValue,
                     form: setting.form.rawValue, home: setting.home.rawValue, choices: setting.choices, limits: limits,
                     value: Requests.capped(self.value), default: Requests.capped(defaultValue), isDefault: isDefault, where: place,
                     guardRail: setting.guardRail, note: note)
    }

}
