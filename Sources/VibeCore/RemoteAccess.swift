import CryptoKit
import Foundation

/// A phone allowed to use Phone Access. Only a hash of its token is kept.
public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var tokenHash: String
    /// The Tailscale account it paired from; every request must come from the same account.
    public var tailscaleLogin: String
    public var pairedAt: Date
    public var lastSeen: Date?
    public var push: WebPush.Subscription?

    public init(id: String, name: String, tokenHash: String, tailscaleLogin: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.tailscaleLogin = tailscaleLogin
        self.pairedAt = pairedAt
    }
}

/// A short code shown on the Mac and typed (or scanned) on the phone. Single use, expires after
/// 10 minutes, and dies after 5 wrong guesses (40 bits of entropy, so guessing is hopeless anyway).
public struct PairingCode: Equatable, Sendable {
    /// No 0/O, 1/I: easy to read off the screen and type.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    public static let lifetime: TimeInterval = 10 * 60
    public static let maxAttempts = 5

    public let code: String
    public let expires: Date
    public private(set) var attempts = 0

    public init(code: String, expires: Date) {
        self.code = code
        self.expires = expires
    }

    public static func generate(now: Date = Date()) -> PairingCode {
        let bytes = WebPush.randomBytes(8)
        let code = String(bytes.map { alphabet[Int($0) % alphabet.count] })   // 256 % 32 == 0: unbiased
        return PairingCode(code: code, expires: now.addingTimeInterval(lifetime))
    }

    public var isUsable: Bool { attempts < Self.maxAttempts }

    /// Counts the attempt; true if `candidate` matches (case, spaces and dashes don't matter).
    public mutating func check(_ candidate: String, now: Date = Date()) -> Bool {
        guard isUsable, now < expires else { return false }
        attempts += 1
        let normalized = candidate.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        return RemoteAuth.constantTimeEquals(normalized, code)
    }
}

public enum RemoteAuth {
    /// 256-bit bearer token for a newly paired device, base64url.
    public static func newToken() -> String { Base64URL.encode(WebPush.randomBytes(32)) }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The device a request belongs to: a known token, from the Tailscale account that paired it.
    /// `login` is the `Tailscale-User-Login` header, which only `tailscale serve` sets.
    public static func authenticate(authorization: String?, login: String?, devices: [PairedDevice]) -> PairedDevice? {
        guard let login, !login.isEmpty, let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let presented = hash(String(authorization.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces))
        return devices.first { constantTimeEquals($0.tokenHash, presented) && $0.tailscaleLogin == login }
    }
}

/// Minimal HTTP/1.1 request parsing for the loopback server that `tailscale serve` proxies to.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public enum HTTPParser {
    public enum Result: Equatable {
        case incomplete
        case invalid
        case tooLarge
        case complete(HTTPRequest)
    }

    public static func parse(_ data: Data, maxHeaderBytes: Int = 16 * 1024, maxBodyBytes: Int = 64 * 1024) -> Result {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .tooLarge : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes,
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return end.lowerBound > maxHeaderBytes ? .tooLarge : .invalid
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
              ["GET", "POST", "DELETE", "HEAD"].contains(String(requestLine[0])),
              let components = URLComponents(string: String(requestLine[1])), requestLine[1].hasPrefix("/")
        else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .invalid }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // No chunked uploads: the web app only sends small JSON bodies with a length.
        if headers["transfer-encoding"] != nil { return .invalid }
        let length = headers["content-length"].map { Int($0) } ?? 0
        guard let length, length >= 0 else { return .invalid }
        guard length <= maxBodyBytes else { return .tooLarge }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: String(requestLine[0]), path: components.path, query: query,
                                     headers: headers, body: Data(body)))
    }
}
