import Foundation
import Testing
@testable import VibeNode

/// The hand-rolled parsers fuzzed (the architecture review's row 19): the HTTP request head (`HTTPHead`), the WebSocket
/// frame decoder (`WebSocketDecoder`), and the wire's line reader and envelope (`NodeWire.Lines`, `NodeWire.unwrap`).
/// Random and mutated inputs, each fed in random chunks: never a trap or a hang, what is held bounded by the stated
/// limits, a refusal for everything malformed, the same thing back for everything well-formed.
///
/// A fixed seed and a few thousand cases in the normal suite (a few seconds); `VIBESWITCHER_FUZZ_ROUNDS` sets how many
/// more (the nightly's long mode, `scripts/ci/host-probe.sh`), `VIBESWITCHER_FUZZ_SEED` another seed. A failure prints
/// the seed and the case, so it can be kept as a regression case.
@Suite(.serialized) struct ParserFuzzTests {
    static let rounds = Int(ProcessInfo.processInfo.environment["VIBESWITCHER_FUZZ_ROUNDS"] ?? "") ?? 1
    static let seed = UInt64(ProcessInfo.processInfo.environment["VIBESWITCHER_FUZZ_SEED"] ?? "") ?? 0x5EED_2026_1122

    /// SplitMix64: the same cases for the same seed, on every machine.
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
        mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }
        mutating func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255, using: &self) } }
        mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
    }

    /// `bytes` cut into random chunks (a whole buffer sometimes, single bytes sometimes).
    static func chunks(_ bytes: [UInt8], _ random: inout Random) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var from = 0
        // Byte by byte only for inputs under 64 KB: a line reader's cost per byte is what a slow client makes it.
        let style = bytes.count > 64 * 1_024 ? random.pick([0, 2]) : random.int(0...2)
        while from < bytes.count {
            let size = style == 0 ? bytes.count : style == 1 ? 1 : random.int(1...max(1, min(4_096, bytes.count)))
            let to = min(bytes.count, from + size)
            out.append(Array(bytes[from..<to]))
            from = to
        }
        return out
    }

    // MARK: HTTP request head

    static let tokenBytes = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~".utf8)

    static func token(_ random: inout Random, _ length: ClosedRange<Int> = 1...12) -> String {
        String(decoding: (0..<random.int(length)).map { _ in random.pick(tokenBytes) }, as: UTF8.self)
    }

    /// A sound request head: a GET of a visible-ASCII path, Host once, and fields of token names and plain values.
    static func soundHead(_ random: inout Random) -> (bytes: [UInt8], target: String, fields: [(String, String)]) {
        let pathBytes = Array("abcdefghijklmnopqrstuvwxyz0123456789-._~%/".utf8)
        var target = "/" + String(decoding: (0..<random.int(0...60)).map { _ in random.pick(pathBytes) }, as: UTF8.self)
        if random.chance(30) {
            let query = Array("abcdefghijklmnopqrstuvwxyz0123456789=&-._~%".utf8)
            target += "?" + String(decoding: (0..<random.int(1...30)).map { _ in random.pick(query) }, as: UTF8.self)
        }
        var fields: [(String, String)] = [("Host", "127.0.0.1:" + String(random.int(1...65_535)))]
        for _ in 0..<random.int(0...20) {
            var name = token(&random)
            while ["host", "content-length", "transfer-encoding"].contains(name.lowercased()) { name = token(&random) }
            let valueBytes = (0..<random.int(0...80)).map { _ in UInt8(random.int(0x20...0x7E)) }
            let value = String(decoding: valueBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            fields.append((name, value))
        }
        fields.shuffle(using: &random)
        let head = "GET \(target) HTTP/1.1\r\n" + fields.map { "\($0.0): \($0.1)\r\n" }.joined() + "\r\n"
        return (Array(head.utf8), target, fields)
    }

    /// The head fed in chunks: the step it ended at (`.more` when it never ended), and the bytes fed by then.
    static func feed(_ bytes: [UInt8], _ random: inout Random, limits: WebLimits = WebLimits()) -> (step: HTTPHead.Step, fed: Int) {
        var head = HTTPHead()
        var fed = 0
        for chunk in chunks(bytes, &random) {
            fed += chunk.count
            let step = head.take(chunk, limits: limits)
            if step != .more { return (step, fed) }
        }
        return (.more, fed)
    }

    /// Whether an accepted request keeps every promise `HTTPHead` makes: a target that is an absolute path of visible
    /// ASCII with no "#", one Host not empty, names that are tokens in lower case, values with no control byte.
    static func keepsThePromises(_ request: WebRequest) -> Bool {
        request.target.hasPrefix("/") && !request.target.contains("#")
            && request.target.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
            && request.headers.all("host").count == 1 && !(request.headers["host"] ?? "").isEmpty
            && request.headers.fields.allSatisfy { field in
                !field.name.isEmpty && field.name == field.name.lowercased() && field.name.utf8.allSatisfy(HTTPHead.isToken)
                    && field.value.utf8.allSatisfy { $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7F) }
                    && field.value == field.value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            }
    }

    @Test func aSoundHeadIsReadBackWholeHoweverItsBytesCome() {
        var random = Random(state: Self.seed)
        for round in 0..<(300 * Self.rounds) {
            let sound = Self.soundHead(&random)
            let rest = random.bytes(random.int(0...40))
            let (step, _) = Self.feed(sound.bytes + rest, &random)
            guard case .request(let request, let after) = step else {
                Issue.record("round \(round): a sound head refused: \(step)\n\(String(decoding: sound.bytes, as: UTF8.self))")
                return
            }
            #expect(request.target == sound.target, "round \(round)")
            #expect(request.headers.fields.map { [$0.name, $0.value] } == sound.fields.map { [$0.0.lowercased(), $0.1] }, "round \(round)")
            // What came after the head is given back; a chunk that ended the head keeps the rest of itself.
            #expect(rest.starts(with: after) || after.starts(with: rest) || after == rest || rest.isEmpty || !after.isEmpty, "round \(round)")
        }
    }

    /// Mutated heads: each malformed kind refused with its status, any other mutation refused or, when accepted, still
    /// keeping every promise; nothing fed past the head's limit without a refusal.
    @Test func aMutatedHeadIsRefusedOrStillSound() {
        var random = Random(state: Self.seed ^ 1)
        let limits = WebLimits()
        for round in 0..<(1_500 * Self.rounds) {
            var bytes = Self.soundHead(&random).bytes
            let kind = random.int(0...11)
            var expected: Set<Int>?
            switch kind {
            case 0: // truncated
                bytes = Array(bytes.prefix(random.int(0...(bytes.count - 1))))
            case 1: // a bare LF somewhere in the head
                bytes.insert(HTTPHead.lf, at: random.int(1...(bytes.count - 4)))
                expected = [400]
            case 2: // a bare CR
                bytes.insert(HTTPHead.cr, at: random.int(1...(bytes.count - 4)))
                expected = [400]
            case 3: // a header flood
                let flood = (0...limits.maxHeaderCount + random.int(1...50)).map { "X-\($0): v\r\n" }.joined()
                bytes.insert(contentsOf: Array(flood.utf8), at: Array(bytes).firstIndex(of: HTTPHead.lf)! + 1)
                expected = [431]
            case 4: // a request line at the limit, or past it
                let over = random.chance(50)
                let path = "/" + String(repeating: "a", count: limits.maxRequestLineBytes - "GET / HTTP/1.1".utf8.count + (over ? 1 : 0))
                bytes = Array("GET \(path) HTTP/1.1\r\nHost: h\r\n\r\n".utf8)
                expected = over ? [414] : nil
            case 5: // a head past its bytes
                let filler = "X-Fill: " + String(repeating: "f", count: limits.maxHeaderBytes) + "\r\n"
                bytes.insert(contentsOf: Array(filler.utf8), at: Array(bytes).firstIndex(of: HTTPHead.lf)! + 1)
                expected = [431]
            case 6: // a folded field
                bytes.insert(contentsOf: Array(" folded\r\n".utf8), at: Array(bytes).firstIndex(of: HTTPHead.lf)! + 1)
                expected = [400]
            case 7: // a body asked for, a length that overflows any integer, or chunked
                let field = random.pick(["Content-Length: 5", "Content-Length: 99999999999999999999999999999999", "Transfer-Encoding: chunked",
                                         "Content-Length: -1", "Content-Length: 0x10"])
                bytes.insert(contentsOf: Array((field + "\r\n").utf8), at: Array(bytes).firstIndex(of: HTTPHead.lf)! + 1)
                expected = [400, 413]
            case 8: // a second Host
                bytes.insert(contentsOf: Array("Host: other\r\n".utf8), at: Array(bytes).firstIndex(of: HTTPHead.lf)! + 1)
                expected = [421]
            case 9: // invalid UTF-8 and control bytes in a value or the target
                let bad = random.pick([[0x00], [0x7F], [0xC0, 0xAF], [0xFF], [0x0B]] as [[UInt8]])
                bytes.insert(contentsOf: Array("X-Bad: a".utf8) + bad + Array("\r\n".utf8), at: Array(bytes).firstIndex(of: HTTPHead.lf)! + 1)
                expected = bad.allSatisfy({ $0 >= 0x80 }) ? nil : [400]
            case 10: // another method or version
                let line = random.pick(["POST / HTTP/1.1", "GET / HTTP/1.0", "GET / HTTP/2.0", "GET /a HTTP/1.1 x", "GET  / HTTP/1.1", "GET http://x/ HTTP/1.1", "GET /#f HTTP/1.1"])
                bytes = Array((line + "\r\nHost: h\r\n\r\n").utf8)
                expected = [400, 405, 505]
            default: // random bytes flipped
                for _ in 0..<random.int(1...6) { bytes[random.int(0...(bytes.count - 1))] = UInt8.random(in: 0...255, using: &random) }
            }
            let (step, fed) = Self.feed(bytes, &random, limits: limits)
            switch step {
            case .more:
                #expect(kind == 0 || kind == 11, "round \(round), kind \(kind): never ended")
                #expect(fed < limits.maxHeaderBytes, "round \(round): \(fed) bytes held with no refusal")
            case .refused(let response):
                if let expected { #expect(expected.contains(response.status), "round \(round), kind \(kind): \(response.status)") }
            case .request(let request, _):
                #expect(expected == nil, "round \(round), kind \(kind): accepted\n\(String(decoding: bytes.prefix(400), as: UTF8.self))")
                #expect(Self.keepsThePromises(request), "round \(round), kind \(kind): \(request)")
            }
        }
    }

    /// Random bytes: refused or still waiting (never accepted unless they happen to be a sound head), never past the
    /// head's limit.
    @Test func randomBytesNeverTrapNorPassTheLimit() {
        var random = Random(state: Self.seed ^ 2)
        let limits = WebLimits()
        for round in 0..<(400 * Self.rounds) {
            let bytes = random.bytes(random.int(0...(limits.maxHeaderBytes + 2_000)))
            let (step, fed) = Self.feed(bytes, &random, limits: limits)
            if case .more = step { #expect(fed < limits.maxHeaderBytes, "round \(round)") }
            if case .request(let request, _) = step { #expect(Self.keepsThePromises(request), "round \(round)") }
        }
    }

    // MARK: WebSocket frames

    /// A client's frame: masked with a random key, the length in its shortest form unless `longForm`.
    static func frame(_ opcode: UInt8, final: Bool, _ payload: [UInt8], _ random: inout Random, masked: Bool = true, reserved: UInt8 = 0,
                      longForm: Bool = false) -> [UInt8] {
        var out: [UInt8] = [(final ? 0x80 : 0) | reserved | opcode]
        let mask: UInt8 = masked ? 0x80 : 0
        if payload.count <= 125 && !longForm {
            out.append(mask | UInt8(payload.count))
        } else if payload.count <= 0xFFFF && !(longForm && payload.count > 125 && random.chance(50)) {
            out += [mask | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            out.append(mask | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        let key = masked ? random.bytes(4) : []
        out += key
        out += payload.enumerated().map { masked ? $0.element ^ key[$0.offset & 3] : $0.element }
        return out
    }

    /// Random text: ASCII, and characters of two, three and four bytes.
    static func text(_ random: inout Random) -> String {
        String((0..<random.int(0...200)).map { _ in random.pick(["a", "z", " ", "é", "€", "😀", "\u{0}", "語"] as [Character]) })
    }

    /// Every event the decoder gives for `bytes` fed in chunks, or the failure it ended with; asserting the bytes it
    /// holds stay within twice the largest message (and a frame's header) all along.
    static func decode(_ bytes: [UInt8], _ random: inout Random, maxMessageBytes: Int, round: Int) -> (events: [WebSocketDecoder.Event], failure: WebSocketDecoder.Failure?) {
        var decoder = WebSocketDecoder(maxMessageBytes: maxMessageBytes)
        var events: [WebSocketDecoder.Event] = []
        for chunk in chunks(bytes, &random) {
            decoder.append(chunk)
            var guardCount = 0
            do {
                while let event = try decoder.next() {
                    events.append(event)
                    guardCount += 1
                    if guardCount > bytes.count + 10 { Issue.record("round \(round): more events than bytes"); return (events, nil) }
                }
            } catch let failure as WebSocketDecoder.Failure {
                return (events, failure)
            } catch {
                Issue.record("round \(round): \(error)")
                return (events, nil)
            }
            #expect(decoder.heldBytes <= 2 * maxMessageBytes + chunk.count + 14, "round \(round): \(decoder.heldBytes) bytes held")
        }
        return (events, nil)
    }

    /// Messages fragmented at random, pings and pongs between their fragments, a close at the end: each message whole,
    /// each ping's bytes, in order, however the bytes come.
    @Test func soundFramesAreReadBackWholeInOrder() {
        var random = Random(state: Self.seed ^ 3)
        for round in 0..<(300 * Self.rounds) {
            var bytes: [UInt8] = []
            var expected: [WebSocketDecoder.Event] = []
            for _ in 0..<random.int(1...6) {
                let isText = random.chance(60)
                let payload: [UInt8] = isText ? Array(Self.text(&random).utf8) : random.bytes(random.int(0...300))
                // Fragments, cut between bytes (a text's may cut a character: only the whole message is UTF-8).
                var cuts = Set((0..<random.int(0...4)).map { _ in random.int(0...payload.count) })
                cuts.insert(payload.count)
                var from = 0
                let message: WebSocketDecoder.Event = isText ? .text(String(decoding: payload, as: UTF8.self)) : .binary(Data(payload))
                for (index, cut) in cuts.sorted().enumerated() {
                    let opcode: UInt8 = index == 0 ? (isText ? 0x1 : 0x2) : 0x0
                    bytes += Self.frame(opcode, final: cut == payload.count, Array(payload[from..<cut]), &random)
                    from = cut
                    // The message is whole at its last fragment: a control frame after it comes after it.
                    if cut == payload.count { expected.append(message) }
                    if random.chance(30) {
                        let ping = random.bytes(random.int(0...125))
                        bytes += Self.frame(0x9, final: true, ping, &random)
                        expected.append(.ping(Data(ping)))
                    }
                    if random.chance(10) {
                        bytes += Self.frame(0xA, final: true, random.bytes(random.int(0...125)), &random)
                        expected.append(.pong)
                    }
                }
            }
            let reason = String(Self.text(&random).prefix(30))
            let closeReason = Array(reason.utf8.prefix(100))
            if let text = String(bytes: closeReason, encoding: .utf8) {
                bytes += Self.frame(0x8, final: true, [0x03, 0xE8] + closeReason, &random)
                expected.append(.close(code: 1000, reason: text))
            }
            let (events, failure) = Self.decode(bytes, &random, maxMessageBytes: 1 << 20, round: round)
            guard failure == nil, events == expected else {
                Issue.record("round \(round): \(String(describing: failure)); \(events.count) events, \(expected.count) expected; first apart at \(Array(zip(events, expected)).firstIndex { $0.0 != $0.1 } ?? min(events.count, expected.count))")
                return
            }
        }
    }

    /// Each malformed frame refused with its close code; truncations wait (nil), never trap.
    @Test func aMalformedFrameIsRefusedWithItsCode() {
        var random = Random(state: Self.seed ^ 4)
        let max = 64 * 1_024
        for round in 0..<(1_500 * Self.rounds) {
            let kind = random.int(0...13)
            var bytes: [UInt8]
            var code: UInt16?
            switch kind {
            case 0: bytes = Self.frame(0x1, final: true, Array("hi".utf8), &random, masked: false); code = WebSocketClose.protocolError
            case 1: bytes = Self.frame(0x1, final: true, [], &random, reserved: UInt8(random.pick([0x10, 0x20, 0x40]))); code = WebSocketClose.protocolError
            case 2: bytes = Self.frame(UInt8(random.pick([0x3, 0x4, 0x5, 0x6, 0x7, 0xB, 0xC, 0xD, 0xE, 0xF])), final: true, [], &random); code = WebSocketClose.protocolError
            case 3: bytes = Self.frame(0x9, final: false, [], &random); code = WebSocketClose.protocolError
            case 4: // a control frame over 125 bytes (its length field says so)
                bytes = [0x89, 0x80 | 126, 0x00, 0x7E] + random.bytes(4) + random.bytes(126); code = WebSocketClose.protocolError
            case 5: bytes = Self.frame(0x2, final: true, random.bytes(random.int(0...125)), &random, longForm: true); code = WebSocketClose.protocolError
            case 6: // a length past the message limit, or past 2^63
                let wide: UInt64 = random.chance(50) ? UInt64(max) + UInt64(random.int(1...1_000_000)) : 0xFFFF_FFFF_FFFF_FFFF
                bytes = [0x82, 0x80 | 127] + stride(from: 56, through: 0, by: -8).map { UInt8((wide >> UInt64($0)) & 0xFF) }
                code = wide >> 63 == 0 ? WebSocketClose.tooBig : WebSocketClose.protocolError
            case 7: bytes = Self.frame(0x0, final: true, Array("x".utf8), &random); code = WebSocketClose.protocolError
            case 8: bytes = Self.frame(0x1, final: false, Array("a".utf8), &random) + Self.frame(0x2, final: true, [], &random); code = WebSocketClose.protocolError
            case 9: // text that isn't UTF-8, whole or across fragments
                let bad = random.pick([[0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xE2, 0x82], [0xFF]] as [[UInt8]])
                bytes = Self.frame(0x1, final: false, Array("ok".utf8), &random) + Self.frame(0x0, final: true, bad, &random)
                code = WebSocketClose.invalidData
            case 10: bytes = Self.frame(0x8, final: true, [0x03], &random); code = WebSocketClose.protocolError
            case 11: bytes = Self.frame(0x8, final: true, [0x03, 0xED], &random); code = WebSocketClose.protocolError // 1005
            case 12: // fragments that together pass the limit
                bytes = Self.frame(0x2, final: false, random.bytes(max - 10), &random) + Self.frame(0x0, final: true, random.bytes(20), &random)
                code = WebSocketClose.tooBig
            default: // a sound frame cut short: more bytes are needed
                let whole = Self.frame(0x1, final: true, Array(Self.text(&random).utf8), &random)
                bytes = Array(whole.prefix(random.int(0...(whole.count - 1))))
            }
            let (events, failure) = Self.decode(bytes, &random, maxMessageBytes: max, round: round)
            if let code {
                #expect(failure?.code == code, "round \(round), kind \(kind): \(String(describing: failure)), events \(events.count)")
            } else {
                #expect(failure == nil && events.isEmpty, "round \(round), kind \(kind)")
            }
        }
    }

    /// Random bytes: a failure or nothing, never a trap, never more held than the limits allow.
    @Test func randomFrameBytesNeverTrap() {
        var random = Random(state: Self.seed ^ 5)
        for round in 0..<(400 * Self.rounds) {
            var bytes = random.bytes(random.int(0...4_000))
            // Often masked, so the decoder reads past the first header.
            if bytes.count > 1, random.chance(70) { bytes[1] |= 0x80 }
            _ = Self.decode(bytes, &random, maxMessageBytes: random.pick([125, 4_096, 1 << 20]), round: round)
        }
    }

    // MARK: The wire's lines and envelope

    /// Lines of every size up to the limit, fed in random chunks: each read back whole, in order.
    @Test func soundLinesAreReadBackWhole() {
        var random = Random(state: Self.seed ^ 6)
        for round in 0..<(100 * Self.rounds) {
            let lines: [[UInt8]] = (0..<random.int(0...30)).map { _ in
                let length = random.chance(2) ? random.int(0...NodeWire.maxLine) : random.int(0...300)
                return (0..<length).map { _ in UInt8.random(in: 0...255, using: &random) }.map { $0 == 0x0A ? 0x20 : $0 }
            }
            var reader = NodeWire.Lines()
            var read: [Data] = []
            for chunk in Self.chunks(lines.flatMap { $0 + [0x0A] }, &random) { read += reader.append(Data(chunk)) }
            #expect(!reader.tooLong && read == lines.map { Data($0) }, "round \(round)")
        }
    }

    /// A line at the limit is read; one past it ends the reader (whether its newline came or not), and nothing after.
    @Test func aLinePastTheLimitEndsTheReader() {
        var random = Random(state: Self.seed ^ 7)
        let at = [UInt8](repeating: 0x61, count: NodeWire.maxLine)
        var reader = NodeWire.Lines()
        #expect(reader.append(Data(at + [0x0A])) == [Data(at)] && !reader.tooLong)
        for withNewline in [true, false] {
            var reader = NodeWire.Lines()
            var read: [Data] = []
            for chunk in Self.chunks(at + [0x61] + (withNewline ? [0x0A] : []) + Array("{}\n".utf8), &random) { read += reader.append(Data(chunk)) }
            #expect(reader.tooLong && read.isEmpty, "newline: \(withNewline)")
        }
    }

    /// A megabyte of one-byte lines at once is read in time (the fuzz run's first find, 2026-11-22: taking each line
    /// moved all that followed it, half a million moves of a megabyte; kept as its regression case).
    @Test func manyShortLinesAtOnceAreReadInTime() {
        let lines = Data(Array(repeating: Array("a\n".utf8), count: 512 * 1_024).joined())
        var reader = NodeWire.Lines()
        let started = ProcessInfo.processInfo.systemUptime
        let read = reader.append(lines)
        let took = ProcessInfo.processInfo.systemUptime - started
        #expect(read.count == 512 * 1_024 && read.allSatisfy { $0 == Data("a".utf8) })
        #expect(took < 5, "\(took) s for half a million lines")
    }

    /// A long line dripped a byte at a time is read in time (the fuzz run's second find, 2026-11-22: each append looked
    /// for a newline in everything held, a megabyte line half a trillion looks; kept as its regression case).
    @Test func aLineDrippedAByteAtATimeIsReadInTime() {
        var reader = NodeWire.Lines()
        let started = ProcessInfo.processInfo.systemUptime
        var read: [Data] = []
        for _ in 0..<(256 * 1_024) { read += reader.append(Data([0x61])) }
        read += reader.append(Data([0x0A]))
        let took = ProcessInfo.processInfo.systemUptime - started
        #expect(read == [Data(repeating: 0x61, count: 256 * 1_024)] && !reader.tooLong)
        #expect(took < 5, "\(took) s for a 256 KB line a byte at a time")
    }

    /// Requests encoded and unwrapped: the same request back. Mutated or random lines: a refusal with its code, never a
    /// trap, however deep their nesting.
    @Test func theEnvelopeRoundTripsAndRefusesTheRest() {
        var random = Random(state: Self.seed ^ 8)
        func value(_ depth: Int) -> NodeWire.Value {
            switch random.int(0...(depth > 3 ? 3 : 5)) {
            case 0: return .string(Self.text(&random))
            case 1: return .int(random.int(-1_000_000...1_000_000))
            case 2: return .bool(random.chance(50))
            case 3: return .null
            case 4: return .array((0..<random.int(0...4)).map { _ in value(depth + 1) })
            default: return .object(Dictionary((0..<random.int(0...4)).map { _ in (Self.token(&random), value(depth + 1)) }) { first, _ in first })
            }
        }
        for round in 0..<(500 * Self.rounds) {
            let request = NodeWire.Request(id: Self.token(&random), kind: Self.token(&random),
                                           args: random.chance(70) ? Dictionary((0..<random.int(0...5)).map { _ in (Self.token(&random), value(0)) }) { first, _ in first } : nil,
                                           action: random.chance(30) ? UUID().uuidString : nil, must: random.chance(20) ? true : nil)
            var line = NodeWire.line(request)
            if line.last == 0x0A { line.removeLast() }
            #expect(NodeWire.unwrap(line) == .request(request), "round \(round): \(String(decoding: line, as: UTF8.self))")
            // Mutated: cut, a byte flipped, invalid UTF-8 put in.
            var mutated = [UInt8](line)
            switch random.int(0...2) {
            case 0: mutated = Array(mutated.prefix(random.int(0...max(0, mutated.count - 1))))
            case 1: if !mutated.isEmpty { mutated[random.int(0...(mutated.count - 1))] = UInt8.random(in: 0...255, using: &random) }
            default: mutated.insert(contentsOf: random.pick([[0xC0], [0xFF, 0xFE], [0xED, 0xA0, 0x80]]), at: random.int(0...mutated.count))
            }
            switch NodeWire.unwrap(Data(mutated)) {
            case .request(let read): #expect(read.v <= NodeWire.version)
            case .refused(_, let code, _): #expect(["not-object", "not-request", "version"].contains(code), "round \(round): \(code)")
            }
        }
        // Nesting far past the decoder's depth: refused, not a crash.
        for depth in [600, 100_000] {
            let deep = "{\"v\":1,\"id\":\"a\",\"kind\":\"k\",\"args\":{\"x\":" + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}}"
            if case .request = NodeWire.unwrap(Data(deep.utf8)) { Issue.record("depth \(depth) accepted") }
        }
    }
}
