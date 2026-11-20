import Foundation
import VibeCore

// MARK: presets.edit

/// Editing the node's launch presets (the page-actions lane, 2026-11-20; the app's Settings › Presets): a preset added,
/// changed or removed in the node's `presets.json`, in the user's voice (`vibeswitcher preset`, recorded). Under the
/// rules the node starts presets by (`SessionPresets.refusal`): Claude as `claude` and plain words, only the reviewed
/// variables, no built-in's name, no Codex; the built-ins themselves are VibeSwitcher's and never edited. What the
/// file holds beyond the preset edited (another app's fields, an entry this build can't read) is kept as it is: the
/// file is edited as JSON, not decoded and written again. The file changes, so the config seal holds it: a preset of it
/// starts once the user accepts it (`config held`, then `config accept`), as any change to it.
enum PresetEdit {
    /// What the user asked: `op` (add, edit or remove) on the preset `name`, one `folder`'s (absolute) or every folder's.
    struct Asked {
        var op: String
        var name: String
        var folder: String?
        /// For edit and remove: the preset as the user was shown it (`SessionPresets.digest`).
        var digest: String?
        var rename: String?
        var kind: LaunchPreset.Kind?
        /// The words after `claude` (nil: as they are; an add's: none).
        var args: String?
        var env: [String: String] = [:]
        var unset: [String] = []
        var keepShell: Bool?
        var makeDefault = false
    }

    /// The edit's outcome: the file's new bytes, and what the reply says.
    struct Done {
        var data: Data
        var result: [String: NodeWire.Value]
    }

    /// The longest name a preset takes.
    static let nameLimit = 80

    /// `asked` from a request's args, or why it can't be.
    static func asked(_ args: [String: NodeWire.Value]?) -> Result<Asked, SessionPresets.Refusal> {
        let refuse = { (why: String) in Result<Asked, SessionPresets.Refusal>.failure(.init(message: why)) }
        guard let op = args?["op"]?.string, ["add", "edit", "remove"].contains(op) else { return refuse("presets.edit's op is add, edit or remove") }
        guard let name = args?["name"]?.string, !name.isEmpty else { return refuse("presets.edit needs name") }
        var asked = Asked(op: op, name: name)
        if let folder = args?["folder"]?.string {
            guard folder.hasPrefix("/") else { return refuse("presets.edit's folder is an absolute path") }
            asked.folder = (folder as NSString).standardizingPath
        }
        asked.digest = args?["digest"]?.string
        if op != "add", asked.digest == nil { return refuse("presets.edit's \(op) needs the digest of the preset shown") }
        asked.rename = args?["rename"]?.string
        if let kind = args?["kind"]?.string {
            guard let known = LaunchPreset.Kind(rawValue: kind), known != .codex else { return refuse("a preset's kind here is claude or shell") }
            asked.kind = known
        }
        asked.args = args?["args"]?.string
        if let env = args?["env"] {
            guard let object = env.object else { return refuse("presets.edit's env maps names to values") }
            for (key, value) in object {
                guard let text = value.string else { return refuse("presets.edit's env maps names to values") }
                asked.env[key] = text
            }
        }
        asked.unset = args?["unset"]?.array?.compactMap(\.string) ?? []
        asked.keepShell = args?["keepShell"]?.bool
        asked.makeDefault = args?["default"]?.bool ?? false
        if asked.makeDefault, asked.folder == nil { return refuse("a default is a folder's: give the folder") }
        if op == "remove", asked.rename != nil || asked.kind != nil || asked.args != nil || !asked.env.isEmpty || !asked.unset.isEmpty
            || asked.keepShell != nil || asked.makeDefault {
            return refuse("a remove takes only the name and folder")
        }
        return .success(asked)
    }

