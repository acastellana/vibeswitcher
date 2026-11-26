import Foundation
import Testing
@testable import VibeCore

/// A few thousand seeded mutations of a valid assertion and a valid registration, both Chrome's (the vectors): none
/// crashes, and none passes, except what attestation `none` leaves unsigned in a registration.
///
/// An assertion is signed over everything the check reads, so every mutation must be refused. A registration's
/// attestation object is signed by nothing (attestation `none`), so changing its AAGUID, sign count, BE and BS flags or
/// reserved flag bits or credential id's bytes is another valid registration, not a forgery: such a mutation may pass, and then the result
/// must say exactly what the mutated bytes say. Anything else that passes is a failure.
struct WebAuthnFuzzTests {
    /// SplitMix64: the same mutations on every run and system.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// One mutation of `bytes`: a bit flipped, a byte set, a byte inserted, a byte dropped, a cut, a run repeated, or
    /// two bytes swapped. Each keeps its kind's chance of reaching the deep checks (half keep the length).
    static func mutate(_ bytes: Data, _ random: inout Seeded) -> Data {
        var data = [UInt8](bytes)
        let at = data.isEmpty ? 0 : Int.random(in: 0..<data.count, using: &random)
        switch Int.random(in: 0..<8, using: &random) {
        case 0, 1, 2: if !data.isEmpty { data[at] ^= 1 << UInt8.random(in: 0..<8, using: &random) }
        case 3: if !data.isEmpty { data[at] = UInt8.random(in: 0...255, using: &random) }
        case 4: data.insert(UInt8.random(in: 0...255, using: &random), at: at)
        case 5: if !data.isEmpty { data.remove(at: at) }
        case 6: data = Array(data[..<at])
        default:
            let length = Int.random(in: 1...8, using: &random)
            let run = data[at..<min(data.count, at + length)]
            data.insert(contentsOf: run, at: at)
        }
        return Data(data)
    }

    @Test func noMutationOfARealAssertionPasses() {
        let vector = WebAuthnSupport.assertions.first { $0["label"] as? String == "es256-uv-allowed" }!
        let listener = WebAuthnSupport.listener(vector), device = WebAuthnSupport.device(vector)
        let challenge = WebAuthnSupport.bytes(vector["challenge"] as! String), valid = WebAuthnSupport.response(vector)
        #expect(WebAuthnSupport.outcome(of: vector) == "ok")
        var random = Seeded(state: 0x5EED_0002)
        var refusals: [String: Int] = [:]
        let rounds = 4000
        for round in 0..<rounds {
            var credentialId = valid.credentialId, clientData = valid.clientDataJSON
            var authenticatorData = valid.authenticatorData, signature = valid.signature
            // One part mutated, sometimes two.
            for _ in 0..<(round % 5 == 0 ? 2 : 1) {
                switch Int.random(in: 0..<10, using: &random) {
                case 0: credentialId = Self.mutate(credentialId, &random)
                case 1, 2, 3: clientData = Self.mutate(clientData, &random)
                case 4, 5, 6: authenticatorData = Self.mutate(authenticatorData, &random)
                default: signature = Self.mutate(signature, &random)
                }
            }
            let response = WebAuthnAssertion.Response(credentialId: credentialId, clientDataJSON: clientData,
                                                      authenticatorData: authenticatorData, signature: signature)
            let unchanged = credentialId == valid.credentialId && clientData == valid.clientDataJSON
                && authenticatorData == valid.authenticatorData && signature == valid.signature
            let refusal = WebAuthnSupport.refusal { _ = try WebAuthnAssertion.check(response, challenge: challenge, listener: listener, device: device) }
            if unchanged { continue }
            #expect(refusal != nil, "round \(round) passed")
            refusals["\(refusal.map { "\($0)" } ?? "passed")", default: 0] += 1
        }
        // The mutations reached the deep checks, the signature's above all.
        #expect((refusals["signature"] ?? 0) > rounds / 10)
        #expect(refusals.keys.count >= 8, "\(refusals)")
    }

