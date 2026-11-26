import Foundation

/// The model families a task's worker sessions were launched on, as the session host saw each one when the lead bound
/// a worker's role to it (`LeadVault.Request.bind`): every `--model` on the command the host itself started that
/// session with (never what the request says), or Claude Code's default at that moment (`~/.claude/settings.json`'s
/// "model" in the host's home) for a launch that passed none. Kept in the vault's record of the task
/// (`Team.launchedFamilies`), which only the host writes, by the task the vault's own grant names (a team member's
/// under its member slug), never trimmed and never cleared, not even at retire (the branch may outlive it).
///
/// These only ever ADD to what an audit is kept off under the floor that keeps audits off the workers' model
/// (`excluded`): the workers' model (the floor's worker_model, the user's word, else Claude Code's default) stays
/// excluded as before, with the board's task model and launched model. Nothing here unlocks a model: argv isn't proof
/// of what ran (a decoy bind, Claude Code's own precedence, `/model` mid-session). A name that isn't a known family
/// adds nothing and removes nothing. The lead's own model was never part of the rule and isn't here (the security
/// architecture's open list: a lead that writes a task's code itself, and `--advisor`).
public enum WorkerLaunch {
    /// What the host saw of a session it binds a role to: the command it started it with (nil: a plain shell), and the
    /// folder it started in (its project settings' model and `env` are read there: they only add).
    public struct Seen: Equatable, Sendable {
        public var command: String?
        public var cwd: String?
        /// A test's stand-in programs a role's path may name, in place of a scratch node's (`nodeLinks`); nil: those.
        public var links: [Agent: [String]]?
        /// The names (never the values) of the environment its spawn request gave it; nil: not told.
        public var environmentNames: [String]?
        /// Whether `command` is the request's in full (false: the host's recorded one, long values as `'…'`, after a
        /// restart or a handover between the spawn and the bind).
        public var full: Bool
        public init(command: String?, cwd: String? = nil, links: [Agent: [String]]? = nil, environmentNames: [String]? = nil, full: Bool = true) {
            self.command = command
            self.cwd = cwd
            self.links = links
            self.environmentNames = environmentNames
            self.full = full
        }
    }

    static let families = ["mythos", "fable", "opus", "sonnet", "haiku"]
    /// Every family: what a launch whose default couldn't be read is recorded as.
    public static var allFamilies: [String] { families.sorted() }
    /// What a Codex worker's launch records (no Claude family): a Codex verifier is kept off such a task.
    public static let codexFamily = "codex"

    /// `model`'s family when it names one; nil for an alias (default, best, opusplan), a custom id or anything else.
    public static func family(of model: String?) -> String? {
        guard let name = model?.lowercased() else { return nil }
        return families.first { name.contains($0) }
    }

    /// Each family's current model id, as this build knows it (kept in step with `LeadPrices.table`'s newest, which a
    /// test holds it to): what a worker under the floor is launched with in place of the family's alias, and what each
    /// team session's `--settings` pins the aliases to under that floor (`pins`), so a worktree's settings `env` can't
    /// remap one. Whoever adds a model's price updates it in the same change (VibeSwitcher's maintainers, by hand, at a
    /// model's release). Stale, a session under the floor runs the older id its family had here, not the newest: an
    /// alias would have moved on with Claude Code; this keeps to what the record names. Without the floor nothing is pinned.
    public static let currentIDs: [String: String] = [
        "fable": "claude-fable-5-2", "mythos": "claude-mythos-5-2", "opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5",
        "haiku": "claude-haiku-5-5",
    ]

    /// `model` as its full id when it is a family's bare alias (`opus`, `Fable`, `opus[1m]` keeps its `[1m]`); any other
    /// name (an id already, or a name this doesn't know) as it is.
    public static func fullID(_ model: String) -> String {
        let lowered = model.lowercased()
        let bare = lowered.hasSuffix("[1m]") ? String(lowered.dropLast(4)) : lowered
        guard let id = currentIDs[bare] else { return model }
        return id + (bare == lowered ? "" : "[1m]")
    }

    /// The `env` each team session's `--settings` carries under the floor (`LeadLaunch.prepare`'s `pinModels`): each
    /// family's alias pinned to its id
    /// (ANTHROPIC_DEFAULT_<FAMILY>_MODEL), and ANTHROPIC_MODEL to the model the session is launched with (`model`, as
    /// its id; none without one). Not ANTHROPIC_BASE_URL: no subscription (claude.ai login) session has been seen to
    /// start and answer with it set (the security architecture's open list). Whether a project's or a worktree's
    /// settings `env` can still win key by key is unverified (the same list); a worker's project settings naming a
    /// routing key are refused at its bind (`routingKeys`).
    public static func pins(model: String?) -> [String: String] {
        var pins = Dictionary(uniqueKeysWithValues: currentIDs.map { ("ANTHROPIC_DEFAULT_\($0.key.uppercased())_MODEL", $0.value) })
        if let model { pins["ANTHROPIC_MODEL"] = fullID(model) }
        return pins
    }

