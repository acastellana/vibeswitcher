import Foundation

/// Device keys, slice 1 (docs/superpowers/specs/2026-11-26-v2-device-keys-design.md, "What is signed, so a message
/// can't be replayed, reordered, or moved"): the envelope every client frame after `auth` travels in, and its check
/// against the unlock key (or a desktop's read key) the connection was admitted by. Nothing calls it yet: the server's
/// screen takes it in slices 7 and 8.
///
/// The server's side is one pure function per frame kind (`text`, `terminal`): given the connection (its nonce and the
/// listener's origin), the sequence number it expects next and the device's public key, a frame yields the exact bytes
/// that were signed, or a `Refusal`. Nothing of a frame is read as a request before its signature checks: the body is
/// returned as the very bytes signed, and the request is parsed from those alone.
///
/// - **A text frame** is exactly, byte for byte, `{"v":1,"kind":"signed","body":"` BODY `","sig":"` SIG `"}`. BODY is
///   the request's JSON with each `"` and `\` escaped by one `\` and nothing else (it holds no byte under 0x20, which a
///   compact JSON never does), so `JSON.stringify({v: 1, kind: "signed", body, sig})` makes exactly these bytes. SIG is
///   ECDSA P-256 with SHA-256, the 64 bytes `r || s` (WebCrypto's form) in unpadded base64url: 86 characters, the last
///   one's 4 spare bits zero. Signed: `"vibeswitcher-frame-v1\n" + origin + "\n" + conn + "\n" + body`, conn the
///   connection's 32 bytes in unpadded base64url (43 characters, as the server's `challenge` said them).
/// - **The body** is one JSON object in RFC 8259's grammar with no whitespace outside strings, at most `depthAtMost`
///   deep, no name twice in any object (names carry no escape, and two are the same when they are equal as Swift
///   strings: canonically equivalent, as a later `[String: …]` decoder takes them), valid UTF-8, a `\u` escape of a surrogate only as a high one followed by a low one. It begins
///   `{"v":1,"seq":N,` with N the frame's sequence number in plain decimal (no sign, no leading zero), 1 to `seqAtMost`.
/// - **A terminal frame** (binary type 6, input and resize sharing the text frames' one sequence) is
///   `[6][stream: 4][seq: 8][sig: 64][type: 1][payload]`, integers big-endian, type 1 (input, at least one byte) or 3
///   (a resize: exactly 4 bytes, columns and rows, 16 bits each, as `TerminalRelay` reads them). Signed:
///   `"vibeswitcher-term-v1\n" + origin + "\n" + conn + "\n"` then the stream, seq, type and payload bytes.
/// - **Sequence:** a frame's seq must be exactly the one expected (1 after `auth`, then one more per frame taken,
///   both kinds counted together); lower is `seqRepeated`, higher `seqSkipped`. The caller closes the connection on
///   any refusal (4401) and counts a frame only when it is taken.
/// - **Limits:** a frame of either kind is at most `frameBytesAtMost` (the live wire contract's 64 KiB for a client
///   frame).
///
/// The order of the checks: size, the envelope's layout, the signature, and only then the signed bytes' content
/// (the body's grammar, the seq). The signature's `s` isn't required low: WebCrypto doesn't make it so, and the other
/// signature of the same frame ((r, n − s)) signs the same bytes, which the sequence takes once.
public enum DeviceProof {
    /// The most bytes a client frame of either kind holds (the live wire contract: "a client text frame at most 64 KiB",
    /// "a client frame is at most 64 KiB").
    public static let frameBytesAtMost = 64 * 1_024
    /// The highest sequence number: JavaScript's largest exact integer, so the page counts it in a plain number.
    public static let seqAtMost: UInt64 = (1 << 53) - 1
    /// The deepest a body's arrays and objects nest, the body's own object counted.
    public static let depthAtMost = 32
    /// A signed terminal frame's first byte.
    public static let terminalType: UInt8 = 6
    /// The length of a terminal frame before its payload: type, stream, seq, signature, inner type.
    public static let terminalHeaderBytes = 1 + 4 + 8 + 64 + 1

