#if canImport(Darwin)
import Foundation

// A connector's messages on the Mac (the Mac's H1, docs/process/v2-mac-tasks.md item 9): its pair is a stream (the
// Mac's Unix domain has no SOCK_SEQPACKET: `socketpair` refuses it, EPROTONOSUPPORT), which keeps no message's edges,
// and a read can run on past one message into the next (measured on this Mac: bytes sent after a descriptor's message
// came in the same read as it). So a message is framed here:
//
// - a byte other than `framedStart` is a message of one byte, as every message on the Mac's connector was before (a
//   connection's request, `HostConnector.connect`'s, and its answer, one byte carrying a descriptor);
// - a message that starts with `framedStart` (`w`, the first byte of every web message, `HostWebListen`) runs to its
//   `framedEnd` (a newline, which none of its words holds), and what rides on it rides on its first byte, sent with it in
//   one call.
//
// Each side reads a framed message one byte at a time, so a read never takes the next message's bytes, nor a descriptor
// that rides on another message than the one read. Anything else (a message too long, cut, or a descriptor on a byte
// that isn't a message's first) fails: never taken as a message.
extension Platform.Sockets {
    /// How long a framed message's rest may take, all of it, once its first byte has come (one deadline for the frame,
    /// never one for each byte: a sender dripping a byte at a time holds its reader no longer than this). Its sender wrote
    /// it in one call, so it is there at once unless the sender is broken.
    static let framedRestPatience: TimeInterval = 1

    /// Sends `bytes`, a framed message (it starts with `framedStart` and holds no `framedEnd`), with `fds` riding on its
    /// first byte, over the stream connector `socket`: the message and its end in one call, then what that call left,
    /// waited for. `bytes.count` once all of it went; -1 and `errno` when nothing went (EAGAIN: the socket doesn't block
    /// and its buffer is full; the caller may send it again whole), or when it was cut after its first bytes went (EIO,
    /// or the failed call's errno: the peer reads a cut message, which it never takes). EINVAL for bytes that aren't a
    /// framed message, nothing sent.
    public static func sendConnectorMessage(_ bytes: [UInt8], with fds: [Int32], over socket: Int32) -> Int {
        guard bytes.first == framedStart, !bytes.contains(framedEnd), fds.count <= descriptorRoom else {
            errno = EINVAL
            return -1
        }
        noSigPipe(socket: socket)
        let frame = bytes + [framedEnd]
        let first = sendFirst(frame, with: fds, over: socket)
        guard first > 0 else { return -1 }
        let deadline = Platform.Clock.awakeSeconds() + framedRestPatience
        var sent = first
        while sent < frame.count {
            let more = frame[sent...].withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
            if more > 0 {
                sent += more
                continue
            }
            if more < 0, errno == EINTR { continue }
            if more < 0, errno == EAGAIN, waitFor(socket, Int16(POLLOUT), until: deadline) { continue }
            if more == 0 { errno = EIO }
            return -1
        }
        return bytes.count
    }

    /// One `sendmsg` of `frame` with `fds` in an `SCM_RIGHTS` message on it (none when empty): how many bytes went, or
    /// -1 and `errno`.
    private static func sendFirst(_ frame: [UInt8], with fds: [Int32], over socket: Int32) -> Int {
        let offset = controlDataOffset
        let length = offset + fds.count * MemoryLayout<Int32>.size
        var control = [UInt8](repeating: 0, count: fds.isEmpty ? 0 : controlAligned(length))
        if !fds.isEmpty {
            control.withUnsafeMutableBytes { raw in
                var header = cmsghdr()
                header.cmsg_len = numericCast(length)
                header.cmsg_level = SOL_SOCKET
                header.cmsg_type = SCM_RIGHTS
                withUnsafeBytes(of: &header) { raw.copyMemory(from: $0) }
                fds.withUnsafeBytes { UnsafeMutableRawBufferPointer(rebasing: raw[offset..<length]).copyMemory(from: $0) }
            }
        }
        var frame = frame
        var sent = -1
        frame.withUnsafeMutableBytes { bytes in
            var vector = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
            withUnsafeMutablePointer(to: &vector) { vectorPointer in
                control.withUnsafeMutableBytes { raw in
                    var message = msghdr()
                    message.msg_iov = vectorPointer
                    message.msg_iovlen = 1
                    message.msg_control = raw.isEmpty ? nil : raw.baseAddress
                    message.msg_controllen = numericCast(raw.count)
                    repeat { sent = sendmsg(socket, &message, 0) } while sent < 0 && errno == EINTR
                }
            }
        }
        return sent
    }

