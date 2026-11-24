import Foundation
import VibeCore

/// The CBOR the WebAuthn objects are written in (RFC 8949), read as far as they need: unsigned and negative integers,
/// byte and text strings, arrays, maps, and the simple values false, true and null. Definite lengths only (WebAuthn's
/// CTAP2 canonical form has nothing else); nesting at most `depth` deep; every length checked against what is left, so
/// no input makes it read past its end or allocate more than its own size. Floats, tags and indefinite lengths are
/// refused.
public enum CBOR: Equatable, Sendable {
    case unsigned(UInt64)
    case negative(UInt64) // -1 - n
    case bytes([UInt8])
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case bool(Bool)
    case null

    public static func == (a: CBOR, b: CBOR) -> Bool {
        switch (a, b) {
        case (.unsigned(let x), .unsigned(let y)), (.negative(let x), .negative(let y)): return x == y
        case (.bytes(let x), .bytes(let y)): return x == y
        case (.text(let x), .text(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.map(let x), .map(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public struct Refused: Error, Equatable, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    static let depth = 16

    /// The first item of `bytes`, and where it ends.
    public static func read(_ bytes: [UInt8], from start: Int = 0) throws -> (CBOR, Int) {
        var at = start
        let item = try item(bytes, &at, depth: 0)
        return (item, at)
    }

    /// `bytes` as one item, nothing after it.
    public static func whole(_ bytes: [UInt8]) throws -> CBOR {
        let (item, end) = try read(bytes)
        guard end == bytes.count else { throw Refused("bytes after the item") }
        return item
    }

    private static func item(_ bytes: [UInt8], _ at: inout Int, depth: Int) throws -> CBOR {
        guard depth <= Self.depth else { throw Refused("nested too deep") }
        guard at < bytes.count else { throw Refused("ends early") }
        let head = bytes[at]
        at += 1
        let major = head >> 5, info = head & 0x1F
        func argument() throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24, 25, 26, 27:
                let count = 1 << Int(info - 24)
                guard bytes.count - at >= count else { throw Refused("ends early") }
                var value: UInt64 = 0
                for _ in 0..<count { value = value << 8 | UInt64(bytes[at]); at += 1 }
                return value
            default: throw Refused("an indefinite or reserved length")
            }
        }
        func length() throws -> Int {
            let value = try argument()
            guard value <= UInt64(bytes.count - at) else { throw Refused("a length past the end") }
            return Int(value)
        }
        switch major {
        case 0: return .unsigned(try argument())
        case 1: return .negative(try argument())
        case 2:
            let count = try length()
            defer { at += count }
            return .bytes(Array(bytes[at..<(at + count)]))
        case 3:
            let count = try length()
            defer { at += count }
            guard let text = String(bytes: bytes[at..<(at + count)], encoding: .utf8) else { throw Refused("text that isn't UTF-8") }
            return .text(text)
        case 4:
            let count = try length() // each item is at least one byte: bounded by what is left
            var items: [CBOR] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try item(bytes, &at, depth: depth + 1)) }
            return .array(items)
        case 5:
            let count = try argument()
            guard count <= UInt64(bytes.count - at) / 2 else { throw Refused("a map past the end") }
            var pairs: [(CBOR, CBOR)] = []
            pairs.reserveCapacity(Int(count))
            for _ in 0..<count { pairs.append((try item(bytes, &at, depth: depth + 1), try item(bytes, &at, depth: depth + 1))) }
            return .map(pairs)
        case 7:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default: throw Refused("a float or a simple value WebAuthn doesn't use")
            }
        default: throw Refused("a tag")
        }
    }

    /// A map's value for an integer key (COSE's labels) or a text key.
    public subscript(int key: Int) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { key >= 0 ? $0.0 == .unsigned(UInt64(key)) : $0.0 == .negative(UInt64(-1 - key)) }?.1
    }

    public subscript(text key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.0 == .text(key) }?.1
    }

    public var bytes: [UInt8]? { if case .bytes(let value) = self { return value } else { return nil } }
    public var text: String? { if case .text(let value) = self { return value } else { return nil } }
    public var int: Int? {
        switch self {
        case .unsigned(let value): return value <= UInt64(Int.max) ? Int(value) : nil
        case .negative(let value): return value < UInt64(Int.max) ? -1 - Int(value) : nil
        default: return nil
        }
    }
}

/// WebAuthn as the node checks it (the `confirm` level: a passkey per acting request; the web UI design's step 2): the
/// relying party is `localhost` (an IP address can't be one), the origin exactly `http://localhost:PORT`, ES256 the one
/// algorithm, user verification required. A registration's attestation is "none" (nothing about the authenticator is
/// trusted or recorded but its key); an assertion is checked against the key the vault keeps, its signature over the
/// authenticator data and the client data's hash, its challenge one this node issued for exactly the request it comes
/// with. No third-party code: swift-crypto's P-256 (CryptoKit on the Mac) and `CBOR` above.
public enum WebAuthn {
    public static let rpID = "localhost"
    /// ES256 (COSE algorithm -7): ECDSA on P-256 with SHA-256.
    public static let es256 = -7

