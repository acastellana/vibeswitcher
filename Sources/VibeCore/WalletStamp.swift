import CryptoKit
import Foundation

/// The session host's stamp on a filed wallet request: the session the filing process runs in, as the host tells from
/// that process (never what the request or the process says), and the host's seal over that session and the request's
/// exact bytes, under a key only the host's vault holds. `vs-wallet request` files it beside the request
/// (`<id>.seal`); the app shows a card only for a request whose stamp the host confirms (`LeadVault.verifyWallet`),
/// for the session the request names. So a request written by hand into the folder, or rewritten after filing, or one
/// naming any session but the filer's own, gets no card. The host seals only for a session of the user's: not one
/// another session started, or typed into last (that one could steer it to ask).
public struct WalletStamp: Codable, Equatable, Sendable {
    /// The filing process's session id, lower case.
    public var session: String
    /// SHA-256 of the request file's bytes, lower-case hex.
    public var digest: String
    /// The host's HMAC over both, lower-case hex.
    public var seal: String

    public init(session: String, digest: String, seal: String) {
        self.session = session
        self.digest = digest
        self.seal = seal
    }

    /// SHA-256 of `bytes`, lower-case hex.
    public static func digest(_ bytes: Data) -> String { hex(Data(SHA256.hash(data: bytes))) }

    /// Whether `text` is a digest as `digest` writes it.
    static func isDigest(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    /// The seal over `session` and `digest` under the vault's `senderKey`: an HMAC under a key of its own, derived
    /// from it, so no seal of a steered message is ever one of a wallet request.
    static func seal(session: String, digest: String, senderKey: Data) -> String {
        hex(Data(HMAC<SHA256>.authenticationCode(for: message(session: session, digest: digest), using: key(senderKey))))
    }

    /// Whether `stamp`'s seal is the one `seal(session:digest:senderKey:)` makes (compared in constant time).
    static func isValid(_ stamp: WalletStamp, senderKey: Data) -> Bool {
        guard stamp.seal.utf8.count == 64, let code = bytes(stamp.seal) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: message(session: stamp.session, digest: stamp.digest),
                                                      using: key(senderKey))
    }

    private static func key(_ senderKey: Data) -> SymmetricKey {
        SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data("vibeswitcher-wallet-request-stamp-key".utf8),
                                                                using: SymmetricKey(data: senderKey))))
    }

    private static func message(session: String, digest: String) -> Data {
        Data("vibeswitcher-wallet-request-v1\0\(session.lowercased())\0\(digest)".utf8)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// `hex`'s bytes: lower- or upper-case ASCII hex digits, two to a byte; nil for anything else (an agent writes the
    /// seal, so it's read as UTF-8 bytes, never stepped through as Characters).
    private static func bytes(_ hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        func value(_ digit: UInt8) -> UInt8? {
            switch digit {
            case 48...57: return digit - 48
            case 97...102: return digit - 87
            case 65...70: return digit - 55
            default: return nil
            }
        }
        var data = Data(capacity: digits.count / 2)
        for at in stride(from: 0, to: digits.count, by: 2) {
            guard let high = value(digits[at]), let low = value(digits[at + 1]) else { return nil }
            data.append(high << 4 | low)
        }
        return data
    }
}