    /// The next message on the stream connector `socket` and what rode on it (each descriptor close-on-exec at once):
    /// a byte other than `framedStart` alone (a connection's answer, its descriptor with it), or a framed message's bytes
    /// without its end. `cut` when the message ran past `count` bytes (its rest read and dropped up to its end), when
    /// its rest didn't come, or when a descriptor rode on a byte after its first (closed); more than `room` descriptors
    /// are all closed, and `cut`. At the stream's end, no bytes and no descriptors (the caller asks `peerHasGone`).
    /// nil and `errno` when the first read fails (EAGAIN: nothing yet on a socket that doesn't block).
    public static func receiveConnectorMessage(over socket: Int32, count: Int, room: Int) -> Received? {
        guard let first = receiveByte(over: socket) else { return nil }
        guard let byte = first.byte else { return Received(bytes: [], descriptors: first.fds, cut: false) }
        var bytes = [byte]
        var fds = first.fds
        var cut = first.cut
        if byte == framedStart {
            while true {
                guard let next = receiveByte(over: socket) ?? (errno == EAGAIN && waitFor(socket, Int16(POLLIN), until: Platform.Clock.awakeSeconds() + framedRestPatience) ? receiveByte(over: socket) : nil),
                      let more = next.byte else {
                    // Its end, a failed read, or its rest never came.
                    cut = true
                    break
                }
                if !next.fds.isEmpty || next.cut {
                    next.fds.forEach { close($0) }
                    cut = true
                }
                if more == framedEnd { break }
                if bytes.count < max(count, 1) { bytes.append(more) } else { cut = true }
            }
        }
        if fds.count > room {
            fds.forEach { close($0) }
            fds = []
            cut = true
        }
        return Received(bytes: bytes, descriptors: fds, cut: cut)
    }

    /// One byte read from `socket` with what rides on it, each descriptor made close-on-exec: `byte` nil at the stream's
    /// end. nil and `errno` when the read fails.
    private static func receiveByte(over socket: Int32) -> (byte: UInt8?, fds: [Int32], cut: Bool)? {
        let room = controlAligned(controlDataOffset + descriptorRoom * MemoryLayout<Int32>.size)
        var control = [UInt8](repeating: 0, count: room)
        var byte: UInt8 = 0
        var got = -1
        var flags: Int32 = 0
        var length = 0
        withUnsafeMutablePointer(to: &byte) { bytePointer in
            var vector = iovec(iov_base: UnsafeMutableRawPointer(bytePointer), iov_len: 1)
            withUnsafeMutablePointer(to: &vector) { vectorPointer in
                control.withUnsafeMutableBytes { raw in
                    var message = msghdr()
                    message.msg_iov = vectorPointer
                    message.msg_iovlen = 1
                    message.msg_control = raw.baseAddress
                    message.msg_controllen = numericCast(raw.count)
                    repeat { got = recvmsg(socket, &message, 0) } while got < 0 && errno == EINTR
                    flags = message.msg_flags
                    length = Int(message.msg_controllen)
                }
            }
        }
        guard got >= 0 else { return nil }
        let carried = descriptors(in: control, length: min(length, control.count))
        for fd in carried { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (got > 0 ? byte : nil, carried, flags & MSG_CTRUNC != 0)
    }

    /// The host's end of a stream connector (nonblocking) reading its child's next request into `buffer`: one byte other
    /// than `framedStart` (a connection's request), or a framed message without its end, read a byte at a time, so the
    /// next request stays unread. Its sender is `peerToken` once the message is read, when it is the same image as after
    /// its first byte (else nil: refused). As `receive(_:into:)` otherwise: 0 at the stream's end, -1 and `errno` when the
    /// first read fails (EAGAIN: nothing yet). A framed message that doesn't fit `buffer` is -1 with EMSGSIZE, one whose
    /// rest doesn't come (its end, a failed read, not all of it within `framedRestPatience`) -1 with EBADMSG: the caller ends
    /// the connector, as on any failed read, since what follows on it can't be told apart any more.
    public static func receiveConnectorRequest(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> (count: Int, sender: Platform.PeerToken?) {
        guard let base = buffer.baseAddress, buffer.count > 0 else {
            errno = EINVAL
            return (-1, nil)
        }
        var first = -1
        repeat { first = read(fd, base, 1) } while first < 0 && errno == EINTR
        guard first > 0 else { return (first, nil) }
        let sender = peerToken(fd)
        guard buffer[0] == framedStart else { return (1, sender) }
        let deadline = Platform.Clock.awakeSeconds() + framedRestPatience
        var count = 1
        while true {
            let got = read(fd, base + count, 1)
            if got == 1 {
                if buffer[count] == framedEnd { break }
                count += 1
                guard count < buffer.count else {
                    errno = EMSGSIZE
                    return (-1, nil)
                }
                continue
            }
            if got < 0, errno == EINTR { continue }
            if got < 0, errno == EAGAIN, waitFor(fd, Int16(POLLIN), until: deadline) { continue }
            errno = EBADMSG
            return (-1, nil)
        }
        guard let sender, let last = peerToken(fd), last.sameImage(as: sender) else { return (count, nil) }
        return (count, sender)
    }

    /// Whether `socket` became ready for `events` before `deadline` (`Platform.Clock.awakeSeconds()`'s; an error or a
    /// hang-up counts as ready: the next call says it). False once the deadline has passed, ready or not.
    private static func waitFor(_ socket: Int32, _ events: Int16, until deadline: TimeInterval) -> Bool {
        var waiting = pollfd(fd: socket, events: events, revents: 0)
        var ready: Int32
        repeat {
            let left = deadline - Platform.Clock.awakeSeconds()
            guard left > 0 else { return false }
            ready = poll(&waiting, 1, Int32(min((left * 1_000).rounded(.up), Double(Int32.max))))
        } while ready < 0 && errno == EINTR
        return ready > 0
    }
}
#endif
