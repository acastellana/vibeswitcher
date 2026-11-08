import Foundation
import Testing
@testable import VibeCore

struct ToolchainWatchTests {
    let temp = Scratch()
    final class Reader {
        var value = ToolchainSnapshot(developerDir: "/Applications/Xcode.app/Contents/Developer", swift: "Swift 6.4.1",
                                      sdkPath: "/SDKs/MacOSX27.sdk", sdkVersion: "27", commandLineTools: "27.0", xcodeExists: true)
    }

    @Test func eachChangedValueReportsBeforeAndAfterOnce() throws {
        let reader = Reader()
        let watch = ToolchainWatch(file: temp.url("toolchain.json"), read: { reader.value })
        #expect(watch.look() == nil)
        let changes: [(WritableKeyPath<ToolchainSnapshot, String>, String)] = [
            (\.swift, "Swift 6.4.2"), (\.sdkVersion, "27.2"), (\.sdkPath, "/SDKs/MacOSX27.2.sdk"),
            (\.developerDir, "/Applications/Xcode-beta.app/Contents/Developer"), (\.commandLineTools, "27.2")
        ]
        for (key, new) in changes {
            let old = reader.value[keyPath: key]
            reader.value[keyPath: key] = new
            let report = try #require(watch.look())
            #expect(report.contains("\(old) → \(new)"))
            #expect(report.contains("If builds fail"))
            #expect(watch.look() == nil)
        }
    }

    @Test func unchangedAndRestartedReadingsProduceNoReportButKeepTheNote() throws {
        let file = temp.url("toolchain.json")
        let reader = Reader()
        let watch = ToolchainWatch(file: file, read: { reader.value })
        #expect(watch.look() == nil)
        #expect(watch.look() == nil)
        reader.value.swift = "Swift 6.4.2"
        let report = try #require(watch.look())
        let restarted = ToolchainWatch(file: file, read: { reader.value })
        #expect(restarted.look() == nil)
        #expect(restarted.note == report)
        reader.value.sdkVersion = "28"
        let afterRestart = ToolchainWatch(file: file, read: { reader.value })
        #expect(try #require(afterRestart.look()).contains("27 → 28"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func commandLineToolsWithXcodeAreFlaggedAtStartupAndWhenXcodeAppears() throws {
        let reader = Reader()
        reader.value.developerDir = "/Library/Developer/CommandLineTools"
        reader.value.xcodeExists = false
        let watch = ToolchainWatch(file: temp.url("tools.json"), read: { reader.value })
        #expect(watch.look() == nil)
        reader.value.xcodeExists = true
        let report = try #require(watch.look())
        #expect(report.contains("SwiftUI macro plugins need Xcode"))
        #expect(report.contains("Command Line Tools are active"))
        #expect(watch.look() == nil)
        let firstLaunch = ToolchainWatch(file: temp.url("first.json"), read: { reader.value })
        #expect(firstLaunch.look() != nil)
        #expect(firstLaunch.look() == nil)
    }

    @Test func unavailableLookKeepsLastGoodBaseline() throws {
        for key in [\ToolchainSnapshot.developerDir, \.swift, \.sdkPath, \.sdkVersion, \.commandLineTools] {
            let reader = Reader()
            let file = temp.url(UUID().uuidString)
            let watch = ToolchainWatch(file: file, read: { reader.value })
            #expect(watch.look() == nil)
            let good = reader.value
            reader.value[keyPath: key] = "unavailable"
            #expect(watch.look() == nil)
            #expect(watch.note == nil)
            reader.value = good
            #expect(watch.look() == nil)
            reader.value.swift = "Swift 6.4.2"
            #expect(try #require(watch.look()).contains("Swift 6.4.1 → Swift 6.4.2"))
        }
    }

    @Test func missingPackageDoesNotSilenceSwiftChanges() throws {
        let reader = Reader()
        reader.value.commandLineTools = "unavailable"
        let watch = ToolchainWatch(file: temp.url("missing-package.json"), read: { reader.value })
        #expect(watch.look() == nil)
        reader.value.swift = "Swift 6.4.2"
        #expect(try #require(watch.look()).contains("Swift 6.4.1 → Swift 6.4.2"))
        #expect(watch.look() == nil)
        reader.value.commandLineTools = "27.0"
        #expect(watch.look() == nil) // First successful observation establishes this field's baseline.
        reader.value.commandLineTools = "27.1"
        #expect(try #require(watch.look()).contains("27.0 → 27.1"))
    }

    @Test func dismissBeforeFirstLookPreservesPersistedBaseline() throws {
        let reader = Reader()
        let file = temp.url("dismiss-before-look.json")
        let watch = ToolchainWatch(file: file, read: { reader.value })
        #expect(watch.look() == nil)
        reader.value.swift = "Swift 6.4.2"
        #expect(watch.look() != nil)
        let restarted = ToolchainWatch(file: file, read: { reader.value })
        restarted.dismissNote()
        #expect(restarted.note == nil)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["note"] == nil)
        reader.value.swift = "Swift 6.4.3"
        let again = ToolchainWatch(file: file, read: { reader.value })
        #expect(try #require(again.look()).contains("Swift 6.4.2 → Swift 6.4.3"))
    }

