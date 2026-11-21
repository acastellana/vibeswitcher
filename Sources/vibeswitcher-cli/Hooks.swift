import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher hooks install|remove [--agent claude|codex]` (the start plan's S6, ST-D17): the server's
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
    static let usage = "usage: vibeswitcher hooks install|remove [--agent claude|codex]"

    static func run(_ arguments: [String]) -> Int32 {
        guard let action = arguments.first, ["install", "remove"].contains(action) else { return Say.usage(usage) }
        var agents = Agent.allCases
        switch Array(arguments.dropFirst()) {
        case []: break
        case let words where words.count == 2 && words[0] == "--agent":
            guard let agent = Agent(rawValue: words[1]) else { return Say.usage(usage) }
            agents = [agent]
        default: return Say.usage(usage)
        }
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
        let outcome = TypedWord.ask(approval: client.approvalRule, code: NodeIds.code(action: id), what: what)
        guard outcome == .typed else { return Say.refused(TypedWord.refusal(outcome)) }
        switch client.request(kind, args: ["agents": .array(agents.map { .string($0.rawValue) })], action: id, timeout: 120) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            // Accepted (the voice passed and the server recorded it): its own refusal (`refused`) comes after that.
            if reply.ok || reply.error?.code == NodeWire.Code.refused.rawValue {
                context.writeJournal(NodeJournal.entry(event: "request", action: id, kind: kind, epoch: client.hello.epoch))
            }
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            for program in result["programs"]?.array ?? [] {
                Say.out("installed \(ConfigSeal.inert(program.string ?? "", limit: 400))")
            }
            let configs = (result["configs"]?.array ?? []).map { ConfigSeal.inert($0.string ?? "", limit: 400) }
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
