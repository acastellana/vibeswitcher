import Foundation
import Testing
@testable import VibeCore

/// Device keys, slice 1 (`DeviceProof`): a signed client frame yields exactly the bytes signed, and nothing else
/// passes. A frame can't be replayed, reordered, or moved to another connection, origin, node, session or frame kind;
/// any other spelling of the envelope or a body outside its grammar is refused, each with its own reason, before
/// anything of the request is read. `theVectorsAreTheBytesThePageMakes` holds the fixed vectors the page's key module
/// (slice 5, `WebApp/js/devicekey.js`) must reproduce byte for byte.
struct DeviceProofTests {
    // MARK: Fixtures

    /// The vectors' key: its scalar is SHA-256 of a fixed phrase, so nothing secret is written down.
    static let key = try! P256.Signing.PrivateKey(rawRepresentation: Array(SHA256.hash(data: Array("vibeswitcher DeviceProof vector key".utf8))))
    static let otherKey = try! P256.Signing.PrivateKey(rawRepresentation: Array(SHA256.hash(data: Array("vibeswitcher DeviceProof another key".utf8))))
    static let localhost = "http://localhost:47830"
    static let phone = "https://node.example.ts.net:47830"
    static let conn = DeviceProof.Connection(conn: (0..<32).map { UInt8($0) }, origin: localhost)!

    static func connection(_ seed: String, origin: String = localhost) -> DeviceProof.Connection {
        DeviceProof.Connection(conn: Array(SHA256.hash(data: Array(seed.utf8))), origin: origin)!
    }

