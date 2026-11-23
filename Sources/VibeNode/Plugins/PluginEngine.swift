import Foundation
import VibeCore

/// The engine's side of the feature plugins: the runtime (`PluginRuntime`) holds their state and logic; the engine keeps
/// the calls the server and the refresh make, and answers what the runtime asks of it (`PluginHost`). On `queue`.
extension LeadEngine: PluginHost {
    /// The desk `plugin` works through.
    func desk(_ plugin: FeaturePlugin) -> PluginDesk { pluginRuntime.desk(plugin) }

    /// Asks the vault which plugins the user set (`PluginRuntime.ask`). On `queue`.
    func askPlugins(then: (() -> Void)? = nil) { pluginRuntime.ask(then: then) }

    /// The vault keeps `kept` (`PluginRuntime.kept`). On `queue`.
    func keptPlugins(_ kept: [String: Bool], written: (() -> Void)? = nil) { pluginRuntime.kept(kept, written: written) }

    /// The user's `plugin on|off NAME` (`PluginRuntime.set`). On `queue`.
    func setPlugin(_ id: String, on: Bool, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) { pluginRuntime.set(id, on: on, then: then) }

    /// Each plugin that is on looks (`PluginRuntime.look`). On `queue`.
    func lookAtPlugins(done: (() -> Void)? = nil) { pluginRuntime.look(done: done) }

    /// The user's answer on a plugin's card (`PluginRuntime.answer`). On `queue`.
    func answerPlugin(_ card: CardStore.Card, text: String, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        pluginRuntime.answer(card, text: text, then: then)
    }

    /// `plugin`'s open cards withdrawn (`PluginRuntime.withdraw`). On `queue`.
    func withdraw(_ plugin: FeaturePlugin, ended: String? = nil) { pluginRuntime.withdraw(plugin, ended: ended) }

    /// `status`'s notices of the plugins (`PluginRuntime.notices`). On `queue`.
    var pluginNotices: [String] { pluginRuntime.notices }

    // MARK: What the runtime asks of the engine (`PluginHost`)

    func pluginTell(_ text: String, from: SteerMessage.Sender, session: UUID, then: @escaping (SessionDelivery) -> Void) {
        tell(text, from: from, session: session, then: then)
    }

    var pluginVault: LeadVault { cardVault }
    var pluginIsScratch: Bool { isScratch }
}

/// The node's one plugin page: the page, the plugin and request it serves, whether it opened. On the engine's queue.
final class PluginPageSlot {
    let page: PluginPage
    let plugin: String
    let key: String
    var opened = false
    var endedEarly = false
    init(page: PluginPage, plugin: String, key: String) {
        self.page = page
        self.plugin = plugin
        self.key = key
    }
}
