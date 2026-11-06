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
        #expect(snapshot.swift.contains("Apple Swift version 6.4.2"))
        #expect(snapshot.sdkVersion == "unavailable")
        #expect(snapshot.needsXcode)
    }
}
