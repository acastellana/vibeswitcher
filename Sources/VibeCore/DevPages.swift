import CryptoKit
import Foundation

/// Where a preview connects to: `connectHost` is what to dial ("localhost" lets the system try ::1 and
/// 127.0.0.1), `hostHeader` is what the browser sent as Host ("localhost:5173").
public struct PreviewTarget: Equatable, Hashable, Sendable {
    public var connectHost: String
    public var hostHeader: String
    public var port: Int

    public init(connectHost: String, hostHeader: String, port: Int) {
        self.connectHost = connectHost
        self.hostHeader = hostHeader
        self.port = port
    }
}

/// A localhost page open in Chrome on the Mac, which the paired phone may open as a preview.
public struct DevPage: Equatable, Sendable {
    public var title: String
    public var url: String
    public var target: PreviewTarget
    /// Path, query and fragment, always starting with exactly one "/".
    public var path: String
}

public enum DevPages {
    /// VibeSwitcher's own local ports (the Phone Access API and the preview slots); never offered.
    public static let reservedPorts: ClosedRange<Int> = Int(PhonePorts.server)...Int(PhonePorts.server) + PhonePorts.previewSlots

    /// The page for a Chrome tab, or nil unless it's plain http on this Mac (localhost, 127.0.0.1, [::1],
    /// *.localhost) on an unprivileged port that isn't ours.
    public static func page(url: String, title: String) -> DevPage? {
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "http",
              components.user == nil, components.password == nil,
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        let connectHost: String
        switch host {
        case "localhost", "127.0.0.1", "::1": connectHost = host
        default:
            guard host.hasSuffix(".localhost") else { return nil }
            connectHost = "localhost"
        }
        let port = components.port ?? 80
        guard (1024...65535).contains(port), !reservedPorts.contains(port) else { return nil }
        let hostHeader = (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?\(query)" }
        if let fragment = components.percentEncodedFragment { path += "#\(fragment)" }
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        return DevPage(title: cleanTitle.isEmpty ? hostHeader : cleanTitle, url: url,
                       target: PreviewTarget(connectHost: connectHost, hostHeader: hostHeader, port: port),
                       path: safePath(path))
    }

    /// Chrome's tabs, filtered, each page once (same server and path), in tab order.
    public static func pages(fromTabs tabs: [(url: String, title: String)]) -> [DevPage] {
        var seen = Set<String>()
        return tabs.compactMap { tab in
            guard let page = page(url: tab.url, title: tab.title),
                  seen.insert(page.target.hostHeader + page.path).inserted else { return nil }
            return page
        }
    }

    /// Opaque, stable id the phone sends back: it never sends a URL, so it can only pick a listed page.
    public static func id(for page: DevPage) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data((page.target.hostHeader + page.path).utf8))).prefix(12))
    }

    /// A same-origin path: "//evil.example" and "/\evil.example" would be protocol-relative in a redirect.
    public static func safePath(_ path: String) -> String {
        "/" + path.drop { $0 == "/" || $0 == "\\" }
    }
}

/// Whether macOS lets this app control another one (Privacy & Security › Automation), from the
/// status `AEDeterminePermissionToAutomateTarget` returns.
public enum AutomationAccess: Equatable, Sendable {
    case allowed
    case denied
    /// macOS hasn't asked yet (only when checking without asking).
    case notAsked
    /// macOS can only answer while the other app is running.
    case appNotRunning
    case unknown(Int32)

    public init(status: Int32) {
        switch status {
        case 0: self = .allowed
        case -1743: self = .denied           // errAEEventNotPermitted
        case -1744: self = .notAsked         // errAEEventWouldRequireUserConsent
        case -600: self = .appNotRunning     // procNotFound
        default: self = .unknown(status)
        }
    }
}

/// Why Chrome's tabs couldn't be read, from the Apple Event error code.
public enum ChromeReadFailure: Error, Equatable, Sendable {
    case notRunning
    case notAllowed
    case failed(String)

    public init(appleEventCode code: Int) {
        switch code {
        case -1743: self = .notAllowed                              // errAEEventNotPermitted
        case -600, -609: self = .notRunning                         // procNotFound, connectionInvalid (Chrome quit mid-read)
        case -1712: self = .failed("Chrome didn't answer in time")  // errAETimeout
        default: self = .failed("Apple Event error \(code)")
        }
    }
}
