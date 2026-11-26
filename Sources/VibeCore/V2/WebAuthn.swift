import Foundation

// The device keys design's slices 2 and 3 (docs/superpowers/specs/2026-11-26-v2-device-keys-design.md, "The unlock"
// and "The first device"): the node's check of a passkey assertion (`WebAuthnAssertion`) and of a passkey
// registration (`WebAuthnRegistration`). Pure functions over the bytes a browser returns and what the server expects;
// each yields a verified result or one `WebAuthnRefusal`. Nothing here keeps state, reads a clock or calls out: the
// caller issues and spends the challenge, finds the device record, and stores what a check returns.
//
// Only what the design uses is taken: ES256 (COSE EC2, P-256, alg -7), attestation `none`, user presence and user
// verification both set, no extensions. Everything else WebAuthn allows is refused, and so is anything unusual or
// unparseable: each check fails closed rather than handling a case.

/// Where a listener (and a device enrolled on it) is: the loopback page (`http://localhost:<port>`) or the serve gate
/// (`https://<name>:<port>`).
public enum WebAuthnPlace: String, Sendable, Equatable {
    case loopback
    case tailnet
}

/// What the server expects of one listener: its exact origin, its rpId and its place. Checked whole before any byte
/// of a ceremony is read (`WebAuthnRefusal.listener` when it isn't one the design has).
public struct WebAuthnListener: Sendable, Equatable {
    public let origin: String
    public let rpId: String
    public let place: WebAuthnPlace

    public init(origin: String, rpId: String, place: WebAuthnPlace) {
        self.origin = origin
        self.rpId = rpId
        self.place = place
    }
}

/// Why a ceremony was refused: the first check it failed, in the order each type's `check` lists.
public enum WebAuthnRefusal: Error, Sendable, Equatable {
    /// The listener isn't one the design has: a loopback listener is `http://localhost[:port]`, a tailnet one
    /// `https://<rpId>[:port]`, the rpId a lower-case DNS name and never an IP address.
    case listener
    /// The challenge the server says it issued isn't 32 bytes.
    case challenge
    /// The device's record names another origin, rpId or place than this listener's (N5).
    case enrolledElsewhere
    /// The assertion names another credential than the device's, or a credential id is outside 16 to 1023 bytes.
    case credential
    /// `clientDataJSON` isn't the spec's serialization with the expected members first (WebAuthn L3 §5.8.1.2), or is
    /// over its bound, or its tail isn't `}` or `,"` … `}` in UTF-8.
    case clientDataNotExact
    /// `type` is another ceremony's (`webauthn.create` for an assertion, `webauthn.get` for a registration).
    case clientDataType
    /// `challenge` isn't the issued one, in unpadded base64url.
    case clientDataChallenge
    /// `origin` isn't exactly the listener's.
    case clientDataOrigin
    /// `crossOrigin` is true.
    case clientDataCrossOrigin
    /// `authenticatorData` is truncated, has trailing bytes, or isn't the shape the ceremony has.
    case authenticatorData
    /// `rpIdHash` isn't SHA-256 of the listener's rpId.
    case rpIdHash
    /// The UP flag isn't set.
    case userPresence
    /// The UV flag isn't set.
    case userVerification
    /// A flag the ceremony never has: AT on an assertion or missing on a registration, ED, a reserved bit, or BS
    /// without BE.
    case flags
    /// BE differs from the device's recorded backup eligibility (it never changes for a credential).
    case backupEligibility
    /// The signature isn't one strict DER ECDSA signature (SEQUENCE of two minimal positive INTEGERs, nothing after).
    case signatureEncoding
    /// The signature doesn't verify under the device's key over `authenticatorData || SHA-256(clientDataJSON)`.
    case signature
    /// The sign count didn't advance: with either count non-zero, the new one must exceed the stored one.
    case signCount
}

