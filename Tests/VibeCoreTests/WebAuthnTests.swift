import Foundation
import Testing
@testable import VibeCore

/// The checks against what a real browser engine made: headless Chrome's virtual authenticator, through
/// scripts/e2e/webauthn-vectors.cjs (Tests/VibeCoreTests/WebAuthnVectors.swift). Every vector passes or is refused
/// exactly as it is labelled.
struct WebAuthnTests {
    @Test func everyRealAssertionHasItsLabelledOutcome() {
        let vectors = WebAuthnSupport.assertions
        #expect(vectors.count >= 14)
        for vector in vectors {
            #expect(WebAuthnSupport.outcome(of: vector) == vector["expect"] as! String, "\(vector["label"]!)")
        }
    }

    /// The design's C11 row: a dev server on another port of localhost asks the same rpId's passkey; its assertion
    /// names its own origin.
    @Test func anAssertionFromAnotherPortIsRefused() {
        let vector = WebAuthnSupport.assertions.first { $0["label"] as? String == "another-port" }!
        #expect((vector["listener"] as! [String: Any])["origin"] as! String != (Self.clientData(vector)["origin"] as! String))
        #expect(WebAuthnSupport.outcome(of: vector) == "clientDataOrigin")
        // On its own port's listener (a device enrolled there) the same bytes pass: only the origin refused them.
        var own = vector
        own["listener"] = ["origin": Self.clientData(vector)["origin"]!, "rpId": "localhost", "place": "loopback"]
        own["device"] = (vector["device"] as! [String: Any]).merging(["origin": Self.clientData(vector)["origin"]!]) { $1 }
        #expect(WebAuthnSupport.outcome(of: own) == "ok")
    }

    /// Each vector's signature checks under Chrome's own reading of its key (`getPublicKey()`), so a refusal is the
    /// check's and not a broken vector; `wrong-type` alone carries another ceremony's client data.
    @Test func everyRealAssertionIsGenuine() throws {
        for vector in WebAuthnSupport.assertions where vector["label"] as? String != "wrong-type" {
            let device = WebAuthnSupport.device(vector), response = WebAuthnSupport.response(vector)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: response.signature)
            #expect(device.publicKey.isValidSignature(signature, for: response.authenticatorData + Data(SHA256.hash(data: response.clientDataJSON))),
                    "\(vector["label"]!)")
        }
    }

    /// What the vectors cover: ES256 with UV on a discoverable credential (with and without allowCredentials, its
    /// user handle returned), and each refusal the contract names.
    @Test func theVectorsCoverTheCases() {
        let labels = Set(WebAuthnSupport.assertions.map { $0["label"] as! String })
        for label in ["es256-uv-allowed", "es256-uv-discoverable", "no-uv", "another-rpid", "another-port", "cross-origin-frame",
                      "wrong-type", "stale-sign-count", "repeated-sign-count", "another-challenge", "another-port-device-enrolled-there"] {
            #expect(labels.contains(label), "\(label)")
        }
        #expect(WebAuthnSupport.document["residentCredentials"] as? Int == 1)
        let discoverable = WebAuthnSupport.assertions.first { $0["label"] as? String == "es256-uv-discoverable" }!
        #expect(discoverable["userHandle"] is String)
    }

    /// Chrome adds a member after the four checked ones to about one ceremony in six (`other_keys_can_be_added_here`):
    /// those assertions pass, as the spec's limited verification means them to.
    @Test func chromesExtraMemberPasses() {
        let shaped = WebAuthnSupport.assertions.filter { ($0["shape"] as? String)?.contains("other_keys_can_be_added_here") == true }
        #expect(!shaped.isEmpty)
        for vector in shaped { #expect(WebAuthnSupport.outcome(of: vector) == "ok") }
        let shapes = WebAuthnSupport.document["shapes"] as! [[String: Any]]
        #expect(shapes.contains { ($0["shape"] as! String).contains("other_keys_can_be_added_here") })
    }

    @Test func everyRealRegistrationHasItsLabelledOutcome() {
        let vectors = WebAuthnSupport.registrations
        #expect(vectors.count >= 9)
        for vector in vectors {
            #expect(WebAuthnSupport.outcome(ofRegistration: vector) == vector["expect"] as! String, "\(vector["label"]!)")
        }
        // RS256 and EdDSA as Chrome made them: refused at the key.
        let algorithms = Set(vectors.filter { $0["expect"] as? String == "coseKey" }.map { $0["alg"] as! Int })
        #expect(algorithms == [-257, -8])
    }

    /// A registration the check takes yields Chrome's own key (`getPublicKey()`) and the credential's id, and the
    /// device record made from it takes that credential's assertions: registration, then unlock, end to end.
    @Test func aRealRegistrationsKeyIsChromesAndItsAssertionsPass() throws {
        let passed = WebAuthnSupport.registrations.filter { $0["expect"] as? String == "ok" }
        #expect(passed.count >= 2)
        for vector in passed {
            let verified = try WebAuthnSupport.registration(vector).get()
            let chrome = try P256.Signing.PublicKey(derRepresentation: WebAuthnSupport.bytes(vector["spki"] as! String))
            #expect(verified.publicKey.x963Representation == chrome.x963Representation)
            #expect(verified.credentialId == WebAuthnSupport.bytes(vector["rawId"] as! String))
            #expect(verified.coseKey.count == 77 && verified.signCount <= 1 && !verified.backupEligible)
        }
        let main = try WebAuthnSupport.registration(passed.first { $0["label"] as? String == "es256-uv-discoverable" }!).get()
        for label in ["es256-uv-allowed", "es256-uv-discoverable"] {
            let vector = WebAuthnSupport.assertions.first { $0["label"] as? String == label }!
            let stored = WebAuthnSupport.device(vector)
            let device = WebAuthnAssertion.Device(credentialId: main.credentialId, publicKey: main.publicKey, origin: stored.origin,
                                                  rpId: stored.rpId, place: stored.place, signCount: stored.signCount,
                                                  backupEligible: main.backupEligible)
            let verified = try WebAuthnAssertion.check(WebAuthnSupport.response(vector), challenge: WebAuthnSupport.bytes(vector["challenge"] as! String),
                                                       listener: WebAuthnSupport.listener(vector), device: device)
            #expect(verified.signCount == UInt32(vector["signCount"] as! Int))
        }
    }

    static func clientData(_ vector: [String: Any]) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: WebAuthnSupport.bytes(vector["clientDataJSON"] as! String)) as! [String: Any]
    }
}
