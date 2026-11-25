import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// The host's housekeeping ends what outlived what it served: a tool server (vibeswitcher-mcp beside the host) whose
/// agent ended under it, and a parser no session holds. Nothing else: a tool server whose agent runs, or another
/// program left to launchd, stays. On a scratch host (its own binary, so the tool server beside it is the test's) that
/// looks twice a second, told to end tool servers (only the user's own host does unasked).
@Suite(hostTestLimit) struct OrphanSweepTests {
    /// Starts `executable` reading `input` (a FIFO) with launchd as its parent (its starter exits at once), as a tool
    /// server is once its agent ends: its pid, and `input` opened for writing (which lets it start). The caller keeps
    /// that open, so it waits on its input as a tool server does.
    ///
    /// The starter is the platform's spawn, which hands it nothing of this process's but its stdout, and is waited
    /// for by pid. Started with Foundation's `Process`, on Linux its end wasn't seen while the job ran (2026-11-13: the
    /// starter a zombie, `isRunning` still true for 300 s, the job and then the tool server holding a socket they
    /// inherited from this process). Its line is read, not the pipe to its end: dash (Ubuntu's /bin/sh) keeps a copy
    /// of the job's stdout (on fd 10, to restore after its redirections) until the job has opened the FIFO.
    static func orphan(_ executable: String, input: String) async throws -> (pid: pid_t, writer: FileHandle) {
        var pipe: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&pipe) == 0)
        var starter = Platform.Spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", "\"$0\" > /dev/null 2>&1 < \"$1\" & echo $!",
                                                                       executable, input])
        starter.stdin = .path("/dev/null", flags: O_RDONLY)
        starter.stdout = .descriptor(pipe[1])
        starter.keep = []
        let started = starter.start()
        Sys.close(pipe[1])
        defer { Sys.close(pipe[0]) }
        guard case .success(let shell) = started else { throw CancellationError() }
        let output = await offPool { () -> Data in
            let reading = FileHandle(fileDescriptor: pipe[0], closeOnDealloc: false)
            var output = Data()
            while !output.contains(UInt8(ascii: "\n")) {
                let chunk = reading.availableData
                guard !chunk.isEmpty else { break }
                output.append(chunk)
            }
            return output
        }
        let pid = try #require(pid_t(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let writer = try await offPool { try FileHandle(forWritingTo: URL(fileURLWithPath: input)) }
        await offPool {
            var status: Int32 = 0
            while waitpid(shell, &status, 0) < 0, errno == EINTR {}
        }
        return (pid, writer)
    }

    /// A FIFO in `folder`, and its write end (opened once the reader is there).
    static func fifo(in folder: String, _ name: String) -> String {
        let path = folder + "/" + name
        mkfifo(path, 0o600)
        return path
    }

    static func parent(of pid: pid_t) -> pid_t? {
        guard case .brief(let brief) = Platform.Processes.brief(pid) else { return nil }
        return brief.ppid
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// The built tool server. A case's copy of it (as a host's sibling it's that host's) is made by a child
    /// (`installProgram`) and run at once: copied by this process, running it failed with "Text file busy" in a full run.
    static var built: String {
        URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
    }

    /// Started by this test (its agent) as /bin/sh, then made `executable` in place once `cue` gets a line, as a tool
    /// server switching builds does (see `MCPHandover`): the same pid, the same parent.
    static func execsInPlace(into executable: String, cue: Pipe) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read _; exec \"$0\"", executable]
        process.standardInput = cue
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Its parsers: the host's children that are `--parse-session`.
    static func parsers(of host: pid_t) -> [pid_t] { HostProcesses.children(of: host).filter(HostProcesses.isParser) }

    @Test func aToolServerWhoseAgentEndedIsEndedAndNothingElse() async throws {
        let host = try await ScratchHostProcess(arguments: ["--housekeeping", "0.5", "--end-orphaned-tool-servers"])
        defer { host.stop() }
        // The tool server beside the scratch host's binary: the built one, waiting on its input as it does for its agent.
        let built = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        let toolServer = host.dir + "/old/vibeswitcher-mcp"
        try installProgram(built, atPath: toolServer)
        let input = Self.fifo(in: host.dir, "orphan-input")
        let (orphaned, writer) = try await Self.orphan(toolServer, input: input)
        defer { try? writer.close() }
        // Another build's, left to launchd too: not this host's to end.
        let otherInput = Self.fifo(in: host.dir, "other-input")
        let (other, otherWriter) = try await Self.orphan(built, input: otherInput)
        defer {
            kill(other, SIGKILL)
            try? otherWriter.close()
        }
        // One whose agent (here the test) still runs.
        let served = Process()
        served.executableURL = URL(fileURLWithPath: toolServer)
        let servedInput = Pipe()
        served.standardInput = servedInput
        served.standardOutput = FileHandle.nullDevice
        served.standardError = FileHandle.nullDevice
        try served.run()
        defer { if served.isRunning { kill(served.processIdentifier, SIGKILL) } }
        // One that switched builds in place while its agent runs: still this test's child.
        let cue = Pipe()
        let switched = try Self.execsInPlace(into: toolServer, cue: cue)
        defer { if switched.isRunning { kill(switched.processIdentifier, SIGKILL) } }
        cue.fileHandleForWriting.write(Data("go\n".utf8))
        let target = URL(fileURLWithPath: toolServer).resolvingSymlinksInPath().path
        #expect(await eventually { HostServer.executable(of: switched.processIdentifier).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == target })

        // What the host did is in its session log.
        let notes = { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }
        #expect(await eventually(timeout: 60) { !Self.alive(orphaned) }, "\(notes())")
        #expect(await eventually(timeout: 60) { notes().contains("ended tool server pid \(orphaned), whose agent ended") }, "\(notes())")
        // A few more looks: the others stay.
        await pause(2)
        #expect(served.isRunning && switched.isRunning && Self.parent(of: switched.processIdentifier) == getpid())
        // Its parent is the one an orphan gets: launchd on the Mac, the user's systemd here (`orphanParents`).
        #expect(Self.alive(other) && Self.parent(of: other).map(HostProcesses.orphanParents.contains) == true, "\(notes())")
        for kept in [served.processIdentifier, switched.processIdentifier, other] { #expect(!notes().contains("pid \(kept)"), "\(notes())") }
    }

    /// A scratch host not told to (a test's, a bench's, beside a build folder) ends none: they'd be that folder's.
    @Test func aScratchHostEndsNoToolServerUnasked() async throws {
        let host = try await ScratchHostProcess(arguments: ["--housekeeping", "0.5"])
        defer { host.stop() }
        let built = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        let toolServer = host.dir + "/old/vibeswitcher-mcp"
        try installProgram(built, atPath: toolServer)
        let input = Self.fifo(in: host.dir, "orphan-input")
        let (orphaned, writer) = try await Self.orphan(toolServer, input: input)
        defer {
            kill(orphaned, SIGKILL)
            try? writer.close()
        }
        // One the sweep would take: only the flag (or being the user's host) is missing.
        #expect(await eventually(timeout: 60) { HostProcesses.orphans(running: toolServer).contains(orphaned) })
        await pause(3)
        #expect(Self.alive(orphaned))
        let notes = (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? ""
        #expect(!notes.contains("ended tool server"), "\(notes)")
    }

    /// What the housekeeping takes for a parser: `launcher --parse-session`, not a session's program or anything else.
    @Test func aParserIsToldFromOtherChildren() async throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, Platform.Sockets.stream, 0, &pair) == 0)
        defer { pair.forEach { Sys.close($0) } }
        let parser = Process()
        parser.executableURL = URL(fileURLWithPath: hostLauncher)
        parser.arguments = ["--parse-session", "80", "24"]
        parser.standardInput = FileHandle(fileDescriptor: pair[1], closeOnDealloc: false)
        try parser.run()
        defer { if parser.isRunning { kill(parser.processIdentifier, SIGKILL) } }
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["600"]
        try other.run()
        defer { kill(other.processIdentifier, SIGKILL) }

        #expect(await eventually { HostProcesses.isParser(parser.processIdentifier) })
        #expect(!HostProcesses.isParser(other.processIdentifier))
        let children = HostProcesses.children(of: getpid())
        #expect(children.contains(parser.processIdentifier) && children.contains(other.processIdentifier))
    }

    /// An orphan of the tool server's: launchd's child, the user's, running exactly that file. The path is asked last
    /// (another user's isn't read).
    @Test func anOrphanIsLaunchdsTheUsersAndThatFile() {
        let target = "/Users/someone/VibeSwitcher.app/Contents/MacOS/vibeswitcher-mcp"
        let me = geteuid()
        #expect(HostProcesses.isOrphan(parent: 1, uid: me, running: target, user: me) { target })
        // Another build's, another program, one gone.
        #expect(!HostProcesses.isOrphan(parent: 1, uid: me, running: target, user: me) { "/Users/someone/build/debug/vibeswitcher-mcp" })
        #expect(!HostProcesses.isOrphan(parent: 1, uid: me, running: target, user: me) { "/bin/sleep" })
        #expect(!HostProcesses.isOrphan(parent: 1, uid: me, running: target, user: me) { nil })
        // Its agent runs: it's that agent's child.
        #expect(!HostProcesses.isOrphan(parent: 4242, uid: me, running: target, user: me) { target })
        // Another user's: not looked at.
        var asked = false
        #expect(!HostProcesses.isOrphan(parent: 1, uid: me + 1, running: target, user: me) { asked = true; return target })
        #expect(!asked)
    }

    /// The sweep's list, from the real process table: the orphan at the host's sibling path only, not one at another
    /// path, nor one whose agent (this test) runs, nor one that switched builds in place under it.
    @Test func theSweepListsOnlyThatFilesOrphans() async throws {
        let dir = "\(shortScratchRoot)/vsos-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let toolServer = dir + "/vibeswitcher-mcp"
        try installProgram(Self.built, atPath: toolServer)
        var ended: [pid_t] = []
        var writers: [FileHandle] = []
        defer {
            ended.forEach { kill($0, SIGKILL) }
            writers.forEach { try? $0.close() }
        }
        let orphanInput = Self.fifo(in: dir, "orphan-input"), otherInput = Self.fifo(in: dir, "other-input")
        let (orphaned, orphanWriter) = try await Self.orphan(toolServer, input: orphanInput)
        ended.append(orphaned)
        writers.append(orphanWriter)
        let (other, otherWriter) = try await Self.orphan(Self.built, input: otherInput)
        ended.append(other)
        writers.append(otherWriter)
        let served = Process()
        served.executableURL = URL(fileURLWithPath: toolServer)
        served.standardInput = Pipe()
        served.standardOutput = FileHandle.nullDevice
        served.standardError = FileHandle.nullDevice
        try served.run()
        ended.append(served.processIdentifier)
        let cue = Pipe()
        let switched = try Self.execsInPlace(into: toolServer, cue: cue)
        ended.append(switched.processIdentifier)
        cue.fileHandleForWriting.write(Data("go\n".utf8))
        #expect(await eventually { HostServer.executable(of: switched.processIdentifier).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                    == URL(fileURLWithPath: toolServer).resolvingSymlinksInPath().path })

        #expect(await eventually(timeout: 60) { HostProcesses.orphans(running: toolServer).contains(orphaned) })
        let listed = HostProcesses.orphans(running: toolServer)
        #expect(listed == [orphaned], "listed \(listed); other \(other), served \(served.processIdentifier), switched \(switched.processIdentifier)")
        #expect(Self.parent(of: switched.processIdentifier) == getpid() && Self.parent(of: served.processIdentifier) == getpid())
    }

    /// A parser a session holds stays through every housekeeping, before a handover and after it; one the host
    /// started no session holds (here one a build standing in for the next left behind as it became the host, in
    /// place) is ended, and that's logged.
    @Test func aHeldParserStaysAndOneNoSessionHoldsIsEnded() async throws {
        let host = try await ScratchHostProcess(arguments: ["--housekeeping", "0.5"])
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        let notes = { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }
        #expect(await eventually { Self.parsers(of: host.pid).count == 1 })
        let held = try #require(Self.parsers(of: host.pid).first)
        await pause(2)
        #expect(Self.parsers(of: host.pid) == [held], "\(notes())")
        #expect(!notes().contains("ended parser"), "\(notes())")

        // The next build, leaving a parser behind it: the host's child once the build is the host.
        let strayFile = host.dir + "/stray-pid", input = Self.fifo(in: host.dir, "stray-input")
        let leaving = host.script("leaving-host", """
            case " $* " in *" --handover-probe "*) exec '\(host.newBinary)' "$@";; esac
            '\(host.newBinary)' --parse-session 80 24 <> '\(input)' > /dev/null 2>&1 &
            echo $! > '\(strayFile)'
            exec '\(host.newBinary)' "$@"
            """)
        let seq = client.send(.handover(executable: leaving))
        #expect(await eventually { client.reply(to: seq) != nil })
        #expect(client.reply(to: seq) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("took over 1 sessions") }, "\(host.log)")
        let stray = try #require(pid_t((try? String(contentsOfFile: strayFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        defer { kill(stray, SIGKILL) }
        #expect(await eventually(timeout: 60) { notes().contains("host: ended parser pid \(stray), which no session holds") }, "\(notes())")
        #expect(await eventually { !Self.alive(stray) })
        // The restored session's own parser (the one before went with the old build) stays.
        #expect(await eventually { Self.parsers(of: host.pid).count == 1 })
        let restored = try #require(Self.parsers(of: host.pid).first)
        #expect(restored != held && restored != stray)
        await pause(2)
        #expect(Self.parsers(of: host.pid) == [restored], "\(notes())")
        #expect(!notes().contains("ended parser pid \(restored),") && !notes().contains("ended parser pid \(held),"), "\(notes())")
    }

    /// `installProgram`: a program it has just copied runs at once while the process starts children meanwhile, as a
    /// full run's other tests do. Linux won't run a file that any process holds open for writing ("Text file busy",
    /// ETXTBSY), and a child keeps every descriptor of this process that isn't close-on-exec: copied here with
    /// `FileManager.copyItem`, the tool server's copies above couldn't be run in a full run (2026-11-17). Here each child
    /// keeps what it inherits for 50 ms.
    @Test func aProgramJustInstalledRunsWhileTheProcessStartsChildren() async throws {
        let folder = scratchRoot.appendingPathComponent("vsos-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #if os(macOS)
        // The Mac kills a copy of its own sleep as it starts (`signedAsItsOwn`): here the copies are of one signed as a
        // program of its own, made before the children start.
        let program = folder + "/sleep"
        try installProgram(URL(fileURLWithPath: "/bin/sleep").resolvingSymlinksInPath().path, atPath: program)
        try signedAsItsOwn(program)
        #else
        let program = URL(fileURLWithPath: "/bin/sleep").resolvingSymlinksInPath().path
        #endif
        let children = Children()
        let spawning = Thread { children.spawnUntilStopped() }
        spawning.start()
        let refused = await offPool { () -> [String] in
            defer { children.stopAndWait() }
            var refused: [String] = []
            for index in 0..<60 {
                let copy = folder + "/sleep-\(index)"
                do {
                    try installProgram(program, atPath: copy)
                    var run = Platform.Spawn(executable: copy, arguments: [copy, "0"])
                    run.stdin = .path("/dev/null", flags: O_RDONLY)
                    switch run.start() {
                    case .failure(let failure): refused.append("\(index): \(failure)")
                    case .success(let pid):
                        var status: Int32 = 0
                        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                        if status != 0 { refused.append("\(index): ended \(status)") }
                    }
                } catch {
                    refused.append("\(index): \(error)")
                }
            }
            return refused
        }
        #expect(refused.isEmpty, "\(refused.count) of 60 copies didn't run, the first: \(refused.first ?? "")")
        #expect(children.started > 0)
    }

    /// Children started with `posix_spawn` and nothing closed: each keeps every descriptor of this process that isn't
    /// close-on-exec, for its 50 ms. At most 64 at once. (As `InstallScriptTests`' in VibeCoreTests.)
    private final class Children: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var live: [pid_t] = []
        private var count = 0
        private let done = DispatchSemaphore(value: 0)
        var started: Int { lock.withLock { count } }

        func spawnUntilStopped() {
            let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("0.05"), nil]
            let environment: [UnsafeMutablePointer<CChar>?] = [nil]
            defer { arguments.forEach { free($0) } }
            while !lock.withLock({ stopped }) {
                reap(blocking: false)
                guard lock.withLock({ live.count }) < 64 else { sched_yield(); continue }
                var pid = pid_t()
                if posix_spawn(&pid, "/bin/sleep", nil, nil, arguments, environment) == 0 {
                    lock.withLock {
                        live.append(pid)
                        count += 1
                    }
                }
            }
            reap(blocking: true)
            done.signal()
        }

        /// Stops the spawning, and returns once every child has ended and been waited for (bounded by the hang guard).
        func stopAndWait() {
            lock.withLock { stopped = true }
            _ = done.wait(timeout: .now() + hangGuard)
        }

        private func reap(blocking: Bool) {
            for pid in lock.withLock({ live }) {
                var status: Int32 = 0
                let got = waitpid(pid, &status, blocking ? 0 : WNOHANG)
                if got == pid || (got < 0 && errno == ECHILD) { lock.withLock { live.removeAll { $0 == pid } } }
            }
        }
    }
}