/// The check of a passkey assertion (`unlock`, a guarded change, a knock): "The unlock", step 3, of the device keys
/// design. In order, failing closed at the first that fails:
///
/// 1. the listener is one the design has, and the challenge 32 bytes;
/// 2. the device's record names this listener's origin, rpId and place (N5);
/// 3. the assertion's credential id is the device's;
/// 4. `clientDataJSON` passes WebAuthn L3's limited verification (§5.8.1.2) for `webauthn.get`, the challenge, the
///    listener's origin and `crossOrigin` false, within 1024 bytes, its tail `}` or `,` … `}` in UTF-8;
/// 5. `authenticatorData` is exactly 37 bytes (rpIdHash, flags, signCount: no attested data, no extensions);
/// 6. its rpIdHash is SHA-256 of the listener's rpId;
/// 7. UP set; UV set; AT, ED and the reserved bits (0x02, 0x20) clear; BS only with BE; BE as the device recorded;
/// 8. the signature is strict DER and verifies under the device's key over `authenticatorData || SHA-256(clientDataJSON)`;
/// 9. the sign count: when the stored or the new one is non-zero, the new one exceeds the stored one.
public enum WebAuthnAssertion {
    /// The device record's part an assertion is checked against.
    public struct Device: Sendable {
        public let credentialId: Data
        public let publicKey: P256.Signing.PublicKey
        public let origin: String
        public let rpId: String
        public let place: WebAuthnPlace
        public let signCount: UInt32
        public let backupEligible: Bool

        public init(credentialId: Data, publicKey: P256.Signing.PublicKey, origin: String, rpId: String,
                    place: WebAuthnPlace, signCount: UInt32, backupEligible: Bool) {
            self.credentialId = credentialId
            self.publicKey = publicKey
            self.origin = origin
            self.rpId = rpId
            self.place = place
            self.signCount = signCount
            self.backupEligible = backupEligible
        }
    }

    /// What the browser returned (`PublicKeyCredential.rawId` and its `AuthenticatorAssertionResponse`), as bytes.
    public struct Response: Sendable {
        public let credentialId: Data
        public let clientDataJSON: Data
        public let authenticatorData: Data
        public let signature: Data

        public init(credentialId: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data) {
            self.credentialId = credentialId
            self.clientDataJSON = clientDataJSON
            self.authenticatorData = authenticatorData
            self.signature = signature
        }
    }

    /// A verified assertion: the sign count to store, and the backup state the authenticator reported (shown as
    /// "synced with your Apple account").
    public struct Verified: Sendable, Equatable {
        public let signCount: UInt32
        public let backupState: Bool
    }

    /// The check, in the order above. `challenge` is the 32 bytes the server issued (the design's SHA-256 of the
    /// ceremony's inputs).
    public static func check(_ response: Response, challenge: Data, listener: WebAuthnListener,
                             device: Device) throws(WebAuthnRefusal) -> Verified {
        try WebAuthnChecks.listener(listener)
        guard challenge.count == 32 else { throw .challenge }
        guard device.origin == listener.origin, device.rpId == listener.rpId, device.place == listener.place else {
            throw .enrolledElsewhere
        }
        guard WebAuthnChecks.credentialIdSizes.contains(response.credentialId.count),
              response.credentialId == device.credentialId else { throw .credential }
        try WebAuthnChecks.clientData(response.clientDataJSON, type: "webauthn.get", challenge: challenge,
                                      origin: listener.origin)
        let data = [UInt8](response.authenticatorData)
        guard data.count == 37 else { throw .authenticatorData }
        guard data[0..<32].elementsEqual(SHA256.hash(data: Data(listener.rpId.utf8))) else { throw .rpIdHash }
        let flags = try WebAuthnChecks.flags(data[32], attested: false)
        guard flags.backupEligible == device.backupEligible else { throw .backupEligibility }
        let signature = try WebAuthnChecks.rawSignature(response.signature)
        var signed = response.authenticatorData
        signed.append(contentsOf: SHA256.hash(data: response.clientDataJSON))
        guard device.publicKey.isValidSignature(signature, for: signed) else { throw .signature }
        let signCount = UInt32(data[33]) << 24 | UInt32(data[34]) << 16 | UInt32(data[35]) << 8 | UInt32(data[36])
        if signCount != 0 || device.signCount != 0 {
            guard signCount > device.signCount else { throw .signCount }
        }
        return Verified(signCount: signCount, backupState: flags.backupState)
    }
}

