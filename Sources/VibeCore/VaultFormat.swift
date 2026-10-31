import Foundation

/// The shared rules of the vault formats (docs/protocol/vault-request.md): a strict JSON reader and writer, the field
/// shapes, and the screen for key material. Everything unusual is refused, never repaired.
public enum VaultFormat {
    /// The largest file either side reads or writes: 64 KiB.
    public static let maxFileBytes = 64 * 1024
    /// How deep a document may nest (the formats themselves need 3).
    static let maxDepth = 8

    /// Why a file or a value was refused.
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// Over `maxFileBytes`.
        case tooLarge(Int)
        /// Not JSON as these formats take it (see `Value.parse`).
        case notJSON(String)
        /// A field the format doesn't have.
        case unknownField(String)
        case missingField(String)
        /// A field of the wrong JSON type: the field, and the type it must be.
        case wrongType(String, String)
        /// A field whose value breaks its rule: the field, and the rule.
        case invalid(String, String)
        /// A field that looks like key material: the field, and the shape seen.
        case keyMaterial(String, String)

        public var description: String {
            switch self {
            case let .tooLarge(bytes): "the file is \(bytes) bytes, over the \(VaultFormat.maxFileBytes)-byte limit"
            case let .notJSON(why): "not JSON as the format takes it: \(why)"
            case let .unknownField(field): "unknown field \(field)"
            case let .missingField(field): "missing field \(field)"
            case let .wrongType(field, type): "\(field) must be \(type)"
            case let .invalid(field, rule): "\(field): \(rule)"
            case let .keyMaterial(field, shape): "\(field) looks like key material (\(shape))"
            }
        }
    }

    // MARK: JSON

    /// A JSON value as these formats read it: objects keep their members' order and may not repeat a key; numbers are
    /// whole, unsigned and at most 16 digits (no sign, fraction or exponent).
    public indirect enum Value: Equatable, Sendable {
        case object([Member])
        case array([Value])
        case string(String)
        case integer(Int64)
        case bool(Bool)
        case null

        public struct Member: Equatable, Sendable {
            public var key: String
            public var value: Value
            public init(_ key: String, _ value: Value) {
                self.key = key
                self.value = value
            }
        }

        /// Parses `data`: UTF-8 without a byte-order mark, one value and whitespace around it, nothing else.
        public static func parse(_ data: Data) throws -> Value {
            var reader = Reader(bytes: [UInt8](data))
            reader.skipWhitespace()
            let value = try reader.value(depth: 0)
            reader.skipWhitespace()
            guard reader.atEnd else { throw Failure.notJSON("text after the value at byte \(reader.index)") }
            return value
        }

        /// Compact JSON, members in their order, ending in a newline.
        public func encoded() -> Data { Data((text + "\n").utf8) }

        var text: String {
            switch self {
            case let .object(members): "{" + members.map { Value.quoted($0.key) + ":" + $0.value.text }.joined(separator: ",") + "}"
            case let .array(items): "[" + items.map(\.text).joined(separator: ",") + "]"
            case let .string(string): Value.quoted(string)
            case let .integer(number): String(number)
            case let .bool(flag): flag ? "true" : "false"
            case .null: "null"
            }
        }

        static func quoted(_ string: String) -> String {
            var out = "\""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if scalar.value < 0x20 || scalar.value == 0x7f {
                        out += String(format: "\\u%04x", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out + "\""
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        var atEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
        }

        func fail(_ why: String) -> Failure { .notJSON("\(why) at byte \(index)") }

        mutating func value(depth: Int) throws -> Value {
            guard depth < maxDepth else { throw fail("nested deeper than \(maxDepth)") }
            guard index < bytes.count else { throw fail("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return .integer(try integer())
            default: throw fail("unexpected character")
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw fail("unexpected character")
            }
            index += expected.count
        }

        mutating func integer() throws -> Int64 {
            let start = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            let digits = bytes[start..<index]
            if index < bytes.count, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[index]) {
                throw fail("a number that isn't whole")
            }
            guard digits.count <= 16 else { throw fail("a number over 16 digits") }
            guard digits.count == 1 || digits.first != UInt8(ascii: "0") else { throw fail("a number with a leading zero") }
            return Int64(String(decoding: digits, as: UTF8.self))!
        }

        mutating func string() throws -> String {
            index += 1
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw fail("unterminated string") }
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(bytes: out, encoding: .utf8) else { throw fail("a string that isn't UTF-8") }
                    return text
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw fail("unterminated string") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5c)
                    case UInt8(ascii: "/"): out.append(0x2f)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0c)
                    case UInt8(ascii: "n"): out.append(0x0a)
                    case UInt8(ascii: "r"): out.append(0x0d)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xd800...0xdbff).contains(code) {
                            guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                                throw fail("a lone surrogate")
                            }
                            index += 2
                            let low = try hex4()
                            guard (0xdc00...0xdfff).contains(low) else { throw fail("a lone surrogate") }
                            code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
                        } else if (0xdc00...0xdfff).contains(code) {
                            throw fail("a lone surrogate")
                        }
                        out.append(contentsOf: Array(String(Unicode.Scalar(code)!).utf8))
                    default: throw fail("an unknown escape")
                    }
                default:
                    guard byte >= 0x20 else { throw fail("a control character in a string") }
                    out.append(byte)
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16),
                  bytes[index..<index + 4].allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) }) else {
                throw fail("a bad \\u escape")
            }
            index += 4
            return code
        }

        mutating func object(depth: Int) throws -> Value {
            index += 1
            var members: [Value.Member] = []
            var keys = Set<String>()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object([])
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                let key = try string()
                guard keys.insert(key).inserted else { throw Failure.notJSON("the key \(key) appears twice") }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                index += 1
                skipWhitespace()
                members.append(Value.Member(key, try value(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw fail("unexpected end") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw fail("expected ',' or '}'")
            }
        }

        mutating func array(depth: Int) throws -> Value {
            index += 1
            var items: [Value] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array([])
            }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw fail("unexpected end") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw fail("expected ',' or ']'")
            }
        }
    }

    /// Parses a whole file: the size first, then the JSON.
    static func document(_ data: Data) throws -> Value {
        guard data.count <= maxFileBytes else { throw Failure.tooLarge(data.count) }
        return try Value.parse(data)
    }

    // MARK: Objects

    /// Reads one object's fields by name: any field outside `allowed` is refused at once.
    struct Fields {
        let path: String
        private let members: [String: Value]

        init(_ value: Value, path: String, allowed: [String]) throws {
            guard case let .object(list) = value else { throw Failure.wrongType(path, "an object") }
            self.path = path
            for member in list where !allowed.contains(member.key) { throw Failure.unknownField(VaultFormat.name(member.key, in: path)) }
            members = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0.value) })
        }

        func name(_ key: String) -> String { VaultFormat.name(key, in: path) }

        func has(_ key: String) -> Bool { members[key] != nil }

        func value(_ key: String) throws -> Value {
            guard let value = members[key] else { throw Failure.missingField(name(key)) }
            return value
        }

        func string(_ key: String) throws -> String {
            guard case let .string(text) = try value(key) else { throw Failure.wrongType(name(key), "a string") }
            return text
        }

        func optionalString(_ key: String) throws -> String? { has(key) ? try string(key) : nil }

        func integer(_ key: String) throws -> Int64 {
            guard case let .integer(number) = try value(key) else { throw Failure.wrongType(name(key), "a whole number") }
            return number
        }

        func bool(_ key: String) throws -> Bool {
            guard case let .bool(flag) = try value(key) else { throw Failure.wrongType(name(key), "true or false") }
            return flag
        }

        func array(_ key: String) throws -> [Value] {
            guard case let .array(items) = try value(key) else { throw Failure.wrongType(name(key), "an array") }
            return items
        }
    }

    static func name(_ key: String, in path: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    // MARK: Shapes

    /// 0x and 40 hex digits, either case (the vault checks an EIP-55 checksum).
    public static func isAddress(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 42 && bytes[0] == UInt8(ascii: "0") && bytes[1] == UInt8(ascii: "x") && bytes[2...].allSatisfy(isHex)
    }

    /// A UUID in lower case, 8-4-4-4-12.
    public static func isID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (offset, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(offset) {
                guard byte == UInt8(ascii: "-") else { return false }
            } else {
                guard (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) else { return false }
            }
        }
        return true
    }

    /// 0x and 64 hex digits: a transaction's or a Safe transaction's hash.
    static func isHash(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 66 && bytes[0] == UInt8(ascii: "0") && bytes[1] == UInt8(ascii: "x") && bytes[2...].allSatisfy(isHex)
    }

    /// 1–64 of A–Z, a–z, 0–9, '.', '_', '-', starting with a letter or digit.
    static func isName(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...64).contains(bytes.count), isAlphanumeric(bytes[0]) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) || (byte >= 0x41 && byte <= 0x46)
    }

    static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x41 && byte <= 0x5a)
    }

    /// Text a person reads: `limit` Unicode scalars at most (`minimum` at least), and no control or format character
    /// (Unicode Cc and Cf: bidi overrides, zero-width characters), except a line feed where `multiline`.
    static func checkText(_ text: String, field: String, minimum: Int = 1, limit: Int, multiline: Bool = false) throws {
        let count = text.unicodeScalars.count
        guard count >= minimum else { throw Failure.invalid(field, minimum == 1 ? "must not be empty" : "under \(minimum) characters") }
        guard count <= limit else { throw Failure.invalid(field, "over \(limit) characters") }
        for scalar in text.unicodeScalars where !(multiline && scalar == "\n") {
            switch scalar.properties.generalCategory {
            case .control, .format: throw Failure.invalid(field, "holds a control or invisible character (U+\(String(format: "%04X", scalar.value)))")
            default: continue
            }
        }
    }

    /// `YYYY-MM-DDTHH:MM:SSZ`, a real date and time (UTC, whole seconds).
    static func date(_ text: String, field: String) throws -> Date {
        guard let date = timestamp.date(from: text), timestamp.string(from: date) == text else {
            throw Failure.invalid(field, "must be a UTC time as YYYY-MM-DDTHH:MM:SSZ")
        }
        return date
    }

    static func string(_ date: Date) -> String { timestamp.string(from: date) }

    nonisolated(unsafe) private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: Key material

    /// The shape of key material `text` holds, or nil: a `-----BEGIN` block (a PEM key), a run of 64 or more hex digits
    /// (a raw private key, with or without 0x), or a run of 12 or more words of the BIP39 English wordlist (a recovery
    /// phrase: words are runs of letters, any other character between them, in any case).
    public static func keyMaterial(in text: String) -> String? {
        if text.contains("-----BEGIN") { return "a -----BEGIN block" }
        var run = 0
        for byte in text.utf8 {
            run = isHex(byte) ? run + 1 : 0
            if run >= 64 { return "64 or more hex digits in a row" }
        }
        var words = 0
        for word in text.lowercased().split(whereSeparator: { !("a"..."z").contains($0) }) {
            // A word next to a letter outside a–z (é, ß) is cut there; the pieces still count only if they're words.
            words = VaultWordlist.words.contains(word) ? words + 1 : 0
            if words >= 12 { return "12 or more BIP39 words in a row" }
        }
        return nil
    }

    /// Refuses `text` (`field`) when it looks like key material.
    static func screen(_ text: String, field: String) throws {
        if let shape = keyMaterial(in: text) { throw Failure.keyMaterial(field, shape) }
    }
}
