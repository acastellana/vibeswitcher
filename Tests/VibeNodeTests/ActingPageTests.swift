import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The host's vault in the test's memory, as the app asks it (`LeadVaultV2.answer`, the app's caller).
final class MemoryVaultV2: @unchecked Sendable {
    private let lock = NSLock()
    private var book: LeadVaultV2.Book?
    var now: () -> Double = { Date().timeIntervalSince1970 }

    var client: LeadVaultV2Client {
        LeadVaultV2Client { [self] request in
            lock.withLock { LeadVaultV2.answer(request, from: .app, book: &book, now: now(), on: true) }
        }
    }
}

/// Acting from the page (the web UI design's step 2, "Acting from the page"), the parts that need no node: the vault's
/// record of it, which page tokens act (the vault's list, never the token file), the route an acting page's request
/// takes, and the screen that hands it on (the loopback page's alone).
struct ActingPageTests {
    private let scratch = Scratch()

    // MARK: The vault

    /// Off on a new record; on keeps its first `since`; a pairing acts only while on, until its end; off drops every
    /// acting pairing, so on again acts for none of them.
    @Test func theVaultKeepsActingAndItsPairings() throws {
        let vault = MemoryVaultV2()
        let client = vault.client
        let sha = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
        let until = (Date().timeIntervalSince1970 + 3_600).rounded()
        #expect(try client.pageActs() == .init(since: nil, tokens: [:]))
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.addActingToken(sha256: sha, until: until) }
        let on = try client.setPageActs(on: true)
        #expect(on.on)
        #expect(try client.setPageActs(on: true).since == on.since, "on again keeps its since")
        #expect(try client.addActingToken(sha256: sha, until: until).tokens == [sha: until])
        #expect(try client.addActingToken(sha256: other, until: until).tokens == [sha: until, other: until])
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.addActingToken(sha256: "not-hex", until: until) }
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.addActingToken(sha256: sha, until: Date().timeIntervalSince1970 - 1) }
        #expect(try client.dropActingTokens([sha]).tokens == [other: until])
        let off = try client.setPageActs(on: false)
        #expect(off == .init(since: nil, tokens: [:]))
        _ = try client.setPageActs(on: true)
        #expect(try client.pageActs().tokens.isEmpty, "a pairing from before an off never acts again")
    }

    /// A pairing past its end is dropped at the next ask.
    @Test func anActingPairingEnds() throws {
        let vault = MemoryVaultV2()
        let start = Date().timeIntervalSince1970
        vault.now = { start }
        let client = vault.client
        _ = try client.setPageActs(on: true)
        _ = try client.addActingToken(sha256: String(repeating: "c", count: 64), until: start + 60)
        vault.now = { start + 61 }
        #expect(try client.pageActs().tokens.isEmpty)
    }

    /// A request made from a page is recorded as the user's with the page's mark; a terminal's has none.
    @Test func aPagesActionIsRecordedWithItsMark() throws {
        let client = MemoryVaultV2().client
        #expect(try client.recordPageAction("a1", kind: "answer", subject: "card", digest: "d", via: "page 0123456789ab from http://127.0.0.1:8765"))
        #expect(try client.recordUserAction("a2", kind: "answer", subject: "card", digest: "d"))
        let actions = try client.userActions()
        #expect(actions.map(\.via) == ["page 0123456789ab from http://127.0.0.1:8765", nil])
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.recordPageAction("a3", kind: "answer", subject: nil, digest: "d", via: "") }
    }

    // MARK: Which pages act

    /// A loopback page's gate, its acting from `vault` loaded (as at a welcome).
    private func gate(_ vault: MemoryVaultV2?, root: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) -> WebAccess {
        let access = WebAccess(tokens: WebTokens(root: root ?? scratch.url("web-root-\(UUID().uuidString.prefix(6))")))
        access.acting = vault.map { ActingPages(vault: $0.client, now: now) }
        access.acting?.refreshLater()
        access.acting?.settled()
        return access
    }

    private func pair(_ access: WebAccess) throws -> WebAdmission {
        let admitted = try #require(access.admit(["pair": .string(access.openCode(now: Date()))]))
        access.acting?.settled()
        return admitted
    }

    /// Paired while on, a page acts and is given its acting secret once; on its token alone (a reload: the secret was in
    /// the page's memory only) it reads and drafts; with both it acts again, after a restart too (the vault outlives the
    /// server); paired while off, it never acts; a gate with no `acting` (the tailnet's) never grants it.
    @Test func aPagePairedWhileOnActsWithItsSecret() throws {
        let vault = MemoryVaultV2()
        let root = scratch.url("web-root")
        let access = gate(vault, root: root)
        let before = try pair(access)
        #expect(before.rights == [.read, .draft] && before.act == nil && before.auth["act"] == nil, "paired while off")
        _ = try access.acting?.set(on: true)
        let paired = try pair(access)
        let secret = try #require(paired.act)
        #expect(paired.rights == [.read, .draft, .act])
        #expect(paired.auth["rights"]?.array?.compactMap(\.string) == ["read", "draft", "act"] && paired.auth["act"]?.string == secret)
        #expect(try client(vault).pageActs().tokens.keys.contains(ActingPages.key(token: paired.token, secret: secret)))
        #expect(!(try client(vault).pageActs().tokens.keys.contains(ActingPages.digest(paired.token))), "never the token's own digest")
        let reloaded = try #require(access.admit(["token": .string(paired.token)]))
        #expect(reloaded.rights == [.read, .draft] && reloaded.auth["act"] == nil, "a reload reads and drafts")
        #expect(try #require(access.admit(["token": .string(paired.token), "act": .string("not-it")])).rights == [.read, .draft])
        let reconnected = try #require(access.admit(["token": .string(paired.token), "act": .string(secret)]))
        #expect(reconnected.rights == [.read, .draft, .act] && reconnected.auth["act"] == nil, "the secret is given once")
        #expect(try #require(access.admit(["token": .string(before.token), "act": .string(secret)])).rights == [.read, .draft], "another token's")
        let restarted = gate(vault, root: root)
        #expect(try #require(restarted.admit(["token": .string(paired.token), "act": .string(secret)])).rights == [.read, .draft, .act], "after a restart")
        let noActing = WebAccess(tokens: WebTokens(root: root))
        #expect(try #require(noActing.admit(["token": .string(paired.token), "act": .string(secret)])).rights == [.read, .draft], "a gate with no acting")
    }

    private func client(_ vault: MemoryVaultV2) -> LeadVaultV2Client { vault.client }

    /// A token any process wrote into the token file (issued there, never paired) reads and drafts, and never acts.
    @Test func aTokenFromTheFileNeverActs() throws {
        let vault = MemoryVaultV2()
        let access = gate(vault)
        _ = try access.acting?.set(on: true)
        let minted = try access.tokens.issue(now: Date()).token
        #expect(try #require(access.admit(["token": .string(minted)])).rights == [.read, .draft])
        #expect(try #require(access.admit(["token": .string(minted), "act": .string(minted)])).rights == [.read, .draft])
    }

    /// An acting pairing lives 12 hours at most: then it acts no more, at the next request as at the next auth.
    @Test func anActingPairingLivesTwelveHoursAtMost() throws {
        let vault = MemoryVaultV2()
        let clock = Locked(Date())
        let access = gate(vault, now: { clock.value })
        let acting = try #require(access.acting)
        _ = try acting.set(on: true)
        let paired = try pair(access)
        let secret = try #require(paired.act)
        #expect(acting.acts(token: paired.token, secret: secret))
        clock.value = clock.value.addingTimeInterval(ActingPages.life + 1)
        #expect(!acting.acts(token: paired.token, secret: secret))
        #expect(try #require(access.admit(["token": .string(paired.token), "act": .string(secret)])).rights == [.read, .draft])
    }

    /// Off, and the user's revoke, end every page's acting at the next request (the cache, at once); off tells the
    /// screen at once (`onOff`), before the vault answers.
    @Test func offAndRevokeEndActingAtOnce() throws {
        let vault = MemoryVaultV2()
        let access = gate(vault)
        let acting = try #require(access.acting)
        let offs = Locked<[Bool]>([])
        acting.onOff = { offs.value.append(acting.state?.on == true) }
        _ = try acting.set(on: true)
        let paired = try pair(access)
        let secret = try #require(paired.act)
        _ = try acting.set(on: false)
        #expect(offs.value == [false], "told once, the cache off already")
        #expect(!acting.acts(token: paired.token, secret: secret))
        #expect(try #require(access.admit(["token": .string(paired.token), "act": .string(secret)])).rights == [.read, .draft])
        _ = try acting.set(on: true)
        let again = try pair(access)
        #expect(acting.acts(token: again.token, secret: try #require(again.act)))
        _ = access.revoke()
        #expect(!acting.acts(token: again.token, secret: again.act), "at once, before the vault's write")
        acting.settled()
        #expect(try vault.client.pageActs().tokens.isEmpty)
        #expect(acting.value(pages: 0)["on"]?.bool == true, "a revoke leaves acting on: a new pairing acts")
    }

    /// A page's auth never waits on the host: with the vault stalled, a token's auth and a pairing's answer at once (from
    /// the cache; the pairing's write waits its turn off the queue).
    @Test func aStalledHostHoldsNoAuth() throws {
        let vault = MemoryVaultV2()
        let access = gate(vault)
        let acting = try #require(access.acting)
        _ = try acting.set(on: true)
        let first = try pair(access)
        let stalled = DispatchSemaphore(value: 0)
        defer { stalled.signal() }
        let blocking = ActingPages(vault: LeadVaultV2Client { request in
            if case .pageActs = request { return .pageActs(try vault.client.pageActs()) }
            stalled.wait()
            return .refused("stalled")
        })
        blocking.refreshLater()
        blocking.settled()
        access.acting = blocking
        let started = Date()
        let token = access.admit(["token": .string(first.token), "act": .string(try #require(first.act))])
        let paired = access.admit(["pair": .string(access.openCode(now: Date()))])
        #expect(Date().timeIntervalSince(started) < 2, "an auth waited on the host")
        #expect(token?.rights.contains(.act) == true && paired?.rights.contains(.act) == true)
    }

    // MARK: The route

    /// An acting page sends every user's kind its entry lets it, and none it doesn't; a page without the right sends
    /// none; the right changes nothing for any other kind; each kind's `page` says what it is: a user's kind acts or is
    /// the terminal's, any other's is its sender's.
    @Test func anActingPageRoutesTheUsersKindsItsEntryLets() {
        let terminalOnly: Set<String> = ["start", "web.open", "build.switch", "hooks.install", "plugin.add", "plugin.inspect"]
        for spec in KindSpec.all {
            switch (spec.sender, spec.page) {
            case (.user, .acts): #expect(!terminalOnly.contains(spec.name), "\(spec.name)")
            case (.user, .terminalOnly): #expect(terminalOnly.contains(spec.name), "\(spec.name)")
            case (.user, .bySender): Issue.record("\(spec.name): a user's kind says whether a page acts it")
            case (_, .bySender): break
            default: Issue.record("\(spec.name): only a user's kind says whether a page acts it")
            }
            for terminals in [false, true] {
                let acting = Principal.page([.read, .draft, .act], terminals: terminals).route(spec.name)
                let plain = Principal.page([.read, .draft], terminals: terminals).route(spec.name)
                if spec.sender == .user {
                    #expect((acting == .pageVoice) == (spec.page == .acts), "\(spec.name): \(acting)")
                    if case .refused(.voice, _) = plain {} else { Issue.record("\(spec.name) from a page that doesn't act: \(plain)") }
                } else {
                    #expect(acting == plain, "\(spec.name): the act right changed its route")
                }
            }
        }
        let kinds = Principal.page([.read, .draft, .act], terminals: false).kinds
        #expect(Set(kinds).isSuperset(of: ["answer", "approve", "approve.list", "send", "stop", "set", "web.revoke"]))
        #expect(Set(kinds).isDisjoint(with: terminalOnly))
    }

    // MARK: The screen

    /// The loopback page's screen hands an acting page's user's request on with its token; a screen with no hand-off (the
    /// tailnet's) refuses it whatever the rights; `closeActing` closes the acting connections alone.
    @Test func theScreenHandsOnAnActingPagesRequestsAndEndsThem() throws {
        final class Inner: WebSocketHandler, @unchecked Sendable {
            func opened(_ transport: LiveTransport, rights: LiveRights) {}
            func text(_ message: Data, on transport: LiveTransport) {}
            func binary(_ message: Data, on transport: LiveTransport) {}
            func closed(_ transport: LiveTransport) {}
        }
        let vault = MemoryVaultV2()
        let access = gate(vault)
        let acting = try #require(access.acting)
        _ = try acting.set(on: true)
        let paired = try pair(access)
        let admissions = Locked<[ObjectIdentifier: WebAdmission]>([:])
        let screen = WebRequestScreen(Inner(), admissionOf: { admissions.value[ObjectIdentifier($0)] })
        let actingPage = Recorder(), reading = Recorder()
        admissions.value[ObjectIdentifier(actingPage)] = paired
        admissions.value[ObjectIdentifier(reading)] = WebAdmission(rights: [.read, .draft], auth: .null, token: paired.token)
        screen.opened(actingPage, rights: paired.rights)
        screen.opened(reading, rights: [.read, .draft])
        let request = Data(NodeWire.line(NodeWire.Request(id: "1", kind: "stop", args: [:], action: UUID().uuidString)).dropLast())
        // No hand-off or no acting (the tailnet's screen): refused whatever the rights say.
        screen.text(request, on: actingPage)
        #expect(actingPage.messages.last?["error"]?["message"]?.string == WebRequestScreen.notActing, "\(actingPage.messages)")
        let handed = Locked<[String]>([])
        screen.onPageVoice = { request, credentials, _ in handed.value.append("\(request.kind) \(credentials.act == paired.act)") }
        screen.text(request, on: actingPage)
        #expect(handed.value.isEmpty, "a screen with no acting hands nothing on")
        screen.acting = acting
        screen.text(request, on: actingPage)
        screen.text(request, on: reading)
        #expect(handed.value == ["stop true"])
        #expect(reading.messages.last?["error"]?["code"]?.string == "voice")
        #expect(screen.actingCount == 1)
        // Judged at each request: a revoke counts at the next one, the connection still open.
        _ = access.revoke()
        screen.text(request, on: actingPage)
        #expect(handed.value == ["stop true"] && actingPage.messages.last?["error"]?["message"]?.string == WebRequestScreen.notActing)
        // Off marks the acting connections not acting at once, and closes them on the queue it is given.
        let closing = DispatchQueue(label: "closes")
        closing.suspend()
        screen.endActing(code: "acts-off", reason: "off", closeOn: closing)
        #expect(screen.actingCount == 0, "marked before any close")
        closing.resume()
        closing.sync {}
        #expect(actingPage.closes == ["acts-off"] && reading.closes.isEmpty)
    }
}
