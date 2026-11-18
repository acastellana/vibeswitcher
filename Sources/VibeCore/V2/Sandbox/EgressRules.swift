import Foundation

/// Which hosts a confined session's egress proxy lets it reach (the session sandbox plan's SB9, its Network section),
/// and what no list does. Pure: names and addresses in, a decision out.
///
/// A request names a host and a port. The name is judged first, before anything resolves it (`admits`): it must be a
/// name (an address literal, in any of the forms a resolver reads as one, is refused), not one of the names no list
/// opens (`neverNames`: loopback's, the tailnet's, mDNS's, the private-use and reverse-lookup zones), and on the list,
/// at its port (443 unless the entry names another). Only then does the proxy resolve it, and judge every address it
/// got (`decision`): any address in a range no list opens (`neverRanges`: this network, loopback, the tailnet, link-local
/// and cloud metadata, multicast and the reserved blocks, and the IPv6 forms that carry such an IPv4 address) refuses
/// the request, and so does a private address (`privateRanges`) unless the project named the host in
/// `privateHosts`. The proxy then connects to the addresses judged here, never resolving the name again.
///
/// An entry is `name`, `name:port`, `*.name` or `*.name:port`. `*.name` covers every name below `name`, never `name`
/// itself. An entry that isn't one of those matches nothing.
public struct EgressRules: Codable, Equatable, Sendable {
    /// The entries a session may reach.
    public var hosts: [String]
    /// The entries (of `hosts`' form; their ports aren't read) whose private addresses the project has allowed.
    public var privateHosts: [String]

    public init(hosts: [String], privateHosts: [String] = []) {
        self.hosts = hosts
        self.privateHosts = privateHosts
    }

    /// The default list per agent: SB-D7 waits for the user, and this is its recommended value, kept as data so it
    /// changes in one place. For Claude Code: its API host; `platform.claude.com`, where it takes a new token (SB0's
    /// third gated run), and `mcp-proxy.anthropic.com`, the account's claude.ai connectors (SB0's second), both the
    /// lead's decision of 2026-11-18 (SB-D24); and `console.anthropic.com`, listed for the login before the runs and
    /// asked for by none of them. Telemetry and updates are off in a box (`DISABLE_AUTOUPDATER`, SB2), so neither of
    /// theirs is here. SB10's gated run settles the list with the user.
    public static let defaultHosts: [Agent: [String]] = [
        .claude: ["api.anthropic.com", "platform.claude.com", "mcp-proxy.anthropic.com", "console.anthropic.com"],
        .codex: [],
    ]

    /// A session's rules from its role and its project's guarded keys (`SandboxPolicy`, the plan's Network table):
    /// - a worker: its agent's default hosts and the project's `sandbox_hosts`;
    /// - a verifier's agent and the lead: their agent's default hosts only;
    /// - a branch run: the project's `sandbox_run_hosts`, and no agent's.
    /// A host the project named is the project's word for a private address too (`privateHosts`); a default host
    /// never is.
    public static func session(role: SandboxRole, policy: SandboxPolicy, agent: Agent?) -> EgressRules {
        let defaults = agent.flatMap { defaultHosts[$0] } ?? []
        switch role {
        case .worker: return EgressRules(hosts: defaults + policy.hosts, privateHosts: policy.hosts)
        case .verifier, .lead: return EgressRules(hosts: defaults)
        case .branchRun: return EgressRules(hosts: policy.runHosts, privateHosts: policy.runHosts)
        }
    }

    /// An address: its bytes in network order, 4 for IPv4 and 16 for IPv6.
    public struct Address: Hashable, Codable, Sendable, CustomStringConvertible {
        public var bytes: [UInt8]
        public init(_ bytes: [UInt8]) { self.bytes = bytes }

        /// The address of `text` in dotted IPv4 or IPv6 notation (no zone, no brackets); nil for anything else.
        public init?(_ text: String) {
            if let four = Self.ipv4(text) { bytes = four; return }
            if let six = Self.ipv6(text) { bytes = six; return }
            return nil
        }

        public var isIPv4: Bool { bytes.count == 4 }

        public var description: String {
            if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
            guard bytes.count == 16 else { return "?" }
            return stride(from: 0, to: 16, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }.joined(separator: ":")
        }

        static func ipv4(_ text: String) -> [UInt8]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var bytes: [UInt8] = []
            for part in parts {
                guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let value = UInt8(part) else { return nil }
                bytes.append(value)
            }
            return bytes
        }

