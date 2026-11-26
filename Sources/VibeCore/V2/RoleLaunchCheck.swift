import Foundation

/// What a worker's, verifier's or finder's launch may carry beside its program under the review floor that keeps audits
/// off the workers' model (the review of 368390d7, X1): the flags, the spawn's environment names and the `--settings`
/// content VibeSwitcher's own launch builders emit (`LeadLaunch.prepare`, `prepareCodex`, and the toolset's spawn), and
/// nothing else. Each of the rest can change the model without `--model` (`--fallback-model`, `--agents '{…"model"…}'`, a
/// second `--settings` with `env.ANTHROPIC_BASE_URL` or `model`, `-c model=…`, PATH or ANTHROPIC_MODEL in the spawn's
/// environment), so the node can't vouch for what ran. Judged at the bind (`LeadVault.Book`, `.bind`), from what the
/// host saw (`WorkerLaunch.BindFacts`); without that floor nothing here applies.
public enum RoleLaunchCheck {
    /// The flags Claude Code's launch builder emits for a worker, verifier or finder (`LeadLaunch.prepare`,
    /// `LinuxLaunch.inline`'s inline prompt and settings, `LinuxLaunch.permissionMode`). Not `--resume`: only the lead's
    /// launch carries it, and it takes a value only when the next word doesn't start with `-` (`[value]`), so a role's
    /// `--resume --fallback-model …` hides the next flag from a reading that takes it greedily.
    public static let claudeFlags: Set<String> = [
        "--append-system-prompt-file", "--append-system-prompt", "--mcp-config", "--settings", "--permission-mode", "--name", "--model",
        "--advisor", "--effort",
    ]
    /// A verifier's (and a finder's) own, each required, `--setting-sources` with the value `user` exactly: without them
    /// it loads the branch's `.claude/settings.local.json` and project MCP servers, whose env can route it anywhere. A
    /// worker carries neither.
    public static let verifierFlags: [String: String?] = ["--setting-sources": "user", "--strict-mcp-config": nil]
    /// The flags Codex's launch builder emits (`LeadLaunch.prepareCodex`).
    public static let codexFlags: Set<String> = ["--no-daemon", "--cd", "--sandbox", "--ask-for-approval", "-c", "--model"]
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

    /// The launch's `--settings` file as the bind can check it, where settings aren't inline (the Mac's, S10): the
    /// digest of what the launch builder wrote (`LeadLaunch.Prepared.settingsDigest`, given with the bind) and the
    /// launch's own folder it must lie in (`LeadVault.runPrefix`).
    public struct SettingsFile: Equatable, Sendable {
        public var digest: String?
        public var folder: String
        public init(digest: String?, folder: String) {
            self.digest = digest
            self.folder = folder
        }
    }

