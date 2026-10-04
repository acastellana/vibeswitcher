import Foundation

/// An HTTP/1.x message head kept as raw lines (order, case and duplicates preserved), so a proxy can
/// change a few fields and pass everything else through untouched. ISO Latin-1 round-trips every byte.
public struct HTTPHead: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    public enum Kind: Sendable { case request, response }

    public enum ParseResult: Equatable {
        case incomplete
        case invalid
        case tooLarge
        /// `consumed`: bytes of the head including the blank line; what follows is the body.
        case complete(HTTPHead, consumed: Int)
    }

    public var startLine: String
    public var fields: [Field]

    public init(startLine: String, fields: [Field]) {
        self.startLine = startLine
        self.fields = fields
    }

    public static func parse(_ data: Data, kind: Kind, maxBytes: Int = 64 * 1024) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxBytes ? .tooLarge : .incomplete
        }
        let length = end.lowerBound - data.startIndex
        guard length <= maxBytes else { return .tooLarge }
        guard let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .isoLatin1) else { return .invalid }
        var lines = text.components(separatedBy: "\r\n")
        // A lone CR or LF left inside a line could smuggle a second header past the rewriting.
        guard !lines.contains(where: { $0.contains("\r") || $0.contains("\n") }) else { return .invalid }
        let start = lines.removeFirst()
        let parts = start.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        switch kind {
        case .request:
            guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty,
                  parts[0].allSatisfy({ $0.isLetter }), parts[1].hasPrefix("/"),
                  !parts[1].unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) else { return .invalid }
        case .response:
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]),
                  (100...599).contains(code) else { return .invalid }
        }
        var fields: [Field] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else { return .invalid }
            fields.append(Field(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return .complete(HTTPHead(startLine: start, fields: fields), consumed: length + 4)
    }

    public var serialized: Data {
        let lines = [startLine] + fields.map { "\($0.name): \($0.value)" }
        return (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .isoLatin1) ?? Data()
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    public func value(_ name: String) -> String? { fields.first { Self.same($0.name, name) }?.value }
    public func values(_ name: String) -> [String] { fields.filter { Self.same($0.name, name) }.map(\.value) }

    public mutating func remove(_ name: String) { fields.removeAll { Self.same($0.name, name) } }

    /// Replaces the first field of that name (dropping any others), or appends it.
    public mutating func set(_ name: String, _ value: String) {
        guard let index = fields.firstIndex(where: { Self.same($0.name, name) }) else {
            fields.append(Field(name: name, value: value))
            return
        }
        fields[index].value = value
        fields = fields.enumerated().filter { $0.offset <= index || !Self.same($0.element.name, name) }.map(\.element)
    }

    private var startParts: [Substring] { startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false) }
    public var method: String { startParts.first.map(String.init) ?? "" }
    private var target: String { startParts.count > 1 ? String(startParts[1]) : "" }
    public var path: String { String(target.prefix { $0 != "?" }) }
    public var query: [String: String] {
        var query: [String: String] = [:]
        for item in URLComponents(string: target)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return query
    }
    public var status: Int? { startParts.count > 1 ? Int(startParts[1]) : nil }
}

/// Access decisions and header rewriting for one preview slot (see `PreviewProxy`).
public enum PreviewGate {
    public enum Decision: Equatable, Sendable {
        case reject(status: Int, message: String)
        case enter(ticket: String)
        case forward(sessionToken: String)
    }

    public static let enterPath = "/__vibeswitcher/enter"
    public static let wrongAccountMessage = "This page is only for the Tailscale account that runs VibeSwitcher."
    public static let expiredMessage = "This preview has expired. Open it again from VibeSwitcher on your phone."
    public static let crossOriginMessage = "Blocked: another page tried to use this preview."
    public static func unreachableMessage(_ target: PreviewTarget) -> String {
        "\(target.hostHeader) isn't answering. Is the dev server still running?"
    }

    /// Cookies ignore ports, so every slot needs its own cookie name.
    public static func cookieName(publicPort: Int) -> String { "vs_preview_\(publicPort)" }
    public static func setCookie(publicPort: Int, token: String) -> String {
        "\(cookieName(publicPort: publicPort))=\(token); Path=/; Secure; HttpOnly; SameSite=Strict"
    }