    public struct Refused: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// base64url without padding, as WebAuthn and the page write it.
    public static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func bytes(base64url text: String) -> [UInt8]? {
        guard text.utf8.count <= 64 * 1024, text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }
        return Data(base64Encoded: standard).map { [UInt8]($0) }
    }

    /// The authenticator data's parts (WebAuthn §6.1).
    public struct AuthenticatorData: Equatable {
        public var rpIDHash: [UInt8]
        public var userPresent: Bool
        public var userVerified: Bool
        public var signCount: UInt32
        /// Set at a registration: the credential's id and its COSE public key.
        public var credentialID: [UInt8]?
        public var publicKey: CBOR?

        public static func parse(_ bytes: [UInt8]) throws -> AuthenticatorData {
            guard bytes.count >= 37 else { throw Refused("authenticator data too short") }
            let flags = bytes[32]
            let count = bytes[33..<37].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            var parsed = AuthenticatorData(rpIDHash: Array(bytes[0..<32]), userPresent: flags & 0x01 != 0, userVerified: flags & 0x04 != 0,
                                           signCount: count, credentialID: nil, publicKey: nil)
            guard flags & 0x40 != 0 else { return parsed } // AT: attested credential data follows
            var at = 37 + 16 // the AAGUID, unread
            guard bytes.count >= at + 2 else { throw Refused("attested data too short") }
            let idLength = Int(bytes[at]) << 8 | Int(bytes[at + 1])
            at += 2
            guard idLength <= 1023, bytes.count >= at + idLength else { throw Refused("a credential id past the end") }
            parsed.credentialID = Array(bytes[at..<(at + idLength)])
            at += idLength
            let (key, end) = try CBOR.read(bytes, from: at)
            // Extensions (ED) may follow; none is asked for, so none may.
            guard end == bytes.count || flags & 0x80 != 0 else { throw Refused("bytes after the credential's key") }
            parsed.publicKey = key
            return parsed
        }
    }

    /// A COSE EC2 P-256 key (kty 2, alg -7, crv 1, x and y of 32 bytes) as X9.63 bytes (04 ‖ x ‖ y).
    public static func p256(cose key: CBOR) throws -> [UInt8] {
        guard key[int: 1]?.int == 2, key[int: 3]?.int == es256, key[int: -1]?.int == 1,
              let x = key[int: -2]?.bytes, let y = key[int: -3]?.bytes, x.count == 32, y.count == 32 else {
            throw Refused("not an ES256 P-256 key")
        }
        let x963 = [0x04] + x + y
        _ = try P256.Signing.PublicKey(x963Representation: x963)
        return x963
    }

    /// The client data as the browser wrote it: its type, challenge (raw) and origin checked; `crossOrigin` false.
    public static func clientData(_ json: [UInt8], type: String, challenge: [UInt8], origin: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any] else { throw Refused("client data isn't JSON") }
        guard object["type"] as? String == type else { throw Refused("client data of another type") }
        guard let given = (object["challenge"] as? String).flatMap({ bytes(base64url: $0) }), given == challenge else {
            throw Refused("the challenge isn't the one issued for this")
        }
        guard object["origin"] as? String == origin else { throw Refused("the origin isn't \(origin)") }
        if let cross = object["crossOrigin"] as? Bool, cross { throw Refused("a cross-origin request") }
    }

    /// The authenticator data's relying party, user presence and verification.
    static func checked(_ data: AuthenticatorData) throws {
        guard data.rpIDHash == Array(SHA256.hash(data: Data(rpID.utf8))) else { throw Refused("another relying party") }
        guard data.userPresent else { throw Refused("no user presence") }
        guard data.userVerified else { throw Refused("the user wasn't verified (a PIN or a biometric is required)") }
    }

    /// A registration (`navigator.credentials.create`, attestation "none"): the credential's id and its key (X9.63).
    public static func registration(clientDataJSON: [UInt8], attestationObject: [UInt8], challenge: [UInt8], origin: String) throws
        -> (id: [UInt8], publicKey: [UInt8]) {
        try clientData(clientDataJSON, type: "webauthn.create", challenge: challenge, origin: origin)
        let attestation = try CBOR.whole(attestationObject)
        guard let authBytes = attestation[text: "authData"]?.bytes else { throw Refused("no authenticator data") }
        let data = try AuthenticatorData.parse(authBytes)
        try checked(data)
        guard let id = data.credentialID, !id.isEmpty, let key = data.publicKey else { throw Refused("no credential in it") }
        return (id, try p256(cose: key))
    }

    /// An assertion (`navigator.credentials.get`) by the key `publicKey` (X9.63): its signature over the authenticator
    /// data and the client data's hash, and the authenticator data's sign count.
    public static func assertion(clientDataJSON: [UInt8], authenticatorData: [UInt8], signature: [UInt8], publicKey: [UInt8],
                                 challenge: [UInt8], origin: String) throws -> UInt32 {
        try clientData(clientDataJSON, type: "webauthn.get", challenge: challenge, origin: origin)
        let data = try AuthenticatorData.parse(authenticatorData)
        try checked(data)
        let key = try P256.Signing.PublicKey(x963Representation: publicKey)
        guard let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { throw Refused("a signature that isn't DER") }
        let signed = Data(authenticatorData) + Data(SHA256.hash(data: Data(clientDataJSON)))
        guard key.isValidSignature(parsed, for: signed) else { throw Refused("the signature doesn't check") }
        return data.signCount
    }
}
