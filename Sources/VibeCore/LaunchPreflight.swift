import Foundation

/// What a lead or a worker needs on this Mac before it's started, looked at first: the agent's CLI as the session's login
/// shell finds it (`LoginShellCommand`), git and the Command Line Tools behind it, and VibeSwitcher's own helpers. On a
/// new Mac one of them is often missing, and the start then failed with an error code ("No such file or directory") or
/// git's own refusal ("isn't in a git repository"); each missing piece is named here with how to get it. Only looks:
/// it installs nothing and never runs `xcode-select --install` (nor the git stub, which offers to). Blocks for as long
/// as the login shell takes to start; never on the main thread. A pass is kept for `keep` seconds, so a start asked
/// for again soon (or many at once) doesn't start the shell again; a miss isn't kept: you install it and try again.
public struct LaunchPreflight: Sendable {
    public enum Missing: Equatable, Sendable {
        /// `$SHELL` isn't there: no session can start.
        case shell(String)
        /// The agent's CLI, as the command names it (`claude`, `/opt/homebrew/bin/codex`), which the login shell doesn't find.
        case agent(program: String, shell: String)
        /// `xcode-select -p` names no developer folder: the Command Line Tools (or Xcode) aren't installed.
        case commandLineTools
        /// The developer folder `xcode-select -p` names has no git: /usr/bin/git is only Apple's stub.
        case gitStub(developer: String)
        /// git is there but doesn't run (`git --version` failed: Xcode's license not accepted, say): what it said.
        case gitFails(String)
        /// No git at the path VibeSwitcher runs it from.
        case git(String)
        /// One of VibeSwitcher's own programs isn't in its bundle.
        case helper(name: String, path: String)
    }

    /// Everything missing, one message for each.
    public struct Problem: Error, Equatable, Sendable, CustomStringConvertible {
        public var missing: [Missing]
        public init(missing: [Missing]) { self.missing = missing }
        public var title: String {
            missing.count == 1 ? LaunchPreflight.title(missing[0]) : "\(missing.count) things it needs are missing on this Mac."
        }
        public var text: String {
            missing.count == 1 ? LaunchPreflight.text(missing[0])
                : missing.map { LaunchPreflight.title($0) + " " + LaunchPreflight.text($0) }.joined(separator: "\n\n")
        }
        public var description: String { title + " " + text }
    }

    /// The login shell sessions start in (`HostedSession.arguments`).
    public var shell: String
    public var xcodeSelect: String
    /// The git VibeSwitcher runs (`Git.run`).
    public var git: String
    /// How long the login shell may take to answer; past it, the agent isn't called missing.
    public var timeout: TimeInterval
    public var keep: TimeInterval
    var now: @Sendable () -> Date
    private let passed = Passes()

    public init(shell: String = LoginShellVariable.userShell, xcodeSelect: String = "/usr/bin/xcode-select", git: String = "/usr/bin/git",
                timeout: TimeInterval = 10, keep: TimeInterval = 60) {
        self.init(shell: shell, xcodeSelect: xcodeSelect, git: git, timeout: timeout, keep: keep, now: { Date() })
    }

    init(shell: String, xcodeSelect: String, git: String, timeout: TimeInterval, keep: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.shell = shell
        self.xcodeSelect = xcodeSelect
        self.git = git
        self.timeout = timeout
        self.keep = keep
        self.now = now
    }

    /// The app's and the tool server's: one per process, so its passes are shared by every start there.
    public static let standard = LaunchPreflight()

    /// What's missing to start `command` (a session's command line: the agent's CLI, its flags) with `helpers` (paths of
    /// VibeSwitcher's own programs it needs); nil when nothing is.
    public func check(command: String, helpers: [String] = []) -> Problem? {
        let key = ([shell, xcodeSelect, git, command] + helpers).joined(separator: "\u{0}")
        if passed.passed(key, since: now().addingTimeInterval(-keep)) { return nil }
        let missing = look(command: command, helpers: helpers)
        guard missing.isEmpty else { return Problem(missing: missing) }
        passed.pass(key, at: now())
        return nil
    }

    func look(command: String, helpers: [String]) -> [Missing] {
        var missing: [Missing] = []
        let files = FileManager.default
        for helper in helpers where !files.isExecutableFile(atPath: helper) {
            missing.append(.helper(name: (helper as NSString).lastPathComponent, path: helper))
        }
        if !files.isExecutableFile(atPath: shell) {
            missing.append(.shell(shell))
        } else if let program = Self.program(in: command) {
            if program.contains("/") {
                let path = (program as NSString).expandingTildeInPath
                if !files.isExecutableFile(atPath: path) { missing.append(.agent(program: program, shell: shell)) }
            } else if LoginShellCommand.resolve(program, shell: shell, timeout: timeout) == .missing {
                missing.append(.agent(program: program, shell: shell))
            }
        }
        if let git = lookAtGit() { missing.append(git) }
        return missing
    }

    /// git's turn: the stub at /usr/bin/git runs the developer folder's git, so the folder is looked at first, and git
    /// itself is run only once it's there (the stub without one offers to install the Command Line Tools).
    func lookAtGit() -> Missing? {
        guard FileManager.default.isExecutableFile(atPath: git) else { return .git(git) }
        guard FileManager.default.isExecutableFile(atPath: xcodeSelect) else { return .commandLineTools }
        let selected = Shell.run(executable: xcodeSelect, args: ["-p"], in: "/", timeout: timeout, grace: 1)
        let developer = selected.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Out of time: not known, so not said.
        if selected.timedOut || selected.cancelled { return nil }
        guard selected.ok, !developer.isEmpty else { return .commandLineTools }
        guard FileManager.default.isExecutableFile(atPath: (developer as NSString).appendingPathComponent("usr/bin/git")) else {
            return .gitStub(developer: developer)
        }
        let version = Shell.run(executable: git, args: ["--version"], in: "/", timeout: timeout, grace: 1)
        if version.timedOut || version.cancelled { return nil }
        guard version.ok, version.output.hasPrefix("git version") else {
            let said = (version.error + "\n" + version.output).trimmingCharacters(in: .whitespacesAndNewlines)
            return .gitFails(said.components(separatedBy: .newlines).first { !$0.isEmpty } ?? "it exited with status \(version.status)")
        }
        return nil
    }

