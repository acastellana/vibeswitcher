import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// What Claude Code does on this system, measured with a real `claude` under a scratch host (the stage 2 plan's Task
/// 12b): which of the user's shell startup files its Bash tool's snapshot takes in, when the session itself starts as
/// Task 10a starts one (`bash --noprofile --norc -c`), and whether its timeout and its interrupt still end a verifier's
/// command that `BranchCode.runPrefix` started in a POSIX session of its own (Task 10c: a SIGKILL to the waiting prefix
/// can't be passed on). Gated as Task 12a is (`RealClaudeHostTests`): on demand only, with a throwaway Claude Code config
/// folder the user logged in once, named on the run's command line (the user's decision 16):
/// `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=<that folder> bash scripts/test.sh --filter RealClaudeTests`. Each test sends
/// one or two short prompts on sonnet (the snapshot's, once for each home in `homes`); bash's own rules behind the
/// snapshot's record are measured ungated, with bash alone. The results are recorded in
/// `docs/process/v2-linux-inventory.md`. The tests
/// assert that the measurement was made, and, for the verifier's command, that no process of it is left cut off from
/// Claude Code: its interrupt ends it; its timeout either ends it or leaves it whole in the background, prefix and all
/// (2.1.323 moves a command that hits its timeout to the background); and the session's `/exit` ends what is left.
///
/// Each session runs in manual permission mode (named, as every role's launch names one: 2.1.323 starts in auto mode
/// unless told) with the one command it is asked to run allowed by an inline `--settings` rule, so no permission
/// question is answered for it; one shown anyway for that command is answered "yes" (Enter), and the run says so.
@Suite(.serialized, hostTestLimit) struct RealClaudeTests {
    static let configFolder = RealClaudeHostTests.configFolder
    static let gate = "starts a real Claude Code and sends it a prompt: set VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR to a Claude Code config folder you logged in once to run it"

    /// The startup files whose sourcing is measured, by the name each one's marker uses.
    static let startupFiles: [(file: String, mark: String)] = [
        (".bashrc", "bashrc"), (".bash_profile", "bash_profile"), (".profile", "profile"), (".zshrc", "zshrc"),
    ]

    /// The homes the snapshot is measured in: one with every startup file (which of them a shell reads first), and one
    /// shaped like the node's, which has `.profile` and `.bashrc` only (a login bash reads the first of
    /// `.bash_profile`, `.bash_login` and `.profile` there is, so only a home without the first two shows `.profile`).
    static let homes: [String: [String]] = [
        "every startup file": startupFiles.map(\.file),
        "the node's, .profile and .bashrc only": [".profile", ".bashrc"],
    ]

    /// A startup file that marks being read four ways: an exported variable, a function and an alias (what a shell
    /// snapshot may carry), a folder of its own put first on `PATH` (`$HOME/vs-<mark>-bin`: which PATH a command
    /// gets), and a line in `$HOME/sourced.log` naming the shell that read it (what read it, and when), with what
    /// makes a bash read a startup file unasked: `BASH_ENV`, `SHLVL`, and its stdin a socket (bash's own rule, bash(1)'s
    /// INVOCATION: a non-interactive bash whose stdin is a network connection, as under rshd or sshd, and whose
    /// level is under 2 reads `~/.bashrc`; any socket counts; Debian's `SSH_SOURCE_BASHRC` only adds the
    /// `SSH_CLIENT` check).
    static func startupFile(_ mark: String) -> String {
        """
        export VS_MARK_\(mark.uppercased())=1
        export PATH="$HOME/vs-\(mark)-bin:$PATH"
        vs_mark_\(mark)() { :; }
        alias vs_alias_\(mark)=true
        printf '%s %s pid %s parent %s, BASH_ENV %s, SHLVL %s, stdin %s, $- %s: %.120s\\n' "$(date +%s.%N)" \(mark) "$$" "$PPID" "${BASH_ENV-unset}" "${SHLVL-unset}" "$(if [ -S /proc/$$/fd/0 ]; then echo a socket; elif [ -p /proc/$$/fd/0 ]; then echo a pipe; else readlink /proc/$$/fd/0; fi)" "$-" "$(tr '\\0\\n' '  ' < /proc/$$/cmdline)" >> "$HOME/sourced.log"

        """
    }

