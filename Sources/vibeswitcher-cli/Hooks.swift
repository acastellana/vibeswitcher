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
        // The Codex the trust is asked of (`NodeCodexTrust`): the one the node's own Codex sessions run, said before the
        // code; the server runs only this one.
        var codex: String?
        // With no link but a `codex` on this command line's PATH: the line that makes the link (shown, never run).
        var linkLine: String?
        if action == "install", agents.contains(.codex) {
            let found = NodePreflight.codex(root: context.root)
            linkLine = found.path == nil ? Self.linkLine(link: NodePreflight.codexLink(root: context.root), home: context.isScratch ? nil : VibePaths.accountHome) : nil
            if let linkLine {
                what += "\n" + linkLine
            } else if let path = found.path {
                codex = path
                what += "\nIt then trusts VibeSwitcher's Codex hooks in Codex by running \(ConfigSeal.inert(path, limit: 300)) app-server "
                    + "(the Codex the node's sessions run), with the node's clean environment; only Codex's trust of those hooks is kept in ~/.codex/config.toml."
            } else {
                what += "\nCodex isn't asked to trust the hooks (\(ConfigSeal.inert(found.why ?? "no codex", limit: 300))): run /hooks in Codex after."
            }
        }
        let ignored = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"].filter { environment[$0] != nil }
        if !ignored.isEmpty { what += "\n\(ignored.joined(separator: " and ")) \(ignored.count == 1 ? "plays" : "play") no part: the node's own home is written." }
        let id = UUID().uuidString.lowercased()
        let said = TypedWord.said(approval: client.approvalRule, action: id, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        let names = agents.map(\.rawValue)
        // Install's result names the programs copied too, and the Codex trust; remove's only the configs.
        let sent: NodeClient.Read<(programs: [String], configs: [String], trusted: Int?, trustNote: String?)> = kind == "hooks.install"
            ? client.change(WireKinds.HooksInstall.self, .init(agents: names, codex: codex), action: id, typed: typed, timeout: 120)
                .map { ($0.programs ?? [], $0.configs ?? [], $0.trusted, $0.trustNote) }
            : client.change(WireKinds.HooksRemove.self, .init(agents: names), action: id, typed: typed, timeout: 120).map { ([], $0.configs ?? [], nil, nil) }
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
                    if let trusted = result.trusted, trusted > 0 {
                        Say.out("  Codex trusts them (\(trusted) hook\(trusted == 1 ? "" : "s")).")
                    }
                    if let linkLine {
                        Say.out("  " + linkLine)
                        continue
                    }
                    if let note = result.trustNote { Say.out("  Not trusted in Codex: \(ConfigSeal.inert(note, limit: 400)).") }
                    if result.trustNote != nil || (result.trusted ?? 0) == 0 {
                        Say.out("  Codex asks to trust new hooks: run /hooks in Codex and trust the vibeswitcher-hook entries.")
                    }
                }
            }
            return 0
        }
    }

    /// When the node's Codex link (`link`) is missing and a `codex` is on this command line's PATH (an absolute folder,
    /// an executable regular file): the line that makes the link, `~` for `home`. Looked up for the text only: the
    /// server runs only what the link names. Nil otherwise (the link there but broken, or no codex found).
    static func linkLine(link: String, home: String?, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        var info = stat()
        guard lstat(link, &info) != 0, errno == ENOENT else { return nil }
        let found = (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }.lazy
            .map { ($0 as NSString).appendingPathComponent("codex") }
            .first { candidate in
                var info = stat()
                return stat(candidate, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(candidate, X_OK) == 0
            }
        guard let found else { return nil }
        func shown(_ path: String) -> String {
            guard let home, path.hasPrefix(home + "/") else { return HookInstaller.shellQuoted(path) }
            return "~/" + HookInstaller.shellQuoted(String(path.dropFirst(home.count + 1)))
        }
        return ConfigSeal.inert("Codex isn't linked for this node: `ln -s \(shown(found)) \(shown(link))`, then run hooks install again "
                                + "(the node holds the new link until you accept it)", limit: 600)
    }
}