    /// The program a command line runs: its first word, past variables set for it (`FOO=1 claude`) and `exec`,
    /// `command`, `env`, `noglob` or `nocorrect` before it, unquoted. Nil for an empty line.
    public static func program(in command: String) -> String? {
        var words = Self.words(command)[...]
        while let word = words.first {
            if ["exec", "command", "builtin", "noglob", "nocorrect", "env"].contains(word) || (word.hasPrefix("-") && word != "-")
                || isAssignment(word) {
                words = words.dropFirst()
            } else {
                return word
            }
        }
        return nil
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "=") else { return false }
        return LaunchPlan.validEnvName(String(word[..<equals]))
    }

    /// The line's words, as sh splits them: quotes and backslashes taken away; up to a `#`, `;`, `&` or `|` outside quotes.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var word = "", inWord = false
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                word.append(character)
                escaped = false
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else if character == "\\" && open == "\"" { escaped = true } else { word.append(character) }
                continue
            }
            switch character {
            case "\\": escaped = true; inWord = true
            case "'", "\"": quote = character; inWord = true
            case " ", "\t", "\n":
                if inWord { words.append(word) }
                word = ""
                inWord = false
            case "#" where !inWord, ";", "&", "|":
                if inWord { words.append(word) }
                return words
            default:
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }

    // MARK: What each says

    static func agentName(_ program: String) -> String {
        switch (program as NSString).lastPathComponent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        default: return (program as NSString).lastPathComponent
        }
    }

    static func install(_ program: String) -> String {
        switch (program as NSString).lastPathComponent {
        case "claude": return "Install Claude Code (claude.com/claude-code)"
        case "codex": return "Install Codex (github.com/openai/codex)"
        default: return "Install it"
        }
    }

    public static func title(_ missing: Missing) -> String {
        switch missing {
        case .shell: return "Your login shell isn't there."
        case .agent(let program, _): return "\(agentName(program)) isn't installed."
        case .commandLineTools, .gitStub: return "git needs Apple's Command Line Tools."
        case .gitFails: return "git doesn't run."
        case .git: return "git isn't on this Mac."
        case .helper(let name, _): return "VibeSwitcher is missing its \(name)."
        }
    }

    public static func text(_ missing: Missing) -> String {
        switch missing {
        case .shell(let shell):
            return "Sessions start in your login shell, \(shell) ($SHELL), and there's nothing at that path. Set a shell that's installed "
                + "(chsh -s /bin/zsh in Terminal), then quit and reopen VibeSwitcher."
        case .agent(let program, let shell):
            if program.contains("/") {
                return "VibeSwitcher starts it as \(program), and there's nothing at that path. \(install(program)), or set the Claude "
                    + "preset's Command in Settings to where it is, then try again."
            }
            return "VibeSwitcher starts it as “\(program)”, and your login shell (\((shell as NSString).lastPathComponent) -l) doesn't find "
                + "that command. \(install(program)), check that “\(program)” runs in a new Terminal window, then try again."
        case .commandLineTools:
            return "They aren't installed on this Mac (xcode-select -p names no developer folder). Run xcode-select --install in "
                + "Terminal, finish the installer, then try again."
        case .gitStub(let developer):
            return "/usr/bin/git is only Apple's stub: the developer folder xcode-select names, \(developer), has no git. Run "
                + "xcode-select --install in Terminal (or reinstall Xcode), then try again."
        case .gitFails(let said):
            let license = said.localizedCaseInsensitiveContains("license")
            return "git --version failed: \(said)" + (said.hasSuffix(".") ? "" : ".")
                + (license ? " Accept Xcode's license (sudo xcodebuild -license in Terminal), then try again."
                           : " Run git --version in Terminal to see why, then try again.")
        case .git(let path):
            return "VibeSwitcher runs git from \(path), and there's nothing there. Run xcode-select --install in Terminal, then try again."
        case .helper(let name, let path):
            return "\(name) should be at \(path), and isn't. Reinstall VibeSwitcher, then try again."
        }
    }

    /// A spawn that failed with `code` (posix_spawn's errno), said with the program and the path it was expected at:
    /// ENOENT is a missing program, or, when the program is there, the folder it was to start in.
    public static func couldntStart(_ program: String, in directory: String? = nil, code: Int32) -> String {
        let name = (program as NSString).lastPathComponent
        guard code == ENOENT else { return "Couldn't start \(program): \(String(cString: strerror(code)))." }
        if let directory, FileManager.default.fileExists(atPath: program) {
            return "Couldn't start \(name) in \(directory): that folder isn't there (No such file or directory)."
        }
        return "Couldn't start \(name): it should be at \(program), and isn't (No such file or directory)."
    }
}

/// The checks that passed, by what they looked at, and when.
private final class Passes: @unchecked Sendable {
    private let lock = NSLock()
    private var at: [String: Date] = [:]

    func passed(_ key: String, since: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return at[key].map { $0 >= since } ?? false
    }

    func pass(_ key: String, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        at[key] = date
    }
}
