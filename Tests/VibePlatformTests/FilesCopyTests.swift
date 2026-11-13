import Foundation
import Testing
@testable import VibePlatform

/// `Platform.Files.copyKeepingModificationDate`: a copy whose modification date is its original's, as the session
/// host's launcher copy must be (its build is that date, `HostBuild.id`).
struct FilesCopyTests {
    @Test func aCopyKeepsItsOriginalsModificationDateAndBytes() throws {
        let folder = try TestScriptLinuxTests.scratch("files-copy")
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original").path, copy = folder.appendingPathComponent("copy").path
        try Data("synthetic\n".utf8).write(to: URL(fileURLWithPath: original))
        let then = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: then, .posixPermissions: 0o755], ofItemAtPath: original)

        try Platform.Files.copyKeepingModificationDate(atPath: original, toPath: copy)

        let attributes = try FileManager.default.attributesOfItem(atPath: copy)
        #expect((attributes[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } == 1_000_000)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(FileManager.default.contents(atPath: copy) == Data("synthetic\n".utf8))
    }

    /// Onto a name that's taken it fails, as FileManager's copy does, and leaves that file as it was.
    @Test func aCopyOntoATakenNameFails() throws {
        let folder = try TestScriptLinuxTests.scratch("files-copy-taken")
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original").path, taken = folder.appendingPathComponent("taken").path
        try Data("new\n".utf8).write(to: URL(fileURLWithPath: original))
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: taken))
        #expect(throws: (any Error).self) { try Platform.Files.copyKeepingModificationDate(atPath: original, toPath: taken) }
        #expect(FileManager.default.contents(atPath: taken) == Data("old\n".utf8))
    }
}
