#if canImport(Darwin)
// The Mac's descriptors passed over a Unix socket: one byte carrying one descriptor (SCM_RIGHTS), as Linux's, for the
// server child's connector on the Mac (the node on the Mac's step 3), whose pair is a stream (`connectorType`: the Mac's
// Unix domain has no SOCK_SEQPACKET). The control message is laid out here, in Swift: the Mac's package has no C shim,
// and Swift doesn't see the CMSG_ macros. Its layout is the Mac's `<sys/socket.h>`: a `cmsghdr` (12 bytes) and its
// data, each rounded up to 4 bytes (`__DARWIN_ALIGN32`). Written on Linux and checked on the hosted Mac
// (`SocketsTests.aDescriptorPassesOverAConnectorPair`); docs/process/v2-mac-tasks.md.
extension Platform.Sockets {
    /// The type of a connector's pair: a stream on the Mac. Each request on it is one byte, and each answer one byte
    /// carrying one descriptor, so no message boundary is needed; its end reads as 0 bytes, and only its end does.
    public static var connectorType: Int32 { stream }

    /// `size` rounded up to the Mac's control alignment, 4 bytes.
    static func controlAligned(_ size: Int) -> Int { (size + 3) & ~3 }

    /// Where a control message's data begins, `CMSG_DATA`'s offset: the header, rounded up.
    static var controlDataOffset: Int { controlAligned(MemoryLayout<cmsghdr>.size) }

    /// Sends `fd` over the Unix socket `socket`: one byte carrying it (`SCM_RIGHTS`), with no SIGPIPE when the peer has
    /// gone (`SO_NOSIGPIPE` set on `socket`: EPIPE). True when the byte went; false and `errno` otherwise. `fd` stays
    /// open here, and the caller closes it when the peer's copy is the only one it means to leave.
    public static func sendDescriptor(_ fd: Int32, over socket: Int32) -> Bool {
        sendDescriptors([fd], over: socket)
    }

    /// `sendDescriptor(_:over:)` with every one of `fds` on its one byte (the tests' message carrying several).
    static func sendDescriptors(_ fds: [Int32], over socket: Int32) -> Bool {
        noSigPipe(socket: socket)
        let offset = controlDataOffset
        let length = offset + fds.count * MemoryLayout<Int32>.size
        var control = [UInt8](repeating: 0, count: controlAligned(length))
        control.withUnsafeMutableBytes { raw in
            var header = cmsghdr()
            header.cmsg_len = numericCast(length)
            header.cmsg_level = SOL_SOCKET
            header.cmsg_type = SCM_RIGHTS
            withUnsafeBytes(of: &header) { raw.copyMemory(from: $0) }
            fds.withUnsafeBytes { UnsafeMutableRawBufferPointer(rebasing: raw[offset..<length]).copyMemory(from: $0) }
        }
        var byte = UInt8(ascii: "d")
        var sent = -1
        withUnsafeMutablePointer(to: &byte) { bytePointer in
            var vector = iovec(iov_base: UnsafeMutableRawPointer(bytePointer), iov_len: 1)
            withUnsafeMutablePointer(to: &vector) { vectorPointer in
                control.withUnsafeMutableBytes { raw in
                    var message = msghdr()
                    message.msg_iov = vectorPointer
                    message.msg_iovlen = 1
                    message.msg_control = raw.baseAddress
                    message.msg_controllen = numericCast(raw.count)
                    repeat { sent = sendmsg(socket, &message, 0) } while sent < 0 && errno == EINTR
                }
            }
        }
        return sent == 1
    }

    /// The most descriptors one message is read with: room for more than one, so that a message carrying several is
    /// read whole, each closed, and refused (EBADMSG), rather than cut by the kernel.
    static let descriptorRoom = 8

