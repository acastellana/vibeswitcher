import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The Mac's checked node start (the node on the Mac's design, "The checked node start"; docs/process/v2-mac-tasks.md
/// item 13). `HostImages.macNodeStart` with a scratch record (the record's path isn't a node process's to choose, so the
/// record is given to the function, as the anchor's tests give it), this test process's own running code as the host's
/// (`Platform.CodeIdentity.ownCdhash`, the kernel's), and a node root under a scratch home whose server is a copy of a
/// signed program of Apple's: `/usr/bin/true` as this build's server, `/bin/echo` as another build's (another cdhash).
/// Then the host's wiring: only a host holding a checked start is a node host (a server child, `vaultV2`, the record in
/// its book); a `--node` host without one gets none of it. Mac only: Linux's node start is `HostImages.startAsNode`'s.
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's checked node start: code identity"), .serialized)
struct MacCheckedStartTests {
    let scratch = Scratch()

    /// A scratch account home with the node's root in it (`<home>/.vibeswitcher/v2/node`, `Platform.Service.nodeRoot`),
    /// its `bin/vibeswitcher-server` a copy of `program`.
    func nodeRoot(server program: String = "/usr/bin/true") throws -> (home: String, root: String, server: String, lock: String) {
        let home = scratch.url("vsck").path
        let root = Platform.Service.nodeRoot(accountHome: home)
        let bin = (root as NSString).appendingPathComponent("bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let server = (bin as NSString).appendingPathComponent(BuildInfo.server)
        try FileManager.default.copyItem(atPath: program, toPath: server)
        return (home, root, server, (root as NSString).appendingPathComponent("host.lock"))
    }

    static let commit = String(repeating: "a", count: 40)
    static let otherCommit = String(repeating: "b", count: 40)
    static let elsewhere = Data(repeating: 0x0f, count: 20)

    func arguments(_ node: (home: String, root: String, server: String, lock: String), server: String? = nil) -> [String] {
        ["vibeswitcher-host", "--node", "--node-root", node.root, "--server", server ?? node.server]
    }

    func record(_ builds: [NodePins.Build]) -> Result<NodePins, NodePins.Refused> { .success(NodePins(uid: getuid(), builds: builds)) }

    func row(host: Data, server: String, commit: String = Self.commit) throws -> NodePins.Build {
        NodePins.Build(commit: commit, host: host, server: try #require(Platform.CodeIdentity.cdhash(atPath: server)), cli: Data(repeating: 0xc1, count: 20))
    }

    func refusal(_ result: Result<HostImages.CheckedNode, HostImages.Refused>) -> String? {
        if case .failure(let why) = result { return why.description }
        return nil
    }

    /// A host on a scratch socket with a vault in memory, given `checked` (or none), and its server child adopted from
    /// `arguments` as `main` adopts it: what it is then.
    func host(checked: HostImages.CheckedNode?, arguments: [String]) throws -> (host: TestHost, child: ServerChild?, book: LeadVault.Book) {
        let book = LeadVault.Book()
        let host = try TestHost(vault: book, appConnector: false, checkedNode: checked)
        let child = ServerChild.adopt(arguments: arguments, ownsLaunchers: false, nodeRoot: value(after: "--node-root", in: arguments) ?? "/nonexistent",
                                      config: host.server.config, server: host.server)
        // The child's start is queued on the host's queue: once it ran, `serverChild` is what it will be.
        _ = host.server.queue.sync { host.server.serverChild }
        return (host, child, book)
    }

    func value(after flag: String, in arguments: [String]) -> String? {
        guard let at = arguments.firstIndex(of: flag), arguments.indices.contains(at + 1) else { return nil }
        return arguments[at + 1]
    }

    /// (a) A node host whose running code the record doesn't pin: refused, plainly, and a `--node` host with no checked
    /// start runs no server child, isn't a node host, lists no `vaultV2`, and its book keeps no record. The same host
    /// whose code the record pins, with its row's server: a node host, all three. Red before: no `--node` host was refused
    /// a server child on a scratch lock, and none was ever a node host.
    @Test func aHostWhoseCodeIsntPinnedGetsNoServerChildNoVaultAndNoHooks() throws {
        let node = try nodeRoot()
        let own = try #require(Platform.CodeIdentity.ownCdhash())
        let given = arguments(node)

        let notPinned = HostImages.macNodeStart(arguments: given, lockPath: node.lock, own: own,
                                                pins: record([try row(host: Self.elsewhere, server: node.server)]), accountHome: node.home)
        let why = try #require(refusal(notPinned), "a host the record doesn't pin passed its start")
        #expect(why.contains("is no host the node's record pins") && why.contains(NodePins.hex(own)), "\(why)")
        #expect(refusal(HostImages.macNodeStart(arguments: given, lockPath: node.lock, own: nil,
                                                pins: record([try row(host: own, server: node.server)]), accountHome: node.home)) != nil,
                "a host whose own code can't be read passed")
        #expect(refusal(HostImages.macNodeStart(arguments: given, lockPath: node.lock, own: own,
                                                pins: .failure(NodePins.Refused("the record is missing")), accountHome: node.home))?
                    .contains("the record is missing") == true)

        let refused = try host(checked: nil, arguments: given)
        defer { refused.child?.stop() }
        #expect(refused.child == nil, "a --node host with no checked start ran a server child")
        #expect(refused.host.server.queue.sync { refused.host.server.serverChild == nil && !refused.host.server.isMacNodeHost })
        #expect(!refused.host.server.welcomeCapabilities.contains(HostProtocol.Capability.vaultV2))
        #expect(!refused.book.recordsActions, "a host that isn't a node host keeps the record of the user's actions")
        #expect(!refused.book.watchesMacList, "a host that isn't a node host watches the Mac seal list")

        let checked = HostImages.macNodeStart(arguments: given, lockPath: node.lock, own: own,
                                              pins: record([try row(host: own, server: node.server)]), accountHome: node.home)
        guard case .success(let start) = checked else { Issue.record("a pinned host refused: \(refusal(checked) ?? "")"); return }
        #expect(start.server == Platform.CodeIdentity.cdhash(atPath: node.server) && start.build.host == own && start.serverPath == node.server)
        let made = try host(checked: start, arguments: given)
        defer { made.child?.stop() }
        #expect(made.child != nil, "a checked node host ran no server child")
        #expect(made.host.server.queue.sync { made.host.server.isMacNodeHost }, "a checked node host isn't a node host")
        #expect(made.host.server.queue.sync { made.host.server.welcomeCapabilities.contains(HostProtocol.Capability.vaultV2) })
        #expect(made.book.recordsActions, "a checked node host's book keeps no record")
        #expect(made.book.watchesMacList, "a checked node host's book doesn't watch the Mac seal list")
    }

    /// (b) A pinned host whose `--server` file is another build's server (pinned, but in another row), or no server the
    /// record names, or not the node root's own file, or a link, or another lock than the node root's: refused, and no
    /// server child. Red before: the start checked nothing.
    @Test func aPinnedHostWithAnotherBuildsServerIsRefused() throws {
        let node = try nodeRoot(server: "/bin/echo")
        let own = try #require(Platform.CodeIdentity.ownCdhash())
        let genuine = try nodeRoot(server: "/usr/bin/true")
        let pins = record([try row(host: own, server: genuine.server),
                           try row(host: Self.elsewhere, server: node.server, commit: Self.otherCommit)])
        let another = refusal(HostImages.macNodeStart(arguments: arguments(node), lockPath: node.lock, own: own, pins: pins, accountHome: node.home))
        #expect(another?.contains("isn't the server the node's record pins for this host's build \(Self.commit)") == true, "\(String(describing: another))")

        // The genuine server, given by a path that isn't the node root's own file (a copy elsewhere), or by a link to it.
        let copy = scratch.url("vsck-copy").path
        try FileManager.default.copyItem(atPath: genuine.server, toPath: copy)
        #expect(refusal(HostImages.macNodeStart(arguments: arguments(genuine, server: copy), lockPath: genuine.lock, own: own, pins: pins,
                                                accountHome: genuine.home))?.contains("isn't the node's own") == true)
        let link = scratch.url("vsck-link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: genuine.server)
        #expect(refusal(HostImages.macNodeStart(arguments: arguments(genuine, server: link), lockPath: genuine.lock, own: own, pins: pins,
                                                accountHome: genuine.home))?.contains("symbolic link") == true)
        // Another lock than the node root's: a scratch one, or the app's.
        for lock in [scratch.url("vsck-lock").path, (genuine.home as NSString).appendingPathComponent(".vibeswitcher/host.lock")] {
            #expect(refusal(HostImages.macNodeStart(arguments: arguments(genuine), lockPath: lock, own: own, pins: pins, accountHome: genuine.home))?
                        .contains("takes only the node root's own lock") == true, "\(lock)")
        }
        #expect(refusal(HostImages.macNodeStart(arguments: arguments(genuine), lockPath: genuine.lock, own: own, pins: pins, accountHome: nil)) != nil)
        // The genuine row and server pass.
        if case .failure(let why) = HostImages.macNodeStart(arguments: arguments(genuine), lockPath: genuine.lock, own: own, pins: pins, accountHome: genuine.home) {
            Issue.record("the genuine server refused: \(why)")
        }

        let refused = try host(checked: nil, arguments: arguments(node))
        defer { refused.child?.stop() }
        #expect(refused.child == nil, "a --node host with another build's server ran a server child")
    }
}

