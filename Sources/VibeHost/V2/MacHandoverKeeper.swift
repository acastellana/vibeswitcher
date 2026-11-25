import Foundation
import VibeCore

/// The Mac's switch through a proven keeper (the node on the Mac's design, "The checked node start", "A switch"; the
/// review of 2026-11-25, F6). macOS has no exec from a descriptor: an in-place exec runs what the path names at that
/// moment, whatever was checked before. So the state, the secrets and every descriptor (the lock, the listener, the
/// secrets' channel, each session's terminal) never cross the exec. The old host parks them with a keeper, the target
/// started from the path as a child of the host, once the keeper's running code proved, by a fresh audit token, to be
/// the code the path check found (`expected`); the host then execs the target with only a channel to the keeper; and
/// the keeper gives them back only to the image at the host's pid whose fresh token runs the keeper's own code.
///
/// Fresh tokens: a stream pair's `LOCAL_PEERTOKEN` names the process that made the pair, fixed at its making, and
/// Security refuses a token whose process exec'd since. So each proof is a pair made by the process proving itself,
/// after its exec, one end sent over the channel it inherited (`SCM_RIGHTS`); the inherited channel's own token proves
/// nothing and is never asked.
///
/// What stays: a file swapped between the keeper's proof and the host's exec runs at the host's pid. It gets nothing
/// (the keeper refuses it and closes everything), but the old image is gone by then and the sessions end.
public enum MacHandoverKeeper {
    /// A keeper's arguments: `--handover-keeper FD`, FD its end of the channel to the old host.
    public static let keeperFlag = "--handover-keeper"
    /// The new image's: `--handover-keeper-channel FD`, FD the host's end of the channel to its keeper, and
    /// `--handover-keeper-pid PID`, the keeper it reaps once it has what it held.
    public static let channelFlag = "--handover-keeper-channel"
    public static let pidFlag = "--handover-keeper-pid"
    /// How long a keeper may take to prove itself, and to take the parcel (amfid's first look at a new build on a loaded
    /// Mac, as the probe's `HostHandover.probeLimit`).
    static let limit: TimeInterval = HostHandover.probeLimit
    /// A keeper's limit for the new image, in seconds, when shorter than `limit`: `--handover-keeper-limit S` (the old
    /// host's; it only shortens the keeper's own wait).
    public static let limitFlag = "--handover-keeper-limit"
    /// How long the old host waits for the keeper's word that it took the parcel, on its queue (decoding a state).
    static let parkLimit: TimeInterval = 30
    /// The keeper's answer once it read the parcel whole: it can give it back.
    static let parked: UInt8 = 0x6b

    public struct Refused: Error, CustomStringConvertible, Equatable {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    /// A keeper started and proven: its pid, the host's end of the channel (what the new image inherits), and the host's
    /// end of the pair the keeper made (what the parcel goes over).
    struct Keeper {
        var pid: pid_t
        var channel: Int32
        var proven: Int32
    }

    /// Why the process behind `token` isn't `pid` running `cdhash` with the Hardened Runtime, or nil when it is.
    static func refusal(_ token: Platform.PeerToken?, pid: pid_t, cdhash: Data, what: String,
                        runs: (Platform.PeerToken, Data) -> Bool = { Platform.CodeIdentity.runs($0, cdhash: $1) },
                        hardened: (Platform.PeerToken) -> Bool? = Platform.CodeIdentity.isHardened) -> String? {
        guard let token else { return "\(what)'s token can't be read" }
        guard token.pid == pid else { return "\(what) is pid \(token.pid), not \(pid)" }
        guard runs(token, cdhash) else { return "\(what) (pid \(pid)) doesn't run the code checked (\(NodePins.hex(cdhash)))" }
        guard hardened(token) == true else { return "\(what) (pid \(pid)) doesn't run with the Hardened Runtime" }
        return nil
    }

    // MARK: The handshake's rules

