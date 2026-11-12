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
        #expect(problem.text.contains("“claude”") && problem.text.contains("fakesh -l") && problem.text.contains("Install Claude Code"))
        // Codex by its name too.
        #expect(try #require(mac.preflight.check(command: "codex")).title == "Codex isn't installed.")
    }

    #if canImport(Darwin)
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
    #else
    /// Linux has no developer tools to ask after (`Platform.Tools.developerToolsApply`): an xcode-select that fails,
    /// or a developer folder with no git, isn't looked at, and git itself is run.
    @Test func linuxAsksAfterNoDeveloperToolsAndRunsGit() throws {
        let mac = try make(Mac(developer: nil, developerGit: false))
        #expect(mac.preflight.check(command: "claude") == nil)
        #expect(mac.runs("git") == 1)
    }
    #endif

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
        #if canImport(Darwin)
        let mac = try make(Mac(claude: false, developer: nil))
        let problem = try #require(mac.preflight.check(command: "claude"))
        #expect(problem.missing == [.agent(program: "claude", shell: mac.preflight.shell), .commandLineTools])
        #expect(problem.title == "2 things it needs are missing on this Mac.")
        #expect(problem.text.contains("Claude Code isn't installed.") && problem.text.contains("git needs Apple's Command Line Tools."))
        #else
        // Linux has no Command Line Tools to miss: its second missing piece is a git that doesn't run.
        let said = "git: error while loading shared libraries: libpcre2-8.so.0"
        let mac = try make(Mac(claude: false, gitVersion: said, gitStatus: 127))
        let problem = try #require(mac.preflight.check(command: "claude"))
        #expect(problem.missing == [.agent(program: "claude", shell: mac.preflight.shell), .gitFails(said)])
        #expect(problem.title == "2 things it needs are missing on this computer.")
        #expect(problem.text.contains("Claude Code isn't installed.") && problem.text.contains("git doesn't run."))
        #endif
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

    /// A program the shell expands or finds from its folder isn't called missing: the session's shell may well run it.
    @Test func aProgramTheShellExpandsIsntCalledMissing() throws {
        let mac = try make(Mac(claude: false))
        #expect(mac.preflight.check(command: "$HOME/.claude/local/claude --resume") == nil)
        #expect(mac.preflight.check(command: "${HOME}/.local/bin/claude") == nil)
        #expect(mac.preflight.check(command: "bin/claude") == nil)
        #expect(LaunchPreflight.program(in: "env -u FOO claude") == "claude")
        #expect(LaunchPreflight.program(in: "exec -a lead claude") == "claude")
        #expect(mac.preflight.check(command: "env -u FOO claude")?.missing == [.agent(program: "claude", shell: mac.preflight.shell)])
    }

    /// The login shell runs in a session of its own (no controlling terminal): an interactive zsh started from the tool
    /// server, which has the lead's terminal, would otherwise be stopped by SIGTTOU taking it, and read as not known.
    /// The fake shell says its pid and waits for the test to look at its session (until `go`, or its folder is gone).
    /// `resolve` blocks, so it runs on a thread of its own, not the shared pool a loaded full run can leave it no thread
    /// on. Whatever happens, `go` is made and the answer waited for (`resolve` ends the shell's group at its timeout),
    /// and a shell still there after that is killed with its group: a failed check leaves nothing looping.
    @Test func theLoginShellRunsInASessionOfItsOwn() async throws {
        let folder = scratch.url("own-session").path
        let (pidFile, go) = (folder + "/pid", folder + "/go")
        let shell = folder + "/fakesh"
        try script(shell, """
            echo $$ > '\(pidFile).tmp' && mv '\(pidFile).tmp' '\(pidFile)'
            while [ ! -e '\(go)' ] && [ -d '\(folder)' ]; do sleep 0.05; done
            shift 2
            exec /bin/sh "$@"
            """)
        // Ceilings, not waits: the pid file or the answer ends each. The shell is given longer than the look at it.
        let (lookBudget, shellBudget): (TimeInterval, TimeInterval) = (300, 330)
        let answer = Answer()
        Thread.detachNewThread { answer.give(LoginShellCommand.resolve("sh", shell: shell, timeout: shellBudget)) }
        var pid: Int32?
        defer {
            FileManager.default.createFile(atPath: go, contents: nil)
            if answer.wait(shellBudget + 10) == nil, let pid { kill(-pid, SIGKILL) }
        }
        // Until the pid file, or an answer without it (the shell couldn't start).
        let said = { (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        let deadline = Date().addingTimeInterval(lookBudget)
        while pid == nil, Date() < deadline {
            pid = said()
            if pid == nil, answer.wait(0) != nil { pid = said(); break }
            if pid == nil { await pause(0.02) }
        }
        let shellPid = try #require(pid, "no pid from the fake shell; resolve said \(String(describing: answer.wait(0)))")
        #expect(getsid(shellPid) == shellPid, "the login shell shares the caller's session (\(getsid(shellPid)), the caller's \(getsid(0)))")
        FileManager.default.createFile(atPath: go, contents: nil)
        #if canImport(Darwin)
        #expect(await offPool { answer.wait(shellBudget + 10) } == .found("/bin/sh"))
        #else
        // The first sh on PATH: Ubuntu's PATH has /usr/bin before /bin, and both hold it.
        #expect(await offPool { answer.wait(shellBudget + 10) } == .found(Platform.Tools.find("sh") ?? "/bin/sh"))
        #endif
    }

    /// `LoginShellCommand.resolve`'s answer, given once from its thread and waited for any number of times.
    final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private let given = DispatchSemaphore(value: 0)
        private var outcome: LoginShellCommand.Outcome?
        func give(_ outcome: LoginShellCommand.Outcome) {
            lock.lock(); self.outcome = outcome; lock.unlock()
            given.signal()
        }
        /// nil when there's none within `seconds`.
        func wait(_ seconds: TimeInterval) -> LoginShellCommand.Outcome? {
            guard given.wait(timeout: .now() + seconds) == .success else { return nil }
            given.signal()
            lock.lock(); defer { lock.unlock() }
            return outcome
        }
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

    /// A login shell whose `command -v` doesn't answer (here a `command` that only fails, with 127 as a shell without
    /// one does) says nothing of the program: not known, so never called missing, whatever sh the system has.
    @Test func aShellWhoseCommandLookupDoesntAnswerIsntTakenToSayMissing() throws {
        let folder = scratch.url("no-command").path
        let shell = folder + "/fakesh"
        // `-l -i -c COMMAND $0 NAME`: the command run by sh after a `command` function that fails as a missing one.
        try script(shell, """
            [ "$1" = -l ] && [ "$2" = -i ] && [ "$3" = -c ] || exit 64
            exec /bin/sh -c "command() { return 127; }; $4" "$5" "$6"
            """)
        #expect(LoginShellCommand.resolve("claude", shell: shell, timeout: Self.budget) == .unknown)
        #expect(LoginShellCommand.resolve("sh", shell: shell, timeout: Self.budget) == .unknown)
    }

    /// The messages name the machine and its terminal in this system's words: the Mac's own on the Mac; on Linux no
    /// Mac, no Terminal app and no xcode-select in what Linux can say (it has no Command Line Tools to miss).
    @Test func theMessagesSayThisSystemsWords() {
        let several = LaunchPreflight.Problem(missing: [.agent(program: "claude", shell: "/bin/zsh"), .git("/usr/bin/git")])
        #if canImport(Darwin)
        #expect(several.title == "2 things it needs are missing on this Mac.")
        #expect(LaunchPreflight.title(.git("/usr/bin/git")) == "git isn't on this Mac.")
        #expect(LaunchPreflight.text(.git("/usr/bin/git"))
                == "VibeSwitcher runs git from /usr/bin/git, and there's nothing there. Run xcode-select --install in Terminal, then try again.")
        #expect(LaunchPreflight.text(.shell("/bin/nosh")).contains("(chsh -s /bin/zsh in Terminal)"))
        #expect(LaunchPreflight.text(.agent(program: "claude", shell: "/bin/zsh")).contains("runs in a new Terminal window, then"))
        #expect(LaunchPreflight.text(.gitFails("it broke")).hasSuffix(" Run git --version in Terminal to see why, then try again."))
        #else
        #expect(several.title == "2 things it needs are missing on this computer.")
        #expect(LaunchPreflight.text(.git("/usr/bin/git"))
                == "VibeSwitcher runs git from /usr/bin/git, and there's nothing there. Install git with your system's package manager, then try again.")
        #expect(LaunchPreflight.text(.shell("/bin/nosh")).contains("(chsh -s /bin/bash in a terminal)"))
        let linuxCanSay: [LaunchPreflight.Missing] = [.shell("/bin/nosh"), .agent(program: "claude", shell: "/bin/bash"),
                                                       .gitFails("it broke"), .git("/usr/bin/git"), .helper(name: "vibeswitcher-mcp", path: "/x")]
        for missing in linuxCanSay {
            let said = LaunchPreflight.title(missing) + " " + LaunchPreflight.text(missing)
            #expect(!said.contains("Mac") && !said.contains("Terminal") && !said.contains("xcode-select"), "\(said)")
        }
        #endif
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
