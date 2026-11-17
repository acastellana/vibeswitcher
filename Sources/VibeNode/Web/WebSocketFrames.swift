import Foundation
import VibeCore

/// The WebSocket handshake's server half (RFC 6455, section 4.2): which requests ask for it, which of those are
/// sound, and the answer that opens the connection. No extension is ever agreed to (no permessage-deflate), so a
/// frame's reserved bits stay 0.
enum WebSocketHandshake {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// `Sec-WebSocket-Accept` for a client's `Sec-WebSocket-Key`: the SHA-1 of the key and the RFC's fixed text, in
    /// base64. SHA-1 as the RFC has it: it proves the server read the handshake, and keeps nothing secret.
    static func accept(key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
    }

    /// Whether `request` asks for a WebSocket: its Upgrade field names it. Such a request is never answered as a
    /// plain GET.
    static func isAsked(by request: WebRequest) -> Bool {
        request.headers.list("upgrade").contains { $0.lowercased() == "websocket" }
    }

    /// The key of a sound upgrade request; or the refusal: 400 for a Connection field that doesn't say upgrade, a key
    /// that is missing, repeated or not 16 bytes in base64, or two Origin fields; 426 naming version 13 for any
    /// other version.
    static func key(of request: WebRequest) -> Result<String, WebRefusal> {
        let headers = request.headers
        guard headers.list("connection").contains(where: { $0.lowercased() == "upgrade" }) else { return .failure(WebRefusal(.plain(400))) }
        guard headers["sec-websocket-version"] == "13" else {
            return .failure(WebRefusal(.plain(426, headers: [("Sec-WebSocket-Version", "13")])))
        }
        guard let key = headers["sec-websocket-key"], key.utf8.count == 24, Data(base64Encoded: key)?.count == 16 else {
            return .failure(WebRefusal(.plain(400)))
        }
        guard headers.all("origin").count <= 1 else { return .failure(WebRefusal(.plain(400))) }
        return .success(key)
    }

    /// The 101 that opens the connection, naming `subprotocol` when one was chosen.
    static func opening(key: String, subprotocol: String?) -> Data {
        var head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        head += "Sec-WebSocket-Accept: \(accept(key: key))\r\n"
        if let subprotocol { head += "Sec-WebSocket-Protocol: \(subprotocol)\r\n" }
        head += "X-Content-Type-Options: nosniff\r\n\r\n"
        return Data(head.utf8)
    }
}

/// A request refused, as an error: the answer to send.
struct WebRefusal: Error {
    var response: WebResponse
    init(_ response: WebResponse) { self.response = response }
}

/// A WebSocket frame's kinds, and a server's frame as bytes.
enum WebSocketFrame {
    enum Opcode: UInt8 {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA

        var isControl: Bool { rawValue & 0x8 != 0 }
    }

    /// One whole frame from the server: final, unmasked (a server never masks), no reserved bit, its length in the
    /// shortest form.
    static func encode(_ opcode: Opcode, _ payload: Data) -> Data {
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode.rawValue)
        switch payload.count {
        case 0...125:
            frame.append(UInt8(payload.count))
        case 126...0xFFFF:
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        default:
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        frame.append(payload)
        return frame
    }

    /// A close frame: `code` (1000 in place of one that may not travel) and as much of `reason` as fits a control
    /// frame's 125 bytes, cut between characters.
    static func close(code: UInt16, reason: String) -> Data {
        let sent = WebSocketClose.isSendable(code) ? code : WebSocketClose.normal
        var text = reason
        while text.utf8.count > 123 { text.removeLast() }
        return encode(.close, Data([UInt8(sent >> 8), UInt8(sent & 0xFF)]) + Data(text.utf8))
    }
}

/// Whether bytes are UTF-8 as RFC 3629 has it: no byte out of place, no character written longer than it needs, no
/// surrogate, nothing over U+10FFFF, nothing cut short.
enum UTF8Check {
    static func isValid(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { isValid($0) }
    }

    static func isValid(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        let count = bytes.count
        while index < count {
            let first = bytes[index]
            if first < 0x80 {
                index += 1
                continue
            }
            // How many bytes follow, and what the first of them may be: where the overlong forms, the surrogates and
            // what lies over U+10FFFF are shut out.
            let following: Int
            var second: ClosedRange<UInt8> = 0x80...0xBF
            switch first {
            case 0xC2...0xDF: following = 1
            case 0xE0: (following, second) = (2, 0xA0...0xBF)
            case 0xE1...0xEC, 0xEE...0xEF: following = 2
            case 0xED: (following, second) = (2, 0x80...0x9F)
            case 0xF0: (following, second) = (3, 0x90...0xBF)
            case 0xF1...0xF3: following = 3
            case 0xF4: (following, second) = (3, 0x80...0x8F)
            default: return false
            }
            guard index + following < count, second.contains(bytes[index + 1]) else { return false }
            if following >= 2 {
                for offset in 2...following where bytes[index + offset] & 0xC0 != 0x80 { return false }
            }
            index += following + 1
        }
        return true
    }
}

/// A client's frames, read as their bytes come, into whole messages. What RFC 6455 asks of a server: every frame
/// masked, no reserved bit (no extension is agreed), a known opcode, control frames whole and at most 125 bytes, a
/// length in its shortest form, fragments in order, text that is UTF-8, a close frame's code one that may travel.
/// A frame is refused by its header, before its payload is waited for or kept.
struct WebSocketDecoder {
    enum Event: Equatable {
        case text(String)
        case binary(Data)
        case ping(Data)
        case pong
        /// The client's close frame: its code (nil when it carried none) and its reason.
        case close(code: UInt16?, reason: String)
    }