/// The blind check's item 1: a checked node host's switch proves the keeper against the cdhash the record was checked
/// against, read once. Here the target's file reads as the genuine pinned host the first time and as another image's
/// after (a file a session renames over it in between): the code expected of the keeper must be the genuine one, never
/// the second read's. Red before: the path was read again for the expected code, and the swapped image's passed.
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's switch through a keeper: code identity"))
struct MacKeeperTargetTests {
    @Test func theKeeperIsProvenAgainstTheCodeTheRecordWasCheckedAgainst() throws {
        let own = try #require(Platform.CodeIdentity.ownCdhash())
        let genuine = Data(repeating: 0x11, count: 20), swapped = Data(repeating: 0x22, count: 20)
        let row = NodePins.Build(commit: String(repeating: "a", count: 40), host: own, server: Data(repeating: 0x5e, count: 20), cli: Data(repeating: 0xc1, count: 20))
        let next = NodePins.Build(commit: String(repeating: "c", count: 40), host: genuine, server: Data(repeating: 0x5f, count: 20), cli: Data(repeating: 0xc2, count: 20))
        let checked = HostImages.CheckedNode(build: row, serverPath: "/usr/bin/true", server: row.server)
        let host = try TestHost(vault: LeadVault.Book(), appConnector: false, checkedNode: checked)
        let child = ServerChild.adopt(arguments: ["vibeswitcher-host", "--node", "--server", "/usr/bin/true"], ownsLaunchers: false, nodeRoot: "/nonexistent",
                                      config: host.server.config, server: host.server)
        defer { child?.stop() }
        try #require(host.server.queue.sync { host.server.isMacNodeHost })
        var reads = 0
        let target = host.server.queue.sync {
            host.server.keeperTarget("/b/c/bin/vibeswitcher-host", pins: .success(NodePins(uid: getuid(), builds: [row, next])), cdhashOf: { path in
                // The target's build's server answers as its row's (the review's N4 reads it too).
                if path.hasSuffix(BuildInfo.server) { return next.server }
                reads += 1
                return reads == 1 ? genuine : swapped
            })
        }
        guard case .success(let expected)? = target else { Issue.record("a pinned target refused: \(String(describing: target))"); return }
        #expect(expected == genuine, "the keeper would be proven against a second read of the path (\(NodePins.hex(expected)))")
        #expect(reads == 1, "the target's file was read \(reads) times")
    }
}

