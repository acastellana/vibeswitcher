import Foundation

/// Why `start`, or a piece it is made of (the unit, its folders, the installed build, the preflight), refused: the
/// text the command line prints, naming what failed (the start plan's ST-D1). Paths and names read from the disk go
/// through `ConfigSeal.inert` where they are made into it.
public struct StartRefusal: Error, Equatable, CustomStringConvertible, Sendable {
    public let text: String

    public init(_ text: String) { self.text = text }

    public var description: String { text }
}
