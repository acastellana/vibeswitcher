import Foundation
import Testing
@testable import VibePlatform

/// The test binary's helper mode, for a socket whose peer is another process: started again with
/// `SocketsTests.connectVariable` naming a socket's path, this binary connects to it before any test of its own,
/// writes one byte, stays until the other end closes, and ends. It exits 3 when it couldn't connect.
private func connectIfAsked() {
    guard let path = getenv(SocketsTests.connectVariable).map({ String(cString: $0) }) else { return }
    let fd = socket(AF_UNIX, Platform.Sockets.stream, 0)
    guard fd >= 0, var address = Platform.Sockets.unixAddress(path) else { _exit(3) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0, write(fd, "c", 1) == 1 else { _exit(3) }
    var byte: UInt8 = 0
    while true {
        let count = read(fd, &byte, 1)
        if count == 0 || (count < 0 && errno != EINTR) { break }
    }
    _exit(0)
}

// Runs as the test bundle loads, as `refuseTheAccountRoot` does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let connectWhenAsked: @convention(c) () -> Void = { connectIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let connectWhenAsked: @convention(c) () -> Void = { connectIfAsked() }
#endif

/// The test binary's helper mode, for `aSocketWriteToAGonePeerFailsWithEPIPEAndTheProcessLives`: started again with
/// `SocketsTests.gonePeerVariable` set, this binary puts SIGPIPE back at its default before any test of its own (the
/// bundle ignores it as it loads, TestSupport.swift: an executable that hasn't settled it yet is the case), lets it in
/// on this thread, says so, writes through `Platform.Sockets.send` to a socket whose peer has closed, says what that
/// returned, and exits 0. Killed by SIGPIPE, it says nothing after its first line.
private func writeToAGonePeerIfAsked() {
    guard getenv(SocketsTests.gonePeerVariable) != nil else { return }
    func say(_ text: String) {
        let line = text + "\n"
        _ = write(STDOUT_FILENO, line, line.utf8.count)
    }
    signal(SIGPIPE, SIG_DFL)
    var pipeSignal = sigset_t(), mask = sigset_t()
    sigemptyset(&pipeSignal)
    sigaddset(&pipeSignal, SIGPIPE)
    pthread_sigmask(SIG_UNBLOCK, &pipeSignal, nil)
    pthread_sigmask(SIG_SETMASK, nil, &mask)
    var now = sigaction()
    sigaction(SIGPIPE, nil, &now)
    guard SignalsTests.handler(now) == nil, sigismember(&mask, SIGPIPE) == 0 else {
        say("SIGPIPE isn't at its default here")
        _exit(4)
    }
    var ends: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, Platform.Sockets.stream, 0, &ends) == 0 else {
        say("no socket pair: errno \(errno)")
        _exit(5)
    }
    // As the code's sockets are (UnixSocket.configure): the Mac's switch; nothing on Linux.
    Platform.Sockets.noSigPipe(socket: ends[0])
    close(ends[1])
    say("SIGPIPE at its default")
    errno = 0
    let sent = Platform.Sockets.send(ends[0], "x", 1)
    let code = errno
    say(sent == -1 && code == EPIPE ? "EPIPE" : "sent \(sent), errno \(code)")
    _exit(0)
}

