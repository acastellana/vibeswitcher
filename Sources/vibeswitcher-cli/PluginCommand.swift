import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher plugin list [--json]` and `vibeswitcher plugin on|off NAME` (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md):
/// the feature plugins, each on or off, why it can't run here and what it adds (a read); turning one on or off is the
/// user's voice: what it does shown, the typed code, then the request, which the server records in the host's vault
/// before it acts. Off, a plugin adds nothing, and its open cards close as withdrawn, their askers told.
enum PluginCommand {
    static let usage = "usage: vibeswitcher plugin list [--json] | plugin on NAME | plugin off NAME | plugin add FOLDER | plugin remove NAME"

    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "list":
            let rest = arguments.dropFirst()
            guard rest.isEmpty || Array(rest) == ["--json"] else { return Say.usage(usage) }
            return list(json: !rest.isEmpty)
        case "on", "off":
            guard arguments.count == 2, !arguments[1].hasPrefix("-") else { return Say.usage(usage) }
            return set(arguments[1], on: arguments[0] == "on")
        case "add":
            guard arguments.count == 2 else { return Say.usage(usage) }
            return add(CardCommand.absolute(arguments[1]))
        case "remove":
            guard arguments.count == 2, !arguments[1].hasPrefix("-") else { return Say.usage(usage) }
            let id = arguments[1].lowercased()
            return SessionCommand.act("plugin.remove", args: { _ in ["plugin": .string(id)] }, what: { _ in
                "This removes the plugin \(ConfigSeal.inert(id, limit: 40)) from this node: its program stops, its open cards close as withdrawn, "
                    + "and the node forgets it (add its folder again to have it back)."
            }) { result in
                let withdrawn = result["withdrawn"]?.int ?? 0
                Say.out("removed \(ConfigSeal.inert(id, limit: 40))" + (withdrawn > 0 ? "; \(withdrawn) open card(s) withdrawn" : ""))
            }
        default:
            return Say.usage(usage)
        }
    }

    /// `plugin add FOLDER`: the folder read by the server (`plugin.inspect`), everything it found shown, then the typed
    /// code, then `plugin.add` bound to the SHA-256 of the manifest and program shown.
    private static func add(_ folder: String) -> Int32 {
        SessionCommand.act("plugin.add", fetch: { client in
            client.request("plugin.inspect", args: ["folder": .string(folder)]).flatMap { reply in
                guard reply.ok, let found = reply.result else {
                    return .failure(.refused(reply.error.map { ConfigSeal.inert($0.message, limit: 600) } ?? "the server read nothing"))
                }
                return .success(found)
            }
        }, args: { found in
            // The folder as the server resolved it, which it requires again (the review of step C, L1).
            ["folder": found["folder"] ?? .null, "manifest": found["manifestSHA"] ?? .null, "program": found["programSHA"] ?? .null]
        }, what: { found in
            let say = { (key: String) in ConfigSeal.inert(found[key]?.string ?? "?", limit: 300) }
            let commands = (found["commands"]?.array ?? []).compactMap(\.string).map { ConfigSeal.inert($0, limit: 40) }
            return "This adds the plugin \(say("id")) (\(say("title")) \(say("version"))): \(say("summary"))\n"
                + "  its program: \(say("program"))\n  its program's SHA-256: \(say("programSHA"))\n  its manifest's SHA-256: \(say("manifestSHA"))\n"
                + (commands.isEmpty ? "" : "  agents get: \(commands.joined(separator: ", "))\n")
                + (found["page"]?.bool == true ? "  it serves a one-request page for your browser, through VibeSwitcher\n" : "")
                + "It starts off: `vibeswitcher plugin on \(say("id"))` runs its program, as you."
        }) { result in
            Say.out("added \(ConfigSeal.inert(result["plugin"]?.string ?? "?", limit: 40)), off: `vibeswitcher plugin on \(ConfigSeal.inert(result["plugin"]?.string ?? "?", limit: 40))` runs it")
        }
    }

    private static func list(json: Bool) -> Int32 {
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        switch client.read(WireKinds.PluginList.self, WireNoArgs()) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, let raw):
            let plugins = result.plugins ?? []
            if json {
                Say.out(String(decoding: NodeWire.printable(NodeWire.line(raw)).dropLast(), as: UTF8.self))
            } else {
                PluginListText.lines(plugins).forEach(Say.out)
            }
            return 0
        }
    }

    private static func set(_ name: String, on: Bool) -> Int32 {
        let id = name.lowercased()
        return SessionCommand.act("plugin.\(on ? "on" : "off")", fetch: { client in
            switch client.read(WireKinds.PluginList.self, WireNoArgs()) {
            case .failure(let failure): return .failure(failure)
            case .refused(let reply): return .failure(.broken(reply.error.map { "\($0.code): \($0.message)" } ?? "the server listed no plugins"))
            case .success(let result, _):
                guard let plugins = result.plugins else { return .failure(.broken("the server listed no plugins")) }
                return .success(plugins.first { $0["id"]?.string == id } ?? .null)
            }
        }, refuse: { plugin in
            guard plugin == .null else { return nil }
            return Say.refused("no plugin \(ConfigSeal.inert(name, limit: 40)) in this build: `vibeswitcher plugin list` lists them")
        }, args: { _ in ["plugin": .string(id)] }, what: { plugin in
            let title = ConfigSeal.inert(plugin["title"]?.string ?? id, limit: 80)
            let commands = (plugin["commands"]?.array ?? []).compactMap { $0["name"]?.string }.map { ConfigSeal.inert($0, limit: 40) }
            let adds = commands.isEmpty ? "" : " (agents get \(commands.joined(separator: ", ")))"
            return on ? "This turns \(title) on for this node\(adds): \(ConfigSeal.inert(plugin["summary"]?.string ?? "", limit: 300))"
                : "This turns \(title) off for this node: its commands file nothing, and its open cards close as withdrawn, their askers told."
        }) { result in
            let state = result["on"]?.bool == true ? "on" : "off"
            let withdrawn = result["withdrawn"]?.int ?? 0
            Say.out("\(ConfigSeal.inert(result["plugin"]?.string ?? id, limit: 40)) is \(state)"
                    + (withdrawn > 0 ? "; \(withdrawn) open card\(withdrawn == 1 ? "" : "s") withdrawn, their askers told" : ""))
        }
    }
}
