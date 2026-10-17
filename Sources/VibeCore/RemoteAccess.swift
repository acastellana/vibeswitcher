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

/// Checks on every Phone Access request before the token is looked at.
public enum RemoteGate {
    /// Whether `Host` names this Mac's tailnet address (what `tailscale serve` passes on), optionally with
    /// `port`. A page that rebinds its own name to 127.0.0.1 sends its own name here, so it's refused.
    public static func hostMatches(_ header: String?, host: String, port: Int) -> Bool {
        guard let header = header?.lowercased(), !header.isEmpty, !host.isEmpty else { return false }
        let expected = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var name = Substring(header)
        if let colon = header.lastIndex(of: ":") {
            guard header[header.index(after: colon)...] == "\(port)" else { return false }
            name = header[..<colon]
        }
        if name.hasSuffix(".") { name = name.dropLast() }
        return name == expected
    }

    /// Who a failed attempt is counted against: the account and the tailnet address `tailscale serve`
    /// reports for the device (`X-Forwarded-For`). One noisy source can't throttle anyone else.
    public static func source(login: String?, forwardedFor: String?) -> String {
        let address = forwardedFor?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return "\(login ?? "")|\(address.isEmpty ? "local" : address)"
    }
}

/// Failed token checks per source. A request with a valid token is never throttled (the caller checks
/// the token first), so failures from one place can't lock the paired phones out.
public struct FailureThrottle: Sendable {
    public let limit: Int
    public let window: TimeInterval
    /// Sources kept at most (the oldest go first): rotating sources can't grow this without bound.
    public let maxSources: Int
    private var failures: [String: [Date]] = [:]

    public init(limit: Int = 20, window: TimeInterval = 60, maxSources: Int = 256) {
        self.limit = limit
        self.window = window
        self.maxSources = maxSources
    }

    public func isThrottled(_ source: String, now: Date = Date()) -> Bool {
        (failures[source] ?? []).filter { now.timeIntervalSince($0) < window }.count >= limit
    }

    public mutating func recordFailure(_ source: String, now: Date = Date()) {
        failures = failures.compactMapValues { dates in
            let recent = dates.filter { now.timeIntervalSince($0) < window }
            return recent.isEmpty ? nil : recent
        }
        failures[source, default: []].append(now)
        if failures[source]!.count > limit { failures[source]!.removeFirst(failures[source]!.count - limit) }
        while failures.count > maxSources,
              let oldest = failures.filter({ $0.key != source })
                .min(by: { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) })?.key {
            failures[oldest] = nil
        }
    }
}

/// Whether a reply from the phone may be typed now. Checked when it arrives and again right before each
/// write (a reply to a window session is several writes, a moment apart): the Mac can lock, the phone be
/// removed or replies turned off in between.
public enum RemoteInputGate {
    public enum Verdict: Equatable, Sendable {
        case allowed
        /// The Mac is locked: nothing is typed (423).
        case locked
        /// Phone Access off, replies off, or the phone unpaired.
        case notAllowed
        /// The session ended or another one took its terminal.
        case sessionChanged
    }

    public struct Conditions: Sendable {
        public var screenLocked: Bool
        public var accessOn: Bool
        public var inputAllowed: Bool
        public var devicePaired: Bool
        public var sameSession: Bool

        public init(screenLocked: Bool, accessOn: Bool, inputAllowed: Bool, devicePaired: Bool, sameSession: Bool) {
            self.screenLocked = screenLocked
            self.accessOn = accessOn
            self.inputAllowed = inputAllowed
            self.devicePaired = devicePaired
            self.sameSession = sameSession
        }
    }

    public static func verdict(_ conditions: Conditions) -> Verdict {
        if conditions.screenLocked { return .locked }
        guard conditions.accessOn, conditions.inputAllowed, conditions.devicePaired else { return .notAllowed }
        guard conditions.sameSession else { return .sessionChanged }
        return .allowed
    }

    /// Runs `writes` one after another (`after` waits that long, then runs the block), asking `check`
    /// right before each one. The first verdict that isn't `.allowed` stops it: that write and the ones
    /// after it are dropped, and `stopped` gets the verdict and how many writes went out.
    public static func deliver(_ writes: [HostInput.Write], check: @escaping () -> Verdict,
                               after: @escaping (TimeInterval, @escaping () -> Void) -> Void,
                               send: @escaping ([UInt8]) -> Void,
                               stopped: @escaping (Verdict, _ sent: Int) -> Void = { _, _ in }) {
        func step(_ index: Int) {
            guard index < writes.count else { return }
            after(writes[index].delay) {
                let verdict = check()
                guard verdict == .allowed else { return stopped(verdict, index) }
                send(writes[index].bytes)
                step(index + 1)
            }
        }
        step(0)
    }
}
