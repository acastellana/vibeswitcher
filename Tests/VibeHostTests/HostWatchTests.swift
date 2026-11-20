import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// `HostRequest.watch` (`Sources/VibeHost/V2/HostWatch.swift`): a client that watches a session gets its replay and
/// output as an attached one does, without taking its terminal over: the host's parser goes on answering the
/// program's queries, the session keeps its size, and a client that attached keeps the replies. Scratch programs only
/// (`/bin/sh -c`), on a scratch host.
@Suite(hostTestLimit) struct HostWatchTests {
    /// Asks twice where its cursor is, each time once a key came: the cursor sent home first, so the host's own answer
    /// is `ESC[1;1R`, six bytes, which `od` prints after "first" and "second".
    static let twoQueries = "stty raw -echo; echo WAITING; "
        + "dd bs=1 count=1 >/dev/null 2>&1; printf '\\033[H\\033[6n'; dd bs=1 count=6 2>/dev/null | od -An -c; echo first; "
        + "dd bs=1 count=1 >/dev/null 2>&1; printf '\\033[H\\033[6n'; dd bs=1 count=6 2>/dev/null | od -An -c; echo second; "
        + "stty sane; \(keepRunning)"

    /// What `od -An -c` printed before `marker`, without spaces (after the one before it, when given).
    static func odBefore(_ marker: String, after earlier: String? = nil, in text: String) -> String {
        var rest = text
        if let earlier, let range = rest.range(of: earlier) { rest = String(rest[range.upperBound...]) }
        guard let range = rest.range(of: marker) else { return "" }
        return String(rest[..<range.lowerBound]).filter { $0 != " " }
    }

    static func attachedClients(_ host: TestHost, _ id: UUID) -> Bool? {
        host.server.queue.sync { host.server.sessions[id]?.clientsAttached }
    }

    func watch(_ client: TestClient, _ id: UUID) async -> HostEvent? {
        let seq = client.send(.watch(id: id))
        _ = await eventually { client.reply(to: seq) != nil }
        return client.reply(to: seq)
    }

    /// The welcome lists the capability the node's link asks before it watches.
    @Test func theWelcomeListsWatch() async throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let seq = client.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(await eventually { client.reply(to: seq) != nil })
        guard case .welcome(_, _, _, let capabilities, _, _) = client.reply(to: seq) else { Issue.record("no welcome"); return }
        #expect(capabilities?.contains(HostProtocol.Capability.watch) == true)
    }

    /// A watcher gets the replay, then the live output, and isn't counted as attached: the session keeps its size, and
    /// its program's query is answered by the host's parser (Linux checks the reply against the query; the Mac passes
    /// every reply while nothing is attached, as before).
    @Test func aWatcherSeesTheSessionAndTheHostStillAnswersItsQueries() async throws {
        let host = try TestHost()
        let watcher = try TestClient(host)
        let session = try await watcher.spawn(Self.twoQueries)
        // The program has printed before the watch: it comes as the replay.
        #expect(await eventually { watcher.screen(session.id)?.contains("WAITING") == true })
        #expect(await watch(watcher, session.id) == .attached(id: session.id))
        #expect(watcher.text(session.id).contains("WAITING"), "the replay: \(watcher.text(session.id).debugDescription)")
        #expect(Self.attachedClients(host, session.id) == false)
        // A key from the watcher (the app's connection may type) doesn't make it the session's either.
        watcher.send(.input(id: session.id, bytes: Data("g".utf8), reply: false))
        #expect(await eventually { watcher.text(session.id).contains("first") }, "\(watcher.text(session.id).debugDescription)")
        #expect(Self.odBefore("first", in: watcher.text(session.id)).contains("033[1;1R"), "\(watcher.text(session.id).debugDescription)")
        #expect(Self.attachedClients(host, session.id) == false)
        let info = host.server.queue.sync { host.server.sessions[session.id]?.info }
        #expect(info?.cols == 80 && info?.rows == 24, "a watch sizes nothing: \(String(describing: info))")
    }

    /// The app's attach is as it was: beside a watcher that came after it, the app still answers the program's query
    /// (its reply is typed, the host's isn't); once the app detaches, only the watcher is left, and the host answers.
    @Test func aWatcherBesideTheAppLeavesTheRepliesToTheApp() async throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let session = try await app.spawn(Self.twoQueries)
        await app.attach(session.id)
        #expect(await eventually { app.text(session.id).contains("WAITING") })
        let watcher = try TestClient(host)
        #expect(await watch(watcher, session.id) == .attached(id: session.id))
        #expect(Self.attachedClients(host, session.id) == true)
        app.send(.input(id: session.id, bytes: Data("g".utf8), reply: false))
        #expect(await eventually { app.text(session.id).contains("\u{1b}[6n") })
        // The app's emulator answers, as the Mac's does; the watcher came last and still isn't the one whose replies count.
        app.send(.input(id: session.id, bytes: Data("\u{1b}[5;1R".utf8), reply: true))
        #expect(await eventually { watcher.text(session.id).contains("first") }, "\(watcher.text(session.id).debugDescription)")
        let first = Self.odBefore("first", in: watcher.text(session.id))
        #expect(first.contains("033[5;1R") && !first.contains("033[1;1R"), "\(first.debugDescription)")

        let detach = app.send(.detach(id: session.id))
        #expect(await eventually { app.reply(to: detach) == .ok })
        #expect(Self.attachedClients(host, session.id) == false)
        watcher.send(.input(id: session.id, bytes: Data("g".utf8), reply: false))
        #expect(await eventually { watcher.text(session.id).contains("second") }, "\(watcher.text(session.id).debugDescription)")
        #expect(Self.odBefore("second", after: "first", in: watcher.text(session.id)).contains("033[1;1R"),
                "\(watcher.text(session.id).debugDescription)")
    }

    /// A watcher's reply is never typed (it is never the one whose replies count), and its resize-free watch becomes
    /// a full attachment when the same connection attaches.
    @Test func aWatchersReplyIsNotTypedAndAnAttachTakesOver() async throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try await client.spawn("read x; echo got:$x; \(keepRunning)")
        #expect(await watch(client, session.id) == .attached(id: session.id))
        client.send(.input(id: session.id, bytes: Data("zzz".utf8), reply: true))
        client.send(.input(id: session.id, bytes: Data("ok\r".utf8), reply: false))
        #expect(await eventually { client.text(session.id).contains("got:") }, "\(client.text(session.id).debugDescription)")
        #expect(client.text(session.id).contains("got:ok") && !client.text(session.id).contains("zzz"), "\(client.text(session.id).debugDescription)")
        #expect(Self.attachedClients(host, session.id) == false)
        await client.attach(session.id)
        #expect(Self.attachedClients(host, session.id) == true)
        let detach = client.send(.detach(id: session.id))
        #expect(await eventually { client.reply(to: detach) == .ok })
        #expect(Self.attachedClients(host, session.id) == false)
    }

    /// A watch is authorized as an attach is: a process that may not reach the session is refused, and a session the
    /// host doesn't run is answered so.
    @Test func aWatchIsAuthorizedAsAnAttachIs() async throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let session = try await app.spawn(keepRunning)
        let other = try TestClient(host, asApp: false)
        #expect(await watch(other, session.id) == .error(HostProtocol.unauthorized))
        #expect(other.text(session.id).isEmpty)
        #expect(await watch(app, UUID()) == .error(HostProtocol.noSuchSession))
    }
}
