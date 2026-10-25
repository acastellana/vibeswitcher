import Foundation
import Testing
@testable import VibeSwitcher

/// The benches keep their defaults in scratch (`BenchDefaults`): cfprefsd kept an unbundled build's defaults in the real
/// ~/Library/Preferences/VibeSwitcher.plist whatever the scratch home said, and every bench wrote its window frames,
/// chat font and inspector tab there. scripts/test.sh fails a run that changes that file (`check_preferences`).
struct BenchDefaultsTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let scratch = Scratch()

    /// A bench's write goes to `<scratch home>/bench-defaults.plist`: the chat bench's font, set from its environment.
    @Test @MainActor func aBenchsDefaultsGoInItsScratchHome() async throws {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        try #require(FileManager.default.isExecutableFile(atPath: app.path))
        let home = scratch.url("bench-defaults")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let transcript = home.appendingPathComponent("t.jsonl")
        try FileManager.default.copyItem(at: ChatBenchTests.fixture, to: transcript)
        let process = Process()
        process.executableURL = app
        process.arguments = ["--chat-bench", transcript.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["VIBESWITCHER_HOME"] = nil  // the run's own (scripts/test.sh) would come before this home
        environment["VIBESWITCHER_BENCH_SECONDS"] = "1"
        environment["VIBESWITCHER_BENCH_FONT"] = "17"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + hangGuard) == .timedOut {
            process.terminate()
            Issue.record("the bench hung")
            return
        }
        // cfprefsd writes the file for the bench: the font is in it once that's done.
        let plist = home.appendingPathComponent("bench-defaults.plist")
        func font() -> Double? {
            (try? Data(contentsOf: plist))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["chatFontSize"] as? Double
        }
        #expect(await until { font() == 17 }, "no chatFontSize 17 in \(plist.path)")
    }

    /// In a scratch home the suite is the home's; on the account's own home (a chat bench run by hand) a new folder in
    /// the temporary folder's, never ~/Library/Preferences.
    @Test func theSuiteIsInTheScratchHomeElseANewTemporaryFolder() throws {
        let temporary = scratch.url("bench-temporary")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        #expect(BenchDefaults.path(home: "/tmp/vs-test.abc/home", accountHome: "/Users/me", temporary: temporary.path)
                == "/tmp/vs-test.abc/home/bench-defaults")
        let own = BenchDefaults.path(home: "/Users/me/", accountHome: "/Users/me", temporary: temporary.path)
        let folder = (own as NSString).deletingLastPathComponent
        #expect((own as NSString).lastPathComponent == "bench-defaults")
        #expect((folder as NSString).deletingLastPathComponent == temporary.path, "\(own)")
        #expect((folder as NSString).lastPathComponent.hasPrefix("vibeswitcher-bench."), "\(own)")
        #expect(FileManager.default.fileExists(atPath: folder), "\(own)")
        #expect(BenchDefaults.path(home: "/Users/me", accountHome: "/Users/me", temporary: temporary.path) != own, "each run its own folder")
    }

    /// main.swift points the defaults at scratch before it runs any bench: every `--…bench…` flag it runs is one of
    /// `BenchDefaults.flags`, and the redirect comes before the first of them.
    @Test func everyBenchFlagInMainRunsOnScratchDefaults() throws {
        let lines = try String(contentsOf: Self.repo.appendingPathComponent("Sources/VibeSwitcher/main.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
        let benches = lines.enumerated().compactMap { index, line in
            line.firstMatch(of: #/arguments\.firstIndex\(of: "(--[a-z-]*bench[a-z-]*)"\)/#).map { (index, String($0.1)) }
        }
        #expect(benches.count >= 5, "\(benches)")
        for (_, flag) in benches { #expect(BenchDefaults.flags.contains(flag), "main.swift runs \(flag) on the build's real defaults") }
        let redirect = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "BenchDefaults.redirect()" }
        #expect(redirect != nil, "main.swift doesn't call BenchDefaults.redirect()")
        if let redirect, let first = benches.first?.0 { #expect(redirect < first, "the redirect comes after \(benches[0].1)") }
    }
}

private final class Anchor {}