        static func ipv6(_ text: String) -> [UInt8]? {
            guard text.contains(":"), text.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
            let halves = text.components(separatedBy: "::")
            guard halves.count <= 2 else { return nil }
            func groups(_ part: String) -> [UInt16]? {
                guard !part.isEmpty else { return [] }
                var found: [UInt16] = []
                let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
                for (index, piece) in pieces.enumerated() {
                    if index == pieces.count - 1, piece.contains("."), let four = ipv4(String(piece)) {
                        found += [UInt16(four[0]) << 8 | UInt16(four[1]), UInt16(four[2]) << 8 | UInt16(four[3])]
                    } else {
                        guard !piece.isEmpty, piece.count <= 4, let value = UInt16(piece, radix: 16) else { return nil }
                        found.append(value)
                    }
                }
                return found
            }
            guard let head = groups(halves[0]) else { return nil }
            var all = head
            if halves.count == 2 {
                guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return nil }
                all += [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail
            }
            guard all.count == 8 else { return nil }
            return all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
        }
    }

    /// A block of addresses: its first address and the length of its prefix.
    public struct Range: Sendable, CustomStringConvertible {
        public var base: [UInt8]
        public var prefix: Int
        public var why: String

        public init(_ text: String, _ why: String) {
            let parts = text.split(separator: "/")
            base = Address(String(parts[0]))!.bytes
            prefix = Int(parts[1])!
            self.why = why
        }

        public func contains(_ address: [UInt8]) -> Bool {
            guard address.count == base.count else { return false }
            var left = prefix
            for index in 0..<base.count where left > 0 {
                let bits = min(8, left)
                let mask = UInt8(truncatingIfNeeded: 0xff << (8 - bits))
                if address[index] & mask != base[index] & mask { return false }
                left -= bits
            }
            return true
        }

        public var description: String { "\(Address(base))/\(prefix)" }
    }

    /// The ranges no list opens, whatever it says.
    public static let neverRanges: [Range] = [
        Range("0.0.0.0/8", "this network"),
        Range("127.0.0.0/8", "loopback, which under mirrored networking is also the Windows side"),
        Range("100.64.0.0/10", "the tailnet (and carrier-grade NAT)"),
        Range("169.254.0.0/16", "link-local, where cloud metadata answers"),
        Range("192.0.0.0/24", "the IETF's protocol assignments"),
        Range("224.0.0.0/4", "multicast"),
        Range("240.0.0.0/4", "reserved, and broadcast"),
        Range("::/128", "the unspecified address"),
        Range("::1/128", "loopback"),
        Range("::/96", "IPv4-compatible"),
        Range("fe80::/10", "link-local"),
        Range("fec0::/10", "site-local"),
        Range("ff00::/8", "multicast"),
        Range("fd7a:115c:a1e0::/48", "the tailnet"),
        Range("fd00:ec2::254/128", "cloud metadata"),
        Range("2001::/32", "Teredo"),
        Range("64:ff9b:1::/48", "local-use NAT64, whose IPv4 address can't be read without its prefix's length"),
    ]

    /// The ranges only the project's word opens (`privateHosts`).
    public static let privateRanges: [Range] = [
        Range("10.0.0.0/8", "a private network"),
        Range("172.16.0.0/12", "a private network"),
        Range("192.168.0.0/16", "a private network"),
        Range("fc00::/7", "a private network"),
    ]

    /// The names no list opens: each name itself and every name below it.
    public static let neverNames = ["localhost", "local", "internal", "ts.net", "home.arpa", "arpa", "lan", "intranet",
                                    "metadata.google.internal"]

    /// `neverRanges` and `neverNames` together, as the plan names them.
    public static var neverAllowed: (ranges: [Range], names: [String]) { (neverRanges, neverNames) }

    public enum Decision: Equatable, Sendable {
        /// Connect to these, and only these.
        case allow([Address])
        case refuse(String)
    }

    /// `host` as a name the rules read: lower case, one trailing dot taken off; nil when it isn't a host name (letters,
    /// digits and hyphens in labels of 1 to 63, at most 253 in all, no label starting or ending with a hyphen) or is
    /// one a resolver would read as an address (every label a number, or a last label that is one: `127.1`,
    /// `0x7f.0.0.1`, `2130706433`).
    public static func name(_ host: String) -> String? {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.utf8.count), !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else { return nil }
        }
        if let last = labels.last, isNumber(last) { return nil }
        return name
    }

    /// Whether `label` reads as a number to a resolver: decimal, octal (a leading 0) or hexadecimal (`0x`).
    static func isNumber(_ label: Substring) -> Bool {
        if label.hasPrefix("0x") { return label.dropFirst(2).allSatisfy(\.isHexDigit) }
        return label.allSatisfy(\.isNumber)
    }

    /// An entry read: `*.` or not, its name, and its port (443 when it names none). nil for anything else.
    static func entry(_ text: String) -> (wildcard: Bool, name: String, port: UInt16)? {
        var rest = Substring(text)
        var port: UInt16 = 443
        if let colon = rest.lastIndex(of: ":") {
            guard let given = UInt16(rest[rest.index(after: colon)...]), given > 0 else { return nil }
            port = given
            rest = rest[..<colon]
        }
        let wildcard = rest.hasPrefix("*.")
        if wildcard { rest = rest.dropFirst(2) }
        guard let name = name(String(rest)), String(rest) == name || String(rest) == name + "." else { return nil }
        return (wildcard, name, port)
    }

    /// Whether `name` (as `name(_:)` gives it) is `under` or below it.
    static func isAtOrBelow(_ name: String, _ under: String) -> Bool { name == under || name.hasSuffix("." + under) }

    /// Whether an entry of `entries` covers `name` (at `port`; any port when nil).
    static func listed(_ name: String, port: UInt16?, in entries: [String]) -> Bool {
        entries.contains { text in
            guard let entry = entry(text), port == nil || entry.port == port else { return false }
            return entry.wildcard ? name.hasSuffix("." + entry.name) : name == entry.name
        }
    }

    /// Why a request for `host` at `port` is refused before anything resolves it; nil when the name may be resolved.
    public func admits(host: String, port: UInt16) -> String? {
        guard let name = Self.name(host) else {
            return Self.Address(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) != nil || host.contains(":")
                ? "\(host) is an address, not a name: only names on the list are reached"
                : "\(host) isn't a host name"
        }
        if let never = Self.neverNames.first(where: { Self.isAtOrBelow(name, $0) }) { return "\(name) is under \(never), which no list opens" }
        guard Self.listed(name, port: port, in: hosts) else {
            return Self.listed(name, port: nil, in: hosts) ? "\(name) is listed, but not at port \(port)" : "\(name) isn't on this session's list"
        }
        return nil
    }

    /// The decision for `host` at `port`, which resolved to `resolved`. See the type's comment.
    public func decision(host: String, port: UInt16, resolved: [Address]) -> Decision {
        if let why = admits(host: host, port: port) { return .refuse(why) }
        let name = Self.name(host)!
        guard !resolved.isEmpty else { return .refuse("\(name) doesn't resolve") }
        for address in resolved {
            if let range = Self.never(address) { return .refuse("\(name) resolves to \(address), \(range.why), which no list opens") }
            if let range = Self.privateRange(address), !Self.listed(name, port: nil, in: privateHosts) {
                return .refuse("\(name) resolves to \(address), \(range.why), which only the project's word opens")
            }
        }
        return .allow(resolved)
    }

    /// The IPv4 address an IPv6 one carries, where it carries one a router would reach: IPv4-mapped (`::ffff:0:0/96`),
    /// SIIT's IPv4-translated (`::ffff:0:0:0/96`), NAT64's well-known prefix (`64:ff9b::/96`) and 6to4 (`2002::/16`).
    /// Local-use NAT64 (`64:ff9b:1::/48`) isn't read: its operator picks the prefix's length (RFC 6052: /32 to /96), so
    /// where the IPv4 address sits can't be known here, and the whole block is refused (`neverRanges`).
    static func carried(_ address: Address) -> Address? {
        let bytes = address.bytes
        guard bytes.count == 16 else { return nil }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff { return Address(Array(bytes[12..<16])) }
        if bytes[0..<8].allSatisfy({ $0 == 0 }), bytes[8] == 0xff, bytes[9] == 0xff, bytes[10] == 0, bytes[11] == 0 {
            return Address(Array(bytes[12..<16]))
        }
        if bytes[0..<12] == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] { return Address(Array(bytes[12..<16])) }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return Address(Array(bytes[2..<6])) }
        return nil
    }

    /// The never-opened range `address` is in (or the address it carries is in); nil when none.
    static func never(_ address: Address) -> Range? {
        if let inside = carried(address) { return never(inside) }
        if let range = neverRanges.first(where: { $0.contains(address.bytes) }) { return range }
        // IPv6 is refused by default outside global unicast, so a special range no one listed never slips through;
        // the private one (`fc00::/7`) stays the project's to open.
        if address.bytes.count == 16, !globalUnicast.contains(address.bytes), privateRange(address) == nil { return outsideGlobal }
        return nil
    }

    /// IPv6's global unicast block, the only one a session reaches without the project's word.
    static let globalUnicast = Range("2000::/3", "global unicast")
    static let outsideGlobal = Range("::/0", "outside IPv6's global unicast (2000::/3)")

    /// The private range `address` is in (or the address it carries is in); nil when none.
    static func privateRange(_ address: Address) -> Range? {
        if let inside = carried(address) { return privateRange(inside) }
        return privateRanges.first { $0.contains(address.bytes) }
    }
}