    /// Why `name` can't be a preset's (nil: it can): empty, too long, a control character, a leading dash.
    static func nameRefusal(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "a preset needs a name" }
        if name != name.trimmingCharacters(in: .whitespaces) { return "a preset's name doesn't start or end with a space" }
        if name.count > nameLimit { return "a preset's name is at most \(nameLimit) characters" }
        if name.hasPrefix("-") { return "a preset's name doesn't start with -" }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "a preset's name holds no control characters" }
        return nil
    }

    /// `asked` applied to the file's bytes (`data`; nil: there is none): the bytes to write, or why nothing changes.
    /// A new file starts with the built-ins, as the app writes it (an app reading a file whose global presets have none
    /// would lose them).
    static func apply(_ asked: Asked, to data: Data?) -> Result<Done, SessionPresets.Refusal> {
        let refuse = { (why: String) in Result<Done, SessionPresets.Refusal>.failure(.init(message: why)) }
        let blank = data.map { $0.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 } } ?? true
        var file: [String: Any]
        if blank {
            guard asked.op == "add" else { return refuse("there are no presets of yours to \(asked.op): `vibeswitcher preset add` makes one") }
            file = ["global": LaunchPresets.builtIns().global.compactMap(json), "byProject": [String: Any](), "defaults": [String: Any]()]
        } else {
            guard let data, let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
                return refuse("presets.json isn't readable JSON: fix it, or move it aside, before editing presets here")
            }
            file = dictionary
        }
        // Where the preset is: a folder's (its nearest project folder that keeps presets, or the folder itself for a new
        // one), or every folder's.
        let decoded = data.map(SessionPresets.decode)?.presets ?? LaunchPresets(global: [])
        let project = asked.folder.map { SessionPresets.projectRoot(of: $0, in: decoded) ?? $0 }
        var projects = file["byProject"] as? [String: Any] ?? [:]
        if file["byProject"] != nil, file["byProject"] as? [String: Any] == nil { return refuse("presets.json's byProject isn't an object: fix it first") }
        var list: [Any]
        if let project {
            guard projects[project] == nil || projects[project] is [Any] else { return refuse("presets.json's presets for that folder aren't a list: fix it first") }
            list = projects[project] as? [Any] ?? []
        } else {
            guard file["global"] == nil || file["global"] is [Any] else { return refuse("presets.json's global presets aren't a list: fix it first") }
            list = file["global"] as? [Any] ?? []
        }
        let place = project.map { "for \(ConfigSeal.inert($0, limit: 200))" } ?? "for every folder"
        let shown = ConfigSeal.inert(asked.name, limit: 80)
        // The entries there by name: the same name, else the same ignoring case (as `SessionPresets.named` finds them).
        func index(of name: String, exact: Bool) -> Int? {
            list.firstIndex { (($0 as? [String: Any])?["name"] as? String).map { exact ? $0 == name : $0.caseInsensitiveCompare(name) == .orderedSame } ?? false }
        }
        var defaults = file["defaults"] as? [String: Any] ?? [:]
        var preset: LaunchPreset
        var entry: [String: Any]
        let at: Int?
        switch asked.op {
        case "add":
            if let why = nameRefusal(asked.name) { return refuse(why) }
            if index(of: asked.name, exact: false) != nil { return refuse("there is a preset \(shown) \(place) already: `vibeswitcher preset edit` changes it") }
            let kind = asked.kind ?? .claude
            preset = LaunchPreset(name: asked.name, kind: kind, command: kind == .claude ? command(asked.args ?? "") : "", env: asked.env,
                                  keepShell: asked.keepShell ?? false)
            guard let made = json(preset) else { return refuse("the preset couldn't be written") }
            entry = made
            at = nil
        default:
            guard let found = index(of: asked.name, exact: true) ?? index(of: asked.name, exact: false), let old = list[found] as? [String: Any],
                  let current = decode(old) else {
                return refuse("there is no preset \(shown) of yours \(place) (`vibeswitcher presets` lists them)")
            }
            if SessionPresets.isBuiltInCopy(current) {
                return refuse("\(shown) is a built-in preset, which comes from VibeSwitcher itself and isn't edited here")
            }
            guard SessionPresets.matches(current, digest: asked.digest) else {
                return refuse("preset \(shown) changed since it was shown (or the node's server restarted since): nothing changed; run the command again to see it as it is now")
            }
            at = found
            preset = current
            entry = old
            if asked.op == "remove" {
                list.remove(at: found)
                // A folder's default that was it is no folder's default any more.
                for (key, value) in defaults where (value as? String).flatMap(UUID.init(uuidString:)) == current.id { defaults[key] = nil }
                return finish(&file, list: list, projects: &projects, project: project, defaults: defaults,
                              result: ["op": .string("remove"), "name": .string(current.name), "folder": project.map(NodeWire.Value.string) ?? .null])
            }
            if let rename = asked.rename, rename != current.name {
                if let why = nameRefusal(rename) { return refuse(why) }
                if let other = index(of: rename, exact: false), other != found {
                    return refuse("there is a preset \(ConfigSeal.inert(rename, limit: 80)) \(place) already")
                }
                preset.name = rename
            }
            if let kind = asked.kind, kind != preset.kind {
                preset.kind = kind
                if kind == .shell { preset.command = "" } else if asked.args == nil { preset.command = "claude" }
            }
            if let args = asked.args {
                guard preset.kind == .claude else { return refuse("a shell preset takes no arguments") }
                preset.command = command(args)
            }
            for name in asked.unset {
                guard preset.env[name] != nil else { return refuse("preset \(shown) sets no \(ConfigSeal.inert(name, limit: 64))") }
                preset.env[name] = nil
            }
            if let keep = asked.keepShell { preset.keepShell = keep }
        }
        if asked.op == "edit" {
            for (name, value) in asked.env { preset.env[name] = value }
        }
        // The node's own rules: what it would refuse to start, it doesn't write.
        if let why = SessionPresets.refusal(preset) { return refuse("preset \(ConfigSeal.inert(preset.name, limit: 80)) can't be kept: \(why)") }
        entry["name"] = preset.name
        entry["kind"] = preset.kind.rawValue
        entry["command"] = preset.command
        entry["env"] = preset.env
        entry["keepShell"] = preset.keepShell
        if let at { list[at] = entry } else { list.append(entry) }
        if asked.makeDefault, let project { defaults[project] = preset.id.uuidString }
        return finish(&file, list: list, projects: &projects, project: project, defaults: defaults, result: [
            "op": .string(asked.op), "name": .string(preset.name), "folder": project.map(NodeWire.Value.string) ?? .null,
            "env": .array(preset.env.keys.sorted().map(NodeWire.Value.string)),
        ])
    }

    private static func finish(_ file: inout [String: Any], list: [Any], projects: inout [String: Any], project: String?, defaults: [String: Any],
                               result: [String: NodeWire.Value]) -> Result<Done, SessionPresets.Refusal> {
        if let project {
            projects[project] = list
            file["byProject"] = projects
        } else {
            file["global"] = list
        }
        file["defaults"] = defaults
        guard let data = try? JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return .failure(.init(message: "the presets couldn't be written as JSON"))
        }
        return .success(Done(data: data, result: result))
    }

    /// Why an edit can't start from `data`, the presets file's bytes as read (nil: it can), failing closed (the
    /// security review of 2026-11-20): an edit is written in the user's voice, so it starts only from the file as the
    /// user accepted it (`Requests.presetsBaselineRefusal`: the seal's record and the user's own accept of exactly
    /// these bytes), never carrying in what anyone else wrote there since. No file, or one with nothing in it, carries
    /// nothing: the edit starts from the built-ins. Asks the vault: never on the engine's queue.
    static func unacceptedRefusal(_ data: Data?, vault: LeadVault?, home: String, nodeRoot: URL) -> String? {
        guard let data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return nil }
        let file = SessionPresets.decode(data)
        guard let why = Requests.presetsBaselineRefusal(vault: vault, home: home, nodeRoot: nodeRoot, file: file, folder: "FOLDER") else { return nil }
        return "presets.json has changes you haven't accepted (\(why)): review them with `vibeswitcher config held` and accept them first; nothing changed"
    }

    /// A Claude preset's command: `claude` and the words given.
    static func command(_ args: String) -> String {
        (["claude"] + args.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)).joined(separator: " ")
    }

    /// `preset` as the app writes it, as a JSON object.
    static func json(_ preset: LaunchPreset) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(preset) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// An entry of the file as a preset (the app's lenient decode), or nil.
    static func decode(_ entry: [String: Any]) -> LaunchPreset? {
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
        return try? JSONDecoder().decode(LaunchPreset.self, from: data)
    }

    /// `data` written as the node's presets file: a new file beside it (`O_EXCL | O_NOFOLLOW`, 0600), synced, then
    /// renamed over it (a link there is replaced, never followed), and only while the file is still `was` (nil: none).
    static func write(_ data: Data, root: URL, was: Data?) -> SessionPresets.Refusal? {
        let path = root.appendingPathComponent(VibePaths.presetsFile.lastPathComponent).path
        let temporary = path + ".edit-" + UUID().uuidString.lowercased()
        let fd = Sys.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .init(message: "a new presets file couldn't be made beside it (errno \(errno))") }
        var ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let wrote = Sys.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else { return false }
                offset += wrote
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        Sys.close(fd)
        guard ok else {
            unlink(temporary)
            return .init(message: "the new presets file couldn't be written")
        }
        // Still as it was read: another writer's change in between isn't lost.
        let now: Data?
        switch SessionPresets.bytes(root: root) {
        case .success(let data): now = data
        case .failure(let refusal):
            unlink(temporary)
            return refusal
        }
        guard now == was else {
            unlink(temporary)
            return .init(message: "presets.json changed while it was being edited: nothing changed; run the command again")
        }
        guard rename(temporary, path) == 0 else {
            let failure = errno
            unlink(temporary)
            return .init(message: "presets.json couldn't be replaced (errno \(failure))")
        }
        return nil
    }
}

