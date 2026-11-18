import Foundation

/// The session sandbox's door (the session sandbox plan's SB4): what a relay inside a confined session's box says to
/// the porter outside, and what it hears back.
///
/// A relay (`DoorRelay`: the `vibeswitcher-mcp` or `vibeswitcher-hook` the agent started inside) connects to the door,
/// a stream socket at `path` that only its box has, and sends one line, `Hello` as JSON ending in a newline, of at most
/// `maxHello` bytes, with its own stdin, stdout and stderr riding on it as descriptors (`SCM_RIGHTS`). The box's init
/// hands the connection, whole, to the session's porter (`Porter`), which starts the real helper outside with those
/// three descriptors as its own and answers, when the helper ends, `exitLine(status)`; or, when it won't start one,
/// `refusedLine(why)` at once. Either way the connection then closes.
///
/// The line names only what the relay was started as: its mode and its arguments. Nothing in it chooses the helper's
/// role, root or task, which the porter has from the host (`SessionHelper`), nor any argument the helper is started
/// with but a hook's agent name out of a fixed set (`Porter.command`).
public enum DoorProtocol {
    /// Where init binds the door inside a box, in the box's own tmpfs: no path outside names it.
    public static let path = "/run/vibeswitcher/door"
    /// The environment variable that tells a helper it runs inside a box, and where its door is (`path` in a box; a
    /// test's stand-in door elsewhere).
    public static let variable = "VIBESWITCHER_DOOR"
    /// The longest hello line, its newline included.
    public static let maxHello = 64 << 10
    /// The descriptors a hello carries: the relay's stdin, stdout and stderr, in that order.
    public static let descriptors = 3

    /// What the relay was started as.
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// The tool server (`vibeswitcher-mcp`, as a role's `--mcp-config` starts it).
        case mcp
        /// The hook (`vibeswitcher-hook <agent>`, as the user's settings start it).
        case hook
        /// A role's status line (`vibeswitcher-mcp --status-line`).
        case statusLine
        /// A role's `PermissionRequest` hook (`vibeswitcher-mcp --read-only-permission`).
        case permission
    }

    /// The one line a relay sends.
    public struct Hello: Codable, Equatable, Sendable {
        /// The protocol's version: 1.
        public var v: Int
        public var mode: Mode
        /// The relay's own arguments after its program's name, as it was started: only a hook's agent name is ever
        /// read from them, out of a fixed set.
        public var args: [String]

        public init(v: Int = 1, mode: Mode, args: [String]) {
            self.v = v
            self.mode = mode
            self.args = args
        }
    }

    /// Why a line isn't a hello.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// `hello` as the line a relay sends: compact JSON and a newline. nil when it would be longer than `maxHello`.
    public static func line(_ hello: Hello) -> [UInt8]? {
        guard let data = try? JSONEncoder().encode(hello) else { return nil }
        let bytes = Array(data) + [UInt8(ascii: "\n")]
        return bytes.count <= maxHello ? bytes : nil
    }

    /// The hello in `line` (its bytes up to the newline, the newline left out): refused when it is longer than
    /// `maxHello`, isn't UTF-8 JSON of a hello, holds a newline or a NUL, or names another version.
    public static func hello(_ line: [UInt8]) -> Result<Hello, Refusal> {
        guard line.count < maxHello else { return .failure(Refusal("the hello is longer than \(maxHello) bytes")) }
        guard !line.contains(0), !line.contains(UInt8(ascii: "\n")) else { return .failure(Refusal("the hello isn't one line")) }
        guard let hello = try? JSONDecoder().decode(Hello.self, from: Data(line)) else {
            return .failure(Refusal("the hello isn't a hello"))
        }
        guard hello.v == 1 else { return .failure(Refusal("the hello's version \(hello.v) isn't 1")) }
        return .success(hello)
    }

    /// The porter's answer once the helper has ended: `exit N` and a newline. `status` is the helper's exit status, or
    /// 128 plus the signal that ended it.
    public static func exitLine(_ status: Int32) -> String { "exit \(status)\n" }

    /// The porter's answer when it starts no helper: `refused <why>` and a newline (`why` on one line).
    public static func refusedLine(_ why: String) -> String {
        "refused " + why.replacingOccurrences(of: "\n", with: " ") + "\n"
    }

    /// What a porter's answer line (without its newline) says: the status to exit with, or why it refused. nil for
    /// anything else.
    public enum Answer: Equatable {
        case exit(Int32)
        case refused(String)
    }

    public static func answer(_ line: String) -> Answer? {
        if line.hasPrefix("exit "), let status = Int32(line.dropFirst(5)), status >= 0, status <= 255 { return .exit(status) }
        if line.hasPrefix("refused ") { return .refused(String(line.dropFirst(8))) }
        return nil
    }

    /// The environment variables a helper the porter started finds its session's connector by: the descriptor's number
    /// and the host's socket it stands for (`HostConnection.register(connector:for:)`). Read by `DoorRelay` first thing.
    public static let connectorVariable = "VIBESWITCHER_SESSION_CONNECTOR"
    public static let hostSocketVariable = "VIBESWITCHER_SESSION_HOST_SOCKET"
}
