import AppKit
import Foundation
import Testing
@testable import VibeSwitcher

/// Messages' texts are built on several threads at once (`ChatTextContent.prepareNow`, `prepare`): no AppKit font may be
/// made or measured there. Made there, a system font raced AppKit's cache of them and the loser leaked with its
/// glyph-advance cache (`leaks`: the NSCTFont of +[NSFont systemFontOfSize:width:], -[__NSFontExtraData
/// glyphAdvancementCacheWithLength:]; 51-53 after the footprint bench's churn against 0 on project-lead). The app's
/// `--chat-bench` with VIBESWITCHER_BENCH_PREPARE builds the bench fixture's 160 texts eight at a time at 200 sizes, each a
/// set of fonts not made yet, in a process of its own (`leaks` on the test process counted every other suite's leaks):
/// `leaks` on it before and after finds none more. Before `ChatFonts` an in-process run of this found 1-12 after, none
/// before, in 5 runs of 5.
@Suite(.serialized)
struct ChatTextPrepareLeakTests {
    let scratch = Scratch()

    /// How long `leaks` may take to look at the bench (1-5 s at load 14) before it's ended: 2026-10-23 two runs sat 24
    /// min behind one at 0 % CPU. An lldb attach had put up the "Developer Tools Access" password dialog (authd's
    /// system.privilege.taskport.debug, asked by taskgated) and every `leaks` and `sample` after it waited behind it.
    static let leaksLimit: TimeInterval = 120

    /// Why `leaks` gave no count.
    enum LeaksFailure: Error, CustomStringConvertible {
        case couldNotRun(String)
        case timedOut(seconds: TimeInterval, pid: Int32)
        case noCount(String)

        var description: String {
            switch self {
            case .couldNotRun(let error): "leaks couldn't run: \(error)"
            case .timedOut(let seconds, let pid):
                "leaks (pid \(pid)) gave no answer in \(Int(seconds)) s and was ended, so it couldn't look. Is a Developer "
                    + "Tools Access password dialog waiting on the screen? An attach (lldb, sample) puts one up and leaks waits behind it."
            case .noCount(let output): "leaks gave no count:\n\(output.prefix(4000))"
            }
        }
    }

    /// The leaks `leaks` finds in process `pid`, or why it couldn't look; `leaks` is ended after `limit` seconds. `tool`
    /// stands in for /usr/bin/leaks in the test of that bound, given `pid` as its one argument as leaks is.
    static func leakCount(_ pid: Int32, tool: String = "/usr/bin/leaks",
                          limit: TimeInterval = leaksLimit) throws -> (count: Int, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { throw LeaksFailure.couldNotRun("\(error)") }
        // Read as it writes (its report can outgrow the pipe), off this thread so the wait below can give up.
        let read = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var data = Data()
        Thread.detachNewThread {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if ended.wait(timeout: .now() + limit) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            ended.wait()
            throw LeaksFailure.timedOut(seconds: limit, pid: process.processIdentifier)
        }
        read.wait()
        let output = String(decoding: data, as: UTF8.self)
        guard let count = output.firstMatch(of: #/: (\d+) leaks? for /#).flatMap({ Int($0.1) }) else {
            throw LeaksFailure.noCount(output)
        }
        return (count, output)
    }

    @Test func leaksIsEndedWhenItGivesNoAnswer() throws {
        let start = Date()
        // /bin/sleep given 600 for a pid: a leaks that never answers.
        #expect {
            try Self.leakCount(600, tool: "/bin/sleep", limit: 1)
        } throws: { error in
            guard case .timedOut(let seconds, let pid)? = error as? LeaksFailure else { return false }
            return seconds == 1 && kill(pid, 0) == -1 && errno == ESRCH
                && "\(error)".contains("gave no answer in 1 s and was ended")
        }
        #expect(Date().timeIntervalSince(start) < 30)
    }

    @Test func buildingTextsOnEightThreadsLeaksNothing() throws {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        let home = scratch.url("prepare-leaks")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = app
        process.arguments = ["--chat-bench", ChatBenchTests.fixture.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["VIBESWITCHER_HOME"] = nil
        environment["VIBESWITCHER_BENCH_PREPARE"] = "1"
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let ended = DispatchGroup()
        ended.enter()
        process.terminationHandler = { _ in ended.leave() }
        try process.run()
        // A bench that hangs (or is left suspended) is killed after hangGuard: the reads below then end and so does this.
        let pid = process.processIdentifier
        DispatchQueue.global().async {
            if ended.wait(timeout: .now() + hangGuard) == .timedOut { kill(pid, SIGKILL) }
        }
        defer {
            try? input.fileHandleForWriting.close()
            ended.wait()
        }
        let lines = LineReader(output.fileHandleForReading)
        let ready = try #require(lines.next())
        #expect(ready == "ready 160 texts", "\(ready)")
        let before = try Self.leakCount(process.processIdentifier)
        input.fileHandleForWriting.write(Data("go\n".utf8))
        #expect(lines.next() == "built")
        let after = try Self.leakCount(process.processIdentifier)
        print("leaks: \(before.count) before building, \(after.count) after")
        #expect(after.count <= before.count, "leaks: \(before.count) before building, \(after.count) after\n\(after.text.prefix(4000))")
    }

    /// The lines a pipe gives, one at a time.
    final class LineReader {
        let handle: FileHandle
        var buffer = Data()
        init(_ handle: FileHandle) { self.handle = handle }
        func next() -> String? {
            while true {
                if let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...end)
                    return line
                }
                let data = handle.availableData
                if data.isEmpty { return nil }
                buffer.append(data)
            }
        }
    }
}

private final class Anchor {}
