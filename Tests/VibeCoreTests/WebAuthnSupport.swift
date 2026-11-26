import Foundation
@testable import VibeCore

/// What the WebAuthn suites share: hex, the vectors' document read, and assertions built by hand (a P-256 key of the
/// test's own signs whatever bytes a case needs, so each case is refused for its one difference, never for a
/// signature that stopped matching).
enum WebAuthnSupport {
    static func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    /// The refusal `body` throws, or nil when it passes.
    static func refusal(_ body: () throws -> Void) -> WebAuthnRefusal? {
        do { try body() } catch { return (error as! WebAuthnRefusal) }
        return nil
    }

    // MARK: The vectors (Tests/VibeCoreTests/WebAuthnVectors.swift, scripts/e2e/webauthn-vectors.cjs)

    static let document: [String: Any] = try! JSONSerialization.jsonObject(with: Data(WebAuthnVectors.json.utf8)) as! [String: Any]
    static var assertions: [[String: Any]] { document["assertions"] as! [[String: Any]] }
    static var registrations: [[String: Any]] { document["registrations"] as! [[String: Any]] }

    static func place(_ name: Any?) -> WebAuthnPlace { WebAuthnPlace(rawValue: name as! String)! }

    static func listener(_ vector: [String: Any]) -> WebAuthnListener {
        let listener = vector["listener"] as! [String: Any]
        return WebAuthnListener(origin: listener["origin"] as! String, rpId: listener["rpId"] as! String,
                                place: place(listener["place"]))
    }

    /// The device record of an assertion vector: its key read from Chrome's own `getPublicKey()` SPKI, not from the
    /// registration check.
    static func device(_ vector: [String: Any]) -> WebAuthnAssertion.Device {
        let device = vector["device"] as! [String: Any]
        return WebAuthnAssertion.Device(
            credentialId: bytes(device["credentialId"] as! String),
            publicKey: try! P256.Signing.PublicKey(derRepresentation: bytes(device["spki"] as! String)),
            origin: device["origin"] as! String, rpId: device["rpId"] as! String, place: place(device["place"]),
            signCount: UInt32(device["signCount"] as! Int), backupEligible: device["backupEligible"] as! Bool)
    }

    static func response(_ vector: [String: Any]) -> WebAuthnAssertion.Response {
        WebAuthnAssertion.Response(credentialId: bytes(vector["rawId"] as! String),
                                   clientDataJSON: bytes(vector["clientDataJSON"] as! String),
                                   authenticatorData: bytes(vector["authenticatorData"] as! String),
                                   signature: bytes(vector["signature"] as! String))
    }

    /// An assertion vector's outcome: "ok", or the refusal's name.
    static func outcome(of vector: [String: Any]) -> String {
        let result = refusal {
            _ = try WebAuthnAssertion.check(response(vector), challenge: bytes(vector["challenge"] as! String),
                                            listener: listener(vector), device: device(vector))
        }
        return result.map { "\($0)" } ?? "ok"
    }

    // MARK: Assertions by hand

    static let loopback = WebAuthnListener(origin: "http://localhost:47830", rpId: "localhost", place: .loopback)
    static let tailnet = WebAuthnListener(origin: "https://node.tail1234.ts.net:47830", rpId: "node.tail1234.ts.net",
                                          place: .tailnet)

    /// `{"type":…,"challenge":…,"origin":…,"crossOrigin":false}`, as a browser serializes it, with `tail` in place of
    /// the closing `}` when given.
    static func clientData(type: String = "webauthn.get", challenge: Data, origin: String, tail: String = "}") -> Data {
        Data(#"{"type":"\#(type)","challenge":"\#(Base64URL.encode(challenge))","origin":"\#(origin)","crossOrigin":false"#.utf8)
            + Data(tail.utf8)
    }

    /// rpIdHash, flags and the sign count: an assertion's authenticator data.
    static func authenticatorData(rpId: String = "localhost", flags: UInt8 = 0x05, signCount: UInt32 = 1) -> Data {
        Data(SHA256.hash(data: Data(rpId.utf8))) + Data([flags]) + withUnsafeBytes(of: signCount.bigEndian) { Data($0) }
    }

    /// One valid assertion for `listener` and its device, every part replaceable; `sign` re-signs the parts as they
    /// are now.
    struct Made {
        var key = P256.Signing.PrivateKey()
        var listener: WebAuthnListener
        var challenge = Data((0..<32).map { UInt8($0) })
        var credentialId = Data((0..<32).map { UInt8(0xA0 ^ $0) })
        var clientDataJSON: Data
        var authenticatorData: Data
        var signature = Data()
        var storedSignCount: UInt32 = 0
        var backupEligible = false
        var deviceOrigin: String
        var deviceRpId: String
        var devicePlace: WebAuthnPlace

        init(listener: WebAuthnListener = WebAuthnSupport.loopback) {
            self.listener = listener
            clientDataJSON = WebAuthnSupport.clientData(challenge: challenge, origin: listener.origin)
            authenticatorData = WebAuthnSupport.authenticatorData(rpId: listener.rpId)
            deviceOrigin = listener.origin
            deviceRpId = listener.rpId
            devicePlace = listener.place
            sign()
        }

        mutating func sign() {
            signature = try! key.signature(for: authenticatorData + Data(SHA256.hash(data: clientDataJSON))).derRepresentation
        }

        /// The same with `change` applied, then signed again.
        func with(_ change: (inout Made) -> Void) -> Made {
            var made = self
            change(&made)
            made.sign()
            return made
        }

        var device: WebAuthnAssertion.Device {
            WebAuthnAssertion.Device(credentialId: credentialId, publicKey: key.publicKey, origin: deviceOrigin,
                                     rpId: deviceRpId, place: devicePlace, signCount: storedSignCount,
                                     backupEligible: backupEligible)
        }

        var response: WebAuthnAssertion.Response {
            WebAuthnAssertion.Response(credentialId: credentialId, clientDataJSON: clientDataJSON,
                                       authenticatorData: authenticatorData, signature: signature)
        }

        func check() throws(WebAuthnRefusal) -> WebAuthnAssertion.Verified {
            try WebAuthnAssertion.check(response, challenge: challenge, listener: listener, device: device)
        }

        /// The refusal, or nil when it passes.
        var refusal: WebAuthnRefusal? { WebAuthnSupport.refusal { _ = try check() } }
    }
}