    // Every pair is passed (`SCM_RIGHTS`) by the process that made it, which keeps its own copy of the end it passed
    // open until the receiver has said, by a byte over the socket it was passed on (whose far end the receiver alone
    // holds, so a receiver that went is seen at once), that it holds that end; and nothing is written over a pair whose
    // other end is still in flight. A socket in flight whose sender had closed its copy was found broken under load (its
    // receiver read an end of file before the parcel was whole, or its peer's write failed: the re-check's flake, 8 of
    // 20 runs), as the kernel's collection of descriptors in flight would leave one it took for unreachable.

    /// The byte that says "I hold the end you passed, go on".
    static let holding: UInt8 = 0x67

    /// Reads and writes on `socket` fail after `seconds` (`SO_RCVTIMEO`, `SO_SNDTIMEO`) rather than wait for ever.
    static func limitIO(_ socket: Int32, _ seconds: TimeInterval) {
        var time = timeval(tv_sec: Int(max(1, seconds)), tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes the `holding` byte on `socket`.
    static func sayHolding(_ socket: Int32) -> Bool {
        var byte = holding
        return Sys.write(socket, &byte, 1) == 1
    }

    /// Waits (within `seconds`) for the `holding` byte on `socket`.
    static func awaitHolding(_ socket: Int32, _ seconds: TimeInterval) -> Bool {
        wait(readable: socket, for: seconds) && readByte(socket) == holding
    }

    // MARK: The old host's side

    /// `executable` started as a keeper (a child of this process, its own process group), proven: its fresh pair's token
    /// is its pid, runs `expected`, hardened. Otherwise it is ended and reaped, and why. Blocks (not on the host's queue).
    static func start(_ executable: String, expected: Data, limit keeperLimit: TimeInterval = limit) -> Result<Keeper, Refused> {
        guard let (host, keeper) = Platform.Sockets.pair(type: Platform.Sockets.stream) else { return .failure(Refused("no channel (errno \(errno))")) }
        var spawn = Platform.Spawn(executable: executable, arguments: [executable, keeperFlag, String(keeper), limitFlag, String(Int(max(1, keeperLimit)))])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .path("/dev/null", flags: O_WRONLY)
        spawn.stderr = .inherit
        spawn.keep = [keeper]
        let started = spawn.start()
        Sys.close(keeper)
        let pid: pid_t
        switch started {
        case .failure(let error):
            Sys.close(host)
            return .failure(Refused("the keeper didn't start: \(String(cString: strerror(error.code)))"))
        case .success(let spawned): pid = spawned
        }
        limitIO(host, limit)
        let fail = { (why: String) -> Result<Keeper, Refused> in
            Sys.close(host)
            end(pid)
            return .failure(Refused(why))
        }
        guard wait(readable: host, for: limit) else { return fail("the keeper didn't prove itself in \(Int(limit)) s") }
        guard let proven = Platform.Sockets.receiveDescriptor(over: host) else { return fail("the keeper sent no pair of its own") }
        limitIO(proven, parkLimit)
        if let why = refusal(Platform.Sockets.peerToken(proven), pid: pid, cdhash: expected, what: "the keeper") {
            Sys.close(proven)
            return fail(why)
        }
        // It may close its copy now: this end is held (said over the socket it came on, whose far end the keeper alone
        // holds, so a keeper that went is seen at once).
        guard sayHolding(host) else {
            Sys.close(proven)
            return fail("the keeper has gone")
        }
        return .success(Keeper(pid: pid, channel: host, proven: proven))
    }

    /// `state` and every descriptor it names given to `keeper`, and its word that it read them whole; false otherwise
    /// (then `abandon` it). The host proves itself to the keeper first (the re-check's I2a): a pair made now, one end
    /// passed, its own copy held until the keeper says it holds it, the parcel over the other. On the host's queue, in
    /// the handover's last turn.
    static func park(_ state: HostHandover.State, with keeper: Keeper) -> Result<Void, Refused> {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(state) else { return .failure(Refused("the state couldn't be encoded")) }
        guard let (mine, theirs) = Platform.Sockets.pair(type: Platform.Sockets.stream) else { return .failure(Refused("no pair (errno \(errno))")) }
        defer { Sys.close(mine) }
        limitIO(mine, parkLimit)
        let passed = Platform.Sockets.sendDescriptor(theirs, over: keeper.proven)
        let held = passed && awaitHolding(keeper.proven, parkLimit)
        Sys.close(theirs)
        guard held else { return .failure(Refused("the keeper didn't take this host's pair (it refuses a parent it can't prove)")) }
        guard send(data, descriptors: state.descriptors, over: mine) else { return .failure(Refused("the state didn't reach the keeper (errno \(errno))")) }
        guard wait(readable: mine, for: parkLimit), readByte(mine) == parked else {
            return .failure(Refused("the keeper didn't take the state"))
        }
        return .success(())
    }

    /// A keeper no longer wanted (the handover failed before the exec): its channel closed, it ended and reaped.
    static func abandon(_ keeper: Keeper) {
        Sys.close(keeper.proven)
        Sys.close(keeper.channel)
        end(keeper.pid)
    }

    // MARK: The keeper

    /// What a keeper requires of its parent's code, from the parcel it is offered: none for a scratch host's (its pid
    /// and the Hardened Runtime only); for a checked node's (`fromCheckedNode`), a host the root record pins (`pins`,
    /// the installed record, never a value of the keeper's arguments). Why not, or nil.
    static func parentRefusal(_ token: Platform.PeerToken?, parent: pid_t, state: HostHandover.State,
                              pins: () -> Result<NodePins, NodePins.Refused> = { NodePins.read() },
                              runs: (Platform.PeerToken, Data) -> Bool = { Platform.CodeIdentity.runs($0, cdhash: $1) },
                              hardened: (Platform.PeerToken) -> Bool? = Platform.CodeIdentity.isHardened) -> String? {
        guard let token else { return "its parent's token can't be read" }
        guard token.pid == parent else { return "its parent is pid \(parent), not \(token.pid)" }
        guard hardened(token) == true else { return "its parent (pid \(parent)) doesn't run with the Hardened Runtime" }
        guard state.fromCheckedNode == true else { return nil }
        guard case .success(let record) = pins() else { return "a checked node's state, and no record of the node's builds to prove its parent by" }
        guard record.builds.contains(where: { runs(token, $0.host) }) else {
            return "a checked node's state from a parent (pid \(parent)) that runs no host the node's record pins"
        }
        return nil
    }

    /// `main`'s first act after the probe's: with `--handover-keeper FD` as its first argument, this process is a keeper
    /// and never returns. It proves itself to the host (a pair it makes, one end sent over FD), takes the host's own pair
    /// over it and proves the host (`parentRefusal`), takes the parcel, says so, then gives it back only to the host's new
    /// image: a pair that image made, its token the host's pid (this process's parent), running this process's own code,
    /// hardened. Anything else, or any step past its limit: it closes everything and exits.
    public static func keepIfAsked(_ arguments: [String], isAvailable: Bool = Platform.CodeIdentity.isAvailable) {
        // Linux has no keeper: the flag means nothing there, as before (the review's N7).
        guard isAvailable else { return }
        guard arguments.count >= 3, arguments[1] == keeperFlag else { return }
        // Before it writes anything (its pairs are SO_NOSIGPIPE already; its stderr isn't).
        signal(SIGPIPE, SIG_IGN)
        guard let channel = Int32(arguments[2]), channel > STDERR_FILENO else { quit("no channel") }
        _ = fcntl(channel, F_SETFD, FD_CLOEXEC)
        let wanted = arguments.firstIndex(of: limitFlag).flatMap { arguments.indices.contains($0 + 1) ? TimeInterval(arguments[$0 + 1]) : nil }
        let keeperLimit = min(limit, max(1, wanted ?? limit))
        limitIO(channel, keeperLimit)
        let host = getppid()
        guard let own = Platform.CodeIdentity.ownCdhash() else { quit("its own code can't be read") }
        guard let (mine, theirs) = Platform.Sockets.pair(type: Platform.Sockets.stream),
              Platform.Sockets.sendDescriptor(theirs, over: channel) else { quit("its pair didn't reach the host") }
        limitIO(mine, keeperLimit)
        // `theirs` held until the host says, over the channel, that it holds it.
        guard awaitHolding(channel, keeperLimit) else { quit("the host didn't take its pair") }
        Sys.close(theirs)
        // The host's own pair: proved once the parcel says what it is.
        guard wait(readable: mine, for: keeperLimit), let parent = Platform.Sockets.receiveDescriptor(over: mine) else { quit("the host sent no pair of its own") }
        limitIO(parent, keeperLimit)
        guard sayHolding(mine) else { quit("the host has gone") }
        guard wait(readable: parent, for: keeperLimit), let parcel = receive(over: parent) else { quit("no state came") }
        guard let offered = try? PropertyListDecoder().decode(HostHandover.State.self, from: parcel.data) else { quit("the state doesn't read") }
        if let why = parentRefusal(Platform.Sockets.peerToken(parent), parent: host, state: offered) { quit("refused the host: \(why); nothing taken") }
        var byte = parked
        guard Sys.write(parent, &byte, 1) == 1 else { quit("the host has gone") }
        // The host's exec closes its ends; the new image's pair arrives on the channel (or the channel ends: the handover
        // failed before the exec, or the host went), within the limit: past it, everything held is closed with this
        // process (the review's N6; the sessions end, as in the residual).
        guard wait(readable: channel, for: keeperLimit) else { quit("no new image came within its limit: everything held closed") }
        guard let theirsNow = Platform.Sockets.receiveDescriptor(over: channel) else { quit("no new image came (the handover ended before its exec)") }
        limitIO(theirsNow, keeperLimit)
        if let why = refusal(Platform.Sockets.peerToken(theirsNow), pid: host, cdhash: own, what: "the image at the host's pid") {
            quit("refused the new image: \(why); nothing handed over")
        }
        guard sayHolding(channel) else { quit("the new image has gone") }
        // The new image proves this keeper in turn (the review's N2): a pair made here, now, one end given to it and held
        // until it says it holds it, the parcel over the other.
        guard let (keeps, gives) = Platform.Sockets.pair(type: Platform.Sockets.stream),
              Platform.Sockets.sendDescriptor(gives, over: theirsNow) else { quit("its own pair didn't reach the new image") }
        limitIO(keeps, keeperLimit)
        guard awaitHolding(theirsNow, keeperLimit) else { quit("the new image didn't take its pair (it refuses a keeper it can't prove)") }
        Sys.close(gives)
        guard send(parcel.data, descriptors: parcel.descriptors, over: keeps) else { quit("the state didn't reach the new image") }
        // Alive until the new image has read the parcel and closed its end, within the limit; then its copies close with
        // it, and the new image's are the only ones left.
        let closed = wait(readable: keeps, for: keeperLimit)
        if closed { _ = readByte(keeps) }
        Platform.Stdio.error("vibeswitcher-host: handover keeper: gave the state to the new image (pid \(host))"
                             + (closed ? "" : ", which didn't close its end within the limit") + "\n")
        exit(0)
    }

    private static func quit(_ why: String) -> Never {
        Platform.Stdio.error("vibeswitcher-host: handover keeper: \(why)\n")
        exit(1)
    }

    // MARK: The new image's side

    /// With `--handover-keeper-channel FD` and `--handover-keeper-pid PID` in `arguments` (a scratch host's switch): the
    /// state its keeper held (`take`); nil without the flag. A checked node's `main` calls `take` with its parsed values.
    public static func takeIfAsked(_ arguments: [String], isAvailable: Bool = Platform.CodeIdentity.isAvailable) -> Result<HostHandover.State, Refused>? {
        // Linux has no keeper: the state is read as before (the review's N7).
        guard isAvailable else { return nil }
        guard let at = arguments.firstIndex(of: channelFlag) else { return nil }
        guard arguments.indices.contains(at + 1), let channel = Int32(arguments[at + 1]), channel > STDERR_FILENO else {
            return .failure(Refused("\(channelFlag) needs a descriptor"))
        }
        guard let pidAt = arguments.firstIndex(of: pidFlag), arguments.indices.contains(pidAt + 1), let keeper = pid_t(arguments[pidAt + 1]), keeper > 1 else {
            Sys.close(channel)
            return .failure(Refused("\(pidFlag) names no keeper"))
        }
        return take(channel: channel, keeper: keeper)
    }

    /// The state the keeper `keeper` held, its descriptors renumbered to the ones received, once this image proved its
    /// code to it (a pair made now, one end sent over `channel`, held until the keeper says it holds it) and the keeper
    /// proved its own to this image (a pair it made then, its token `keeper`'s pid, a child of this process, running this
    /// image's own code, hardened). A failure is a refusal: nothing was given.
    public static func take(channel: Int32, keeper: pid_t) -> Result<HostHandover.State, Refused> {
        defer { Sys.close(channel) }
        guard keeper > 1, Platform.Processes.link(keeper)?.parent == getpid() else { return .failure(Refused("\(pidFlag) names no keeper of this process")) }
        guard let own = Platform.CodeIdentity.ownCdhash() else { return .failure(Refused("this image's own code can't be read")) }
        guard let (mine, theirs) = Platform.Sockets.pair(type: Platform.Sockets.stream) else { return .failure(Refused("no pair (errno \(errno))")) }
        defer { Sys.close(mine) }
        limitIO(mine, limit)
        limitIO(channel, limit)
        let sent = Platform.Sockets.sendDescriptor(theirs, over: channel)
        let held = sent && awaitHolding(channel, limit)
        Sys.close(theirs)
        guard held else { return .failure(Refused("the keeper didn't take this image's pair (errno \(errno))")) }
        guard wait(readable: mine, for: limit) else { return .failure(Refused("the keeper's pair didn't come within the limit (errno \(errno))")) }
        guard let kept = Platform.Sockets.receiveDescriptor(over: mine) else { return .failure(Refused("the keeper's pair didn't arrive (errno \(errno))")) }
        limitIO(kept, limit)
        if let why = refusal(Platform.Sockets.peerToken(kept), pid: keeper, cdhash: own, what: "the keeper") {
            Sys.close(kept)
            return .failure(Refused(why))
        }
        guard sayHolding(mine) else {
            Sys.close(kept)
            return .failure(Refused("the keeper has gone"))
        }
        let ready = wait(readable: kept, for: limit)
        let readyErrno = errno
        let received = ready ? receive(over: kept) : nil
        let receiveErrno = errno
        // Closed before the keeper is reaped: it waits for this end to close.
        Sys.close(kept)
        guard ready else { return .failure(Refused("the keeper's state didn't come within the limit (errno \(readyErrno))")) }
        guard let parcel = received else { return .failure(Refused("the keeper's state didn't arrive whole (errno \(receiveErrno))")) }
        // The keeper exits once it gave the parcel: reaped here, the proven keeper's pid alone (never a session's).
        var status: Int32 = 0
        while waitpid(keeper, &status, 0) < 0, errno == EINTR {}
        guard var state = try? PropertyListDecoder().decode(HostHandover.State.self, from: parcel.data) else {
            parcel.descriptors.forEach { Sys.close($0) }
            return .failure(Refused("the state doesn't read"))
        }
        guard let renumbered = renumber(&state, to: parcel.descriptors) else {
            parcel.descriptors.forEach { Sys.close($0) }
            return .failure(Refused("the state names descriptors the keeper didn't give, or what no Mac handover carries"))
        }
        return .success(renumbered)
    }

    /// `state` with each descriptor it names replaced by the one received in its place (`received`, in the order of
    /// `state.descriptors`); nil when the counts differ, or `state` carries what no Mac handover does (a server child, a
    /// sealed image, the web's sockets).
    static func renumber(_ state: inout HostHandover.State, to received: [Int32]) -> HostHandover.State? {
        guard state.serverChild == nil, state.images == nil, state.webListeners == nil else { return nil }
        let named = state.descriptors
        guard named.count == received.count else { return nil }
        var map: [Int32: Int32] = [:]
        for (old, new) in zip(named, received) {
            if let other = map[old], other != new { Sys.close(new); continue }
            map[old] = new
        }
        func new(_ fd: Int32) -> Int32 { map[fd] ?? -1 }
        var result = state
        result.lockFD = new(state.lockFD)
        result.listenFD = new(state.listenFD)
        result.secretFD = state.secretFD.map(new)
        result.testAppConnector?.fd = state.testAppConnector.map { new($0.fd) } ?? -1
        for index in result.sessions.indices { result.sessions[index].masterFD = state.sessions[index].masterFD.map(new) }
        return result
    }

    // MARK: The parcel

    /// The parcel on a stream: the state's length (8 bytes, big-endian) and bytes, the descriptors' count (4 bytes),
    /// then each descriptor on a byte of its own (`SCM_RIGHTS`).
    static func send(_ data: Data, descriptors: [Int32], over socket: Int32) -> Bool {
        var header = Data()
        withUnsafeBytes(of: UInt64(data.count).bigEndian) { header.append(contentsOf: $0) }
        var count = Data()
        withUnsafeBytes(of: UInt32(descriptors.count).bigEndian) { count.append(contentsOf: $0) }
        guard write(header + data + count, to: socket) else { return false }
        return descriptors.allSatisfy { Platform.Sockets.sendDescriptor($0, over: socket) }
    }

    /// The parcel `send` wrote, its descriptors close-on-exec; nil (each closed) when it ends early or says too much.
    static func receive(over socket: Int32) -> (data: Data, descriptors: [Int32])? {
        guard let header = read(8, from: socket) else { return nil }
        let length = header.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard length > 0, length <= 256 << 20, let data = read(Int(length), from: socket), let count = read(4, from: socket) else { return nil }
        let number = count.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard number <= 65_536 else { return nil }
        var descriptors: [Int32] = []
        for _ in 0..<number {
            guard let fd = Platform.Sockets.receiveDescriptor(over: socket) else {
                descriptors.forEach { Sys.close($0) }
                return nil
            }
            descriptors.append(fd)
        }
        return (data, descriptors)
    }

    private static func write(_ data: Data, to socket: Int32) -> Bool {
        var written = 0
        return data.withUnsafeBytes { raw in
            while written < raw.count {
                let count = Sys.write(socket, raw.baseAddress! + written, raw.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
    }

    private static func read(_ count: Int, from socket: Int32) -> Data? {
        var data = Data(count: count)
        var got = 0
        let ok = data.withUnsafeMutableBytes { raw in
            while got < count {
                let n = Sys.read(socket, raw.baseAddress! + got, count - got)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                got += n
            }
            return true
        }
        return ok ? data : nil
    }

    private static func readByte(_ socket: Int32) -> UInt8? { read(1, from: socket)?.first }

    /// Whether `socket` has something to read (or its end) within `seconds`.
    static func wait(readable socket: Int32, for seconds: TimeInterval) -> Bool {
        var waiting = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        let deadline = Platform.Clock.steadyDate().addingTimeInterval(seconds)
        while true {
            let left = Int32(max(0, min(Double(Int32.max), deadline.timeIntervalSince(Platform.Clock.steadyDate()) * 1000)))
            let ready = poll(&waiting, 1, left)
            // A poll that couldn't be made (EAGAIN: no room for its records) is tried again, as an interrupted one is.
            if ready < 0, errno == EINTR || errno == EAGAIN { continue }
            return ready > 0
        }
    }

    /// `pid` ended (SIGKILL) and reaped.
    static func end(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }
}
