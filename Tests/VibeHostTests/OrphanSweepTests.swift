import Darwin
import Foundation
import Testing
@testable import VibeHost

/// The host's housekeeping ends what outlived what it served: a tool server (vibeswitcher-mcp beside the host) whose
/// agent ended under it, and a parser no session holds. Nothing else: a tool server whose agent runs, or another
/// program left to launchd, stays. On a scratch host (its own binary, so the tool server beside it is the test's) that
/// looks twice a second, told to end tool servers (only the user's own host does unasked).
@Suite(hostTestLimit) struct OrphanSweepTests {
    /// Starts `executable` reading `input` (a FIFO) with launchd as its parent (its starter exits at once), as a tool
    /// server is once its agent ends: its pid. The caller opens `input` for writing (which lets it start) and keeps it
    /// open, so it waits on its input as a tool server does.
    static func orphan(_ executable: String, input: String) throws -> pid_t {
        let starter = Process()
        starter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Its output first: while it waits on the FIFO it mustn't hold this pipe (read to its end below).
        starter.arguments = ["-c", "\"$0\" > /dev/null 2>&1 < \"$1\" & echo $!", executable, input]
        let pipe = Pipe()
        starter.standardOutput = pipe
        try starter.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        starter.waitUntilExit()
        return try #require(pid_t(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// A FIFO in `folder`, and its write end (opened once the reader is there).
    static func fifo(in folder: String, _ name: String) -> String {
        let path = folder + "/" + name
        mkfifo(path, 0o600)
        return path
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var short = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 1, &short, size) == size else { return nil }
        return pid_t(short.pbsi_ppid)
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// The built tool server, and a copy of it at `path`: as a host's sibling it's that host's.
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

    @Test func aToolServerWhoseAgentEndedIsEndedAndNothingElse() throws {
        let host = try ScratchHostProcess(arguments: ["--housekeeping", "0.5", "--end-orphaned-tool-servers"])
        defer { host.stop() }
        // The tool server beside the scratch host's binary: the built one, waiting on its input as it does for its agent.
        let built = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        let toolServer = host.dir + "/old/vibeswitcher-mcp"
        try FileManager.default.copyItem(atPath: built, toPath: toolServer)
        let input = Self.fifo(in: host.dir, "orphan-input")
        let orphaned = try Self.orphan(toolServer, input: input)
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: input))
        defer { try? writer.close() }
        // Another build's, left to launchd too: not this host's to end.
        let otherInput = Self.fifo(in: host.dir, "other-input")
        let other = try Self.orphan(built, input: otherInput)
        let otherWriter = try FileHandle(forWritingTo: URL(fileURLWithPath: otherInput))
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
        #expect(eventually { HostServer.executable(of: switched.processIdentifier).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == target })

        // What the host did is in its session log.
        let notes = { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }
        #expect(eventually(timeout: 60) { !Self.alive(orphaned) }, "\(notes())")
        #expect(eventually(timeout: 60) { notes().contains("ended tool server pid \(orphaned), whose agent ended") }, "\(notes())")
        // A few more looks: the others stay.
        Thread.sleep(forTimeInterval: 2)
        #expect(served.isRunning && switched.isRunning && Self.parent(of: switched.processIdentifier) == getpid())
        #expect(Self.alive(other) && Self.parent(of: other) == 1, "\(notes())")
        for kept in [served.processIdentifier, switched.processIdentifier, other] { #expect(!notes().contains("pid \(kept)"), "\(notes())") }
    }

