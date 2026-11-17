import Foundation

/// A request's header fields, in the order they came, their names in lower case.
public struct WebHeaders: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        /// In lower case.
        public var name: String
        /// Without the blanks around it.
        public var value: String
    }

    public var fields: [Field]

    public init(_ fields: [(String, String)] = []) {
        self.fields = fields.map { Field(name: $0.0.lowercased(), value: $0.1) }
    }

    init(fields: [Field]) {
        self.fields = fields
    }

    /// Every value of the fields named `name` (any case), in order.
    public func all(_ name: String) -> [String] {
        let wanted = name.lowercased()
        return fields.filter { $0.name == wanted }.map(\.value)
    }

    /// The value of the one field named `name` (any case); nil when there is none, and when there are several: a
    /// field a decision rests on (Host, Origin) is never one of two.
    public subscript(_ name: String) -> String? {
        let found = all(name)
        return found.count == 1 ? found[0] : nil
    }

    /// The members of a field that holds a list (`Connection`, `Upgrade`, `Sec-WebSocket-Protocol`), from every
    /// field of that name: split at commas, the blanks around each removed, empty ones left out.
    public func list(_ name: String) -> [String] {
        all(name).flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// A GET request as it was sent: nothing in it is decoded but what `segments` gives.
public struct WebRequest: Sendable, Equatable {
    /// The request line's target: an absolute path, and its query when it has one ("/a/b?c=d").
    public var target: String
    public var headers: WebHeaders

    public init(target: String, headers: WebHeaders) {
        self.target = target
        self.headers = headers
    }

    /// The target up to its "?", percent-escapes and all.
    public var path: String {
        String(target.prefix { $0 != "?" })
    }

    /// What follows the target's first "?"; nil when it has none.
    public var query: String? {
        target.firstIndex(of: "?").map { String(target[target.index(after: $0)...]) }
    }

    /// The Host field: exactly one came (a request without, or with two, is refused 421 before it gets here).
    public var host: String { headers["host"] ?? "" }

    /// The Origin field; nil when none came (or several, which an upgrade is refused for).
    public var origin: String? { headers["origin"] }

    /// The path's segments, percent-decoded, when each names a plain entry: nil when one is empty ("//", a "/" at
    /// the end), is "." or "..", doesn't decode to UTF-8, or holds a "/", a "\" or a control character once
    /// decoded. "/" is no segments. What a handler that maps paths to files reads, so that no path leaves its
    /// folder.
    public var segments: [String]? {
        let path = self.path
        guard path.hasPrefix("/") else { return nil }
        if path == "/" { return [] }
        var decoded: [String] = []
        for raw in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard let segment = String(raw).removingPercentEncoding, !segment.isEmpty, segment != ".", segment != "..",
                  !segment.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F })
            else { return nil }
            decoded.append(segment)
        }
        return decoded
    }
}

