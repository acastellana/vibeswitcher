import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher hooks install|remove [--agent claude|codex]...` (the start plan's S6, ST-D17): the server's
/// `hooks.install` or `hooks.remove`, in the user's voice, after the command line's own typed code (EN-D5). With no
/// `--agent` both agents go in one request, under one code.
///
/// The server writes in its own home (`getpwuid`'s on the node, the scratch home on a scratch node) as the app, so the
/// change is sealed as the user's (`LeadVault.appWrite`): install copies `vibeswitcher-hook` and `vibeswitcher-mcp`
/// from the node's build into `~/.vibeswitcher/bin`, only when their bytes are the ones the host's `build-info` names,
/// then adds the hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`; remove takes only VibeSwitcher's hooks
/// out (the user's own handlers stay). Nothing is written here, and `CLAUDE_CONFIG_DIR` and `CODEX_HOME` play no part.
/// The accepted request is written to the journal (ids only).
enum HooksCommand {
    static let usage = "usage: vibeswitcher hooks install|remove [--agent claude|codex]..."

    static func run(_ arguments: [String]) -> Int32 {
        guard let action = arguments.first, ["install", "remove"].contains(action) else { return Say.usage(usage) }
        // `--agent` once or more (each agent once, in the order given: `approve` and `status` print it once per agent);
        // none is both.
        var agents: [Agent] = []
        var words = Array(arguments.dropFirst())[...]
        while let flag = words.popFirst() {
            guard flag == "--agent", let name = words.popFirst(), let agent = Agent(rawValue: name) else { return Say.usage(usage) }
            if !agents.contains(agent) { agents.append(agent) }
        }
        if agents.isEmpty { agents = Agent.allCases }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let kind = "hooks." + action
        let named = agents.map(\.displayName).joined(separator: " and ")
        var what = action == "install"
            ? "This installs VibeSwitcher's hooks for \(named) in the node's home, copying vibeswitcher-hook and vibeswitcher-mcp "
                + "from the node's build into ~/.vibeswitcher/bin, written as VibeSwitcher's own (sealed)."
            : "This removes VibeSwitcher's hooks for \(named) from the node's home (your own hooks stay), written as VibeSwitcher's own (sealed)."
        let environment = ProcessInfo.processInfo.environment
        let ignored = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"].filter { environment[$0] != nil }
        if !ignored.isEmpty { what += "\n\(ignored.joined(separator: " and ")) \(ignored.count == 1 ? "plays" : "play") no part: the node's own home is written." }
        let id = UUID().uuidString.lowercased()
        let said = TypedWord.said(approval: client.approvalRule, action: id, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        let args = WireKinds.AgentsArgs(agents: agents.map(\.rawValue))
        // Install's result names the programs copied too; remove's only the configs.
        let sent: NodeClient.Read<(programs: [String], configs: [String])> = kind == "hooks.install"
            ? client.change(WireKinds.HooksInstall.self, args, action: id, typed: typed, timeout: 120).map { ($0.programs ?? [], $0.configs ?? []) }
            : client.change(WireKinds.HooksRemove.self, args, action: id, typed: typed, timeout: 120).map { ([], $0.configs ?? []) }
        switch sent {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _):
            for program in result.programs {
                Say.out("installed \(ConfigSeal.inert(program, limit: 400))")
            }
            let configs = result.configs.map { ConfigSeal.inert($0, limit: 400) }
            for (agent, config) in zip(agents, configs) {
                Say.out(kind == "hooks.install" ? "\(agent.displayName): hooks installed in \(config)" : "\(agent.displayName): hooks removed from \(config)")
                if kind == "hooks.install", agent == .codex {
                    Say.out("  Codex asks to trust new hooks: run /hooks in Codex and trust the vibeswitcher-hook entries.")
                }
            }
            return 0
        }
    }
}