    /// Bash's own rules behind what the snapshot run records, measured with bash alone (no Claude Code, no gated
    /// run), in the shapes Claude Code 2.1.323 starts it in (`whatClaudesBashToolSourcesIsMeasured`): the snapshot's
    /// `/bin/bash -c -l <script>` and each command's `/bin/bash -c <command>`, stdin a socket, `SHLVL` unset, no
    /// `SSH_CLIENT`. A login bash reads the first of `.bash_profile`, `.bash_login` and `.profile` there is (so in the
    /// node's home, `.profile` and `.bashrc` only, it reads `.profile` and gets the PATH it sets), and a non-login
    /// bash reads `~/.bashrc` when its stdin is a socket, not when it is /dev/null. Linux's bash; the Mac's /bin/bash
    /// isn't measured here.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's bash; the Mac's isn't measured here"))
    func theStartupFilesBashReadsInClaudeCodesShapesAreMeasured() throws {
        let temp = Scratch()
        let root = temp.url("r12b-bash")
        let cases: [(name: String, files: [String], login: Bool, socket: Bool, read: [String])] = [
            ("the node's home, login", [".profile", ".bashrc"], true, true, ["profile"]),
            ("a .bash_login too, login", [".profile", ".bashrc", ".bash_login"], true, true, ["bash_login"]),
            ("a .bash_profile too, login", [".profile", ".bashrc", ".bash_login", ".bash_profile"], true, true, ["bash_profile"]),
            ("the node's home, a command, stdin a socket", [".profile", ".bashrc"], false, true, ["bashrc"]),
            ("the node's home, a command, stdin /dev/null", [".profile", ".bashrc"], false, false, []),
        ]
        for (index, shape) in cases.enumerated() {
            let home = root.appendingPathComponent("\(index)").path
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            for file in shape.files {
                let mark = String(file.dropFirst())
                try Self.startupFile(mark).write(toFile: home + "/" + file, atomically: true, encoding: .utf8)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = (shape.login ? ["-c", "-l"] : ["-c"]) + ["printf '%s' \"$PATH\""]
            process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var ends: (Int32, Int32)?
            if shape.socket {
                ends = try #require(Platform.Sockets.pair(type: Platform.Sockets.stream))
                process.standardInput = FileHandle(fileDescriptor: ends!.0, closeOnDealloc: false)
            } else {
                process.standardInput = FileHandle.nullDevice
            }
            try process.run()
            let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(waitForEnd(process, within: 30), "\(shape.name): bash didn't end")
            if let ends { close(ends.0); close(ends.1) }
            let log = (try? String(contentsOfFile: home + "/sourced.log", encoding: .utf8)) ?? ""
            let read = log.split(separator: "\n").map { String($0.split(separator: " ")[1]) }
            print("R12b bash: \(shape.name): read \(read.isEmpty ? "nothing" : read.joined(separator: ", ")); PATH=\(path)")
            #expect(read == shape.read, "\(shape.name): \(log)")
            let first = shape.read.first.map { home + "/vs-\($0)-bin:" }
            #expect(first.map { path.hasPrefix($0) } ?? !path.contains("/vs-"), "\(shape.name): PATH=\(path)")
        }
    }

    @Test(.enabled(if: configFolder != nil, Comment(rawValue: gate)), arguments: homes.keys.sorted())
    func whatClaudesBashToolSourcesIsMeasured(home: String) async throws {
        let run = try await Run(name: "R12b snapshot, \(home) home")
        defer { run.end() }
        let files = try #require(Self.homes[home])
        for (file, mark) in Self.startupFiles where files.contains(file) {
            try Self.startupFile(mark).write(toFile: run.host.home + "/" + file, atomically: true, encoding: .utf8)
        }
        // What the Bash tool's command sees: its environment's markers, its PATH, its shell, and the shell that ran it.
        let markers = run.project + "/markers.txt"
        let script = """
            #!/bin/bash
            {
              echo "SHELL=$SHELL"
              echo "PATH=$PATH"
              echo "parent: $(tr '\\0\\n' '  ' < /proc/$PPID/cmdline | cut -c1-300)"
              echo "BASH_ENV=${BASH_ENV-unset} SHLVL=${SHLVL-unset}"
              env | grep '^VS_MARK_' | sort
              echo end
            } > \(RecentProjects.shellQuote(markers)).partial
            mv \(RecentProjects.shellQuote(markers)).partial \(RecentProjects.shellQuote(markers))

            """
        _ = FileManager.default.createFile(atPath: run.project + "/markers.sh", contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        let snapshots = run.config.appendingPathComponent("shell-snapshots").path
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: snapshots)) ?? [])