/// The advisor's check: a checked node's switch to another build. The new image is started with the target build's
/// `--node-root` and `--server` (its folder, `<folder>/bin/…`, as the unit and the agent start a build), so its own
/// checked start finds its row and that row's server; the lock stays the node's data root's. Red before: the new image
/// got the old build's `--server`, which isn't its row's, and refused: no switch to another build could pass.
extension MacKeeperTargetTests {
    @Test func aSwitchGivesTheNewImageItsOwnBuildsFolders() throws {
        let scratch = Scratch()
        let home = scratch.url("vskt").path
        let builds = (Platform.Service.nodeRoot(accountHome: home) as NSString).deletingLastPathComponent + "/builds"
        func folder(_ commit: String, server program: String) throws -> String {
            let folder = builds + "/" + commit
            try FileManager.default.createDirectory(atPath: folder + "/bin", withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: program, toPath: folder + "/bin/" + BuildInfo.server)
            return folder
        }
        let old = try folder(String(repeating: "a", count: 40), server: "/usr/bin/true")
        let new = try folder(String(repeating: "c", count: 40), server: "/bin/echo")
        let oldHost = Data(repeating: 0x11, count: 20), newHost = Data(repeating: 0x22, count: 20)
        func row(_ commit: Character, host: Data, folder: String) throws -> NodePins.Build {
            NodePins.Build(commit: String(repeating: commit, count: 40), host: host,
                           server: try #require(Platform.CodeIdentity.cdhash(atPath: folder + "/bin/" + BuildInfo.server)), cli: Data(repeating: 0xc1, count: 20))
        }
        let pins = Result<NodePins, NodePins.Refused>.success(NodePins(uid: getuid(), builds: [try row("a", host: oldHost, folder: old),
                                                                                               try row("c", host: newHost, folder: new)]))
        let lock = (Platform.Service.nodeRoot(accountHome: home) as NSString).appendingPathComponent("host.lock")
        let started = [HostImages.nodeFlag, HostImages.nodeRootFlag, old, "--server", old + "/bin/" + BuildInfo.server]
        if case .failure(let why) = HostImages.macNodeStart(arguments: ["vibeswitcher-host"] + started, lockPath: lock, own: oldHost, pins: pins, accountHome: home) {
            Issue.record("the old build's own start refused: \(why)")
        }
        let given = HostServer.keeperArguments(started: started, target: new + "/bin/vibeswitcher-host", checkedNode: true)
        if case .failure(let why) = HostImages.macNodeStart(arguments: ["vibeswitcher-host"] + given, lockPath: lock, own: newHost, pins: pins, accountHome: home) {
            Issue.record("the new image's start refused what the switch gave it: \(why)")
        }
        #expect(given.filter { $0 == "--server" }.count == 1 && given.filter { $0 == HostImages.nodeRootFlag }.count == 1, "\(given)")
        // A scratch host's switch (no checked node) keeps what it was started with.
        #expect(HostServer.keeperArguments(started: ["--server", "/x"], target: new + "/bin/vibeswitcher-host", checkedNode: false) == ["--server", "/x"])
    }
}