    /// Why the connection must be closed, and the code to close it with: 1002, 1007 or 1009.
    struct Failure: Error, Equatable {
        var code: UInt16
        var reason: String
    }

    let maxMessageBytes: Int
    private var buffer: [UInt8] = []
    /// Where the bytes not yet read begin in `buffer`.
    private var start = 0
    /// The message whose fragments are coming: text or binary, and its bytes so far.
    private var message: (opcode: WebSocketFrame.Opcode, bytes: [UInt8])?

    init(maxMessageBytes: Int) {
        self.maxMessageBytes = maxMessageBytes
    }

    /// The bytes held: what came and isn't a whole frame yet, and the fragments of a message not yet ended.
    var heldBytes: Int { buffer.count - start + (message?.bytes.count ?? 0) }

    mutating func append(_ bytes: some Collection<UInt8>) {
        if start > 0, start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 64 * 1_024 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// The next whole message or control frame; nil when more bytes are needed. Throws what ends the connection.
    mutating func next() throws -> Event? {
        while true {
            let available = buffer.count - start
            guard available >= 2 else { return nil }
            let first = buffer[start], second = buffer[start + 1]
            guard first & 0x70 == 0 else { throw Failure(code: WebSocketClose.protocolError, reason: "a reserved bit") }
            guard let opcode = WebSocketFrame.Opcode(rawValue: first & 0x0F) else {
                throw Failure(code: WebSocketClose.protocolError, reason: "an unknown opcode")
            }
            let final = first & 0x80 != 0
            guard second & 0x80 != 0 else { throw Failure(code: WebSocketClose.protocolError, reason: "a frame not masked") }
            var length = Int(second & 0x7F)
            var header = 2
            if opcode.isControl {
                guard final, length <= 125 else { throw Failure(code: WebSocketClose.protocolError, reason: "a control frame fragmented or too long") }
            } else if length == 126 {
                guard available >= 4 else { return nil }
                length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                guard length >= 126 else { throw Failure(code: WebSocketClose.protocolError, reason: "a length not in its shortest form") }
                header = 4
            } else if length == 127 {
                guard available >= 10 else { return nil }
                var wide: UInt64 = 0
                for offset in 2..<10 { wide = wide << 8 | UInt64(buffer[start + offset]) }
                guard wide >> 63 == 0, wide > 0xFFFF else { throw Failure(code: WebSocketClose.protocolError, reason: "a length not in its shortest form") }
                guard wide <= UInt64(maxMessageBytes) else { throw Failure(code: WebSocketClose.tooBig, reason: "a message too big") }
                length = Int(wide)
                header = 10
            }
            switch opcode {
            case .continuation:
                guard message != nil else { throw Failure(code: WebSocketClose.protocolError, reason: "a continuation of nothing") }
            case .text, .binary:
                guard message == nil else { throw Failure(code: WebSocketClose.protocolError, reason: "a message inside another") }
            case .close, .ping, .pong:
                break
            }
            if !opcode.isControl {
                guard (message?.bytes.count ?? 0) + length <= maxMessageBytes else { throw Failure(code: WebSocketClose.tooBig, reason: "a message too big") }
            }
            guard available >= header + 4 + length else { return nil }

            let mask = start + header
            let from = mask + 4
            let payload = [UInt8](unsafeUninitializedCapacity: length) { unmasked, count in
                buffer.withUnsafeBufferPointer { held in
                    for index in 0..<length { unmasked[index] = held[from + index] ^ held[mask + (index & 3)] }
                }
                count = length
            }
            start = from + length

            switch opcode {
            case .ping:
                return .ping(Data(payload))
            case .pong:
                return .pong
            case .close:
                return try closing(payload)
            case .text, .binary:
                if final { return try whole(opcode, payload) }
                message = (opcode, payload)
            case .continuation:
                message?.bytes.append(contentsOf: payload)
                if final, let ended = message {
                    message = nil
                    return try whole(ended.opcode, ended.bytes)
                }
            }
        }
    }

    private func whole(_ opcode: WebSocketFrame.Opcode, _ bytes: [UInt8]) throws -> Event {
        guard opcode == .text else { return .binary(Data(bytes)) }
        guard UTF8Check.isValid(bytes) else { throw Failure(code: WebSocketClose.invalidData, reason: "text that isn't UTF-8") }
        return .text(String(decoding: bytes, as: UTF8.self))
    }

    private func closing(_ payload: [UInt8]) throws -> Event {
        if payload.isEmpty { return .close(code: nil, reason: "") }
        guard payload.count >= 2 else { throw Failure(code: WebSocketClose.protocolError, reason: "a close frame of one byte") }
        let code = UInt16(payload[0]) << 8 | UInt16(payload[1])
        guard WebSocketClose.isSendable(code) else { throw Failure(code: WebSocketClose.protocolError, reason: "a close code that may not be sent") }
        let reason = Array(payload[2...])
        guard UTF8Check.isValid(reason) else { throw Failure(code: WebSocketClose.invalidData, reason: "a close reason that isn't UTF-8") }
        return .close(code: code, reason: String(decoding: reason, as: UTF8.self))
    }
}