    static let textLabel = Array("vibeswitcher-frame-v1\n".utf8)
    static let terminalLabel = Array("vibeswitcher-term-v1\n".utf8)
    static let envelopeStart = Array(#"{"v":1,"kind":"signed","body":""#.utf8)
    static let envelopeSig = Array(#"","sig":""#.utf8)
    static let envelopeEnd = Array(#""}"#.utf8)
    static let bodyStart = Array(#"{"v":1,"seq":"#.utf8)
    static let signatureCharacters = 86

    /// What the frame is bound to: the connection's nonce (the server's `challenge`, 32 random bytes) and the origin of
    /// the listener it arrived on (`http://localhost:47830`, `https://<name>:47830`).
    public struct Connection: Equatable, Sendable {
        public let conn: [UInt8]
        public let origin: String

        /// Nil unless `conn` is 32 bytes and `origin` is printable ASCII without a space (so no newline can move the
        /// signed bytes' fields).
        public init?(conn: [UInt8], origin: String) {
            guard conn.count == 32, !origin.isEmpty, origin.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
            self.conn = conn
            self.origin = origin
        }

        /// The connection's nonce as the signed bytes name it: unpadded base64url.
        public var connText: String { DeviceProof.base64url(conn) }

        func signedStart(_ label: [UInt8]) -> [UInt8] {
            label + Array(origin.utf8) + [0x0A] + Array(connText.utf8) + [0x0A]
        }
    }

    /// Why a frame was refused. Each closes the connection; none says more than its name.
    public enum Refusal: String, Error, Equatable, Sendable {
        /// Over `frameBytesAtMost`.
        case tooLarge
        /// Not the envelope: a text frame that doesn't begin with its fixed bytes, a binary frame whose first byte isn't 6.
        case notSigned
        /// The frame ends before its layout does.
        case truncated
        /// Bytes after the envelope's end, or a resize's payload past its 4 bytes.
        case trailingBytes
        /// A byte the layout doesn't allow where it is: a control byte in the body, a character outside base64url.
        case malformed
        /// A value in a spelling other than its one: an escape other than `\"` or `\\` in the envelope, a signature
        /// whose spare bits aren't zero, a seq with a leading zero.
        case nonCanonical
        /// An empty body, or an input frame with no byte.
        case empty
        /// A terminal frame's inner type other than 1 (input) or 3 (a resize).
        case terminalType
        /// The signature doesn't check under the key, over the bytes signed for this connection and origin.
        case badSignature
        /// The signed body isn't one object by the body's grammar.
        case body
        /// The signed body names a member twice in one object.
        case duplicateName
        /// The signed body nests deeper than `depthAtMost`.
        case tooDeep
        /// The signed body doesn't begin `{"v":1,"seq":N,`.
        case bodyStart
        /// A seq of 0 or past `seqAtMost`, or an expected one out of that range.
        case seqOutOfRange
        /// A seq lower than the one expected: a replay, a repeat, a frame behind another.
        case seqRepeated
        /// A seq higher than the one expected: a frame lost, or one ahead of another.
        case seqSkipped
    }

    /// A text frame taken: its seq, and the body exactly as signed (the request, parsed from these bytes alone).
    public struct Request: Equatable, Sendable {
        public let seq: UInt64
        public let body: [UInt8]
    }

    /// A terminal frame taken.
    public struct Terminal: Equatable, Sendable {
        public enum Kind: UInt8, Sendable {
            case input = 1
            case resize = 3
        }

        public let stream: UInt32
        public let seq: UInt64
        public let kind: Kind
        public let payload: [UInt8]
    }

    // MARK: The server's check

    /// A text frame of `connection`'s, signed by `key`, expected to carry `next`: its body, or why not.
    public static func text(_ frame: [UInt8], on connection: Connection, next: UInt64,
                            key: P256.Signing.PublicKey) -> Result<Request, Refusal> {
        guard frame.count <= frameBytesAtMost else { return .failure(.tooLarge) }
        let envelope: (body: [UInt8], signature: [UInt8])
        switch layout(text: frame) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let parts): envelope = parts
        }
        guard verify(envelope.signature, over: connection.signedStart(textLabel) + envelope.body, key: key) else {
            return .failure(.badSignature)
        }
        let seq: UInt64
        switch bodySeq(envelope.body) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let number): seq = number
        }
        if let refusal = strictObject(envelope.body) { return .failure(refusal) }
        if let refusal = sequence(seq, next: next) { return .failure(refusal) }
        return .success(Request(seq: seq, body: envelope.body))
    }

