import Foundation
import Testing
import VibePlatform

/// `Platform.Stdio`: a failed write says false and never traps; a log past its limit is rotated, at a start by its
/// name and while running through the descriptor that appends to it. Files are a test's own, in the run's scratch folder.
struct StdioTests {
    /// /dev/full fails every write with ENOSPC: what a full disk does to a log. `FileHandle.write(_:)` traps there.
    @Test func aWriteToAFullDeviceSaysFalseAndReturns() throws {
        let fd = open("/dev/full", O_WRONLY | O_CLOEXEC)
        try #require(fd >= 0, "open /dev/full: errno \(errno)")
        defer { close(fd) }
        #expect(!Platform.Stdio.write(fd, Data("a line\n".utf8)))
        #expect(Platform.Stdio.write(fd, Data()))
    }

    @Test func aWriteToAPipeWritesEveryByte() throws {
        var fds: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&fds) == 0)
        defer { close(fds[0]) }
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        #expect(Platform.Stdio.write(fds[1], data))
        close(fds[1])
        var read = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let got = Sys.read(fds[0], &buffer, buffer.count)
            if got <= 0 { break }
            read.append(contentsOf: buffer[..<got])
        }
        #expect(read == data)
    }

    @Test func rotateMovesOnlyALogPastItsLimit() throws {
        let folder = try TestScriptLinuxTests.scratch("stdio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("host.log").path
        try Data(repeating: 0x61, count: 100).write(to: URL(fileURLWithPath: log))
        #expect(!Platform.Stdio.rotate(path: log, limit: 100))
        #expect(FileManager.default.fileExists(atPath: log))
        try Data(repeating: 0x62, count: 101).write(to: URL(fileURLWithPath: log))
        #expect(Platform.Stdio.rotate(path: log, limit: 100))
        #expect(!FileManager.default.fileExists(atPath: log))
        #expect(try Data(contentsOf: URL(fileURLWithPath: log + ".1")).count == 101)
        #expect(!Platform.Stdio.rotate(path: log, limit: 100), "nothing there")
    }

    /// The descriptor two processes append to (a host and its server child): past the limit its bytes go to `.1` and the
    /// file is emptied in place, so the next write starts it again, through the same descriptor.
    @Test func capErrorKeepsOneCopyAndEmptiesTheFileInPlace() throws {
        let folder = try TestScriptLinuxTests.scratch("stdio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("host.log").path
        let fd = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(Platform.Stdio.write(fd, Data(repeating: 0x61, count: 50)))
        #expect(!Platform.Stdio.capError(fd, limit: 100), "under the limit")
        #expect(Platform.Stdio.write(fd, Data(repeating: 0x62, count: 60)))
        #expect(Platform.Stdio.capError(fd, limit: 100))
        #expect(try Data(contentsOf: URL(fileURLWithPath: log + ".1")) == Data(repeating: 0x61, count: 50) + Data(repeating: 0x62, count: 60))
        #expect(Platform.Stdio.write(fd, Data("next\n".utf8)))
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "next\n", "written from the start again")
    }

    /// A file not opened to append is left alone: emptied, its writer would go on at its old offset.
    @Test func capErrorLeavesAFileNotOpenedToAppend() throws {
        let folder = try TestScriptLinuxTests.scratch("stdio")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("plain.log").path
        let fd = open(log, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(Platform.Stdio.write(fd, Data(repeating: 0x61, count: 200)))
        #expect(!Platform.Stdio.capError(fd, limit: 100))
        #expect(!FileManager.default.fileExists(atPath: log + ".1"))
    }
}
