import Foundation
import VibeCore

/// What `vibeswitcher-server` is started with (the engine plan's E1, EN-D3): by the session host's `ServerChild`,
/// `--host-connector N --host-socket PATH`, then `--node --node-root PATH` (the user's node) or `--root PATH
/// --node-root PATH` (a scratch host's), then each `--server-arg X` a scratch host was given. The test flags
/// (`--test-user-scopes=…`, `--test-housekeeping=…`, `--test-child=…`, `--test-first-look`) come only that way; a server with `--node`
/// refuses each, with a log line, and takes nothing from it.
public struct ServerArguments: Equatable, Sendable {
    /// The connector's descriptor, inherited.
    public var connector: Int32
    /// The host's socket: the path the connector is registered for, which must be the root's.
    public var hostSocket: String
    /// The user's node: the root is the account's own `~/.vibeswitcher`.
    public var node: Bool
    /// A scratch host's root (its `VibePaths.root`).
    public var root: String?
    /// The build's folder (`<node-root>/bin`, `<node-root>/build-info`).
    public var nodeRoot: String?
    /// The scopes a scratch host's test gives the voice rule (`VoiceRule.at`).
    public var testUserScopes: [String]?
    /// A scratch host's test's housekeeping period, in seconds (30 otherwise).
    public var testHousekeeping: Int?
    /// A scratch host's test's program, started once at the server's start with every descriptor the server holds
    /// that isn't close-on-exec (`ServerTests.theServersChildrenInheritNoConnector`): the server starts no child of its
    /// own before E4, and this is how a test sees what one would inherit.
    public var testChild: String?
    /// A scratch host's test says its vault holds its first look (`--hold-first-look`, stage 2's Task 10e): the engine
    /// refuses `lead` until the project's config and head are accepted (S7), as it always does for the user's node.
    public var testFirstLook = false
    /// The test flags a server with `--node` left out, each as given.
    public var refused: [String] = []

    public static let testUserScopesFlag = "--test-user-scopes="
    public static let testHousekeepingFlag = "--test-housekeeping="
    public static let testChildFlag = "--test-child="
    public static let testFirstLookFlag = "--test-first-look"

    /// The housekeeping period without a test's: 30 s (S2).
    public static let housekeeping = 30

    /// `arguments` (the program's name first) read, or why they can't be.
    public static func parse(_ arguments: [String]) -> Result<ServerArguments, Usage> {
        var connector: Int32?
        var hostSocket: String?
        var node = false
        var root: String?
        var nodeRoot: String?
        var scopes: [String]?
        var housekeeping: Int?
        var child: String?
        var firstLook = false
        var tests: [String] = []
        var index = 1
        func value() -> String? {
            guard arguments.indices.contains(index + 1) else { return nil }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let word = arguments[index]
            switch word {
            case "--host-connector":
                guard let number = value().flatMap(Int32.init), number >= 0 else { return .failure(Usage("--host-connector needs a descriptor's number")) }
                connector = number
            case "--host-socket":
                guard let path = value(), path.hasPrefix("/") else { return .failure(Usage("--host-socket needs an absolute path")) }
                hostSocket = path
            case "--node":
                node = true
            case "--root":
                guard let path = value(), path.hasPrefix("/") else { return .failure(Usage("--root needs an absolute path")) }
                root = path
            case "--node-root":
                guard let path = value(), path.hasPrefix("/") else { return .failure(Usage("--node-root needs an absolute path")) }
                nodeRoot = path
            case _ where word.hasPrefix(testUserScopesFlag):
                tests.append(word)
                let given = word.dropFirst(testUserScopesFlag.count).split(separator: ",").map(String.init)
                guard !given.isEmpty, given.allSatisfy({ $0.hasPrefix("/") }) else { return .failure(Usage("\(testUserScopesFlag) needs cgroup paths")) }
                scopes = given
            case _ where word.hasPrefix(testHousekeepingFlag):
                tests.append(word)
                guard let seconds = Int(word.dropFirst(testHousekeepingFlag.count)), seconds > 0 else {
                    return .failure(Usage("\(testHousekeepingFlag) needs a number of seconds"))
                }
                housekeeping = seconds
            case _ where word.hasPrefix(testChildFlag):
                tests.append(word)
                let path = String(word.dropFirst(testChildFlag.count))
                guard path.hasPrefix("/") else { return .failure(Usage("\(testChildFlag) needs an absolute path")) }
                child = path
            case testFirstLookFlag:
                tests.append(word)
                firstLook = true
            default:
                return .failure(Usage("unknown argument \(word)"))
            }
            index += 1
        }
        guard let connector else { return .failure(Usage("--host-connector is needed")) }
        guard let hostSocket else { return .failure(Usage("--host-socket is needed")) }
        guard node != (root != nil) else { return .failure(Usage("one of --node and --root is needed")) }
        var parsed = ServerArguments(connector: connector, hostSocket: hostSocket, node: node, root: root, nodeRoot: nodeRoot,
                                     testUserScopes: scopes, testHousekeeping: housekeeping, testChild: child, testFirstLook: firstLook)
        if node {
            parsed.refused = tests
            parsed.testUserScopes = nil
            parsed.testHousekeeping = nil
            parsed.testChild = nil
            parsed.testFirstLook = false
        }
        return .success(parsed)
    }

    /// Why the arguments weren't taken.
    public struct Usage: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// The connector's number in `arguments`, as early as the server's first statements read it (before anything
    /// else is parsed); nil without one.
    public static func connector(in arguments: [String]) -> Int32? {
        guard let at = arguments.firstIndex(of: "--host-connector"), arguments.indices.contains(at + 1) else { return nil }
        return Int32(arguments[at + 1]).flatMap { $0 >= 0 ? $0 : nil }
    }

    /// Whether `given` names the root's host socket (`VibePaths.hostSocket` under the root this process now has),
    /// spelled either way.
    public static func isRootsHostSocket(_ given: String, root: URL) -> Bool {
        let own = root.appendingPathComponent("host.sock").standardizedFileURL.path
        return URL(fileURLWithPath: given).standardizedFileURL.path == own
    }
}
