import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The re-check of v2-mac-checked-start (2026-11-25, "not yet"): a checked node's command line read once by one strict
/// parser (I1), and the switch's proof both ways and bound to the node's lock (I2). The command line is the parser's
/// alone; the keeper's proof of its parent runs a real hardened host image as the keeper (Mac only); the lock's binding
/// and the node's lock by file are functions on scratch files.
@Suite(.serialized, hostTestLimit)
struct MacCheckedReCheckTests {
    let scratch = Scratch()

    struct Node { var home, data, build, server, lock: String }

    func node() throws -> Node {
        let home = scratch.url("vsrc").path
        let data = Platform.Service.nodeRoot(accountHome: home)
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        let build = (data as NSString).deletingLastPathComponent + "/builds/" + String(repeating: "a", count: 40)
        try FileManager.default.createDirectory(atPath: build + "/bin", withIntermediateDirectories: true)
        let server = build + "/bin/" + BuildInfo.server
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: server)
        return Node(home: home, data: data, build: build, server: server, lock: data + "/host.lock")
    }

    // MARK: I1: one parser, a closed grammar

    /// The repository's root, from this file's place.
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The sources of the host's `main` and of every helper it hands its arguments to, and of the flags they name.
    static let scanned = ["Sources/vibeswitcher-host/main.swift", "Sources/VibeHost/V2/HostImages.swift", "Sources/VibeHost/V2/HostHardening.swift",
                          "Sources/VibeHost/V2/HandoverMemory.swift", "Sources/VibeHost/V2/HandoverTarget.swift", "Sources/VibeHost/V2/ServerChild.swift",
                          "Sources/VibeHost/V2/TestAppPrincipal.swift", "Sources/VibeHost/V2/VaultFirstLook.swift", "Sources/VibeHost/V2/ProjectAllowList.swift",
                          "Sources/VibeHost/HostHandover.swift", "Sources/VibeHost/V2/MacHandoverKeeper.swift", "Sources/VibeHost/V2/MacHandoverSwitch.swift",
                          "Sources/VibeHost/HostStart.swift", "Sources/VibeHost/V2/EgressProxy.swift", "Sources/VibeHost/PTYSpawn.swift",
                          "Sources/VibeHost/SessionParser.swift", "Sources/VibeCore/LeadVaultAppProof.swift",
                          "Sources/VibeHost/V2/CheckedSessions.swift"]

    /// Every flag those sources know, classified. `grammar`: a checked node's own; `dispatch`: a mode `main` dispatches
    /// before the parser, a separate program that takes no node state; every other: refused for a checked node.
    static let grammar: Set<String> = ["--node", "--node-root", "--server", "--handover-keeper-channel", "--handover-keeper-pid"]
    static let dispatch: Set<String> = ["--pty-exec", "--parse-session", "--handover-probe", "--handover-keeper", "--egress-proxy"]
    static let refused: Set<String> = [
        "--app-executable", "--app-key-stdin", "--control", "--end-orphaned-tool-servers", "--exit-with", "--handover", "--handover-fail-restore",
        "--handover-fallback", "--handover-fallback-app", "--handover-fallback-image", "--handover-probe-key", "--handover-proof", "--handover-fallback-node-root", "--handover-fallback-server",
        "--handover-keeper-limit", "--handover-test-fail-next", "--handover-test-hold", "--handover-test-hold-check", "--handover-test-keeper", "--handover-test-keeper-limit",
        "--handover-test-secret", "--handover-test-secret-file", "--handover-test-swap-after-check", "--handover-test-swap-before-exec",
        "--handover-test-traced", "--hold-first-look", "--host-connector", "--host-pid", "--host-socket", "--housekeeping", "--idle-exit",
        "--image-path", "--install-root", "--launcher-test-hold", "--log", "--parser-stall-limit", "--parser-test-hooks", "--root",
        "--scrollback", "--server-arg", "--server-test-replace-hold", "--socket", "--lock", "--test-app-connector", "--test-app-pid", "--test-inotify-census",
        "--test-no-inotify", "--test-stays-dumpable", "--test-user-seal-life", "--test-checked-shape"]

    /// The flags in `scanned`, and `HostHardening.testFlags`'s.
    static func flagsInTheSources() throws -> Set<String> {
        var found = Set(HostHardening.testFlags.keys)
        let pattern = try NSRegularExpression(pattern: "\"(--[a-z0-9][a-z0-9-]*)")
        for file in scanned {
            let text = try String(contentsOf: repository.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
            }
        }
        return found
    }

    /// I1: every flag the host's sources know is classified (a flag added later fails here until it is), and every one
    /// not in the grammar is refused by the checked start's parser in a flag's place and in every value's place (the
    /// re-check's `--handover --log …`: a flag of `main`'s as another flag's value). Red before: a value was skipped
    /// unread, so a flag in a value's place got through.
    @Test func everyFlagIsInTheGrammarOrRefusedInEveryPlace() throws {
        let found = try Self.flagsInTheSources()
        let classified = Self.grammar.union(Self.dispatch).union(Self.refused)
        #expect(found.subtracting(classified).isEmpty, "flags not classified: \(found.subtracting(classified).sorted())")
        let n = try node()
        let own = Platform.CodeIdentity.ownCdhash() ?? Data(repeating: 9, count: 20)
        let pins = Result<NodePins, NodePins.Refused>.success(NodePins(uid: getuid(), builds: []))
        // Refused by the parser itself (its refusal names the command line), never by a later check that happens to
        // refuse too: the record here pins nothing, so every line is refused at its row.
        func refused(_ arguments: [String]) -> Bool {
            if case .failure(let why) = HostImages.macNodeStart(arguments: arguments, lockPath: n.lock, own: own, pins: pins, accountHome: n.home) {
                return why.description.contains("command line")
            }
            return false
        }
        func parsed(_ arguments: [String]) -> Bool {
            if case .failure(let why) = HostImages.macNodeStart(arguments: arguments, lockPath: n.lock, own: own, pins: pins, accountHome: n.home) {
                return !why.description.contains("command line")
            }
            return true
        }
        let base = ["vibeswitcher-host", "--node", "--node-root", n.build, "--server", n.server]
        let keeper = ["--handover-keeper-channel", "9", "--handover-keeper-pid", "4321"]
        #expect(parsed(base) && parsed(base + keeper), "the node's own command line refused by the parser")
        for flag in found.subtracting(Self.grammar).sorted() {
            #expect(refused(base + [flag]), "a checked start took \(flag)")
            #expect(refused(base + [flag, "/x"]), "a checked start took \(flag) /x")
            #expect(refused(["vibeswitcher-host", "--node", "--node-root", flag, "--server", n.server]), "\(flag) as --node-root's value")
            #expect(refused(["vibeswitcher-host", "--node", "--node-root", n.build, "--server", flag]), "\(flag) as --server's value")
            #expect(refused(base + ["--handover-keeper-channel", flag, "--handover-keeper-pid", "4321"]), "\(flag) as the channel's value")
            #expect(refused(base + ["--handover-keeper-channel", "9", "--handover-keeper-pid", flag]), "\(flag) as the keeper pid's value")
        }
        // The grammar's own shapes: repeated, `--x=v`, `--`, a positional word, a relative path, a value missing, one
        // keeper flag alone, a descriptor or pid that isn't a number above its floor.
        for wrong in [base + ["--node"], base + ["--server", n.server], ["vibeswitcher-host", "--node", "--node-root", n.build, "--server=" + n.server],
                      base + ["--"], base + ["--", "--log", "/x"], base + ["extra"], ["vibeswitcher-host", "--node", "--node-root", "builds/a", "--server", n.server],
                      base + ["--handover-keeper-channel"], base + ["--handover-keeper-channel", "9"], base + ["--handover-keeper-pid", "4321"],
                      base + ["--handover-keeper-channel", "2", "--handover-keeper-pid", "4321"], base + ["--handover-keeper-channel", "9", "--handover-keeper-pid", "1"],
                      base + ["--handover-keeper-channel", "9x", "--handover-keeper-pid", "4321"], base + ["--handover", "/x/state"] + keeper,
                      ["vibeswitcher-host", "--node-root", n.build, "--server", n.server]] {
            #expect(refused(wrong), "a checked start took \(wrong.dropFirst())")
        }
    }

    /// I1: the value renders a command line that parses back to it, the switch's next image's among them (a target's
    /// folders and the keeper's two), so the next image of a switch passes the grammar.
    @Test func theValueRendersWhatParsesBackToIt() throws {
        let n = try node()
        guard case .success(let line) = HostImages.CheckedCommandLine.parse(["vibeswitcher-host", "--node", "--node-root", n.build, "--server", n.server,
                                                                              "--handover-keeper-channel", "7", "--handover-keeper-pid", "99"]) else {
            Issue.record("the node's own command line refused")
            return
        }
        #expect(HostImages.CheckedCommandLine.parse(["h"] + line.rendered) == .success(line))
        var plain = line
        plain.keeper = nil
        let next = HostServer.keeperArguments(started: plain.rendered, target: "/b/c/bin/vibeswitcher-host", checkedNode: true)
            + [MacHandoverKeeper.channelFlag, "5", MacHandoverKeeper.pidFlag, "77"]
        guard case .success(let given) = HostImages.CheckedCommandLine.parse(["h"] + next) else { Issue.record("a switch's next image refused: \(next)"); return }
        #expect(given.nodeRoot == "/b/c" && given.server == "/b/c/bin/" + BuildInfo.server && given.keeper == .init(channel: 5, pid: 77))
    }

    // MARK: I2a: the keeper proves its parent

    /// The re-check's route 1 (`aKeeperTakesAParcelFromAParentThatIsNoHost`): a keeper, a hardened copy of the built
    /// host, started by this test process (which is no host the node's record pins, and has no Hardened Runtime) is
    /// offered a checked node's parcel carrying chosen secrets. It takes nothing: its parent's token doesn't pass. Red
    /// before: it took the parcel, proving nothing about its parent.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's switch through a keeper: code identity"))
    func aKeeperRefusesAParentItCantProve() async throws {
        let folder = scratch.url("vsrc-keeper").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let image = folder + "/vibeswitcher-host"
        try installProgram(hostLauncher, atPath: image)
        let cdhash = try MacKeeperHandoverTests.sign(image, "dev.vibeswitcher.test.recheck.keeper")
        guard case .success(let keeper) = MacHandoverKeeper.start(image, expected: cdhash, limit: 5) else {
            Issue.record("the keeper didn't prove itself")
            return
        }
        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        defer { Sys.close(ends[0]); Sys.close(ends[1]) }
        let secret = try HostHandover.SecretChannel.make(Data("FORGED-VAULT-BYTES".utf8))
        defer { Sys.close(secret) }
        var state = HostHandover.State(fromBuild: 1, startedAt: Date(), lockFD: ends[0], listenFD: ends[1], secretFD: secret, sessions: [])
        state.fromCheckedNode = true
        let parked = MacHandoverKeeper.park(state, with: keeper)
        var status: Int32 = 0
        let ended = await eventually(timeout: 60) { waitpid(keeper.pid, &status, WNOHANG) == keeper.pid }
        if !ended { MacHandoverKeeper.abandon(keeper) } else { Sys.close(keeper.proven); Sys.close(keeper.channel) }
        if case .success = parked { Issue.record("a keeper whose parent is no pinned host took a checked node's parcel") }
        #expect(ended, "the keeper ran on")
    }

    /// I2a, the function: a parent's token must be the keeper's parent's pid and hardened; for a checked node's parcel
    /// also a host the record pins (read from the record, never from the keeper's arguments): no record, or a record
    /// that doesn't pin its code, refuses. This process's own token stands for the parent.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's switch through a keeper: code identity"))
    func aKeepersParentMustBeAPinnedHostForACheckedNodesParcel() throws {
        let (a, b) = try #require(Platform.Sockets.pair(type: Platform.Sockets.stream))
        defer { Sys.close(a); Sys.close(b) }
        let token = try #require(Platform.Sockets.peerToken(a))
        let own = try #require(Platform.CodeIdentity.ownCdhash())
        var state = HostHandover.State(fromBuild: 1, startedAt: Date(), lockFD: 0, listenFD: 1, secretFD: nil, sessions: [])
        let hardened: (Platform.PeerToken) -> Bool? = { _ in true }
        let pinned: () -> Result<NodePins, NodePins.Refused> = {
            .success(NodePins(uid: getuid(), builds: [NodePins.Build(commit: String(repeating: "a", count: 40), host: own,
                                                                      server: Data(repeating: 2, count: 20), cli: Data(repeating: 3, count: 20))]))
        }
        let other: () -> Result<NodePins, NodePins.Refused> = {
            .success(NodePins(uid: getuid(), builds: [NodePins.Build(commit: String(repeating: "a", count: 40), host: Data(repeating: 7, count: 20),
                                                                      server: Data(repeating: 2, count: 20), cli: Data(repeating: 3, count: 20))]))
        }
        #expect(MacHandoverKeeper.parentRefusal(token, parent: getpid(), state: state, pins: other, hardened: hardened) == nil, "a scratch host's parcel")
        #expect(MacHandoverKeeper.parentRefusal(token, parent: 1, state: state, pins: pinned, hardened: hardened) != nil, "another pid as the parent")
        #expect(MacHandoverKeeper.parentRefusal(token, parent: getpid(), state: state, pins: pinned, hardened: { _ in false }) != nil, "no Hardened Runtime")
        state.fromCheckedNode = true
        #expect(MacHandoverKeeper.parentRefusal(token, parent: getpid(), state: state, pins: pinned, hardened: hardened) == nil)
        #expect(MacHandoverKeeper.parentRefusal(token, parent: getpid(), state: state, pins: other, hardened: hardened) != nil, "a parent the record doesn't pin")
        #expect(MacHandoverKeeper.parentRefusal(token, parent: getpid(), state: state, pins: { .failure(NodePins.Refused("missing")) },
                                                hardened: hardened) != nil, "no record")
    }

    // MARK: I2b: the parcel bound to the node's lock

    /// I2b, and the re-check's route 2 (a scratch host of the pinned build, given test flags, whose parcel a genuine
    /// checked start would take): a checked start takes a parcel only when its lock descriptor is the node's own lock
    /// held through that open file. Another file (a scratch host's own lock), the node's lock not held, or held by another
    /// open file than the one given: refused; the holder's own descriptor: taken. Red before: no lock was asked.
    @Test func aParcelIsTakenOnlyWithTheNodesLockHeldThroughItsDescriptor() throws {
        let n = try node()
        let row = NodePins.Build(commit: String(repeating: "a", count: 40), host: Data(repeating: 1, count: 20), server: Data(repeating: 2, count: 20),
                                 cli: Data(repeating: 3, count: 20))
        let checked = HostImages.CheckedNode(build: row, serverPath: n.server, server: row.server)
        let holder = open(n.lock, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        let scratchLock = open(n.data + "/scratch.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        let other = open(n.lock, O_RDWR | O_CLOEXEC)
        defer { [holder, scratchLock, other].forEach { Sys.close($0) } }
        #expect(holder >= 0 && scratchLock >= 0 && other >= 0)
        #expect(flock(scratchLock, LOCK_EX | LOCK_NB) == 0)
        func take(_ fd: Int32) -> String? {
            var state = HostHandover.State(fromBuild: 1, startedAt: Date(), lockFD: fd, listenFD: 4, secretFD: nil, sessions: [])
            state.fromCheckedNode = true
            return HostImages.mayTakeHandover(state, viaKeeper: true, checkedNode: checked, lockPath: n.lock)
        }
        #expect(take(scratchLock) != nil, "a scratch host's own lock taken for the node's")
        #expect(take(holder) != nil, "the node's lock taken while no one held it")
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)
        #expect(take(other) != nil, "the node's lock taken through an open file that doesn't hold it")
        #expect(take(holder) == nil, "the node's lock refused through the open file that holds it")
    }

    // MARK: I2c: only a checked node on the node's lock

    /// I2c: the node's lock by file: its own path, another spelling, a hard link elsewhere, and (before it exists) a
    /// `host.lock` in the data root by its folder's device and inode; not another file. Red before: nothing asked it.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's node root"))
    func theNodesLockIsKnownByFile() throws {
        let n = try node()
        #expect(HostImages.isNodeLock(n.lock, accountHome: n.home), "the node's lock, before it exists")
        #expect(HostImages.isNodeLock(n.data + "/./host.lock", accountHome: n.home), "another spelling, before it exists")
        #expect(!HostImages.isNodeLock(n.data + "/other.lock", accountHome: n.home))
        FileManager.default.createFile(atPath: n.lock, contents: nil)
        let hard = scratch.url("vsrc-hard.lock").path
        #expect(link(n.lock, hard) == 0)
        for alias in [n.lock, n.data + "/./host.lock", n.data + "//host.lock", hard] {
            #expect(HostImages.isNodeLock(alias, accountHome: n.home), "\(alias) not known for the node's lock")
        }
        let scratchLock = scratch.url("vsrc-scratch.lock").path
        FileManager.default.createFile(atPath: scratchLock, contents: nil)
        #expect(!HostImages.isNodeLock(scratchLock, accountHome: n.home))
        #expect(!HostImages.isNodeLock(n.lock, accountHome: nil))
    }
}