    /// A terminal frame (binary type 6) of `connection`'s, signed by `key`, expected to carry `next`.
    public static func terminal(_ frame: [UInt8], on connection: Connection, next: UInt64,
                                key: P256.Signing.PublicKey) -> Result<Terminal, Refusal> {
        guard frame.count <= frameBytesAtMost else { return .failure(.tooLarge) }
        guard let first = frame.first else { return .failure(.truncated) }
        guard first == terminalType else { return .failure(.notSigned) }
        guard frame.count >= terminalHeaderBytes else { return .failure(.truncated) }
        guard let kind = Terminal.Kind(rawValue: frame[terminalHeaderBytes - 1]) else { return .failure(.terminalType) }
        let payload = Array(frame[terminalHeaderBytes...])
        switch kind {
        case .input where payload.isEmpty: return .failure(.empty)
        case .resize where payload.count < 4: return .failure(.truncated)
        case .resize where payload.count > 4: return .failure(.trailingBytes)
        default: break
        }
        let stream = Array(frame[1..<5]), seqBytes = Array(frame[5..<13]), signature = Array(frame[13..<77])
        let signed = connection.signedStart(terminalLabel) + stream + seqBytes + [kind.rawValue] + payload
        guard verify(signature, over: signed, key: key) else { return .failure(.badSignature) }
        let seq = seqBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard (1...seqAtMost).contains(seq) else { return .failure(.seqOutOfRange) }
        if let refusal = sequence(seq, next: next) { return .failure(refusal) }
        return .success(Terminal(stream: stream.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, seq: seq, kind: kind, payload: payload))
    }

    // MARK: The page's side (the vectors, the tests)

    /// The bytes a text frame's signature is over.
    public static func signedBytes(body: [UInt8], on connection: Connection) -> [UInt8] {
        connection.signedStart(textLabel) + body
    }

    /// The bytes a terminal frame's signature is over.
    public static func signedBytes(stream: UInt32, seq: UInt64, kind: Terminal.Kind, payload: [UInt8],
                                   on connection: Connection) -> [UInt8] {
        connection.signedStart(terminalLabel) + bigEndian(UInt64(stream), bytes: 4) + bigEndian(seq, bytes: 8) + [kind.rawValue] + payload
    }

    /// A text frame around `body` and its 64-byte `signature`.
    public static func textFrame(body: [UInt8], signature: [UInt8]) -> [UInt8] {
        var escaped: [UInt8] = []
        escaped.reserveCapacity(body.count)
        for byte in body {
            if byte == 0x22 || byte == 0x5C { escaped.append(0x5C) }
            escaped.append(byte)
        }
        return envelopeStart + escaped + envelopeSig + Array(base64url(signature).utf8) + envelopeEnd
    }

    /// A terminal frame of its parts and its 64-byte `signature`.
    public static func terminalFrame(stream: UInt32, seq: UInt64, kind: Terminal.Kind, payload: [UInt8],
                                     signature: [UInt8]) -> [UInt8] {
        [terminalType] + bigEndian(UInt64(stream), bytes: 4) + bigEndian(seq, bytes: 8) + signature + [kind.rawValue] + payload
    }

    /// Unpadded base64url.
    public static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: The parts