#if os(Linux)
@_used @_section(".init_array")
private let writeToAGonePeerWhenAsked: @convention(c) () -> Void = { writeToAGonePeerIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let writeToAGonePeerWhenAsked: @convention(c) () -> Void = { writeToAGonePeerIfAsked() }
#endif

#if os(Linux)
/// The test binary's helper mode for `aSenderInItsOwnPidNamespaceCanNameOnlyItsOwnProcesses`: started under
/// `unshare --user --map-root-user --pid --fork` with `SocketsTests.namespaceVariable` set to "SOCKET:PID" (SOCKET its
/// end of a `SOCK_SEQPACKET` pair, handed down; PID the test's, a number of the namespace outside), this binary is
/// pid 1 of a pid namespace of its own and root of a user namespace of its own, so it may name any process of its pid
/// namespace in the credentials it sends. Before any test of its own it starts a child (`sleep`), then sends three
/// claims (`vibe_send_claiming`), each a message: its own pid ("own N"), its child's ("child N"), and the test's
/// ("outside"); a claim the kernel refuses is followed by a plain "refused ERRNO", sent as itself. It stays until the
/// test closes its end, and exits 0, which ends the namespace and its child. It exits 2 when it can't read the
/// variable, 3 when the child didn't start, 4 when a send failed otherwise.
private func claimInAPidNamespaceIfAsked() {
    guard let asked = getenv(SocketsTests.namespaceVariable).map({ String(cString: $0) }) else { return }
    let words = asked.split(separator: ":")
    guard words.count == 2, let socket = Int32(words[0]), let outside = pid_t(words[1]) else { _exit(2) }
    var sleeper = Platform.Spawn(executable: "/bin/sleep", arguments: ["sleep", "600"])
    sleeper.stdin = .path("/dev/null", flags: O_RDONLY)
    sleeper.stdout = .path("/dev/null", flags: O_WRONLY)
    sleeper.keep = []
    guard case .success(let child) = sleeper.start() else { _exit(3) }
    func claim(_ text: String, naming pid: pid_t) {
        let bytes = Array(text.utf8)
        guard vibe_send_claiming(socket, bytes, bytes.count, pid, getuid(), getgid()) != bytes.count else { return }
        let refusal = Array("refused \(errno)".utf8)
        guard send(socket, refusal, refusal.count, Int32(MSG_NOSIGNAL)) == refusal.count else { _exit(4) }
    }
    claim("own \(getpid())", naming: getpid())
    claim("child \(child)", naming: child)
    claim("outside", naming: outside)
    var byte: UInt8 = 0
    while true {
        let count = read(socket, &byte, 1)
        if count == 0 || (count < 0 && errno != EINTR) { break }
    }
    _exit(0)
}

@_used @_section(".init_array")
private let claimInAPidNamespaceWhenAsked: @convention(c) () -> Void = { claimInAPidNamespaceIfAsked() }
#endif

/// `Platform.Sockets`: an address and its limit, a write to a peer that has gone, and who is at the other end. The
/// sockets are a test's own, in the run's scratch folder; a child is the test binary itself or `/bin/sh`, and is
/// reaped.
struct SocketsTests {
    static let connectVariable = "VIBE_SOCKETS_TEST_CONNECT"
    static let gonePeerVariable = "VIBE_SOCKETS_TEST_GONE_PEER"

    struct Failure: Error { var what: String }

    /// How many bytes `sun_path` holds: the longest path, with the 0 that ends it.
    static var pathRoom: Int {
        let address = sockaddr_un()
        return MemoryLayout.size(ofValue: address.sun_path)
    }

    /// A new folder to keep a socket in, which the test removes: of the run's scratch, or, when a socket's path
    /// wouldn't fit there (a run given a long TMPDIR, as scripts/test-under-load.sh gives one), of the temporary
    /// folder every process shares, as VibeHostTests' `shortScratchRoot`.
    static func socketFolder() throws -> URL {
        let folder = try TestScriptLinuxTests.scratch("so")
        // With "/s" and the 0 that ends it.
        guard folder.path.utf8.count + 3 > pathRoom else { return folder }
        try? FileManager.default.removeItem(at: folder)
        let short = URL(fileURLWithPath: Platform.Files.sharedTemporaryRoot, isDirectory: true)
            .appendingPathComponent("vibe-so-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: short, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return short
    }

    /// A stream socket no program started meanwhile keeps (another test's child, started to keep what isn't marked,
    /// would hold a test's socket open after the test closed it).
    static func streamSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, Platform.Sockets.stream, 0)
        guard fd >= 0 else { throw Failure(what: "no socket: \(errno)") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// A socket listening at `path`.
    static func listener(at path: String) throws -> Int32 {
        guard var address = Platform.Sockets.unixAddress(path) else { throw Failure(what: "\(path) is too long for a socket") }
        let fd = try streamSocket()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Sys.listen(fd, 8) == 0 else {
            let code = errno
            Sys.close(fd)
            throw Failure(what: "no listener at \(path): \(code)")
        }
        return fd
    }

    /// A socket connected to the listener at `path`: the connection waits in the listener's queue, and an accept
    /// finds it there.
    static func client(of path: String) throws -> Int32 {
        guard var address = Platform.Sockets.unixAddress(path) else { throw Failure(what: "\(path) is too long for a socket") }
        let fd = try streamSocket()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Sys.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            Sys.close(fd)
            throw Failure(what: "no connection to \(path): \(code)")
        }
        return fd
    }

    /// The listener's next connection. One that doesn't come within `hangGuard` fails the test, and doesn't hold the
    /// run.
    static func accepted(from listener: Int32) throws -> Int32 {
        var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        var ready: Int32 = -1
        repeat { ready = poll(&waiting, 1, Int32(TestScriptLinuxTests.hangGuard * 1_000)) } while ready < 0 && errno == EINTR
        guard ready == 1 else { throw Failure(what: "nothing connected: poll \(ready)") }
        let fd = Sys.accept(listener, nil, nil)
        guard fd >= 0 else { throw Failure(what: "no accept: \(errno)") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// A pair connected through a listener in a folder of the test's own (`socketFolder`), both ends this process's. `close`
    /// closes what is still open of the three and removes the folder.
    struct Pair {
        var folder: URL
        var path: String
        var listener: Int32
        var client: Int32
        var served: Int32

        init(listening prepare: (Int32) -> Void = { _ in }) throws {
            let folder = try SocketsTests.socketFolder()
            let path = folder.appendingPathComponent("s").path
            var opened: [Int32] = []
            do {
                let listener = try SocketsTests.listener(at: path)
                opened.append(listener)
                prepare(listener)
                let client = try SocketsTests.client(of: path)
                opened.append(client)
                let served = try SocketsTests.accepted(from: listener)
                (self.folder, self.path, self.listener, self.client, self.served) = (folder, path, listener, client, served)
            } catch {
                opened.forEach { Sys.close($0) }
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }

        /// Closes `end` (the client or the served one) before the rest.
        mutating func close(_ end: WritableKeyPath<Pair, Int32>) {
            Sys.close(self[keyPath: end])
            self[keyPath: end] = -1
        }

        func close() {
            for fd in [served, client, listener] where fd >= 0 { Sys.close(fd) }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// What a write of one byte to `fd` returned, and `errno` after it.
    static func writeOne(to fd: Int32) -> (count: Int, code: Int32) {
        errno = 0
        let count = Sys.write(fd, "x", 1)
        return (count, errno)
    }

    /// Asks `condition` again every millisecond until it holds; false when it didn't within `hangGuard`. For what a
    /// test closed and now needs gone: a child that another test starts meanwhile holds a copy of every descriptor
    /// of this process until its program replaces it, and for that moment the closed end is still open there.
    static func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(TestScriptLinuxTests.hangGuard)
        while !condition() {
            if Date() > deadline { return false }
            usleep(1_000)
        }
        return true
    }

    /// What a write of one byte to `fd` ends with once its reader has gone: the first write that isn't taken.
    static func refusedWrite(to fd: Int32) -> (count: Int, code: Int32) {
        var last = writeOne(to: fd)
        _ = eventually {
            if last.count != 1 { return true }
            last = writeOne(to: fd)
            return last.count != 1
        }
        return last
    }

    // MARK: The address

    @Test func aPathOverTheLimitIsRefused() throws {
        let room = Self.pathRoom
        #if os(Linux)
        #expect(room == 108)
        #else
        #expect(room == 104)
        #endif
        // The longest path that fits leaves one byte for the 0 that ends it.
        let longest = "/" + String(repeating: "a", count: room - 2)
        let address = try #require(Platform.Sockets.unixAddress(longest))
        #expect(address.sun_family == sa_family_t(AF_UNIX))
        #if canImport(Darwin)
        #expect(Int(address.sun_len) == MemoryLayout<sockaddr_un>.size)
        #endif
        let held = withUnsafeBytes(of: address.sun_path) { Array($0) }
        #expect(held.count == room)
        #expect(Array(held.dropLast()) == Array(longest.utf8))
        #expect(held.last == 0)

        #expect(Platform.Sockets.unixAddress(longest + "a") == nil)
        #expect(Platform.Sockets.unixAddress(String(repeating: "a", count: 4_096)) == nil)
        // Bytes are counted, not characters: fewer characters than the room, more bytes.
        let accented = String(repeating: "é", count: room / 2)
        #expect(accented.count < room - 1 && accented.utf8.count == room)
        #expect(Platform.Sockets.unixAddress(accented) == nil)

        // A short one ends where it ends: nothing of the room after it is set.
        let short = try #require(Platform.Sockets.unixAddress("/tmp/s"))
        #expect(withUnsafeBytes(of: short.sun_path) { Array($0) } == Array("/tmp/s".utf8) + [UInt8](repeating: 0, count: room - 6))
    }

    @Test func theStreamTypeMakesAStreamSocket() throws {
        let fd = socket(AF_UNIX, Platform.Sockets.stream, 0)
        try #require(fd >= 0)
        defer { Sys.close(fd) }
        var type: Int32 = -1
        var size = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) == 0)
        #expect(type == Platform.Sockets.stream)
        #expect(Platform.Sockets.stream == 1)
    }

    // MARK: The peer

    @Test func aPeersUIDAndPIDAreThisProcesss() throws {
        let pair = try Pair()
        defer { pair.close() }
        // Each end's peer is this process: the one that listened and the one that connected.
        for end in [pair.served, pair.client] {
            #expect(Platform.Sockets.peerUID(end) == geteuid())
            #expect(Platform.Sockets.peerPID(end) == getpid())
        }
        // A socket connected to nothing has no peer, and a file is no socket.
        let lone = socket(AF_UNIX, Platform.Sockets.stream, 0)
        try #require(lone >= 0)
        defer { Sys.close(lone) }
        #expect(Platform.Sockets.peerUID(lone) == nil)
        #expect(Platform.Sockets.peerPID(lone) == nil)
        #expect(Platform.Sockets.peerToken(lone) == nil)
        let file = Sys.open("/dev/null", O_RDONLY)
        try #require(file >= 0)
        defer { Sys.close(file) }
        #expect(Platform.Sockets.peerUID(file) == nil)
        #expect(Platform.Sockets.peerPID(file) == nil)
        #expect(Platform.Sockets.peerToken(file) == nil)
    }

    /// Starts this binary again in its helper mode (`connectIfAsked`), connecting to the listener at `path`.
    static func connector(to path: String) throws -> pid_t {
        // The helper never gets as far as a test; one that did would not start another.
        try #require(getenv(connectVariable) == nil)
        let binary = try #require(Bundle.main.executablePath)
        var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(connectVariable)=\(path)"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        return try spawn.start().get()
    }

    @Test func aPeerTokenComparesEqualForTheSameProcessAndDiffersForAnother() throws {
        let pair = try Pair()
        defer { pair.close() }
        let own = try #require(Platform.Sockets.peerToken(pair.served))
        let again = try #require(Platform.Sockets.peerToken(pair.served))
        let fromTheOtherEnd = try #require(Platform.Sockets.peerToken(pair.client))
        #expect(own.pid == getpid())
        #expect(own.sameImage(as: again))
        #expect(own.sameImage(as: fromTheOtherEnd))

        // Another process connects: this binary again. Its byte read, it is the one that last used its socket.
        let child = try Self.connector(to: pair.path)
        var reaped = false
        defer { if !reaped { _ = SpawnTests.ended(child) } }
        let served = try Self.accepted(from: pair.listener)
        var servedIsOpen = true
        defer { if servedIsOpen { Sys.close(served) } }
        var byte: UInt8 = 0
        #expect(Sys.read(served, &byte, 1) == 1)
        #expect(byte == UInt8(ascii: "c"))
        let other = try #require(Platform.Sockets.peerToken(served))
        let otherAgain = try #require(Platform.Sockets.peerToken(served))
        #expect(other.pid == child)
        #expect(other.sameImage(as: otherAgain))
        #expect(!other.sameImage(as: own))
        #expect(!own.sameImage(as: other))
        #expect(Platform.Sockets.peerPID(served) == child)
        #expect(Platform.Sockets.peerUID(served) == geteuid())
        #if os(Linux)
        #expect(own.uid == geteuid() && other.uid == geteuid())
        // The start is the process's own, as its line of /proc says; and a token of the same pid with another
        // start (the pid given again to a later process) isn't the same image.
        guard case .line(let line) = Platform.Processes.System.statLine(child) else {
            Issue.record("no stat line for \(child)")
            return
        }
        #expect(other.startTicks == line.startTicks)
        #expect(other.startTicks >= own.startTicks)
        #expect(!other.sameImage(as: Platform.PeerToken(pid: child, uid: other.uid, startTicks: other.startTicks + 1)))
        #expect(other.sameImage(as: Platform.PeerToken(pid: child, uid: 0, startTicks: other.startTicks)))
        #endif

        // The helper ends when its connection does.
        Sys.close(served)
        servedIsOpen = false
        let ended = SpawnTests.ended(child)
        reaped = true
        #expect(ended.exit == 0, "\(ended)")
    }

    // MARK: A reader that has gone

    /// The process gets an error, not SIGPIPE's death. On the Mac each descriptor is asked; on Linux the test bundle
    /// ignores the signal as it loads (TestSupport.swift), as an executable settles it for itself.
    @Test func writingToAClosedPeerReturnsAnErrorNotASignal() throws {
        #if os(Linux)
        let before = signal(SIGPIPE, SIG_IGN)
        #expect(unsafeBitCast(before, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self), "the test bundle doesn't ignore SIGPIPE")
        #endif

        // A socket, as UnixSocket.configure sets one.
        var pair = try Pair()
        defer { pair.close() }
        Platform.Sockets.noSigPipe(socket: pair.client)
        #expect(Self.writeOne(to: pair.client).count == 1)
        var byte: UInt8 = 0
        #expect(Sys.read(pair.served, &byte, 1) == 1)
        pair.close(\.served)
        let toSocket = Self.refusedWrite(to: pair.client)
        #expect(toSocket.count == -1)
        #expect(toSocket.code == EPIPE)

        // A pipe, as the writers to a child's stdin and to stdout set theirs.
        var ends: [Int32] = [-1, -1]
        try #require(Sys.pipe(&ends) == 0)
        defer { Sys.close(ends[1]) }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        Platform.Sockets.noSigPipe(ends[1])
        #expect(Self.writeOne(to: ends[1]).count == 1)
        #expect(Sys.read(ends[0], &byte, 1) == 1)
        Sys.close(ends[0])
        let toPipe = Self.refusedWrite(to: ends[1])
        #expect(toPipe.count == -1)
        #expect(toPipe.code == EPIPE)

        // Asked of a descriptor that is nothing of the kind, or closed: nothing happens.
        Platform.Sockets.noSigPipe(-1)
        Platform.Sockets.noSigPipe(socket: -1)
        Platform.Sockets.noSigPipe(socket: ends[1])
    }

    /// A write through `Platform.Sockets.send` to a socket whose peer has gone fails with EPIPE, and the process lives,
    /// with SIGPIPE at its default: the hook's round trip to a session host that went mid-write (a handover, a
    /// restart), made before the hook has settled SIGPIPE. In the test binary's helper mode (`writeToAGonePeerIfAsked`),
    /// a process of its own: the test bundle ignores SIGPIPE.
    @Test func aSocketWriteToAGonePeerFailsWithEPIPEAndTheProcessLives() throws {
        // The helper never gets as far as a test; one that did would not start another.
        try #require(getenv(Self.gonePeerVariable) == nil)
        let binary = try #require(Bundle.main.executablePath)
        var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(Self.gonePeerVariable)=1"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        let ended = try SpawnTests.output(of: spawn)
        #expect(ended.output == "SIGPIPE at its default\nEPIPE\n", "\(ended)")
        #expect(ended.signal == nil && ended.exit == 0, "\(ended)")
    }

    // MARK: Made close-on-exec

    static func closedOnExec(_ fd: Int32) -> Bool { fcntl(fd, F_GETFD) & FD_CLOEXEC != 0 }

    static func type(of fd: Int32) -> Int32? {
        var type: Int32 = -1
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) == 0 ? type : nil
    }

    /// The types a Unix-domain socket comes in on this system: the Mac has no seqpacket one (XNU's Unix domain has
    /// only stream and datagram sockets).
    static var socketTypes: [Int32] {
        #if os(Linux)
        [Platform.Sockets.stream, Platform.Sockets.seqpacket]
        #else
        [Platform.Sockets.stream]
        #endif
    }

    /// Both ends of a pair are close-on-exec from the call that made them (the Mac: right after it), and are of the
    /// type asked.
    @Test(arguments: SocketsTests.socketTypes)
    func aPairIsClosedOnExecFromItsMaking(type: Int32) throws {
        let (one, other) = try #require(Platform.Sockets.pair(type: type))
        defer { [one, other].forEach { Sys.close($0) } }
        #expect(Self.closedOnExec(one) && Self.closedOnExec(other))
        #expect(Self.type(of: one) == type && Self.type(of: other) == type)
        // Connected to each other.
        #expect(Platform.Sockets.send(one, "x", 1) == 1)
        var byte: UInt8 = 0
        #expect(Sys.read(other, &byte, 1) == 1 && byte == UInt8(ascii: "x"))
    }

    #if os(Linux)
    /// What the server child's connector (Linux's) relies on: each send is one message, read whole and alone.
    @Test func aSeqpacketPairKeepsMessageBoundaries() throws {
        let (one, other) = try #require(Platform.Sockets.pair(type: Platform.Sockets.seqpacket))
        defer { [one, other].forEach { Sys.close($0) } }
        #expect(Platform.Sockets.send(one, "a", 1) == 1)
        #expect(Platform.Sockets.send(one, "b", 1) == 1)
        var buffer = [UInt8](repeating: 0, count: 16)
        #expect(Sys.read(other, &buffer, buffer.count) == 1 && buffer[0] == UInt8(ascii: "a"))
        #expect(Sys.read(other, &buffer, buffer.count) == 1 && buffer[0] == UInt8(ascii: "b"))
    }
    #else
    /// The Mac makes no seqpacket socket, alone or in a pair.
    @Test func theMacHasNoSeqpacketSocket() {
        #expect(Platform.Sockets.pair(type: Platform.Sockets.seqpacket) == nil)
        let fd = Platform.Sockets.makeSocket(type: Platform.Sockets.seqpacket)
        if fd >= 0 { Sys.close(fd) }
        #expect(fd == -1)
    }
    #endif

    @Test(arguments: SocketsTests.socketTypes)
    func aSocketIsClosedOnExecFromItsMaking(type: Int32) throws {
        let fd = Platform.Sockets.makeSocket(type: type)
        try #require(fd >= 0, "errno \(errno)")
        defer { Sys.close(fd) }
        #expect(Self.closedOnExec(fd))
        #expect(Self.type(of: fd) == type)
    }

    @Test func anAcceptedConnectionIsClosedOnExecFromItsMaking() throws {
        let folder = try Self.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("s").path
        let listener = try Self.listener(at: path)
        defer { Sys.close(listener) }
        let client = try Self.client(of: path)
        defer { Sys.close(client) }
        // The connection waits in the listener's queue: the accept finds it there and doesn't block.
        let served = Platform.Sockets.accept(listener)
        try #require(served >= 0, "errno \(errno)")
        defer { Sys.close(served) }
        #expect(Self.closedOnExec(served))
        #expect(Platform.Sockets.send(client, "x", 1) == 1)
        var byte: UInt8 = 0
        #expect(Sys.read(served, &byte, 1) == 1 && byte == UInt8(ascii: "x"))
        // Nothing waiting, on a listener that doesn't block: -1 and EAGAIN, as accept(2).
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        errno = 0
        let none = Platform.Sockets.accept(listener)
        let code = errno
        #expect(none == -1 && code == EAGAIN, "\(none), errno \(code)")
    }

    // MARK: Who sent the bytes

    /// On both systems: bytes read come with the process that sent them, here this one.
    @Test func receivedBytesComeWithTheirSender() throws {
        var pair = try Pair { Platform.Sockets.enableCredentials($0) }
        defer { pair.close() }
        Platform.Sockets.enableCredentials(pair.served)
        #expect(Sys.write(pair.client, "hello", 5) == 5)
        var buffer = [UInt8](repeating: 0, count: 64)
        let got = buffer.withUnsafeMutableBytes { Platform.Sockets.receive(pair.served, into: $0) }
        #expect(got.count == 5)
        #expect(Array(buffer.prefix(5)) == Array("hello".utf8))
        let sender = try #require(got.sender)
        #expect(sender.pid == getpid())
        let connected = try #require(Platform.Sockets.peerToken(pair.served))
        #expect(sender.sameImage(as: connected))

        // The end of the stream is a count of 0 and no sender; a descriptor that isn't open, -1 and its error.
        pair.close(\.client)
        let end = buffer.withUnsafeMutableBytes { Platform.Sockets.receive(pair.served, into: $0) }
        #expect(end.count == 0)
        #expect(end.sender == nil)
        errno = 0
        let closed = buffer.withUnsafeMutableBytes { Platform.Sockets.receive(-1, into: $0) }
        let code = errno
        #expect(closed.count == -1)
        #expect(closed.sender == nil)
        #expect(code == EBADF)
    }

    #if os(Linux)
    static func received(_ fd: Int32) -> (text: String, count: Int, sender: Platform.PeerToken?) {
        var buffer = [UInt8](repeating: 0, count: 64)
        let got = buffer.withUnsafeMutableBytes { Platform.Sockets.receive(fd, into: $0) }
        return (String(decoding: buffer.prefix(max(0, got.count)), as: UTF8.self), got.count, got.sender)
    }

    static func pair() throws -> (reading: Int32, writing: Int32) {
        var ends: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Platform.Sockets.stream | Int32(SOCK_CLOEXEC.rawValue), 0, &ends) == 0 else {
            throw Failure(what: "no socket pair: \(errno)")
        }
        return (ends[0], ends[1])
    }

    /// What the Mac's token does by itself: the one who writes is named, not the one who connected. This process
    /// writes, then a child writes on the same socket: each read holds one sender's bytes and names that sender,
    /// though both writes were waiting when the first was read.
    @Test func eachMessagesSenderIsTheProcessThatWroteIt() throws {
        let ends = try Self.pair()
        defer { [ends.reading, ends.writing].forEach { Sys.close($0) } }
        Platform.Sockets.enableCredentials(ends.reading)
        #expect(Sys.write(ends.writing, "parent", 6) == 6)

        var spawn = SpawnTests.shell("echo child")
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .descriptor(ends.writing)
        let child = try spawn.start().get()
        var reaped = false
        defer { if !reaped { _ = SpawnTests.ended(child) } }
        // The child has written when it has ended. Not reaped yet: its line of /proc is still there to read.
        var info = siginfo_t()
        var waited: Int32 = -1
        repeat { waited = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) } while waited < 0 && errno == EINTR
        try #require(waited == 0, "waitid: \(errno)")

        let first = Self.received(ends.reading)
        #expect(first.text == "parent")
        #expect(first.sender?.pid == getpid())
        #expect(first.sender?.uid == geteuid())
        let second = Self.received(ends.reading)
        #expect(second.text == "child\n")
        #expect(second.sender?.pid == child)
        #expect(second.sender?.uid == geteuid())
        if let own = first.sender, let other = second.sender {
            #expect(!own.sameImage(as: other))
            // Who made the pair stays this process, whoever writes on it.
            #expect(Platform.Sockets.peerToken(ends.reading)?.sameImage(as: own) == true)
        }

        // Reaped, the child is no one: its bytes would come with no sender.
        let ended = SpawnTests.ended(child)
        reaped = true
        #expect(ended.exit == 0, "\(ended)")
        #expect(Platform.Sockets.token(pid: child, uid: geteuid()) == nil)
    }

    /// Bytes sent before the socket asked for senders have none; a listener that asked gives every connection it
    /// accepts its senders from the first byte, sent before the accept.
    @Test func sendersAreKnownOnlyFromWhenTheyWereAskedFor() throws {
        let ends = try Self.pair()
        defer { [ends.reading, ends.writing].forEach { Sys.close($0) } }
        #expect(Sys.write(ends.writing, "early", 5) == 5)
        Platform.Sockets.enableCredentials(ends.reading)
        let early = Self.received(ends.reading)
        #expect(early.text == "early")
        #expect(early.sender == nil)
        #expect(Sys.write(ends.writing, "late", 4) == 4)
        let late = Self.received(ends.reading)
        #expect(late.text == "late")
        #expect(late.sender?.pid == getpid())

        let folder = try Self.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("s").path
        let listener = try Self.listener(at: path)
        defer { Sys.close(listener) }
        Platform.Sockets.enableCredentials(listener)
        let client = try Self.client(of: path)
        defer { Sys.close(client) }
        #expect(Sys.write(client, "first", 5) == 5)
        let served = try Self.accepted(from: listener)
        defer { Sys.close(served) }
        let first = Self.received(served)
        #expect(first.text == "first")
        #expect(first.sender?.pid == getpid())
    }

    /// A peer can send descriptors along with its bytes: `receive` keeps none. The one sent here is a pipe's
    /// writing end; while the message waits it holds the pipe open, and once it is received nothing does.
    @Test(arguments: [false, true]) func descriptorsSentAlongAreClosed(askingForSenders: Bool) throws {
        let ends = try Self.pair()
        defer { [ends.reading, ends.writing].forEach { Sys.close($0) } }
        if askingForSenders { Platform.Sockets.enableCredentials(ends.reading) }
        var pipeEnds: [Int32] = [-1, -1]
        try #require(Sys.pipe(&pipeEnds) == 0)
        defer { Sys.close(pipeEnds[0]) }
        for end in pipeEnds { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(pipeEnds[0], F_SETFL, fcntl(pipeEnds[0], F_GETFL) | O_NONBLOCK)

        // One control message, SCM_RIGHTS (1) with one descriptor, as 64-bit Linux lays it out: its length (16 of
        // header and 4 of data) in 8 bytes, the level and the type in 4 each, the descriptor, and 4 to round up.
        var control = [UInt8](repeating: 0, count: 24)
        control.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt64(20), toByteOffset: 0, as: UInt64.self)
            raw.storeBytes(of: SOL_SOCKET, toByteOffset: 8, as: Int32.self)
            raw.storeBytes(of: Int32(1), toByteOffset: 12, as: Int32.self)
            raw.storeBytes(of: pipeEnds[1], toByteOffset: 16, as: Int32.self)
        }
        var byte: UInt8 = 0x66
        let sent = withUnsafeMutableBytes(of: &byte) { data in
            control.withUnsafeMutableBytes { control in
                var piece = iovec(iov_base: data.baseAddress, iov_len: 1)
                return withUnsafeMutablePointer(to: &piece) { piece in
                    var message = msghdr()
                    message.msg_iov = piece
                    message.msg_iovlen = 1
                    message.msg_control = control.baseAddress
                    message.msg_controllen = numericCast(control.count)
                    return sendmsg(ends.writing, &message, 0)
                }
            }
        }
        try #require(sent == 1, "sendmsg: \(errno)")
        Sys.close(pipeEnds[1])

        var read: UInt8 = 0
        let waiting = Sys.read(pipeEnds[0], &read, 1)
        let code = errno
        #expect(waiting == -1 && code == EAGAIN, "the descriptor wasn't sent: read \(waiting), errno \(code)")

        let got = Self.received(ends.reading)
        #expect(got.text == "f")
        #expect(got.sender?.pid == (askingForSenders ? getpid() : nil))
        // The pipe's end: no one has its writing end any more.
        #expect(Self.eventually { Sys.read(pipeEnds[0], &read, 1) == 0 }, "a descriptor sent along is still open in this process")
    }

    /// A sender that wrote, ended and was reaped before the read is no one: its bytes come with no sender. (Had its
    /// pid been given to another process in between, they would come as that process's: `receive`'s caveat, the
    /// security architecture document's S5. With pid_max in the millions, not within this test.)
    @Test func bytesFromAReapedSenderComeWithNoSender() throws {
        let ends = try Self.pair()
        defer { [ends.reading, ends.writing].forEach { Sys.close($0) } }
        Platform.Sockets.enableCredentials(ends.reading)
        var spawn = SpawnTests.shell("echo gone")
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .descriptor(ends.writing)
        let child = try spawn.start().get()
        let ended = SpawnTests.ended(child)
        #expect(ended.exit == 0, "\(ended)")

        let got = Self.received(ends.reading)
        #expect(got.text == "gone\n")
        #expect(got.sender == nil, "pid \(child), reaped, came as \(String(describing: got.sender))")
    }

    /// The kernel checks the pid a sender names in its own credentials: outside a namespace of its own, a process
    /// naming another (here this process naming its parent and a child of its own) is refused at the send, EPERM.
    /// Root may name anyone, so this runs only for an account that isn't.
    @Test(.enabled(if: geteuid() != 0)) func aSenderCannotClaimAnotherPid() throws {
        let ends = try Self.pair()
        defer { [ends.reading, ends.writing].forEach { Sys.close($0) } }
        Platform.Sockets.enableCredentials(ends.reading)
        let held = try SpawnTests.held(.inherit)
        defer {
            Sys.close(held.release)
            _ = SpawnTests.ended(held.pid)
        }
        for other in [getppid(), held.pid] {
            errno = 0
            let sent = vibe_send_claiming(ends.writing, "m", 1, other, getuid(), getgid())
            let code = errno
            #expect(sent == -1 && code == EPERM, "naming pid \(other): sent \(sent), errno \(code)")
        }
        // Naming itself is no claim at all: it arrives as itself.
        #expect(vibe_send_claiming(ends.writing, "s", 1, getpid(), getuid(), getgid()) == 1)
        let got = Self.received(ends.reading)
        #expect(got.text == "s")
        #expect(got.sender?.pid == getpid())
    }

    static let namespaceVariable = "VIBE_SOCKETS_TEST_NAMESPACE"
    static let unshare = "/usr/bin/unshare"

    /// Why this runner can't make a user and pid namespace without privileges (GitHub's Ubuntu 24.04 runners refuse
    /// one, through AppArmor); nil when it can.
    static let noPidNamespace: String? = {
        guard FileManager.default.isExecutableFile(atPath: unshare) else { return "no \(unshare)" }
        var probe = Platform.Spawn(executable: unshare, arguments: ["unshare", "--user", "--map-root-user", "--pid", "--fork", "/bin/true"])
        probe.stdin = .path("/dev/null", flags: O_RDONLY)
        probe.stdout = .path("/dev/null", flags: O_WRONLY)
        probe.stderr = .path("/dev/null", flags: O_WRONLY)
        guard case .success(let pid) = probe.start() else { return "\(unshare) didn't start" }
        let ended = SpawnTests.ended(pid)
        return ended.exit == 0 ? nil : "this runner refuses an unprivileged user namespace (unshare: \(ended))"
    }()

    /// What any process of the user can do (unprivileged user namespaces are on): make a user and pid namespace of
    /// its own, where it holds `CAP_SYS_ADMIN` and may name another process in its credentials. It can name only the
    /// processes of that namespace, its own: its own pid and its child's arrive as themselves (their pids outside),
    /// and a pid of the namespace outside (the test's) is refused at the send. The helper is this binary
    /// (`claimInAPidNamespaceIfAsked`).
    @Test(.enabled(if: geteuid() != 0 && SocketsTests.noPidNamespace == nil,
                   "needs an unprivileged user and pid namespace: \(SocketsTests.noPidNamespace ?? "")"))
    func aSenderInItsOwnPidNamespaceCanNameOnlyItsOwnProcesses() throws {
        let pair = try Self.seqpacketPair()
        Platform.Sockets.enableCredentials(pair.test)
        try #require(getenv(Self.namespaceVariable) == nil)
        let binary = try #require(Bundle.main.executablePath)
        var spawn = Platform.Spawn(executable: Self.unshare, arguments: ["unshare", "--user", "--map-root-user", "--pid", "--fork", binary]
            + ProcessInfo.processInfo.arguments.dropFirst())
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
            + ["\(Self.namespaceVariable)=\(pair.helper):\(getpid())"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.keep = [pair.helper]
        let started = spawn.start()
        Sys.close(pair.helper)
        let unshared: pid_t
        do { unshared = try started.get() } catch {
            Sys.close(pair.test)
            throw error
        }
        var ended: SpawnTests.Ended?
        defer { if ended == nil { _ = Self.finish(unshared, closing: pair.test) } }
        func parent(of pid: pid_t) -> pid_t? {
            guard case .brief(let brief) = Platform.Processes.brief(pid) else { return nil }
            return brief.ppid
        }

        var got: [(text: String, count: Int, sender: Platform.PeerToken?)] = []
        for _ in 0..<3 {
            try #require(Self.readable(pair.test), "the helper sent \(got.count) messages: \(got.map(\.text))")
            got.append(Self.received(pair.test))
        }
        // Its own pid there (1): itself, unshare's child.
        #expect(got[0].text == "own 1", "\(got[0])")
        let helper = try #require(got[0].sender)
        #expect(helper.uid == getuid())
        #expect(parent(of: helper.pid) == unshared)
        // Its child's pid there: that child, a process of its own, under its pid outside.
        #expect(got[1].text.hasPrefix("child "), "\(got[1])")
        let child = try #require(got[1].sender)
        #expect(child.pid != helper.pid && "child \(child.pid)" != got[1].text)
        #expect(child.uid == getuid())
        #expect(parent(of: child.pid) == helper.pid)
        // A pid outside its namespace: no such process there, refused.
        #expect(got[2].text.hasPrefix("refused "), "\(got[2])")
        #expect(got[2].sender?.pid == helper.pid)

        ended = Self.finish(unshared, closing: pair.test)
        #expect(ended?.exit == 0, "\(String(describing: ended))")
    }
    #endif
}

