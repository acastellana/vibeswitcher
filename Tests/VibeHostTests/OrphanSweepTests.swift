import Darwin
import Foundation
import Testing
@testable import VibeHost

/// The host's housekeeping ends what outlived what it served: a tool server (vibeswitcher-mcp beside the host) whose
/// agent ended under it, and a parser no session holds. Nothing else: a tool server whose agent runs, or another
/// program left to launchd, stays. On a scratch host (its own binary, so the tool server beside it is the test's) that
/// looks twice a second, told to end tool servers (only the user's own host does unasked).
struct OrphanSweepTests {
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

        // What the host did is in its session log.
        let notes = { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }
        #expect(eventually(timeout: 60) { !Self.alive(orphaned) }, "\(notes())")
        #expect(eventually(timeout: 60) { notes().contains("ended tool server pid \(orphaned), whose agent ended") }, "\(notes())")
        // A few more looks: the others stay.
        Thread.sleep(forTimeInterval: 2)
        #expect(served.isRunning)
        #expect(Self.alive(other) && Self.parent(of: other) == 1, "\(notes())")
        #expect(!notes().contains("pid \(served.processIdentifier)") && !notes().contains("pid \(other)"), "\(notes())")
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
        #expect(eventually(timeout: 60) { Self.parent(of: orphaned) == 1 })
        Thread.sleep(forTimeInterval: 3)
        #expect(Self.alive(orphaned))
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
}
