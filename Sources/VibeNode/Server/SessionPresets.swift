import Foundation
import VibeCore

/// The app's launch presets on the node (the parity table's row, 2026-11-20): what `vibeswitcher new FOLDER --preset
/// NAME` and the page's New session form offer. They are read where the app keeps them, the node's `presets.json`
/// (`VibePaths.presetsFile` under the node's root: `LaunchPresets`, shared with the app), with the app's built-in
/// Claude, Codex and Shell when there is none; a folder's own presets and its default come first, as the app's New
/// Session lists them. Never written here, nor a `.corrupt` copy made: the node only reads them.
///
/// What a preset runs on the node keeps EN-D13: Claude is the program the node's `claude` link names, never a word a
/// shell looks up, so a Claude preset's command must be `claude` and then plain words (its arguments), each passed
/// quoted; Codex isn't on the node yet; a shell is the host's own. Its environment may not name what the host refuses
/// a spawn (`Platform.Tools.spawnEnvironmentRefused`) nor VibeSwitcher's own `VIBESWITCHER_*`. What the user is shown
/// is bound to what starts by the preset's `digest`, an HMAC under a key only this server run holds: a preset changed in
/// between is refused, nothing started. A variable's value never leaves the node: the wire, the command line's listing
/// and the log name variables only.
public enum SessionPresets {
    /// A preset as the node lists it.
    public struct Listed: Equatable, Sendable {
        public var preset: LaunchPreset
        /// One of the folder's own presets (else a global one).
        public var project: Bool
        /// The folder's default (the first listed).
        public var isDefault: Bool
        /// Why the node can't start it, or nil.
        public var refusal: String?
    }

