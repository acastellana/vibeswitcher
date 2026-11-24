import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The host's vault in the test's memory, as the app asks it (`LeadVaultV2.answer`, the app's caller).
final class MemoryVaultV2: @unchecked Sendable {
    private let lock = NSLock()
    private var book: LeadVaultV2.Book?
    var now: () -> Double = { Date().timeIntervalSince1970 }

    var client: LeadVaultV2Client { LeadVaultV2Client { [self] request in answer(request) } }

    /// One request, answered as the host answers the app.
    func answer(_ request: LeadVaultV2.Request) -> LeadVaultV2.Reply {
        lock.withLock { LeadVaultV2.answer(request, from: .app, book: &book, now: now(), on: true) }
    }

    /// The host restarted: its vault's record starts over.
    func restart() { lock.withLock { book = nil } }
}

/// A loopback page's gate as `NodeLive` wires it: its tokens the vault's (`tokenAuthority`), its pairings confirmed in
/// the terminal (`acting`), the cache loaded (as at a welcome).
func pageGate(_ vault: MemoryVaultV2, root: URL, now: @escaping @Sendable () -> Date = { Date() }) -> WebAccess {
    let access = WebAccess(tokens: WebTokens(root: root), now: now)
    let acting = ActingPages(vault: vault.client, now: now)
    access.acting = acting
    access.tokenAuthority = (acting, "loopback")
    acting.refreshLater()
    acting.settled()
    return access
}

/// A page taking a code of `access`'s, its token kept in the vault: the admission, and its pairing's code id.
func pagePairs(_ access: WebAccess) throws -> (admission: WebAdmission, code: String) {
    let admitted = try #require(access.admit(["pair": .string(access.openCode(now: Date()))]))
    access.acting?.settled()
    return (admitted, try #require(admitted.pairing))
}

/// That pairing confirmed in the terminal (`web.confirm`'s part on the gate): its secret.
func pageConfirmed(_ access: WebAccess, _ code: String) throws -> String {
    let pairing = try #require(access.takePairing(code: code))
    let secret = try #require(access.acting).confirmed(token: pairing.token, tokenEnds: pairing.tokenEnds)
    access.acting?.settled()
    return secret
}

/// Acting from the page (the web UI design's step 2) and its security reviews, the parts that need no node: the vault's
/// record (the level, confirmed pairings, every page token), which pages are admitted, watch and act, the route, and
/// the screen.
struct ActingPageTests {
    private let scratch = Scratch()

    // MARK: The vault

    /// Off on a new record; a level kept with its first `since`; pairings kept whatever the level, until their end; off
    /// drops every pairing; page tokens by scope, dropped by scope.
    @Test func theVaultKeepsTheLevelPairingsAndPageTokens() throws {
        let vault = MemoryVaultV2()
        let client = vault.client
        let sha = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
        let until = (Date().timeIntervalSince1970 + 3_600).rounded()
        #expect(try client.pageActs() == .init())
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.setPageActs(level: "on") }
        let trust = try client.setPageActs(level: "trust")
        #expect(trust.level == "trust" && trust.on)
        #expect(try client.setPageActs(level: "trust").since == trust.since, "the same level again keeps its since")
        #expect(try client.addActingToken(sha256: sha, until: until).tokens == [sha: until])
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.addActingToken(sha256: "not-hex", until: until) }
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.addActingToken(sha256: sha, until: Date().timeIntervalSince1970 - 1) }
        let off = try client.setPageActs(level: "off")
        #expect(off.level == "off" && off.since == nil && off.tokens.isEmpty)
        // Pairings for watching are kept at off too.
        #expect(try client.addActingToken(sha256: other, until: until).tokens == [other: until])
        #expect(try client.addPageToken(scope: "loopback", sha256: sha, until: until).pages == ["loopback:\(sha)": until])
        #expect(try client.addPageToken(scope: "tailnet", sha256: other, until: until).pages.count == 2)
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.addPageToken(scope: "elsewhere", sha256: sha, until: until) }
        #expect(try client.dropPageTokens(scope: "loopback", nil).pages == ["tailnet:\(other)": until])
    }

    /// A pairing past its end is dropped at the next ask.
    @Test func aPairingEnds() throws {
        let vault = MemoryVaultV2()
        let start = Date().timeIntervalSince1970
        vault.now = { start }
        let client = vault.client
        _ = try client.addActingToken(sha256: String(repeating: "c", count: 64), until: start + 60)
        vault.now = { start + 61 }
        #expect(try client.pageActs().tokens.isEmpty)
    }

    /// A pairing's phrase: three of 256 words, none twice, the same for the same token.
    @Test func aPhraseIsThreeOfTwoHundredFiftySixWords() {
        #expect(PagePairing.words.count == 256 && Set(PagePairing.words).count == 256)
        #expect(PagePairing.phrase(token: "t") == PagePairing.phrase(token: "t") && PagePairing.phrase(token: "t") != PagePairing.phrase(token: "u"))
    }

    /// A request made from a page is recorded as the user's with the page's mark; a terminal's has none.
    @Test func aPagesActionIsRecordedWithItsMark() throws {
        let client = MemoryVaultV2().client
        #expect(try client.recordPageAction("a1", kind: "answer", subject: "card", digest: "d", via: "page 0123456789ab from http://127.0.0.1:8765"))
        #expect(try client.recordUserAction("a2", kind: "answer", subject: "card", digest: "d"))
        #expect(try client.userActions().map(\.via) == ["page 0123456789ab from http://127.0.0.1:8765", nil])
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.recordPageAction("a3", kind: "answer", subject: nil, digest: "d", via: "") }
    }

    // MARK: Which pages are admitted, watch and act

    /// A page that takes a code reads and drafts, and is shown its phrase (the terminal's to confirm); only once confirmed
    /// is it given its secret, and then with its token it watches, and acts while the level is above off; on its token
    /// alone (a reload) it reads and drafts; after a server restart the same (the vault outlives the server).
    @Test func aPairingConfirmedInTheTerminalWatchesAndActs() throws {
        let vault = MemoryVaultV2()
        let root = scratch.url("web-root")
        let access = pageGate(vault, root: root)
        _ = try access.acting?.set(level: "trust")
        let (paired, code) = try pagePairs(access)
        #expect(paired.rights == [.read, .draft] && paired.act == nil && paired.auth["act"] == nil, "not before the terminal's confirmation")
        let phrase = try #require(paired.auth["phrase"]?.string)
        #expect(phrase == PagePairing.phrase(token: paired.token) && phrase.split(separator: " ").count == 3)
        #expect(access.pairing(code: code) == .taken(phrase: phrase, contested: false))
        let secret = try pageConfirmed(access, code)
        #expect(try #require(access.admit(["token": .string(paired.token), "act": .string(secret)])).rights == [.read, .draft, .watch, .act])
        #expect(try #require(access.admit(["token": .string(paired.token)])).rights == [.read, .draft], "a reload reads and drafts")
        #expect(try vault.client.pageActs().tokens.keys.contains(ActingPages.key(token: paired.token, secret: secret)))
        let restarted = pageGate(vault, root: root)
        #expect(try #require(restarted.admit(["token": .string(paired.token), "act": .string(secret)])).rights == [.read, .draft, .watch, .act])
        _ = try restarted.acting?.set(level: "off")
        let watching = try pagePairs(restarted)
        let watchSecret = try pageConfirmed(restarted, watching.code)
        #expect(try #require(restarted.admit(["token": .string(watching.admission.token), "act": .string(watchSecret)])).rights == [.read, .draft, .watch],
                "at off a confirmed pairing watches and doesn't act")
    }

    /// A token any process wrote into the token file, never issued by the node to a pairing, isn't admitted at all (the
    /// file is no authority); and a host restart (its vault starting over) needs every page paired again.
    @Test func onlyATokenTheVaultKnowsIsAdmitted() throws {
        let vault = MemoryVaultV2()
        let access = pageGate(vault, root: scratch.url("web-root"))
        let minted = try access.tokens.issue(now: Date()).token
        #expect(access.admit(["token": .string(minted)]) == nil, "a token in the file alone")
        let (paired, _) = try pagePairs(access)
        #expect(access.admit(["token": .string(paired.token)]) != nil)
        vault.restart()
        access.acting?.refreshLater()
        access.acting?.settled()
        #expect(access.admit(["token": .string(paired.token)]) == nil, "the host restarted: pair again")
        #expect(!access.holds(paired.token))
    }

    /// The token file's ends are capped at a token's life (the review's finding 5): a year written there is a day.
    @Test func theTokenFilesEndsAreCapped() throws {
        let root = scratch.url("web-root")
        let file = root.appendingPathComponent("v2/web-tokens.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let token = "a-token-whose-end-the-file-says-is-a-year-off"
        let now = Date()
        let entry = #"{"format":1,"tokens":[{"sha256":"\#(ActingPages.digest(token))","issuedAt":"\#(NodeWire.dateText(now))","expiresAt":"\#(NodeWire.dateText(now.addingTimeInterval(365 * 86_400)))"}]}"#
        try Data(entry.utf8).write(to: file)
        let tokens = WebTokens(root: root)
        let end = try #require(tokens.expiry(of: token, now: now))
        #expect(end.timeIntervalSince(now) <= WebTokens.life + 1)
    }

    /// A pairing lives 12 hours at most: then it watches and acts no more, at the next request as at the next auth.
    @Test func aPairingLivesTwelveHoursAtMost() throws {
        let vault = MemoryVaultV2()
        let clock = Locked(Date())
        let access = pageGate(vault, root: scratch.url("web-root"), now: { clock.value })
        let acting = try #require(access.acting)
        _ = try acting.set(level: "trust")
        let (paired, code) = try pagePairs(access)
        let secret = try pageConfirmed(access, code)
        #expect(acting.acts(token: paired.token, secret: secret))
        clock.value = clock.value.addingTimeInterval(ActingPages.life + 1)
        #expect(!acting.acts(token: paired.token, secret: secret) && !acting.watches(token: paired.token, secret: secret))
    }

    /// Off and the user's revoke end every pairing at the next request (the cache, at once); a lower level tells the
    /// screen at once (`onLowered`), before the vault answers; `confirm` can't be set before its check exists.
    @Test func offAndRevokeEndPairingsAtOnce() throws {
        let vault = MemoryVaultV2()
        let access = pageGate(vault, root: scratch.url("web-root"))
        let acting = try #require(access.acting)
        let lowered = Locked<[String]>([])
        acting.onLowered = { lowered.value.append("\($0) \(acting.level)") }
        _ = try acting.set(level: "trust")
        let (paired, code) = try pagePairs(access)
        let secret = try pageConfirmed(access, code)
        _ = try acting.set(level: "off")
        #expect(lowered.value == ["off off"], "told once, the cache lowered already")
        #expect(!acting.acts(token: paired.token, secret: secret) && !acting.watches(token: paired.token, secret: secret))
        _ = try acting.set(level: "trust")
        let again = try pagePairs(access)
        let againSecret = try pageConfirmed(access, again.code)
        #expect(acting.acts(token: again.admission.token, secret: againSecret))
        _ = access.revoke()
        #expect(!acting.watches(token: again.admission.token, secret: againSecret), "at once, before the vault's write")
        #expect(access.admit(["token": .string(again.admission.token)]) == nil, "a revoke drops every page token")
        acting.settled()
        #expect(try vault.client.pageActs().tokens.isEmpty && vault.client.pageActs().pages.isEmpty)
        #expect(!ActingPages.confirmBuilt)
    }

    /// A page's auth never waits on the host: with the vault stalled, a token's auth and a pairing's answer at once.
    @Test func aStalledHostHoldsNoAuth() throws {
        let vault = MemoryVaultV2()
        let root = scratch.url("web-root")
        let access = pageGate(vault, root: root)
        _ = try access.acting?.set(level: "trust")
        let (first, code) = try pagePairs(access)
        let secret = try pageConfirmed(access, code)
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
        access.tokenAuthority = (blocking, "loopback")
        let started = Date()
        let token = access.admit(["token": .string(first.token), "act": .string(secret)])
        let paired = access.admit(["pair": .string(access.openCode(now: Date()))])
        #expect(Date().timeIntervalSince(started) < 2, "an auth waited on the host")
        #expect(token?.rights.contains(.act) == true && paired != nil)
    }

    // MARK: The route

    /// An acting page sends every user's kind its entry lets it, and none it doesn't; a page without the right sends
    /// none; the right changes nothing for any other kind; a terminal needs the watch right, never reading alone.
    @Test func anActingPageRoutesTheUsersKindsItsEntryLets() {
        let terminalOnly: Set<String> = ["start", "web.open", "build.switch", "hooks.install", "plugin.add", "plugin.inspect", "web.pairing", "web.confirm"]
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
        #expect(Principal.page([.read, .draft], terminals: true).route("term.open") != .terminal, "reading alone never watches")
        #expect(Principal.page([.read, .draft, .watch], terminals: true).route("term.open") == .terminal)
        let kinds = Principal.page([.read, .draft, .act], terminals: false).kinds
        #expect(Set(kinds).isSuperset(of: ["answer", "approve", "approve.list", "send", "stop", "set", "web.revoke"]))
        #expect(Set(kinds).isDisjoint(with: terminalOnly))
    }

    // MARK: The screen

    final class Inner: WebSocketHandler, @unchecked Sendable {
        let rights = Locked<[LiveRights]>([])
        func opened(_ transport: LiveTransport, rights: LiveRights) { self.rights.value.append(rights) }
        func text(_ message: Data, on transport: LiveTransport) {}
        func binary(_ message: Data, on transport: LiveTransport) {}
        func closed(_ transport: LiveTransport) {}
    }

    /// The loopback page's screen: a pairing's connection is given its secret once and its rights raised when the
    /// terminal confirms it; an acting page's request goes on only while it acts, judged at each request; a terminal only
    /// while it watches; a lower level marks the acting connections at once and closes them on the queue given.
    @Test func theScreenConfirmsJudgesAndEnds() throws {
        let vault = MemoryVaultV2()
        let access = pageGate(vault, root: scratch.url("web-root"))
        let acting = try #require(access.acting)
        _ = try acting.set(level: "trust")
        let (paired, code) = try pagePairs(access)
        let admissions = Locked<[ObjectIdentifier: WebAdmission]>([:])
        let inner = Inner()
        let screen = WebRequestScreen(inner, terminals: true, admissionOf: { admissions.value[ObjectIdentifier($0)] })
        screen.acting = acting
        let page = Recorder(), reading = Recorder()
        admissions.value[ObjectIdentifier(page)] = paired
        admissions.value[ObjectIdentifier(reading)] = WebAdmission(rights: [.read, .draft], auth: .null, token: "another")
        screen.opened(page, rights: paired.rights)
        screen.opened(reading, rights: [.read, .draft])
        let handed = Locked<[String]>([])
        screen.onPageVoice = { request, credentials, _ in handed.value.append("\(request.kind) \(credentials.act != nil)") }
        let stop = Data(NodeWire.line(NodeWire.Request(id: "1", kind: "stop", args: [:], action: UUID().uuidString)).dropLast())
        screen.text(stop, on: page)
        #expect(handed.value.isEmpty && page.messages.last?["error"]?["code"]?.string == "voice", "not confirmed: \(page.messages)")
        // Confirmed in the terminal: the secret once, on this connection, and its rights raised (the hub told too).
        #expect(screen.holdsPairing(code))
        let pairing = try #require(access.takePairing(code: code))
        let secret = acting.confirmed(token: pairing.token, tokenEnds: pairing.tokenEnds)
        #expect(screen.confirmPairing(code, secret: secret, rights: [.read, .draft, .watch, .act]))
        let given = try #require(page.messages.last)
        #expect(given["kind"]?.string == "paired" && given["act"]?.string == secret && given["rights"]?.array?.count == 4, "\(given)")
        #expect(inner.rights.value.last == [.read, .draft, .watch, .act])
        #expect(!screen.confirmPairing(code, secret: secret, rights: [.read]), "once")
        screen.text(stop, on: page)
        screen.text(stop, on: reading)
        #expect(handed.value == ["stop true"])
        #expect(reading.messages.last?["error"]?["code"]?.string == "voice")
        // Judged at each request: a revoke counts at the next one, the connection still open.
        _ = access.revoke()
        screen.text(stop, on: page)
        #expect(handed.value == ["stop true"] && page.messages.last?["error"]?["code"]?.string == "acts-ended")
        let open = Data(NodeWire.line(NodeWire.Request(id: "2", kind: "term.open", args: ["session": .string("s"), "cols": .int(80), "rows": .int(24)])).dropLast())
        screen.text(open, on: page)
        #expect(page.messages.last?["error"]?["code"]?.string == "acts-ended", "no longer watches")
        // A lower level marks the acting connections not acting at once, and closes them on the queue given.
        let closing = DispatchQueue(label: "closes")
        closing.suspend()
        screen.endActing(code: "acts-off", reason: "off", closeOn: closing)
        #expect(screen.actingCount == 0, "marked before any close")
        closing.resume()
        closing.sync {}
        #expect(page.closes == ["acts-off"] && reading.closes.isEmpty)
    }

    /// A connection that only watches is ended too when its pairing stops watching (the review of 25a03f63's branch):
    /// marked at once (`watching`, which the terminal relay asks for each chunk, false before any close), its terminal
    /// streams dropped (`onWatchEnded`) and then it closed, on the queue given. By the level going to off, and by the
    /// sweep when its pairing ran out; the sweep leaves a pairing that still watches alone.
    @Test func aWatchingConnectionEndsWhenItsPairingStopsWatching() throws {
        let vault = MemoryVaultV2()
        let clock = Locked(Date())
        let access = pageGate(vault, root: scratch.url("web-root"), now: { clock.value })
        let acting = try #require(access.acting)
        let admissions = Locked<[ObjectIdentifier: WebAdmission]>([:])
        let screen = WebRequestScreen(Inner(), terminals: true, admissionOf: { admissions.value[ObjectIdentifier($0)] })
        screen.acting = acting
        let order = Locked<[String]>([])
        screen.onWatchEnded = { _ in order.mutate { $0.append("streams dropped") } }
        /// A page paired and confirmed at the level off: it watches, and doesn't act.
        func watcher() throws -> Recorder {
            let (paired, code) = try pagePairs(access)
            let page = Recorder()
            admissions.value[ObjectIdentifier(page)] = paired
            screen.opened(page, rights: paired.rights)
            let pairing = try #require(access.takePairing(code: code))
            let secret = acting.confirmed(token: pairing.token, tokenEnds: pairing.tokenEnds)
            #expect(screen.confirmPairing(code, secret: secret, rights: [.read, .draft, .watch]))
            return page
        }
        let first = try watcher()
        #expect(screen.watching(first))
        // The sweep leaves a pairing that still watches alone.
        let queue = DispatchQueue(label: "closes")
        screen.sweepPairings(closeOn: queue)
        queue.sync {}
        #expect(screen.watching(first) && first.closes.isEmpty)
        // The level to off (every pairing dropped): ended though it never acted.
        queue.suspend()
        screen.endActing(code: "acts-off", reason: "off", closeOn: queue)
        #expect(!screen.watching(first), "marked before any close")
        first.onClose = { order.mutate { $0.append("closed") } }
        queue.resume()
        queue.sync {}
        #expect(first.closes == ["acts-off"] && order.value == ["streams dropped", "closed"], "\(order.value)")
        // The sweep, once a pairing ran out.
        let second = try watcher()
        #expect(screen.watching(second))
        clock.value = clock.value.addingTimeInterval(ActingPages.life + 1)
        screen.sweepPairings(closeOn: queue)
        #expect(!screen.watching(second))
        queue.sync {}
        #expect(second.closes == ["acts-off"])
    }

    /// The re-read's R1: a refresh queued just before the level is lowered never puts the higher level back: the lower
    /// level counts at once, and the refresh's answer (asked before) is turned away when it comes.
    @Test func aRefreshQueuedBeforeALowerLevelNeverRaisesItAgain() async throws {
        let vault = MemoryVaultV2()
        _ = try vault.client.setPageActs(level: "trust")
        let held = DispatchSemaphore(value: 0), asked = DispatchSemaphore(value: 0)
        let writing = DispatchSemaphore(value: 0), written = DispatchSemaphore(value: 0)
        let holding = Locked(false)
        let acting = ActingPages(vault: LeadVaultV2Client { request in
            if case .pageActs = request, holding.value {
                // The refresh's read of `trust`, answered only once the lowering began.
                let before = try vault.client.pageActs()
                asked.signal()
                held.wait()
                return .pageActs(before)
            }
            if case .setPageActs = request {
                // The lowering's own write, held until the test looked (the refresh's answer has been taken by then).
                writing.signal()
                written.wait()
            }
            return vault.answer(request)
        })
        acting.refreshLater()
        acting.settled()
        #expect(acting.level == "trust")
        holding.value = true
        acting.refreshLater()
        asked.wait()
        holding.value = false
        let lowering = DispatchQueue(label: "lowering")
        let done = DispatchSemaphore(value: 0)
        lowering.async {
            _ = try? acting.set(level: "off")
            done.signal()
        }
        #expect(await eventually(timeout: 30) { acting.level == "off" }, "off didn't count at once")
        held.signal()
        // The refresh answered `trust` and its answer was taken or turned away before the write began.
        await offPool { writing.wait() }
        #expect(acting.level == "off", "the refresh asked before put trust back while the write was under way")
        written.signal()
        await offPool { done.wait() }
        acting.settled()
        #expect(acting.level == "off", "the refresh asked before put trust back")
    }
}