    @Test func noMutationOfARealRegistrationPassesUnlessItSaysWhatItsBytesSay() throws {
        let vector = WebAuthnSupport.registrations.first { $0["label"] as? String == "es256-uv-discoverable" }!
        let listener = WebAuthnSupport.registrationListener(vector), valid = WebAuthnSupport.registrationResponse(vector)
        let challenge = WebAuthnSupport.bytes(vector["challenge"] as! String)
        let original = try WebAuthnSupport.registration(vector).get()
        // Where the authenticator data starts inside the object (`{"fmt":"none","attStmt":{},"authData":` and the
        // byte string's two-byte head), and the unsigned places in it: the flags' BE, BS and reserved bits, the sign count, the
        // AAGUID, the credential id's bytes.
        let object = [UInt8](valid.attestationObject)
        let start = 30
        #expect(object[28] == 0x58 && Int(object[29]) == object.count - start)
        // The client data's checked prefix: what follows it is the browser's, read only for its shape.
        let text = String(decoding: valid.clientDataJSON, as: UTF8.self)
        let checked = text.utf8.distance(from: text.startIndex, to: text.range(of: #""crossOrigin":false"#)!.upperBound)
        let idLength = Int(object[start + 53]) << 8 | Int(object[start + 54])
        let unsigned = Set([start + 32]).union((start + 33)..<(start + 53)).union((start + 55)..<(start + 55 + idLength))
        var random = Seeded(state: 0x5EED_0003)
        var refusals: [String: Int] = [:]
        var passedAsAnother = 0
        for round in 0..<4000 {
            var clientData = valid.clientDataJSON, attestation = valid.attestationObject
            for _ in 0..<(round % 5 == 0 ? 2 : 1) {
                if Int.random(in: 0..<10, using: &random) < 3 { clientData = Self.mutate(clientData, &random) }
                else { attestation = Self.mutate(attestation, &random) }
            }
            if clientData == valid.clientDataJSON && attestation == valid.attestationObject { continue }
            let response = WebAuthnRegistration.Response(clientDataJSON: clientData, attestationObject: attestation)
            switch Result(catching: { () throws(WebAuthnRefusal) in try WebAuthnRegistration.check(response, challenge: challenge, listener: listener) }) {
            case .failure(let refusal):
                refusals["\(refusal)", default: 0] += 1
            case .success(let verified):
                // Only a change of the unsigned places, the client data untouched, and the result reading them.
                let mutated = [UInt8](attestation)
                let changed = (0..<object.count).filter { mutated.count == object.count && mutated[$0] != object[$0] }
                #expect(clientData.prefix(checked) == valid.clientDataJSON.prefix(checked) && mutated.count == object.count && unsigned.isSuperset(of: changed),
                        "round \(round) passed with \(changed)")
                #expect(mutated[start + 32] & 0xC5 == object[start + 32] & 0xC5) // only BE, BS and the reserved bits
                #expect(verified.credentialId == Data(mutated[(start + 55)..<(start + 55 + idLength)]))
                #expect(verified.aaguid == Data(mutated[(start + 37)..<(start + 53)]))
                #expect(verified.signCount == UInt32(mutated[start + 33]) << 24 | UInt32(mutated[start + 34]) << 16
                        | UInt32(mutated[start + 35]) << 8 | UInt32(mutated[start + 36]))
                #expect(verified.backupEligible == (mutated[start + 32] & 0x08 != 0) && verified.backupState == (mutated[start + 32] & 0x10 != 0))
                #expect(verified.publicKey.x963Representation == original.publicKey.x963Representation && verified.coseKey == original.coseKey)
                passedAsAnother += 1
            }
        }
        #expect(refusals.keys.count >= 8, "\(refusals)")
        #expect(passedAsAnother < 1000, "\(passedAsAnother)")
    }
}
