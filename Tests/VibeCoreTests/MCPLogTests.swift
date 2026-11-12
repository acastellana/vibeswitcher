import Foundation
import Testing
@testable import VibeCore

/// The tool server's own log (incident 4: two tool servers ended mid-session and nothing said why).
@Suite(.serialized) struct MCPLogTests {
    /// A tool whose error carries an errno, and text that must stay out of the log.
    final class Failing: MCPToolset {
        var tools: [MCPToolInfo] { [MCPToolInfo(name: "cleanup", description: "Fails")] }
        func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult {
            MCPToolResult(text: "secret-result-text Error Domain=NSPOSIXErrorDomain Code=9 \"Bad file descriptor\"", isError: true)
        }
    }

    /// Serves `lines` on a pipe, then ends its input (`close`) or stops it with SIGUSR2; returns once serve has.
    func serve(_ lines: [String], stopWith signal: Int32? = nil) -> Bool {
        let server = MCPServer(name: "vibeswitcher", version: "1", toolset: Failing())
        let input = Pipe(), output = Pipe()
        // What the signal did before, put back once serve has returned: its source stays registered, and nothing
        // sends the signal after that (a test in another suite may install its own handler for it next).
        var before = sigaction()
        if let signal { sigaction(signal, nil, &before) }
        defer { if let signal { Self.putBack(signal, before) } }
        if let signal { server.stop(on: [signal]) }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            server.serve(input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor)
            done.signal()
        }
        input.fileHandleForWriting.write(Data(lines.map { $0 + "\n" }.joined().utf8))
        // The call's answer is out before the input ends: its failure is logged by then.
        if !lines.isEmpty {
            var answered = Data()
            while !String(decoding: answered, as: UTF8.self).contains("\"isError\"") { answered.append(output.fileHandleForReading.availableData) }
        }
        guard let signal else {
            try? input.fileHandleForWriting.close()
            return done.wait(timeout: .now() + hangGuard) == .success
        }
        // The signal source is registered with the kernel on a pool thread: a signal before that is caught by the empty
        // handler and lost, so it's sent again until serve has returned. Sent to the process, as another's kill sends
        // it: raise() sends it to this thread alone, which Linux's dispatch source (a signalfd) never reads.
        let deadline = Date().addingTimeInterval(hangGuard)
        repeat {
            kill(getpid(), signal)
            if done.wait(timeout: .now() + 0.2) == .success { return true }
        } while Date() < deadline
        return false
    }

    /// Puts `action` back for `signal` once none of it waits for this process: a kill the loop in `serve` sent before
    /// it saw serve return, which the server's source hasn't read yet, would otherwise meet the action put back (for
    /// SIGUSR2 its default: the end of the test run).
    static func putBack(_ signal: Int32, _ action: sigaction) {
        let deadline = Date().addingTimeInterval(10)
        var waiting = sigset_t()
        while true {
            sigemptyset(&waiting)
            sigpending(&waiting)
            guard sigismember(&waiting, signal) == 1, Date() < deadline else { break }
            usleep(1_000)
        }
        // A default that ends the process goes back as "ignored": sigpending sees only the calling thread's signals on
        // the Mac, so a kill still on its way to another thread could otherwise end the test run.
        var action = action
        if Self.isDefault(action) {
            var ignored = sigaction()
            sigemptyset(&ignored.sa_mask)
            sigaction(signal, nil, &ignored)
            Self.setIgnored(&ignored)
            action = ignored
        }
        sigaction(signal, &action, nil)
    }

    /// Whether `action` is the signal's default (no handler: SIG_DFL), on both systems.
    static func isDefault(_ action: sigaction) -> Bool {
        #if os(Linux)
        action.sa_flags & Int32(SA_SIGINFO) == 0 && action.__sigaction_handler.sa_handler == nil
        #else
        action.sa_flags & SA_SIGINFO == 0 && action.__sigaction_u.__sa_handler == nil
        #endif
    }

    /// `action` made SIG_IGN, its other fields as they are.
    static func setIgnored(_ action: inout sigaction) {
        #if os(Linux)
        action.__sigaction_handler.sa_handler = SIG_IGN
        #else
        action.__sigaction_u.__sa_handler = SIG_IGN
        #endif
    }

    @Test func itSaysWhyServingEndedAndAToolsErrnoButNoneOfItsText() async throws {
        let temp = Scratch()
        let root = temp.url("vs")
        let log = try #require(MCPLog.start(role: "lead", root: root))
        #expect(log.path == root.appendingPathComponent("debug/mcp-lead-\(getpid()).log").path)
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"cleanup","arguments":{"task":"secret-argument"}}}"#
        #expect(serve([call]))
        let text = try String(contentsOfFile: log.path, encoding: .utf8)
        #expect(text.contains("tool cleanup failed after"), "\(text)")
        #expect(text.contains("errno 9 (EBADF), fds "), "\(text)")
        #expect(text.contains("serve: input ended (EOF: the client closed it)"), "\(text)")
        #expect(!text.contains("secret"), "\(text)")
        // Private: the user's own, as the app's debug files.
        var info = stat()
        #expect(stat(log.path, &info) == 0 && info.st_mode & 0o777 == 0o600)

        #expect(await SignalTestLock.held { serve([], stopWith: SIGUSR2) })
        let stopped = try String(contentsOfFile: log.path, encoding: .utf8)
        #expect(stopped.contains("stopping: signal \(SIGUSR2)"), "\(stopped)")
        #expect(stopped.contains("serve: stopped (asked to)"), "\(stopped)")
    }

    @Test func aFullLogMovesToItsOneBefore() throws {
        let temp = Scratch()
        let folder = temp.url("rotate")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("mcp-lead-1.log").path
        let log = try #require(MCPLog(path: path, maxBytes: 300))
        for index in 0..<20 { log.write("line \(index) " + String(repeating: "x", count: 40)) }
        let current = try String(contentsOfFile: path, encoding: .utf8)
        let before = try String(contentsOfFile: path + ".1", encoding: .utf8)
        #expect(current.utf8.count <= 300 && before.utf8.count <= 300)
        #expect(current.contains("line 19") && !before.contains("line 19"))
    }

    @Test func itNamesErrnosAndOldLogsGo() throws {
        #expect(MCPLog.errnoCode(in: "Error Domain=NSPOSIXErrorDomain Code=9 \"Bad file descriptor\"") == EBADF)
        #expect(MCPLog.errnoCode(in: "Couldn't start the command: Too many open files.") == EMFILE)
        #expect(MCPLog.errnoCode(in: "No such task.") == nil)
        #expect(MCPLog.errnoText(EMFILE) == "errno 24 (EMFILE)")
        #expect(MCPLog.file(role: "worker", pid: 7, root: URL(fileURLWithPath: "/r")).path == "/r/debug/mcp-worker-7.log")
        #expect(MCPLog.file(role: "../x", pid: 7, root: URL(fileURLWithPath: "/r")).path == "/r/debug/mcp-unknown-7.log")
        #expect((MCPLog.openDescriptors() ?? 0) >= 3)

        let temp = Scratch()
        let folder = temp.url("prune")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["mcp-lead-1.log", "mcp-lead-2.log.1", "app.log"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let later = Date().addingTimeInterval(8 * 24 * 3600)
        MCPLog.prune(folder: folder, olderThan: 7 * 24 * 3600, now: later)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["app.log"])
    }
}
