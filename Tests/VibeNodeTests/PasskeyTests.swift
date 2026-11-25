import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A software P-256 key standing in for the user's authenticator (Windows Hello, a security key), and the WebAuthn
/// objects a browser makes with it, written as a browser writes them.
struct SoftAuthenticator {
    let key = P256.Signing.PrivateKey()
    let id: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }
    var idText: String { WebAuthn.base64url(id) }
    var publicKey: String { WebAuthn.base64url([UInt8](key.publicKey.x963Representation)) }

    /// CBOR as an authenticator writes it (the few forms WebAuthn's objects use).
    enum Item { case int(Int), bytes([UInt8]), text(String), map([(Item, Item)]) }

    static func cbor(_ item: Item) -> [UInt8] {
        func head(_ major: UInt8, _ value: UInt64) -> [UInt8] {
            switch value {
            case 0..<24: return [major << 5 | UInt8(value)]
            case 24..<256: return [major << 5 | 24, UInt8(value)]
            case 256..<65_536: return [major << 5 | 25, UInt8(value >> 8), UInt8(value & 0xFF)]
            default: return [major << 5 | 26] + (0..<4).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
            }
        }
        switch item {
        case .int(let value): return value >= 0 ? head(0, UInt64(value)) : head(1, UInt64(-1 - value))
        case .bytes(let bytes): return head(2, UInt64(bytes.count)) + bytes
        case .text(let text): return head(3, UInt64(text.utf8.count)) + Array(text.utf8)
        case .map(let pairs): return head(5, UInt64(pairs.count)) + pairs.flatMap { cbor($0.0) + cbor($0.1) }
        }
    }

    var cose: [UInt8] {
        let x963 = [UInt8](key.publicKey.x963Representation)
        return Self.cbor(.map([(.int(1), .int(2)), (.int(3), .int(-7)), (.int(-1), .int(1)), (.int(-2), .bytes(Array(x963[1...32]))),
                               (.int(-3), .bytes(Array(x963[33...64])))]))
    }

    static func authData(rp: String = WebAuthn.rpID, flags: UInt8, count: UInt32, attested: [UInt8] = []) -> [UInt8] {
        Array(SHA256.hash(data: Data(rp.utf8))) + [flags] + [UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
            + attested
    }

    static func clientData(_ type: String, challenge: [UInt8], origin: String, crossOrigin: Bool = false) -> [UInt8] {
        Array(#"{"type":"\#(type)","challenge":"\#(WebAuthn.base64url(challenge))","origin":"\#(origin)","crossOrigin":\#(crossOrigin)}"#.utf8)
    }

    /// `navigator.credentials.create`'s answer: client data and an attestation object ("none").
    func registration(challenge: [UInt8], origin: String = "http://localhost:8765", flags: UInt8 = 0x45, rp: String = WebAuthn.rpID)
        -> (clientData: [UInt8], attestation: [UInt8]) {
        let attested = [UInt8](repeating: 0, count: 16) + [UInt8(id.count >> 8), UInt8(id.count & 0xFF)] + id + cose
        let data = Self.authData(rp: rp, flags: flags, count: 0, attested: attested)
        let attestation = Self.cbor(.map([(.text("fmt"), .text("none")), (.text("attStmt"), .map([])), (.text("authData"), .bytes(data))]))
        return (Self.clientData("webauthn.create", challenge: challenge, origin: origin), attestation)
    }

    /// `navigator.credentials.get`'s answer, as the request's `assertion`.
    func assertion(challenge: [UInt8], origin: String = "http://localhost:8765", flags: UInt8 = 0x05, count: UInt32 = 1, rp: String = WebAuthn.rpID,
                   crossOrigin: Bool = false) throws -> NodeWire.Value {
        let client = Self.clientData("webauthn.get", challenge: challenge, origin: origin, crossOrigin: crossOrigin)
        let data = Self.authData(rp: rp, flags: flags, count: count)
        let signature = try key.signature(for: Data(data) + Data(SHA256.hash(data: Data(client))))
        return .object(["id": .string(idText), "clientDataJSON": .string(WebAuthn.base64url(client)), "authenticatorData": .string(WebAuthn.base64url(data)),
                        "signature": .string(WebAuthn.base64url([UInt8](signature.derRepresentation)))])
    }
}

/// The level `confirm` (a passkey per acting request): the CBOR reader, the WebAuthn checks, and on a node each act's
/// assertion checked against a challenge issued for exactly that request, every wrong one refused before any record.
@Suite(.timeLimit(.minutes(5)))
struct PasskeyTests {
    private let scratch = Scratch()

    // MARK: CBOR

    @Test func theCBORReaderReadsWhatWebAuthnWrites() throws {
        let soft = SoftAuthenticator()
        let key = try CBOR.whole(soft.cose)
        #expect(key[int: 1]?.int == 2 && key[int: 3]?.int == -7 && key[int: -2]?.bytes?.count == 32)
        #expect(try WebAuthn.p256(cose: key) == [UInt8](soft.key.publicKey.x963Representation))
        #expect(try CBOR.whole([0xF5]) == .bool(true) && CBOR.whole([0xF6]) == .null && CBOR.whole([0x39, 0x01, 0x00]) == .negative(256))
        // Refused: a length past the end, bytes after the item, a float, a tag, an indefinite length, too deep a nest.
        for bad: [UInt8] in [[0x5A, 0xFF, 0xFF, 0xFF, 0xFF], [0x01, 0x02], [0xFB, 0, 0, 0, 0, 0, 0, 0, 0], [0xC1, 0x01], [0x5F],
                             [UInt8](repeating: 0x81, count: 40) + [0x01], [0xBB, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]] {
            #expect(throws: CBOR.Refused.self) { try CBOR.whole(bad) }
        }
    }

    /// Fuzzed: random bytes, and a real attestation cut and flipped anywhere, never crash the reader nor make it read
    /// past its end.
    @Test func theCBORReaderTakesAnyBytes() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let bytes = (0..<Int.random(in: 0...48, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if let (_, end) = try? CBOR.read(bytes) { #expect(end <= bytes.count) }
        }
        let soft = SoftAuthenticator()
        let valid = soft.registration(challenge: [1, 2, 3]).attestation
        for index in 0..<valid.count {
            _ = try? CBOR.whole(Array(valid[..<index]))
            var flipped = valid
            flipped[index] ^= UInt8.random(in: 1...255)
            _ = try? CBOR.whole(flipped)
            _ = try? WebAuthn.AuthenticatorData.parse(Array(flipped.dropFirst(index % 40)))
        }
    }

    // MARK: WebAuthn

    @Test func aRegistrationAndAnAssertionCheck() throws {
        let soft = SoftAuthenticator()
        let challenge: [UInt8] = Array(repeating: 7, count: 32)
        let (client, attestation) = soft.registration(challenge: challenge)
        let made = try WebAuthn.registration(clientDataJSON: client, attestationObject: attestation, challenge: challenge, origin: "http://localhost:8765")
        #expect(made.id == soft.id && made.publicKey == [UInt8](soft.key.publicKey.x963Representation))
        // Refused: another origin, relying party, challenge; no user verification.
        let other = soft.registration(challenge: challenge, origin: "http://127.0.0.1:8765")
        #expect(throws: WebAuthn.Refused.self) { try WebAuthn.registration(clientDataJSON: other.clientData, attestationObject: other.attestation, challenge: challenge, origin: "http://localhost:8765") }
        let rp = soft.registration(challenge: challenge, rp: "example.com")
        #expect(throws: WebAuthn.Refused.self) { try WebAuthn.registration(clientDataJSON: rp.clientData, attestationObject: rp.attestation, challenge: challenge, origin: "http://localhost:8765") }
        let noUV = soft.registration(challenge: challenge, flags: 0x41)
        #expect(throws: WebAuthn.Refused.self) { try WebAuthn.registration(clientDataJSON: noUV.clientData, attestationObject: noUV.attestation, challenge: challenge, origin: "http://localhost:8765") }
        #expect(throws: WebAuthn.Refused.self) { try WebAuthn.registration(clientDataJSON: client, attestationObject: attestation, challenge: [9], origin: "http://localhost:8765") }
    }

    // MARK: On a node

    /// A world at the level `confirm`: a key registered (in the vault in memory), a page paired at localhost, its
    /// credentials; and a question card to answer.
    private func confirmWorld() async throws -> (CardWorld, SoftAuthenticator, PageCredentials, ActingPages, CardStore.Card, CardStore.Card) {
        let world = try await CardWorld.make(scratch)
        let soft = SoftAuthenticator()
        let acting = ActingPages(vault: MemoryVaultV2().client)
        _ = try acting.addPasskey(id: soft.idText, publicKey: soft.publicKey)
        _ = try acting.set(level: "confirm")
        let token = "a-page-token-at-localhost"
        let secret = acting.confirmed(token: token, tokenEnds: Date().addingTimeInterval(3_600))
        acting.settled()
        world.queue.sync { world.requests.actingPages = acting }
        let lead = try await world.sleepingLead()
        // A question whose line, with its quotes, runs past the vault's 200 bytes for a page's mark (the browser check
        // found the mark cut by characters, not bytes, and the act not recorded).
        let first = try await world.asked("Ship it? " + String(repeating: "“Launch the onboarding page” ", count: 6), options: ["Yes", "No"], lead: lead)
        let second = try await world.asked("Rename it?", options: ["Yes", "No"], lead: lead)
        return (world, soft, PageCredentials(token: token, act: secret, origin: "localhost:8765"), acting,
                try #require(world.card(first.card.id)), try #require(world.card(second.card.id)))
    }

    private func challenge(_ world: CardWorld, _ credentials: PageCredentials, kind: String, args: [String: NodeWire.Value], action: String) throws -> (bytes: [UInt8], line: String) {
        let got = Locked<NodeWire.Reply?>(nil)
        world.queue.sync {
            world.requests.pagePaired(NodeWire.Request(id: "c", kind: "act.challenge", args: ["kind": .string(kind), "args": .object(args), "action": .string(action)]),
                                      credentials: credentials) { got.value = $0 }
        }
        let reply = try #require(got.value)
        let text = try #require(reply.result?["challenge"]?.string, "\(reply)")
        return (try #require(WebAuthn.bytes(base64url: text)), reply.result?["line"]?.string ?? "")
    }

    private func act(_ world: CardWorld, _ credentials: PageCredentials, kind: String, args: [String: NodeWire.Value], action: String,
                     assertion: NodeWire.Value?) async -> NodeWire.Reply? {
        let got = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: UUID().uuidString, kind: kind, args: args, action: action, assertion: assertion)
        world.queue.async { world.requests.pageVoiced(request, credentials: credentials, origin: "http://localhost:8765") { got.value = $0 } }
        _ = await eventually(timeout: 120) { got.value != nil }
        return got.value
    }

    /// An answer approved by the passkey: recorded as the page's with what it approved, that line given back; and each
    /// wrong assertion refused before anything is recorded: another origin, relying party, no user verification, a
    /// cross-origin one, a challenge for another card, another `seen`, another action, one run out, one used already, a
    /// sign count that didn't move, a key not registered.
    @Test(NodeTraits.linuxOnly) func eachActNeedsItsOwnTouch() async throws {
        let (world, soft, credentials, acting, card, other) = try await confirmWorld()
        defer { world.stop() }
        let args: [String: NodeWire.Value] = ["card": .string(card.id), "seen": .string(card.seen), "text": .string("Yes")]
        // Refused, each before any record.
        func refused(_ why: String, code: String = "passkey", _ make: (_ action: String) throws -> (args: [String: NodeWire.Value], assertion: NodeWire.Value?)) async throws {
            let action = UUID().uuidString.lowercased()
            let (sent, assertion) = try make(action)
            let reply = try #require(await act(world, credentials, kind: "answer", args: sent, action: action, assertion: assertion))
            #expect(!reply.ok && reply.error?.code == code, "\(why): \(reply)")
            #expect(await world.actions().allSatisfy { $0.action != action }, "\(why): recorded")
        }
        try await refused("no assertion", code: "assertion-needed") { _ in (args, nil) }
        try await refused("another origin") { action in (args, try soft.assertion(challenge: try challenge(world, credentials, kind: "answer", args: args, action: action).bytes, origin: "http://127.0.0.1:8765")) }
        try await refused("another relying party") { action in (args, try soft.assertion(challenge: try challenge(world, credentials, kind: "answer", args: args, action: action).bytes, rp: "example.com")) }
        try await refused("no user verification") { action in (args, try soft.assertion(challenge: try challenge(world, credentials, kind: "answer", args: args, action: action).bytes, flags: 0x01)) }
        try await refused("cross-origin") { action in (args, try soft.assertion(challenge: try challenge(world, credentials, kind: "answer", args: args, action: action).bytes, crossOrigin: true)) }
        try await refused("another card") { action in
            let otherArgs: [String: NodeWire.Value] = ["card": .string(other.id), "seen": .string(other.seen), "text": .string("Yes")]
            return (args, try soft.assertion(challenge: try challenge(world, credentials, kind: "answer", args: otherArgs, action: action).bytes))
        }
        try await refused("another seen") { action in
            var drawn = args
            drawn["seen"] = .string(String(repeating: "0", count: 64))
            return (args, try soft.assertion(challenge: try challenge(world, credentials, kind: "answer", args: drawn, action: action).bytes))
        }
        try await refused("another action") { action in (args, try soft.assertion(challenge: try challenge(world, credentials, kind: "answer", args: args, action: UUID().uuidString.lowercased()).bytes)) }
        try await refused("run out", code: "assertion-needed") { action in
            let issued = try challenge(world, credentials, kind: "answer", args: args, action: action).bytes
            world.queue.sync { world.requests.passkeyChallenges[WebAuthn.base64url(issued)]?.until = Platform.Clock.steadyDate().addingTimeInterval(-1) }
            return (args, try soft.assertion(challenge: issued))
        }
        try await refused("a key not registered") { action in (args, try SoftAuthenticator().assertion(challenge: try challenge(world, credentials, kind: "answer", args: args, action: action).bytes)) }

        // The touch for exactly this answer: done, recorded with its line, the line given back.
        let action = UUID().uuidString.lowercased()
        let (issued, line) = try challenge(world, credentials, kind: "answer", args: args, action: action)
        #expect(line.contains("Ship it?") && line.contains("Yes"), "\(line)")
        let assertion = try soft.assertion(challenge: issued, count: 5)
        let reply = try #require(await act(world, credentials, kind: "answer", args: args, action: action, assertion: assertion))
        #expect(reply.ok && reply.recorded == line, "\(reply)")
        let recorded = await world.actions().first { $0.action == action && $0.kind == "answer" }
        #expect(recorded?.via?.contains("passkey approved: ") == true, "\(String(describing: recorded))")
        // A repeat after a lost reply (the same action and assertion, sent again after a reconnect): the earlier reply,
        // not a refusal for a used challenge; done once.
        let again = try #require(await act(world, credentials, kind: "answer", args: args, action: action, assertion: assertion))
        #expect(again.ok, "\(again)")
        #expect(await world.actions().filter { $0.action == action && $0.kind == "answer" }.count == 1)
        // A known action id with anything else isn't a repeat: another kind, other arguments, another page's token each
        // need the assertion, and nothing more is done.
        let otherPage = PageCredentials(token: "another-page", act: acting.confirmed(token: "another-page", tokenEnds: Date().addingTimeInterval(3_600)),
                                        origin: "localhost:8765")
        acting.settled()
        var changedArgs = args
        changedArgs["text"] = .string("No")
        for (kind, sent, page, why) in [("hold", args, credentials, "another kind"), ("answer", changedArgs, credentials, "other arguments"),
                                        ("answer", args, otherPage, "another page's token")] {
            let reused = try #require(await act(world, page, kind: kind, args: sent, action: action, assertion: nil))
            #expect(reused.error?.code == "assertion-needed", "\(why): \(reused)")
        }
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["answer", "message"], "nothing more done")
        // Used already: a challenge is taken by its first use (here refused, by a key not registered), and a second use
        // with the right key is refused.
        let reuseAction = UUID().uuidString.lowercased()
        let otherArgs: [String: NodeWire.Value] = ["card": .string(other.id), "seen": .string(other.seen), "text": .string("No")]
        let reused = try challenge(world, credentials, kind: "answer", args: otherArgs, action: reuseAction).bytes
        _ = await act(world, credentials, kind: "answer", args: otherArgs, action: reuseAction, assertion: try SoftAuthenticator().assertion(challenge: reused))
        try await refused("used already") { _ in (otherArgs, try soft.assertion(challenge: reused, count: 9)) }
        // A count that didn't move past 5.
        try await refused("a count that didn't move") { action in
            (otherArgs, try soft.assertion(challenge: try challenge(world, credentials, kind: "answer", args: otherArgs, action: action).bytes, count: 4))
        }
    }

    /// `set web_acts confirm` needs a passkey; the page at 127.0.0.1 doesn't act at `confirm` (it can't do passkeys) and
    /// is asked no challenge.
    @Test(NodeTraits.linuxOnly) func confirmNeedsAKeyAndLocalhost() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let acting = ActingPages(vault: MemoryVaultV2().client)
        world.queue.sync { world.requests.actingPages = acting }
        let refused = try #require(await world.ask("set", ["key": .string("web_acts"), "value": .string("confirm")]))
        #expect(refused.error?.message.contains("needs a passkey first") == true, "\(refused)")
        let soft = SoftAuthenticator()
        _ = try acting.addPasskey(id: soft.idText, publicKey: soft.publicKey)
        let set = try #require(await world.ask("set", ["key": .string("web_acts"), "value": .string("confirm")]))
        #expect(set.ok, "\(set)")
        let secret = acting.confirmed(token: "t", tokenEnds: Date().addingTimeInterval(3_600))
        #expect(acting.acts(token: "t", secret: secret, origin: "localhost:8765"))
        #expect(!acting.acts(token: "t", secret: secret, origin: "127.0.0.1:8765"), "127.0.0.1 can't do passkeys")
        #expect(acting.watches(token: "t", secret: secret))
    }

    /// A passkey's registration is bound to the one page the terminal names by its words, and to the one connection
    /// (tab) whose button was clicked: none showing the words is refused; one at a time; another page's ask or answer,
    /// another tab's, or a second answer makes it contested (nothing kept, the terminal told); the offer stays open after
    /// the answer; and it is kept only when the id the user types is the first characters of the one received.
    ///
    /// The review's K1 (the hijack): a client holding the page's token and acting secret (any connection, any Origin it
    /// writes) asks and answers first with its own software key. Once the user's own tab asks, it is contested; if the
    /// user's tab never asks, the user's page shows no id, and nothing the user types keeps the key.
    @Test(NodeTraits.linuxOnly) func aRegistrationIsTheNamedPagesClickedTabAlone() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let acting = ActingPages(vault: MemoryVaultV2().client)
        let (tokenA, tokenB) = ("the-named-pages-token", "another-pages-token")
        let secretA = acting.confirmed(token: tokenA, tokenEnds: Date().addingTimeInterval(3_600))
        let secretB = acting.confirmed(token: tokenB, tokenEnds: Date().addingTimeInterval(3_600))
        acting.settled()
        let phraseA = PagePairing.phrase(token: tokenA)
        let offered = Locked<[String]>([])
        let ended = Locked<Int>(0)
        world.queue.sync {
            world.requests.actingPages = acting
            world.requests.pairings = PairingSeat(holds: { _ in true }, confirm: { _, _, _ in true },
                                                  toPasskeyPages: { message in
                                                      if String(decoding: message, as: UTF8.self).contains("\"ended\"") { ended.mutate { $0 += 1 } }
                                                      return 1
                                                  },
                                                  toPasskeyPage: { phrase, message in
                                                      offered.mutate { $0.append(phrase) }
                                                      #expect(!String(decoding: message, as: UTF8.self).contains("challenge"), "the tabs are told one waits, no more")
                                                      return phrase == phraseA ? ActingPages.digest(tokenA) : nil
                                                  })
        }
        // The user's tab, a second tab of theirs, the hijacker's raw client on the same token and secret, another page.
        let tab = PageCredentials(token: tokenA, act: secretA, origin: "localhost:8765", connection: 1)
        let sibling = PageCredentials(token: tokenA, act: secretA, origin: "localhost:8765", connection: 2)
        let raw = PageCredentials(token: tokenA, act: secretA, origin: "localhost:8765", connection: 3)
        let pageB = PageCredentials(token: tokenB, act: secretB, origin: "localhost:8765", connection: 4)
        func paired(_ page: PageCredentials, _ kind: String, _ args: [String: NodeWire.Value]) throws -> NodeWire.Reply {
            let got = Locked<NodeWire.Reply?>(nil)
            world.queue.sync {
                world.requests.pagePaired(NodeWire.Request(id: "r", kind: kind, args: args, action: UUID().uuidString), credentials: page) { got.value = $0 }
            }
            return try #require(got.value)
        }
        func ask(_ page: PageCredentials, _ register: String) throws -> NodeWire.Reply { try paired(page, "passkey.ask", ["register": .string(register)]) }
        /// `page` answers with `soft`'s key, to the challenge its own ask gave (or, when it asked nothing, the offer's).
        func registered(_ page: PageCredentials, _ register: String, _ soft: SoftAuthenticator, asked: NodeWire.Reply? = nil) throws -> NodeWire.Reply {
            let text = try asked?.result?["challenge"]?.string ?? #require(world.queue.sync { world.requests.passkeyRegistrations[register]?.offer["challenge"]?.string })
            let made = soft.registration(challenge: try #require(WebAuthn.bytes(base64url: text)))
            return try paired(page, "passkey.registered", [
                "register": .string(register), "id": .string(soft.idText), "clientDataJSON": .string(WebAuthn.base64url(made.clientData)),
                "attestationObject": .string(WebAuthn.base64url(made.attestation)),
            ])
        }
        func begin(_ phrase: String) async throws -> NodeWire.Reply { try #require(await world.ask("web.passkey", ["phrase": .string(phrase)], action: nil)) }
        func state(_ register: String) async throws -> NodeWire.Reply {
            try #require(await world.ask("web.passkey", ["register": .string(register)], action: nil))
        }
        func add(_ register: String, typed: String) async throws -> NodeWire.Reply {
            try #require(await world.ask("web.passkey.add", ["register": .string(register), "typed": .string(typed)]))
        }
        func clear() { world.queue.sync { world.requests.passkeyRegistrations = [:] } }
        let typedLength = Requests.typedIDLength

        // No page shows those words.
        #expect(try await begin("acorn acorn acorn").error?.code == "gone")
        // Another page asks for the offer made to the named one: refused, contested, not kept.
        let first = try #require(try await begin(phraseA.uppercased()).result?["register"]?.string)
        #expect(try await begin(phraseA).error?.message.contains("waits already") == true, "one at a time")
        #expect(try await state(first).result?["state"]?.string == "waiting")
        #expect(try ask(pageB, first).error?.code == "voice")
        #expect(try await state(first).result?["state"]?.string == "contested")
        #expect(try await add(first, typed: "abcdef").error?.message.contains("another page or tab asked") == true)
        #expect(acting.state?.keys.isEmpty == true)
        clear()

        // K1, the hijacker first: its raw client asks and answers with its own key; the user's tab then asks: contested.
        let hijacked = try #require(try await begin(phraseA).result?["register"]?.string)
        let rogue = SoftAuthenticator()
        let rogueAsked = try ask(raw, hijacked)
        #expect(rogueAsked.ok && rogueAsked.result?["challenge"]?.string != nil)
        #expect(try registered(raw, hijacked, rogue, asked: rogueAsked).ok)
        let received = try await state(hijacked)
        #expect(received.result?["state"]?.string == "received" && received.result?["id"] == nil, "the terminal never shows an id: \(received)")
        #expect(try ask(tab, hijacked).error?.code == "voice", "the user's click after the hijacker's answer")
        #expect(try await state(hijacked).result?["state"]?.string == "contested")
        let refused = try await add(hijacked, typed: String(rogue.idText.prefix(typedLength)))
        #expect(refused.error?.message.contains("If that wasn't you, run `vibeswitcher web --revoke`") == true, "\(refused)")
        #expect(acting.state?.keys.isEmpty == true)
        clear()

        // K1, the user never clicks: their page shows no id; whatever they type (not the hijacker's id) keeps nothing.
        let unclicked = try #require(try await begin(phraseA).result?["register"]?.string)
        let silent = SoftAuthenticator()
        let silentAsked = try ask(raw, unclicked)
        #expect(try registered(raw, unclicked, silent, asked: silentAsked).ok)
        let guessed = try await add(unclicked, typed: "abcdef")
        #expect(guessed.error?.message.contains("aren't the first \(typedLength) characters") == true, "\(guessed)")
        #expect(acting.state?.keys.isEmpty == true)
        #expect(try await state(unclicked).result?["state"]?.string == "gone", "a wrong id ends it")
        clear()

        // The user's tab first, and the hijacker answers after (to the same offer): the offer is still open, so contested.
        let after = try #require(try await begin(phraseA).result?["register"]?.string)
        let mine = SoftAuthenticator()
        let tabAsked = try ask(tab, after)
        #expect(try registered(tab, after, mine, asked: tabAsked).ok)
        #expect(try registered(raw, after, SoftAuthenticator(), asked: tabAsked).error?.code == "voice")
        #expect(try await state(after).result?["state"]?.string == "contested")
        #expect(try await add(after, typed: String(mine.idText.prefix(typedLength))).error?.message.contains("another page or tab answered") == true)
        #expect(acting.state?.keys.isEmpty == true)
        clear()

        // A second tab of the user's clicks too: one tab at a time, contested.
        let twoTabs = try #require(try await begin(phraseA).result?["register"]?.string)
        #expect(try ask(tab, twoTabs).ok && ask(tab, twoTabs).ok, "the same tab asking again")
        #expect(try ask(sibling, twoTabs).error?.code == "voice")
        #expect(try await state(twoTabs).result?["state"]?.string == "contested")
        // K1b: a contested registration holds no seat: the next one is taken at once (no clear here), and the
        // contested one is gone with it.
        let retried = try #require(try await begin(phraseA).result?["register"]?.string, "a retry right after a contested registration")
        #expect(try await state(twoTabs).result?["state"]?.string == "gone")
        #expect(try ask(raw, retried).ok)
        #expect(try await state(retried).result?["state"]?.string == "asked")
        #expect(try await begin(phraseA).error?.message.contains("waits already") == true, "a live one still holds the seat")
        #expect(try ask(tab, retried).error?.code == "voice", "contested again, by the user's own click")
        // A typed mismatch ends one too: the next is taken at once.
        let mismatched = try #require(try await begin(phraseA).result?["register"]?.string)
        let mismatchedAsked = try ask(tab, mismatched)
        let wrong = SoftAuthenticator()
        #expect(try registered(tab, mismatched, wrong, asked: mismatchedAsked).ok)
        #expect(try await add(mismatched, typed: wrong.idText.prefix(typedLength) == "abcdef" ? "abcdeg" : "abcdef").error != nil)
        #expect(try await begin(phraseA).result?["register"]?.string != nil, "a retry right after a mismatch")
        clear()

        // The clicked tab answers twice: contested.
        let twice = try #require(try await begin(phraseA).result?["register"]?.string)
        let twiceAsked = try ask(tab, twice)
        #expect(try registered(tab, twice, SoftAuthenticator(), asked: twiceAsked).ok)
        #expect(try registered(tab, twice, SoftAuthenticator(), asked: twiceAsked).error?.code == "voice")
        #expect(try await state(twice).result?["state"]?.string == "contested")
        clear()

        // The clicked tab answers once, the user types its id's first characters (any case) off their page: kept, and
        // the offer ended on the page's tabs.
        let soft = SoftAuthenticator()
        let once = try #require(try await begin(phraseA).result?["register"]?.string)
        let onceAsked = try ask(tab, once)
        let answer = try registered(tab, once, soft, asked: onceAsked)
        #expect(answer.ok && answer.result?["state"]?.string == "received" && answer.result?["id"] == nil, "\(answer)")
        let endedBefore = ended.value
        let added = try await add(once, typed: String(soft.idText.prefix(typedLength)).uppercased())
        #expect(added.ok, "\(added)")
        #expect(acting.state?.keys[soft.idText] != nil)
        #expect(ended.value == endedBefore + 1)
        #expect(offered.value.allSatisfy { $0 == phraseA || $0 == "acorn acorn acorn" })
    }

    /// The review's Low: a request that passed at `trust` while the level rose to `confirm` meanwhile is refused (it
    /// needs its passkey now), and nothing is recorded.
    @Test(NodeTraits.linuxOnly) func aRequestPassedAtTrustAsTheLevelRisesNeedsItsPasskey() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let acting = ActingPages(vault: MemoryVaultV2().client)
        _ = try acting.set(level: "trust")
        let page = PageCredentials(token: "page-one", act: acting.confirmed(token: "page-one", tokenEnds: Date().addingTimeInterval(3_600)), origin: "localhost:8765")
        acting.settled()
        /// The level raised to `confirm` while the request is confirmed at `trust`.
        struct RisingVoice: PageVoice {
            let acting: ActingPages
            func confirm(_ request: NodeWire.Request, page: PageAct, done: @escaping @Sendable (NodeWire.Failure?) -> Void) {
                _ = try? acting.set(level: "confirm")
                acting.settled()
                done(nil)
            }
        }
        world.queue.sync {
            world.requests.actingPages = acting
            world.requests.pageVoice = RisingVoice(acting: acting)
        }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: lead)
        let card = try #require(world.card(asked.card.id))
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await act(world, page, kind: "answer", args: ["card": .string(card.id), "seen": .string(card.seen), "text": .string("Yes")],
                                           action: action, assertion: nil))
        #expect(reply.error?.code == "assertion-needed", "\(reply)")
        #expect(await world.actions().filter { $0.action == action }.isEmpty)
    }

    /// At `trust` too, a known action id is only the same page's very same request: another page's, another kind, other
    /// arguments are refused before anything is done (and a terminal's action id from a page as well).
    @Test(NodeTraits.linuxOnly) func atTrustAKnownActionIsTheSamePagesSameRequestAlone() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let acting = ActingPages(vault: MemoryVaultV2().client)
        _ = try acting.set(level: "trust")
        let page = PageCredentials(token: "page-one", act: acting.confirmed(token: "page-one", tokenEnds: Date().addingTimeInterval(3_600)), origin: "127.0.0.1:8765")
        let other = PageCredentials(token: "page-two", act: acting.confirmed(token: "page-two", tokenEnds: Date().addingTimeInterval(3_600)), origin: "127.0.0.1:8765")
        acting.settled()
        world.queue.sync { world.requests.actingPages = acting }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Ship it?", options: ["Yes", "No"], lead: lead)
        let card = try #require(world.card(asked.card.id))
        let args: [String: NodeWire.Value] = ["card": .string(card.id), "seen": .string(card.seen), "text": .string("Yes")]
        let action = UUID().uuidString.lowercased()
        #expect(try #require(await act(world, page, kind: "answer", args: args, action: action, assertion: nil)).ok)
        #expect(try #require(await act(world, page, kind: "answer", args: args, action: action, assertion: nil)).ok, "the same page's repeat")
        var changed = args
        changed["text"] = .string("No")
        for (kind, sent, from) in [("answer", args, other), ("hold", args, page), ("answer", changed, page)] {
            let reply = try #require(await act(world, from, kind: kind, args: sent, action: action, assertion: nil))
            #expect(reply.error?.code == "voice" && reply.error?.message.contains("another request's") == true, "\(reply)")
        }
        // A terminal's action id, from a page.
        let terminalAction = UUID().uuidString.lowercased()
        _ = try #require(await world.ask("set", ["key": .string("ai_summaries"), "value": .string("off")], action: terminalAction))
        let borrowed = try #require(await act(world, page, kind: "set", args: ["key": .string("ai_summaries"), "value": .string("off")],
                                              action: terminalAction, assertion: nil))
        #expect(borrowed.error?.message.contains("another request's") == true, "\(borrowed)")
        #expect(await world.actions().filter { $0.action == action && $0.kind == "answer" }.count == 1)
    }
}
