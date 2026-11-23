import Foundation
import VibeCore

/// What `vibeswitcher-server` is started with (the engine plan's E1, EN-D3): by the session host's `ServerChild`,
/// `--host-connector N --host-socket PATH`, then `--node --node-root PATH` (the user's node) or `--root PATH
/// --node-root PATH` (a scratch host's), then each `--server-arg X` a scratch host was given. The test flags
/// (`--test-user-scopes=…`, `--test-cgroup-root=…`, `--test-runner-above`, `--test-housekeeping=…`, `--test-child=…`, `--test-first-look`,
/// `--test-install-root=…`, and the web's `--test-web-port=…`, `--test-web-root=…`, `--test-web-pair`, `--test-web-terminal`,
/// `--test-web-terminal-watch`, the watchdog's `--test-stall=…` and the idle limits' `--test-idle=…`) come only that way; a server with `--node` refuses each, with a log line, and takes
/// nothing from it.
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
    /// The cgroup a scratch host's test runs in, when that is inside the user's systemd manager (a test run a session
    /// of the node started: the tool server's merge gate, a worker's shell). The server reads each sender's cgroup
    /// from there (`PeerFacts.rerooted`, as a cgroup namespace rooted there shows it), so the test's own scope is `/`
    /// and `--test-user-scopes=/` names it; without this no scope could, for `VoiceRule.cgroupRefusal` refuses every
    /// path in the manager before it looks at a scope. It moves no path that isn't at or under it and changes
    /// nothing of the rule. The user's node reads `/proc/<pid>/cgroup` as it is, never through this.
    public var testCgroupRoot: String?
    /// A scratch host's test runs under a branch code runner (`BranchCode.wrapper`): a merge's and an audit's test
    /// command are started under one, so every process of such a run has it among its ancestors, the test process that
    /// speaks to its scratch node as the user too, and `Voice.judge` refuses a sender under a runner. With this the
    /// server reads its own ancestry once, at its start, and the runners in it (`PeerFacts.runners(above:)`, each by
    /// pid and start) are not counted as a sender's: they are above the whole scratch node, server and all. A runner
    /// anywhere else in a sender's ancestry counts as ever, and nothing of the rule changes. The flag names no
    /// process: which runners is the server's own reading of `/proc`. The user's node never takes it.
    public var testRunnerAbove = false
    /// A scratch host's test's housekeeping period, in seconds (30 otherwise).
    public var testHousekeeping: Int?
    /// A scratch host's test's program, started once at the server's start with every descriptor the server holds
    /// that isn't close-on-exec (`ServerTests.theServersChildrenInheritNoConnector`): the server starts no child of its
    /// own before E4, and this is how a test sees what one would inherit.
    public var testChild: String?
    /// A scratch host's test says its vault holds its first look (`--hold-first-look`, stage 2's Task 10e): the engine
    /// refuses `lead` until the project's config and head are accepted (S7), as it always does for the user's node.
    public var testFirstLook = false
    /// A scratch host's test's install root (the start plan's S8b): where `build.switch` finds the builds it switches
    /// between, and `status` the install record (`<it>/installs`). The user's node takes the account's own
    /// (`NodeFolders.defaultPrefix`), never this.
    public var testInstallRoot: String?
    /// A scratch server's web port (the live plan's I1): 0 for one the kernel picks. The user's node listens on
    /// `NodeWeb.port` alone, never this.
    public var testWebPort: UInt16?
    /// A scratch server serves the page's files from this folder, read at each request (`FolderAssets`), instead of the
    /// embedded ones, so the web lane sees a change at the next load.
    public var testWebRoot: String?
    /// A scratch server takes `web.open` from any process of the uid, with no voice or typed code (the sandbox's and the
    /// tests' "scratch form"): the user's node never does.
    public var testWebPair = false
    /// A scratch server opens a session's terminal to a page to type into (`term.open`, the live plan's slice 4 and
    /// I4, LW-D12): the user's node never does (it only watches, `webTerminal`).
    public var testWebTerminal = false
    /// A scratch server opens a session's terminal to watch, as the user's node does (`webTerminal`): the end-to-end
    /// tests' stand-in for the user's node, whose root a scratch server can't take.
    public var testWebTerminalWatch = false
    /// A scratch server checks for updates against these answers (`UpdateWatch.Answers`), on `update.check` only, never
    /// on a timer: the user's node asks GitHub, never this.
    public var testUpdateAnswers: String?
    /// A scratch server's watchdog ends it after this many seconds of a stalled engine queue (120 otherwise), beating
    /// every 0.25 s and calling 1 s a stall; and the test's trigger files block its lanes (`ServerStart.testBlocks`).
    public var testStall: Double?
    /// A scratch server's idle limits (`NodeServer.Idle`): this many seconds for a connection's first request, twice it
    /// for one that only sits there (30 s and 10 minutes otherwise).
    public var testIdle: Double?
    /// A scratch server's file watch tests (`Platform.Watches.testNoInstance`, `testCensus`).
    public var testNoInotify = false
    public var testInotifyCensus: String?
    /// A scratch server that lists the sessions its host didn't start, as the user's node does (`NodeSessions`'
    /// `onlyHosted` off): a test of what the user's node lists beside another node.
    public var testListsUnhosted = false
    /// The test flags a server with `--node` left out, each as given.
    public var refused: [String] = []

    public static let testUserScopesFlag = "--test-user-scopes="
    public static let testCgroupRootFlag = "--test-cgroup-root="
    public static let testRunnerAboveFlag = "--test-runner-above"
    public static let testHousekeepingFlag = "--test-housekeeping="
    public static let testChildFlag = "--test-child="
    public static let testFirstLookFlag = "--test-first-look"
    public static let testInstallRootFlag = "--test-install-root="
    public static let testWebPortFlag = "--test-web-port="
    public static let testWebRootFlag = "--test-web-root="
    public static let testWebPairFlag = "--test-web-pair"
    public static let testWebTerminalFlag = "--test-web-terminal"
    public static let testWebTerminalWatchFlag = "--test-web-terminal-watch"
    public static let testUpdateAnswersFlag = "--test-update-answers="
    public static let testStallFlag = "--test-stall="
    public static let testIdleFlag = "--test-idle="
    public static let testNoInotifyFlag = "--test-no-inotify"
    public static let testInotifyCensusFlag = "--test-inotify-census="
    public static let testListsUnhostedFlag = "--test-lists-unhosted"

    /// What a page may do with a session's terminal (`TerminalRelay.Mode`; nil: no terminal, `term.open` is
    /// `unknown-kind`): on the user's node, watch it; on a scratch server, what its test flag says, read-write first.
    public var webTerminal: TerminalRelay.Mode? {
        if node { return .watch }
        if testWebTerminal { return .readWrite }
        return testWebTerminalWatch ? .watch : nil
    }

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
        var cgroupRoot: String?
        var runnerAbove = false
        var housekeeping: Int?
        var child: String?
        var firstLook = false
        var installRoot: String?
        var webPort: UInt16?
        var webRoot: String?
        var webPair = false
        var webTerminal = false
        var webTerminalWatch = false
        var updateAnswers: String?
        var stall: Double?
        var idle: Double?
        var noInotify = false
        var listsUnhosted = false
        var census: String?
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
            case _ where word.hasPrefix(testCgroupRootFlag):
                tests.append(word)
                let path = String(word.dropFirst(testCgroupRootFlag.count))
                guard PeerFacts.isCgroupRoot(path) else {
                    return .failure(Usage("\(testCgroupRootFlag) needs a cgroup's path under the root (/a/b, with no . or .. and no / at its end)"))
                }
                cgroupRoot = path
            case testRunnerAboveFlag:
                tests.append(word)
                runnerAbove = true
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
            case _ where word.hasPrefix(testInstallRootFlag):
                tests.append(word)
                let path = String(word.dropFirst(testInstallRootFlag.count))
                guard path.hasPrefix("/") else { return .failure(Usage("\(testInstallRootFlag) needs an absolute path")) }
                installRoot = path
            case _ where word.hasPrefix(testWebPortFlag):
                tests.append(word)
                guard let port = UInt16(word.dropFirst(testWebPortFlag.count)) else {
                    return .failure(Usage("\(testWebPortFlag) needs a port's number (0: the kernel's pick)"))
                }
                webPort = port
            case _ where word.hasPrefix(testWebRootFlag):
                tests.append(word)
                let path = String(word.dropFirst(testWebRootFlag.count))
                guard path.hasPrefix("/") else { return .failure(Usage("\(testWebRootFlag) needs an absolute path")) }
                webRoot = path
            case testWebPairFlag:
                tests.append(word)
                webPair = true
            case testNoInotifyFlag:
                tests.append(word)
                noInotify = true
            case testListsUnhostedFlag:
                tests.append(word)
                listsUnhosted = true
            case _ where word.hasPrefix(testInotifyCensusFlag):
                tests.append(word)
                let path = String(word.dropFirst(testInotifyCensusFlag.count))
                guard path.hasPrefix("/") else { return .failure(Usage("\(testInotifyCensusFlag) needs an absolute path")) }
                census = path
            case testWebTerminalFlag:
                tests.append(word)
                webTerminal = true
            case testWebTerminalWatchFlag:
                tests.append(word)
                webTerminalWatch = true
            case _ where word.hasPrefix(testUpdateAnswersFlag):
                tests.append(word)
                let path = String(word.dropFirst(testUpdateAnswersFlag.count))
                guard path.hasPrefix("/") else { return .failure(Usage("\(testUpdateAnswersFlag) needs an absolute path")) }
                updateAnswers = path
            case _ where word.hasPrefix(testIdleFlag):
                tests.append(word)
                guard let seconds = Double(word.dropFirst(testIdleFlag.count)), seconds >= 1, seconds <= 600 else {
                    return .failure(Usage("\(testIdleFlag) needs a number of seconds, 1 to 600"))
                }
                idle = seconds
            case _ where word.hasPrefix(testStallFlag):
                tests.append(word)
                guard let seconds = Double(word.dropFirst(testStallFlag.count)), seconds >= 2, seconds <= 600 else {
                    return .failure(Usage("\(testStallFlag) needs a number of seconds, 2 to 600"))
                }
                stall = seconds
            default:
                return .failure(Usage("unknown argument \(word)"))
            }
            index += 1
        }
        guard let connector else { return .failure(Usage("--host-connector is needed")) }
        guard let hostSocket else { return .failure(Usage("--host-socket is needed")) }
        guard node != (root != nil) else { return .failure(Usage("one of --node and --root is needed")) }
        var parsed = ServerArguments(connector: connector, hostSocket: hostSocket, node: node, root: root, nodeRoot: nodeRoot,
                                     testUserScopes: scopes, testHousekeeping: housekeeping, testChild: child, testFirstLook: firstLook,
                                     testInstallRoot: installRoot, testWebPort: webPort, testWebRoot: webRoot, testWebPair: webPair)
        parsed.testWebTerminal = webTerminal
        parsed.testWebTerminalWatch = webTerminalWatch
        parsed.testUpdateAnswers = updateAnswers
        parsed.testStall = stall
        parsed.testIdle = idle
        parsed.testNoInotify = noInotify
        parsed.testInotifyCensus = census
        parsed.testListsUnhosted = listsUnhosted
        parsed.testCgroupRoot = cgroupRoot
        parsed.testRunnerAbove = runnerAbove
        if node {
            parsed.refused = tests
            parsed.testUserScopes = nil
            parsed.testCgroupRoot = nil
            parsed.testRunnerAbove = false
            parsed.testHousekeeping = nil
            parsed.testChild = nil
            parsed.testFirstLook = false
            parsed.testInstallRoot = nil
            parsed.testWebPort = nil
            parsed.testWebRoot = nil
            parsed.testWebPair = false
            parsed.testWebTerminal = false
            parsed.testWebTerminalWatch = false
            parsed.testUpdateAnswers = nil
            parsed.testStall = nil
            parsed.testIdle = nil
            parsed.testNoInotify = false
            parsed.testInotifyCensus = nil
            parsed.testListsUnhosted = false
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