    /// A scratch host not told to (a test's, a bench's, beside a build folder) ends none: they'd be that folder's.
    @Test func aScratchHostEndsNoToolServerUnasked() throws {
        let host = try ScratchHostProcess(arguments: ["--housekeeping", "0.5"])
        defer { host.stop() }
        let built = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        let toolServer = host.dir + "/old/vibeswitcher-mcp"
        try FileManager.default.copyItem(atPath: built, toPath: toolServer)
        let input = Self.fifo(in: host.dir, "orphan-input")
        let orphaned = try Self.orphan(toolServer, input: input)
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: input))
        defer {
            kill(orphaned, SIGKILL)
            try? writer.close()
        }
        // One the sweep would take: only the flag (or being the user's host) is missing.
        #expect(eventually(timeout: 60) { HostProcesses.orphans(running: toolServer).contains(orphaned) })
        Thread.sleep(forTimeInterval: 3)
        #expect(Self.alive(orphaned))
        let notes = (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? ""
        #expect(!notes.contains("ended tool server"), "\(notes)")
    }

    /// What the housekeeping takes for a parser: `launcher --parse-session`, not a session's program or anything else.
    @Test func aParserIsToldFromOtherChildren() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { Darwin.close($0) } }
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

        #expect(eventually { HostProcesses.isParser(parser.processIdentifier) })
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
    @Test func theSweepListsOnlyThatFilesOrphans() throws {
        let dir = "\(shortScratchRoot)/vsos-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let toolServer = dir + "/vibeswitcher-mcp"
        try FileManager.default.copyItem(atPath: Self.built, toPath: toolServer)
        var ended: [pid_t] = []
        var writers: [FileHandle] = []
        defer {
            ended.forEach { kill($0, SIGKILL) }
            writers.forEach { try? $0.close() }
        }
        let orphanInput = Self.fifo(in: dir, "orphan-input"), otherInput = Self.fifo(in: dir, "other-input")
        let orphaned = try Self.orphan(toolServer, input: orphanInput), other = try Self.orphan(Self.built, input: otherInput)
        ended += [orphaned, other]
        writers += [try FileHandle(forWritingTo: URL(fileURLWithPath: orphanInput)), try FileHandle(forWritingTo: URL(fileURLWithPath: otherInput))]
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
        #expect(eventually { HostServer.executable(of: switched.processIdentifier).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                    == URL(fileURLWithPath: toolServer).resolvingSymlinksInPath().path })

        #expect(eventually(timeout: 60) { HostProcesses.orphans(running: toolServer).contains(orphaned) })
        let listed = HostProcesses.orphans(running: toolServer)
        #expect(listed == [orphaned], "listed \(listed); other \(other), served \(served.processIdentifier), switched \(switched.processIdentifier)")
        #expect(Self.parent(of: switched.processIdentifier) == getpid() && Self.parent(of: served.processIdentifier) == getpid())
    }

    /// A parser a session holds stays through every housekeeping, before a handover and after it; one the host
    /// started no session holds (here one a build standing in for the next left behind as it became the host, in
    /// place) is ended, and that's logged.
    @Test func aHeldParserStaysAndOneNoSessionHoldsIsEnded() throws {
        let host = try ScratchHostProcess(arguments: ["--housekeeping", "0.5"])
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try client.spawn("exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        let notes = { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }
        #expect(eventually { Self.parsers(of: host.pid).count == 1 })
        let held = try #require(Self.parsers(of: host.pid).first)
        Thread.sleep(forTimeInterval: 2)
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
        #expect(eventually { client.reply(to: seq) != nil })
        #expect(client.reply(to: seq) == .ok, "\(host.log)")
        #expect(eventually { host.log.contains("took over 1 sessions") }, "\(host.log)")
        let stray = try #require(pid_t((try? String(contentsOfFile: strayFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        defer { kill(stray, SIGKILL) }
        #expect(eventually(timeout: 60) { notes().contains("host: ended parser pid \(stray), which no session holds") }, "\(notes())")
        #expect(eventually { !Self.alive(stray) })
        // The restored session's own parser (the one before went with the old build) stays.
        #expect(eventually { Self.parsers(of: host.pid).count == 1 })
        let restored = try #require(Self.parsers(of: host.pid).first)
        #expect(restored != held && restored != stray)
        Thread.sleep(forTimeInterval: 2)
        #expect(Self.parsers(of: host.pid) == [restored], "\(notes())")
        #expect(!notes().contains("ended parser pid \(restored),") && !notes().contains("ended parser pid \(held),"), "\(notes())")
    }
}
