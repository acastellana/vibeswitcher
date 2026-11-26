import Foundation
import Testing
@testable import VibeCore

/// `WebAuthnRegistration.check` on registrations built by hand, byte by byte: the CBOR and COSE shapes a browser's
/// virtual authenticator never makes. Each differs from a valid registration in one thing. With attestation `none`
/// nothing signs the attestation object, so no case needs signing again.
struct WebAuthnRegistrationTests {
    static let listener = WebAuthnSupport.loopback
    static let challenge = Data((0..<32).map { UInt8(0x40 + $0) })
    let key = P256.Signing.PrivateKey()
    var x: [UInt8] { Array(key.publicKey.x963Representation[1..<33]) }
    var y: [UInt8] { Array(key.publicKey.x963Representation[33...]) }

    // MARK: Building one

    /// A CBOR head: major type and argument, in its shortest form.
    static func head(_ major: UInt8, _ argument: Int) -> [UInt8] {
        switch argument {
        case 0..<24: [major << 5 | UInt8(argument)]
        case 24..<0x100: [major << 5 | 24, UInt8(argument)]
        case 0x100..<0x1_0000: [major << 5 | 25, UInt8(argument >> 8), UInt8(argument & 0xFF)]
        default: [major << 5 | 26] + withUnsafeBytes(of: UInt32(argument).bigEndian) { Array($0) }
        }
    }
    static func text(_ text: String) -> [UInt8] { head(3, text.utf8.count) + Array(text.utf8) }
    static func bytes(_ bytes: [UInt8]) -> [UInt8] { head(2, bytes.count) + bytes }
    static func int(_ value: Int) -> [UInt8] { value >= 0 ? head(0, value) : head(1, -1 - value) }

    /// `{1: 2, 3: -7, -1: 1, -2: x, -3: y}`, canonical.
    static func cose(x: [UInt8], y: [UInt8]) -> [UInt8] {
        head(5, 5) + int(1) + int(2) + int(3) + int(-7) + int(-1) + int(1) + int(-2) + bytes(x) + int(-3) + bytes(y)
    }
    var cose: [UInt8] { Self.cose(x: x, y: y) }

    static func authData(rpId: String = "localhost", flags: UInt8 = 0x45, signCount: UInt32 = 0,
                         aaguid: [UInt8] = Array(repeating: 0, count: 16), credentialId: [UInt8] = Array(0..<32),
                         length: Int? = nil, key: [UInt8]) -> [UInt8] {
        let count = length ?? credentialId.count
        return Array(SHA256.hash(data: Data(rpId.utf8))) + [flags] + withUnsafeBytes(of: signCount.bigEndian) { Array($0) }
            + aaguid + [UInt8(count >> 8), UInt8(count & 0xFF)] + credentialId + key
    }
    func authData(flags: UInt8 = 0x45, rpId: String = "localhost") -> [UInt8] { Self.authData(rpId: rpId, flags: flags, key: cose) }

    /// `{"fmt": "none", "attStmt": {}, "authData": …}`, canonical.
    static func object(_ authData: [UInt8], fmt: String = "none", attStmt: [UInt8] = [0xA0]) -> [UInt8] {
        head(5, 3) + text("fmt") + text(fmt) + text("attStmt") + attStmt + text("authData") + bytes(authData)
    }

    static func clientData(type: String = "webauthn.create", origin: String = listener.origin, tail: String = "}") -> Data {
        WebAuthnSupport.clientData(type: type, challenge: challenge, origin: origin, tail: tail)
    }

    static func check(_ object: [UInt8], clientData: Data = clientData(), challenge: Data = challenge,
                      listener: WebAuthnListener = listener) throws(WebAuthnRefusal) -> WebAuthnRegistration.Verified {
        try WebAuthnRegistration.check(.init(clientDataJSON: clientData, attestationObject: Data(object)),
                                       challenge: challenge, listener: listener)
    }

    static func refusal(_ object: [UInt8], clientData: Data = clientData(), challenge: Data = challenge,
                        listener: WebAuthnListener = listener) -> WebAuthnRefusal? {
        WebAuthnSupport.refusal { _ = try check(object, clientData: clientData, challenge: challenge, listener: listener) }
    }

    // MARK: The valid one, and its client data

