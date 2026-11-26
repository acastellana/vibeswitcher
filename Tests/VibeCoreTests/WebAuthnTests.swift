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

    static func clientData(_ vector: [String: Any]) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: WebAuthnSupport.bytes(vector["clientDataJSON"] as! String)) as! [String: Any]
    }
}