    @Test func driverAndTargetChangesDoNotReport() {
        let reader = Reader()
        reader.value.swift = "Apple Swift version 6.4.2 (swiftlang-1 clang-1)\nTarget: arm64-apple-macosx27.0"
        let watch = ToolchainWatch(file: temp.url("driver.json"), read: { reader.value })
        #expect(watch.look() == nil)
        reader.value.swift = "swift-driver version: 2\nApple Swift version 6.4.2 (swiftlang-2 clang-2)\nTarget: arm64-apple-macosx28.0"
        #expect(watch.look() == nil)
        #expect(watch.note == nil)
    }

    @Test func dismissedNoteStaysClearedAfterRestart() throws {
        let reader = Reader()
        let file = temp.url("dismiss.json")
        let watch = ToolchainWatch(file: file, read: { reader.value })
        #expect(watch.look() == nil)
        reader.value.swift = "Swift 6.4.2"
        #expect(watch.look() != nil)
        watch.dismissNote()
        #expect(watch.note == nil)
        let restarted = ToolchainWatch(file: file, read: { reader.value })
        #expect(restarted.look() == nil)
        #expect(restarted.note == nil)
    }

    @Test func oldNoteExpiresEvenWhenReadIsUnavailable() throws {
        let reader = Reader()
        let file = temp.url("expiry.json")
        var now = Date(timeIntervalSince1970: 100_000)
        let watch = ToolchainWatch(file: file, read: { reader.value }, now: { now })
        #expect(watch.look() == nil)
        reader.value.swift = "Swift 6.4.2"
        let report = try #require(watch.look())
        now.addTimeInterval(24 * 60 * 60 - 1)
        #expect(watch.look() == nil)
        #expect(watch.note == report)
        now.addTimeInterval(2)
        reader.value.swift = "unavailable"
        #expect(watch.look() == nil)
        #expect(watch.note == nil)
        reader.value.swift = "Swift 6.4.2"
        let restarted = ToolchainWatch(file: file, read: { reader.value }, now: { now })
        #expect(restarted.look() == nil)
        #expect(restarted.note == nil)
    }

    @Test func persistedOldNoteIsCleared() throws {
        let reader = Reader()
        let file = temp.url("persisted-expiry.json")
        let watch = ToolchainWatch(file: file, read: { reader.value })
        #expect(watch.look() == nil)
        reader.value.swift = "Swift 6.4.2"
        #expect(watch.look() != nil)
        var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        saved["notedAt"] = Date().addingTimeInterval(-25 * 60 * 60).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        let restarted = ToolchainWatch(file: file, read: { reader.value })
        #expect(restarted.look() == nil)
        #expect(restarted.note == nil)
        let again = ToolchainWatch(file: file, read: { reader.value })
        #expect(again.look() == nil)
        #expect(again.note == nil)
    }

    @Test func readerUsesOnlyQueriesAndShowsFailedQueries() {
        var calls: [(String, [String])] = []
        let snapshot = ToolchainSnapshot.read(run: { executable, args in
            calls.append((executable, args))
            if executable == "/usr/sbin/pkgutil" { return "package-id: com.apple.pkg.CLTools_Executables\nversion: 27.2\n" }
            if args.last == "-p" { return "/Library/Developer/CommandLineTools\n" }
            if args.suffix(2) == ["swift", "--version"] { return "Apple Swift version 6.4.2\nTarget: arm64-apple-macosx27.0\n" }
            if args.last == "--show-sdk-path" { return "/SDKs/MacOSX27.2.sdk\n" }
            return nil
        }, exists: { $0 == "/Applications/Xcode.app" })
        #expect(calls.map(\.0) == ["/usr/sbin/pkgutil", "/usr/bin/env", "/usr/bin/env", "/usr/bin/env", "/usr/bin/env"])
        #expect(calls[0].1 == ["--pkg-info", "com.apple.pkg.CLTools_Executables"])
        #expect(calls[1].1 == ["-u", "DEVELOPER_DIR", "/usr/bin/xcode-select", "-p"])
        #expect(calls.dropFirst(2).map(\.1) == [
            ["-u", "DEVELOPER_DIR", "-u", "SDKROOT", "-u", "TOOLCHAINS", "/usr/bin/xcrun", "swift", "--version"],
            ["-u", "DEVELOPER_DIR", "-u", "SDKROOT", "-u", "TOOLCHAINS", "/usr/bin/xcrun", "--show-sdk-path"],
            ["-u", "DEVELOPER_DIR", "-u", "SDKROOT", "-u", "TOOLCHAINS", "/usr/bin/xcrun", "--show-sdk-version"]])
        #expect(snapshot.commandLineTools == "27.2")
        #expect(snapshot.swift == "Apple Swift version 6.4.2")
        #expect(snapshot.sdkVersion == "unavailable")
        #expect(snapshot.needsXcode)
    }
}
