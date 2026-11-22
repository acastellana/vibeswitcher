import Foundation
import VibeCore

/// The feature plugins this build has (`standard`, the registry's list: the one place outside `Plugins/<Name>/` that
/// names one), and which are on. On and off are the user's (the definition's rule 5): `vibeswitcher plugin on|off NAME`
/// is a voiced, recorded action, and what it set is kept in the host's vault (`LeadVaultV2.Book.plugins`), which only
/// the app reads or writes, so a session that rewrites a file under the node's root turns nothing on. Until the vault
/// answered (`kept` nil) every plugin is off: nothing is drawn or acted on, and nothing is withdrawn either.
///
/// `<root>/plugins.json` mirrors which are on for the agents' commands (`vs-shell` says "this node doesn't have shell
/// on" from it): it is the server's to write and never read back here, so a forged one only changes what a command
/// prints; the server drops what an off plugin's command files anyway (`LeadEngine.lookAtPlugins`). On the engine's
/// queue.
public final class PluginRegistry {
    /// The plugins this build has, in the order `plugin list` shows them.
    public static func standard() -> [FeaturePlugin] { [ShellPlugin()] }

    public let plugins: [FeaturePlugin]
    /// What the user set, by id, as the vault last said; nil until it answered.
    public internal(set) var kept: [String: Bool]?

    /// `plugins`, each declaration checked (`PluginInfo.refusal`) and each id once: a build with a bad one doesn't start.
    public init(_ plugins: [FeaturePlugin] = PluginRegistry.standard()) {
        for plugin in plugins {
            if let refusal = plugin.info.refusal { preconditionFailure(refusal) }
        }
        precondition(Set(plugins.map(\.info.id)).count == plugins.count, "a plugin id twice")
        self.plugins = plugins
    }

    public func plugin(_ id: String) -> FeaturePlugin? { plugins.first { $0.info.id == id } }

    /// Whether the user's setting is known yet.
    public var known: Bool { kept != nil }

    /// Whether `id` is set on: as the user set it, else as its plugin says by default (false until the vault answered).
    public func isSet(_ id: String) -> Bool {
        guard let kept, let plugin = plugin(id) else { return false }
        return kept[id] ?? plugin.info.defaultOn
    }

    /// Whether `id` is on: set on, and able to run here.
    public func isOn(_ id: String) -> Bool { isSet(id) && plugin(id)?.availability() == nil }

    /// The plugins that are on.
    public var on: [FeaturePlugin] { plugins.filter { isOn($0.info.id) } }

    /// The ids of the plugins that are on (`hello`, `status`, the mirror).
    public var onIDs: [String] { on.map(\.info.id) }

    /// `plugin list`'s entry for `plugin`.
    public func value(_ plugin: FeaturePlugin) -> NodeWire.Value {
        let info = plugin.info
        return .object([
            "id": .string(info.id), "title": .string(info.title), "summary": .string(info.summary),
            "on": .bool(isOn(info.id)), "set": .bool(isSet(info.id)), "defaultOn": .bool(info.defaultOn),
            "known": .bool(known), "unavailable": plugin.availability().map(NodeWire.Value.string) ?? .null,
            "commands": .array(info.commands.map { .object(["name": .string($0.name), "about": .string($0.about)]) }),
            "tools": .array(info.tools.map(NodeWire.Value.string)),
            "settings": .array(info.settings.map { .string($0.key) }),
            "brief": .array(info.brief.map(NodeWire.Value.string)),
        ])
    }

    /// The on plugins as `hello` and `status` list them: id and title.
    public var onValue: NodeWire.Value {
        .array(on.map { .object(["id": .string($0.info.id), "title": .string($0.info.title)]) })
    }

    /// The mirror's bytes: which are on, for the agents' commands (`PluginGate` reads it).
    public var mirror: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(PluginGate.Mirror(on: onIDs, known: known))) ?? Data()
    }
}
