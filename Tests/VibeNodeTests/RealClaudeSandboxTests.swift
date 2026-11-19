import Foundation
import Testing
import VibeCore
import VibePlatform

/// A real Claude Code turn in the session sandbox's prototype box (`prototype.sh`, the session sandbox plan's SB0
/// Step 3), to measure what the shim's box must give it: which entries of its config folder it writes, whether it
/// rewrites its login, which hosts it asks for, whether its terminal UI minds a terminal with no name, whether a seeded
/// trust entry spares the trust question, and which hook events it sends. Each is printed as a line starting "SB0:",
/// for the inventory's "The session sandbox, measured".
///
/// On demand only: it spends a prompt of the account's usage, on Sonnet, and needs a Claude Code config folder the user
/// logged in once (an agent never logs in, and never reads or copies `.credentials.json`), named on the run's command
/// line: `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=<that folder> bash scripts/test.sh --filter RealClaudeSandboxTests`.
///
/// That folder is never the box's config folder. The box's is a scratch one (`HOME/.claude`), seeded with a
/// `.claude.json` made from the given one's by `ClaudeFiles.seededConfig` (its allow-list, then this worktree's trust
/// entry), with the given folder's read-only entries bound into it
/// read-only, the login among them: the kernel binds the file, nothing here reads it. So the run adds nothing to the
/// given folder; the test lists its entries (`lstat` only) before and after, and removes any entry that appeared.
struct RealClaudeSandboxTests {
    private let scratch = Scratch()

    static let configFolder = ProcessInfo.processInfo.environment["VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR"]

    static let prompt = "Use your Bash tool to run exactly this command: touch made-in-the-box. Then answer with the one word: finished."

    /// The hook events, recorded inside the box: a stand-in for the door, which SB4 builds.
    static let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification"]

