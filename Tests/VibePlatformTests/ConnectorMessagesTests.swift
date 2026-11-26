import Foundation
import Testing
@testable import VibePlatform

/// A connector's messages (`Platform.Sockets.sendConnectorMessage`, `receiveConnectorMessage`, `receiveConnectorRequest`)
/// on both systems: Linux's `SOCK_SEQPACKET` keeps each message's edges; the Mac's stream frames a web message to its
/// newline, its descriptor on its first byte (the Mac's H1, docs/process/v2-mac-tasks.md item 9). On either, a one-byte
/// message, a web message with a socket riding on it and another one-byte message, all queued before any read, are read
/// as three, each with what rode on it alone; and what the Mac can't read whole fails, never taken as a message.
struct ConnectorMessagesTests {
    static let request = Array("web listen loopback 127.0.0.1 0".utf8)

    /// A listening socket, as the host's answer carries one.
    static func listening() throws -> Int32 {
        try Platform.TCP.listen(family: .ipv4, address: "127.0.0.1", port: 0, backlog: 1).get()
    }

    @Test func messagesQueuedTogetherAreReadOneByOneWithWhatRodeOnEach() throws {
        let (mine, theirs) = try #require(Platform.Sockets.pair(type: Platform.Sockets.connectorType))
        defer { Sys.close(mine); Sys.close(theirs) }
        let socket = try Self.listening()
        defer { Sys.close(socket) }
        var byte = UInt8(ascii: "c")
        #expect(Platform.Sockets.send(mine, &byte, 1) == 1)
        #expect(Platform.Sockets.sendConnectorMessage(Self.request, with: [socket], over: mine) == Self.request.count)
        #expect(Platform.Sockets.sendDescriptor(socket, over: mine))

        let first = try #require(Platform.Sockets.receiveConnectorMessage(over: theirs, count: 512, room: 1))
        #expect(first.bytes == [UInt8(ascii: "c")] && first.descriptors.isEmpty && !first.cut, "\(first)")
        let second = try #require(Platform.Sockets.receiveConnectorMessage(over: theirs, count: 512, room: 1))
        defer { second.descriptors.forEach { Sys.close($0) } }
        #expect(second.bytes == Self.request && second.descriptors.count == 1 && !second.cut, "\(second)")
        if let fd = second.descriptors.first {
            #expect(Platform.TCP.isListening(fd) && Platform.TCP.localPort(fd) == Platform.TCP.localPort(socket))
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        }
        let third = try #require(Platform.Sockets.receiveConnectorMessage(over: theirs, count: 512, room: 1))
        defer { third.descriptors.forEach { Sys.close($0) } }
        #expect(third.bytes.count == 1 && third.descriptors.count == 1, "\(third)")
    }

    /// The host's end (nonblocking): a connection's request, a web request and another, queued at once, read as three
    /// requests, each with its sender.
    @Test func theHostsEndReadsEachRequestAlone() throws {
        let (child, host) = try #require(Platform.Sockets.pair(type: Platform.Sockets.connectorType))
        defer { Sys.close(child); Sys.close(host) }
        Platform.Sockets.enableCredentials(host)
        _ = fcntl(host, F_SETFL, fcntl(host, F_GETFL) | O_NONBLOCK)
        var byte = UInt8(ascii: "c")
        #expect(Platform.Sockets.send(child, &byte, 1) == 1)
        #expect(Platform.Sockets.sendConnectorMessage(Self.request, with: [], over: child) == Self.request.count)
        #expect(Platform.Sockets.send(child, &byte, 1) == 1)
        var read: [[UInt8]] = []
        for _ in 0..<3 {
            var buffer = [UInt8](repeating: 0, count: 256)
            let (count, sender) = buffer.withUnsafeMutableBytes { Platform.Sockets.receiveConnectorRequest(host, into: $0) }
            #expect(count > 0 && sender?.pid == getpid(), "count \(count), errno \(errno)")
            read.append(Array(buffer.prefix(max(count, 0))))
        }
        #expect(read == [[UInt8(ascii: "c")], Self.request, [UInt8(ascii: "c")]])
        var buffer = [UInt8](repeating: 0, count: 256)
        let (count, _) = buffer.withUnsafeMutableBytes { Platform.Sockets.receiveConnectorRequest(host, into: $0) }
        #expect(count < 0 && errno == EAGAIN, "nothing more")
    }

