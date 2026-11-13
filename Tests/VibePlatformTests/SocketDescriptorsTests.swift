import Foundation
import Testing
@testable import VibePlatform

#if os(Linux)
/// The test binary's helper mode, for descriptors passed over a pair and senders that name themselves: started again
/// with `SocketsTests.passVariable` set to "WHAT:SOCKET:FD" (SOCKET its end of a pair, FD a pipe's writing end, both
/// handed down), this binary sends one message on SOCKET before any test of its own, closes FD, stays until the test
/// closes its end (so its line of /proc is there while the test reads who sent), and exits 0. WHAT is a count: a
/// message carrying that many copies of FD, `Platform.Sockets.sendDescriptor` for one; or a claim (`vibe_send_claiming`)
/// of one byte, "m", with credentials naming this process ("claim"), or naming its parent, the test ("claimParent"), or
/// a uid not its own ("claimUid"). A claim the kernel refuses (EPERM) is followed by a plain "r", with no credentials
/// of its own making, so that the test reads the refusal rather than waits for nothing. It exits 2 when it can't read
/// the variable, 4 when a send failed otherwise.
private func passOverThePairIfAsked() {
    guard let asked = getenv(SocketsTests.passVariable).map({ String(cString: $0) }) else { return }
    let words = asked.split(separator: ":").map(String.init)
    guard words.count == 3, let socket = Int32(words[1]), let fd = Int32(words[2]) else { _exit(2) }
    let claims: [String: (pid_t, uid_t)] = [
        "claim": (getpid(), getuid()), "claimParent": (getppid(), getuid()), "claimUid": (getpid(), getuid() &+ 1),
    ]
    if let (pid, uid) = claims[words[0]] {
        if vibe_send_claiming(socket, "m", 1, pid, uid, getgid()) != 1 {
            guard errno == EPERM, send(socket, "r", 1, Int32(MSG_NOSIGNAL)) == 1 else { _exit(4) }
        }
    } else if let count = Int(words[0]) {
        let sent = count == 1 ? Platform.Sockets.sendDescriptor(fd, over: socket)
            : SocketsTests.sendRights(Array(repeating: fd, count: count), over: socket)
        guard sent else { _exit(4) }
    } else {
        _exit(2)
    }
    if fd >= 0 { close(fd) }
    var byte: UInt8 = 0
    while true {
        let count = read(socket, &byte, 1)
        if count == 0 || (count < 0 && errno != EINTR) { break }
    }
    _exit(0)
}

// Runs as the test bundle loads, as `refuseTheAccountRoot` does (TestSupport.swift).
@_used @_section(".init_array")
private let passOverThePairWhenAsked: @convention(c) () -> Void = { passOverThePairIfAsked() }

/// `Platform.Sockets.sendDescriptor` and `receiveDescriptor`: a descriptor passed from another process over a
/// `SOCK_SEQPACKET` pair, as the server child's connector will be; and a sender that names itself, the control for the
/// host's per-read check of who sent a message. The other process is this binary in its helper mode
/// (`passOverThePairIfAsked`), and is reaped.
extension SocketsTests {
    static let passVariable = "VIBE_SOCKETS_TEST_PASS"