        let session = try await run.start(allowing: "./markers.sh",
                                          prompt: "Use your Bash tool to run exactly this command: ./markers.sh. Then answer with the one word: finished.")
        let wrote = await run.eventuallyAnswering(timeout: 180, "./markers.sh") { FileManager.default.fileExists(atPath: markers) }
        if !wrote { run.diagnose(session) }
        try #require(wrote, "the command never ran")

        // The record: what read each file, what the snapshot holds of each, and what reached the command.
        let sourced = (try? String(contentsOfFile: run.host.home + "/sourced.log", encoding: .utf8)) ?? ""
        let made = ((try? FileManager.default.contentsOfDirectory(atPath: snapshots)) ?? []).filter { !before.contains($0) }.sorted()
        let seen = try String(contentsOfFile: markers, encoding: .utf8)
        run.say("\(run.claude) in a session started as \(Platform.Tools.sessionShellArguments(shell: "/bin/bash", command: "…", keepShell: false).joined(separator: " ")), SHELL=/bin/bash, HOME a scratch home")
        run.say("startup files read, in order:\n" + (sourced.isEmpty ? "none" : sourced))
        for name in made {
            let text = (try? String(contentsOfFile: snapshots + "/" + name, encoding: .utf8)) ?? ""
            let held = Self.startupFiles.map { mark in
                let kinds = [("variable", "VS_MARK_\(mark.mark.uppercased())"), ("function", "vs_mark_\(mark.mark)"), ("alias", "vs_alias_\(mark.mark)")]
                    .filter { text.contains($0.1) }.map(\.0)
                return "\(mark.file): \(kinds.isEmpty ? "nothing" : kinds.joined(separator: ", "))"
            }
            let path = text.split(separator: "\n").filter { $0.hasPrefix("export PATH=") }.joined(separator: " | ")
            run.say("snapshot \(name) (\(text.utf8.count) bytes): \(held.joined(separator: "; ")); its \(path.isEmpty ? "PATH: none" : path)")
        }
        if made.isEmpty { run.say("no new snapshot in \(snapshots)") }
        run.say("what the command saw:\n" + seen)
        #expect(seen.hasSuffix("end\n"), "\(seen)")
        await run.exit(session)
    }

    @Test(.enabled(if: configFolder != nil, Comment(rawValue: gate)))
    func aVerifierCommandInItsOwnSessionStillTimesOut() async throws {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        try #require(BranchCode.prefixable(mcp), "\(mcp) can't be a shell prefix")
        let run = try await Run(name: "R12b verifier")
        // The POSIX sessions the commands' processes were seen in: the defer kills what is left of them there and
        // under Claude Code, and nothing else on the machine.
        var sessions: Set<pid_t> = []
        defer {
            for seconds in ["611", "622"] {
                for pid in Self.tree(of: seconds, prefix: mcp, root: run.sessionPID, sessions: sessions).map(\.pid) { kill(pid, SIGKILL) }
            }
            run.end()
        }

        // The command: a script that sleeps (2.1.323's Bash tool refuses a standalone `sleep` of that length, and a
        // script is what a verifier's long commands are: a branch's tests).
        _ = FileManager.default.createFile(atPath: run.project + "/hold.sh", contents: Data("#!/bin/bash\nsleep \"$1\"\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        // A verifier's environment, as its launch gives it in its inline settings: every Bash command through the tool
        // server's binary as Claude Code's shell prefix (`BranchCode.runPrefix`).
        let session = try await run.start(allowing: ["./hold.sh 611", "./hold.sh 622"], env: LeadLaunch.verifierEnvironment(server: mcp),
                                          prompt: "Use your Bash tool to run exactly this command: ./hold.sh 611. Set the Bash tool's timeout parameter to 5000 milliseconds, and don't run it in the background. Once the tool returns, answer with the one word: finished.")

        // 1. Its timeout. 2.1.323 doesn't end a command at its timeout: it moves it to the background, where it runs on
        // as one of the session's shells (its screen: "moved to the background", "now running in the background"). What
        // must not happen is the tree cut in two: the prefix ended and the command, in a session of its own, left
        // running.
        let timeout = try await Self.started("611", prefix: mcp, run: run, session: session)
        sessions.formUnion(timeout.sessions)
        let timedOut = await Self.ended("611", prefix: mcp, run: run, session: session, since: timeout, within: 30)
        let flat = (run.screen(session) ?? "").filter { $0.isLetter }.lowercased()
        run.say("at its timeout the command was \(timedOut.ended ? "ended" : flat.contains("background") ? "moved to the background" : "left running")")
        #expect(timedOut.ended || timedOut.left.contains { $0.role == "prefix" },
                "the command outlived its prefix at the Bash tool's timeout: \(timedOut.record)")

        // 2. Its interrupt: Escape while the command runs, with the tool's longest timeout.
        _ = await eventually(timeout: 60) { RealClaudeHostTests.promptShows(run.screen(session)) }
        let asked = run.client.send(.inputUnit(id: session.id, writes: HostInput.writes(
            text: "Use your Bash tool to run exactly this command: ./hold.sh 622. Set the Bash tool's timeout parameter to 600000 milliseconds, and don't run it in the background.",
            submit: true, key: nil), more: false))
        #expect(await eventually { run.client.reply(to: asked) != nil })
        let interrupt = try await Self.started("622", prefix: mcp, run: run, session: session)
        sessions.formUnion(interrupt.sessions)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        run.say(String(format: "interrupting (Escape) at %.1f s", MacTime.real.awake() - interrupt.at))
        let typed = run.client.send(.inputUnit(id: session.id, writes: HostInput.writes(text: nil, submit: false, key: "escape"), more: false))
        #expect(await eventually { run.client.reply(to: typed) != nil })
        let interrupted = await Self.ended("622", prefix: mcp, run: run, session: session, since: interrupt, within: 60)
        #expect(interrupted.ended, "the command outlived its interrupt: \(interrupted.record)")

        // 3. The session's end (`/exit`): a command still in the background then is ended with it, no process of it left.
        guard !timedOut.ended else { await run.exit(session); return }
        let exiting = MacTime.real.awake()
        await run.exit(session)
        run.say(String(format: "the session %@ %.1f s after /exit", kill(session.childPID, 0) == 0 ? "still ran" : "ended", MacTime.real.awake() - exiting))
        let afterExit = await Self.ended("611", prefix: mcp, run: run, session: session, since: timeout, within: 30)
        #expect(afterExit.ended, "the backgrounded command outlived its session: \(afterExit.record)")
    }

    /// One of a command's processes: the prefix (`vibeswitcher-mcp '<line>'`), the branch-code wrapper, the shells
    /// under it, the script, or its `sleep`.
    struct Member: Equatable {
        var pid: pid_t
        var role: String
        var session: pid_t
    }

    /// The processes of the Bash tool's command `./hold.sh <seconds>`, among this run's only: Claude Code's
    /// descendants (`root`, Claude Code itself, holds the command in its prompt and isn't one), and the processes of
    /// `sessions`, the POSIX sessions the command's processes were seen in (one cut off from Claude Code is no longer
    /// its descendant, but keeps its session). A process elsewhere on the machine whose arguments match isn't one.
    static func tree(of seconds: String, prefix: String, root: pid_t, sessions: Set<pid_t>) -> [Member] {
        let command = "./hold.sh \(seconds)"
        let all = Platform.Processes.allPids() ?? []
        var parents: [pid_t: [pid_t]] = [:]
        for pid in all { if case .brief(let brief) = Platform.Processes.brief(pid) { parents[brief.ppid, default: []].append(pid) } }
        var candidates = Set<pid_t>()
        var next = parents[root] ?? []
        while let pid = next.popLast() { if candidates.insert(pid).inserted { next += parents[pid] ?? [] } }
        let scoped = sessions.filter { $0 > 0 }
        if !scoped.isEmpty { for pid in all where scoped.contains(getsid(pid)) { candidates.insert(pid) } }
        return candidates.sorted().compactMap { pid -> Member? in
            guard pid != root, pid != getpid() else { return nil }
            let arguments = Platform.Processes.arguments(pid)
            guard let first = arguments.first else { return nil }
            let role: String
            if arguments.count == 2, first == "sleep" || first.hasSuffix("/sleep"), arguments[1] == seconds {
                role = "sleep"
            } else if arguments.suffix(2) == ["./hold.sh", seconds] {
                role = "script"
            } else if !arguments.contains(where: { $0.contains(command) }) {
                return nil
            } else if BranchCode.sameFile(first, prefix) {
                role = "prefix"
            } else if BranchCode.isRunner(arguments) {
                role = "wrapper"
            } else {
                role = "shell (\(URL(fileURLWithPath: first).lastPathComponent))"
            }
            return Member(pid: pid, role: role, session: getsid(pid))
        }
    }

    /// What one measurement found: whether every process of the command ended, and what happened when.
    struct Measured {
        var ended: Bool
        var left: [Member]
        var record: String
    }

    /// A command's processes once its `sleep` runs, and when that was seen.
    struct Start {
        var members: [Member]
        var at: TimeInterval
        /// The POSIX sessions its processes were in (the prefix's and the wrapper's).
        var sessions: Set<pid_t> { Set(members.map(\.session).filter { $0 > 0 }) }
    }

    /// Waits for `./hold.sh <seconds>` to start (its `sleep` running), and says what it is made of.
    static func started(_ seconds: String, prefix: String, run: Run, session: HostSession) async throws -> Start {
        let command = "./hold.sh \(seconds)"
        var members: [Member] = []
        let started = await run.eventuallyAnswering(timeout: 180, command) {
            members = tree(of: seconds, prefix: prefix, root: run.sessionPID, sessions: [])
            return members.contains { $0.role == "sleep" }
        }
        if !started { run.diagnose(session) }
        try #require(started, "\(command) never started")
        run.say("\(command) started; Claude Code's session \(getsid(run.sessionPID)); its processes: "
                + members.map { "\($0.role) \($0.pid) in session \($0.session)" }.joined(separator: ", "))
        return Start(members: members, at: MacTime.real.awake())
    }

    /// Waits up to `within` for every process of `./hold.sh <seconds>` to end, looking as often as `eventually` does,
    /// and says when each went (from its start) and what is left.
    static func ended(_ seconds: String, prefix: String, run: Run, session: HostSession, since start: Start,
                      within: TimeInterval) async -> Measured {
        let command = "./hold.sh \(seconds)"
        let from = MacTime.real.awake()
        var known = start.members
        var sessions = start.sessions
        var gone: [String] = []
        let ended = await eventually(timeout: within) {
            let now = tree(of: seconds, prefix: prefix, root: run.sessionPID, sessions: sessions)
            for member in now where !known.contains(where: { $0.pid == member.pid }) {
                known.append(member)
                if member.session > 0 { sessions.insert(member.session) }
            }
            for member in known where !now.contains(where: { $0.pid == member.pid }) && !gone.contains(where: { $0.hasPrefix("\(member.role) \(member.pid) ") }) {
                gone.append(String(format: "%@ %d ended at %.1f s", member.role, member.pid, MacTime.real.awake() - start.at))
            }
            return now.isEmpty
        }
        let left = tree(of: seconds, prefix: prefix, root: run.sessionPID, sessions: sessions)
        let record = "from its start: " + (gone.isEmpty ? "none ended" : gone.joined(separator: ", "))
            + (left.isEmpty ? "" : String(format: "; still running %.1f s later: ", MacTime.real.awake() - from)
               + left.map { "\($0.role) \($0.pid) in session \($0.session)" }.joined(separator: ", "))
        run.say("\(command): \(ended ? "ended" : "NOT ended") \(record)")
        run.say("the screen:\n" + RealClaudeHostTests.rows(run.screen(session)).filter { !$0.isEmpty }.joined(separator: "\n"))
        return Measured(ended: ended, left: left, record: record)
    }

    /// A real `claude` session under a scratch host, in a scratch repository trusted in the config folder (its entry
    /// taken out again by `end`), on a client of the test's own.
    final class Run {
        let name: String
        let config: URL
        let claude: String
        let host: ScratchHostProcess
        let project: String
        let client: TestClient
        private(set) var sessionPID: pid_t = 0
        private var spawned: HostSession?
        private var trusted = false

        init(name: String) async throws {
            self.name = name
            config = URL(fileURLWithPath: try #require(RealClaudeTests.configFolder))
            try #require(FileManager.default.fileExists(atPath: config.appendingPathComponent(".claude.json").path),
                         "\(config.path) has no .claude.json: log in there once first")
            claude = try #require(RealClaudeHostTests.claudeExecutable(), "no claude on PATH")
            // The user's shell is bash here, as the node's unit gives it from the account (the scratch host's own
            // default is /bin/sh).
            host = try await ScratchHostProcess(environment: ["SHELL": "/bin/bash"])
            project = URL(fileURLWithPath: host.dir + "/project").path
            try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
            for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: project) }
            client = try await TestClient.welcomed(host.socket, appKey: host.appKey).0
            say("\(claude) --version: \(RealClaudeHostTests.version(of: claude, home: host.home, config: config))")
        }

        var resolvedProject: String { URL(fileURLWithPath: project).resolvingSymlinksInPath().path }

        func say(_ line: String) { print("\(name): \(line)") }

        func screen(_ session: HostSession) -> String? { client.screen(session.id) }

        /// What a failed wait leaves to read: the screen, the session's processes and the host's log, printed (a test
        /// issue's comment doesn't carry a screen's lines).
        func diagnose(_ session: HostSession) {
            say("the screen:\n" + RealClaudeHostTests.rows(screen(session)).filter { !$0.isEmpty }.joined(separator: "\n"))
            var lines: [String] = []
            var next: [(pid_t, Int)] = [(session.childPID, 0)]
            while let (pid, depth) = next.popLast() {
                let arguments = Platform.Processes.arguments(pid).joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
                lines.append(String(repeating: "  ", count: depth) + "\(pid) (session \(getsid(pid))): " + String(arguments.prefix(240)))
                next += Platform.Processes.children(pid).map { ($0, depth + 1) }
            }
            say("the session's processes:\n" + lines.joined(separator: "\n"))
            say("the host's log:\n" + String(host.log.suffix(3000)))
        }

        /// Starts `claude --model sonnet --permission-mode manual` with `prompt`, its inline settings allowing exactly
        /// `allowing` and setting `env`.
        func start(allowing: [String], env: [String: String] = [:], prompt: String) async throws -> HostSession {
            try RealClaudeHostTests.trust(resolvedProject, in: config, true)
            trusted = true
            let settings: [String: Any] = ["permissions": ["allow": allowing.map { "Bash(\($0))" }], "env": env]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), as: UTF8.self)
            let quote = RecentProjects.shellQuote
            let command = "exec \(quote(claude)) --model sonnet --permission-mode manual --settings \(quote(json)) \(quote(prompt))"
            let seq = client.send(.spawn(SpawnRequest(cwd: resolvedProject, command: command,
                                                      env: ["CLAUDE_CONFIG_DIR": config.path, "DISABLE_AUTOUPDATER": "1",
                                                            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"],
                                                      cols: 120, rows: 40, keepShell: false, label: "Claude", agent: "claude")))
            #expect(await eventually { client.reply(to: seq) != nil })
            guard case .spawned(let session)? = client.reply(to: seq) else {
                throw TestClient.NoWelcome(description: "no session: \(String(describing: client.reply(to: seq))); \(host.log)")
            }
            spawned = session
            sessionPID = session.childPID
            say("the session's terminal: \(session.tty)")
            return session
        }

        func start(allowing: String, prompt: String) async throws -> HostSession {
            try await start(allowing: [allowing], prompt: prompt)
        }

        /// Waits for `condition`, answering "yes" (Enter) to a permission question that names `command` meanwhile
        /// (its allow rule should have spared it); says so when it does.
        func eventuallyAnswering(timeout: TimeInterval, _ command: String, _ condition: @escaping () -> Bool) async -> Bool {
            var answered = 0.0
            return await eventually(timeout: timeout) { [self] in
                if condition() { return true }
                guard let session = spawned, let screen = screen(session), case .dialog = LeadDelivery.box(in: screen),
                      screen.contains(command), MacTime.real.awake() - answered > 5 else { return false }
                answered = MacTime.real.awake()
                say("a question named \(command) despite its allow rule: answered yes:\n\(screen)")
                _ = client.send(.inputUnit(id: session.id, writes: HostInput.writes(text: nil, submit: false, key: "enter"), more: false))
                return false
            }
        }

        /// `/exit`, then its end waited for (killed by `end` otherwise).
        /// A question it asks first (a shell still running in the background) is answered with Enter, once, and said.
        func exit(_ session: HostSession) async {
            _ = client.send(.inputUnit(id: session.id, writes: HostInput.writes(text: "/exit", submit: true, key: nil), more: false))
            if await eventually(timeout: 5, { kill(session.childPID, 0) != 0 }) { return }
            if let screen = screen(session), case .dialog = LeadDelivery.box(in: screen) {
                say("/exit asked first; answered with Enter:\n" + RealClaudeHostTests.rows(screen).filter { !$0.isEmpty }.joined(separator: "\n"))
                _ = client.send(.inputUnit(id: session.id, writes: HostInput.writes(text: nil, submit: false, key: "enter"), more: false))
            }
            if !(await eventually(timeout: 25) { kill(session.childPID, 0) != 0 }) { diagnose(session) }
        }

        /// The session killed if it still runs, the host stopped, the trust entry taken out.
        func end() {
            if let session = spawned, kill(session.childPID, 0) == 0 {
                kill(-session.childPID, SIGKILL)
                _ = eventuallyBlocking(timeout: 15) { kill(session.childPID, 0) != 0 }
            }
            client.close()
            host.stop()
            if trusted {
                do { try RealClaudeHostTests.trust(resolvedProject, in: config, false) } catch { Issue.record("the trust entry stayed: \(error)") }
                trusted = false
            }
        }
    }
}
