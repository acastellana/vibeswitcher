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

    /// The leaks `leaks` finds in process `pid` (`nil` when it can't look).
    static func leakCount(_ pid: Int32) -> (count: Int, text: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        process.arguments = ["\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.firstMatch(of: #/: (\d+) leaks? for /#).flatMap { Int($0.1) }.map { ($0, output) }
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
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        let lines = LineReader(output.fileHandleForReading)
        let ready = try #require(lines.next())
        #expect(ready == "ready 160 texts", "\(ready)")
        let before = try #require(Self.leakCount(process.processIdentifier), "leaks couldn't look at the bench")
        input.fileHandleForWriting.write(Data("go\n".utf8))
        #expect(lines.next() == "built")
        let after = try #require(Self.leakCount(process.processIdentifier))
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
