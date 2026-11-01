import Darwin
import Foundation
import Testing
@testable import VibeCore

/// The built `vibeswitcher-mcp --status-line`, as Claude Code runs it for a session VibeSwitcher started (see
/// `UsageStatusLine`), on a scratch home: a reader that has gone (your status line not reading its input, Claude Code
/// closing the output) never ends it with SIGPIPE before your status line's output is printed and the usage kept.
struct StatusLineBinaryTests {
    let temp = Scratch()

    /// The binary run with `input` on its stdin (from a file) and `home` as HOME, its output to `output` (nil: a pipe
    /// whose reader is closed before it starts); its exit status, once it has exited.
    func run(input: Data, home: String, output: URL?) throws -> (status: Int32, reason: Process.TerminationReason) {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let inputFile = temp.url("status-input")
        try input.write(to: inputFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mcp)
        process.arguments = [UsageStatusLine.argument]
        process.environment = ["HOME": home, "CFFIXED_USER_HOME": home, "VIBESWITCHER_HOME": home + "/.vibeswitcher", "PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.standardInput = try FileHandle(forReadingFrom: inputFile)
        process.standardError = FileHandle.nullDevice
        let gone = Pipe()
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: output)
        } else {
            process.standardOutput = gone
        }
        try process.run()
        if output == nil { try gone.fileHandleForReading.close() }
        process.waitUntilExit()
        return (process.terminationStatus, process.terminationReason)
    }

    func home(statusLine command: String) throws -> String {
        let home = temp.url("status-home").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": command]]
        try JSONSerialization.data(withJSONObject: settings).write(to: URL(fileURLWithPath: home + "/.claude/settings.json"))
        return home
    }

    /// A status line's input with a weekly window, padded to `size` bytes.
    func input(size: Int) -> Data {
        let head = #"{"rate_limits":{"seven_day":{"used_percentage":55,"resets_at":\#(Int(Date().timeIntervalSince1970) + 86_400)}},"pad":""#
        return Data((head + String(repeating: "a", count: max(0, size - head.utf8.count - 2)) + #""}"#).utf8)
    }

    @Test func aBigInputToAStatusLineThatDoesntReadItStillShowsItsOutput() throws {
        let home = try home(statusLine: "echo mine")
        let output = temp.url("status-output")
        let ran = try run(input: input(size: 100_000), home: home, output: output)
        #expect(ran.reason == .exit && ran.status == 0, "\(ran)")
        #expect(try Data(contentsOf: output) == Data("mine\n".utf8))
        #expect(AccountUsageStore(file: URL(fileURLWithPath: home + "/.vibeswitcher/account-usage.json")).load().limits.map(\.usedPercent) == [55])
    }

    @Test func anOutputWhoseReaderHasGoneStillKeepsTheUsage() throws {
        let home = try home(statusLine: "head -c 10 >/dev/null; echo mine")
        let ran = try run(input: input(size: 100_000), home: home, output: nil)
        #expect(ran.reason == .exit && ran.status == 0, "\(ran)")
        #expect(AccountUsageStore(file: URL(fileURLWithPath: home + "/.vibeswitcher/account-usage.json")).load().limits.map(\.usedPercent) == [55])
    }
}