    /// The Mac's framing refuses what it can't read whole: a message whose rest never comes (its sender gone after its
    /// first bytes) and one too long for the reader are failed reads (the host then ends the connector); a web message
    /// holding the frame's end, or a byte that isn't a framed message's start, is never sent.
    @Test(.enabled(if: Platform.Sockets.connectorType == Platform.Sockets.stream, "the Mac's framing"))
    func theMacsFramingFailsWhatItCantReadWhole() throws {
        #expect(Platform.Sockets.framedStart == Self.request[0])
        do {
            let (child, host) = try #require(Platform.Sockets.pair(type: Platform.Sockets.connectorType))
            defer { Sys.close(host) }
            _ = fcntl(host, F_SETFL, fcntl(host, F_GETFL) | O_NONBLOCK)
            let cut = Array("web listen".utf8)
            #expect(cut.withUnsafeBytes { Platform.Sockets.send(child, $0.baseAddress, $0.count) } == cut.count)
            Sys.close(child)
            var buffer = [UInt8](repeating: 0, count: 256)
            let (count, sender) = buffer.withUnsafeMutableBytes { Platform.Sockets.receiveConnectorRequest(host, into: $0) }
            #expect(count == -1 && errno == EBADMSG && sender == nil, "count \(count), errno \(errno)")
        }
        do {
            let (child, host) = try #require(Platform.Sockets.pair(type: Platform.Sockets.connectorType))
            defer { Sys.close(child); Sys.close(host) }
            _ = fcntl(host, F_SETFL, fcntl(host, F_GETFL) | O_NONBLOCK)
            let long = [UInt8(ascii: "w")] + [UInt8](repeating: UInt8(ascii: "x"), count: 300)
            #expect(Platform.Sockets.sendConnectorMessage(long, with: [], over: child) == long.count)
            var buffer = [UInt8](repeating: 0, count: 256)
            let (count, _) = buffer.withUnsafeMutableBytes { Platform.Sockets.receiveConnectorRequest(host, into: $0) }
            #expect(count == -1 && errno == EMSGSIZE, "count \(count), errno \(errno)")
        }
        do {
            let (child, host) = try #require(Platform.Sockets.pair(type: Platform.Sockets.connectorType))
            defer { Sys.close(child); Sys.close(host) }
            #expect(Platform.Sockets.sendConnectorMessage(Self.request + [Platform.Sockets.framedEnd, UInt8(ascii: "c")], with: [], over: child) == -1 && errno == EINVAL)
            #expect(Platform.Sockets.sendConnectorMessage([UInt8(ascii: "c")], with: [], over: child) == -1 && errno == EINVAL)
            // A web message read past its reader's room: cut, its rest dropped up to its end, the next message whole.
            #expect(Platform.Sockets.sendConnectorMessage(Self.request, with: [], over: child) == Self.request.count)
            #expect(Platform.Sockets.sendConnectorMessage(Self.request, with: [], over: child) == Self.request.count)
            let short = try #require(Platform.Sockets.receiveConnectorMessage(over: host, count: 5, room: 1))
            #expect(short.cut && short.bytes == Array(Self.request.prefix(5)), "\(short)")
            let whole = try #require(Platform.Sockets.receiveConnectorMessage(over: host, count: 512, room: 1))
            #expect(!whole.cut && whole.bytes == Self.request, "\(whole)")
        }
    }

