import Foundation

/// What a worker's, verifier's or finder's launch may carry beside its program under the review floor that keeps audits
/// off the workers' model (the review of 368390d7, X1): the flags, the spawn's environment names and the `--settings`
/// content VibeSwitcher's own launch builders emit (`LeadLaunch.prepare`, `prepareCodex`, and the toolset's spawn), and
/// nothing else. Each of the rest can change the model without `--model` (`--fallback-model`, `--agents '{…"model"…}'`, a
/// second `--settings` with `env.ANTHROPIC_BASE_URL` or `model`, `-c model=…`, PATH or ANTHROPIC_MODEL in the spawn's
/// environment), so the node can't vouch for what ran. Judged at the bind (`LeadVault.Book`, `.bind`), from what the
/// host saw (`WorkerLaunch.BindFacts`); without that floor nothing here applies.
public enum RoleLaunchCheck {
    /// The flags Claude Code's launch builder emits (`LeadLaunch.prepare`, `LinuxLaunch.inline`'s inline prompt and
    /// settings, `LinuxLaunch.permissionMode`).
    public static let claudeFlags: Set<String> = [
        "--append-system-prompt-file", "--append-system-prompt", "--mcp-config", "--settings", "--setting-sources", "--strict-mcp-config",
        "--permission-mode", "--name", "--model", "--advisor", "--effort", "--resume",
    ]
    /// The flags Codex's launch builder emits (`LeadLaunch.prepareCodex`).
    public static let codexFlags: Set<String> = ["--no-daemon", "--cd", "--sandbox", "--ask-for-approval", "-c", "--model"]
    /// The flags above that take no value; every other one takes the word after it (or its `=` part).
    static let switches: Set<String> = ["--strict-mcp-config", "--no-daemon", "--dangerously-skip-permissions"]
    /// The base command's own flags allowed beside them (a launch preset's): `--dangerously-skip-permissions`, a
    /// permission mode that doesn't change the model. The presets' defaults hold none (`LaunchPresets.builtIns`).
    public static let baseFlags: Set<String> = ["--dangerously-skip-permissions"]
    /// The `-c` keys `prepareCodex` writes, and the prefix of its tool server's.
    public static let codexConfigKeys: Set<String> = [
        "sandbox_workspace_write.writable_roots", "sandbox_workspace_write.network_access", "projects", "check_for_update_on_startup",
        "developer_instructions", "model_reasoning_effort",
    ]
    static let codexConfigPrefix = "mcp_servers.vibeswitcher."
    /// The top-level keys of the `--settings` `LeadLaunch.prepare` writes.
    public static let settingsKeys: Set<String> = ["permissions", "env", "autoMemoryEnabled", "enabledPlugins", "hooks", "statusLine"]

    /// The names the launch puts in a `role` session's spawn environment (`Prepared.environment` and the toolset's
    /// heavy-slot limits).
    public static func environmentNames(role: LeadLaunch.Role, agent: Agent) -> Set<String> {
        var names: Set<String> = [SessionNote.roleVariable, "TMPDIR", TestLock.slotsVariable, TestLock.timeoutVariable, TestLock.stallVariable]
        if agent == .codex { return names.union(LeadLaunch.environment(role).keys) }
        names.insert(LeadLaunch.autoUpdaterVariable)
        if role == .lead { names.insert(LeadLaunch.leadModelVariable) }
        if role == .verifier { names.formUnion(LeadLaunch.verifierEnvironment(server: "/s").keys + [BranchRun.policyVariable]) }
        return names
    }

    /// The names a `role` session's `--settings` `env` may hold: the role's environment, a verifier's additions and the
    /// models' pins.
    public static func settingsEnvironmentNames(role: LeadLaunch.Role) -> Set<String> {
        var names = Set(LeadLaunch.environment(role).keys).union(WorkerLaunch.pins(model: "opus").keys)
        if role == .verifier { names.formUnion(LeadLaunch.verifierEnvironment(server: "/s").keys + [BranchRun.policyVariable]) }
        return names
    }

    /// Where the way out of a refusal is said.
    static let wayOut = "remove it from the launch preset, or lower `floor_verifier_different`"