    /// The presets the node's `root` keeps, and a line for each thing in the file that couldn't be read (the file as a
    /// whole too: the built-ins then).
    public static func load(root: URL) -> (presets: LaunchPresets, problems: [String]) {
        let url = root.appendingPathComponent(VibePaths.presetsFile.lastPathComponent)
        let builtIns = LaunchPresets.builtIns()
        guard let data = try? Data(contentsOf: url) else { return (builtIns, []) }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return (builtIns, []) }
        // The lenient decode skips what it can't read (`LaunchPresets.init(from:)`).
        guard var presets = try? JSONDecoder().decode(LaunchPresets.self, from: data) else {
            return (builtIns, ["\(url.lastPathComponent) isn't readable JSON, so the built-in presets are used"])
        }
        if presets.global.isEmpty { presets.global = builtIns.global }
        return (presets, [])
    }

    /// The presets for `folder` (absolute), as the app's New Session lists them: the default of the nearest project
    /// folder that has presets (the folder itself or one it is in) first, then that project's own, then the global ones.
    public static func list(_ presets: LaunchPresets, folder: String?) -> [Listed] {
        let project = folder.flatMap { projectRoot(of: $0, in: presets) }
        let own = Set((project.flatMap { presets.byProject[$0] } ?? []).map(\.id))
        let listed = presets.presets(for: project)
        return listed.enumerated().map { index, preset in
            Listed(preset: preset, project: own.contains(preset.id), isDefault: index == 0 && project.flatMap { presets.defaults[$0] } == preset.id,
                   refusal: refusal(preset))
        }
    }

    /// The nearest folder at or above `folder` that `presets` keeps presets or a default for.
    static func projectRoot(of folder: String, in presets: LaunchPresets) -> String? {
        let standard = (folder as NSString).standardizingPath
        let tidy = { (key: String) in (key as NSString).standardizingPath }
        return Set(presets.byProject.keys).union(presets.defaults.keys).filter { key in
            let root = tidy(key)
            return standard == root || standard.hasPrefix(root == "/" ? "/" : root + "/")
        }.max { tidy($0).count < tidy($1).count }
    }

    /// The preset `name` names among `listed`: the same name, else the same ignoring case; of those, the first the node
    /// can start (a project's preset that shadows a built-in's name never stands in for the built-in), else the first.
    public static func named(_ name: String, in listed: [Listed]) -> Listed? {
        let same = listed.filter { $0.preset.name == name }
        let found = same.isEmpty ? listed.filter { $0.preset.name.caseInsensitiveCompare(name) == .orderedSame } : same
        return found.first { $0.refusal == nil } ?? found.first
    }

    /// The built-in presets' ids and names (`LaunchPresets.builtIns`): another preset may not go by one of the names.
    static let builtIns = LaunchPresets.builtIns().global
    static let builtInNames = Set(builtIns.map { $0.name.lowercased() })

    /// The config seal's name for the presets file (`LinuxSealList.homeEntries`): while the vault holds a change to it,
    /// no preset starts (`Requests.presetsHeld`).
    public static var sealName: String { "~/.vibeswitcher/presets.json" }

    /// Why the node can't start `preset` (nil: it can): Codex, a name that is a role's, a Claude command that isn't
    /// `claude` and plain words, an environment variable the host refuses.
    public static func refusal(_ preset: LaunchPreset) -> String? {
        if preset.kind == .codex { return "Codex doesn't run on this node yet" }
        if LeadTeams.role(label: preset.name) != nil {
            return "its name is a lead's or a team member's label, which only a lead's start gives"
        }
        if builtInNames.contains(preset.name.lowercased()), !builtIns.contains(where: { $0.id == preset.id }) {
            return "its name is a built-in preset's (\(ConfigSeal.inert(preset.name, limit: 40))), which it would stand in for: rename it"
        }
        if preset.kind == .claude, case .failure(let why) = arguments(preset) { return why.message }
        let names = preset.env.keys.sorted()
        if let bad = names.first(where: { !LaunchPlan.validEnvName($0) }) {
            return "its environment names \(ConfigSeal.inert(bad, limit: 64)), which isn't a variable's name"
        }
        let refused = names.compactMap { name in envRefusal(name).map { "\(name) (\($0))" } }
        if !refused.isEmpty { return "its environment sets \(refused.joined(separator: ", ")), which a preset may not set" }
        if preset.env.values.contains(where: { $0.contains("\u{0}") }) { return "an environment value holds a NUL" }
        return nil
    }

    struct Refusal: Error { let message: String }

    /// Why a preset may not set the variable `name` (nil: it may), in a few words (the security review of 2026-11-20:
    /// `presets.json` is a file any process of the uid can write, so a variable that changes what a session runs, where
    /// it reads its config, whom it talks to or what its shell does first could be planted in a preset the user later
    /// starts). Besides what the host refuses any spawn (`Platform.Tools.spawnEnvironmentRefused`).
    public static func envRefusal(_ name: String) -> String? {
        let upper = name.uppercased()
        if !Platform.Tools.spawnEnvironmentRefused([name]).isEmpty { return "the host refuses it for any session" }
        if upper.hasPrefix("VIBESWITCHER_") { return "VibeSwitcher's own" }
        if upper.hasPrefix("LD_") || upper.hasPrefix("DYLD_") { return "a loader hook" }
        let loaders: Set<String> = ["NODE_OPTIONS", "NODE_PATH", "NODE_EXTRA_CA_CERTS", "NODE_TLS_REJECT_UNAUTHORIZED", "PYTHONPATH", "PYTHONSTARTUP",
                                    "PYTHONHOME", "PYTHONUSERBASE", "PERL5LIB", "PERL5OPT", "PERLLIB", "RUBYOPT", "RUBYLIB", "JAVA_TOOL_OPTIONS",
                                    "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH", "GEM_HOME", "GEM_PATH", "BUN_INSTALL", "DENO_DIR", "NPM_CONFIG_PREFIX",
                                    "GCONV_PATH", "GLIBC_TUNABLES", "MALLOC_CONF"]
        if loaders.contains(upper) || upper.hasPrefix("NPM_CONFIG_") || upper.hasPrefix("GIT_") { return "it changes what a program loads or runs" }
        if ["PATH", "MANPATH", "CDPATH", "FPATH", "INFOPATH"].contains(upper) || upper.hasSuffix("_PATH") { return "a search path" }
        if ["HOME", "USER", "LOGNAME", "SHELL", "PWD", "OLDPWD", "TMPDIR", "TMP", "TEMP", "ZDOTDIR", "INPUTRC", "TERMINFO"].contains(upper) {
            return "where a session's home, shell or files are"
        }
        if upper.hasPrefix("XDG_") || upper.hasSuffix("_CONFIG_DIR") || upper.hasSuffix("_CONFIG_FILE") || upper.hasSuffix("_CONFIG_HOME")
            || upper.hasSuffix("_HOME") || ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GNUPGHOME", "KUBECONFIG", "DOCKER_CONFIG", "AWS_SHARED_CREDENTIALS_FILE"].contains(upper) {
            return "where a program reads its config"
        }
        if upper.hasSuffix("_BASE_URL") || upper.hasSuffix("_API_URL") || upper.hasSuffix("_URL") || upper.contains("ENDPOINT") || upper.hasSuffix("_HOST")
            || upper.hasSuffix("_API_BASE") {
            return "whom a program talks to"
        }
        if upper.hasSuffix("_PROXY") || upper == "PROXY" { return "a proxy" }
        if ["SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "SSLKEYLOGFILE"].contains(upper) { return "what TLS trusts" }
        if upper.hasPrefix("PS") && upper.dropFirst(2).allSatisfy(\.isNumber) || ["PROMPT_COMMAND", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "IFS",
                                                                                 "PS4", "BASH_XTRACEFD", "HISTFILE"].contains(upper)
            || upper.hasPrefix("BASH_FUNC_") {
            return "a shell's prompt or startup hook"
        }
        if ["EDITOR", "VISUAL", "PAGER", "BROWSER", "SSH_ASKPASS", "SUDO_ASKPASS", "SSH_AUTH_SOCK", "DISPLAY", "WAYLAND_DISPLAY",
            "DBUS_SESSION_BUS_ADDRESS"].contains(upper) {
            return "a program the session would run, or a socket it would use"
        }
        return nil
    }

    /// Whether a variable's value is shown masked: a name that looks secret (a key, a token, a password…), or a value
    /// shaped like a known kind of key.
    public static func looksSecret(name: String, value: String) -> Bool {
        let upper = name.uppercased()
        let words = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "AUTH", "CREDENTIAL", "COOKIE", "PRIVATE", "SESSION", "SIGNATURE", "BEARER"]
        if words.contains(where: { upper.contains($0) }) { return true }
        return ["sk-", "ghp_", "gho_", "ghs_", "github_pat_", "xoxb-", "xoxp-", "AKIA", "glpat-"].contains { value.hasPrefix($0) }
    }

    /// `preset`'s variables as the user's confirmation shows them: each value, inert and short, or `<set>` for one that
    /// looks secret (`looksSecret`). Never sent to a web page (`Requests.presets`).
    public static func shownValues(_ preset: LaunchPreset) -> [String: String] {
        Dictionary(uniqueKeysWithValues: preset.env.map { name, value in
            (name, looksSecret(name: name, value: value) ? "<set>" : ConfigSeal.inert(value, limit: 120))
        })
    }

    /// The words after `claude` in a Claude preset's command (none: plain `claude`), or why it can't run on the node.
    static func arguments(_ preset: LaunchPreset) -> Result<[String], Refusal> {
        let words = preset.command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first else { return .success([]) }
        guard first == "claude" else {
            return .failure(Refusal(message: "its command starts \(ConfigSeal.inert(first, limit: 64)), and on this node a Claude preset's command is "
                                    + "`claude` and its arguments (the node runs the claude its link names, never one a shell finds)"))
        }
        let rest = Array(words.dropFirst())
        if let odd = rest.first(where: { $0.range(of: #"^[A-Za-z0-9_./:=,+@%\[\]-]+$"#, options: .regularExpression) == nil }) {
            return .failure(Refusal(message: "its command has \(ConfigSeal.inert(odd, limit: 64)), and on this node a Claude preset's arguments are "
                                    + "plain words (letters, digits and _ . / : = , + @ % [ ] -): no quotes, variables or shell syntax"))
        }
        return .success(rest)
    }

    /// The command line the host runs for `preset` (nil: the host's plain shell), Claude run as `program`.
    public static func command(_ preset: LaunchPreset, program: String) -> String? {
        guard preset.kind == .claude, case .success(let rest) = arguments(preset) else { return nil }
        return ([program] + rest).map(RecentProjects.shellQuote).joined(separator: " ")
    }

    /// The key presets' digests are made under: random, made at this server's start and kept in its memory only (never
    /// sent, never written). A restart makes a new one, so a digest from before it no longer matches: the user lists the
    /// presets again.
    static let key = SymmetricKey(size: .bits256)

    /// What binds the preset the user was shown to the one started: an HMAC under `key` of its name, kind, command,
    /// environment (names and values) and whether a shell stays, hex. Keyed (the security review of 2026-11-20): a
    /// plain hash of a variable's value, sent to a page that may only read, would let the page test guesses of that
    /// value (an API key) offline; without the key, two presets that differ in a value alone can't be told apart.
    static func digest(_ preset: LaunchPreset, key: SymmetricKey = SessionPresets.key) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: bound(preset), using: key)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `digest` is `preset`'s under `key`, compared in constant time.
    static func matches(_ preset: LaunchPreset, digest: String?, key: SymmetricKey = SessionPresets.key) -> Bool {
        guard let digest, digest.count == 64, let code = hexData(digest) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: bound(preset), using: key)
    }

    private static func bound(_ preset: LaunchPreset) -> Data {
        let env = preset.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let parts = ["vibeswitcher-preset", preset.name, preset.kind.rawValue, preset.command, preset.keepShell ? "keep" : "-"] + env
        return Data(parts.joined(separator: "\u{0}").utf8)
    }

    private static func hexData(_ text: String) -> Data? {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// A preset as the wire carries it (`session.presets`): its name, kind, command and the names of its environment's
    /// variables, whether a shell stays, where it is from, and why the node can't start it; with `values` (a terminal's
    /// request, never a page's), each variable's value as the confirmation shows it (`shownValues`: a secret-looking one
    /// `<set>`).
    static func value(_ listed: Listed, key: SymmetricKey = SessionPresets.key, values: Bool = false) -> NodeWire.Value {
        let preset = listed.preset
        var fields: [String: NodeWire.Value] = [
            "name": .string(preset.name), "kind": .string(preset.kind.rawValue), "command": .string(preset.command),
            "env": .array(preset.env.keys.sorted().map(NodeWire.Value.string)), "keepShell": .bool(preset.keepShell),
            "project": .bool(listed.project), "default": .bool(listed.isDefault),
            "digest": .string(digest(preset, key: key)), "refused": listed.refusal.map(NodeWire.Value.string) ?? .null,
        ]
        // For a terminal's confirmation only, never a page's: each variable's value, a secret-looking one masked.
        if values { fields["values"] = .object(shownValues(preset).mapValues(NodeWire.Value.string)) }
        return .object(fields)
    }
}
