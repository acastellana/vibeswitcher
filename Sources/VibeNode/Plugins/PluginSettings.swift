import Foundation
import VibeCore

/// The feature plugins' settings in the settings catalog (the definition's "settings: its entries in the settings
/// catalog (its own section)"): each plugin that is on lists its declared settings (`PluginInfo.Setting`) under its own
/// title, keyed `<plugin>_<name>`; an off plugin's are absent, and `set` refuses them. Their values are kept in the host's
/// vault (`LeadVaultV2.Book.pluginSettings`, as `<plugin>.<name>`), which only the app writes: `set` is the user's voice
/// (`Requests.voiced` recorded it first), the plugin checks the value (`FeaturePlugin.check`), and no session's file write
/// changes one.
extension LeadEngine {
    /// The catalog's entry for a plugin's setting, and its plugin.
    static func catalogSetting(_ plugin: FeaturePlugin, _ setting: PluginInfo.Setting) -> NodeSettings.Setting {
        NodeSettings.Setting(key: "\(plugin.info.id)_\(setting.key)", title: setting.title, about: setting.about, section: plugin.info.title,
                             scope: .node, form: NodeSettings.Form(rawValue: setting.form) ?? .text, home: .plugin,
                             // No plugin says yet which of its settings a page may set: none is (a shell plugin's
                             // allow list among them).
                             page: .terminalOnly("a plugin's setting: no plugin says yet that a page may set it"), choices: setting.choices)
    }

    /// The on plugins' settings as `settings` shows them, from what the vault last said. On `queue`.
    var pluginSettingsShown: [NodeSettings.Shown] {
        plugins.on.flatMap { plugin in
            plugin.info.settings.map { setting in
                let value = pluginRuntime.setting(plugin.info.id, setting.key) ?? setting.defaultValue
                return NodeSettings.Shown(setting: Self.catalogSetting(plugin, setting), value: value, defaultValue: setting.defaultValue,
                                          place: NodeSettings.place(Self.catalogSetting(plugin, setting), files: NodeSettings.Files(root: root), project: nil),
                                          note: nil)
            }
        }
    }

    /// The on plugin whose setting the catalog names `key`, and that setting. On `queue`.
    func pluginSetting(_ key: String) -> (plugin: FeaturePlugin, setting: PluginInfo.Setting)? {
        for plugin in plugins.on {
            if let setting = plugin.info.settings.first(where: { "\(plugin.info.id)_\($0.key)" == key }) { return (plugin, setting) }
        }
        return nil
    }

    /// The user's `set KEY VALUE` on a plugin's setting (the voice passed, the action recorded): the plugin checks it,
    /// the vault keeps it, the engine takes what the vault says. `then` on `queue` with the value as shown and the one
    /// before. On `queue`.
    func setPluginSetting(_ key: String, given: String, then: @escaping (Result<(value: String, was: String), CardFailure>) -> Void) {
        guard let (plugin, setting) = pluginSetting(key) else { return then(.failure(.gone("no setting \(key) of a plugin that is on"))) }
        let reset = NodeSettings.resetWords.contains(given.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        plugin.check(setting: setting.key, value: reset ? nil : given, desk: desk(plugin)) { [weak self] checked in
            self?.queue.async { self?.checkedPluginSetting(checked, key: key, plugin: plugin, setting: setting, then: then) }
        }
    }

    private func checkedPluginSetting(_ checked: Result<String?, PluginRefusal>, key: String, plugin: FeaturePlugin, setting: PluginInfo.Setting,
                                      then: @escaping (Result<(value: String, was: String), CardFailure>) -> Void) {
            switch checked {
            case .failure(let refusal): then(.failure(.badArgs("\(key): \(refusal.description)")))
            case .success(let value): keepPluginSetting(key, plugin: plugin, setting: setting, value: value, then: then)
            }
    }

    private func keepPluginSetting(_ key: String, plugin: FeaturePlugin, setting: PluginInfo.Setting, value checked: String?,
                                   then: @escaping (Result<(value: String, was: String), CardFailure>) -> Void) {
        pluginRuntime.keepSetting(key, plugin: plugin, setting: setting, value: checked, then: then)
    }
}