extension SocketsTests {
    // MARK: The file a socket is bound to

    /// `boundFile`: the device and inode `lstat` gives the socket's path, the device in `stat`'s own encoding (the
    /// kernel reports its own, which differs for every device but 0:n with n under 256: 8:32 is 0x800020 to the kernel
    /// and 0x820 to `stat`). Renamed, the socket's file is still what the kernel names, at its new path; another socket
    /// renamed over that path is not it, and is its own listener's. A socket bound to no file, and a descriptor that is
    /// no socket, have none.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "unix_diag is Linux's"))
    func boundFileIsTheFileTheSocketIsBoundTo() throws {
        let folder = try Self.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func look(_ path: String) throws -> stat {
            var info = stat()
            guard lstat(path, &info) == 0 else { throw Failure(what: "no lstat of \(path): \(errno)") }
            return info
        }
        let path = folder.appendingPathComponent("s").path
        let listener = try Self.listener(at: path)
        defer { Sys.close(listener) }
        let info = try look(path)
        let bound = try #require(Platform.Sockets.boundFile(of: listener))
        #expect(bound.device == UInt64(truncatingIfNeeded: info.st_dev), "kernel said \(bound.device), lstat \(info.st_dev)")
        #expect(bound.inode == UInt64(UInt32(truncatingIfNeeded: info.st_ino)))
        #expect(Platform.Sockets.boundFile(bound, is: info))

        let moved = folder.appendingPathComponent("m").path
        #expect(rename(path, moved) == 0)
        let movedBound = try #require(Platform.Sockets.boundFile(of: listener))
        #expect(movedBound == bound)
        #expect(Platform.Sockets.boundFile(movedBound, is: try look(moved)))

        let otherPath = folder.appendingPathComponent("o").path
        let other = try Self.listener(at: otherPath)
        defer { Sys.close(other) }
        #expect(rename(otherPath, moved) == 0)
        let renamedOver = try look(moved)
        #expect(!Platform.Sockets.boundFile(bound, is: renamedOver))
        #expect(Platform.Sockets.boundFile(of: listener)! == bound)
        let otherBound = try #require(Platform.Sockets.boundFile(of: other))
        #expect(Platform.Sockets.boundFile(otherBound, is: renamedOver))

        let unbound = try Self.streamSocket()
        defer { Sys.close(unbound) }
        #expect(Platform.Sockets.boundFile(of: unbound) == nil)
        var ends: [Int32] = [-1, -1]
        #expect(Sys.pipeClosedOnExec(&ends) == 0)
        defer { ends.forEach { Sys.close($0) } }
        #expect(Platform.Sockets.boundFile(of: ends[0]) == nil)
    }