    /// The descriptor the next message on `socket` carries, close-on-exec right after its arrival (the Mac has no
    /// `MSG_CMSG_CLOEXEC`: a spawn on another thread in between that doesn't start with `POSIX_SPAWN_CLOEXEC_DEFAULT`,
    /// as `Platform.Spawn` does, would inherit it). Exactly one is taken: a message carrying none or more than one, or
    /// one the kernel cut (`MSG_CTRUNC`), gives nil (`errno` EBADMSG), and every descriptor it carried is closed. nil
    /// too at the end of the stream (EPIPE: the peer has closed or shut its end) and when the read fails (its `errno`:
    /// EAGAIN on a socket that doesn't block and has nothing yet). Waits for a message as the socket's reads do.
    public static func receiveDescriptor(over socket: Int32) -> Int32? {
        let offset = controlDataOffset
        let room = controlAligned(offset + descriptorRoom * MemoryLayout<Int32>.size)
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
        guard got > 0 else {
            carried.forEach { close($0) }
            errno = EPIPE
            return nil
        }
        guard carried.count == 1, flags & MSG_CTRUNC == 0 else {
            carried.forEach { close($0) }
            errno = EBADMSG
            return nil
        }
        return carried[0]
    }

    /// The descriptors the `SCM_RIGHTS` messages in `control` (its first `length` bytes) carry, in order.
    static func descriptors(in control: [UInt8], length: Int) -> [Int32] {
        let headerSize = MemoryLayout<cmsghdr>.size
        let offset = controlDataOffset
        var found: [Int32] = []
        var at = 0
        control.withUnsafeBytes { raw in
            while at + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: at, as: cmsghdr.self)
                let size = Int(header.cmsg_len)
                guard size >= offset, at + size <= length else { break }
                if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
                    var data = at + offset
                    while data + MemoryLayout<Int32>.size <= at + size {
                        found.append(raw.loadUnaligned(fromByteOffset: data, as: Int32.self))
                        data += MemoryLayout<Int32>.size
                    }
                }
                at += controlAligned(size)
            }
        }
        return found
    }

    /// Nothing is read, and nil: the Mac has no door.
    public static func receiveDescriptorAndSender(over socket: Int32) -> (descriptor: Int32, sender: pid_t)? { nil }

    /// Whether `socket` reports a hang-up or an error (`POLLHUP`, `POLLERR`, `POLLNVAL`): a poll that doesn't wait; a
    /// failed poll says gone. The Mac's poll reports a hang-up once the peer has closed its end or shut it for writing
    /// (the read filter's end of file), so on a stream connector this answers what Linux's `POLLRDHUP` does.
    public static func peerHasGone(_ socket: Int32) -> Bool {
        var waiting = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        var ready: Int32
        repeat { ready = poll(&waiting, 1, 0) } while ready < 0 && errno == EINTR
        return ready < 0 || (ready > 0 && waiting.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0)
    }

    /// Waits until `socket`'s peer can send nothing more (it closed its end, or shut it for writing), reading nothing:
    /// true then, and when it can't be watched; false when `socket` isn't open. The server child's watch on its
    /// connector (`ServerStart.watchConnector`). A kqueue's read filter, edge-triggered (`EV_CLEAR`), so a byte that
    /// arrives for another thread to read (the host's reply to `HostConnector.connect`) wakes it once and it waits on,
    /// and its end of file (`EV_EOF`) ends the wait. (The Mac's `poll` asked for no event registers no filter, so it
    /// never wakes, as Linux's does for a hang-up.)
    public static func waitUntilPeerHasGone(_ socket: Int32) -> Bool {
        let queue = kqueue()
        guard queue >= 0 else { return true }
        defer { close(queue) }
        var change = kevent(ident: UInt(socket), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { return errno != EBADF }
        while true {
            var event = kevent()
            let count = kevent(queue, nil, 0, &event, 1, nil)
            if count < 0, errno == EINTR { continue }
            if count < 0 { return true }
            if count > 0, event.flags & UInt16(EV_EOF | EV_ERROR) != 0 { return true }
        }
    }

    /// Nothing is sent, and -1 with ENOTSUP: the Mac has no session sandbox and so no door.
    public static func send(_ bytes: [UInt8], with fds: [Int32], over socket: Int32) -> Int {
        errno = ENOTSUP
        return -1
    }

    /// As Linux's (SocketDescriptors+Linux.swift).
    public struct Received: Sendable {
        public var bytes: [UInt8]
        public var descriptors: [Int32]
        public var cut: Bool
    }

    /// Nothing is read, and nil with ENOTSUP: the Mac has no door.
    public static func receive(over socket: Int32, count: Int, room: Int) -> Received? {
        errno = ENOTSUP
        return nil
    }
}
#endif