    @Test func aValidRegistrationPasses() throws {
        let aaguid = Array(repeating: UInt8(0xAA), count: 16)
        let made = Self.object(Self.authData(flags: 0x5D, signCount: 7, aaguid: aaguid, key: cose))
        let verified = try Self.check(made)
        #expect(verified.credentialId == Data(0..<32))
        #expect(verified.publicKey.x963Representation == key.publicKey.x963Representation)
        #expect(verified.coseKey == Data(cose) && verified.coseKey.count == 77)
        #expect(verified.signCount == 7 && verified.backupEligible && verified.backupState && verified.aaguid == Data(aaguid))
        #expect(Self.refusal(Self.object(authData())) == nil)
        // On the serve gate too.
        let phone = Self.object(Self.authData(rpId: WebAuthnSupport.tailnet.rpId, key: cose))
        #expect(Self.refusal(phone, clientData: Self.clientData(origin: WebAuthnSupport.tailnet.origin), listener: WebAuthnSupport.tailnet) == nil)
    }

    @Test func theClientDataIsCheckedAsAnAssertionsIs() {
        let made = Self.object(authData())
        #expect(Self.refusal(made, clientData: Self.clientData(type: "webauthn.get")) == .clientDataType)
        #expect(Self.refusal(made, clientData: Self.clientData(origin: "http://localhost:3000")) == .clientDataOrigin)
        #expect(Self.refusal(made, challenge: Data(repeating: 1, count: 32)) == .clientDataChallenge)
        #expect(Self.refusal(made, clientData: Self.clientData(tail: #","later":1}"#)) == nil)
        #expect(Self.refusal(made, clientData: Data(#"{"type":"webauthn.create","challenge":"x"}"#.utf8)) == .clientDataChallenge)
        #expect(Self.refusal(made, clientData: Data()) == .clientDataNotExact)
        #expect(Self.refusal(made, challenge: Data(count: 31)) == .challenge)
        #expect(Self.refusal(made, listener: WebAuthnListener(origin: "http://127.0.0.1:47830", rpId: "127.0.0.1", place: .loopback)) == .listener)
    }

    // MARK: The key

    @Test func anAlgorithmOtherThanES256IsRefused() {
        for alg in [-8, -257, -35, -36, -37, -47, 7, -6, 0] {
            let key = Self.head(5, 5) + Self.int(1) + Self.int(2) + Self.int(3) + Self.int(alg) + Self.int(-1) + Self.int(1)
                + Self.int(-2) + Self.bytes(x) + Self.int(-3) + Self.bytes(y)
            #expect(Self.refusal(Self.object(Self.authData(key: key))) == .coseKey, "\(alg)")
        }
    }

