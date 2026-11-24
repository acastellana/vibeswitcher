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
        let first = try await world.asked("Ship it?", options: ["Yes", "No"], lead: lead)
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
    @Test func eachActNeedsItsOwnTouch() async throws {
        let (world, soft, credentials, _, card, other) = try await confirmWorld()
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
    @Test func confirmNeedsAKeyAndLocalhost() async throws {
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
}
