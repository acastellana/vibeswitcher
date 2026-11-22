import Foundation
import VibeCore

/// Shell requests, as a feature plugin: an agent's `vs-shell run [--cwd DIR] -- COMMAND` asks the user for a new shell
/// session in that folder running that command, and nothing runs until the user answers its card in a terminal
/// (`vibeswitcher answer CARD run|decline`). On by default.
///
/// The registry's declaration. Until the move onto the plugin system (the definition's step 2) the requests are still
/// looked at and answered by `Engine/ShellCards.swift`, which keeps to this plugin's on and off.
public final class ShellPlugin: FeaturePlugin {
    public static let id = "shell"

    public let info = PluginInfo(
        id: ShellPlugin.id, title: "Shell requests",
        summary: "An agent asks for a new shell session running a command it names; nothing runs until you answer its card run in your terminal.",
        defaultOn: true,
        commands: [.init(name: "vs-shell", about: "vs-shell run [--cwd DIR] [--label TEXT] -- COMMAND…: asks the user for a shell session running COMMAND")],
        folder: "shell-requests/asked",
        brief: ["When something needs a real terminal, ask for it with `vs-shell run [--cwd DIR] [--label TEXT] -- COMMAND…`: the user runs or declines it from its card."])

    public init() {}

    public func look(_ desk: PluginDesk, done: @escaping () -> Void) { done() }

    public func perform(_ word: String, on card: CardStore.Card, desk: PluginDesk,
                        then: @escaping (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void) {
        then(.failure(.gone("no shell request on card \(card.id)")))
    }

    public func withdrawn(_ card: PluginCard, desk: PluginDesk) {}
}
