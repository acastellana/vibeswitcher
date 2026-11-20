import Foundation
import VibeCore

/// Where the node's page is on the user's tailnet (the remote access note, docs/superpowers/specs/2026-11-20-v2-remote-access.md):
/// this machine's Tailscale IPv4 address, which the tailnet listener binds, and its MagicDNS name, the page's one
/// origin there. Never the address as a name: a phone whose Tailscale is off routes 100.64.0.0/10 to its carrier, and
/// a page bookmarked by address would send its token there; a tailnet's `ts.net` name doesn't resolve without Tailscale.
public struct TailnetPlace: Equatable, Sendable {
    /// The numeric IPv4 address bound: in 100.64.0.0/10, on one of this machine's interfaces.
    public var address: String
    /// The MagicDNS name, lowercase, with no final dot: `<machine>.<tailnet>.ts.net`.
    public var name: String

    public init(address: String, name: String) {
        self.address = address
        self.name = name
    }
}

/// Finding the `TailnetPlace` from `tailscale status --json`. Nothing here changes the network or Tailscale's settings,
/// and nothing installs Tailscale: when it isn't there, or isn't running, the answer says so.
///
/// - **The program.** Only a `tailscale` only root can change, at one of `places` (`Platform.Tools.onlyRootCanChange`,
///   as git is found): a worker's `~/.local/bin/tailscale` could otherwise name another network's address. It is run
///   with `environment` alone and for `patience` seconds at most.
/// - **The answer.** `BackendState` `Running`; MagicDNS on; `Self.DNSName` a `ts.net` name of letters, digits, `-`
///   and `.`; the first IPv4 address of `Self.TailscaleIPs` in Tailscale's range (`Platform.TCP.isTailscaleAddress`);
///   and that address on one of this machine's interfaces now.
public enum Tailnet {
    /// Where a `tailscale` is looked for, in this order: Linux's packages, Homebrew's, the Mac app's.
    public static let places = ["/usr/bin/tailscale", "/usr/sbin/tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                                "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
    /// The environment `tailscale` runs with: nothing inherited.
    public static let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C"]
    /// Seconds `tailscale status --json` has.
    public static let patience: TimeInterval = 5
    /// The longest name taken (DNS's limit).
    static let longestName = 253

    /// Finds the place: a `TailnetPlace`, or why there is none.
    public typealias Finder = @Sendable () -> Result<TailnetPlace, WebTokens.Refusal>

    /// This machine's place, asked of its `tailscale` now. Blocks up to `patience` seconds: never on the engine's queue.
    public static func find() -> Result<TailnetPlace, WebTokens.Refusal> {
        let program: String
        switch self.program(places: places, exists: { FileManager.default.fileExists(atPath: $0) },
                            status: { Platform.Tools.fileStatus($0) }) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let found): program = found
        }
        guard let output = Platform.Tools.output([program, "status", "--json"], timeout: patience, environment: environment) else {
            return .failure(.init("`\(program) status --json` didn't answer within \(Int(patience)) s: is Tailscale running? Start it and log in"))
        }
        return place(statusJSON: Data(output.utf8), interfaces: Platform.TCP.interfaceAddresses())
    }

    /// The first of `places` that exists and only root can change. None exists: Tailscale isn't installed. One exists
    /// that a process of the user's could change: refused, naming it.
    static func program(places: [String], exists: (String) -> Bool, status: (String) -> Platform.Tools.FileStatus?) -> Result<String, WebTokens.Refusal> {
        let present = places.filter(exists)
        if let trusted = present.first(where: { Platform.Tools.onlyRootCanChange($0, status: status) }) { return .success(trusted) }
        guard let first = present.first else {
            return .failure(.init("Tailscale isn't installed here (no `tailscale` at \(places.joined(separator: ", "))): VibeSwitcher doesn't install it; install it and log in, then run this again"))
        }
        return .failure(.init("\(first) is a link, or a process of yours could change it: only a `tailscale` that only root can change, in folders only root can change, is run"))
    }

    /// The place `tailscale status --json` names, when `interfaces` (this machine's addresses) hold its address.
    static func place(statusJSON: Data, interfaces: [String]) -> Result<TailnetPlace, WebTokens.Refusal> {
        guard let status = (try? JSONSerialization.jsonObject(with: statusJSON)) as? [String: Any] else {
            return .failure(.init("`tailscale status --json` gave no status this build can read"))
        }
        let state = status["BackendState"] as? String ?? "unknown"
        guard state == "Running" else {
            return .failure(.init("Tailscale isn't connected (its state: \(ConfigSeal.inert(state, limit: 40))): open Tailscale and log in"))
        }
        guard let own = status["Self"] as? [String: Any] else { return .failure(.init("`tailscale status --json` names no device for this machine")) }
        let tailnet = status["CurrentTailnet"] as? [String: Any]
        guard tailnet?["MagicDNSEnabled"] as? Bool == true else {
            return .failure(.init("MagicDNS is off on this tailnet: the page is reached only by this machine's tailnet name, never its address (a phone with Tailscale off would send its token to the carrier's network); turn MagicDNS on in Tailscale's admin console › DNS"))
        }
        guard let name = Self.name(own["DNSName"] as? String) else {
            return .failure(.init("Tailscale gives this machine no MagicDNS name (`*.ts.net`)"))
        }
        let addresses = own["TailscaleIPs"] as? [String] ?? []
        guard let address = addresses.first(where: { $0.contains(".") && Platform.TCP.isTailscaleAddress($0) }) else {
            return .failure(.init("Tailscale gives this machine no IPv4 address in 100.64.0.0/10"))
        }
        guard interfaces.contains(address) else {
            return .failure(.init("\(address), this machine's Tailscale address, is on none of its interfaces: is Tailscale up here?"))
        }
        return .success(TailnetPlace(address: address, name: name))
    }

    /// A MagicDNS name as the page's origin takes it: lowercase, its final dot dropped, ending `.ts.net`, labels of
    /// letters, digits and `-` only. Nil for anything else.
    public static func name(_ given: String?) -> String? {
        guard var name = given?.lowercased() else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        guard name.utf8.count <= longestName, name.hasSuffix(".ts.net") else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }) else { return nil }
        return name
    }
}
