import Foundation
import Testing
import VibePlatform

/// `Platform.Journal` (the engine plan's E1, EN-D15): an entry in journald's native form, one datagram, to a scratch
/// datagram socket standing in for journald. The Mac sends nothing.
struct JournalTests {
    @Test func anEntryCarriesIdsAndNoText() throws {
        let fields: [(name: String, value: String)] = [("SYSLOG_IDENTIFIER", "vibeswitcher"), ("MESSAGE", "vibeswitcher request stop"),
                                                       ("VIBESWITCHER_ACTION", "6f1c…"), ("VIBESWITCHER_NOTE", "two\nlines")]
        // The native form: NAME=value lines, a value with a newline as NAME, its length and its bytes.
        let datagram = try #require(Platform.Journal.encode(fields))
        let decoded = try #require(Platform.Journal.decode(datagram))
        #expect(decoded.map(\.name) == fields.map(\.name) && decoded.map(\.value) == fields.map(\.value))
        #expect(String(decoding: datagram, as: UTF8.self).hasPrefix("SYSLOG_IDENTIFIER=vibeswitcher\nMESSAGE=vibeswitcher request stop\n"))
        // journald's trusted fields can't be named by a sender, nor a name that isn't journald's shape.
        #expect(Platform.Journal.encode([("_SYSTEMD_CGROUP", "/init.scope")]) == nil)
        #expect(Platform.Journal.encode([("_UID", "0")]) == nil)
        #expect(Platform.Journal.encode([("message", "x")]) == nil)
        #expect(Platform.Journal.encode([("A=B", "x")]) == nil)
        #expect(!Platform.Journal.send([("_UID", "0")], to: "/nonexistent/journal.sock"))

        guard !Platform.CodeIdentity.isAvailable else {
            // The Mac has no journald: nothing goes.
            #expect(!Platform.Journal.send(fields, to: "/nonexistent/journal.sock"))
            return
        }
        #if os(Linux)
        // To a socket standing in for journald: the datagram arrives whole, once, with its sender.
        let folder = try SocketsTests.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("s").path
        let fd = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        try #require(fd >= 0)
        defer { close(fd) }
        let address = try #require(Platform.Sockets.unixAddress(path))
        try #require(Platform.Sockets.bindOwnerOnly(fd, to: address, path: path, mode: 0o600) == nil)
        Platform.Sockets.enableCredentials(fd)
        #expect(Platform.Journal.send(fields, to: path))
        var buffer = [UInt8](repeating: 0, count: 70_000)
        let (count, sender) = buffer.withUnsafeMutableBytes { Platform.Sockets.receive(fd, into: $0) }
        #expect(count == datagram.count)
        #expect(sender?.pid == getpid())
        #expect(Platform.Journal.decode(Data(buffer[0..<max(count, 0)]))?.map(\.value) == fields.map(\.value))
        // No socket there: false, nothing thrown.
        #expect(!Platform.Journal.send(fields, to: folder.appendingPathComponent("none.sock").path))
        #endif
    }
}