    static func body(seq: UInt64, session: String = "s-1", text: String = "hello") -> [UInt8] {
        Array(#"{"v":1,"seq":\#(seq),"id":"\#(seq)","kind":"send","action":"6f1d2c3b-0000-4000-8000-00000000000\#(seq % 10)","args":{"session":"\#(session)","text":"\#(text)"}}"#.utf8)
    }

    static func sign(_ bytes: [UInt8], by key: P256.Signing.PrivateKey = key) -> [UInt8] {
        Array(try! key.signature(for: bytes).rawRepresentation)
    }

    /// A text frame of `body`, signed for `connection` by `key`.
    static func text(_ body: [UInt8], on connection: DeviceProof.Connection = conn, by key: P256.Signing.PrivateKey = key) -> [UInt8] {
        DeviceProof.textFrame(body: body, signature: sign(DeviceProof.signedBytes(body: body, on: connection), by: key))
    }

    static func terminal(stream: UInt32 = 3, seq: UInt64, kind: DeviceProof.Terminal.Kind = .input, payload: [UInt8] = Array("ls\r".utf8),
                         on connection: DeviceProof.Connection = conn, by key: P256.Signing.PrivateKey = key) -> [UInt8] {
        let signature = sign(DeviceProof.signedBytes(stream: stream, seq: seq, kind: kind, payload: payload, on: connection), by: key)
        return DeviceProof.terminalFrame(stream: stream, seq: seq, kind: kind, payload: payload, signature: signature)
    }

    static func check(_ frame: [UInt8], on connection: DeviceProof.Connection = conn, next: UInt64 = 1,
                      key: P256.Signing.PublicKey = key.publicKey) -> Result<DeviceProof.Request, DeviceProof.Refusal> {
        DeviceProof.text(frame, on: connection, next: next, key: key)
    }

    static func checkTerminal(_ frame: [UInt8], on connection: DeviceProof.Connection = conn, next: UInt64 = 1,
                              key: P256.Signing.PublicKey = key.publicKey) -> Result<DeviceProof.Terminal, DeviceProof.Refusal> {
        DeviceProof.terminal(frame, on: connection, next: next, key: key)
    }

    static func refusal<T>(_ result: Result<T, DeviceProof.Refusal>) -> DeviceProof.Refusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    /// A backslash and a u: the start of a JSON `\\u` escape, written so no tool reads it as one.
    static let u = "\u{5C}u"

    static func hex(_ text: String) -> [UInt8] {
        let digits = Array(text.utf8)
        return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(decoding: digits[$0..<($0 + 2)], as: UTF8.self), radix: 16)! }
    }

    /// A signed text frame around bytes of the test's own (signed, so only the body's own rules can refuse it).
    static func signedBody(_ body: String) -> Result<DeviceProof.Request, DeviceProof.Refusal> {
        check(text(Array(body.utf8)))
    }

    // MARK: What passes

    @Test func aSignedFrameYieldsExactlyTheSignedBody() {
        let body = Self.body(seq: 1, text: #"say \"hi\" \\ café ✓"#)
        #expect(Self.check(Self.text(body)) == .success(.init(seq: 1, body: body)))
        let phone = Self.connection("phone", origin: Self.phone)
        let seven = Self.body(seq: 7)
        #expect(Self.check(Self.text(seven, on: phone), on: phone, next: 7) == .success(.init(seq: 7, body: seven)))
    }

    @Test func aSignedTerminalFrameYieldsItsStreamKindAndPayload() {
        #expect(Self.checkTerminal(Self.terminal(stream: 0x0102_0304, seq: 1)) == .success(.init(stream: 0x0102_0304, seq: 1, kind: .input, payload: Array("ls\r".utf8))))
        let size: [UInt8] = [0x00, 0x78, 0x00, 0x28]
        #expect(Self.checkTerminal(Self.terminal(seq: 9, kind: .resize, payload: size), next: 9) == .success(.init(stream: 3, seq: 9, kind: .resize, payload: size)))
    }

    /// Text and terminal frames count in one sequence: each frame takes the next number, whichever its kind.
    @Test func textAndTerminalFramesShareOneSequence() {
        #expect(Self.check(Self.text(Self.body(seq: 1)), next: 1) == .success(.init(seq: 1, body: Self.body(seq: 1))))
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 1), next: 2)) == .seqRepeated)
        #expect((try? Self.checkTerminal(Self.terminal(seq: 2), next: 2).get())?.seq == 2)
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 2)), next: 3)) == .seqRepeated)
        #expect((try? Self.check(Self.text(Self.body(seq: 3)), next: 3).get())?.seq == 3)
    }

    /// The limit is the contract's 64 KiB a client frame, of either kind: a frame of exactly that passes, one more byte doesn't.
    @Test func aFrameAtTheLimitPassesAndOneByteMoreIsRefused() {
        let empty = Self.body(seq: 1, text: "")
        let room = DeviceProof.frameBytesAtMost - Self.text(empty).count
        let full = Self.body(seq: 1, text: String(repeating: "a", count: room))
        let atLimit = Self.text(full)
        #expect(atLimit.count == DeviceProof.frameBytesAtMost)
        #expect(Self.check(atLimit) == .success(.init(seq: 1, body: full)))
        let over = Self.text(Self.body(seq: 1, text: String(repeating: "a", count: room + 1)))
        #expect(Self.refusal(Self.check(over)) == .tooLarge)

        let payloadRoom = DeviceProof.frameBytesAtMost - DeviceProof.terminalHeaderBytes
        let input = Self.terminal(seq: 1, payload: Array(repeating: 0x61, count: payloadRoom))
        #expect(input.count == DeviceProof.frameBytesAtMost)
        #expect((try? Self.checkTerminal(input).get())?.payload.count == payloadRoom)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 1, payload: Array(repeating: 0x61, count: payloadRoom + 1)))) == .tooLarge)
    }

    // MARK: Replayed, reordered

    @Test func aReplayedFrameIsRefused() {
        let frame = Self.text(Self.body(seq: 1))
        #expect((try? Self.check(frame, next: 1).get()) != nil)
        #expect(Self.refusal(Self.check(frame, next: 2)) == .seqRepeated)
        let input = Self.terminal(seq: 2)
        #expect((try? Self.checkTerminal(input, next: 2).get()) != nil)
        #expect(Self.refusal(Self.checkTerminal(input, next: 3)) == .seqRepeated)
    }

    @Test func aSkippedSeqIsRefused() {
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 3)), next: 2)) == .seqSkipped)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 3), next: 2)) == .seqSkipped)
    }

    /// A new frame (another body) that repeats a number already taken.
    @Test func aRepeatedSeqIsRefused() {
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 4, text: "other")), next: 5)) == .seqRepeated)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 4, payload: [0x71]), next: 5)) == .seqRepeated)
    }

    /// Frames 1, 2, 3 sent as 1, 3, 2: the 3 is ahead of the 2 expected, and a 2 after a 3 was taken is behind.
    @Test func framesOutOfOrderAreRefused() {
        #expect((try? Self.check(Self.text(Self.body(seq: 1)), next: 1).get()) != nil)
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 3)), next: 2)) == .seqSkipped)
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 2)), next: 4)) == .seqRepeated)
    }

    @Test func aSeqOutOfRangeIsRefused() {
        #expect(Self.refusal(Self.signedBody(#"{"v":1,"seq":9007199254740992,"id":"1"}"#)) == .seqOutOfRange)
        #expect(Self.refusal(Self.signedBody(#"{"v":1,"seq":12345678901234567,"id":"1"}"#)) == .seqOutOfRange)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 0))) == .seqOutOfRange)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: DeviceProof.seqAtMost + 1), next: 1)) == .seqOutOfRange)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: UInt64.max))) == .seqOutOfRange)
        // The highest passes; an expected number out of range takes nothing.
        let top = DeviceProof.seqAtMost
        #expect((try? Self.check(Self.text(Self.body(seq: top)), next: top).get())?.seq == top)
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 1)), next: 0)) == .seqOutOfRange)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: top), next: top + 1)) == .seqOutOfRange)
    }

    // MARK: Moved

    @Test func aFrameForAnotherConnectionIsRefused() {
        let other = Self.connection("another connection")
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 1), on: other))) == .badSignature)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 1, on: other))) == .badSignature)
    }

    @Test func aFrameForAnotherOriginIsRefused() {
        let samenonce = DeviceProof.Connection(conn: Self.conn.conn, origin: "http://127.0.0.1:47830")!
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 1), on: samenonce))) == .badSignature)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 1, on: samenonce))) == .badSignature)
        let tailnet = DeviceProof.Connection(conn: Self.conn.conn, origin: Self.phone)!
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 1), on: tailnet))) == .badSignature)
    }

    /// Another node: on loopback every node's origin is the same (`http://localhost:47830`), so what binds a frame to
    /// its node there is the connection's nonce (the node picked it) and the unlock key (the node certified it). A
    /// phone paired to two nodes: their origins differ too.
    @Test func aFrameForAnotherNodeIsRefused() {
        let nodeA = Self.connection("node A's connection"), nodeB = Self.connection("node B's connection")
        #expect((try? Self.check(Self.text(Self.body(seq: 1), on: nodeA), on: nodeA).get()) != nil)
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 1), on: nodeA), on: nodeB)) == .badSignature)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 1, on: nodeA), on: nodeB)) == .badSignature)
        let phoneA = Self.connection("A", origin: "https://a.example.ts.net:47830"), phoneB = Self.connection("B", origin: "https://b.example.ts.net:47830")
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 1), on: phoneA), on: phoneB)) == .badSignature)
        // Node B's unlock key is another key: node A's frame isn't B's device's.
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 1), on: nodeA), on: nodeA, key: Self.otherKey.publicKey)) == .badSignature)
    }

    /// Another session or card: they are in the body's `args`, and a terminal frame's stream in its signed bytes.
    @Test func aFrameMovedToAnotherSessionIsRefused() {
        let frame = Self.text(Self.body(seq: 1, session: "s-1"))
        let moved = Array(String(decoding: frame, as: UTF8.self).replacingOccurrences(of: "s-1", with: "s-2").utf8)
        #expect(moved != frame && moved.count == frame.count)
        #expect(Self.refusal(Self.check(moved)) == .badSignature)
        var stream = Self.terminal(stream: 3, seq: 1)
        stream[4] = 4
        #expect(Self.refusal(Self.checkTerminal(stream)) == .badSignature)
        var resized = Self.terminal(seq: 1, kind: .input, payload: [0, 0x78, 0, 0x28])
        resized[DeviceProof.terminalHeaderBytes - 1] = DeviceProof.Terminal.Kind.resize.rawValue
        #expect(Self.refusal(Self.checkTerminal(resized)) == .badSignature)
    }

    @Test func aTextFrameAsATerminalFrameAndTheReverseAreRefused() {
        let text = Self.text(Self.body(seq: 1)), input = Self.terminal(seq: 1)
        #expect(Self.refusal(Self.checkTerminal(text)) == .notSigned)
        #expect(Self.refusal(Self.check(input)) == .notSigned)
        // A signature made for one kind's bytes never checks as the other's: each kind's signed bytes begin with its own label.
        let body = Self.body(seq: 1)
        let textSignature = Self.sign(DeviceProof.signedBytes(body: body, on: Self.conn))
        let transplanted = DeviceProof.terminalFrame(stream: 3, seq: 1, kind: .input, payload: body, signature: textSignature)
        #expect(Self.refusal(Self.checkTerminal(transplanted)) == .badSignature)
        let terminalSignature = Self.sign(DeviceProof.signedBytes(stream: 3, seq: 1, kind: .input, payload: body, on: Self.conn))
        #expect(Self.refusal(Self.check(DeviceProof.textFrame(body: body, signature: terminalSignature))) == .badSignature)
        // Each kind's own label: the same parts signed under the other kind's label don't check.
        let frameLabel = Array("vibeswitcher-frame-v1\n".utf8), termLabel = Array("vibeswitcher-term-v1\n".utf8)
        let bound = Array("\(Self.localhost)\n\(Self.conn.connText)\n".utf8)
        let terminalParts = bound + [0, 0, 0, 3] + [0, 0, 0, 0, 0, 0, 0, 1] + [1] + Array("ls\r".utf8)
        #expect(Self.checkTerminal(DeviceProof.terminalFrame(stream: 3, seq: 1, kind: .input, payload: Array("ls\r".utf8), signature: Self.sign(termLabel + terminalParts)))
                == .success(.init(stream: 3, seq: 1, kind: .input, payload: Array("ls\r".utf8))))
        #expect(Self.refusal(Self.checkTerminal(DeviceProof.terminalFrame(stream: 3, seq: 1, kind: .input, payload: Array("ls\r".utf8), signature: Self.sign(frameLabel + terminalParts)))) == .badSignature)
        #expect(Self.check(DeviceProof.textFrame(body: body, signature: Self.sign(frameLabel + bound + body))) == .success(.init(seq: 1, body: body)))
        #expect(Self.refusal(Self.check(DeviceProof.textFrame(body: body, signature: Self.sign(termLabel + bound + body)))) == .badSignature)
        // The old unsigned terminal types aren't type 6.
        for type: UInt8 in [1, 3, 0, 7] {
            var old = input
            old[0] = type
            #expect(Self.refusal(Self.checkTerminal(old)) == .notSigned, "\(type)")
        }
    }

    // MARK: Malformed

    /// Every cut of a valid frame, at every length: the text envelope is always `truncated`; a terminal frame is while
    /// its header is, and past it an input frame's payload has no length of its own, so a cut one is another payload,
    /// which the signature refuses.
    @Test func aTruncatedFrameIsRefused() {
        let text = Self.text(Self.body(seq: 1, text: #"a \"quote\" \\ and é"#))
        for length in 0..<text.count {
            #expect(Self.refusal(Self.check(Array(text.prefix(length)))) == .truncated, "\(length)")
        }
        let input = Self.terminal(seq: 1, payload: Array("hello".utf8))
        for length in 0..<input.count {
            let expected: DeviceProof.Refusal = length < DeviceProof.terminalHeaderBytes ? .truncated
                : length == DeviceProof.terminalHeaderBytes ? .empty : .badSignature
            #expect(Self.refusal(Self.checkTerminal(Array(input.prefix(length)))) == expected, "\(length)")
        }
        let resize = Self.terminal(seq: 1, kind: .resize, payload: [0, 0x78, 0, 0x28])
        for length in 0..<resize.count {
            #expect(Self.refusal(Self.checkTerminal(Array(resize.prefix(length)))) == .truncated, "\(length)")
        }
    }

    @Test func trailingBytesAreRefused() {
        let text = Self.text(Self.body(seq: 1))
        for tail in [[0x20], [0x0A], [0x7D], Array(#","x":1}"#.utf8), text] as [[UInt8]] {
            #expect(Self.refusal(Self.check(text + tail)) == .trailingBytes, "\(tail)")
        }
        let resize = Self.terminal(seq: 1, kind: .resize, payload: [0, 0x78, 0, 0x28, 0])
        #expect(Self.refusal(Self.checkTerminal(resize)) == .trailingBytes)
    }

    /// Each value of the envelope has one spelling: another one that JSON would read the same is refused, before the signature.
    @Test func aNonCanonicalEnvelopeIsRefused() {
        let body = Self.body(seq: 1)
        let frame = Self.text(body)
        let text = String(decoding: frame, as: UTF8.self)
        func refused(_ changed: String) -> DeviceProof.Refusal? { Self.refusal(Self.check(Array(changed.utf8))) }
        // Escapes other than \" and \\ (each a valid JSON spelling of a body byte).
        #expect(refused(text.replacingOccurrences(of: #"\"v\""#, with: "\u{5C}u0022v\u{5C}u0022")) == .nonCanonical)
        let slash = Self.body(seq: 1, text: "a/b")
        #expect(refused(String(decoding: Self.text(slash), as: UTF8.self).replacingOccurrences(of: "a/b", with: #"a\/b"#)) == .nonCanonical)
        #expect(refused(text.replacingOccurrences(of: "hello", with: "hell\u{5C}u006f")) == .nonCanonical)
        // The signature's spare bits: the last of 86 characters carries 2 bits of the 64th byte and 4 that must be zero.
        let sig = Array(frame[(frame.count - 88)..<(frame.count - 2)])
        let last = sig[85]
        let sextet = DeviceProof.sextet(last)!
        #expect(sextet & 0x0F == 0)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        var spare = frame
        spare[frame.count - 3] = alphabet[Int(sextet | 0x01)]
        #expect(Self.refusal(Self.check(spare)) == .nonCanonical)
        // Padding, or the standard alphabet's characters, aren't base64url's unpadded form.
        var padded = frame
        padded.insert(UInt8(ascii: "="), at: frame.count - 2)
        #expect(Self.refusal(Self.check(padded)) == .malformed)
        var plus = frame
        plus[frame.count - 10] = UInt8(ascii: "+")
        #expect(Self.refusal(Self.check(plus)) == .malformed)
        // The fields in another order, with spaces, another version or kind, or a field more: not the envelope.
        for other in [text.replacingOccurrences(of: #"{"v":1,"kind":"signed","#, with: #"{"kind":"signed","v":1,"#),
                      text.replacingOccurrences(of: #"{"v":1,"kind""#, with: #"{"v": 1,"kind""#),
                      text.replacingOccurrences(of: #"{"v":1,"#, with: #"{"v":2,"#),
                      text.replacingOccurrences(of: #""kind":"signed""#, with: #""kind":"Signed""#),
                      text.replacingOccurrences(of: #""body":"#, with: #""body2":"#),
                      " " + text] {
            #expect(refused(other) == .notSigned, "\(other)")
        }
        // After the body: two bodies, a field between, or the signature's name changed.
        #expect(refused(text.replacingOccurrences(of: #"","sig":""#, with: #"","body":"x","sig":""#)) == .malformed)
        #expect(refused(text.replacingOccurrences(of: #"","sig":""#, with: #"", "sig":""#)) == .malformed)
        #expect(refused(text.replacingOccurrences(of: #"","sig":""#, with: #"","sig2":""#)) == .malformed)
        // A raw control byte in the body (JSON allows none in a string).
        #expect(refused(text.replacingOccurrences(of: "hello", with: "hel\nlo")) == .malformed)
        #expect(refused(text.replacingOccurrences(of: "hello", with: "hel\u{7}lo")) == .malformed)
        // A seq with a leading zero (signed, so the body's own rule refuses it).
        #expect(Self.refusal(Self.signedBody(#"{"v":1,"seq":01,"id":"1"}"#)) == .nonCanonical)
        #expect(Self.refusal(Self.signedBody(#"{"v":1,"seq":0,"id":"1"}"#)) == .nonCanonical)
    }

    /// A signed body must still be one object by the body's grammar, begun by its version and seq: the page holds the
    /// key, so these show the parse is strict, not that a stranger could send them.
    @Test func aSignedBodyOutsideTheGrammarIsRefused() {
        let bodies: [(String, DeviceProof.Refusal)] = [
            (#"{"seq":1,"v":1,"id":"1"}"#, .bodyStart),
            (#"{"v":1,"seq":1}"#, .bodyStart),
            (#"{"v":1,"seq":-1,"id":"1"}"#, .bodyStart),
            (#"{"v":1,"seq":1.0,"id":"1"}"#, .bodyStart),
            (#"{"v":1,"seq":"1","id":"1"}"#, .bodyStart),
            (#"{"v":1, "seq":1,"id":"1"}"#, .bodyStart),
            (#"[{"v":1,"seq":1,"id":"1"}]"#, .bodyStart),
            (#"{"v":1,"seq":1,"id":"1"}{"v":1}"#, .body),
            (#"{"v":1,"seq":1,"id":"1"} "#, .body),
            (#"{"v":1,"seq":1,"id": "1"}"#, .body),
            (#"{"v":1,"seq":1,"id":"1",}"#, .body),
            (#"{"v":1,"seq":1,"id":"1""#, .body),
            (#"{"v":1,"seq":1,"n":NaN}"#, .body),
            (#"{"v":1,"seq":1,"n":01}"#, .body),
            (#"{"v":1,"seq":1,"n":1.}"#, .body),
            (#"{"v":1,"seq":1,"n":+1}"#, .body),
            (#"{"v":1,"seq":1,"n":tru}"#, .body),
            (#"{"v":1,"seq":1,"s":'x'}"#, .body),
            (#"{"v":1,"seq":1,"s":"\x"}"#, .body),
            (#"{"v":1,"seq":1,"s":"\u12"}"#, .body),
            (#"{"v":1,"seq":1,"s":""# + Self.u + #"d800"}"#, .body),
            (#"{"v":1,"seq":1,"s":""# + Self.u + "dc00" + Self.u + #"d800"}"#, .body),
            (#"{"v":1,"seq":1,"s":""# + Self.u + "d800" + Self.u + #"0041"}"#, .body),
            (#"{"v":1,"seq":1,"k"# + Self.u + #"0069nd":"send"}"#, .body),
            (#"{"v":1,"seq":1,"kind":"send","kind":"status"}"#, .duplicateName),
            (#"{"v":1,"seq":1,"seq":2,"id":"1"}"#, .duplicateName),
            (#"{"v":1,"seq":1,"v":1,"id":"1"}"#, .duplicateName),
            (#"{"v":1,"seq":1,"args":{"session":"a","session":"b"}}"#, .duplicateName),
            (#"{"v":1,"seq":1,"args":{"items":[{"card":"a"},{"card":"b","card":"c"}]}}"#, .duplicateName),
        ]
        for (body, refusal) in bodies {
            #expect(Self.refusal(Self.signedBody(body)) == refusal, "\(body)")
        }
        // Two names a Swift decoder takes as one key (String compares by canonical equivalence) are one name twice:
        // "K" and the Kelvin sign; "é" composed and decomposed. Else the later decoder would keep either value.
        for (first, second) in [("K", "\u{212A}"), ("\u{E9}", "e\u{301}")] {
            #expect(Array(first.utf8) != Array(second.utf8))
            #expect(Self.refusal(Self.signedBody(#"{"v":1,"seq":1,"args":{""# + first + #"":"a",""# + second + #"":"b"}}"#)) == .duplicateName, "\(second)")
        }
        // What JSON allows, and the grammar takes: every value form, a paired surrogate, escapes in a value, a name
        // repeated in two different objects.
        for body in [#"{"v":1,"seq":1,"a":[],"b":{},"c":[1,-0,0.5,-1.5e+3,2E-2,true,false,null,"x"],"d":"\"\\\/\b\f\n\r\té😀"}"#,
                     #"{"v":1,"seq":1,"d":""# + Self.u + "00e9" + Self.u + "d83d" + Self.u + "de00" + Self.u + #"001f"}"#,
                     #"{"v":1,"seq":1,"args":{"items":[{"card":"a"},{"card":"b"}]}}"#] {
            #expect((try? Self.signedBody(body).get())?.body == Array(body.utf8), "\(body)")
        }
        // Invalid UTF-8: a lone continuation byte, an overlong slash, a surrogate encoded directly, a cut sequence.
        for bad: [UInt8] in [[0x80], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xE2, 0x9C]] {
            let body = Array(#"{"v":1,"seq":1,"s":""#.utf8) + bad + Array(#""}"#.utf8)
            #expect(Self.refusal(Self.check(Self.text(body))) == .body, "\(bad)")
        }
    }

    @Test func aBodyNestedPastTheLimitIsRefused() {
        func nested(_ depth: Int) -> String {
            // The body's own object is level 1; each "a" nests one more.
            #"{"v":1,"seq":1,"a":"# + String(repeating: #"{"a":"#, count: depth - 1) + "1" + String(repeating: "}", count: depth)
        }
        #expect((try? Self.signedBody(nested(DeviceProof.depthAtMost)).get()) != nil)
        #expect(Self.refusal(Self.signedBody(nested(DeviceProof.depthAtMost + 1))) == .tooDeep)
        let arrays = #"{"v":1,"seq":1,"a":"# + String(repeating: "[", count: DeviceProof.depthAtMost) + String(repeating: "]", count: DeviceProof.depthAtMost) + "}"
        #expect(Self.refusal(Self.signedBody(arrays)) == .tooDeep)
        // Far past it (a stack's worth): refused, and nothing recurses that deep.
        let deep = #"{"v":1,"seq":1,"a":"# + String(repeating: "[", count: 20_000) + String(repeating: "]", count: 20_000) + "}"
        #expect(Self.refusal(Self.signedBody(deep)) == .tooDeep)
    }

    @Test func anEmptyPayloadIsRefused() {
        let empty = DeviceProof.textFrame(body: [], signature: Self.sign(DeviceProof.signedBytes(body: [], on: Self.conn)))
        #expect(Self.refusal(Self.check(empty)) == .empty)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 1, payload: []))) == .empty)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 1, kind: .resize, payload: []))) == .truncated)
        #expect(Self.refusal(Self.checkTerminal([])) == .truncated)
        #expect(Self.refusal(Self.check([])) == .truncated)
    }

    @Test func aTerminalFrameOfAnotherInnerTypeIsRefused() {
        for type: UInt8 in [0, 2, 4, 5, 6, 0xFF] {
            var frame = Self.terminal(seq: 1)
            frame[DeviceProof.terminalHeaderBytes - 1] = type
            #expect(Self.refusal(Self.checkTerminal(frame)) == .terminalType, "\(type)")
        }
    }

    // MARK: Signatures

    @Test func aSignatureByAnotherKeyIsRefused() {
        #expect(Self.refusal(Self.check(Self.text(Self.body(seq: 1), by: Self.otherKey))) == .badSignature)
        #expect(Self.refusal(Self.checkTerminal(Self.terminal(seq: 1, by: Self.otherKey))) == .badSignature)
        // Zero, or the curve's order, as r or s: no signature.
        let n = Self.hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
        let body = Self.body(seq: 1)
        for signature in [[UInt8](repeating: 0, count: 64), n + n, [UInt8](repeating: 0xFF, count: 64), Array(repeating: 0, count: 32) + n] {
            #expect(Self.refusal(Self.check(DeviceProof.textFrame(body: body, signature: signature))) == .badSignature)
        }
    }

    /// The design doesn't require a low `s` (WebCrypto doesn't make one): the other signature of a frame, (r, n − s),
    /// signs the same bytes, so it is the same frame, and the sequence takes it once.
    @Test func aMalleatedSignatureGainsNothing() {
        let body = Self.body(seq: 1)
        let signature = Self.sign(DeviceProof.signedBytes(body: body, on: Self.conn))
        let twin = Array(signature[0..<32]) + Self.orderMinus(Array(signature[32..<64]))
        #expect(twin != signature)
        let original = DeviceProof.textFrame(body: body, signature: signature), malleated = DeviceProof.textFrame(body: body, signature: twin)
        #expect(Self.check(original) == .success(.init(seq: 1, body: body)))
        #expect(Self.check(malleated) == .success(.init(seq: 1, body: body)), "CryptoKit takes either s: the twin is the same frame")
        #expect(Self.refusal(Self.check(malleated, next: 2)) == .seqRepeated)
        #expect(Self.refusal(Self.check(original, next: 2)) == .seqRepeated)
        // On another connection the twin is as foreign as the original.
        #expect(Self.refusal(Self.check(malleated, on: Self.connection("another"))) == .badSignature)
    }

    /// n − s for P-256's order n, big-endian.
    static func orderMinus(_ s: [UInt8]) -> [UInt8] {
        let n = hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
        var out = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for i in (0..<32).reversed() {
            var digit = Int(n[i]) - Int(s[i]) - borrow
            borrow = digit < 0 ? 1 : 0
            if digit < 0 { digit += 256 }
            out[i] = UInt8(digit)
        }
        return out
    }

    @Test func aConnectionNeedsItsNonceAndAPlainOrigin() {
        let nonce = Self.conn.conn
        #expect(DeviceProof.Connection(conn: Array(nonce.prefix(31)), origin: Self.localhost) == nil)
        #expect(DeviceProof.Connection(conn: nonce + [0], origin: Self.localhost) == nil)
        for origin in ["", "http://localhost:47830\n", "http://local host:47830", "http://lócalhost:47830", "http://localhost:47830\u{0}"] {
            #expect(DeviceProof.Connection(conn: nonce, origin: origin) == nil, "\(origin)")
        }
        #expect(Self.conn.connText == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    }

    // MARK: Fuzz

    /// SplitMix64: the same mutations each run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func mutate(_ bytes: [UInt8], _ random: inout Seeded) -> [UInt8] {
        var out = bytes
        for _ in 0..<Int.random(in: 1...3, using: &random) {
            let at = out.isEmpty ? 0 : Int.random(in: 0..<out.count, using: &random)
            switch Int.random(in: 0..<7, using: &random) {
            case 0 where !out.isEmpty: out[at] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &random)
            case 1 where !out.isEmpty: out[at] = UInt8.random(in: 0...255, using: &random)
            case 2: out.insert(UInt8.random(in: 0...255, using: &random), at: at)
            case 3 where !out.isEmpty: out.remove(at: at)
            case 4: out = Array(out.prefix(at))
            case 5 where !out.isEmpty:
                let end = Int.random(in: at..<out.count, using: &random)
                out.insert(contentsOf: out[at...end], at: Int.random(in: 0...out.count, using: &random))
            case 6 where out.count > 1:
                out.swapAt(at, Int.random(in: 0..<out.count, using: &random))
            default: out.append(UInt8(ascii: "\""))
            }
        }
        return out
    }

    /// Thousands of random mutations of a valid frame of each kind, and of either kind fed to the other's check:
    /// none passes, none crashes.
    @Test func randomMutationsOfAValidFrameNeverPass() {
        var random = Seeded(state: 0xD0E5_1F00_0000_0001)
        let text = Self.text(Self.body(seq: 1, text: #"a \"q\" \\ é ✓"#))
        let input = Self.terminal(seq: 1), resize = Self.terminal(seq: 1, kind: .resize, payload: [0, 0x78, 0, 0x28])
        var refusals: [DeviceProof.Refusal: Int] = [:]
        for round in 0..<3_000 {
            let mutated = Self.mutate(text, &random)
            guard mutated != text else { continue }
            switch Self.check(mutated) {
            case .success: Issue.record("round \(round): a mutated text frame passed: \(String(decoding: mutated, as: UTF8.self))")
            case .failure(let refusal): refusals[refusal, default: 0] += 1
            }
            #expect(Self.refusal(Self.checkTerminal(mutated)) != nil)
        }
        for (frame, rounds) in [(input, 1_500), (resize, 1_500)] {
            for round in 0..<rounds {
                let mutated = Self.mutate(frame, &random)
                guard mutated != frame else { continue }
                switch Self.checkTerminal(mutated) {
                case .success: Issue.record("round \(round): a mutated terminal frame passed: \(mutated)")
                case .failure(let refusal): refusals[refusal, default: 0] += 1
                }
                #expect(Self.refusal(Self.check(mutated)) != nil)
            }
        }
        // The mutations reached the layout's checks as well as the signature's.
        for reason in [DeviceProof.Refusal.badSignature, .truncated, .trailingBytes, .malformed, .notSigned] {
            #expect(refusals[reason, default: 0] > 0, "no mutation was refused as \(reason): \(refusals)")
        }
    }

    /// The body's grammar under hostile bytes: random mutations of a body, each signed with the test's key, so only
    /// the body's own rules stand between it and the server. Whatever passes is exactly the bytes signed, and a
    /// standard JSON reader agrees it is one object with that seq.
    @Test func randomSignedBodiesPassOnlyAsTheObjectTheySay() {
        var random = Seeded(state: 0xB0D1_E500_0000_0002)
        let text: String = #"{"v":1,"seq":1,"id":"1","kind":"send","args":{"session":"s-1","n":[1,-2.5e3,true,null],"t":"\"x\" é "# + Self.u + #"00e9"}}"#
        let body = Array(text.utf8)
        var passed = 0
        for round in 0..<2_000 {
            let mutated = Self.mutate(body, &random)
            let result = Self.check(Self.text(mutated))
            guard case .success(let request) = result else { continue }
            passed += 1
            #expect(request.body == mutated, "round \(round)")
            let object = try? JSONSerialization.jsonObject(with: Data(mutated)) as? [String: Any]
            #expect((object?["seq"] as? NSNumber)?.uint64Value == request.seq, "round \(round): \(String(decoding: mutated, as: UTF8.self))")
        }
        #expect(passed > 0, "no mutation kept the grammar: the check on what passes ran on nothing")
    }

    // MARK: Vectors

    /// The fixed vectors slice 5's `devicekey.js` must reproduce: for each, the signed bytes it builds from the origin,
    /// the connection's nonce and the frame's parts, and the frame it assembles around the signature given (ECDSA's
    /// signatures are random, so a module's own differ: it checks these verify under the public key, and that its
    /// signed bytes and frames equal these). The key: scalar `d` and public key below (the scalar is SHA-256 of
    /// "vibeswitcher DeviceProof vector key"; `x963` imports in WebCrypto as `raw`, `spki` as `spki`).
    static let vectorScalar = "6be7b03f9a2135b0b6700ba6abc79ca1f2246f2c90d6a9e0e928ff09c6a9ba11"
    static let vectorX963 = "040c1a46ac59324f528c12db68087046fe392aec73bac26368f2e14627f7eff4b7e2d91c5d5c6218fabf7f5bc25ee470da2477862ca6e508f0b2102965cee61ad1"
    static let vectorSPKI = "3059301306072a8648ce3d020106082a8648ce3d030107034200040c1a46ac59324f528c12db68087046fe392aec73bac26368f2e14627f7eff4b7e2d91c5d5c6218fabf7f5bc25ee470da2477862ca6e508f0b2102965cee61ad1"

    struct TextVector {
        var origin: String, conn: String, connText: String, seq: UInt64, body: String, signed: String, sig: String, frame: String
    }

    struct TerminalVector {
        var origin: String, conn: String, stream: UInt32, seq: UInt64, kind: DeviceProof.Terminal.Kind, payload: String, signed: String, sig: String, frame: String
    }

    static let textVectors = [
        // Body: {"v":1,"seq":1,"id":"1","kind":"send","action":"6f1d2c3b-0000-4000-8000-000000000001","args":{"session":"s-1","text":"say \"hi\" \\ café ✓"}}
        TextVector(origin: "http://localhost:47830", conn: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                   connText: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", seq: 1,
                   body: "7b2276223a312c22736571223a312c226964223a2231222c226b696e64223a2273656e64222c22616374696f6e223a2236663164326333622d303030302d343030302d383030302d303030303030303030303031222c2261726773223a7b2273657373696f6e223a22732d31222c2274657874223a22736179205c2268695c22205c5c20636166c3a920e29c93227d7d",
                   signed: "7669626573776974636865722d6672616d652d76310a687474703a2f2f6c6f63616c686f73743a34373833300a41414543417751464267634943516f4c4441304f4478415245684d554652595847426b61477877644868380a7b2276223a312c22736571223a312c226964223a2231222c226b696e64223a2273656e64222c22616374696f6e223a2236663164326333622d303030302d343030302d383030302d303030303030303030303031222c2261726773223a7b2273657373696f6e223a22732d31222c2274657874223a22736179205c2268695c22205c5c20636166c3a920e29c93227d7d",
                   sig: "c95216078aa47f56bac232d128cd60156b6b0b82454c7b292d442aa0d45029b81dda93ff47deef08807111664d519de399ba2bff0ed7f0094726a1eef9631ec9",
                   frame: "7b2276223a312c226b696e64223a227369676e6564222c22626f6479223a227b5c22765c223a312c5c227365715c223a312c5c2269645c223a5c22315c222c5c226b696e645c223a5c2273656e645c222c5c22616374696f6e5c223a5c2236663164326333622d303030302d343030302d383030302d3030303030303030303030315c222c5c22617267735c223a7b5c2273657373696f6e5c223a5c22732d315c222c5c22746578745c223a5c22736179205c5c5c2268695c5c5c22205c5c5c5c20636166c3a920e29c935c227d7d222c22736967223a22795649574234716b66316136776a4c524b4d31674657747243344a46544873704c5551716f4e52514b6267643270505f523937764349427845575a4e555a336a6d626f725f77375838416c484a7148752d574d657951227d"),
        // Body: {"v":1,"seq":7,"id":"12","kind":"chat.page","args":{"session":"s-2","limit":200}}; conn SHA-256 of "vibeswitcher DeviceProof vector conn 2".
        TextVector(origin: "https://node.example.ts.net:47830", conn: "649f918f28362df4d7b7ffc45945bfef58d8c295a5103a0e373cd2033ef33ffd",
                   connText: "ZJ-Rjyg2LfTXt__EWUW_71jYwpWlEDoONzzSAz7zP_0", seq: 7,
                   body: "7b2276223a312c22736571223a372c226964223a223132222c226b696e64223a22636861742e70616765222c2261726773223a7b2273657373696f6e223a22732d32222c226c696d6974223a3230307d7d",
                   signed: "7669626573776974636865722d6672616d652d76310a68747470733a2f2f6e6f64652e6578616d706c652e74732e6e65743a34373833300a5a4a2d526a7967324c665458745f5f455755575f37316a597770576c45446f4f4e7a7a53417a377a505f300a7b2276223a312c22736571223a372c226964223a223132222c226b696e64223a22636861742e70616765222c2261726773223a7b2273657373696f6e223a22732d32222c226c696d6974223a3230307d7d",
                   sig: "805c94c5cf3b4b937c70cea2991ec562cf9da95419230c5e7ec9c10fb50c2422268ddff1ddecacb5d2a1a5cb89621569c2961b96f29c79691cd4ff594fc25adf",
                   frame: "7b2276223a312c226b696e64223a227369676e6564222c22626f6479223a227b5c22765c223a312c5c227365715c223a372c5c2269645c223a5c2231325c222c5c226b696e645c223a5c22636861742e706167655c222c5c22617267735c223a7b5c2273657373696f6e5c223a5c22732d325c222c5c226c696d69745c223a3230307d7d222c22736967223a22674679557863383753354e38634d36696d52374659732d647156515a4977786566736e424437554d4a43496d6a645f783365797374644b687063754a59685670777059626c764b6365576b633150395a54384a613377227d"),
    ]

    static let terminalVectors = [
        // Input "ls\r" on stream 3, seq 2.
        TerminalVector(origin: "http://localhost:47830", conn: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", stream: 3, seq: 2, kind: .input,
                       payload: "6c730d",
                       signed: "7669626573776974636865722d7465726d2d76310a687474703a2f2f6c6f63616c686f73743a34373833300a41414543417751464267634943516f4c4441304f4478415245684d554652595847426b61477877644868380a000000030000000000000002016c730d",
                       sig: "f748cb321aa1f859a4b201cd3f2003e73fbca4ddc83e3ae3b12facd9fdc1366b9b3df390ed80cebadd1cdb57f2cca5d0d4ce0cdad2d7106dc9d0cda369c3ab15",
                       frame: "06000000030000000000000002f748cb321aa1f859a4b201cd3f2003e73fbca4ddc83e3ae3b12facd9fdc1366b9b3df390ed80cebadd1cdb57f2cca5d0d4ce0cdad2d7106dc9d0cda369c3ab15016c730d"),
        // A resize to 120 × 40 on stream 3, seq 3.
        TerminalVector(origin: "http://localhost:47830", conn: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", stream: 3, seq: 3, kind: .resize,
                       payload: "00780028",
                       signed: "7669626573776974636865722d7465726d2d76310a687474703a2f2f6c6f63616c686f73743a34373833300a41414543417751464267634943516f4c4441304f4478415245684d554652595847426b61477877644868380a0000000300000000000000030300780028",
                       sig: "7225d6731dedbaff2ff9c01777a96a022924ab7466d8daf9a0e2aa177eac95fd14879795a5eafb6cece389012a311b559d4edde32889808cc067924afe038996",
                       frame: "060000000300000000000000037225d6731dedbaff2ff9c01777a96a022924ab7466d8daf9a0e2aa177eac95fd14879795a5eafb6cece389012a311b559d4edde32889808cc067924afe0389960300780028"),
    ]

    @Test func theVectorsAreTheBytesThePageMakes() throws {
        let key = try P256.Signing.PublicKey(x963Representation: Self.hex(Self.vectorX963))
        #expect(Array(key.derRepresentation) == Self.hex(Self.vectorSPKI))
        #expect(Array(Self.key.publicKey.x963Representation) == Self.hex(Self.vectorX963))
        #expect(Array(Self.key.rawRepresentation) == Self.hex(Self.vectorScalar))
        for vector in Self.textVectors {
            let connection = try #require(DeviceProof.Connection(conn: Self.hex(vector.conn), origin: vector.origin))
            #expect(connection.connText == vector.connText)
            let body = Self.hex(vector.body)
            #expect(DeviceProof.signedBytes(body: body, on: connection) == Self.hex(vector.signed))
            let frame = DeviceProof.textFrame(body: body, signature: Self.hex(vector.sig))
            #expect(frame == Self.hex(vector.frame))
            #expect(DeviceProof.text(frame, on: connection, next: vector.seq, key: key) == .success(.init(seq: vector.seq, body: body)))
        }
        for vector in Self.terminalVectors {
            let connection = try #require(DeviceProof.Connection(conn: Self.hex(vector.conn), origin: vector.origin))
            let payload = Self.hex(vector.payload)
            #expect(DeviceProof.signedBytes(stream: vector.stream, seq: vector.seq, kind: vector.kind, payload: payload, on: connection) == Self.hex(vector.signed))
            let frame = DeviceProof.terminalFrame(stream: vector.stream, seq: vector.seq, kind: vector.kind, payload: payload, signature: Self.hex(vector.sig))
            #expect(frame == Self.hex(vector.frame))
            #expect(DeviceProof.terminal(frame, on: connection, next: vector.seq, key: key)
                    == .success(.init(stream: vector.stream, seq: vector.seq, kind: vector.kind, payload: payload)))
        }
    }
}