/// What a request is answered with. The listener adds `Content-Length`, `Connection: close` and
/// `X-Content-Type-Options: nosniff` to every response, and `Content-Type: application/octet-stream` to a body that
/// names no type; a field of those names given here (but the type) is left out.
public struct WebResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [WebHeaders.Field]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers.map { WebHeaders.Field(name: $0.0, value: $0.1) }
        self.body = body
    }

    /// The listener's own answer for `status`: its number and its name as plain text, and nothing of the request.
    public static func plain(_ status: Int, headers: [(String, String)] = []) -> WebResponse {
        WebResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + headers,
                    body: Data("\(status) \(reason(status))\n".utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 413: return "Content Too Large"
        case 414: return "URI Too Long"
        case 421: return "Misdirected Request"
        case 426: return "Upgrade Required"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Status"
        }
    }

    /// The fields the listener writes itself, whatever a handler gave.
    static let own: Set<String> = ["content-length", "connection", "transfer-encoding", "x-content-type-options", "upgrade"]

    /// The response as bytes. One whose status isn't 200 to 599, or with a field that can't be a header (a name
    /// that isn't a token, a value holding a control character: a line end would start a field of its own), goes as
    /// 500 instead.
    func serialized() -> Data {
        let sound = (200...599).contains(status) && headers.allSatisfy { field in
            !field.name.isEmpty && field.name.utf8.allSatisfy(HTTPHead.isToken)
                && field.value.utf8.allSatisfy { $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7F) }
        }
        guard sound else { return WebResponse.plain(500).serialized() }
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var typed = false
        for field in headers where !Self.own.contains(field.name.lowercased()) {
            if field.name.lowercased() == "content-type" { typed = true }
            head += "\(field.name): \(field.value)\r\n"
        }
        if !typed, !body.isEmpty { head += "Content-Type: application/octet-stream\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A request's head, read as its bytes come: the request line and the header fields, up to the empty line. Strict:
/// each line ends in CR LF and nothing else holds either, a field's name is a token with its colon right after, no
/// field is folded onto a second line, the method is GET with no body, the version is HTTP/1.1, the target is an
/// absolute path of visible ASCII, and Host comes exactly once. Every size is limited as the bytes arrive, before
/// anything is parsed.
struct HTTPHead {
    enum Step: Equatable {
        /// The head hasn't ended yet.
        case more
        /// Refused: the answer to send before the close.
        case refused(WebResponse)
        /// The request, and the bytes that came after its head.
        case request(WebRequest, rest: [UInt8])
    }

    private var bytes: [UInt8] = []
    private var scanned = 0
    private var lineStart = 0
    private var lines: [Range<Int>] = []
    private var done = false

    static let cr = UInt8(ascii: "\r")
    static let lf = UInt8(ascii: "\n")

    /// RFC 9110's `tchar`: what a method and a field's name are made of.
    static func isToken(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"): return true
        default: return "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    /// Takes the next bytes of the connection. After anything but `.more` it takes no more.
    mutating func take(_ chunk: some Collection<UInt8>, limits: WebLimits) -> Step {
        guard !done else { return .more }
        bytes.append(contentsOf: chunk)
        while scanned < bytes.count {
            let index = scanned
            let byte = bytes[index]
            scanned += 1
            let afterCR = index > 0 && bytes[index - 1] == Self.cr
            if byte == Self.lf {
                guard afterCR else { return refuse(400) }
                let line = lineStart..<(index - 1)
                lineStart = index + 1
                if line.isEmpty {
                    guard index + 1 <= limits.maxHeaderBytes else { return refuse(431) }
                    done = true
                    let rest = Array(bytes[(index + 1)...])
                    switch parse(limits) {
                    case .success(let request): return .request(request, rest: rest)
                    case .failure(let refusal): return .refused(refusal.response)
                    }
                }
                if lines.isEmpty, line.count > limits.maxRequestLineBytes { return refuse(414) }
                lines.append(line)
                if lines.count > limits.maxHeaderCount + 1 { return refuse(431) }
            } else if afterCR {
                return refuse(400)
            }
        }
        // The CR that may yet end the line isn't the line's.
        let pending = bytes.count - lineStart - (bytes.last == Self.cr ? 1 : 0)
        if lines.isEmpty, pending > limits.maxRequestLineBytes { return refuse(414) }
        if bytes.count >= limits.maxHeaderBytes { return refuse(431) }
        return .more
    }

    private mutating func refuse(_ status: Int) -> Step {
        done = true
        return .refused(.plain(status))
    }

    private struct Refusal: Error {
        var response: WebResponse
        init(_ status: Int, headers: [(String, String)] = []) { response = .plain(status, headers: headers) }
        init(_ response: WebResponse) { self.response = response }
    }

    private func parse(_ limits: WebLimits) -> Result<WebRequest, Refusal> {
        guard let first = lines.first else { return .failure(Refusal(400)) }
        let parts = bytes[first].split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy(Self.isToken),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return .failure(Refusal(400)) }
        // "HTTP/" and two digits around a ".".
        let version = Array(parts[2])
        guard version.count == 8, version.starts(with: Array("HTTP/".utf8)), version[6] == UInt8(ascii: "."),
              (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(version[5]), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(version[7])
        else { return .failure(Refusal(400)) }
        guard version[5] == UInt8(ascii: "1"), version[7] == UInt8(ascii: "1") else { return .failure(Refusal(505)) }

        var fields: [WebHeaders.Field] = []
        for line in lines.dropFirst() {
            let raw = bytes[line]
            guard let colon = raw.firstIndex(of: UInt8(ascii: ":")), colon > raw.startIndex,
                  raw[..<colon].allSatisfy(Self.isToken) else { return .failure(Refusal(400)) }
            var value = raw[(colon + 1)...]
            while let byte = value.first, byte == 0x20 || byte == 0x09 { value = value.dropFirst() }
            while let byte = value.last, byte == 0x20 || byte == 0x09 { value = value.dropLast() }
            // Visible ASCII, blanks, and bytes over 127 (another site's cookie for this machine may hold them).
            guard value.allSatisfy({ $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7F) }) else { return .failure(Refusal(400)) }
            fields.append(WebHeaders.Field(name: String(decoding: raw[..<colon], as: UTF8.self).lowercased(),
                                           value: String(decoding: value, as: UTF8.self)))
        }
        let headers = WebHeaders(fields: fields)

        guard parts[0].elementsEqual("GET".utf8) else { return .failure(Refusal(405, headers: [("Allow", "GET")])) }
        guard parts[1].first == UInt8(ascii: "/"), !parts[1].contains(UInt8(ascii: "#")) else { return .failure(Refusal(400)) }
        // No Host, an empty one or two: not this listener's name, whatever it is (the live wire contract's §1): 421 with
        // no body, as for another name.
        guard let host = headers["host"], !host.isEmpty else { return .failure(Refusal(WebResponse(status: 421))) }
        // A GET carries no body: any length but 0, and any transfer coding, is one too large.
        guard headers.all("transfer-encoding").isEmpty else { return .failure(Refusal(413)) }
        let lengths = headers.all("content-length")
        if !lengths.isEmpty {
            guard lengths.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } }) else {
                return .failure(Refusal(400))
            }
            guard lengths.allSatisfy({ $0.utf8.allSatisfy { $0 == UInt8(ascii: "0") } }) else { return .failure(Refusal(413)) }
        }
        return .success(WebRequest(target: String(decoding: parts[1], as: UTF8.self), headers: headers))
    }
}
