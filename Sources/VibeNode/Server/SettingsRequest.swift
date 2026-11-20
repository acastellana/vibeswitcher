import Foundation
import VibeCore

/// `settings` and `set` (the parity table's gap 9; `NodeSettings`).
///
/// - `settings [folder]`: a read (anyone of the uid, no code; a web page's token reads it): the node's settings and,
///   with a folder, those of the project holding it (its repository's top), each with its value, its default, where it
///   lives and whether it is a guard rail; and what the app has that a node leaves out. A folder no lead has worked in
///   is `gone`.
/// - `set [folder] key value`: the user's voice, recorded in the vault before it acts (`Requests.recorded`), its typed
///   code the command line's (as `tell`'s: no card). A page never sets: it drafts the `vibeswitcher set …` line for a
///   terminal. The change is written where the app writes it; a guard rail's hash recorded as the user's; then the
///   engine tells: the policy to every running lead, a project's change to its lead, and boost and the room looked at
///   again after a limit's.
extension Requests {
    func settings(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let files = NodeSettings.Files(root: root)
        let folder = request.args?["folder"]?.string
        if let folder, !folder.hasPrefix("/") { return reply(.init(re: request.id, error: .init(.badArgs, "folder is an absolute path"))) }
        let (find, vault, home) = (repositoryOf, link.vault, self.home)
        (engine?.work ?? DispatchQueue.global(qos: .userInitiated)).async {
            var result: [String: NodeWire.Value] = [
                "node": .object(["root": .string(files.root.path), "settings": .array(NodeSettings.node(files: files).map(\.wire))]),
                "project": .null,
                "leftOut": .array(NodeSettings.leftOut.map { .object(["title": .string($0.title), "why": .string($0.why)]) }),
            ]
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
                result["project"] = .object(["project": .string(NodeIds.project(root: root)), "root": .string(root),
                                             "settings": .array(shown.map(\.wire))])
            }
            reply(.init(re: request.id, result: .object(result)))
        }
    }

    func set(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let refuse = { (code: NodeWire.Code, why: String) in reply(.init(re: request.id, error: .init(code, why))) }
        guard let key = request.args?["key"]?.string, let setting = NodeSettings.setting(key) else {
            return refuse(.badArgs, "set needs key, one of `vibeswitcher settings`'s")
        }
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
                    var result: [String: NodeWire.Value] = ["key": .string(key), "value": .string(Self.capped(applied.value)),
                                                            "was": .string(Self.capped(applied.was)), "scope": .string(setting.scope.rawValue),
                                                            "project": root.map { .string(NodeIds.project(root: $0)) } ?? .null]
                    guard let engine else {
                        result["told"] = .null
                        return reply(.init(re: request.id, result: .object(result)))
                    }
                    engine.settingChanged(key, root: root, told: applied.told) { told in
                        result["told"] = told ? .string(setting.scope == .node ? "leads" : "lead") : .null
                        reply(.init(re: request.id, result: .object(result)))
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
}

extension NodeSettings.Shown {
    /// As the wire carries it (`WireSchema`'s `setting`): every string from the files capped (a session can write
    /// workflow.md), shown as text, never markup.
    public var wire: NodeWire.Value {
        let limits: String? = {
            switch setting.form {
            case .count: return setting.range.map { "\($0.lowerBound) to \($0.upperBound)" }
            case .number: return "above 0" + (setting.ceiling.map { ", at most \(MacLoad.number($0))" } ?? "")
            case .flag: return "on or off"
            case .choice: return setting.choices.joined(separator: ", ")
            case .model: return "a model's name as claude --model takes it"
            case .paths: return "globs, comma-separated; none for no paths"
            case .text: return "at most \(NodeSettings.policyLimit) characters"
            }
        }()
        return .object([
            "key": .string(setting.key), "title": .string(setting.title), "about": .string(setting.about), "section": .string(setting.section),
            "scope": .string(setting.scope.rawValue), "form": .string(setting.form.rawValue), "home": .string(setting.home.rawValue),
            "choices": .array(setting.choices.map(NodeWire.Value.string)), "limits": limits.map(NodeWire.Value.string) ?? .null,
            "value": .string(Requests.capped(self.value)), "default": .string(Requests.capped(defaultValue)), "isDefault": .bool(isDefault),
            "where": .string(place), "guardRail": .bool(setting.guardRail), "note": note.map(NodeWire.Value.string) ?? .null,
        ])
    }
}