    @Test(.enabled(if: configFolder != nil && PrototypeBox.unavailable == nil,
                   "spends Claude usage: set VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR to a Claude Code config folder you logged in once to run it"))
    func aRealClaudeTurnRunsInThePrototype() async throws {
        let config = URL(fileURLWithPath: try #require(Self.configFolder)).resolvingSymlinksInPath()
        let account = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) })
        try #require(config.path != "\(account)/.claude", "never the account's own config folder")
        let claudeLink = try #require(RealClaudeStatusTests.claudeExecutable(), "no claude on PATH")
        let claude = URL(fileURLWithPath: claudeLink).resolvingSymlinksInPath().path

        let folder = try scratch.shortFolder("sb0")
        let home = folder.appendingPathComponent("home"), worktree = folder.appendingPathComponent("worktree")
        for made in [home.appendingPathComponent(".claude"), worktree] {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        }
        _ = try await scratchGit(worktree.path, ["init", "-q", "-b", "main"])
        let worktreePath = worktree.resolvingSymlinksInPath().path

        // The seeded config, and the given folder as it was.
        let given = try Data(contentsOf: config.appendingPathComponent(".claude.json"))
        try ClaudeFiles.seededConfig(from: given, cwd: worktreePath, login: true).write(to: home.appendingPathComponent(".claude/.claude.json"))
        let before = Self.entries(of: config)
        defer { Self.removeWhatAppeared(in: config, since: before) }

        // The stand-in proxy, logging each host asked for.
        let proxyLog = folder.appendingPathComponent("proxy.log"), portFile = folder.appendingPathComponent("proxy.port")
        var proxy = Platform.Spawn(executable: "/usr/bin/python3",
                                   arguments: ["python3", "-I", packageFolder.appendingPathComponent("Tests/Fixtures/sandbox/logging-proxy.py").path,
                                               portFile.path, proxyLog.path])
        proxy.stdin = .path("/dev/null", flags: O_RDONLY)
        proxy.stdout = .path("/dev/null", flags: O_WRONLY)
        let proxyPid = try proxy.start().get()
        defer {
            Sys.kill(proxyPid, SIGKILL)
            _ = collected(proxyPid, by: MacTime.real.awake() + 10)
        }
        try #require(await eventually(timeout: 30) { FileManager.default.fileExists(atPath: portFile.path) }, "the proxy never listened")
        let port = try String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        // Hooks given on the command line, each appending its event to a file of the box's home.
        let eventsFile = home.appendingPathComponent("hook-events.jsonl").path
        let hook = ["type": "command", "command": "/bin/sh -c 'cat >> \"$HOME/hook-events.jsonl\"; echo >> \"$HOME/hook-events.jsonl\"'"]
        let settings: [String: Any] = ["hooks": Dictionary(uniqueKeysWithValues: Self.hookEvents.map { ($0, [["hooks": [hook]]]) })]
        let settingsText = String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), as: UTF8.self)

        let proxyURL = "http://127.0.0.1:\(port)"
        let options = ["--ro", claude]
            + ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"].flatMap { ["--env", "\($0)=\(proxyURL)"] }
            + ["--env", "DISABLE_AUTOUPDATER=1", "--env", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"]
        let program = [claude, "--model", "sonnet", "--debug", "--allowedTools", "Bash(touch made-in-the-box)",
                       "--settings", settingsText, Self.prompt]
        let boxCommand = ([PrototypeBox.script.path, home.path, worktree.path, config.path] + options + ["--"] + program)
            .map(Self.quoted).joined(separator: " ")
        let session = try BoxTerminal(command: "stty rows 40 cols 120; exec /bin/bash \(boxCommand)", temporary: folder.path)
        defer { session.end() }

        // The turn's end is its Stop hook's event: the prompt's own text, echoed on the screen, says "finished" too.
        func events() -> [String] {
            ((try? String(contentsOfFile: eventsFile, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["hook_event_name"] as? String
            }
        }
        let finished = await eventually(timeout: 180) { events().contains("Stop") }
        print("SB0: the turn \(finished ? "finished (its Stop hook ran)" : "did not finish within 180 s")")
        print("SB0: made-in-the-box in the worktree: \(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("made-in-the-box").path))")
        // Input on a terminal with no name: typed into the prompt, not sent (no second turn).
        let typed = "typed-in-the-box"
        session.type(typed)
        let echoed = await eventually(timeout: 15) { session.screen().components(separatedBy: typed).count > 1 }
        print("SB0: text typed at the prompt was drawn: \(echoed)")
        let screen = session.screen()
        print("SB0: the trust question shown: \(screen.contains("trust the files") || screen.contains("Do you trust"))")
        print("SB0: the answer drawn: \(screen.components(separatedBy: "finished").count > 2)")
        // Out as RealSession does: Ctrl-C, and again once it says a second one ends it.
        session.type("\u{15}\u{3}")
        let asked = await eventually(timeout: 10) { session.screen().filter { !$0.isWhitespace }.contains("againtoexit") || session.ended() }
        session.type("\u{3}")
        _ = await eventually(timeout: 15) { session.ended() }
        print("SB0: the session \(session.ended() ? "ended on Ctrl-C\(asked ? " twice" : "")" : "was killed")")

        // What it wrote: the box's own config folder, the given folder, the login, the hosts, the hooks.
        let own = Self.entries(of: home.appendingPathComponent(".claude"))
        print("SB0: the box's config folder now holds: \(own.keys.sorted().joined(separator: " "))")
        let after = Self.entries(of: config)
        let moved = after.filter { before[$0.key] != $0.value }.keys.sorted()
        print("SB0: entries of the given folder that changed or appeared: \(moved.isEmpty ? "none" : moved.joined(separator: " "))")
        print("SB0: .credentials.json \(before[".credentials.json"] == after[".credentials.json"] ? "unchanged (inode, ctime, size)" : "CHANGED")")
        let homeEntries = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        print("SB0: the box's home now holds: \(homeEntries.sorted().joined(separator: " "))")
        let hosts = ((try? String(contentsOf: proxyLog, encoding: .utf8)) ?? "").split(separator: "\n")
        print("SB0: hosts asked of the proxy, in order: \(hosts.joined(separator: " | "))")
        print("SB0: hook events: \(events().joined(separator: " "))")
        // Refused writes and login errors, from its own debug log (in the box's config folder).
        let debug = home.appendingPathComponent(".claude/debug")
        for file in (try? FileManager.default.contentsOfDirectory(atPath: debug.path)) ?? [] {
            let text = (try? String(contentsOf: debug.appendingPathComponent(file), encoding: .utf8)) ?? ""
            // Kept for reading afterwards, beside the run's other logs (not committed).
            try? text.write(to: packageFolder.appendingPathComponent(".build/logs/sb0-claude-debug-\(file)"), atomically: true, encoding: .utf8)
            for line in text.split(separator: "\n") where Self.worthSaying(line) { print("SB0: debug: \(line.prefix(300))") }
        }
        print("SB0: screen's end: \(String(screen.suffix(800)))")

        #expect(finished, "the turn never finished: \(String(screen.suffix(1500)))")
        #expect(echoed, "typed text never drawn: \(String(screen.suffix(1500)))")
        #expect(before[".credentials.json"] == after[".credentials.json"])
    }

    /// The lines of Claude Code's debug log that say something the box refused, or about its login: never one that
    /// carries a long token-like word.
    static func worthSaying(_ line: Substring) -> Bool {
        let lower = line.lowercased()
        return ["erofs", "read-only", "eacces", "eperm", "permission denied", "credential", "oauth", "refresh", "login",
                "ttyname", "not a tty"].contains { lower.contains($0) }
            && !lower.contains("bearer ") && !lower.contains("sk-ant")
            && line.range(of: "[A-Za-z0-9_\\-]{40,}", options: .regularExpression) == nil
    }

    /// Each entry of `folder`, by name: its inode, change time and size, from `lstat` (nothing is opened).
    static func entries(of folder: URL) -> [String: String] {
        var found: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            var info = stat()
            guard lstat(folder.appendingPathComponent(name).path, &info) == 0 else { continue }
            let changed = Platform.Files.changed(info)
            found[name] = "\(info.st_ino) \(changed.tv_sec).\(changed.tv_nsec) \(info.st_size)"
        }
        return found
    }

    /// Removes each entry of `folder` that wasn't there before the run; never the login.
    static func removeWhatAppeared(in folder: URL, since before: [String: String]) {
        for name in entries(of: folder).keys where before[name] == nil && name != ".credentials.json" {
            print("SB0: removing \(name), which the run added to \(folder.path)")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func quoted(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// A command on a pty made outside the box by `script` (util-linux's), as `RealSession` does: the test types into
/// `script`'s stdin and reads what is drawn from its stdout. Started through `Platform.Spawn`, in a process group of its
/// own, and collected with bounded waits.
private final class BoxTerminal: @unchecked Sendable {
    private let pid: pid_t
    private let input: Int32
    private let lock = NSLock()
    private var drawn = Data()
    private var status: Int32?

    init(command: String, temporary: String) throws {
        var stdin: [Int32] = [-1, -1], stdout: [Int32] = [-1, -1]
        guard Sys.pipeClosedOnExec(&stdin) == 0, Sys.pipeClosedOnExec(&stdout) == 0 else { throw Platform.Errno(code: errno) }
        var spawn = Platform.Spawn(executable: "/usr/bin/script", arguments: ["script", "-q", "-c", command, "/dev/null"])
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporary
        environment["TERM"] = "xterm-256color"
        spawn.environment = environment.map { "\($0.key)=\($0.value)" }
        spawn.stdin = .descriptor(stdin[0])
        spawn.stdout = .descriptor(stdout[1])
        spawn.stderr = .descriptor(stdout[1])
        spawn.group = .ownGroup
        let started = spawn.start()
        Sys.close(stdin[0])
        Sys.close(stdout[1])
        input = stdin[1]
        pid = try started.get()
        let reading = stdout[0]
        Thread { [self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Sys.read(reading, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                lock.lock()
                drawn.append(contentsOf: chunk[0..<count])
                lock.unlock()
            }
            Sys.close(reading)
        }.start()
    }

    /// What it drew so far, its escape sequences dropped.
    func screen() -> String {
        lock.lock()
        let text = String(decoding: drawn, as: UTF8.self)
        lock.unlock()
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9]*C", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][0-9A-Za-z]",
                                  with: "", options: .regularExpression)
    }

    func type(_ text: String) {
        _ = text.utf8CString.withUnsafeBufferPointer { Sys.write(input, $0.baseAddress, $0.count - 1) }
    }

    /// Whether `script` has ended (collected here, without waiting).
    func ended() -> Bool {
        if status != nil { return true }
        var raw: Int32 = 0
        if waitpid(pid, &raw, WNOHANG) == pid { status = raw }
        return status != nil
    }

    /// Its group killed, if it still runs, and it collected.
    func end() {
        Sys.close(input)
        guard !ended() else { return }
        Sys.kill(-pid, SIGKILL)
        status = collected(pid, by: MacTime.real.awake() + 10)
    }
}
