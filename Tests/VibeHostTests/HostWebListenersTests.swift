import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// H1's host side (`HostWebListeners`, `AppConnector`'s web requests): the host binds what its server child asks for and
/// holds it, a second ask gets the same socket, nothing else binds the port while it is held, a release frees it; the
/// host's own check refuses an address outside loopback or the tailnet's range, and another port on the user's host,
/// before binding; a handover's socket is held again only when it is one; and only the server child's connector gets
/// one, beside its connection requests, which work as before.
struct HostWebListenersTests {
    /// The device and inode `fd` names now, nil when it names nothing.
    static func identity(_ fd: Int32) -> [UInt64]? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return [UInt64(info.st_dev), UInt64(info.st_ino)]
    }

    private let scratch = Scratch()

    private func squat(_ port: UInt16) -> Bool {
        guard case .success(let fd) = Platform.TCP.listen(family: .ipv4, address: "127.0.0.1", port: port, backlog: 1) else { return false }
        Sys.close(fd)
        return true
    }

    @Test func aSocketIsBoundOnceHeldAndFreedOnRelease() throws {
        let lines = Lines()
        let held = HostWebListeners(usersHost: false, note: { line in lines.add(line) })
        defer { held.closeAll() }
        let fd = try held.listen(.loopback, address: "127.0.0.1", port: 0).get()
        let port = try #require(held.port(.loopback))
        #expect(Platform.TCP.isListening(fd) && Platform.TCP.localPort(fd) == port)
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0, "no session inherits it")
        // Asked again (port 0, or its port): the same socket, not a second.
        #expect(try held.listen(.loopback, address: "127.0.0.1", port: 0).get() == fd)
        #expect(try held.listen(.loopback, address: "127.0.0.1", port: port).get() == fd)
        #expect(!squat(port), "held: no other socket binds it")
        held.release(.loopback)
        #expect(held.port(.loopback) == nil && squat(port), "released: free")
        held.release(.loopback)
        let said = lines.all
        #expect(said.contains("web listener loopback bound on 127.0.0.1:\(port), held for the server"), "\(said)")
        #expect(said.contains("web listener loopback 127.0.0.1:\(port) closed: the web went off"), "\(said)")
    }

    @Test func theHostsOwnCheckRefusesBeforeBinding() {
        let scratchHost = HostWebListeners(usersHost: false, note: { _ in })
        let usersHost = HostWebListeners(usersHost: true, note: { _ in })
        defer { scratchHost.closeAll(); usersHost.closeAll() }
        for (place, address, port, host) in [(HostWebListen.Place.tailnet, "10.1.2.3", UInt16(0), scratchHost), (.tailnet, "127.0.0.1", 0, scratchHost),
                                             (.loopback, "0.0.0.0", 0, scratchHost), (.loopback, "127.0.0.2", 0, scratchHost),
                                             (.loopback, "127.0.0.1", 0, usersHost), (.loopback, "127.0.0.1", 8080, usersHost)] {
            guard case .failure(let refusal) = host.listen(place, address: address, port: port) else {
                Issue.record("\(place) \(address):\(port) bound")
                continue
            }
            #expect(!refusal.why.contains("couldn't be bound"), "refused by the check, not the bind: \(refusal.why)")
            #expect(host.port(place) == nil)
        }
    }

    @Test func aHandoversSocketIsHeldAgainOnlyWhenItIsOne() throws {
        let held = HostWebListeners(usersHost: false, note: { _ in })
        defer { held.closeAll() }
        // As the exec leaves it: inherited (not close-on-exec), listening on what its record says.
        let carried = try Platform.TCP.listen(family: .ipv4, address: "127.0.0.1", port: 0, backlog: 4).get()
        let port = try #require(Platform.TCP.localPort(carried))
        _ = fcntl(carried, F_SETFD, 0)
        let wrong = try Platform.TCP.listen(family: .ipv4, address: "127.0.0.1", port: 0, backlog: 4).get()
        _ = fcntl(wrong, F_SETFD, 0)
        // What `wrong` is, by identity: once closed its number can be another test's open in this process, so the check
        // below asks whether that number still names this socket, not whether it names anything (the CI flake of
        // 2026-11-22).
        let wrongIdentity = Self.identity(wrong)
        let made = try Platform.TCP.listen(family: .ipv4, address: "127.0.0.1", port: 0, backlog: 4).get()
        defer { Sys.close(made) }
        held.adopt([.init(place: "loopback", address: "127.0.0.1", port: port, fd: carried),
                    // Its record lies about its port; another is this image's own (close-on-exec); another names a place there is none of.
                    .init(place: "tailnet", address: "100.64.0.1", port: 1, fd: wrong),
                    .init(place: "loopback", address: "127.0.0.1", port: Platform.TCP.localPort(made)!, fd: made),
                    .init(place: "phone", address: "127.0.0.1", port: 2, fd: 99_999)], others: [])
        #expect(held.port(.loopback) == port && held.port(.tailnet) == nil)
        #expect(fcntl(carried, F_GETFD) & FD_CLOEXEC != 0, "made close-on-exec once held again")
        #expect(wrongIdentity != nil && Self.identity(wrong) != wrongIdentity, "a socket not held again is closed")
        #expect(fcntl(made, F_GETFD) >= 0, "a descriptor this image made is never closed for a record")
        #expect(held.records == [.init(place: "loopback", address: "127.0.0.1", port: port, fd: carried)])
        #expect(try held.listen(.loopback, address: "127.0.0.1", port: port).get() == carried)
    }

    /// Over a connector that isn't the server child's (no server child runs): refused, and its connection requests
    /// still made.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's connector"))
    func onlyTheServerChildsConnectorGetsASocket() throws {
        let dir = scratch.url("web-host").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let host = try TestHost(vault: LeadVault.Book(), log: dir + "/host.log", appConnector: false, removing: dir)
        let connector = try #require(host.server.openAppConnector(expecting: Platform.Processes.token(getpid()), requireNonDumpable: false,
                                                                  onDumpable: nil))
        defer {
            host.server.closeAppConnector(connector)
            Sys.close(connector)
        }
        let answer = try HostConnector.web(.listen(.loopback, address: "127.0.0.1", port: 0), over: connector, timeout: 30)
        #expect(answer == .refused("only the server child holds the web's listeners"), "\(answer)")
        #expect(try HostConnector.web(.release(.loopback), over: connector, timeout: 30) == .refused("only the server child holds the web's listeners"))
        let connection = try HostConnector.connect(over: connector, timeout: 30)
        Sys.close(connection)
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
