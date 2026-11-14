import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The sessions' environment, their shell, and what a spawn may add (the stage 2 plan's Task 10a; the security
/// architecture document's S10). A scratch host's own process (`ScratchHostProcess`) where what is checked is the
/// host's environment or its signals; an in-process one (`TestHost`) where a session's process asks the host itself.
struct SessionEnvironmentTests {
    /// The environment `pid` (a session's program, dumpable) was started with; nil while it can't be read (its launcher
    /// still runs, non-dumpable, or it's gone).
    static func environment(of pid: pid_t) -> [String: String]? {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/environ"), !data.isEmpty else { return nil }
        var result: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            result[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return result
    }

    /// What `/proc/<pid>/exe` names, its links followed; nil while it can't be read.
    static func program(of pid: pid_t) -> String? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    /// bash, its links followed (`/bin` is `/usr/bin` on Ubuntu).
    static let bash = URL(fileURLWithPath: "/bin/bash").resolvingSymlinksInPath().path

    /// The environment a session's program was started with, read once its command has run (its launcher gone), in a
    /// scratch host started with `hostEnvironment` added to its own.
    func sessionEnvironment(hostEnvironment: [String: String]) async throws -> [String: String] {
        let host = try await ScratchHostProcess(environment: hostEnvironment)
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let ran = host.dir + "/ran"
        let session = try await client.spawn("touch '\(ran)'; \(keepRunning)")
        defer { kill(-session.childPID, SIGKILL) }
        #expect(await eventually { FileManager.default.fileExists(atPath: ran) }, "\(host.log)")
        return try #require(Self.environment(of: session.childPID), "\(host.log)")
    }

    /// With the user's agent socket, interop, bus, display and audio, and the gated tests' config folder, in the host's
    /// environment, a session's program gets none of them; it gets the host's HOME and PATH and the fixed part.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's list; the Mac's passes SSH_AUTH_SOCK, as always"))
    func aLinuxSessionGetsNoAgentSocketNoInteropNoBus() async throws {
        let kept = ["SSH_AUTH_SOCK": "/run/user/1000/gnupg/S.gpg-agent.ssh", "WSL_INTEROP": "/run/WSL/1_interop",
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus", "DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-0",
                    "PULSE_SERVER": "unix:/mnt/wslg/PulseServer", "VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR": "/nonexistent/claude-config"]
        let environment = try await sessionEnvironment(hostEnvironment: kept)
        for name in kept.keys.sorted() { #expect(environment[name] == nil, "\(name) reached the session: \(environment)") }
        #expect(environment["HOME"]?.hasSuffix("/home") == true, "\(environment)")
        #expect(environment["PATH"]?.contains("/usr/bin") == true, "\(environment)")
        #expect(environment["SWIFT_BACKTRACE"] == "enable=no", "\(environment)")
        #expect(environment["LANG"] == "C.UTF-8", "\(environment)")
    }

    /// The runtime folder (the gpg-agent's, the bus's and WSLg's sockets) isn't passed. A regression test: today's list
    /// never held it either; this keeps the new one from gaining it.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's list"))
    func aLinuxSessionGetsNoRuntimeDir() async throws {
        let environment = try await sessionEnvironment(hostEnvironment: ["XDG_RUNTIME_DIR": "/run/user/1000"])
        #expect(environment["XDG_RUNTIME_DIR"] == nil, "\(environment)")
        #expect(environment["HOME"] != nil, "\(environment)")
    }

    /// A scratch HOME whose `.bashrc`, `.profile`, `.bash_profile` and `.bash_login` each leave a marker: a session's
    /// command runs and none is left, nor by a session that stays an interactive shell after its command, once a line
    /// typed into that shell has run.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's plain shell; the Mac's sessions are login shells"))
    func aTeamSessionRunsNoShellStartupFile() async throws {
        let startupFiles = [".bashrc", ".profile", ".bash_profile", ".bash_login"]
        let host = try await ScratchHostProcess { dir in
            for file in startupFiles {
                try "touch '\(dir)/marker\(file)'\n".write(toFile: dir + "/home/" + file, atomically: true, encoding: .utf8)
            }
        }
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let ran = host.dir + "/ran", kept = host.dir + "/kept", typed = host.dir + "/typed"
        let session = try await client.spawn("touch '\(ran)'; \(keepRunning)")
        defer { kill(-session.childPID, SIGKILL) }
        let seq = client.send(.spawn(SpawnRequest(cwd: host.dir, command: "touch '\(kept)'", env: [:], cols: 80, rows: 24, keepShell: true,
                                                  label: "Kept", agent: nil)))
        #expect(await eventually { client.reply(to: seq) != nil })
        guard case .spawned(let shell)? = client.reply(to: seq) else { Issue.record("not spawned: \(String(describing: client.reply(to: seq)))"); return }
        defer { kill(-shell.childPID, SIGKILL) }
        #expect(await eventually { FileManager.default.fileExists(atPath: ran) && FileManager.default.fileExists(atPath: kept) }, "\(host.log)")
        client.send(.input(id: shell.id, bytes: Data("touch '\(typed)'\r".utf8), reply: false))
        #expect(await eventually { FileManager.default.fileExists(atPath: typed) }, "\(client.screen(shell.id) ?? "")")
        let markers = startupFiles.filter { FileManager.default.fileExists(atPath: host.dir + "/marker" + $0) }
        #expect(markers == [], "startup files run: \(markers)")
    }

    /// With `SHELL=/bin/sh` in the host's environment (`ScratchHostProcess`'s), a session's program is bash, and runs
    /// its command. Run as `$SHELL` with bash's options (the launcher runs the program it is given with these
    /// arguments, `PTYSpawn`), sh would refuse them.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's plain bash; the Mac's sessions run $SHELL"))
    func aSessionRunsBashWhateverTheHostsShell() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let said = host.dir + "/said"
        let session = try await client.spawn("echo \"bash=$BASH_VERSION shell=$SHELL\" > '\(said)'; \(keepRunning); true")
        defer { kill(-session.childPID, SIGKILL) }
        #expect(await eventually { ((try? String(contentsOfFile: said, encoding: .utf8)) ?? "").hasSuffix("\n") }, "\(host.log)")
        let text = (try? String(contentsOfFile: said, encoding: .utf8)) ?? ""
        #expect(text.hasPrefix("bash=") && !text.hasPrefix("bash= ") && text.contains("shell=/bin/sh"), "\(text)")
        #expect(Self.program(of: session.childPID) == Self.bash)
    }

    /// A parser is started with `SWIFT_BACKTRACE=enable=no` beside its fixed PATH. Its launcher here is a script
    /// standing in for the host's image (`ParserLink.start` runs what it is given, with the environment it builds),
    /// which writes its environment beside itself.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's backtracer; the Mac's parsers get PATH alone, as always"))
    func aParserGetsNoBacktracer() async throws {
        let scratch = Scratch()
        let folder = scratch.url("parser-env")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launcher = folder.appendingPathComponent("launcher").path
        let written = folder.appendingPathComponent("parser-environment").path
        FileManager.default.createFile(atPath: launcher, contents: Data("#!/bin/sh\nenv > '\(written).partial' && mv '\(written).partial' '\(written)'\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let queue = DispatchQueue(label: "parser-env")
        var link: ParserLink?
        // A file just written can be busy to exec (ETXTBSY) while another test's child, forked meanwhile, holds it.
        #expect(await eventually { link = ParserLink.start(launcher: launcher, cols: 80, rows: 24, options: ParserOptions(), queue: queue); return link != nil })
        defer { queue.sync { _ = link?.stop() } }
        #expect(await eventually { FileManager.default.fileExists(atPath: written) })
        let lines = ((try? String(contentsOfFile: written, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        #expect(lines.contains("SWIFT_BACKTRACE=enable=no"), "\(lines)")
        #expect(lines.contains("PATH=/usr/bin:/bin"), "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("HOME=") }, "\(lines)")
    }

    /// A session's process asks the host to start a session with `LD_PRELOAD`, `BASH_ENV` or `SSH_AUTH_SOCK` in its
    /// `env`: each is refused, naming it, while its spawn with an ordinary variable is started. The app's spawn with all
    /// three is started, and its program has them.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's spawn rule; the Mac refuses none"))
    func aSpawnAddingALoaderVariableIsRefused() async throws {
        let vault = LeadVaultHostTests()
        try FileManager.default.createDirectory(at: vault.folder, withIntermediateDirectories: true)
        let host = try TestHost()
        let app = try TestClient(host)
        defer { app.close() }
        let requests = vault.folder.appendingPathComponent("spawn.requests")
        let answers = vault.folder.appendingPathComponent("spawn.answers")
        let go = vault.folder.appendingPathComponent("spawn.go")
        let stop = vault.folder.appendingPathComponent("spawn.stop")
        let asker = try await app.spawn("while [ ! -f '\(go.path)' ]; do sleep 0.02; done; " + vault.nc(host, requests, answers, until: stop)
            + "; " + keepRunning)
        let refused = ["LD_PRELOAD": "", "BASH_ENV": "/dev/null", "SSH_AUTH_SOCK": "/nonexistent/agent"]
        func request(_ env: [String: String]) -> HostRequest {
            .spawn(SpawnRequest(cwd: vault.folder.path, command: keepRunning, env: env, cols: 80, rows: 24, keepShell: false, label: "Asked", agent: nil))
        }
        let names = refused.keys.sorted()
        try vault.frames(names.map { request([$0: refused[$0]!]) } + [request(["VIBE_FINE": "1"])]).write(to: requests)
        FileManager.default.createFile(atPath: go.path, contents: nil)
        #expect(await eventually { vault.answered(answers, 2...5) })
        FileManager.default.createFile(atPath: stop.path, contents: nil)
        let got = try vault.replies(Data(contentsOf: answers))
        for (offset, name) in names.enumerated() {
            guard case .error(let why)? = got[offset + 2] else { Issue.record("\(name): not refused: \(String(describing: got[offset + 2]))"); continue }
            #expect(why.contains(name), "\(why)")
        }
        guard case .spawned(let fine)? = got[5] else { Issue.record("an ordinary variable refused: \(String(describing: got[5]))"); return }
        #expect(fine.childPID > 0)
        _ = asker

        let ran = vault.folder.appendingPathComponent("app.ran").path
        let seq = app.send(.spawn(SpawnRequest(cwd: vault.folder.path, command: "touch '\(ran)'; \(keepRunning)", env: refused, cols: 80, rows: 24,
                                               keepShell: false, label: "App's", agent: nil)))
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .spawned(let started)? = app.reply(to: seq) else { Issue.record("the app's refused: \(String(describing: app.reply(to: seq)))"); return }
        #expect(await eventually { FileManager.default.fileExists(atPath: ran) })
        let environment = Self.environment(of: started.childPID)
        for name in names { #expect(environment?[name] == refused[name], "\(name): \(String(describing: environment))") }
    }

    /// The host ignores SIGPIPE; a session's program (its shell, reading its own mask through ps) starts with it at its
    /// default. A regression test: the launcher is spawned with every signal at its default and execs before the host's
    /// `main.swift` ignores SIGPIPE; it keeps the launcher's hooks from changing that.
    @Test func aSessionsProgramStartsWithSIGPIPEAtItsDefault() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let said = host.dir + "/ignored"
        let session = try await client.spawn("/bin/ps -o sigignore= -p $$ > '\(said).partial' && mv '\(said).partial' '\(said)'; \(keepRunning)")
        defer { kill(-session.childPID, SIGKILL) }
        #expect(await eventually { FileManager.default.fileExists(atPath: said) }, "\(host.log)")
        let pipe = UInt64(1) << UInt64(SIGPIPE - 1)
        let program = try #require(Self.mask((try? String(contentsOfFile: said, encoding: .utf8)) ?? ""))
        #expect(program & pipe == 0, "the session's program ignores SIGPIPE: \(String(program, radix: 16))")
        let hostMask = try #require(Self.ignoredMask(of: host.pid))
        #expect(hostMask & pipe != 0, "the host doesn't ignore SIGPIPE: \(String(hostMask, radix: 16))")
    }

    /// A mask as ps prints it (hex, with or without `0x`).
    static func mask(_ text: String) -> UInt64? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        return UInt64(hex, radix: 16)
    }

    /// The signals `pid` ignores, as ps reads them.
    static func ignoredMask(of pid: pid_t) -> UInt64? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "sigignore=", "-p", String(pid)]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return mask(String(decoding: data, as: UTF8.self))
    }
}
