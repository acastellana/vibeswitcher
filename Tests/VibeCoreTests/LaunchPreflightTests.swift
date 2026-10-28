import Foundation
import Testing
@testable import VibeCore

/// The look before a lead or a worker starts (`LaunchPreflight`), in an injected environment: a fake login shell whose
/// PATH is a scratch folder (with or without `claude`), a fake `xcode-select` and a fake /usr/bin/git, each a script in
/// a scratch folder. Never the user's shell, git or Command Line Tools; nothing is installed.
struct LaunchPreflightTests {
    /// A ceiling for the fake shell's answer, not a wait: its exit ends the read.
    static let budget: TimeInterval = 120
    let scratch = Scratch()

    /// One Mac: which pieces are there.
    struct Mac {
        var claude = true
        /// nil: `xcode-select -p` fails, as with no Command Line Tools.
        var developer: Bool? = true
        /// The developer folder has its git (false: /usr/bin/git is only the stub).
        var developerGit = true
        /// What `git --version` prints and exits with.
        var gitVersion = "git version 2.50.1 (Apple Git-155)"
        var gitStatus = 0
    }

    struct Made {
        var preflight: LaunchPreflight
        /// Each run of the shell and of git, one line each.
        var log: String
        func runs(_ name: String) -> Int {
            ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == name }.count
        }
    }

    func script(_ path: String, _ body: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    func make(_ mac: Mac, name: String = "mac", clock: @escaping @Sendable () -> Date = { Date() }) throws -> Made {
        let folder = scratch.url(name).path
        let bin = folder + "/bin", log = folder + "/runs.log"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        if mac.claude { try script(bin + "/claude", "echo claude") }
        // The session's `-l -i -c COMMAND $0 NAME`, run by sh with PATH only the scratch bin (and sh's own builtins).
        let shell = folder + "/fakesh"
        try script(shell, """
            [ "$1" = -l ] && [ "$2" = -i ] && [ "$3" = -c ] || exit 64
            echo shell >> '\(log)'
            shift 2
            PATH='\(bin)'; export PATH
            echo 'Welcome back!'
            exec /bin/sh "$@"
            """)
        let developer = folder + "/CommandLineTools"
        if mac.developerGit { try script(developer + "/usr/bin/git", "exit 0") }
        let xcodeSelect = folder + "/xcode-select"
        try script(xcodeSelect, mac.developer == nil
            ? "echo 'xcode-select: error: unable to get active developer directory' >&2; exit 2"
            : "[ \"$1\" = -p ] || exit 64; echo '\(developer)'")
        let git = folder + "/git"
        try script(git, "echo git >> '\(log)'; echo '\(mac.gitVersion)'; exit \(mac.gitStatus)")
        return Made(preflight: LaunchPreflight(shell: shell, xcodeSelect: xcodeSelect, git: git, timeout: Self.budget, keep: 60, now: clock),
                    log: log)
    }

    @Test func aMacWithEverythingPasses() throws {
        let mac = try make(Mac())
        #expect(mac.preflight.check(command: "claude --dangerously-skip-permissions") == nil)
        #expect(mac.runs("shell") == 1 && mac.runs("git") == 1)
    }

    @Test func aPathWithoutClaudeSaysClaudeCodeIsntInstalled() throws {
        let mac = try make(Mac(claude: false))
        let problem = try #require(mac.preflight.check(command: "claude --model opus"))
        #expect(problem.missing == [.agent(program: "claude", shell: mac.preflight.shell)])
        #expect(problem.title == "Claude Code isn't installed.")
        #expect(problem.text.contains("`claude`") && problem.text.contains("fakesh -l") && problem.text.contains("Install Claude Code"))
        // Codex by its name too.
        #expect(try #require(mac.preflight.check(command: "codex")).title == "Codex isn't installed.")
    }

    @Test func xcodeSelectFailingSaysToInstallTheCommandLineTools() throws {
        let mac = try make(Mac(developer: nil))
        let problem = try #require(mac.preflight.check(command: "claude"))
        #expect(problem.missing == [.commandLineTools])
        #expect(problem.title == "git needs Apple's Command Line Tools.")
        #expect(problem.text.contains("Run xcode-select --install in Terminal"))
        // The stub isn't run: without the tools it offers to install them.
        #expect(mac.runs("git") == 0)
    }

    @Test func aGitThatsTheStubSaysSo() throws {
        let mac = try make(Mac(developerGit: false))
        let problem = try #require(mac.preflight.check(command: "claude"))
        guard case .gitStub(let developer) = problem.missing.first else { Issue.record("\(problem)"); return }
        #expect(developer.hasSuffix("/CommandLineTools"))
        #expect(problem.missing.count == 1)
        #expect(problem.text.contains("only Apple's stub") && problem.text.contains("xcode-select --install"))
        #expect(mac.runs("git") == 0)
    }

    @Test func aGitThatDoesntRunSaysWhatItSaid() throws {
        let mac = try make(Mac(gitVersion: "You have not agreed to the Xcode license agreements.", gitStatus: 69))
        let problem = try #require(mac.preflight.check(command: "claude"))
        #expect(problem.missing == [.gitFails("You have not agreed to the Xcode license agreements.")])
        #expect(problem.title == "git doesn't run.")
        #expect(problem.text.contains("sudo xcodebuild -license"))
    }

    @Test func aMissingHelperOrShellOrAgentPathIsNamedWithItsPath() throws {
        let mac = try make(Mac())
        let helper = scratch.url("App.app").path + "/Contents/MacOS/vibeswitcher-mcp"
        let problem = try #require(mac.preflight.check(command: "claude", helpers: [helper]))
        #expect(problem.missing == [.helper(name: "vibeswitcher-mcp", path: helper)])
        #expect(problem.text.contains(helper))

        var noShell = mac.preflight
        noShell.shell = scratch.url("no-such-shell").path
        #expect(noShell.check(command: "claude")?.missing == [.shell(noShell.shell)])

        let path = scratch.url("bin").path + "/claude"
        let agent = try #require(mac.preflight.check(command: "'\(path)' --resume"))
        #expect(agent.missing == [.agent(program: path, shell: mac.preflight.shell)])
        #expect(agent.text.contains("VibeSwitcher starts it as \(path), and there's nothing at that path."))
    }

    @Test func severalMissingAreEachSaid() throws {
        let mac = try make(Mac(claude: false, developer: nil))
        let problem = try #require(mac.preflight.check(command: "claude"))
        #expect(problem.missing == [.agent(program: "claude", shell: mac.preflight.shell), .commandLineTools])
        #expect(problem.title == "2 things it needs are missing on this Mac.")
        #expect(problem.text.contains("Claude Code isn't installed.") && problem.text.contains("git needs Apple's Command Line Tools."))
    }

    /// A pass is kept for `keep` seconds: a start asked for again meanwhile starts no shell. A miss isn't kept: once
    /// it's installed, the next start passes.
    @Test func aPassIsKeptBrieflyAndAMissIsnt() throws {
        let clock = Clock()
        let mac = try make(Mac(), clock: { clock.now })
        #expect(mac.preflight.check(command: "claude") == nil)
        #expect(mac.preflight.check(command: "claude") == nil)
        #expect(mac.runs("shell") == 1)
        clock.advance(61)
        #expect(mac.preflight.check(command: "claude") == nil)
        #expect(mac.runs("shell") == 2)

        let missing = try make(Mac(claude: false), name: "missing", clock: { clock.now })
        #expect(missing.preflight.check(command: "claude") != nil)
        #expect(missing.preflight.check(command: "claude") != nil)
        #expect(missing.runs("shell") == 2)
    }

    @Test func theProgramIsTheCommandsFirstWord() {
        #expect(LaunchPreflight.program(in: "claude --dangerously-skip-permissions") == "claude")
        #expect(LaunchPreflight.program(in: "FOO=1 BAR='a b' claude") == "claude")
        #expect(LaunchPreflight.program(in: "exec /bin/sleep 600 #") == "/bin/sleep")
        #expect(LaunchPreflight.program(in: "env -i PATH=/bin codex") == "codex")
        #expect(LaunchPreflight.program(in: "'/Users/a b/.local/bin/claude' -c") == "/Users/a b/.local/bin/claude")
        #expect(LaunchPreflight.program(in: "  ") == nil)
    }

    @Test func theLoginShellsAnswerIsRead() {
        let marker = LoginShellCommand.marker
        #expect(LoginShellCommand.outcome(status: 0, output: "banner\(marker)/opt/homebrew/bin/claude\n") == .found("/opt/homebrew/bin/claude"))
        #expect(LoginShellCommand.outcome(status: 0, output: "\(marker)alias claude='claude --x'\n") == .found("alias claude='claude --x'"))
        #expect(LoginShellCommand.outcome(status: 1, output: "\(marker)") == .missing)
        // A shell with no `command -v`, or one whose startup files exit first: not known, so not called missing.
        #expect(LoginShellCommand.outcome(status: 127, output: "\(marker)") == .unknown)
        #expect(LoginShellCommand.outcome(status: 3, output: "bye") == .unknown)
        #expect(!LoginShellCommand.validName("claude; rm") && !LoginShellCommand.validName("-v") && LoginShellCommand.validName("claude"))
    }

    /// ENOENT from a spawn names the program and where it was expected (or the folder, when the program is there).
    @Test func aSpawnsENOENTNamesTheProgramAndItsPath() {
        let missing = scratch.url("no-such-bin").path + "/vibeswitcher-mcp"
        let run = Shell.run(executable: missing, args: [], in: "/")
        #expect(run.status == -1)
        #expect(run.error == "Couldn't start vibeswitcher-mcp: it should be at \(missing), and isn't (No such file or directory).")
        let folder = scratch.url("no-such-folder").path
        #expect(Shell.run(executable: "/bin/echo", args: [], in: folder).error
                == "Couldn't start echo in \(folder): that folder isn't there (No such file or directory).")
        #expect(LaunchPreflight.couldntStart("/bin/x", code: EACCES) == "Couldn't start /bin/x: Permission denied.")
    }

    /// The host's socket not there, said in words (it was `system("connect", 2)` in the lead's start alert).
    @Test func aSocketThatIsntThereIsSaidInWords() {
        #expect("\(UnixSocket.Failure.system("connect", ENOENT))".contains("the session host (vibeswitcher-host) isn't running"))
        #expect("\(UnixSocket.Failure.system("bind", EACCES))" == "bind: Permission denied")
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
    }
}