/// The checks both ceremonies share. Internal: slice 1's DeviceProof.swift lands in the same module.
enum WebAuthnChecks {
    /// WebAuthn L3's bounds on a credential id: "at least 16 bytes" (§4, Credential ID, the random form) and "at most
    /// 1023 bytes" (§6.5.1, `credentialIdLength`).
    static let credentialIdSizes = 16...1023
    /// The longest `clientDataJSON` taken: the four members with a 253-byte host name come to about 400 bytes, and
    /// Chrome's extra member to 120 more.
    static let clientDataLimit = 1024

    /// The listener's shape (`WebAuthnRefusal.listener`): a loopback one `http://localhost[:port]`, a tailnet one
    /// `https://<rpId>[:port]`; the rpId lower-case letters, digits, `-` and `.` in labels of 1 to 63, at most 253,
    /// its last label not all digits (an IP address is no rpId); the port 1 to 65535, no leading zero.
    static func listener(_ listener: WebAuthnListener) throws(WebAuthnRefusal) {
        let rpId = listener.rpId
        let labels = rpId.split(separator: ".", omittingEmptySubsequences: false)
        guard !rpId.isEmpty, rpId.utf8.count <= 253,
              labels.allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && label.utf8.first != UInt8(ascii: "-") && label.utf8.last != UInt8(ascii: "-")
                      && label.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-") }
              }),
              let last = labels.last, !last.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { throw .listener }
        let scheme: String
        switch listener.place {
        case .loopback:
            guard rpId == "localhost" else { throw .listener }
            scheme = "http://"
        case .tailnet:
            guard labels.count >= 2 else { throw .listener }
            scheme = "https://"
        }
        let base = scheme + rpId
        guard listener.origin.hasPrefix(base) else { throw .listener }
        let rest = listener.origin.dropFirst(base.count)
        if rest.isEmpty { return }
        guard rest.first == ":" else { throw .listener }
        let port = rest.dropFirst()
        guard (1...5).contains(port.utf8.count), port.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              port.first != "0", let number = Int(port), number <= 65535 else { throw .listener }
    }

    /// WebAuthn L3 §5.8.1.1's CCDToString: a JSON string of `text`, `"` and `\` escaped by a backslash, U+0000 to
    /// U+001F as `\u` and four lower-case hex digits, every other code point in UTF-8.
    static func ccdString(_ text: String) -> [UInt8] {
        var encoded: [UInt8] = [0x22]
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: encoded += [0x5C, 0x22]
            case 0x5C: encoded += [0x5C, 0x5C]
            case 0x00...0x1F: encoded += Array(String(format: "\\u%04x", scalar.value).utf8)
            default: encoded += Array(String(scalar).utf8)
            }
        }
        encoded.append(0x22)
        return encoded
    }

    /// WebAuthn L3 §5.8.1.2's limited verification, with no topOrigin (a frame's ceremony is refused): `clientDataJSON`
    /// begins exactly `{"type":T,"challenge":C,"origin":O,"crossOrigin":false`, T, C (the challenge in unpadded
    /// base64url) and O built here by CCDToString, and what follows is `}` alone, or `,"` (the next member's name:
    /// §5.8.1.1 step 14 serializes the rest as JSON members) then anything ending in `}`, in UTF-8. The JSON is never parsed: nothing after the checked prefix can override it. The refusal names the
    /// first piece that differs when the bytes there begin as that member's value would; anything else is
    /// `clientDataNotExact`.
    static func clientData(_ bytes: Data, type: String, challenge: Data, origin: String) throws(WebAuthnRefusal) {
        guard bytes.count <= clientDataLimit else { throw .clientDataNotExact }
        let data = [UInt8](bytes)
        // Each piece, and what a difference in it is when the bytes there start as its value (`"` for a string,
        // `t` for `true`): the members' names and separators are never a value.
        let pieces: [([UInt8], WebAuthnRefusal?, UInt8?)] = [
            (Array(#"{"type":"#.utf8), nil, nil),
            (ccdString(type), .clientDataType, 0x22),
            (Array(#","challenge":"#.utf8), nil, nil),
            (ccdString(Base64URL.encode(challenge)), .clientDataChallenge, 0x22),
            (Array(#","origin":"#.utf8), nil, nil),
            (ccdString(origin), .clientDataOrigin, 0x22),
            (Array(#","crossOrigin":"#.utf8), nil, nil),
            (Array("false".utf8), .clientDataCrossOrigin, UInt8(ascii: "t")),
        ]
        var at = 0
        for (piece, refusal, starts) in pieces {
            guard data.count >= at + piece.count, data[at..<(at + piece.count)].elementsEqual(piece) else {
                if let refusal, let starts, at < data.count, data[at] == starts { throw refusal }
                throw .clientDataNotExact
            }
            at += piece.count
        }
        let tail = data[at...]
        if tail.elementsEqual([0x7D]) { return }
        // UTF-8 when decoding it changes nothing (an invalid sequence would come back as U+FFFD).
        guard tail.starts(with: [0x2C, 0x22]), tail.count >= 3, tail.last == 0x7D,
              String(decoding: tail, as: UTF8.self).utf8.elementsEqual(tail) else {
            throw .clientDataNotExact
        }
    }

    /// The authenticator data flags (WebAuthn L3 §6.1): UP and UV set; AT set exactly when the ceremony carries
    /// attested credential data (`attested`); ED and the reserved bits 0x02 and 0x20 clear; BS only with BE.
    static func flags(_ flags: UInt8, attested: Bool) throws(WebAuthnRefusal) -> (backupEligible: Bool, backupState: Bool) {
        guard flags & 0x01 != 0 else { throw .userPresence }
        guard flags & 0x04 != 0 else { throw .userVerification }
        guard (flags & 0x40 != 0) == attested, flags & 0x80 == 0, flags & 0x22 == 0 else { throw .flags }
        let eligible = flags & 0x08 != 0, state = flags & 0x10 != 0
        guard eligible || !state else { throw .flags }
        return (eligible, state)
    }

    /// A WebAuthn ES256 signature (ASN.1 DER, WebAuthn L3 §6.5.6) as P-256's 64-byte r || s, parsed here strictly so
    /// neither CryptoKit's nor swift-crypto's DER reading decides what is taken: SEQUENCE (short-form length, the
    /// rest of the bytes exactly) of two INTEGERs, each 1 to 33 bytes, positive, minimal (a leading zero only before
    /// a byte with its top bit set), not zero, at most 32 bytes of value.
    static func rawSignature(_ der: Data) throws(WebAuthnRefusal) -> P256.Signing.ECDSASignature {
        let bytes = [UInt8](der)
        guard bytes.count >= 8, bytes.count <= 72, bytes[0] == 0x30, Int(bytes[1]) == bytes.count - 2 else {
            throw .signatureEncoding
        }
        var at = 2
        var raw: [UInt8] = []
        for _ in 0..<2 {
            guard at + 2 <= bytes.count, bytes[at] == 0x02 else { throw .signatureEncoding }
            let length = Int(bytes[at + 1])
            guard (1...33).contains(length), at + 2 + length <= bytes.count else { throw .signatureEncoding }
            var value = Array(bytes[(at + 2)..<(at + 2 + length)])
            guard value[0] & 0x80 == 0 else { throw .signatureEncoding }
            if value[0] == 0 {
                guard value.count > 1, value[1] & 0x80 != 0 else { throw .signatureEncoding }
                value.removeFirst()
            }
            guard value.count <= 32, value.contains(where: { $0 != 0 }) else { throw .signatureEncoding }
            raw += [UInt8](repeating: 0, count: 32 - value.count) + value
            at += 2 + length
        }
        guard at == bytes.count, let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else {
            throw .signatureEncoding
        }
        return signature
    }
}