    /// A `SOCK_SEQPACKET` pair, both ends close-on-exec from its making: only the end a spawn keeps reaches its child.
    static func seqpacketPair() throws -> (test: Int32, helper: Int32) {
        var ends: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &ends) == 0 else {
            throw Failure(what: "no seqpacket pair: \(errno)")
        }
        return (ends[0], ends[1])
    }

    /// Sends one byte over `socket` carrying `fds` (none when it's empty) in one control message, laid out by hand: what
    /// `sendDescriptor` never sends. As 64-bit Linux lays it out: the length (16 of header, 4 a descriptor) in 8 bytes,
    /// the level and the type (`SCM_RIGHTS`, 1) in 4 each, the descriptors, then up to 8 bytes' alignment.
    static func sendRights(_ fds: [Int32], over socket: Int32) -> Bool {
        let length = 16 + 4 * fds.count
        var control = [UInt8](repeating: 0, count: fds.isEmpty ? 0 : (length + 7) & ~7)
        if !fds.isEmpty {
            control.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: UInt64(length), toByteOffset: 0, as: UInt64.self)
                raw.storeBytes(of: SOL_SOCKET, toByteOffset: 8, as: Int32.self)
                raw.storeBytes(of: Int32(1), toByteOffset: 12, as: Int32.self)
                for (index, fd) in fds.enumerated() { raw.storeBytes(of: fd, toByteOffset: 16 + 4 * index, as: Int32.self) }
            }
        }
        var byte: UInt8 = 0x64
        let sent = withUnsafeMutableBytes(of: &byte) { data in
            control.withUnsafeMutableBytes { control in
                var piece = iovec(iov_base: data.baseAddress, iov_len: 1)
                return withUnsafeMutablePointer(to: &piece) { piece in
                    var message = msghdr()
                    message.msg_iov = piece
                    message.msg_iovlen = 1
                    message.msg_control = control.isEmpty ? nil : control.baseAddress
                    message.msg_controllen = numericCast(control.count)
                    return sendmsg(socket, &message, Int32(MSG_NOSIGNAL))
                }
            }
        }
        return sent == 1
    }

    /// Starts this binary in its helper mode (`passOverThePairIfAsked`) with `what`, keeping `socket` and `fd` (both
    /// then closed here, so the helper's are the only copies this process made).
    static func passer(_ what: String, socket: Int32, fd: Int32 = -1) throws -> pid_t {
        defer {
            Sys.close(socket)
            if fd >= 0 { Sys.close(fd) }
        }
        // The helper never gets as far as a test; one that did would not start another.
        try #require(getenv(passVariable) == nil)
        let binary = try #require(Bundle.main.executablePath)
        var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(passVariable)=\(what):\(socket):\(fd)"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.keep = fd >= 0 ? [socket, fd] : [socket]
        return try spawn.start().get()
    }

    /// Whether `fd` has something to read, or its end, within `hangGuard`: a helper that never sends fails the test
    /// rather than holding the run.
    static func readable(_ fd: Int32) -> Bool {
        var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var ready: Int32 = -1
        repeat { ready = poll(&waiting, 1, Int32(TestScriptLinuxTests.hangGuard * 1_000)) } while ready < 0 && errno == EINTR
        return ready == 1
    }

    /// `Platform.Sockets.receiveDescriptor`, or with `room` the shim's tests-only form that gives the kernel only that
    /// many bytes of control data to fill (`vibe_receive_descriptor_in_room`).
    static func receiveDescriptor(over socket: Int32, room: Int?) -> Int32? {
        guard let room else { return Platform.Sockets.receiveDescriptor(over: socket) }
        let fd = vibe_receive_descriptor_in_room(socket, room)
        return fd >= 0 ? fd : nil
    }

    /// Room for exactly one descriptor, as 64-bit Linux lays it out: 16 of header and 4 a descriptor
    /// (`CMSG_LEN(sizeof(int))`). A second would need 4 more.
    static let roomForOne = 20

    /// Closes the test's end of the pair, which ends the helper, and reaps it: how it ended.
    static func finish(_ helper: pid_t, closing testEnd: Int32) -> SpawnTests.Ended {
        Sys.close(testEnd)
        return SpawnTests.ended(helper)
    }

    /// With the receiver's whole room, and with room for that one only: the room alone refuses nothing (the control
    /// for `aMessageCutToOneDescriptorGivesNone`).
    @Test(arguments: [nil, roomForOne]) func aDescriptorSentOverAPairArrivesClosedOnExec(room: Int?) throws {
        let pair = try Self.seqpacketPair()
        let pipe = try SpawnTests.newPipe()
        defer { Sys.close(pipe.reading) }
        let helper: pid_t
        do { helper = try Self.passer("1", socket: pair.helper, fd: pipe.writing) } catch {
            Sys.close(pair.test)
            throw error
        }
        var ended: SpawnTests.Ended?
        defer { if ended == nil { _ = Self.finish(helper, closing: pair.test) } }

        try #require(Self.readable(pair.test), "the helper sent nothing")
        errno = 0
        let received = try #require(Self.receiveDescriptor(over: pair.test, room: room), "nothing received: errno \(errno)")
        defer { Sys.close(received) }
        #expect(fcntl(received, F_GETFD) & FD_CLOEXEC != 0, "the descriptor came without close-on-exec")
        #expect(Sys.write(received, "through", 7) == 7)
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = Sys.read(pipe.reading, &buffer, buffer.count)
        #expect(count == 7)
        #expect(String(decoding: buffer.prefix(max(0, count)), as: UTF8.self) == "through")

        ended = Self.finish(helper, closing: pair.test)
        #expect(ended?.exit == 0, "\(String(describing: ended))")
    }

    /// A message carrying `count` descriptors, other than one, gives none, and keeps none: once the helper's copies are
    /// closed too, nothing holds the pipe's writing end. `room` as `receiveDescriptor(over:room:)` takes it.
    static func nothingIsTaken(fromAMessageCarrying count: Int, room: Int? = nil) throws {
        let pair = try Self.seqpacketPair()
        let pipe = try SpawnTests.newPipe()
        defer { Sys.close(pipe.reading) }
        let helper: pid_t
        do { helper = try Self.passer("\(count)", socket: pair.helper, fd: pipe.writing) } catch {
            Sys.close(pair.test)
            throw error
        }
        var ended: SpawnTests.Ended?
        defer { if ended == nil { _ = Self.finish(helper, closing: pair.test) } }

        try #require(Self.readable(pair.test), "the helper sent nothing")
        errno = 0
        let received = Self.receiveDescriptor(over: pair.test, room: room)
        let code = errno
        if let received { Sys.close(received) }
        try #require(received == nil && code == EBADMSG, "received \(String(describing: received)), errno \(code)")

        var byte: UInt8 = 0
        #expect(Self.readable(pipe.reading) && Sys.read(pipe.reading, &byte, 1) == 0,
                "a descriptor of a message with \(count) is still open in this process")
        ended = Self.finish(helper, closing: pair.test)
        #expect(ended?.exit == 0, "\(String(describing: ended))")
    }

    @Test func aMessageWithTwoDescriptorsGivesNone() throws {
        try Self.nothingIsTaken(fromAMessageCarrying: 2)
    }

    /// None at all, and more than the receiver's room: with 16, the twelve that fit are refused as more than one, and
    /// the four the kernel dropped it closed itself (no copy of the pipe's end is left here either way).
    @Test(arguments: [0, 16]) func aMessageWithNoDescriptorOrManyGivesNone(count: Int) throws {
        try Self.nothingIsTaken(fromAMessageCarrying: count)
    }

    /// A message of two that the room cut to one (the kernel drops the other and says so: `MSG_CTRUNC`) is refused,
    /// not taken for a message of one. With the receiver's whole room this can't come about on 64-bit Linux (what is
    /// left for descriptors there is 8-byte aligned, room for none or for two), so the test gives the kernel room for
    /// one only.
    @Test func aMessageCutToOneDescriptorGivesNone() throws {
        try Self.nothingIsTaken(fromAMessageCarrying: 2, room: Self.roomForOne)
    }

    /// On a `SOCK_SEQPACKET` socket a message of no bytes reads as 0, as the end of the stream does: from a peer still
    /// there it is a message carrying nothing (EBADMSG), not a hang-up, and the pair goes on.
    @Test func anEmptyMessageFromAPeerStillThereIsNotTheEnd() throws {
        let pair = try Self.seqpacketPair()
        defer { [pair.test, pair.helper].forEach { Sys.close($0) } }
        try #require(send(pair.helper, nil, 0, Int32(MSG_NOSIGNAL)) == 0, "no empty message sent: \(errno)")
        errno = 0
        let empty = Platform.Sockets.receiveDescriptor(over: pair.test)
        let code = errno
        if let empty { Sys.close(empty) }
        #expect(empty == nil)
        #expect(code == EBADMSG, "errno \(code)")

        let pipe = try SpawnTests.newPipe()
        defer { [pipe.reading, pipe.writing].forEach { Sys.close($0) } }
        try #require(Platform.Sockets.sendDescriptor(pipe.writing, over: pair.helper), "the pair is gone: \(errno)")
        let next = try #require(Platform.Sockets.receiveDescriptor(over: pair.test), "nothing after: errno \(errno)")
        Sys.close(next)
    }

    /// The end of the stream gives none too, and says the peer has gone (EPIPE).
    @Test func aPairWhoseOtherEndHasGoneGivesNone() throws {
        let pair = try Self.seqpacketPair()
        defer { Sys.close(pair.test) }
        Sys.close(pair.helper)
        errno = 0
        let received = Platform.Sockets.receiveDescriptor(over: pair.test)
        let code = errno
        #expect(received == nil)
        #expect(code == EPIPE)
    }

    /// The control for the host's refusals of a sender that names another process: a process naming itself, in
    /// credentials it sends (`vibe_send_claiming`), arrives as itself.
    @Test func aSenderClaimingItsOwnPidIsBelieved() throws {
        let pair = try Self.seqpacketPair()
        Platform.Sockets.enableCredentials(pair.test)
        let helper: pid_t
        do { helper = try Self.passer("claim", socket: pair.helper) } catch {
            Sys.close(pair.test)
            throw error
        }
        var ended: SpawnTests.Ended?
        defer { if ended == nil { _ = Self.finish(helper, closing: pair.test) } }

        try #require(Self.readable(pair.test), "the helper sent nothing")
        let got = Self.received(pair.test)
        #expect(got.count == 1 && got.text == "m", "\(got)")
        #expect(got.sender?.pid == helper)
        #expect(got.sender?.uid == getuid())
        if let sender = got.sender, case .line(let line) = Platform.Processes.System.statLine(helper) {
            #expect(sender.startTicks == line.startTicks)
        }

        ended = Self.finish(helper, closing: pair.test)
        #expect(ended?.exit == 0, "\(String(describing: ended))")
    }

    /// The host's refusals rest on the kernel checking what a sender claims: a claim naming another process (the
    /// test, the helper's parent) or another uid is refused at the send (EPERM), so the claim goes out as credentials
    /// the kernel reads, not as bytes it lets by. The helper then sends a plain "r", and the test reads that, as itself.
    /// Root may name anyone, so this runs only for an account that isn't.
    @Test(.enabled(if: geteuid() != 0), arguments: ["claimParent", "claimUid"])
    func aSenderClaimingAnotherIsRefusedAtTheSend(claim: String) throws {
        let pair = try Self.seqpacketPair()
        Platform.Sockets.enableCredentials(pair.test)
        let helper: pid_t
        do { helper = try Self.passer(claim, socket: pair.helper) } catch {
            Sys.close(pair.test)
            throw error
        }
        var ended: SpawnTests.Ended?
        defer { if ended == nil { _ = Self.finish(helper, closing: pair.test) } }

        try #require(Self.readable(pair.test), "the helper sent nothing")
        let got = Self.received(pair.test)
        #expect(got.count == 1 && got.text == "r", "the claim went through: \(got)")
        #expect(got.sender?.pid == helper)
        #expect(got.sender?.uid == getuid())

        ended = Self.finish(helper, closing: pair.test)
        #expect(ended?.exit == 0, "\(String(describing: ended))")
    }
}
#else
extension SocketsTests {
    /// The Mac has no connector: nothing is sent, and nothing is read.
    @Test func noDescriptorIsPassedOnTheMac() throws {
        var ends: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, Platform.Sockets.stream, 0, &ends) == 0)
        defer { ends.forEach { Sys.close($0) } }
        #expect(!Platform.Sockets.sendDescriptor(ends[0], over: ends[1]))
        var waiting = pollfd(fd: ends[0], events: Int16(POLLIN), revents: 0)
        #expect(poll(&waiting, 1, 0) == 0, "something was sent")
        #expect(Platform.Sockets.receiveDescriptor(over: ends[0]) == nil)
    }
}
#endif
