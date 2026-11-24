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

    /// Off on a new record; on keeps its first `since`; a token acts only while on, until its end; off drops every
    /// acting token, so on again acts for none of them.
    @Test func theVaultKeepsActingAndItsTokens() throws {
        let vault = MemoryVaultV2()
        let client = vault.client
        let sha = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
        let until = Date().timeIntervalSince1970 + 3_600
        #expect(try client.pageActs() == .init(since: nil, tokens: []))
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.addActingToken(sha256: sha, until: until) }
        let on = try client.setPageActs(on: true)
        #expect(on.on)
        #expect(try client.setPageActs(on: true).since == on.since, "on again keeps its since")
        #expect(try client.addActingToken(sha256: sha, until: until).tokens == [sha])
        #expect(try client.addActingToken(sha256: other, until: until).tokens == [sha, other])
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.addActingToken(sha256: "not-hex", until: until) }
        #expect(throws: LeadVaultV2Client.Refused.self) { try client.addActingToken(sha256: sha, until: Date().timeIntervalSince1970 - 1) }
        #expect(try client.dropActingTokens([sha]).tokens == [other])
        let off = try client.setPageActs(on: false)
        #expect(off == .init(since: nil, tokens: []))
        _ = try client.setPageActs(on: true)
        #expect(try client.pageActs().tokens.isEmpty, "a token from before an off never acts again")
    }

    /// A token past its end is dropped at the next ask.
    @Test func anActingTokenEndsWithItsToken() throws {
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

    // MARK: Which tokens act

    private func gate(_ vault: MemoryVaultV2?, root: URL? = nil) -> WebAccess {
        let access = WebAccess(tokens: WebTokens(root: root ?? scratch.url("web-root-\(UUID().uuidString.prefix(6))")))
        access.acting = vault.map { ActingPages(vault: $0.client) }
        return access
    }

    /// Paired while on, a page acts, and acts again on its token alone after a restart (the vault outlives the server);
    /// paired while off, it never does; a gate with no `acting` (the tailnet's) never grants it.
    @Test func aPagePairedWhileOnActs() throws {
        let vault = MemoryVaultV2()
        let root = scratch.url("web-root")
        let access = gate(vault, root: root)
        let before = try #require(access.admit(["pair": .string(access.openCode(now: Date()))]))
        #expect(before.rights == [.read, .draft], "paired while off")
        _ = try vault.client.setPageActs(on: true)
        #expect(try #require(access.admit(["token": .string(before.token)])).rights == [.read, .draft], "a page paired before on doesn't act")
        let paired = try #require(access.admit(["pair": .string(access.openCode(now: Date()))]))
        #expect(paired.rights == [.read, .draft, .act])
        #expect(paired.auth["rights"]?.array?.compactMap(\.string) == ["read", "draft", "act"])
        let restarted = WebAccess(tokens: WebTokens(root: root))
        restarted.acting = ActingPages(vault: vault.client)
        #expect(try #require(restarted.admit(["token": .string(paired.token)])).rights == [.read, .draft, .act], "after a restart")
        // The tailnet's gate has no `acting`: the same token, there, reads and drafts.
        let noActing = WebAccess(tokens: WebTokens(root: root))
        #expect(try #require(noActing.admit(["token": .string(paired.token)])).rights == [.read, .draft], "a gate with no acting")
    }

    /// A token any process wrote into the token file (issued there, never paired) reads and drafts, and never acts.
    @Test func aTokenFromTheFileNeverActs() throws {
        let vault = MemoryVaultV2()
        let access = gate(vault)
        _ = try vault.client.setPageActs(on: true)
        let minted = try access.tokens.issue(now: Date()).token
        #expect(try #require(access.admit(["token": .string(minted)])).rights == [.read, .draft])
    }

    /// Off, and the user's revoke, end every page's acting, and say so to the screen (`onOff`) for off.
    @Test func offAndRevokeEndActing() throws {
        let vault = MemoryVaultV2()
        let access = gate(vault)
        let acting = try #require(access.acting)
        let offs = Locked(0)
        acting.onOff = { offs.value += 1 }
        _ = try acting.set(on: true)
        let paired = try #require(access.admit(["pair": .string(access.openCode(now: Date()))]))
        #expect(paired.rights.contains(.act))
        _ = try acting.set(on: false)
        #expect(offs.value == 1)
        #expect(try #require(access.admit(["token": .string(paired.token)])).rights == [.read, .draft])
        _ = try acting.set(on: true)
        let again = try #require(access.admit(["pair": .string(access.openCode(now: Date()))]))
        #expect(again.rights.contains(.act))
        _ = access.revoke()
        #expect(try vault.client.pageActs().tokens.isEmpty)
        #expect(acting.value(pages: 0)["on"]?.bool == true, "a revoke leaves acting on: a new pairing acts")
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
    @Test func theScreenHandsOnAnActingPagesRequestsAndClosesThem() throws {
        final class Inner: WebSocketHandler, @unchecked Sendable {
            func opened(_ transport: LiveTransport, rights: LiveRights) {}
            func text(_ message: Data, on transport: LiveTransport) {}
            func binary(_ message: Data, on transport: LiveTransport) {}
            func closed(_ transport: LiveTransport) {}
        }
        let screen = WebRequestScreen(Inner(), tokenOf: { _ in "the-token" })
        let acting = Recorder(), reading = Recorder()
        screen.opened(acting, rights: [.read, .draft, .act])
        screen.opened(reading, rights: [.read, .draft])
        let request = Data(NodeWire.line(NodeWire.Request(id: "1", kind: "stop", args: [:], action: UUID().uuidString)).dropLast())
        screen.text(request, on: acting)
        #expect(acting.messages.first?["error"]?["message"]?.string == "this page doesn't act", "\(acting.messages)")
        let handed = Locked<[String]>([])
        screen.onPageVoice = { request, token, _ in handed.value.append("\(request.kind) \(token)") }
        screen.text(request, on: acting)
        screen.text(request, on: reading)
        #expect(handed.value == ["stop the-token"])
        #expect(reading.messages.last?["error"]?["code"]?.string == "voice")
        #expect(screen.actingCount == 1)
        screen.closeActing(code: "acts-off", reason: "off")
        #expect(acting.closes == ["acts-off"] && reading.closes.isEmpty)
    }
}