    /// The text envelope's body (unescaped: the bytes signed) and signature, or why its bytes aren't the envelope's.
    static func layout(text frame: [UInt8]) -> Result<(body: [UInt8], signature: [UInt8]), Refusal> {
        if frame.count < envelopeStart.count {
            return frame.elementsEqual(envelopeStart.prefix(frame.count)) ? .failure(.truncated) : .failure(.notSigned)
        }
        guard frame[0..<envelopeStart.count].elementsEqual(envelopeStart) else { return .failure(.notSigned) }
        var at = envelopeStart.count
        var body: [UInt8] = []
        body.reserveCapacity(frame.count - at)
        while true {
            guard at < frame.count else { return .failure(.truncated) }
            let byte = frame[at]
            if byte == 0x22 { break }
            if byte < 0x20 { return .failure(.malformed) }
            if byte == 0x5C {
                guard at + 1 < frame.count else { return .failure(.truncated) }
                let escaped = frame[at + 1]
                guard escaped == 0x22 || escaped == 0x5C else { return .failure(escaped < 0x20 ? .malformed : .nonCanonical) }
                body.append(escaped)
                at += 2
            } else {
                body.append(byte)
                at += 1
            }
        }
        // `at` is the body's closing quote: the first byte of `envelopeSig`.
        for expected in envelopeSig {
            guard at < frame.count else { return .failure(.truncated) }
            guard frame[at] == expected else { return .failure(.malformed) }
            at += 1
        }
        guard !body.isEmpty else { return .failure(.empty) }
        guard frame.count - at >= signatureCharacters else {
            return frame[at...].allSatisfy({ sextet($0) != nil }) ? .failure(.truncated) : .failure(.malformed)
        }
        let signatureText = Array(frame[at..<(at + signatureCharacters)])
        at += signatureCharacters
        let signature: [UInt8]
        switch strictSignature(signatureText) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let bytes): signature = bytes
        }
        for expected in envelopeEnd {
            guard at < frame.count else { return .failure(.truncated) }
            guard frame[at] == expected else { return .failure(.malformed) }
            at += 1
        }
        guard at == frame.count else { return .failure(.trailingBytes) }
        return .success((body, signature))
    }

    /// 86 base64url characters as 64 bytes: each in the alphabet, the last one's 4 spare bits zero.
    static func strictSignature(_ text: [UInt8]) -> Result<[UInt8], Refusal> {
        var bits: UInt32 = 0, count = 0
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for character in text {
            guard let value = sextet(character) else { return .failure(.malformed) }
            bits = bits << 6 | UInt32(value)
            count += 6
            if count >= 8 {
                count -= 8
                bytes.append(UInt8(truncatingIfNeeded: bits >> UInt32(count)))
                bits &= (1 << UInt32(count)) - 1
            }
        }
        guard bits == 0 else { return .failure(.nonCanonical) }
        return .success(bytes)
    }

    static func sextet(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return character - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return character - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0") + 52
        case UInt8(ascii: "-"): return 62
        case UInt8(ascii: "_"): return 63
        default: return nil
        }
    }

    static func verify(_ signature: [UInt8], over signed: [UInt8], key: P256.Signing.PublicKey) -> Bool {
        guard signature.count == 64, let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(ecdsa, for: signed)
    }

    /// The seq the body's fixed beginning names.
    static func bodySeq(_ body: [UInt8]) -> Result<UInt64, Refusal> {
        guard body.count > bodyStart.count, body[0..<bodyStart.count].elementsEqual(bodyStart) else { return .failure(.bodyStart) }
        var at = bodyStart.count
        let digitsStart = at
        while at < body.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(body[at]) { at += 1 }
        let digits = body[digitsStart..<at]
        guard let first = digits.first, at < body.count, body[at] == UInt8(ascii: ",") else { return .failure(.bodyStart) }
        guard first != UInt8(ascii: "0") else { return .failure(.nonCanonical) }
        guard digits.count <= 16 else { return .failure(.seqOutOfRange) }
        let seq = digits.reduce(UInt64(0)) { $0 * 10 + UInt64($1 - UInt8(ascii: "0")) }
        guard seq <= seqAtMost else { return .failure(.seqOutOfRange) }
        return .success(seq)
    }

    static func sequence(_ seq: UInt64, next: UInt64) -> Refusal? {
        guard (1...seqAtMost).contains(next) else { return .seqOutOfRange }
        if seq < next { return .seqRepeated }
        if seq > next { return .seqSkipped }
        return nil
    }

    static func bigEndian(_ value: UInt64, bytes: Int) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }

    // MARK: The body's grammar

    /// Nil when `body` is one JSON object by the body's grammar (above), else why not.
    static func strictObject(_ body: [UInt8]) -> Refusal? {
        // Valid UTF-8: decoding replaces anything else (an overlong form, a surrogate, a cut sequence) with U+FFFD.
        guard Array(String(decoding: body, as: UTF8.self).utf8) == body else { return .body }
        var reader = StrictJSON(bytes: body)
        guard body.first == UInt8(ascii: "{") else { return .body }
        if let refusal = reader.value(depth: 1) { return refusal }
        return reader.at == body.count ? nil : .body
    }

    /// RFC 8259's grammar without whitespace, over bytes already valid UTF-8.
    struct StrictJSON {
        let bytes: [UInt8]
        var at = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var peek: UInt8? { at < bytes.count ? bytes[at] : nil }

        mutating func take(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            at += 1
            return true
        }

        mutating func value(depth: Int) -> Refusal? {
            guard let byte = peek else { return .body }
            switch byte {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string(name: false).refusal
            case UInt8(ascii: "t"): return word("true")
            case UInt8(ascii: "f"): return word("false")
            case UInt8(ascii: "n"): return word("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
            default: return .body
            }
        }

        mutating func object(depth: Int) -> Refusal? {
            guard depth <= DeviceProof.depthAtMost else { return .tooDeep }
            at += 1
            if take(UInt8(ascii: "}")) { return nil }
            var names: Set<String> = []
            while true {
                let name = string(name: true)
                if let refusal = name.refusal { return refusal }
                // As String: canonically equivalent names (K and the Kelvin sign) are one key to every Swift decoder.
                guard names.insert(String(decoding: name.bytes, as: UTF8.self)).inserted else { return .duplicateName }
                guard take(UInt8(ascii: ":")) else { return .body }
                if let refusal = value(depth: depth + 1) { return refusal }
                if take(UInt8(ascii: "}")) { return nil }
                guard take(UInt8(ascii: ",")) else { return .body }
            }
        }

        mutating func array(depth: Int) -> Refusal? {
            guard depth <= DeviceProof.depthAtMost else { return .tooDeep }
            at += 1
            if take(UInt8(ascii: "]")) { return nil }
            while true {
                if let refusal = value(depth: depth + 1) { return refusal }
                if take(UInt8(ascii: "]")) { return nil }
                guard take(UInt8(ascii: ",")) else { return .body }
            }
        }

        /// A string at `at`; a name may hold no escape. Its bytes between the quotes.
        mutating func string(name: Bool) -> (bytes: ArraySlice<UInt8>, refusal: Refusal?) {
            guard take(UInt8(ascii: "\"")) else { return ([], .body) }
            let start = at
            while let byte = peek {
                if byte == UInt8(ascii: "\"") {
                    at += 1
                    return (bytes[start..<(at - 1)], nil)
                }
                if byte < 0x20 { return ([], .body) }
                if byte == UInt8(ascii: "\\") {
                    if name { return ([], .body) }
                    at += 1
                    guard let escaped = peek else { return ([], .body) }
                    at += 1
                    switch escaped {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"), UInt8(ascii: "f"),
                         UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                        continue
                    case UInt8(ascii: "u"):
                        guard let unit = hex4() else { return ([], .body) }
                        if (0xDC00...0xDFFF).contains(unit) { return ([], .body) }
                        if (0xD800...0xDBFF).contains(unit) {
                            guard take(UInt8(ascii: "\\")), take(UInt8(ascii: "u")), let low = hex4(),
                                  (0xDC00...0xDFFF).contains(low) else { return ([], .body) }
                        }
                    default:
                        return ([], .body)
                    }
                } else {
                    at += 1
                }
            }
            return ([], .body)
        }

        mutating func hex4() -> UInt16? {
            guard at + 4 <= bytes.count else { return nil }
            var unit: UInt16 = 0
            for byte in bytes[at..<(at + 4)] {
                let digit: UInt8
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
                default: return nil
                }
                unit = unit << 4 | UInt16(digit)
            }
            at += 4
            return unit
        }

        mutating func word(_ text: String) -> Refusal? {
            for byte in text.utf8 {
                guard take(byte) else { return .body }
            }
            return nil
        }

        /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
        mutating func number() -> Refusal? {
            _ = take(UInt8(ascii: "-"))
            if take(UInt8(ascii: "0")) {
                if let next = peek, isDigit(next) { return .body }
            } else {
                guard digits() else { return .body }
            }
            if take(UInt8(ascii: ".")) {
                guard digits() else { return .body }
            }
            if take(UInt8(ascii: "e")) || take(UInt8(ascii: "E")) {
                _ = take(UInt8(ascii: "+")) || take(UInt8(ascii: "-"))
                guard digits() else { return .body }
            }
            return nil
        }

        /// One or more digits.
        mutating func digits() -> Bool {
            let start = at
            while let byte = peek, isDigit(byte) { at += 1 }
            return at > start
        }

        func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }
    }
}