    /// Why a `role` session launched with `command` (its spawn environment's names `environment`, nil: the host didn't
    /// say; `settings`: the text of a `--settings` file the bind read, nil when none was read) isn't judged under the
    /// floor; nil when it is. One plain sentence, naming what it found and the way out.
    public static func refusal(command: String, agent: Agent, role: LeadLaunch.Role, environment: [String]?, settings: SettingsRead?) -> String? {
        let words = WorkerLaunch.tokens(command).map(\.text).prefix { $0 != "--" }
        // The program and `env` (with its options) before it, as `WorkerLaunch.program(of:)` reads them.
        var rest = words[...]
        if let first = rest.first, first == "env" || first == "/usr/bin/env" || first == "/bin/env" {
            rest = rest.dropFirst()
            while let option = rest.first, option.hasPrefix("-") {
                rest = rest.dropFirst()
                if option == "-u" || option == "--unset" { rest = rest.dropFirst() }
            }
        }
        rest = rest.dropFirst()
        let allowed = (agent == .codex ? codexFlags : claudeFlags).union(baseFlags)
        var seen: Set<String> = []
        var index = rest.startIndex
        while index < rest.endIndex {
            let word = rest[index]
            index = rest.index(after: index)
            guard word.hasPrefix("-") else { continue }
            let name = String(word.prefix { $0 != "=" })
            let inlineValue = word.contains("=") ? String(word.drop { $0 != "=" }.dropFirst()) : nil
            guard allowed.contains(name) else { return said("`\(clip(name))`") }
            // Each once, as the builders write them: the program takes the last of a repeated one, and only `--model` is
            // read that way here (`WorkerLaunch.launchModel`); Codex's `-c` is one per key.
            guard seen.insert(name).inserted || name == "-c" || name == "--model" else { return said("`\(name)` more than once") }
            // The word a flag takes is its value, never a flag, even when it starts with `-` (a prompt, a name).
            var value: String?
            if switches.contains(name) {
                guard inlineValue == nil else { return said("`\(clip(word))`") }
            } else if let inlineValue {
                value = inlineValue
            } else if index < rest.endIndex {
                value = rest[index]
                index = rest.index(after: index)
            }
            switch name {
            case "--settings":
                let given = value ?? ""
                if let why = settingsRefusal(given.hasPrefix("{") ? .text(given) : (settings ?? .unread(given)), role: role,
                                             model: WorkerLaunch.launchModel(command: command)) { return said(why) }
            case "-c" where agent == .codex:
                let key = String((value ?? "").prefix { $0 != "=" })
                guard codexConfigKeys.contains(key) || key.hasPrefix(codexConfigPrefix) else {
                    return said("`-c \(clip(key))` (a Codex setting VibeSwitcher's launch doesn't set)")
                }
            default:
                break
            }
        }
        if let environment {
            let names = environmentNames(role: role, agent: agent)
            if let stray = environment.sorted().first(where: { !names.contains($0) }) {
                return "This session's spawn environment has `\(clip(stray))`, which the node can't vouch for under your review rules: \(wayOut)."
            }
        }
        return nil
    }

    /// A `--settings` as the bind found it: its text (inline, or the file read), or a file it couldn't read.
    public enum SettingsRead: Equatable, Sendable {
        case text(String)
        case unread(String)
    }

    /// Why a `--settings` isn't VibeSwitcher's own (nil: it is): a JSON object of `settingsKeys` only, whose `env` names
    /// are within the role's (`settingsEnvironmentNames`); unread or not that, refused.
    /// The models' pins (`WorkerLaunch.pins`) only as VibeSwitcher sets them: each alias to its id, ANTHROPIC_MODEL to
    /// the launch's own `--model` (`model`).
    static func settingsRefusal(_ read: SettingsRead, role: LeadLaunch.Role, model: String?) -> String? {
        guard case .text(let text) = read else { return "a `--settings` file the node couldn't read" }
        guard WorkerLaunch.nests(Data(text.utf8), within: WorkerLaunch.depthLimit),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return "a `--settings` that isn't a JSON object the node can read"
        }
        if let key = object.keys.sorted().first(where: { !settingsKeys.contains($0) }) {
            return "`\(clip(key))` in its `--settings`"
        }
        let names = settingsEnvironmentNames(role: role)
        if let env = object["env"] as? [String: Any] {
            if let key = env.keys.sorted().first(where: { !names.contains($0) }) { return "`\(clip(key))` in its `--settings` env" }
            let pins = WorkerLaunch.pins(model: model)
            if let key = env.keys.sorted().first(where: { key in
                WorkerLaunch.pins(model: "opus")[key] != nil && (env[key] as? String) != pins[key]
            }) {
                return "`\(clip(key))` in its `--settings` env set otherwise than VibeSwitcher pins it"
            }
        }
        return nil
    }

    static func said(_ what: String) -> String {
        "This session's command has \(what), which the node can't vouch for under your review rules: \(wayOut)."
    }

    static func clip(_ text: String) -> String { text.count > 80 ? String(text.prefix(80)) + "…" : text }

    /// The `--settings` path a command names, when it names a file rather than inline JSON: what the bind reads.
    public static func settingsPath(in command: String) -> String? {
        let words = Array(WorkerLaunch.tokens(command).map(\.text).prefix { $0 != "--" })
        for (index, word) in words.enumerated() {
            if word == "--settings", index + 1 < words.count, words[index + 1].hasPrefix("/") { return words[index + 1] }
            if word.hasPrefix("--settings=/") { return String(word.dropFirst("--settings=".count)) }
        }
        return nil
    }
}
