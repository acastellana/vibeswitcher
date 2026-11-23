import Foundation

/// Typed requests (the architecture review's row 11, the later part): a kind's arguments and its result as Codable
/// types, in the wire layer both the server and the command line import, so the server builds its reply from a value
/// the compiler checks and the command line reads it by property, never by a string key.
///
/// - **One type per side.** A kind is a `WireKind`: its `Args` (`WireNoArgs` for none) and its `Result`. The server
///   decodes the arguments (`NodeWire.Request.typedArgs`) and replies with the result (`NodeWire.Reply(re:typed:)`); the
///   command line asks with the arguments and decodes the result (`NodeClient.read`).
/// - **The same bytes as before.** A result encodes as the dictionary it replaces did: the same keys, sorted, the same
///   values (`NodeWire.line`'s encoder), a key written as `null` where the dictionary wrote one (`@WireNull`), a key left
///   out where it left one out (a plain optional). `WireKindsTests` holds each kind to replies captured from the server
///   before the types (Tests/Fixtures/wire-kinds): decoded and encoded again, byte for byte. So a command line from
///   before reads a newer server's reply as it did, and the reverse.
/// - **Tolerant reads.** Every result field decodes when it is missing (an older server's reply) and a field a type
///   doesn't name is skipped (a newer server's): a result is never refused for its shape. Arguments of a state-changing
///   kind stay refused for a key they don't take (`RequestArguments`); this slice types read kinds only.
/// - **Entities stay values.** What the live wire carries as an entity (a session, a lead, a card, a board, a plugin's
///   entry) and the values other renderers share (the node's web, usage, boost, health, restart) stay
///   `NodeWire.Value` inside a typed result, checked by `WireSchema`, until a slice of their own types them.
public protocol WireKind {
    associatedtype Args: Codable & Sendable
    associatedtype Result: Codable & Sendable
    /// The request's `kind`.
    static var kind: String { get }
}

/// The kinds typed so far, by name (`WireKindsLintTests` holds the command line to reading them through their types).
public enum WireKinds {
    /// The kinds the command line asks that aren't typed yet, left out on purpose: the external plugins' (the plugins
    /// lane's, to follow the pattern). `WireKindsLintTests` allows reading or sending these by name, and no other.
    public static let leftOut: Swift.Set<String> = Swift.Set(KindSpec.all.filter { if case .notYet = $0.wire { return true } else { return false } }.map(\.name))

    public static let typed: [String] = KindSpec.all.compactMap { spec in spec.typed.flatMap { $0 is any WireChangeKind.Type ? nil : spec.name } }
}

/// A kind that takes no arguments: asked with none (`args` absent, as before).
public struct WireNoArgs: WireArgs, Equatable {
    public init() {}

    public enum CodingKeys: CodingKey, CaseIterable {
        public var stringValue: String { switch self {} }
        public init?(stringValue: String) { nil }
        public var intValue: Int? { nil }
        public init?(intValue: Int) { nil }
    }
}

/// An optional written as `null` when it is nil (a dictionary's `.null`), and read as nil when it is `null` or missing.
@propertyWrapper
public struct WireNull<Wrapped: Codable & Sendable>: Codable, Sendable {
    public var wrappedValue: Wrapped?

    public init(wrappedValue: Wrapped?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        wrappedValue = single.decodeNil() ? nil : try single.decode(Wrapped.self)
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        if let wrappedValue { try single.encode(wrappedValue) } else { try single.encodeNil() }
    }
}

extension WireNull: Equatable where Wrapped: Equatable {}

extension KeyedDecodingContainer {
    /// A `@WireNull` field whose key is missing: nil (an older server's reply), not an error.
    public func decode<T>(_ type: WireNull<T>.Type, forKey key: Key) throws -> WireNull<T> {
        WireNull(wrappedValue: try decodeIfPresent(T.self, forKey: key))
    }
}

