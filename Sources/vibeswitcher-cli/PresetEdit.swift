import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher preset add|edit|remove NAME ...` (the page-actions lane, 2026-11-20; the app's Settings › Presets): a
/// launch preset of the node's added, changed or removed (`presets.edit`, the user's voice: shown, the typed code, then
/// the request). `--folder FOLDER` makes it that folder's (its project's) preset, else every folder's. The node keeps
/// its rules for what a preset may be (Claude as `claude` and plain words, only the reviewed variables, no built-in's
/// name); the variables are checked here first, before any code is asked. The file changes, so the config seal holds
/// it until you accept it (`config held FOLDER`, then `config accept CARD`): no preset of it starts before that.
enum PresetEditCommand {
    static let usage = """
        usage: vibeswitcher preset add NAME [--folder FOLDER] [--shell | --args WORDS] [--env NAME=VALUE]... [--keep-shell] [--default]
               vibeswitcher preset edit NAME [--folder FOLDER] [--rename NEW] [--claude | --shell] [--args WORDS] [--env NAME=VALUE]...
                                             [--unset NAME]... [--keep-shell | --no-keep-shell] [--default]
               vibeswitcher preset remove NAME [--folder FOLDER]
        """

    /// The command line read: the request's args, and what the confirmation says it changes.
    struct Parsed {
        var op: String
        var name: String
        var folder: String?
        var args: [String: NodeWire.Value]
        var changes: [String]
    }

    /// Why the command line can't be read: its usage (exit 64), or a refusal (77).
    struct Failure: Error { let message: String }

    static func parse(_ arguments: [String], cwd: String = FileManager.default.currentDirectoryPath) -> Result<Parsed, Failure> {
        guard arguments.count >= 2, ["add", "edit", "remove"].contains(arguments[0]), !arguments[1].isEmpty, !arguments[1].hasPrefix("-") else {
            return .failure(Failure(message: usage))
        }
        let op = arguments[0], name = arguments[1]
        var args: [String: NodeWire.Value] = ["op": .string(op), "name": .string(name)]
        var folder: String?
        var env: [String: NodeWire.Value] = [:]
        var unset: [NodeWire.Value] = []
        var changes: [String] = []
        var kind: String?
        var words = arguments.dropFirst(2)
        let allowed: Set<String> = switch op {
        case "add": ["--folder", "--shell", "--args", "--env", "--keep-shell", "--default"]
        case "edit": ["--folder", "--rename", "--claude", "--shell", "--args", "--env", "--unset", "--keep-shell", "--no-keep-shell", "--default"]
        default: ["--folder"]
        }
        while let word = words.popFirst() {
            guard allowed.contains(word) else { return .failure(Failure(message: usage)) }
            let takesValue: Set<String> = ["--folder", "--rename", "--args", "--env", "--unset"]
            var value = ""
            if takesValue.contains(word) {
                guard let next = words.popFirst() else { return .failure(Failure(message: usage)) }
                value = next
            }
            switch word {
            case "--folder":
                guard folder == nil, !value.isEmpty else { return .failure(Failure(message: usage)) }
                folder = CardCommand.absolute(value, cwd: cwd)
            case "--rename":
                guard args["rename"] == nil, !value.isEmpty, !value.hasPrefix("-") else { return .failure(Failure(message: usage)) }
                args["rename"] = .string(value)
                changes.append("renamed \u{201C}\(ConfigSeal.inert(value, limit: 80))\u{201D}")
            case "--claude", "--shell":
                guard kind == nil else { return .failure(Failure(message: usage)) }
                kind = word == "--shell" ? "shell" : "claude"
                args["kind"] = .string(kind!)
                changes.append(kind == "shell" ? "a shell" : "Claude")
            case "--args":
                guard args["args"] == nil else { return .failure(Failure(message: usage)) }
                args["args"] = .string(value)
                changes.append(value.isEmpty ? "plain `claude`" : "runs `claude \(ConfigSeal.inert(value, limit: 200))`")
            case "--env":
                guard let equals = value.firstIndex(of: "=") else { return .failure(Failure(message: usage + "\n(--env takes NAME=VALUE)")) }
                let variable = String(value[..<equals]), setting = String(value[value.index(after: equals)...])
                guard env[variable] == nil, !variable.isEmpty else { return .failure(Failure(message: usage)) }
                if let why = SessionPresets.envRefusal(variable) { return .failure(Failure(message: "\(ConfigSeal.inert(variable, limit: 64)): \(why)")) }
                env[variable] = .string(setting)
                let shown = SessionPresets.looksSecret(name: variable, value: setting) ? "<set>" : ConfigSeal.inert(setting, limit: 120)
                changes.append("sets \(variable)=\(shown)")
            case "--unset":
                guard !value.isEmpty, !unset.contains(.string(value)) else { return .failure(Failure(message: usage)) }
                unset.append(.string(value))
                changes.append("no longer sets \(ConfigSeal.inert(value, limit: 64))")
            case "--keep-shell", "--no-keep-shell":
                guard args["keepShell"] == nil else { return .failure(Failure(message: usage)) }
                args["keepShell"] = .bool(word == "--keep-shell")
                changes.append(word == "--keep-shell" ? "a shell stays when it ends" : "no shell stays when it ends")
            case "--default":
                guard args["default"] == nil else { return .failure(Failure(message: usage)) }
                args["default"] = .bool(true)
                changes.append("the folder's default")
            default: return .failure(Failure(message: usage))
            }
        }
        if args["default"] != nil, folder == nil { return .failure(Failure(message: usage + "\n(--default is a folder's: give --folder)")) }
        if op == "add", kind == "shell", args["args"] != nil { return .failure(Failure(message: usage + "\n(a shell takes no --args)")) }
        if !env.isEmpty { args["env"] = .object(env) }
        if !unset.isEmpty { args["unset"] = .array(unset) }
        if let folder { args["folder"] = .string(folder) }
        if op == "edit", changes.isEmpty { return .failure(Failure(message: usage + "\n(an edit says what it changes)")) }
        return .success(Parsed(op: op, name: name, folder: folder, args: args, changes: changes))
    }

    static func run(_ arguments: [String]) -> Int32 {
        let parsed: Parsed
        switch parse(arguments) {
        case .failure(let why): return why.message.hasPrefix("usage:") ? Say.usage(why.message) : Say.refused(why.message)
        case .success(let value): parsed = value
        }
        let place = parsed.folder.map { "for \(ConfigSeal.inert($0, limit: 200))" } ?? "for every folder"
        let shownName = ConfigSeal.inert(parsed.name, limit: 80)
        let held = "\nThe presets file then waits for your accept (`vibeswitcher config held`, then `config accept CARD`): none of its presets starts before that."
        guard parsed.op != "add" else {
            let what = "This adds preset \(shownName) \(place)" + (parsed.changes.isEmpty ? " (Claude, plain `claude`)" : ": " + parsed.changes.joined(separator: "; ")) + "." + held
            return SessionCommand.act("presets.edit", args: { _ in parsed.args }, what: { _ in what }, say: said)
        }
        // An edit or a remove: the preset as the node lists it now, shown, and bound to what was shown by its digest.
        return SessionCommand.act("presets.edit", fetch: { client in
            var listArgs: [String: NodeWire.Value] = ["values": .bool(true)]
            if let folder = parsed.folder { listArgs["folder"] = .string(folder) }
            switch client.request("session.presets", args: listArgs) {
            case .failure(let failure): return .failure(failure)
            case .success(let reply):
                guard reply.ok, let list = reply.result?["presets"]?.array else {
                    return .failure(.broken(reply.error.map { "\($0.code): \($0.message)" } ?? "the server listed no presets"))
                }
                // Only those of the place named: a folder's own, or every folder's.
                let mine = list.filter { $0["builtIn"]?.bool != true && ($0["project"]?.bool == true) == (parsed.folder != nil) }
                guard let found = PresetsCommand.named(parsed.name, in: mine) else {
                    let builtIn = list.contains { $0["builtIn"]?.bool == true && $0["name"]?.string?.caseInsensitiveCompare(parsed.name) == .orderedSame }
                    return .failure(.refused(builtIn ? "\(shownName) is a built-in preset, which comes from VibeSwitcher itself and isn't edited here"
                                                     : "no preset \(shownName) of yours \(place) (`vibeswitcher presets\(parsed.folder.map { " " + ConfigSeal.inert($0, limit: 200) } ?? "")` lists them"
                                                       + (parsed.folder == nil ? "; a folder's own takes --folder" : "") + ")"))
                }
                return .success(found)
            }
        }, args: { preset in
            var args = parsed.args
            args["name"] = preset["name"] ?? .string(parsed.name)
            args["digest"] = preset["digest"] ?? .null
            return args
        }, what: { preset in
            parsed.op == "remove" ? "This removes preset " + PresetsCommand.describe(preset) + " \(place)." + held
                : "This changes preset " + PresetsCommand.describe(preset) + " \(place): " + parsed.changes.joined(separator: "; ") + "." + held
        }, say: said)
    }

    static func said(_ result: NodeWire.Value) {
        let name = ConfigSeal.inert(result["name"]?.string ?? "?", limit: 80)
        let folder = result["folder"]?.string.map { ConfigSeal.inert($0, limit: 200) }
        let done = ["add": "added", "edit": "changed", "remove": "removed"][result["op"]?.string ?? ""] ?? "changed"
        Say.out("\(done): preset \(name) \(folder.map { "for \($0)" } ?? "for every folder")")
        Say.out("held: the presets file waits for your accept: `vibeswitcher config held\(folder.map { " " + $0 } ?? "")`, then `vibeswitcher config accept CARD`")
    }
}
