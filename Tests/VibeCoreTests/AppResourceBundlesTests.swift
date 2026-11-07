import Foundation
import Testing

/// The resource bundles scripts/build-app.sh puts in the app (scripts/lib/resource-bundles.sh): SwiftPM's own and the
/// app's dependencies' (SwiftTerm_SwiftTerm.bundle, its Metal shaders), never a test target's. 2026-11-07 every
/// $BIN/*.bundle went in, VibeSwitcher_VibeHostTests.bundle and its fixtures too, and the --install copy into
/// /Applications failed on one of those fixtures.
struct AppResourceBundlesTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// A scratch build folder holding the app's bundles and test targets' ones: only the app's land in Resources.
    @Test func theAppsResourcesGetItsOwnBundlesAndNoTestBundle() throws {
        let root = temp.url("bundles")
        let bin = root.appendingPathComponent("release"), resources = root.appendingPathComponent("VibeSwitcher.app/Contents/Resources")
        let own = ["SwiftTerm_SwiftTerm.bundle", "VibeSwitcher_VibeCore.bundle"]
        let tests = ["VibeSwitcher_VibeHostTests.bundle", "VibeSwitcher_VibeSwitcherTests.bundle"]
        for name in own + tests {
            let file = bin.appendingPathComponent("\(name)/Contents/Resources/Fixtures/a.raw")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try name.write(to: file, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -euo pipefail; source \"$1\"; copy_resource_bundles \"$2\" \"$3\"", "bash",
                             Self.repo.appendingPathComponent("scripts/lib/resource-bundles.sh").path, bin.path, resources.path]
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, Comment(rawValue: output))
        let copied = try FileManager.default.contentsOfDirectory(atPath: resources.path).sorted()
        #expect(copied == own.sorted())
        #expect(!copied.contains { $0.hasSuffix("Tests.bundle") })
        let shader = resources.appendingPathComponent("SwiftTerm_SwiftTerm.bundle/Contents/Resources/Fixtures/a.raw")
        #expect((try? String(contentsOf: shader, encoding: .utf8)) == "SwiftTerm_SwiftTerm.bundle", "a bundle's contents came with it")
    }

    /// build-app.sh copies the bundles through that helper, not a loop over every $BIN/*.bundle.
    @Test func buildAppCopiesBundlesThroughTheHelper() throws {
        let script = try String(contentsOf: Self.repo.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("source scripts/lib/resource-bundles.sh"))
        #expect(script.contains("copy_resource_bundles \"$BIN\" \"$APP/Contents/Resources\""))
        #expect(!script.contains("for bundle in \"$BIN\"/*.bundle"))
    }
}