    /// The Mac can't ask the kernel what file a socket is bound to: nil, and callers keep their check through the path.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's form"))
    func theMacKnowsNoBoundFile() throws {
        let folder = try Self.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let listener = try Self.listener(at: folder.appendingPathComponent("s").path)
        defer { Sys.close(listener) }
        #expect(Platform.Sockets.boundFile(of: listener) == nil)
    }
}

extension SocketsTests {
    // MARK: A listener's file, its owner's alone

    /// Linux: the file `bindOwnerOnly` binds is 0600 the moment the bind returns (the socket's own mode, set before
    /// it), and nothing goes through the path after: a link to a file of the test's (0644) renamed over the path just
    /// after the bind (the call's test hook) is not followed, and that file keeps its mode. The Mac's form chmods the
    /// path after the bind, as the Mac always did.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux sets the mode before the bind; the Mac chmods after it"))
    func aListenersFileIsOwnerOnlyFromItsBindAndNoLinkIsFollowed() throws {
        let folder = try Self.socketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("t").path
        #expect(FileManager.default.createFile(atPath: target, contents: nil))
        #expect(chmod(target, 0o644) == 0)
        func mode(_ path: String) -> mode_t? {
            var info = stat()
            return lstat(path, &info) == 0 ? info.st_mode & 0o777 : nil
        }
        let path = folder.appendingPathComponent("s").path
        let link = folder.appendingPathComponent("l").path
        let address = try #require(Platform.Sockets.unixAddress(path))
        let fd = try Self.streamSocket()
        defer { Sys.close(fd) }
        var atBind: mode_t?
        let failed = Platform.Sockets.bindOwnerOnly(fd, to: address, path: path, mode: 0o600) {
            atBind = mode(path)
            #expect(symlink(target, link) == 0)
            #expect(rename(link, path) == 0)
        }
        #expect(failed == nil, "\(String(describing: failed))")
        #expect(atBind == 0o600, "the file was \(atBind.map { String($0, radix: 8) } ?? "not there") as the bind returned")
        #expect(mode(target) == 0o644, "the link renamed over the path was followed")
    }
}
