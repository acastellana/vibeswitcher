import Foundation
import Testing
import VibePlatform

/// `stat`'s fields under the names both systems share, and a file's birth time. Files are a test's own, in the run's
/// scratch folder.
struct StatTests {
    /// A `Date()` outside a function body: on Linux it makes the compiler take `stat` from CoreFoundation's copy of the
    /// C library's headers in this file, where a member that another module's extension gave `stat` isn't found
    /// (Stat.swift). Nothing reads it: that this file compiles with it here is the test that what the tests below
    /// call is found there too.
    static let loaded = Date()

    static func status(_ path: String) throws -> stat {
        var info = stat()
        try #require(stat(path, &info) == 0, "stat \(path): errno \(errno)")
        return info
    }

    @Test func modifiedFollowsAWrite() throws {
        let folder = try TestScriptLinuxTests.scratch("stat")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first").path, second = folder.appendingPathComponent("second").path
        let before = Date().timeIntervalSince1970
        try Data(repeating: 0x61, count: 1234).write(to: URL(fileURLWithPath: first))
        try Data().write(to: URL(fileURLWithPath: second))
        let info = try Self.status(first), other = try Self.status(second)
        let after = Date().timeIntervalSince1970

        let modified = Double(Platform.Files.modified(info).tv_sec) + Double(Platform.Files.modified(info).tv_nsec) / 1e9
        #expect(modified >= before - 2 && modified <= after + 2, "modified \(modified), written between \(before) and \(after)")
        #expect((0..<1_000_000_000).contains(Platform.Files.modified(info).tv_nsec))
        #expect(Platform.Files.byteSize(info) == 1234)
        #expect(Platform.Files.byteSize(other) == 0)
        #expect(Platform.Files.inode(info) != Platform.Files.inode(other))

        // What Foundation says of the same file, which reads it by its own road.
        let attributes = try FileManager.default.attributesOfItem(atPath: first)
        #expect((attributes[.systemFileNumber] as? NSNumber)?.uint64Value == Platform.Files.inode(info))
        #expect((attributes[.size] as? NSNumber)?.int64Value == Platform.Files.byteSize(info))
    }

    /// A file's contents changing moves both times; its mode changing moves only `changed`.
    @Test func changedFollowsTheInodeAndModifiedDoesNot() throws {
        let folder = try TestScriptLinuxTests.scratch("stat")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("file").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: path))
        // An hour back, so that the change below is later whatever the clock's grain.
        let hourAgo = timeval(tv_sec: time(nil) - 3600, tv_usec: 0)
        #expect(utimes(path, [hourAgo, hourAgo]) == 0)
        let written = try Self.status(path)
        #expect(chmod(path, 0o600) == 0)
        let moded = try Self.status(path)

        let modified = (before: Platform.Files.modified(written), after: Platform.Files.modified(moded))
        let changed = (before: Platform.Files.changed(written), after: Platform.Files.changed(moded))
        #expect(modified.after.tv_sec == modified.before.tv_sec && modified.after.tv_nsec == modified.before.tv_nsec)
        #expect(modified.before.tv_sec < time(nil) - 3000)
        // utimes and chmod each change the inode now: `changed` isn't an hour back, and never goes back.
        #expect(changed.after.tv_sec > modified.before.tv_sec + 3000)
        #expect((changed.after.tv_sec, changed.after.tv_nsec) >= (changed.before.tv_sec, changed.before.tv_nsec))
    }

    /// The birth time is the file's own or "not known" (a file system that keeps none), never a time to come, and
    /// never later than the file's first write.
    @Test func birthTimeIsNilOrNotLaterThanNow() throws {
        let folder = try TestScriptLinuxTests.scratch("stat")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("born").path
        let before = Date().timeIntervalSince1970
        try Data("a".utf8).write(to: URL(fileURLWithPath: path))
        let info = try Self.status(path)
        let after = Date().timeIntervalSince1970

        if let born = Platform.Files.birthTime(path) {
            #expect(born >= before - 2 && born <= after + 2, "born \(born), made between \(before) and \(after)")
            #expect(born <= Double(Platform.Files.modified(info).tv_sec) + Double(Platform.Files.modified(info).tv_nsec) / 1e9 + 0.001)
        }
        #expect(Platform.Files.birthTime(folder.appendingPathComponent("never-made").path) == nil)
    }

    #if os(Linux)
    /// /proc keeps no birth time: "not known", not an error's garbage and not 1970.
    @Test func aFileSystemWithNoBirthTimesReadsNil() {
        #expect(Platform.Files.birthTime("/proc/self/status") == nil)
    }
    #endif
}