extension Requests {
    /// `presets.edit` with `op` (add, edit, remove), `name`, `folder?` (absolute: a project's preset, else every
    /// folder's), `digest` (an edit's or remove's: the preset as shown), and for add and edit `rename?`, `kind?` (claude
    /// or shell), `args?` (the words after `claude`), `env?` (names to values, set), `unset?` (names), `keepShell?`,
    /// `default?` (the folder's default) (the page-actions lane, 2026-11-20): `PresetEdit` on the node's presets file. The
    /// user's voice, recorded. The reply names the preset and says the seal now holds the file until the user accepts it.
    func editPreset(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let asked: PresetEdit.Asked
        switch PresetEdit.asked(request.args) {
        case .failure(let refusal): return reply(.init(re: request.id, error: .init(.badArgs, refusal.message)))
        case .success(let value): asked = value
        }
        let (queue, nodeRoot, note) = (self.queue, root, self.note)
        // The vault that keeps the user's accept of the presets file, and the home the config seal reads.
        let (vault, home) = (engine?.cardVault, engine?.home ?? self.home)
        let refuse = { (why: String) in queue.async { reply(.init(re: request.id, error: .init(.refused, why))) } }
        // Off the queue: the file is read and written, the vault asked.
        DispatchQueue.global(qos: .userInitiated).async {
            let was: Data?
            switch SessionPresets.bytes(root: nodeRoot) {
            case .failure(let refusal): return refuse(refusal.message + ": nothing changed")
            case .success(let data): was = data
            }
            if let why = PresetEdit.unacceptedRefusal(was, vault: vault, home: home, nodeRoot: nodeRoot) { return refuse(why) }
            let done: PresetEdit.Done
            switch PresetEdit.apply(asked, to: was) {
            case .failure(let refusal): return refuse(refusal.message)
            case .success(let value): done = value
            }
            if let refusal = PresetEdit.write(done.data, root: nodeRoot, was: was) { return refuse(refusal.message) }
            var result = done.result
            result["held"] = .bool(true)
            queue.async {
                note("presets.edit: a preset \(asked.op == "add" ? "added" : asked.op == "edit" ? "changed" : "removed")")
                reply(.init(re: request.id, result: .object(result)))
            }
        }
    }
}