    /// Why a `role` session launched with `command` (its spawn environment's names `environment`, nil: the host didn't
    /// say; `settings`: a `--settings` file as the bind read it; `file`: what that file must be; `inline`: whether this
    /// platform's launches put their settings inline, so that a file is never theirs; `full`: whether the host had the
    /// command in full) isn't judged under the floor; nil when it is. One plain sentence, naming what it found and the
    /// way out. The options read as the agent reads them (`WorkerLaunch.options(of:)`).
    public static func refusal(command: String, agent: Agent, role: LeadLaunch.Role, environment: [String]?, settings: SettingsRead?,
                               file: SettingsFile? = nil, inline: Bool = Platform.Tools.roleSettingsInline, full: Bool = true) -> String? {
        guard full else {
            return "This session's full command isn't known to the host (it restarted or took over after the session started), so it can't be judged under your review rules: start it again."
        }
        let options = WorkerLaunch.options(of: command, agent: agent)
        let verifier = agent == .claude && role == .verifier
        let allowed = (agent == .codex ? codexFlags : claudeFlags.union(verifier ? Set(verifierFlags.keys) : [])).union(baseFlags)
        let arity = agent == .codex ? WorkerLaunch.codexArity : WorkerLaunch.claudeArity
        var seen: Set<String> = []
        for option in options {
            let name = option.flag
            guard allowed.contains(name) else { return said("`\(clip(name))`") }
            // Each once, as the builders write them: the program takes the last of a repeated one, and only `--model` is
            // read that way here (`WorkerLaunch.launchModel`); Codex's `-c` is one per key.
            guard seen.insert(name).inserted || name == "-c" || name == "--model" else { return said("`\(name)` more than once") }
            let takes = arity[name] ?? .none
            if takes == .none {
                guard option.value == nil else { return said("`\(clip(name))` given a value") }
                continue
            }
            guard let value = option.value else { return said("`\(name)` without its value") }
            // A value the builders never write: `--` or a word starting with `-` (`--name -- --model x`: the program takes
            // the `--` as the name and reads on).
            guard !value.hasPrefix("-") else { return said("`\(name)` given `\(clip(value))`") }
            if let wanted = verifierFlags[name], verifier, let wanted, value != wanted {
                return said("`\(name) \(clip(value))` (a verifier's launch carries `\(name) \(wanted)`)")
            }
            switch name {
            case "--settings":
                if value.hasPrefix("{") {
                    if let why = settingsRefusal(.text(value), role: role, model: WorkerLaunch.launchModel(command: command)) { return said(why) }
                    continue
                }
                if inline { return said("a `--settings` file (VibeSwitcher's launch here gives its settings inline)") }
                guard let file, value.hasPrefix(file.folder), !value.contains("/../"), (value as NSString).lastPathComponent == "settings.json" else {
                    return said("a `--settings` file outside its launch's own folder")
                }
                guard case .text(let text)? = settings, let digest = file.digest, WalletStamp.digest(Data(text.utf8)) == digest else {
                    return said(settings.map { if case .unread = $0 { return "a `--settings` file the node couldn't read" } else { return "a `--settings` file that isn't the one VibeSwitcher wrote for it" } }
                                ?? "a `--settings` file the node couldn't read")
                }
                if let why = settingsRefusal(.text(text), role: role, model: WorkerLaunch.launchModel(command: command)) { return said(why) }
            case "-c" where agent == .codex:
                let key = String(value.prefix { $0 != "=" })
                guard codexConfigKeys.contains(key) || key.hasPrefix(codexConfigPrefix) else {
                    return said("`-c \(clip(key))` (a Codex setting VibeSwitcher's launch doesn't set)")
                }
            default:
                break
            }
        }
        if verifier, let missing = verifierFlags.keys.sorted().first(where: { !seen.contains($0) }) {
            let wanted = verifierFlags[missing].flatMap { $0.map { " \($0)" } } ?? ""
            return "This verifier's command lacks `\(missing)\(wanted)`, which keeps the branch's settings and MCP servers out, so the node can't vouch for it under your review rules: start it from VibeSwitcher's launch, or lower `floor_verifier_different`."
        }
        if let environment {
            let names = environmentNames(role: role, agent: agent)
            if let stray = environment.sorted().first(where: { !names.contains($0) }) {
                return "This session's spawn environment has `\(clip(stray))`, which the node can't vouch for under your review rules: \(wayOut)."
            }
        }
        return nil
    }

    /// Why a Claude worker's branch settings (its worktree's `.claude/settings.json` and `settings.local.json`, which
    /// a worker loads by design) keep it from being judged under the floor; nil when they don't. Fails closed: a file
    /// there that couldn't be read whole (refused, too big, not one JSON object, a key twice) or reads that didn't
    /// finish refuse it; a missing file is clean. One that names a routing key (`WorkerLaunch.routingKeys`) would run
    /// another model than its record says.
    public static func branchRefusal(_ facts: WorkerLaunch.BindFacts) -> String? {
        guard facts.projectRead else {
            return "This worker's branch settings weren't read in time, so the node can't vouch for it under your review rules: start it again, or lower `floor_verifier_different`."
        }
        if let note = facts.projectUnread.first {
            return "This worker's branch settings couldn't be read whole (\(clip(note, 300))), so the node can't vouch for it under your review rules: fix or remove the file, or lower `floor_verifier_different`."
        }
        if let routing = facts.projectRouting.first {
            return "This worker's branch sets \(routing), which can send it to another model than its --model, so the node can't vouch for it under your review rules: remove it from the branch's settings, or lower `floor_verifier_different`."
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
        if let key = WorkerLaunch.duplicateKey(Data(text.utf8)) { return "a `--settings` that names \"\(clip(key))\" twice in one object" }
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

    static func clip(_ text: String, _ limit: Int = 80) -> String { text.count > limit ? String(text.prefix(limit)) + "…" : text }

    /// The `--settings` path a command names, when it names a file rather than inline JSON: what the bind reads. Read
    /// as the agent reads its options (`WorkerLaunch.options(of:)`).
    public static func settingsPath(in command: String) -> String? {
        WorkerLaunch.options(of: command).first { $0.flag == "--settings" }?.value.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
}
