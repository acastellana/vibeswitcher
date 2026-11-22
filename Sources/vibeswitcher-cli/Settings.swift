import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher settings [FOLDER] [--find WORDS] [--json]` (the parity table's gap 9): the node's settings and, with a
/// folder, its project's, each with its value, its default, where it lives and whether it is a guard rail; then what the
/// app has that a node leaves out. `--find` keeps the settings whose key, title, description or section holds every
/// word (the app's Settings search). A read: anyone of the uid, no code. Every value from a file is shown inert, line
/// by line.
enum SettingsCommand {
    static let usage = "usage: vibeswitcher settings [FOLDER] [--find WORDS] [--json]"

    static func run(_ arguments: [String]) -> Int32 {
        var folder: String?
        var json = false
        var find: String?
        var words = arguments[...]
        while let word = words.popFirst() {
            switch word {
            case "--json": json = true
            case "--find":
                guard let given = words.popFirst(), !given.trimmingCharacters(in: .whitespaces).isEmpty else { return Say.usage(usage) }
                find = given
            default:
                guard folder == nil, !word.hasPrefix("--") else { return Say.usage(usage) }
                folder = CardCommand.absolute(word)
            }
        }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        switch client.request("settings", args: folder.map { ["folder": .string($0)] } ?? [:]) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            if json {
                Say.out(String(decoding: NodeWire.printable(NodeWire.line(result)).dropLast(), as: UTF8.self))
                return 0
            }
            lines(result, home: ProcessInfo.processInfo.environment["HOME"], find: find).forEach(Say.out)
            return 0
        }
    }

    /// The reply as a person reads it.
    static func lines(_ result: NodeWire.Value, home: String?, find: String? = nil) -> [String] {
        var out: [String] = []
        let words = (find ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        // The app's search: every word in the setting's key, title, description or section.
        let found = { (setting: NodeWire.Value) -> Bool in
            let text = ["key", "title", "about", "section"].compactMap { setting[$0]?.string }.joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let shown = { (path: String) -> String in
            guard let home, !home.isEmpty, path.hasPrefix(home + "/") else { return ConfigSeal.inert(path, limit: 300) }
            return "~" + ConfigSeal.inert(String(path.dropFirst(home.count)), limit: 300)
        }
        func section(_ heading: String, _ all: [NodeWire.Value], folder: String?) {
            let settings = all.filter(found)
            if !words.isEmpty, settings.isEmpty { return }
            out.append(heading)
            var last: String?
            for setting in settings {
                let section = setting["section"]?.string ?? ""
                if section != last {
                    out.append("")
                    out.append("  \(ConfigSeal.inert(section, limit: 80))")
                    last = section
                }
                let key = setting["key"]?.string ?? "?"
                let value = setting["value"]?.string ?? ""
                let isDefault = setting["isDefault"]?.bool == true
                let mark = isDefault ? "  (the default)" : "  (default: \(ConfigSeal.inert(setting["default"]?.string ?? "", limit: 80)))"
                let valueLines = value.split(separator: "\n", omittingEmptySubsequences: false)
                if valueLines.count > 1 {
                    out.append("    \(key):" + (isDefault ? "  (the default)" : ""))
                    valueLines.forEach { out.append("      | " + ConfigSeal.inert(String($0), limit: 400)) }
                } else {
                    out.append("    \(key) = \(ConfigSeal.inert(value, limit: 400))" + (setting["form"]?.string == "text" ? "" : mark))
                }
                // What it does (the page shows its title), and what it takes.
                var about = ConfigSeal.inert(setting["about"]?.string ?? "", limit: 300)
                if about.hasSuffix(".") { about.removeLast() }
                if let limits = setting["limits"]?.string { about += " (\(ConfigSeal.inert(limits, limit: 120)))" }
                out.append("        \(about).")
                // The machine-wide limits' file keeps the Mac's name (mac-limits.json, which the leads' tools read): this node's.
                var place = (setting["home"]?.string == "limits" ? "In this node's limits, " : "In ") + shown(setting["where"]?.string ?? "?")
                if setting["guardRail"]?.bool == true { place += "; a guard rail: a change here is recorded in the vault as yours" }
                out.append("        \(place).")
                if let note = setting["note"]?.string { out.append("        \(ConfigSeal.inert(note, limit: 300)).") }
            }
            out.append("")
            out.append("  Set one: vibeswitcher set \(folder.map { shown($0) + " " } ?? "")KEY VALUE (default puts it back)")
        }
        if let node = result["node"] {
            section("This node's settings (\(shown(node["root"]?.string ?? "?"))), for every project:", node["settings"]?.array ?? [], folder: nil)
        }
        if let project = result["project"], project != .null {
            out.append("")
            let root = project["root"]?.string ?? "?"
            section("Project \(ConfigSeal.inert((root as NSString).lastPathComponent, limit: 80)) (\(shown(root))):",
                    project["settings"]?.array ?? [], folder: root)
        }
        let usage = words.isEmpty ? NodeUsage.lines(result["usage"]) : []
        if !usage.isEmpty {
            out.append("")
            out += usage
        }
        if !words.isEmpty {
            if out.isEmpty { out.append("No setting matches \u{201C}\(ConfigSeal.inert(find ?? "", limit: 80))\u{201D}.") }
            return out
        }
        if let left = result["leftOut"]?.array, !left.isEmpty {
            out.append("")
            out.append("Not on a node (the app's Settings has them):")
            for item in left {
                out.append("  \(ConfigSeal.inert(item["title"]?.string ?? "", limit: 120)): \(ConfigSeal.inert(item["why"]?.string ?? "", limit: 200))")
            }
        }
        return out
    }
}

/// `vibeswitcher set [FOLDER] KEY VALUE` (the parity table's gap 9): changes one setting, the node's (no folder) or the
/// project's holding FOLDER, in the user's voice after the command line's own typed code (EN-D5, as `tell`'s: no card).
/// VALUE `default` puts it back; `-` reads it from standard input (the working policy from a file:
/// `vibeswitcher set policy - < policy.md`). The value is checked here first, then shown inert before the code; the
/// server records the request in the host's vault, writes it where the app does, and tells the leads it concerns. The
/// accepted request is written to the journal (ids only).
enum SetCommand {
    static let usage = "usage: vibeswitcher set [FOLDER] KEY VALUE   (VALUE: default puts it back; - reads standard input)\n"
        + "       `vibeswitcher settings [FOLDER]` lists the keys"

    static func run(_ arguments: [String]) -> Int32 {
        let folder: String?
        let key: String
        var given: String
        switch arguments.count {
        case 2: (folder, key, given) = (nil, arguments[0], arguments[1])
        case 3 where !arguments[0].isEmpty && !arguments[0].hasPrefix("--"): (folder, key, given) = (CardCommand.absolute(arguments[0]), arguments[1], arguments[2])
        default: return Say.usage(usage)
        }
        guard let setting = NodeSettings.setting(key) else {
            return Say.refused("no setting \(ConfigSeal.inert(key, limit: 80)): `vibeswitcher settings [FOLDER]` lists them")
        }
        switch (setting.scope, folder) {
        case (.project, nil): return Say.refused("\(key) is a project's: `vibeswitcher set FOLDER \(key) VALUE`")
        case (.node, _?): return Say.refused("\(key) is this node's, for every project: `vibeswitcher set \(key) VALUE`, no folder")
        default: break
        }
        if given == "-" {
            guard let data = try? FileHandle.standardInput.readToEnd(), let text = String(data: data ?? Data(), encoding: .utf8) else {
                return Say.refused("standard input isn't text")
            }
            given = text
        }
        let value: String?
        switch NodeSettings.parse(setting, given) {
        case .failure(let refusal): return Say.refused(refusal.description)
        case .success(let taken): value = taken
        }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let action = UUID().uuidString.lowercased()
        let shownValue = value.map { $0.contains("\n") ? "this text:\n" + $0.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  | " + ConfigSeal.inert(String($0), limit: 400) }.joined(separator: "\n") : ConfigSeal.inert($0, limit: 400) } ?? "its default"
        let place = folder.map { "the project in \(ConfigSeal.inert($0, limit: 300))" } ?? "this node, for every project"
        let what = "This sets \(key) (\(setting.title)) for \(place) to \(shownValue)"
            + (setting.guardRail ? "\nA guard rail: recorded in the host's vault as yours." : "")
        let said = TypedWord.said(approval: client.approvalRule, action: action, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        var args: [String: NodeWire.Value] = ["key": .string(key), "value": .string(given)]
        if let folder { args["folder"] = .string(folder) }
        switch client.change("set", args: args, action: action, typed: typed, timeout: 120) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            let now = result["value"]?.string ?? "?"
            let was = result["was"]?.string ?? "?"
            let shown = { (text: String) in text.contains("\n") ? "(\(text.split(separator: "\n").count) lines)" : ConfigSeal.inert(text, limit: 200) }
            var said = was == now ? "\(key) was \(shown(now)) already" : "set \(key): \(shown(was)) → \(shown(now))"
            switch result["told"]?.string {
            case "lead": said += "; the project's lead is told at its next step"
            case "leads": said += "; the running leads are told"
            default:
                if setting.home == .limits || setting.home == .preferences { said += "; the leads read it at their next call" }
                else if setting.scope == .project { said += "; no lead runs there: it reads the file when it starts" }
            }
            Say.out(said)
            return 0
        }
    }
}
