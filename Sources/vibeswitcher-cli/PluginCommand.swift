import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher plugin list [--json]` and `vibeswitcher plugin on|off NAME` (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md):
/// the feature plugins, each on or off, why it can't run here and what it adds (a read); turning one on or off is the
/// user's voice: what it does shown, the typed code, then the request, which the server records in the host's vault
/// before it acts. Off, a plugin adds nothing, and its open cards close as withdrawn, their askers told.
enum PluginCommand {
    static let usage = "usage: vibeswitcher plugin list [--json] | plugin on NAME | plugin off NAME"

    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "list":
            let rest = arguments.dropFirst()
            guard rest.isEmpty || Array(rest) == ["--json"] else { return Say.usage(usage) }
            return list(json: !rest.isEmpty)
        case "on", "off":
            guard arguments.count == 2, !arguments[1].hasPrefix("-") else { return Say.usage(usage) }
            return set(arguments[1], on: arguments[0] == "on")
        default:
            return Say.usage(usage)
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
        on ? set(name, on: true, as: WireKinds.PluginOn.self) : set(name, on: false, as: WireKinds.PluginOff.self)
    }

    private static func set<K: WireChangeKind>(_ name: String, on: Bool, as kind: K.Type) -> Int32
    where K.Args == WireKinds.PluginArgs, K.Result == WireKinds.PluginSetResult {
        let id = name.lowercased()
        return SessionCommand.act(K.self, fetch: { client in
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
        }, args: { _ in .init(plugin: id) }, what: { plugin in
            let title = ConfigSeal.inert(plugin["title"]?.string ?? id, limit: 80)
            let commands = (plugin["commands"]?.array ?? []).compactMap { $0["name"]?.string }.map { ConfigSeal.inert($0, limit: 40) }
            let adds = commands.isEmpty ? "" : " (agents get \(commands.joined(separator: ", ")))"
            return on ? "This turns \(title) on for this node\(adds): \(ConfigSeal.inert(plugin["summary"]?.string ?? "", limit: 300))"
                : "This turns \(title) off for this node: its commands file nothing, and its open cards close as withdrawn, their askers told."
        }) { result in
            let state = result.on == true ? "on" : "off"
            let withdrawn = result.withdrawn ?? 0
            Say.out("\(ConfigSeal.inert(result.plugin ?? id, limit: 40)) is \(state)"
                    + (withdrawn > 0 ? "; \(withdrawn) open card\(withdrawn == 1 ? "" : "s") withdrawn, their askers told" : ""))
        }
    }
}