    /// A flag two threads share.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var value: Bool { lock.withLock { on } }
        func set() { lock.withLock { on = true } }
    }

    /// F2 (the review of v2-mac-web-port): the host's end gives a framed request's rest one patience in all, never one
    /// for each byte. A sender dripping a byte every 0.25 s, 40 of them (10 s), never its end: the read fails (EBADMSG)
    /// while the drip still runs, so it held the host's queue for the patience, not for the drip.
    @Test(.enabled(if: Platform.Sockets.connectorType == Platform.Sockets.stream, "the Mac's framing"), .timeLimit(.minutes(1)))
    func theHostsEndGivesAFramesRestOnePatienceInAll() throws {
        let (child, host) = try #require(Platform.Sockets.pair(type: Platform.Sockets.connectorType))
        defer { Sys.close(host) }
        _ = fcntl(host, F_SETFL, fcntl(host, F_GETFL) | O_NONBLOCK)
        var first = Platform.Sockets.framedStart
        #expect(Platform.Sockets.send(child, &first, 1) == 1)
        let readerDone = Flag(), dripEnded = Flag()
        let ended = DispatchSemaphore(value: 0)
        let drip = Thread {
            for _ in 0..<40 where !readerDone.value {
                var byte = UInt8(ascii: "x")
                _ = Platform.Sockets.send(child, &byte, 1)
                usleep(250_000)
            }
            dripEnded.set()
            Sys.close(child)
            ended.signal()
        }
        drip.start()
        var buffer = [UInt8](repeating: 0, count: 256)
        let (count, sender) = buffer.withUnsafeMutableBytes { Platform.Sockets.receiveConnectorRequest(host, into: $0) }
        let code = errno
        let dripping = !dripEnded.value
        readerDone.set()
        ended.wait()
        #expect(count == -1 && code == EBADMSG && sender == nil, "count \(count), errno \(code)")
        #expect(dripping, "the host's read waited for the whole drip: a patience for each byte")
    }

    /// F3 (the review's `childEndACutFrameOnABlockingSocket`): on a socket that blocks, as the server's end of its
    /// connector does, a framed answer cut short while its sender is still there is read as cut once its rest doesn't
    /// come within the patience, not waited for for good.
    @Test(.enabled(if: Platform.Sockets.connectorType == Platform.Sockets.stream, "the Mac's framing"), .timeLimit(.minutes(1)))
    func aCutFrameOnABlockingSocketIsCut() throws {
        let (host, child) = try #require(Platform.Sockets.pair(type: Platform.Sockets.connectorType))
        defer { Sys.close(host); Sys.close(child) }
        #expect(fcntl(child, F_GETFL) & O_NONBLOCK == 0, "a socket that blocks")
        let answer = Array("web ok listen loopback 127.0.0.1 0".utf8)
        #expect(answer.prefix(10).withUnsafeBytes { Platform.Sockets.send(host, $0.baseAddress, $0.count) } == 10)
        let got = try #require(Platform.Sockets.receiveConnectorMessage(over: child, count: 512, room: 1))
        #expect(got.cut && got.descriptors.isEmpty, "\(got)")
    }

    /// F4 (the review of v2-mac-web-port): a message carrying more descriptors than a message may (`room`, and past the 8
    /// a reader once had control room for, when the kernel cut what it reported but installed every one): each that
    /// arrived is closed, none left open in the reader, the message `cut` and carrying none. Each descriptor sent is a
    /// pipe's write end: once this side's copies and the pair are closed, its read end hangs up only when no copy is open.
    @Test(.enabled(if: Platform.Sockets.connectorType == Platform.Sockets.stream, "the Mac's framing"), arguments: [9, 60])
    func descriptorsPastTheRoomAreAllClosed(count: Int) throws {
        let (host, child) = try #require(Platform.Sockets.pair(type: Platform.Sockets.connectorType))
        var reads: [Int32] = [], writes: [Int32] = []
        for _ in 0..<count {
            var ends: [Int32] = [-1, -1]
            try #require(pipe(&ends) == 0)
            reads.append(ends[0])
            writes.append(ends[1])
        }
        defer { reads.forEach { Sys.close($0) } }
        #expect(SocketsTests.sendSeveral(writes, over: host))
        writes.forEach { Sys.close($0) }
        let got = try #require(Platform.Sockets.receiveConnectorMessage(over: child, count: 512, room: 1))
        #expect(got.cut && got.descriptors.isEmpty, "\(got)")
        // The pair closed first, so nothing still in flight on it holds a write end: only the reader could.
        Sys.close(host)
        Sys.close(child)
        for read in reads {
            var waiting = pollfd(fd: read, events: Int16(POLLIN), revents: 0)
            #expect(poll(&waiting, 1, 10_000) == 1 && waiting.revents & Int16(POLLHUP) != 0, "a write end left open in the reader")
        }
    }
}

