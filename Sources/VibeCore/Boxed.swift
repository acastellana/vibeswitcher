import Foundation

/// An optional value kept on the heap, a pointer inline: for a board type's large fields. A `LeadTask` is copied by
/// value on the stack wherever the board's code works on one, and a debug build's frames hold dozens of copies at
/// once (`LeadToolset.mergeBatch`'s was 118 KB): every byte a task holds inline is paid many times over on the tool
/// server's threads (see `ToolThread`). Boxed, a field's size doesn't count there, and its growth never does.
///
/// Coded as the optional it wraps, under its own key: a nil one is left out, as a plain optional's is (the overloads
/// below are what the synthesized `Codable` calls), so the board's JSON is the same byte for byte. Immutable: a change
/// makes a new box, so copies never share a change.
@propertyWrapper
public struct Boxed<Value: Codable & Equatable & Sendable>: Equatable, Sendable {
    private final class Box: Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private var box: Box?

    public init(wrappedValue: Value?) { box = wrappedValue.map(Box.init) }

    /// Nil, as a plain optional starts.
    public init() { box = nil }

    public var wrappedValue: Value? {
        get { box?.value }
        set { box = newValue.map(Box.init) }
    }

    public static func == (a: Self, b: Self) -> Bool { a.wrappedValue == b.wrappedValue }
}

extension Boxed: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wrappedValue: container.decodeNil() ? nil : try container.decode(Value.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// A boxed field as its optional decodes: missing or null is nil.
    public func decode<Value>(_ type: Boxed<Value>.Type, forKey key: Key) throws -> Boxed<Value> {
        Boxed(wrappedValue: try decodeIfPresent(Value.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    /// A boxed field as its optional encodes: nil leaves the key out.
    public mutating func encode<Value>(_ value: Boxed<Value>, forKey key: Key) throws {
        try encodeIfPresent(value.wrappedValue, forKey: key)
    }
}