    /// A name that says which one model it is: a family's or its claude-… id (`opusplan` is two, `best` none).
    public static func namesOne(_ model: String) -> Bool { LeadReviewFloor.knownModel(model) && runsOn(model).count == 1 }

    /// The families a model name a launch passed may run on: its own, `best` Opus, `opusplan` Opus and Sonnet (Claude
    /// Code's aliases); none for anything else (`default` is read as no `--model` by the caller).
    static func runsOn(_ model: String) -> [String] {
        switch model.lowercased() {
        case "best": return ["opus"]
        case "opusplan": return ["opus", "sonnet"]
        default: return family(of: model).map { [$0] } ?? []
        }
    }

    /// The most of a settings file read at a bind, and the deepest its JSON may nest.
    static let settingsLimit = 1 << 20
    static let depthLimit = 64

    /// A settings file under `root` (`components`), read the careful way (`Platform.Files.readRegular`: no link below
    /// `root`, a regular file only, opened without waiting, at most `settingsLimit` bytes) and parsed only when its JSON
    /// nests no deeper than `depthLimit`; with why not, when it isn't read (none: no such file).
    public static func settings(in root: String, _ components: [String]) -> (object: [String: Any]?, note: String?) {
        let name = components.joined(separator: "/")
        var read = Platform.Files.readRegular(in: root, path: components, limit: settingsLimit)
        // A link at the end (a settings file kept elsewhere): followed, with the same checks on what it names.
        if case .refused(let why) = read, why.hasSuffix(" is a link") { read = followingLastLink(in: root, components) }
        switch read {
        case .absent: return (nil, nil)
        case .refused(let why): return (nil, "\(name) in \(root) not read: \(why)")
        case .data(let data):
            guard nests(data, within: depthLimit) else {
                return (nil, "\(name) in \(root) not read: not UTF-8 JSON (no byte-order mark, no NUL) nesting at most \(depthLimit) deep")
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
            return (object, nil)
        }
    }

    /// The file at `components` under `root`, its last link followed (the folders on the way were checked for links by
    /// `readRegular` already): opened without waiting, a regular file of at most `settingsLimit` bytes, read once.
    static func followingLastLink(in root: String, _ components: [String]) -> Platform.Files.Under {
        let path = ([root] + components).joined(separator: "/")
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .absent : .refused("the link's file can't be opened") }
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .refused("the link names no regular file") }
        guard Int64(info.st_size) <= Int64(settingsLimit) else { return .refused("the link's file is more than the \(settingsLimit >> 20) MB read") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while data.count <= settingsLimit {
            let count = buffer.withUnsafeMutableBytes { Sys.read(fd, $0.baseAddress, min($0.count, settingsLimit + 1 - data.count)) }
            if count < 0 {
                if errno == EINTR { continue }
                return .refused("the link's file can't be read")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.count <= settingsLimit ? .data(data) : .refused("the link's file is more than the \(settingsLimit >> 20) MB read")
    }

    /// Whether `data`'s JSON nests at most `limit` deep (brackets outside strings counted), before a parser sees it:
    /// only UTF-8 with no byte-order mark and no NUL (what the parser could read otherwise, UTF-16 or UTF-32, isn't these
    /// bytes), and never closing more than it opened.
    static func nests(_ data: Data, within limit: Int) -> Bool {
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]), !data.contains(0), String(data: data, encoding: .utf8) != nil else { return false }
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x5B, 0x7B:
                depth += 1
                if depth > limit { return false }
            case 0x5D, 0x7D:
                depth -= 1
                if depth < 0 { return false }
            default: break
            }
        }
        return true
    }

    /// The `env` names that send Claude Code to another endpoint or provider than the one its `--model` names there:
    /// a base URL, Bedrock, Vertex or Foundry and theirs, a proxy and the certificates that let one read it. A worker
    /// whose project settings name one is refused at its bind under the floor (its record would say its `--model`).
    public static let routingKeys: Set<String> = [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL", "ANTHROPIC_FOUNDRY_BASE_URL", "ANTHROPIC_FOUNDRY_RESOURCE",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_SKIP_BEDROCK_AUTH", "CLAUDE_CODE_SKIP_VERTEX_AUTH",
        "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy", "NODE_EXTRA_CA_CERTS", "ANTHROPIC_CUSTOM_HEADERS",
    ]

    /// The model names a session's project settings in `cwd` give Claude Code (their "model", and their `env`'s
    /// ANTHROPIC_MODEL and ANTHROPIC_DEFAULT_*_MODEL), and the routing names their `env` holds (`routingKeys`, with the
    /// file): branch content, read the careful way (`settings`) only to add; with why a file wasn't read.
    static func projectModels(cwd: String?) -> (models: [String], notes: [String], routing: [String]) {
        guard let cwd else { return ([], [], []) }
        var found: [String] = [], notes: [String] = [], routing: [String] = []
        for file in ["settings.json", "settings.local.json"] {
            let read = settings(in: cwd, [".claude", file])
            if let note = read.note { notes.append(note) }
            guard let object = read.object else { continue }
            if let model = object["model"] as? String { found.append(model) }
            let env = object["env"] as? [String: Any] ?? [:]
            for (key, value) in env where key == "ANTHROPIC_MODEL" || (key.hasPrefix("ANTHROPIC_DEFAULT_") && key.hasSuffix("_MODEL")) {
                if let value = value as? String { found.append(value) }
            }
            routing += env.keys.filter(routingKeys.contains).sorted().map { "\($0) in .claude/\(file)" }
        }
        return (found, notes, routing)
    }

    /// The `--model` (or `--model=`) a launch command passes (`options(of:)`): the last one, as Claude Code's own option
    /// parsing takes it; nil when none.
    public static func launchModel(command: String) -> String? {
        options(of: command).last { $0.flag == "--model" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: A launch's options, as its agent reads them

    /// One option of a launch command: its flag (the long or short name, without `=value`), the value it took (nil: none),
    /// and whether that value was joined to it (`--model=x`, `-mx`).
    public struct Option: Equatable, Sendable {
        public var flag: String
        public var value: String?
        public var joined: Bool
    }

    /// How many words a flag takes: none, one whatever it is (`<value>`: Claude Code's commander and Codex's clap take
    /// the next word even when it is `--` or starts with `-`), one only when the next word doesn't start with `-`
    /// (`[value]`), or one and every next word that doesn't (`<values...>`).
    public enum Arity: Sendable { case none, required, optional, variadic }

    /// Claude Code's flags that take a value, from its own option definitions (2.1.332's `.option(…)` and `new Option(…)`
    /// texts, read from its binary; no session started): `[value]` ones optional. Every other flag takes none.
    static let claudeArity: [String: Arity] = [
        "--model": .required, "--fallback-model": .required, "--advisor": .required, "--effort": .required, "--name": .required, "-n": .required,
        "--settings": .required, "--setting-sources": .required, "--permission-mode": .required, "--agents": .required, "--agent": .required,
        "--append-system-prompt": .required, "--append-system-prompt-file": .required, "--system-prompt": .required, "--system-prompt-file": .required,
        "--mcp-config": .variadic, "--add-dir": .variadic, "--allowedTools": .variadic, "--allowed-tools": .variadic,
        "--disallowedTools": .variadic, "--disallowed-tools": .variadic, "--tools": .variadic, "--plugin-dir": .required,
        "--session-id": .required, "--output-format": .required, "--input-format": .required, "--max-turns": .required,
        "--resume": .optional, "-r": .optional, "--debug": .optional, "-d": .optional, "--worktree": .optional, "-w": .optional, "--from-pr": .optional,
    ]
    /// Codex's, from its `--help` (0.x, run in a scratch home): every one of these takes one value; `--no-daemon`,
    /// `--oss`, `--search` and the rest none.
    static let codexArity: [String: Arity] = [
        "--config": .required, "-c": .required, "--model": .required, "-m": .required, "--profile": .required, "-p": .required,
        "--sandbox": .required, "-s": .required, "--cd": .required, "-C": .required, "--add-dir": .required,
        "--ask-for-approval": .required, "-a": .required, "--enable": .required, "--disable": .required,
        "--image": .variadic, "-i": .variadic, "--local-provider": .required,
    ]

    /// `command`'s options as its agent's parser reads them, the one reading every check here uses (`launchModel`,
    /// `RoleLaunchCheck`): after its program (leading assignments and `env` with its options passed over, as
    /// `program(of:)` reads them), each flag takes the words its arity says (`claudeArity`, `codexArity`; `agent` nil:
    /// Codex's when the program's name starts with `codex`), and only a `--` where a flag could start ends them (what
    /// follows is the start message). A word that is neither is a positional, passed over.
    public static func options(of command: String, agent: Agent? = nil) -> [Option] {
        var words = tokens(command)[...]
        while words.first?.assignment == true { words = words.dropFirst() }
        if let first = words.first?.text, first == "env" || first == "/usr/bin/env" || first == "/bin/env" {
            words = words.dropFirst()
            while let option = words.first?.text, option.hasPrefix("-") {
                words = words.dropFirst()
                if option == "-u" || option == "--unset" { words = words.dropFirst() }
            }
            while words.first?.assignment == true { words = words.dropFirst() }
        }
        guard let program = words.first?.text else { return [] }
        let rest = Array(words.dropFirst().map(\.text))
        let codex = agent.map { $0 == .codex } ?? (program as NSString).lastPathComponent.hasPrefix("codex")
        let arity = codex ? codexArity : claudeArity
        var options: [Option] = []
        var index = 0
        while index < rest.count {
            let word = rest[index]
            index += 1
            if word == "--" { break }
            guard word.hasPrefix("-"), word != "-" else { continue }
            var flag = word, joined: String?
            if word.hasPrefix("--") {
                if let equals = word.firstIndex(of: "=") { flag = String(word[..<equals]); joined = String(word[word.index(after: equals)...]) }
            } else if word.count > 2 {
                flag = String(word.prefix(2))
                let tail = word.dropFirst(2)
                joined = String(tail.hasPrefix("=") ? tail.dropFirst() : tail)
            }
            var option = Option(flag: flag, value: joined, joined: joined != nil)
            switch arity[flag] ?? .none {
            case .none:
                break
            case .required, .variadic:
                if joined == nil, index < rest.count {
                    option.value = rest[index]
                    index += 1
                }
                if arity[flag] == .variadic { while index < rest.count, !rest[index].hasPrefix("-") { index += 1 } }
            case .optional:
                if joined == nil, index < rest.count, !rest[index].hasPrefix("-") {
                    option.value = rest[index]
                    index += 1
                }
            }
            options.append(option)
        }
        return options
    }

    /// The agent a launch command starts, judged by what runs, never by a scan of its words: the command must be one
    /// simple command of literal words (no `;`, `&`, `|`, redirection, substitution, expansion or newline outside
    /// quotes: `controlled`), no assignment, its program the first word or the first after `env` with its options (the
    /// one transparent wrapper; `sh -c`, `exec -a` or any other wrapper isn't), and that program Claude Code's or
    /// Codex's: the bare name `claude` or `codex` (what the session's shell finds), or a path that resolves into Claude
    /// Code's versioned binaries or Codex's install root (`agent(atPath:links:)`), or to a scratch node's stand-ins
    /// (`nodeLinks`). Anything else is nil (a shell, a wrapper, another program), which a bind under the floor refuses.
    public static func commandAgent(_ command: String, links: [Agent: [String]] = nodeLinks) -> Agent? {
        switch program(of: command) {
        case .bare(let agent): return agent
        case .path(let path): return agent(atPath: path, links: links)
        case nil: return nil
        }
    }

    /// What `commandAgent` reads of a command without touching the disk: the agent a bare name starts, or the path
    /// whose resolution decides (`agent(atPath:links:)`); nil when it can't be told (not one simple command, a wrapper,
    /// any assignment, an expansion or a glob).
    enum Program: Equatable { case bare(Agent), path(String) }

    static func program(of command: String) -> Program? {
        guard !controlled(command) else { return nil }
        var rest = tokens(command)[...]
        // No assignment at all: neither the node's launches nor the Mac's presets put one in a role's command (a
        // preset's env goes in the session's environment), and any one may change the model, the config or what runs.
        func skipAssignments() -> Bool { !(rest.first?.assignment ?? false) }
        guard skipAssignments() else { return nil }
        if let first = rest.first?.text, first == "env" || first == "/usr/bin/env" || first == "/bin/env" {
            rest = rest.dropFirst()
            while let option = rest.first?.text, option.hasPrefix("-") {
                rest = rest.dropFirst()
                if option == "-u" || option == "--unset" { rest = rest.dropFirst() }
                guard ["-i", "-", "--ignore-environment", "-u", "--unset"].contains(option) || option.hasPrefix("--unset=") else { return nil }
            }
            guard skipAssignments() else { return nil }
        }
        guard let program = rest.first?.text else { return nil }
        if program == "claude" { return .bare(.claude) }
        if program == "codex" { return .bare(.codex) }
        return program.hasPrefix("/") ? .path(program) : nil
    }


    /// The agent the program at `path` is, by what it resolves to, never by which link it was reached through: Claude
    /// Code's versioned binary in the account's `~/.local/share/claude/versions/`, or Codex under one of its install
    /// roots (`codexRoots`, `CodexRoot.holds`); on a scratch node, a test's stand-in its links name (`links`,
    /// `nodeLinks`). A link the user's `~/.local/bin/claude` points at `/bin/bash` resolves to bash: nil. Anything else
    /// is nil (a name alone, a package path anyone of the uid could make).
    static func agent(atPath path: String, links: [Agent: [String]], codexRoots: [CodexRoot] = codexRoots) -> Agent? {
        guard let real = realPathOf(path) else { return nil }
        let versions = (VibePaths.accountHome as NSString).appendingPathComponent(".local/share/claude/versions") + "/"
        if real.hasPrefix(versions), VersionedClaude.isBinary(real) { return .claude }
        if codexRoots.contains(where: { $0.holds(real) }) { return .codex }
        for (agent, paths) in links where paths.contains(where: { realPathOf($0) == real }) { return agent }
        return nil
    }

    /// The programs a scratch node's roles start by (`<root>/v2/test/claude` and `codex`, a test's stand-ins), counted by
    /// what they are only on a scratch node: a root other than the account's own `~/.vibeswitcher`
    /// (`VibePaths.isAccountRoot`, the test `NodeFolders.isUsersRoot` makes too). On the user's node none: anyone of the
    /// uid could make that folder.
    public static var nodeLinks: [Agent: [String]] {
        guard !VibePaths.isAccountRoot(VibePaths.root, accountHome: VibePaths.accountHome) else { return [:] }
        let test = VibePaths.root.appendingPathComponent("v2/test").path
        return [.claude: [test + "/claude"], .codex: [test + "/codex"]]
    }

    /// A folder Codex's package is installed in, and whether it counts only when root's.
    public struct CodexRoot: Equatable, Sendable {
        /// The package's folder, ending in `/`.
        public var folder: String
        /// npm's global roots: counted only when every folder from `/` down to the program, and the program, is root's
        /// and writable by no group or other (`rootsAlone`). Those a same-uid writer can't make or change, so they hold
        /// more than the home one, which anyone of the uid could fill.
        public var rootOwned: Bool

        public init(folder: String, rootOwned: Bool) {
            self.folder = folder.hasSuffix("/") ? folder : folder + "/"
            self.rootOwned = rootOwned
        }

        /// Whether the resolved program `real` is this root's.
        public func holds(_ real: String) -> Bool {
            real.hasPrefix(folder) && (!rootOwned || WorkerLaunch.rootsAlone(real))
        }
    }

    /// Codex's install roots: bun's global package in the account's home (`~/.bun/bin/codex` resolves into it), and npm's
    /// global roots (`/usr/lib/node_modules`, `/usr/local/lib/node_modules`, Homebrew's `/opt/homebrew/lib/node_modules`)
    /// when root's (`CodexRoot.rootOwned`). Read where it's used (HomePathLint).
    public static var codexRoots: [CodexRoot] {
        [CodexRoot(folder: (VibePaths.accountHome as NSString).appendingPathComponent(".bun/install/global/node_modules/@openai/codex"), rootOwned: false)]
            + ["/usr/lib/node_modules", "/usr/local/lib/node_modules", "/opt/homebrew/lib/node_modules"].map {
                CodexRoot(folder: $0 + "/@openai/codex", rootOwned: true)
            }
    }

    /// Whether `real` (a resolved path) and every folder from `/` down to it is root's, owned by uid 0 and writable by no
    /// group or other, each looked at without following a link.
    static func rootsAlone(_ real: String) -> Bool {
        guard real.hasPrefix("/") else { return false }
        var paths = ["/"]
        for component in real.split(separator: "/") { paths.append((paths.count == 1 ? "" : paths[paths.count - 1]) + "/" + component) }
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & (S_IWGRP | S_IWOTH) == 0,
                  info.st_mode & S_IFMT != S_IFLNK else { return false }
        }
        return true
    }

    /// Why a role's program at `path`, meant as Codex, isn't counted as Codex: named with the roots it would have had to
    /// resolve into.
    public static func codexRootsSaid(_ path: String, roots: [CodexRoot] = codexRoots) -> String {
        let listed = roots.map { $0.folder + ($0.rootOwned ? " (root's)" : "") }.joined(separator: ", ")
        return "\(path) doesn't resolve into one of Codex's install roots here (\(listed))"
    }

    static func realPathOf(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }


    /// Whether `command` is more than one simple command of literal words, as the shell would run it: a list (`;`,
    /// `&`, `|`), a redirection, a substitution or expansion (`$` anywhere but in single quotes, backquote), a glob or
    /// brace (`*`, `?`, `[`, `{` outside quotes), a word starting with an unquoted `~`, a subshell or a newline. What's in
    /// single quotes is literal (the start message, the tool server's settings).
    static func controlled(_ command: String) -> Bool {
        var single = false, double = false, escaped = false
        var atWordStart = true
        for character in command {
            if escaped { escaped = false; atWordStart = false; continue }
            if single { if character == "'" { single = false }; continue }
            if character == "\\" { escaped = true; atWordStart = false; continue }
            if double {
                if character == "\"" { double = false } else if character == "`" || character == "$" { return true }
                continue
            }
            switch character {
            case "'": single = true
            case "\"": double = true
            case ";", "&", "|", "<", ">", "`", "(", ")", "\n", "$", "*", "?", "[", "{": return true
            case "~" where atWordStart: return true
            default: break
            }
            atWordStart = character.isWhitespace
        }
        return false
    }

    /// `command`'s words as a POSIX shell splits them: single quotes literal, double quotes with `\` escaping `"`, `\`,
    /// `$` and `` ` ``, a bare `\` escaping the next character (`RecentProjects.shellQuote`'s `'\''` among them).
    static func words(_ command: String) -> [String] { tokens(command).map(\.text) }

    /// `command`'s words as `words` splits them, each with whether the shell takes it as an assignment: a word whose
    /// first `=` comes after a name of unquoted, unescaped ASCII `[A-Za-z_][A-Za-z0-9_]*` (`'FOO=1'`, `"PATH"=/x` and
    /// `é=1` aren't: the shell runs them as a program's name).
    static func tokens(_ command: String) -> [(text: String, assignment: Bool)] {
        var tokens: [(text: String, assignment: Bool)] = []
        var word = "", inWord = false
        // Before the word's first `=`: whether every character was plain and makes a name.
        var name = "", plainName = true, sawEquals = false, assignment = false
        func plain(_ character: Character) {
            guard !sawEquals else { return }
            if character == "=" {
                sawEquals = true
                assignment = plainName && !name.isEmpty
                return
            }
            let ascii = character.isASCII && (character.isLetter || character == "_" || (character.isNumber && !name.isEmpty))
            if !ascii { plainName = false }
            name.append(character)
        }
        func quoted() { if !sawEquals { plainName = false } }
        func end() {
            if inWord { tokens.append((word, assignment)) }
            word = ""; inWord = false; name = ""; plainName = true; sawEquals = false; assignment = false
        }
        var characters = command.makeIterator()
        while let character = characters.next() {
            switch character {
            case "'":
                inWord = true
                quoted()
                while let next = characters.next(), next != "'" { word.append(next) }
            case "\"":
                inWord = true
                quoted()
                while let next = characters.next(), next != "\"" {
                    if next == "\\", let escaped = characters.next() {
                        if !"\"\\$`".contains(escaped) { word.append(next) }
                        word.append(escaped)
                    } else {
                        word.append(next)
                    }
                }
            case "\\":
                inWord = true
                quoted()
                if let escaped = characters.next() { word.append(escaped) }
            case _ where character.isWhitespace:
                end()
            default:
                inWord = true
                plain(character)
                word.append(character)
            }
        }
        end()
        return tokens
    }

    /// The families a launch adds (`seen` nil: the host didn't know the session, none): its `--model`'s (`runsOn`), or
    /// with none (or `default`), Claude Code's default's as `home` holds it now, and with no default set either, Claude's
    /// own, which the floor counts as Opus (`LeadReviewFloor.workersModel`); and whatever its project settings name
    /// (`projectModels`). An unknown name adds nothing.
    /// What a bind takes from what the host saw of the session: the `--model` its command passes (read from the argv
    /// on the caller's queue, whatever the files do), Claude Code's default and the project settings' models (read the
    /// careful way, bounded), the families a worker's launch adds, and whether a settings file wasn't read.
    public struct BindFacts: Equatable, Sendable {
        /// The host knew the session (its command).
        public var known = false
        /// The `--model` passed (`default` read as none).
        public var model: String?
        /// The agent the command starts, as its argv says (`commandAgent`); nil: none told apart (a plain shell, an
        /// unknown program).
        public var agent: Agent?
        /// Claude Code's default as the vault's home held it (nil: none set, or not read).
        public var defaultModel: String?
        /// The home's settings were read (or aren't there): false when refused or out of time, so `defaultModel` isn't
        /// known, and the bind fails closed (`LeadVault.Book.verifierBindRefusal`, every family for a worker).
        public var defaultKnown = false
        /// The families a worker's launch adds (`families`).
        public var families: [String] = []
        /// A settings file there wasn't read (refused, or the reads ran out of time).
        public var unread = false
        /// The command the host started it with, its spawn environment's names, and the `--settings` file it names, as
        /// read (`RoleLaunchCheck`, judged under the floor at the bind).
        public var command: String?
        public var environmentNames: [String]?
        public var settings: RoleLaunchCheck.SettingsRead?
        public var full = true
        /// The routing names a worker's project settings hold (`routingKeys`), each with its file.
        public var projectRouting: [String] = []
        public var notes: [String] = []
    }

    /// `BindFacts` for `seen`: the command's model now, the files on a global queue waited for at most `limit` (past it,
    /// only the command's family is recorded, and that's said).
    public static func bindFacts(seen: Seen?, home: String, limit: TimeInterval) -> BindFacts {
        guard let seen else { return BindFacts() }
        let links = seen.links ?? nodeLinks
        var facts = BindFacts(known: true)
        facts.command = seen.command
        facts.environmentNames = seen.environmentNames
        facts.full = seen.full
        let settingsPath = seen.command.flatMap(RoleLaunchCheck.settingsPath(in:))
        facts.model = seen.command.flatMap(launchModel(command:)).flatMap { $0.lowercased() == "default" ? nil : $0 }
        // The agent: a bare name told now; a path resolved in the bounded block below (a hung mount never holds the
        // vault), nil past its time.
        let told = seen.command.flatMap { Self.program(of: $0) }
        if case .bare(let agent) = told { facts.agent = agent }
        let done = DispatchSemaphore(value: 0)
        let result = Found()
        DispatchQueue.global(qos: .userInitiated).async {
            let home = settings(in: home, [".claude", "settings.json"])
            let project = projectModels(cwd: seen.cwd)
            var agent: Agent?
            if case .path(let path) = told { agent = Self.agent(atPath: path, links: links) }
            // The `--settings` file a command names, read the careful way (its content judged at the bind).
            var settingsText: String?
            if let settingsPath, case .data(let data)? = Optional(Platform.Files.readRegular(in: (settingsPath as NSString).deletingLastPathComponent,
                                                                                            path: [(settingsPath as NSString).lastPathComponent],
                                                                                            limit: settingsLimit)) {
                settingsText = String(data: data, encoding: .utf8)
            }
            result.set((home.object?["model"] as? String, project.models, home.note.map { [$0] } ?? [], project.notes, home.note == nil, agent, settingsText,
                        project.routing))
            done.signal()
        }
        if done.wait(timeout: .now() + limit) == .success, let read = result.get() {
            facts.defaultModel = read.defaultModel
            facts.defaultKnown = read.homeRead
            if case .path = told { facts.agent = read.agent }
            if let settingsPath { facts.settings = read.settingsText.map { .text($0) } ?? .unread(settingsPath) }
            facts.notes = read.homeNotes + read.projectNotes
            facts.projectRouting = read.projectRouting
            facts.unread = !read.projectNotes.isEmpty
            facts.families = Array(Set(ran(facts) + read.projectModels.flatMap(runsOn))).sorted()
        } else {
            facts.unread = true
            facts.notes = ["a launch's settings weren't read: reading them took more than \(Int(limit)) s; only its command's model is recorded"]
            facts.families = ran(facts).sorted()
            if let settingsPath { facts.settings = .unread(settingsPath) }
        }
        return facts
    }

    /// The families a launch ran on by its command: its `--model`'s; with none, Claude Code's default's, and every
    /// family when that default couldn't be read (never a guess: the user is then asked rather than an audit run on it).
    static func ran(_ facts: BindFacts) -> [String] {
        if let model = facts.model { return runsOn(model) }
        guard facts.defaultKnown else { return families }
        return runsOn(LeadReviewFloor.workersModel(facts.defaultModel))
    }

    /// The families a launch adds and why a file wasn't read (`bindFacts`, unbounded): for a caller that waits itself.
    public static func families(seen: Seen?, home: String) -> (families: [String], notes: [String]) {
        let facts = bindFacts(seen: seen, home: home, limit: 3_600)
        return (facts.families, facts.notes)
    }

    /// `bindFacts`' families and notes, bounded by `limit`.
    public static func families(seen: Seen?, home: String, limit: TimeInterval) -> (families: [String], notes: [String]) {
        let facts = bindFacts(seen: seen, home: home, limit: limit)
        return (facts.families, facts.notes)
    }

    /// How long a bind waits for its reads.
    public static let bindLimit: TimeInterval = 2

    /// The bounded reads' result, handed between two queues.
    private final class Found: @unchecked Sendable {
        typealias Read = (defaultModel: String?, projectModels: [String], homeNotes: [String], projectNotes: [String], homeRead: Bool, agent: Agent?,
                          settingsText: String?, projectRouting: [String])
        private let lock = NSLock()
        private var value: Read?
        func set(_ found: Read) { lock.withLock { value = found } }
        func get() -> Read? { lock.withLock { value } }
    }

    /// What a task's audit is kept off under the floor, and the line that says so: the workers' model (`floorModel`,
    /// the floor's worker_model, else `projectDefault`, Claude Code's default) and the families the vault recorded for
    /// the task's launches (`launched`, nil: no record).
    public static func excluded(floorModel: String?, projectDefault: String?, launched: [String]?) -> (workers: [String?], text: String) {
        let base = floorModel.map { "workers' model \(shown($0)) by your review floor" }
            ?? "Claude Code's default \(projectDefault.map(shown) ?? "(Claude's own, counted as opus)")"
        let record = launched.flatMap { $0.isEmpty ? nil : $0 }.map { " and launched on \($0.joined(separator: " and ")) by the host's record" }
            ?? ", no launch record"
        return ([floorModel ?? projectDefault] + (launched ?? []), "kept off " + base + record)
    }

    /// A model as the line says it: its family when known.
    static func shown(_ model: String) -> String { family(of: model) ?? model }
}

/// The lead's audit of `task` at `commit` found no model the floor leaves and asked the user (`LeadVault.Request
/// .offerAuditModels`): only an answer to that question, naming that task and commit, records an allowance.
public struct AuditOffer: Codable, Equatable, Sendable {
    public var task: String
    public var commit: String
    public var at: Double
    /// The question as the audit asked it (`questionDigest` of its text and options): a reworded or re-optioned one
    /// isn't the audit's.
    public var digest: String?

    /// The digest of a question's text and options, as the audit asked them.
    public static func questionDigest(text: String, options: [String]) -> String {
        LeadVault.hash(([text] + options).joined(separator: "\u{0}"))
    }
}

/// The user allowed `model` to audit `task` at `commit` (their answer to an `AuditOffer`'s question): used by the one
/// audit that starts while the task's branch is at that commit. The vault takes it at that audit's verifier's bind
/// (`usedBy`: the verifier's grant, or a finders' panel, whose other finders it also lets bind), never again.
public struct AuditAllowance: Codable, Equatable, Sendable {
    public var task: String
    public var commit: String
    public var model: String
    public var at: Double
    public var usedBy: String?
    /// A finders' panel that took it: its size then, and the finders (by index) bound on it, each once: never more
    /// than one panel's worth, whatever grants come later under that panel's name.
    public var panelSize: Int?
    public var takenIndices: [Int]?
}

extension LeadVault {
    /// The offer behind a question, nil for a question no audit asked (or a vault that can't be asked).
    public func auditOffer(root: String, question: String) -> AuditOffer? {
        guard case .offer(let offer)? = try? call(.auditOffer(root: root, question: question)) else { return nil }
        return offer
    }

    /// The lead's audit of `task` at `commit` asked `question` (its id): the user's answer to it may then allow a model.
    public func offerAuditModels(root: String, task: String, commit: String, question: String, digest: String) throws {
        _ = try call(.offerAuditModels(root: root, task: task, commit: commit, question: question, digest: digest))
    }

    /// Whether a worker of `task` (or of its team's members) was bound while a settings file of its worktree wasn't read.
    public func settingsUnread(root: String, task: String) -> Bool {
        guard case .approved(let unread)? = try? call(.unreadSettings(root: root, task: task)) else { return false }
        return unread
    }

    /// The families the vault's own record keeps `task`'s audits off under the floor (nil: no such floor, or a vault
    /// that can't say): what the lead's tools choose an audit model from, with the board's.
    public func auditExclusions(root: String, task: String) -> [String]? {
        guard case .families(let families)? = try? call(.auditExclusions(root: root, task: task)) else { return nil }
        return families
    }

    /// The allowance the user gave for `task`, if any.
    public func auditAllowance(root: String, task: String) -> AuditAllowance? {
        guard case .allowance(let allowance)? = try? call(.auditAllowance(root: root, task: task)) else { return nil }
        return allowance
    }

    /// The families the host recorded for `task`'s worker launches and its team members' (`WorkerLaunch`); nil: none
    /// kept, or the vault couldn't be asked (an older host).
    public func launchedFamilies(root: String, task: String) -> [String]? {
        guard case .families(let families)? = try? call(.launchedFamilies(root: root, task: task)) else { return nil }
        return families
    }
}
