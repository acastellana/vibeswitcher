import Foundation
import Testing
@testable import VibeCore

/// `WebAuthnAssertion.check` on assertions built by hand: the cases a browser's virtual authenticator can't make. Each
/// differs from a valid assertion in one thing, and is signed again over its bytes, so it is refused for that thing.
struct WebAuthnAssertionTests {
    typealias Made = WebAuthnSupport.Made
    let valid = Made()

    @Test func aValidAssertionPasses() throws {
        let verified = try valid.check()
        #expect(verified == WebAuthnAssertion.Verified(signCount: 1, backupState: false))
        let tailnet = Made(listener: WebAuthnSupport.tailnet)
        #expect(tailnet.refusal == nil)
    }

    // MARK: clientDataJSON (WebAuthn L3 §5.8.1.2's limited verification)

    func withClientData(_ text: String) -> Made { valid.with { $0.clientDataJSON = Data(text.utf8) } }
    var challenge: String { Base64URL.encode(valid.challenge) }

    @Test func anotherMemberAfterTheCheckedOnesPasses() {
        // The point of the spec's rule: a member after the four is the browser's, and changes nothing checked.
        #expect(valid.with { $0.clientDataJSON = WebAuthnSupport.clientData(challenge: $0.challenge, origin: $0.listener.origin,
                                                                             tail: #","later":"anything","n":[1,{"x":2}]}"#) }.refusal == nil)
        // Chrome's own extra member, as it sends it about one time in six.
        #expect(valid.with { $0.clientDataJSON = WebAuthnSupport.clientData(challenge: $0.challenge, origin: $0.listener.origin,
            tail: #","other_keys_can_be_added_here":"do not compare clientDataJSON against a template. See https://goo.gl/yabPex"}"#) }
            .refusal == nil)
        // A later duplicate of a checked member is never read: the checked prefix stands.
        #expect(valid.with { $0.clientDataJSON = WebAuthnSupport.clientData(challenge: $0.challenge, origin: $0.listener.origin,
                                                                             tail: #","origin":"http://evil.example"}"#) }.refusal == nil)
    }

    @Test func anExtraMemberBeforeOrBetweenTheCheckedOnesIsRefused() {
        let o = valid.listener.origin
        #expect(withClientData(#"{"x":1,"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":false}"#).refusal == .clientDataNotExact)
        #expect(withClientData(#"{"type":"webauthn.get","x":1,"challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":false}"#).refusal == .clientDataNotExact)
        #expect(withClientData(#"{"type":"webauthn.get","challenge":"\#(challenge)","x":1,"origin":"\#(o)","crossOrigin":false}"#).refusal == .clientDataNotExact)
        #expect(withClientData(#"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","x":1,"crossOrigin":false}"#).refusal == .clientDataNotExact)
        #expect(withClientData(#"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","topOrigin":"\#(o)","crossOrigin":false}"#).refusal == .clientDataNotExact)
    }

    @Test func reorderedMembersAreRefused() {
        let o = valid.listener.origin
        #expect(withClientData(#"{"challenge":"\#(challenge)","type":"webauthn.get","origin":"\#(o)","crossOrigin":false}"#).refusal == .clientDataNotExact)
        #expect(withClientData(#"{"type":"webauthn.get","origin":"\#(o)","challenge":"\#(challenge)","crossOrigin":false}"#).refusal == .clientDataNotExact)
        #expect(withClientData(#"{"type":"webauthn.get","challenge":"\#(challenge)","crossOrigin":false,"origin":"\#(o)"}"#).refusal == .clientDataNotExact)
    }

    @Test func otherWhitespaceIsRefused() {
        let o = valid.listener.origin
        for text in [#"{ "type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":false}"#,
                     #"{"type": "webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":false}"#,
                     #"{"type":"webauthn.get", "challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":false}"#,
                     #"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin": false}"#,
                     #"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":false }"#,
                     "{\"type\":\"webauthn.get\",\n\"challenge\":\"\(challenge)\",\"origin\":\"\(o)\",\"crossOrigin\":false}",
                     #" {"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":false}"#] {
            #expect(withClientData(text).refusal == .clientDataNotExact, "\(text)")
        }
    }

    @Test func anEscapedOrLookAlikeOriginIsRefused() {
        for origin in [#"http:\/\/localhost:47830"#, "\\" + "u0068ttp://localhost:47830", "http://local" + "\\" + "u0068ost:47830", "http://localhost:47830/", "http://localhost.:47830",
                       "HTTP://localhost:47830", "http://LOCALHOST:47830", "http://locaIhost:47830", "http://lоcalhost:47830",
                       "http://localhost:47831", "http://localhost:047830", "http://localhost", "https://localhost:47830",
                       "http://127.0.0.1:47830", "http://localhost:47830\u{0}", "http://localhost:4783"] {
            let made = valid.with { $0.clientDataJSON = WebAuthnSupport.clientData(challenge: $0.challenge, origin: origin) }
            #expect(made.refusal == .clientDataOrigin, "\(origin)")
        }
    }

    @Test func aChallengeInAnotherBase64FormIsRefused() {
        // Bytes whose base64 differs from base64url and that pad: 0xFB 0xFF … (so `+`, `/` and `=` appear).
        let issued = Data([0xFB, 0xFF, 0xBF] + (3..<32).map { UInt8($0) })
        let base = valid.with { $0.challenge = issued; $0.clientDataJSON = WebAuthnSupport.clientData(challenge: issued, origin: $0.listener.origin) }
        #expect(base.refusal == nil)
        let o = valid.listener.origin
        let forms = [issued.base64EncodedString(),                                        // standard, padded
                     issued.base64EncodedString().replacingOccurrences(of: "=", with: ""), // standard, unpadded
                     Base64URL.encode(issued) + "=",                                      // base64url, padded
                     issued.map { String(format: "%02x", $0) }.joined(),                  // hex
                     Base64URL.encode(issued).uppercased(),
                     Base64URL.encode(Data(SHA256.hash(data: issued)))]                   // another challenge
        for form in forms {
            let made = base.with { $0.clientDataJSON = Data(#"{"type":"webauthn.get","challenge":"\#(form)","origin":"\#(o)","crossOrigin":false}"#.utf8) }
            #expect(made.refusal == .clientDataChallenge, "\(form)")
        }
    }

    @Test func theWrongTypeIsRefused() {
        for type in ["webauthn.create", "webauthn.Get", "webauthn.get ", "payment.get", ""] {
            #expect(valid.with { $0.clientDataJSON = WebAuthnSupport.clientData(type: type, challenge: $0.challenge, origin: $0.listener.origin) }
                .refusal == .clientDataType, "\(type)")
        }
    }

    @Test func crossOriginTrueOrMissingIsRefused() {
        let o = valid.listener.origin
        #expect(withClientData(#"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":true}"#).refusal == .clientDataCrossOrigin)
        #expect(withClientData(#"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":true,"topOrigin":"http://localhost:3000"}"#).refusal == .clientDataCrossOrigin)
        #expect(withClientData(#"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)"}"#).refusal == .clientDataNotExact)
        #expect(withClientData(#"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":0}"#).refusal == .clientDataNotExact)
        #expect(withClientData(#"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":"false"}"#).refusal == .clientDataNotExact)
    }

    @Test func aTailThatIsntOneObjectsEndIsRefused() {
        let o = valid.listener.origin
        let prefix = #"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(o)","crossOrigin":false"#
        for tail in ["", "}}", "} ", "}\n", ",", ",\"x\":1", ",}", ", \"x\":1}", ",1}", "]", " }", "x}"] {
            #expect(withClientData(prefix + tail).refusal == .clientDataNotExact, "\(tail.debugDescription)")
        }
        // Not UTF-8 after the prefix.
        let invalid = valid.with { $0.clientDataJSON = Data((prefix + #","x":""#).utf8) + Data([0xC3, 0x28]) + Data(#""}"#.utf8) }
        #expect(invalid.refusal == .clientDataNotExact)
        // Over the bound, though well formed.
        let long = valid.with { $0.clientDataJSON = Data((prefix + #","x":"\#(String(repeating: "a", count: 1024))"}"#).utf8) }
        #expect(long.refusal == .clientDataNotExact)
        #expect(withClientData("").refusal == .clientDataNotExact)
        #expect(withClientData("null").refusal == .clientDataNotExact)
    }

    /// CCDToString (WebAuthn L3 §5.8.1.1): `"` and `\` escaped by a backslash, U+0000 to U+001F as `\u` and four
    /// lower-case hex digits, everything else in UTF-8.
    @Test func theExpectedStringsAreSerializedAsTheSpecSays() {
        #expect(WebAuthnChecks.ccdString("http://localhost:47830") == Array(#""http://localhost:47830""#.utf8))
        #expect(WebAuthnChecks.ccdString("a\"b\\c") == Array(#""a\"b\\c""#.utf8))
        #expect(WebAuthnChecks.ccdString("\u{0}\u{1F}\u{7F}") == [0x22] + Array("\\".utf8) + Array("u0000".utf8) + Array("\\".utf8) + Array("u001f".utf8) + [0x7F, 0x22])
        #expect(WebAuthnChecks.ccdString("\u{E9}\u{1F600}") == [0x22, 0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80, 0x22])
    }

    // MARK: authenticatorData

    @Test func truncatedOrTrailingOrAttestedAuthenticatorDataIsRefused() {
        #expect(valid.with { $0.authenticatorData = $0.authenticatorData.prefix(36) }.refusal == .authenticatorData)
        #expect(valid.with { $0.authenticatorData = Data() }.refusal == .authenticatorData)
        #expect(valid.with { $0.authenticatorData.append(0) }.refusal == .authenticatorData)
        // Attested credential data where none belongs: AT set and the data after the count.
        #expect(valid.with {
            $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x45) + Data(count: 16) + Data([0, 16]) + Data(count: 16)
        }.refusal == .authenticatorData)
        // AT set on a 37-byte one: a flag the assertion never has.
        #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x45) }.refusal == .flags)
        // Extension data: ED set, with or without the bytes.
        #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x85) }.refusal == .flags)
        #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x85) + Data([0xA0]) }.refusal == .authenticatorData)
    }

    @Test func anotherRpIdsHashIsRefused() {
        for rpId in ["sub.localhost", "localhost.", "LOCALHOST", "evil.example", ""] {
            #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(rpId: rpId) }.refusal == .rpIdHash, "\(rpId)")
        }
    }

    @Test func theFlagsMustBeUPAndUVAndNothingUnknown() {
        #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x04) }.refusal == .userPresence)
        #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x01) }.refusal == .userVerification)
        #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x00) }.refusal == .userPresence)
        #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x07) }.refusal == .flags)
        #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x25) }.refusal == .flags)
        // BS without BE is a combination WebAuthn doesn't allow.
        #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x15) }.refusal == .flags)
    }

    @Test func backupEligibilityMustBeTheRecordedOne() throws {
        #expect(valid.with { $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x0D) }.refusal == .backupEligibility)
        #expect(valid.with { $0.backupEligible = true }.refusal == .backupEligibility)
        let synced = valid.with { $0.backupEligible = true; $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x1D) }
        #expect(try synced.check() == WebAuthnAssertion.Verified(signCount: 1, backupState: true))
        let eligible = valid.with { $0.backupEligible = true; $0.authenticatorData = WebAuthnSupport.authenticatorData(flags: 0x0D) }
        #expect(try eligible.check() == WebAuthnAssertion.Verified(signCount: 1, backupState: false))
    }

    // MARK: The signature

    @Test func aSignatureNotInStrictDERIsRefused() {
        let der = [UInt8](valid.signature)
        func with(_ bytes: [UInt8]) -> Made { var made = valid; made.signature = Data(bytes); return made }
        #expect(with(der + [0]).refusal == .signatureEncoding)                                   // trailing byte
        #expect(with([0x30, 0x81, UInt8(der.count - 2)] + der[2...]).refusal == .signatureEncoding) // long-form length
        #expect(with([0x31] + der[1...]).refusal == .signatureEncoding)                           // a SET
        #expect(with([0x30, der[1] &+ 1] + der[2...]).refusal == .signatureEncoding)              // length off by one
        #expect(with(Array(der.dropLast())).refusal == .signatureEncoding)                         // truncated
        #expect(with([]).refusal == .signatureEncoding)
        // The raw 64 bytes (r || s, as WebCrypto signs) and an Ed25519-sized signature: not DER.
        #expect(with(Array(try! valid.key.signature(for: Data("x".utf8)).rawRepresentation)).refusal == .signatureEncoding)
        // r and s parsed again from the DER, then re-encoded wrongly.
        let (r, s) = Self.integers(der)
        func encoded(_ r: [UInt8], _ s: [UInt8]) -> [UInt8] {
            let body = [0x02, UInt8(r.count)] + r + [0x02, UInt8(s.count)] + s
            return [0x30, UInt8(body.count)] + body
        }
        #expect(with(encoded(r, s)).refusal == nil)                                                // the control
        // A byte after s that the SEQUENCE's own length covers, on a signature short enough (70 bytes, neither r nor s
        // with a leading zero) that the byte keeps it within the 72 a DER signature may have.
        var short = valid
        repeat { short.sign() } while short.signature.count > 70
        let (shortR, shortS) = Self.integers([UInt8](short.signature))
        let inner = [0x02, UInt8(shortR.count)] + shortR + [0x02, UInt8(shortS.count)] + shortS + [0x00]
        short.signature = Data([0x30, UInt8(inner.count)] + inner)
        #expect(short.signature.count <= 72 && short.refusal == .signatureEncoding)
        #expect(with(encoded([0] + r, s)).refusal == .signatureEncoding)                           // a needless leading zero
        #expect(with(encoded(r, [0] + s)).refusal == .signatureEncoding)
        #expect(with(encoded([0x80] + Array(repeating: 1, count: 31), s)).refusal == .signatureEncoding) // negative
        #expect(with(encoded([0xFF] + Array(repeating: 1, count: 31), s)).refusal == .signatureEncoding) // negative
        #expect(with(encoded([0], s)).refusal == .signatureEncoding)                               // r zero
        #expect(with(encoded(r, [0])).refusal == .signatureEncoding)                               // s zero
        #expect(with(encoded(Array(repeating: 1, count: 33), s)).refusal == .signatureEncoding)    // 33 bytes of value
        #expect(with([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01]).refusal == .signatureEncoding)
    }

    /// r and s of a DER signature this test made (well formed: no checks).
    static func integers(_ der: [UInt8]) -> ([UInt8], [UInt8]) {
        let rLength = Int(der[3])
        let r = Array(der[4..<(4 + rLength)])
        let s = Array(der[(6 + rLength)...])
        return (r, s)
    }

    @Test func aSignatureByAnotherKeyOrOverOtherBytesIsRefused() {
        var other = valid
        other.signature = try! P256.Signing.PrivateKey().signature(for: valid.authenticatorData + Data(SHA256.hash(data: valid.clientDataJSON))).derRepresentation
        #expect(other.refusal == .signature)
        var overClientData = valid
        overClientData.signature = try! valid.key.signature(for: valid.clientDataJSON).derRepresentation
        #expect(overClientData.refusal == .signature)
        // Signed, then one byte of the client data changed after the checked prefix (a member the check doesn't read).
        var changed = valid.with { $0.clientDataJSON = WebAuthnSupport.clientData(challenge: $0.challenge, origin: $0.listener.origin, tail: #","x":1}"#) }
        changed.clientDataJSON = WebAuthnSupport.clientData(challenge: changed.challenge, origin: changed.listener.origin, tail: #","x":2}"#)
        #expect(changed.refusal == .signature)
        // s replaced by n - s: the same signature's other form verifies (ECDSA allows both; nothing here relies on one).
        var high = valid
        high.signature = Self.negatedS(valid.signature)
        #expect(high.refusal == nil)
    }

    /// The signature with s replaced by n − s, P-256's order n.
    static func negatedS(_ der: Data) -> Data {
        let raw = [UInt8](try! P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation)
        let n: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                          0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51]
        var s = Array(raw[32...])
        var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) {
            var value = Int(n[index]) - Int(s[index]) - borrow
            borrow = value < 0 ? 1 : 0
            if value < 0 { value += 256 }
            s[index] = UInt8(value)
        }
        return try! P256.Signing.ECDSASignature(rawRepresentation: Array(raw[..<32]) + s).derRepresentation
    }

    // MARK: The sign count

    @Test func theSignCountMustAdvance() throws {
        func counted(stored: UInt32, new: UInt32) -> Made {
            valid.with { $0.storedSignCount = stored; $0.authenticatorData = WebAuthnSupport.authenticatorData(signCount: new) }
        }
        #expect(counted(stored: 5, new: 5).refusal == .signCount)      // repeated
        #expect(counted(stored: 5, new: 4).refusal == .signCount)      // stale
        #expect(counted(stored: 5, new: 0).refusal == .signCount)      // a counter that went back to zero
        #expect(counted(stored: .max, new: .max).refusal == .signCount)
        #expect(try counted(stored: 0, new: 0).check().signCount == 0) // an authenticator with no counter (Apple's)
        #expect(try counted(stored: 0, new: 1).check().signCount == 1)
        #expect(try counted(stored: 5, new: 6).check().signCount == 6)
        #expect(try counted(stored: 5, new: .max).check().signCount == .max)
    }

    // MARK: The credential, the device's binding (N5), the listener, the challenge

    @Test func anotherCredentialIsRefused() {
        #expect(valid.with { $0.credentialId[0] ^= 1 }.refusal == nil) // both sides changed: the same credential
        var other = valid
        other.credentialId[0] ^= 1
        let device = valid.device
        #expect(WebAuthnSupport.refusal { _ = try WebAuthnAssertion.check(other.response, challenge: valid.challenge, listener: valid.listener, device: device) }
                == .credential)
        #expect(valid.with { $0.credentialId = Data(count: 15) }.refusal == .credential)
        #expect(valid.with { $0.credentialId = Data(count: 1024) }.refusal == .credential)
        #expect(valid.with { $0.credentialId = Data(count: 16) }.refusal == nil)
        #expect(valid.with { $0.credentialId = Data(count: 1023) }.refusal == nil)
    }

    @Test func aDeviceEnrolledOnAnotherOriginOrPlaceIsRefused() {
        // The review's N5: the device's record must name this listener's origin, rpId and place.
        #expect(valid.with { $0.deviceOrigin = "http://localhost:3000" }.refusal == .enrolledElsewhere)
        #expect(valid.with { $0.deviceOrigin = "https://node.tail1234.ts.net:47830" }.refusal == .enrolledElsewhere)
        #expect(valid.with { $0.devicePlace = .tailnet }.refusal == .enrolledElsewhere)
        #expect(valid.with { $0.deviceRpId = "node.tail1234.ts.net" }.refusal == .enrolledElsewhere)
        // A phone's device on the loopback listener, and a loopback device on the serve gate.
        let phone = Made(listener: WebAuthnSupport.tailnet)
        #expect(phone.with { $0.listener = WebAuthnSupport.loopback }.refusal == .enrolledElsewhere)
        #expect(valid.with { $0.listener = WebAuthnSupport.tailnet }.refusal == .enrolledElsewhere)
    }

    @Test func aListenerTheDesignDoesntHaveIsRefused() {
        let listeners = [
            WebAuthnListener(origin: "http://127.0.0.1:47830", rpId: "127.0.0.1", place: .loopback),
            WebAuthnListener(origin: "https://localhost:47830", rpId: "localhost", place: .loopback),
            WebAuthnListener(origin: "http://localhost:47830/", rpId: "localhost", place: .loopback),
            WebAuthnListener(origin: "http://localhost:0", rpId: "localhost", place: .loopback),
            WebAuthnListener(origin: "http://localhost:047830", rpId: "localhost", place: .loopback),
            WebAuthnListener(origin: "http://localhost:65536", rpId: "localhost", place: .loopback),
            WebAuthnListener(origin: "http://localhost:", rpId: "localhost", place: .loopback),
            WebAuthnListener(origin: "http://sub.localhost:47830", rpId: "sub.localhost", place: .loopback),
            WebAuthnListener(origin: "http://localhost:47830", rpId: "sub.localhost", place: .loopback),
            WebAuthnListener(origin: "http://node.tail1234.ts.net:47830", rpId: "node.tail1234.ts.net", place: .tailnet),
            WebAuthnListener(origin: "https://100.64.0.1:47830", rpId: "100.64.0.1", place: .tailnet),
            WebAuthnListener(origin: "https://Node.ts.net:47830", rpId: "Node.ts.net", place: .tailnet),
            WebAuthnListener(origin: "https://node.ts.net:47830", rpId: "other.ts.net", place: .tailnet),
            WebAuthnListener(origin: "https://node..ts.net", rpId: "node..ts.net", place: .tailnet),
            WebAuthnListener(origin: "https://-node.ts.net", rpId: "-node.ts.net", place: .tailnet),
            WebAuthnListener(origin: "https://node", rpId: "node", place: .tailnet),
            WebAuthnListener(origin: #"https://no"de.ts.net"#, rpId: #"no"de.ts.net"#, place: .tailnet),
        ]
        for listener in listeners {
            #expect(valid.with { $0.listener = listener; $0.deviceOrigin = listener.origin; $0.deviceRpId = listener.rpId; $0.devicePlace = listener.place }
                .refusal == .listener, "\(listener)")
        }
        #expect(valid.with { $0.listener = WebAuthnListener(origin: "http://localhost", rpId: "localhost", place: .loopback)
            $0.deviceOrigin = "http://localhost"; $0.clientDataJSON = WebAuthnSupport.clientData(challenge: $0.challenge, origin: "http://localhost") }
            .refusal == nil)
    }

    @Test func aChallengeThatIsntThirtyTwoBytesIsRefused() {
        for count in [0, 16, 31, 33, 64] {
            let challenge = Data(repeating: 7, count: count)
            #expect(valid.with { $0.challenge = challenge; $0.clientDataJSON = WebAuthnSupport.clientData(challenge: challenge, origin: $0.listener.origin) }
                .refusal == .challenge, "\(count)")
        }
    }
}
