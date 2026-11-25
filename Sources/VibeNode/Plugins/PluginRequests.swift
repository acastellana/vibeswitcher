import Foundation
import VibeCore

/// The server's requests on the feature plugins (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md, "Commands"):
/// `plugin.list` (a read: each plugin, on or off, why it can't run here, what it adds) and `plugin.on`/`plugin.off` with
/// `plugin` (the user's voice, recorded in the vault before it acts, as every state-changing request is; never part of
/// `approve`'s batch). On the engine's queue, as `Requests.handle` calls them.
extension Requests {
    /// `page`: a web page asks: only the plugins that are on (off leaves no trace); the whole list is the user's.
    func pluginList(_ request: NodeWire.Request, page: Bool, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no plugins"))) }
        let answer = {
            let listed = page ? engine.plugins.on : engine.plugins.plugins
            let values = listed.map { plugin -> NodeWire.Value in
                guard case .object(var fields) = engine.plugins.value(plugin) else { return .null }
                // Nothing set in the vault's record, which began at its host's start (a restart starts it over): since when
                // it is at its default, from the vault's own word, never a file of the node's.
                fields["defaultSince"] = engine.plugins.kept?[plugin.info.id] == nil ? engine.pluginRuntime.recordSince.map(NodeWire.Value.date) ?? .null : .null
                return .object(fields)
            }
            reply(.init(re: request.id, typed: WireKinds.PluginList.Result(plugins: values)))
        }
        // Until the vault said, ask it first: the list says what the user set.
        engine.plugins.known ? answer() : engine.askPlugins(then: answer)
    }

    func pluginSet(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no plugins"))) }
        guard let id = request.args?["plugin"]?.string, !id.isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs plugin (`vibeswitcher plugin list` lists them)")))
        }
        engine.setPlugin(id, on: request.kind == "plugin.on") { result in
            switch result {
            case .success(let value):
                // As `WireKinds.PluginSetResult` (the registry's value, read into it).
                reply(.init(re: request.id, typed: WireKinds.PluginSetResult(plugin: value["plugin"]?.string ?? id, on: value["on"]?.bool ?? false,
                                                                              withdrawn: value["withdrawn"]?.int ?? 0)))
            case .failure(.gone(let why)): reply(.init(re: request.id, error: .init(.gone, why)))
            case .failure(.refused(let why)), .failure(.delivered(let why)): reply(.init(re: request.id, error: .init(.refused, why)))
            case .failure(.badArgs(let why)): reply(.init(re: request.id, error: .init(.badArgs, why)))
            }
        }
    }
}
