import CryptoKit
import Security
import Foundation

/// Web Push (RFC 8030) messages to the phone: the payload is encrypted end to end for the browser
/// (RFC 8291, `aes128gcm` from RFC 8188), so the push service in between can't read it, and each
/// request is signed with our VAPID key (RFC 8292) so only we can push to our subscriptions.
public enum WebPush {
    public struct Subscription: Codable, Equatable, Sendable {
        public var endpoint: String
        /// The browser's P-256 public key (uncompressed point), base64url.
        public var p256dh: String
        /// 16-byte authentication secret, base64url.
        public var auth: String

        public init(endpoint: String, p256dh: String, auth: String) {
            self.endpoint = endpoint
            self.p256dh = p256dh
            self.auth = auth
        }
    }

    public enum PushError: Error, Equatable {
        case invalidSubscription
        case untrustedEndpoint
    }

    /// Push services we deliver to. A paired device supplies the endpoint URL, so this keeps the Mac
    /// from being pointed at arbitrary hosts.
    static let trustedPushHosts = ["fcm.googleapis.com", "push.services.mozilla.com", "push.apple.com",
                                   "notify.windows.com"]

    public static func validatedEndpoint(_ endpoint: String) throws -> URL {
        guard let url = URL(string: endpoint), url.scheme == "https", let host = url.host?.lowercased(),
              trustedPushHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { throw PushError.untrustedEndpoint }
        return url
    }

    /// Encrypts `plaintext` for the subscription: returns the `aes128gcm` body (header + one record).
    /// `serverKey` and `salt` are random per message; they're parameters for the RFC test vectors.
    public static func encrypt(_ plaintext: Data, for subscription: Subscription,
                               serverKey: P256.KeyAgreement.PrivateKey = .init(),
                               salt: Data = randomBytes(16)) throws -> Data {
        guard let uaPublicBytes = Base64URL.decode(subscription.p256dh),
              let authSecret = Base64URL.decode(subscription.auth), authSecret.count == 16,
              let uaPublic = try? P256.KeyAgreement.PublicKey(x963Representation: uaPublicBytes)
        else { throw PushError.invalidSubscription }
        let asPublic = serverKey.publicKey.x963Representation

        let shared = try serverKey.sharedSecretFromKeyAgreement(with: uaPublic)
        let ecdhSecret = shared.withUnsafeBytes { Data($0) }
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(uaPublicBytes)
        keyInfo.append(asPublic)
        let ikm = hkdf(ecdhSecret, salt: authSecret, info: keyInfo, count: 32)
        let cek = hkdf(ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), count: 16)
        let nonce = hkdf(ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), count: 12)

        var padded = plaintext
        padded.append(2)   // delimiter: last (and only) record
        let sealed = try AES.GCM.seal(padded, using: SymmetricKey(data: cek), nonce: AES.GCM.Nonce(data: nonce))

        var body = salt
        body.append(contentsOf: [0x00, 0x00, 0x10, 0x00])   // record size 4096
        body.append(UInt8(asPublic.count))
        body.append(asPublic)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }

    /// `Authorization` header value for a push request to `endpoint` (a JWT signed with our VAPID key).
    public static func vapidAuthorization(endpoint: URL, key: P256.Signing.PrivateKey, subject: String,
                                          now: Date = Date()) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host else { throw PushError.untrustedEndpoint }
        let audience = endpoint.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        let header = Base64URL.encode(Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8))
        let claims: [String: Any] = ["aud": audience, "exp": Int(now.timeIntervalSince1970) + 12 * 3600, "sub": subject]
        let payload = Base64URL.encode(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let signingInput = "\(header).\(payload)"
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation   // r || s
        return "vapid t=\(signingInput).\(Base64URL.encode(signature)), k=\(Base64URL.encode(key.publicKey.x963Representation))"
    }

    static func hkdf(_ ikm: Data, salt: Data, info: Data, count: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base64 = text.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