    public static func decide(_ head: HTTPHead, owner: String, ownOrigin: String, siblingOrigins: Set<String>,
                              publicPort: Int) -> Decision {
        guard head.value("tailscale-user-login") == owner else { return .reject(status: 403, message: wrongAccountMessage) }
        if let origin = head.value("origin"), origin != ownOrigin, siblingOrigins.contains(origin) {
            return .reject(status: 403, message: crossOriginMessage)
        }
        if head.path == enterPath, let ticket = head.query["t"], !ticket.isEmpty { return .enter(ticket: ticket) }
        // Subresources and frames send no Origin. Another slot's page is another port of the same host, so
        // the browser marks its requests same-site (and attaches every slot's cookie): only the page itself
        // (same-origin) and the user (none) may use this slot's session.
        if let site = head.value("sec-fetch-site")?.lowercased(), site == "same-site" || site == "cross-site" {
            return .reject(status: 403, message: crossOriginMessage)
        }
        guard let token = cookie(cookieName(publicPort: publicPort), in: head) else {
            return .reject(status: 403, message: expiredMessage)
        }
        return .forward(sessionToken: token)
    }

    public static func isUpgrade(_ head: HTTPHead) -> Bool {
        head.value("upgrade") != nil && (head.value("connection") ?? "").lowercased().contains("upgrade")
    }

    /// What the dev server sees: its own Host/Origin (Vite checks them), no Tailscale identity headers,
    /// no VibeSwitcher cookie, and one request per connection so every request is authenticated.
    public static func upstreamRequest(_ head: HTTPHead, target: PreviewTarget, ownOrigin: String,
                                       publicPort: Int) -> HTTPHead {
        var head = head
        // Tailscale's identity headers, and the proxy headers tailscale serve adds: the dev server must see
        // only its own address (Next.js checks Origin against X-Forwarded-Host; Express builds https
        // redirects from X-Forwarded-Proto).
        head.fields.removeAll {
            let name = $0.name.lowercased()
            return name.hasPrefix("tailscale-") || name.hasPrefix("x-forwarded-") || name == "forwarded"
        }
        // Every slot's cookie (cookies ignore ports), not just this one's: none of them is the dev server's.
        let kept = head.values("cookie").flatMap { $0.split(separator: ";") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isSlotCookie($0) }
        head.remove("cookie")
        if !kept.isEmpty { head.set("Cookie", kept.joined(separator: "; ")) }
        head.set("Host", target.hostHeader)
        let local = "http://\(target.hostHeader)"
        if head.value("origin") == ownOrigin { head.set("Origin", local) }
        if let referer = head.value("referer"), referer == ownOrigin || referer.hasPrefix(ownOrigin + "/") {
            head.set("Referer", local + referer.dropFirst(ownOrigin.count))
        }
        if !isUpgrade(head) {
            head.remove("keep-alive")
            head.remove("proxy-connection")
            head.set("Connection", "close")
        }
        return head
    }

    /// What the phone sees: redirects to the dev server's own address become paths, cookies lose a
    /// `Domain=localhost` the phone's browser would reject, and the connection closes after the response.
    public static func clientResponse(_ head: HTTPHead, target: PreviewTarget) -> HTTPHead {
        var head = head
        if let location = head.value("location"), let path = localPath(location, port: target.port) {
            head.set("Location", path)
        }
        // A dev server may not set (or overwrite) a slot's cookie.
        head.fields.removeAll { $0.name.lowercased() == "set-cookie" && isSlotCookie($0.value) }
        for index in head.fields.indices where head.fields[index].name.lowercased() == "set-cookie" {
            head.fields[index].value = head.fields[index].value
                .replacingOccurrences(of: #";\s*[Dd][Oo][Mm][Aa][Ii][Nn]=[^;]*"#, with: "", options: .regularExpression)
        }
        // Interim heads (100 Continue, 103 Early Hints) and upgrades keep their connection.
        if let status = head.status, status >= 200 {
            head.remove("keep-alive")
            head.set("Connection", "close")
        }
        return head
    }

    /// "vs_preview_8444=…" (any slot), whatever the case.
    static func isSlotCookie(_ pair: String) -> Bool {
        pair.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("vs_preview_")
    }

    /// "/login" for "http://localhost:3000/login" (or 127.0.0.1, [::1], *.localhost) on the target's port.
    static func localPath(_ location: String, port: Int) -> String? {
        guard let components = URLComponents(string: location), components.scheme?.lowercased() == "http",
              components.port == port, var host = components.host?.lowercased() else { return nil }
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        guard ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".localhost") else { return nil }
        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?\(query)" }
        if let fragment = components.percentEncodedFragment { path += "#\(fragment)" }
        return DevPages.safePath(path)
    }

    static func cookie(_ name: String, in head: HTTPHead) -> String? {
        for value in head.values("cookie") {
            for pair in value.split(separator: ";") {
                let pair = pair.trimmingCharacters(in: .whitespaces)
                if pair.hasPrefix("\(name)=") { return String(pair.dropFirst(name.count + 1)) }
            }
        }
        return nil
    }
}