    @Test func aKeyNotOnTheCurveIsRefused() {
        var offCurve = y
        offCurve[31] ^= 1
        let p: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01] + Array(repeating: 0, count: 12) + Array(repeating: 0xFF, count: 12)
        for (x, y) in [(x, offCurve), (Array(repeating: 0, count: 32), Array(repeating: 0, count: 32)),
                       (p, y), (x, p), (Array(repeating: 0xFF, count: 32), Array(repeating: 0xFF, count: 32))] {
            #expect(Self.refusal(Self.object(Self.authData(key: Self.cose(x: x, y: y)))) == .coseKey)
        }
    }

    @Test func anRSAOrEd25519OrOtherCurveKeyIsRefused() {
        let rsa = Self.head(5, 4) + Self.int(1) + Self.int(3) + Self.int(3) + Self.int(-257)
            + Self.int(-1) + Self.bytes(Array(repeating: 0xC5, count: 256)) + Self.int(-2) + Self.bytes([1, 0, 1])
        let ed25519 = Self.head(5, 4) + Self.int(1) + Self.int(1) + Self.int(3) + Self.int(-8) + Self.int(-1) + Self.int(6)
            + Self.int(-2) + Self.bytes(Array(repeating: 0x11, count: 32))
        let p384 = Self.head(5, 5) + Self.int(1) + Self.int(2) + Self.int(3) + Self.int(-35) + Self.int(-1) + Self.int(2)
            + Self.int(-2) + Self.bytes(Array(repeating: 1, count: 48)) + Self.int(-3) + Self.bytes(Array(repeating: 2, count: 48))
        let okpShaped = Self.head(5, 5) + Self.int(1) + Self.int(1) + Self.int(3) + Self.int(-7) + Self.int(-1) + Self.int(1)
            + Self.int(-2) + Self.bytes(x) + Self.int(-3) + Self.bytes(y)
        let secp256k1 = Self.head(5, 5) + Self.int(1) + Self.int(2) + Self.int(3) + Self.int(-7) + Self.int(-1) + Self.int(8)
            + Self.int(-2) + Self.bytes(x) + Self.int(-3) + Self.bytes(y)
        let compressed = Self.head(5, 5) + Self.int(1) + Self.int(2) + Self.int(3) + Self.int(-7) + Self.int(-1) + Self.int(1)
            + Self.int(-2) + Self.bytes(x) + Self.int(-3) + [0xF5]
        for key in [rsa, ed25519, p384, okpShaped, secp256k1] {
            #expect(Self.refusal(Self.object(Self.authData(key: key))) == .coseKey)
        }
        #expect(Self.refusal(Self.object(Self.authData(key: compressed))) == .cbor) // y as `true`: a simple value
    }

    @Test func anOversizedCredentialIdOrKeyIsRefused() {
        for count in [0, 1, 15, 1024, 1500] {
            #expect(Self.refusal(Self.object(Self.authData(credentialId: Array(repeating: 9, count: count), key: cose))) == .credential, "\(count)")
        }
        // The length field naming more than there is.
        #expect(Self.refusal(Self.object(Self.authData(length: 1023, key: cose))) == .authenticatorData)
        // 16 and 1023 bytes, WebAuthn's bounds, pass.
        for count in [16, 1023] {
            #expect(Self.refusal(Self.object(Self.authData(credentialId: Array(repeating: 9, count: count), key: cose))) == nil, "\(count)")
        }
        // A coordinate of 33 bytes, and a sixth member.
        let wide = Self.head(5, 5) + Self.int(1) + Self.int(2) + Self.int(3) + Self.int(-7) + Self.int(-1) + Self.int(1)
            + Self.int(-2) + Self.bytes([0] + x) + Self.int(-3) + Self.bytes(y)
        #expect(Self.refusal(Self.object(Self.authData(key: wide))) == .coseKey)
        let extra = Self.head(5, 6) + Array(cose.dropFirst()) + Self.int(-4) + Self.bytes(Array(repeating: 7, count: 32))
        #expect(Self.refusal(Self.object(Self.authData(key: extra))) == .coseKey)
        // The whole object over 2048 bytes (a credential id the length field can't name runs past it too).
        let long = Self.object(Self.authData(credentialId: Array(repeating: 9, count: 1023), key: cose) + Array(repeating: 0, count: 900))
        #expect(long.count > 2048 && Self.refusal(long) == .cbor)
    }

    // MARK: The CBOR

    @Test func indefiniteLengthsAreRefused() {
        let data = authData()
        let indefiniteMap = [0xBF] + Self.text("fmt") + Self.text("none") + Self.text("attStmt") + [0xA0] + Self.text("authData")
            + Self.bytes(data) + [0xFF]
        let indefiniteText = Self.head(5, 3) + Self.text("fmt") + [0x7F] + Self.text("none") + [0xFF] + Self.text("attStmt") + [0xA0]
            + Self.text("authData") + Self.bytes(data)
        let indefiniteBytes = Self.head(5, 3) + Self.text("fmt") + Self.text("none") + Self.text("attStmt") + [0xA0]
            + Self.text("authData") + [0x5F] + Self.bytes(Array(data[..<100])) + Self.bytes(Array(data[100...])) + [0xFF]
        let indefiniteAttStmt = Self.object(data, attStmt: [0xBF, 0xFF])
        let indefiniteKey = Self.object(Self.authData(key: [0xBF] + Array(cose.dropFirst()) + [0xFF]))
        for object in [indefiniteMap, indefiniteText, indefiniteBytes, indefiniteAttStmt, indefiniteKey] {
            #expect(Self.refusal(object) == .cbor)
        }
    }

    @Test func nonCanonicalCBORIsRefused() {
        let data = authData()
        let object = Self.object(data)
        // A head wider than its value needs, at each level.
        let wideText = [0xA3, 0x78, 0x03] + Array("fmt".utf8) + Array(object[4...])
        let wideMap = [0xB8, 0x03] + Array(object[1...])
        let wideBytes = Self.head(5, 3) + Self.text("fmt") + Self.text("none") + Self.text("attStmt") + [0xA0] + Self.text("authData")
            + [0x5A, 0, 0, 0, UInt8(data.count)] + data
        let wideAttStmt = Self.object(data, attStmt: [0xB8, 0x00])
        let wideKeyInt = Self.object(Self.authData(key: [0xA5, 0x18, 0x01] + Array(cose[2...])))
        let wideCoordinate = Self.object(Self.authData(key: Array(cose[..<8]) + [0x59, 0x00, 0x20] + Array(cose[10...])))
        for object in [wideText, wideMap, wideBytes, wideAttStmt, wideKeyInt, wideCoordinate] {
            #expect(Self.refusal(object) == .cbor)
        }
        // The members out of the canonical order.
        let reordered = Self.head(5, 3) + Self.text("attStmt") + [0xA0] + Self.text("fmt") + Self.text("none") + Self.text("authData") + Self.bytes(data)
        let lastFirst = Self.head(5, 3) + Self.text("authData") + Self.bytes(data) + Self.text("fmt") + Self.text("none") + Self.text("attStmt") + [0xA0]
        #expect(Self.refusal(reordered) == .cbor)
        #expect(Self.refusal(lastFirst) == .cbor)
        let keyReordered = Self.head(5, 5) + Self.int(3) + Self.int(-7) + Self.int(1) + Self.int(2) + Self.int(-1) + Self.int(1)
            + Self.int(-2) + Self.bytes(x) + Self.int(-3) + Self.bytes(y)
        #expect(Self.refusal(Self.object(Self.authData(key: keyReordered))) == .coseKey)
        // The reserved heads (28 to 30), a tag, a float, an array, a simple value.
        for initial: UInt8 in [0xBC, 0xBD, 0xBE] { #expect(Self.refusal([initial] + Array(object[1...])) == .cbor) }
        #expect(Self.refusal([0xD8, 0x18] + Self.bytes(object)) == .cbor)
        #expect(Self.refusal([0xC0] + object) == .cbor)
        let float = Self.head(5, 3) + Self.text("fmt") + [0xFA, 0, 0, 0, 0] + Array(object[10...])
        #expect(Self.refusal(float) == .cbor)
        #expect(Self.refusal([0x83] + Array(object[1...])) == .cbor)
        #expect(Self.refusal(Self.object(data, attStmt: [0xF6])) == .cbor)
        // Trailing bytes, and nothing at all.
        #expect(Self.refusal(object + [0x00]) == .cbor)
        #expect(Self.refusal([]) == .cbor)
        #expect(Self.refusal(Array(object.dropLast())) == .cbor)
    }

    @Test func duplicateMapKeysAreRefused() {
        let data = authData()
        let twice = Self.head(5, 3) + Self.text("fmt") + Self.text("none") + Self.text("fmt") + Self.text("none") + Self.text("authData") + Self.bytes(data)
        let four = Self.head(5, 4) + Self.text("fmt") + Self.text("none") + Self.text("attStmt") + [0xA0] + Self.text("authData")
            + Self.bytes(data) + Self.text("authData") + Self.bytes(data)
        let authDataTwice = Self.head(5, 3) + Self.text("fmt") + Self.text("none") + Self.text("authData") + Self.bytes(data) + Self.text("authData") + Self.bytes(data)
        #expect(Self.refusal(twice) == .cbor)
        #expect(Self.refusal(four) == .cbor)
        #expect(Self.refusal(authDataTwice) == .cbor)
        let ktyTwice = Self.head(5, 5) + Self.int(1) + Self.int(2) + Self.int(1) + Self.int(2) + Self.int(-1) + Self.int(1)
            + Self.int(-2) + Self.bytes(x) + Self.int(-3) + Self.bytes(y)
        let xTwice = Self.head(5, 6) + Array(cose[1..<8]) + Self.int(-2) + Self.bytes(x) + Self.int(-2) + Self.bytes(x) + Self.int(-3) + Self.bytes(y)
        #expect(Self.refusal(Self.object(Self.authData(key: ktyTwice))) == .coseKey)
        #expect(Self.refusal(Self.object(Self.authData(key: xTwice))) == .coseKey)
    }

    @Test func nestingBeyondTheBoundIsRefused() {
        let data = authData()
        // attStmt holding maps inside maps; authData a map 10,000 deep (never recursed into); a coordinate as a map.
        var deep: [UInt8] = [0xA0]
        for _ in 0..<64 { deep = Self.head(5, 1) + Self.text("x") + deep }
        #expect(Self.refusal(Self.object(data, attStmt: deep)) == .attestationFormat)
        let tower = Self.head(5, 3) + Self.text("fmt") + Self.text("none") + Self.text("attStmt") + [0xA0] + Self.text("authData")
            + Array(repeating: 0xA1, count: 10_000)
        #expect(Self.refusal(tower) == .cbor)
        let arrays = Self.head(5, 3) + Self.text("fmt") + Self.text("none") + Self.text("attStmt") + [0xA0] + Self.text("authData")
            + Array(repeating: 0x81, count: 10_000) + [0x00]
        #expect(Self.refusal(arrays) == .cbor)
        let nestedKey = Self.head(5, 5) + Array(cose[1..<8]) + Self.int(-2) + Self.head(5, 1) + Self.int(1) + Self.bytes(x)
            + Self.int(-3) + Self.bytes(y)
        #expect(Self.refusal(Self.object(Self.authData(key: nestedKey))) == .coseKey)
    }

    @Test func anyAttestationFormatButNoneIsRefused() {
        let data = authData()
        for fmt in ["packed", "fido-u2f", "tpm", "android-key", "android-safetynet", "apple", "compound", "None", "none ", "", "nonee"] {
            #expect(Self.refusal(Self.object(data, fmt: fmt)) == .attestationFormat, "\(fmt)")
        }
        // `none` with a statement.
        let statement = Self.head(5, 2) + Self.text("alg") + Self.int(-7) + Self.text("sig") + Self.bytes(Array(repeating: 1, count: 70))
        #expect(Self.refusal(Self.object(data, attStmt: statement)) == .attestationFormat)
        // A packed statement's x5c is an array: refused before any of it is read.
        let packed = Self.head(5, 3) + Self.text("alg") + Self.int(-7) + Self.text("sig") + Self.bytes([1]) + Self.text("x5c") + [0x81] + Self.bytes([2])
        #expect(Self.refusal(Self.object(data, fmt: "packed", attStmt: packed)) == .attestationFormat)
        // `fmt` not a text string.
        let bytesFormat = Self.head(5, 3) + Self.text("fmt") + Self.bytes(Array("none".utf8)) + Self.text("attStmt") + [0xA0] + Self.text("authData") + Self.bytes(data)
        #expect(Self.refusal(bytesFormat) == .cbor)
    }

    // MARK: The authenticator data

    @Test func theAuthenticatorDataMustBeWholeAndAttested() {
        #expect(Self.refusal(Self.object(Array(authData()[..<54]))) == .authenticatorData)    // before the id's length ends
        #expect(Self.refusal(Self.object(Array(authData()[..<37]))) == .authenticatorData)    // an assertion's
        #expect(Self.refusal(Self.object(Array(authData()[..<(55 + 32)]))) == .authenticatorData) // no key
        #expect(Self.refusal(Self.object(Array(authData().dropLast()))) == .cbor)            // the key cut short
        #expect(Self.refusal(Self.object(authData() + [0x00]))  == .authenticatorData)       // trailing bytes
        #expect(Self.refusal(Self.object(authData() + [0xA0]))  == .authenticatorData)       // an extensions map without ED
        #expect(Self.refusal(Self.object(authData(flags: 0xC5) + [0xA0])) == .flags)          // ED set
        #expect(Self.refusal(Self.object(authData(flags: 0x05))) == .flags)                   // AT clear
        #expect(Self.refusal(Self.object(authData(flags: 0x44))) == .userPresence)
        #expect(Self.refusal(Self.object(authData(flags: 0x41))) == .userVerification)
        #expect(Self.refusal(Self.object(authData(flags: 0x55))) == .flags)                   // BS without BE
        #expect(Self.refusal(Self.object(authData(flags: 0x47))) == .flags)                   // reserved bit
        #expect(Self.refusal(Self.object(authData(flags: 0x65))) == .flags)                   // reserved bit
        #expect(Self.refusal(Self.object(authData(rpId: "sub.localhost"))) == .rpIdHash)
        #expect(Self.refusal(Self.object([]))  == .authenticatorData)
    }
}