/// A field the server sometimes leaves out and sometimes writes as `null` (one of a kind's replies has it, another
/// doesn't): left out when `isPresent` is false, `null` when present with no value. Read as not present when missing.
@propertyWrapper
public struct WireMaybe<Wrapped: Codable & Sendable>: Codable, Sendable {
    public var wrappedValue: Wrapped?
    public var isPresent: Bool

    public init(wrappedValue: Wrapped?) {
        self.wrappedValue = wrappedValue
        isPresent = wrappedValue != nil
    }

    public init(_ value: Wrapped?, present: Bool) {
        wrappedValue = value
        isPresent = present
    }

    /// `$field`: the wrapper itself, to set a present `null`.
    public var projectedValue: WireMaybe<Wrapped> {
        get { self }
        set { self = newValue }
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        wrappedValue = single.decodeNil() ? nil : try single.decode(Wrapped.self)
        isPresent = true
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        if let wrappedValue { try single.encode(wrappedValue) } else { try single.encodeNil() }
    }
}

extension WireMaybe: Equatable where Wrapped: Equatable {}

extension KeyedDecodingContainer {
    /// A `@WireMaybe` field: missing is not present, `null` present with no value.
    public func decode<T>(_ type: WireMaybe<T>.Type, forKey key: Key) throws -> WireMaybe<T> {
        guard contains(key) else { return WireMaybe(nil, present: false) }
        return WireMaybe(try decodeIfPresent(T.self, forKey: key), present: true)
    }
}

extension KeyedEncodingContainer {
    /// A `@WireMaybe` field not present is left out.
    public mutating func encode<T>(_ value: WireMaybe<T>, forKey key: Key) throws {
        guard value.isPresent else { return }
        if let wrapped = value.wrappedValue { try encode(wrapped, forKey: key) } else { try encodeNil(forKey: key) }
    }
}

/// A state-changing kind's arguments: the keys it takes, from its coding keys, which `RequestArguments` refuses any
/// other key by (naming it, as before the types).
public protocol WireArgs: Codable, Sendable {
    associatedtype CodingKeys: CodingKey & CaseIterable
}

extension WireArgs {
    public static var keys: Set<String> { Set(CodingKeys.allCases.map(\.stringValue)) }
}

extension NodeWire.Value {
    /// `value` as the wire writes it (`NodeWire.line`'s encoder), read back as a value.
    public init<T: Encodable>(wire value: T) {
        var data = NodeWire.line(value)
        data.removeLast()
        self = NodeWire.decode(NodeWire.Value.self, data) ?? .null
    }

    /// This value read as `type`: what the command line does with a typed kind's result.
    public func wire<T: Decodable>(_ type: T.Type) throws -> T {
        var data = NodeWire.line(self)
        data.removeLast()
        return try JSONDecoder().decode(type, from: data)
    }
}

extension NodeWire.Reply {
    /// A typed kind's result as its reply.
    public init<T: Encodable>(re: String, typed result: T) {
        self.init(re: re, result: NodeWire.Value(wire: result))
    }
}

/// A typed kind's arguments as taken, or why they weren't.
public enum WireTaken<T> {
    case success(T)
    case failure(NodeWire.Failure)

    /// The arguments taken, or nil.
    public var taken: T? { if case .success(let value) = self { return value } else { return nil } }
}

extension NodeWire.Request {
    /// This request's arguments as `type` (none given: `{}`), or why they aren't (`bad-args`, naming the field).
    public func typedArgs<T: Decodable>(_ type: T.Type) -> WireTaken<T> {
        do {
            return .success(try NodeWire.Value.object(args ?? [:]).wire(type))
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            return .failure(.init(.badArgs, "\(kind): \(field.isEmpty ? "its arguments" : field) isn't of the form it takes"))
        } catch {
            return .failure(.init(.badArgs, "\(kind): its arguments aren't of the form it takes"))
        }
    }
}
