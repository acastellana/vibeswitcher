import Foundation

/// Why `start`, or a piece it is made of (the unit, its folders, the installed build, the preflight), refused: the
/// text the command line prints, naming what failed (the start plan's ST-D1). Paths and names read from the disk go
/// through `ConfigSeal.inert` where they are made into it.
///
/// `exitCode` is the command line's (S2, 2026-11-16): 77 a refusal (the default), 69 no node (a scratch node with no
/// server), 1 a failure (a journal entry not written, a manager that didn't start the unit).
public struct StartRefusal: Error, Equatable, CustomStringConvertible, Sendable {
    public let text: String
    public let exitCode: Int32

    public init(_ text: String, exitCode: Int32 = 77) {
        self.text = text
        self.exitCode = exitCode
    }

    public var description: String { text }
}
