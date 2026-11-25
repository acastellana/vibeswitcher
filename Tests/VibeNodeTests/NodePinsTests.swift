import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeNode

/// The Mac node's anchor (the node on the Mac's design, "The anchor"; docs/process/v2-mac-tasks.md items 3, 10 and 12):
/// the node's checks find a build by the code a process runs, in a record only root can write, never by a file under
/// the user's home. The record here is a scratch tree with the installed record's shape
/// (`<scratch>/Library/Application Support/VibeSwitcher/node-<uid>.pins`), walked from the scratch folder (the walk's
/// top, `/` in the node), and this account's files counted as root's by an injected owner fact (a test can't make a
/// file root's). The processes are real: each "image" is a copy of the built host, signed here ad hoc with the
/// Hardened Runtime under an identifier of its own, so each has a cdhash of its own; started as a scratch host it
/// listens on its socket, and its audit token (read from a connection to it, as the command line reads the server's)
/// runs that code. What a process listens as doesn't matter to these checks: only the code its token runs does.
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's anchor: code identity"), .serialized)
struct NodePinsAnchorTests {
    let scratch = Scratch()
    let uid = getuid()

    /// A copy of the built host at `path`, signed with the Hardened Runtime as `identifier`: its cdhash.
    func image(_ path: URL, _ identifier: String) throws -> Data {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(try runToEnd("/bin/cp", [builtProducts.appendingPathComponent("vibeswitcher-host").path, path.path]) == 0)
        try #require(try runToEnd("/usr/bin/codesign", ["--force", "-s", "-", "-o", "runtime", "-i", identifier, path.path]) == 0)
        return try #require(Platform.CodeIdentity.cdhash(atPath: path.path))
    }

    /// A build folder `<prefix>/<commit>/bin` with a host, a server and a command line, each an image of its own: the
    /// build's row as the record would pin it.
    func build(_ prefix: URL, _ commit: String, server serverIdentifier: String? = nil) throws -> NodePins.Build {
        let bin = prefix.appendingPathComponent(commit).appendingPathComponent("bin")
        let host = try image(bin.appendingPathComponent("vibeswitcher-host"), "dev.vibeswitcher.test.host.\(commit.prefix(6))")
        let server = try image(bin.appendingPathComponent("vibeswitcher-server"), serverIdentifier ?? "dev.vibeswitcher.test.server.\(commit.prefix(6))")
        let cli = try image(bin.appendingPathComponent("vibeswitcher"), "dev.vibeswitcher.test.cli.\(commit.prefix(6))")
        return NodePins.Build(commit: commit, host: host, server: server, cli: cli)
    }

    /// The record for `builds`, written with the installed record's shape below `base` (folders 0755, the file 0644):
    /// its components.
    @discardableResult
    func record(_ builds: [NodePins.Build], in base: URL) throws -> [String] {
        let components = ["Library", "Application Support", "VibeSwitcher", "node-\(uid).pins"]
        var folder = base
        for name in components.dropLast() {
            folder = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            chmod(folder.path, 0o755)
        }
        let file = folder.appendingPathComponent(components.last!)
        try Data(NodePins(uid: uid, builds: builds).text.utf8).write(to: file)
        chmod(file.path, 0o644)
        return components
    }

    /// This account's files as root's (the owner fact a test can give), everyone else's as they are.
    var asRoot: (String, uid_t) -> uid_t { { [uid] _, owner in owner == uid ? 0 : owner } }

    /// A scratch host started from `image`, listening on `<root>/host.sock`; ended with this process.
    func listener(_ image: String, root: URL) throws -> SpawnedHost {
        let arguments = [image, "--socket", root.appendingPathComponent("host.sock").path, "--lock", root.appendingPathComponent("scratch-host.lock").path,
                         "--log", root.appendingPathComponent("host.log").path, "--idle-exit", "120", "--exit-with", String(getpid())]
        var spawn = Platform.Spawn(executable: image, arguments: arguments)
        let home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        spawn.environment = ["VIBESWITCHER_HOME=\(root.path)", "HOME=\(home)", "CFFIXED_USER_HOME=\(home)", "PATH=/usr/bin:/bin", "SHELL=/bin/sh",
                             "TMPDIR=\(scratchRoot.path)"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .path(root.appendingPathComponent("host.out").path, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600)
        spawn.stderr = .path(root.appendingPathComponent("host.out").path, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600)
        spawn.group = .ownGroup
        switch spawn.start() {
        case .failure(let error): throw error
        case .success(let pid): return SpawnedHost(pid: pid)
        }
    }

    /// A connection to the socket at `path` once it accepts one (waited for, never slept): its descriptor.
    func connection(_ path: String) async -> Int32? {
        var made: Int32?
        _ = await eventually(timeout: 120) {
            let fd = socket(AF_UNIX, Platform.Sockets.stream, 0)
            guard fd >= 0, var address = Platform.Sockets.unixAddress(path) else { return false }
            let joined = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if joined == 0 { made = fd; return true }
            close(fd)
            return false
        }
        return made
    }

    /// The image at `path` running, its token as a connection reads it, and an end for it.
    func running(_ path: String) async throws -> (token: Platform.PeerToken, end: () async -> Void) {
        let root = try scratch.shortFolder("vspn")
        let host = try listener(path, root: root)
        guard let fd = await connection(root.appendingPathComponent("host.sock").path) else {
            kill(host.processIdentifier, SIGKILL)
            _ = await exited(host)
            Issue.record("\(path) never listened: \((try? String(contentsOf: root.appendingPathComponent("host.out"), encoding: .utf8)) ?? "")")
            throw CancellationError()
        }
        let token = try #require(Platform.Sockets.peerToken(fd))
        try #require(token.pid == host.processIdentifier)
        return (token, {
            close(fd)
            kill(host.processIdentifier, SIGTERM)
            _ = await exited(host)
        })
    }

    static let genuine = String(repeating: "a", count: 40)
    static let other = String(repeating: "b", count: 40)
    static let next = String(repeating: "c", count: 40)

    // MARK: (a) The fake server of item 10

    /// Item 10's attack: a genuine host and another server image in a builds folder a session made, the agent's plist
    /// rewritten so the job's program is that host (`launchctl bootout`, then `bootstrap` from any path). Before the
    /// record, the check took the server beside the job's program, and the fake one passed it. Now the listener's code
    /// must be a server the record pins: refused. The genuine server still passes, whatever the job's program says.
    @Test func aFakeServerBesideAGenuineHostIsRefused() async throws {
        let top = try scratch.shortFolder("vspa")
        let prefix = top.appendingPathComponent("builds")
        let genuine = try build(prefix, Self.genuine)
        // The session's build: the genuine host copied (the same code), another server image.
        let fake = prefix.appendingPathComponent(Self.other).appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try #require(try runToEnd("/bin/cp", [prefix.appendingPathComponent(Self.genuine).appendingPathComponent("bin/vibeswitcher-host").path,
                                              fake.appendingPathComponent("vibeswitcher-host").path]) == 0)
        let fakeServer = try image(fake.appendingPathComponent("vibeswitcher-server"), "dev.vibeswitcher.test.fake-server")
        #expect(fakeServer != genuine.server)
        let base = top.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let components = try record([genuine], in: base)
        let pins = NodePins.read(uid: uid, components: components, base: base.path, owner: asRoot)
        guard case .success = pins else { Issue.record("the record: \(pins)"); return }
        let realPrefix = try #require(NodeCheck.resolved(prefix.path))
        let rewritten = NodeAgent.Printed(pid: 1, program: fake.appendingPathComponent("vibeswitcher-host").path)

        let (fakeToken, endFake) = try await running(fake.appendingPathComponent("vibeswitcher-server").path)
        let answer = NodeCheck.macServerCode(token: fakeToken, job: rewritten, prefix: realPrefix, pins: pins)
        await endFake()
        #expect(answer != .runs, "the fake server passed: \(answer)")
        #expect(answer.why?.contains("no server the node's record pins") == true, "\(answer)")
        var listener = NodeCheck.Listener(pid: 50, dumpable: nil, parent: 40, cgroup: nil, session: 40, code: answer.told)
        listener.codeWhy = answer.why
        #expect(NodeCheck.refusal(listener, mode: .node, expectedParent: 40, parentSession: 40, codeIdentity: true) != nil)

        // The genuine server passes, with the job's program the session's host or the genuine one.
        let (token, end) = try await running(prefix.appendingPathComponent(Self.genuine).appendingPathComponent("bin/vibeswitcher-server").path)
        let genuineJob = NodeAgent.Printed(pid: 1, program: prefix.appendingPathComponent(Self.genuine).appendingPathComponent("bin/vibeswitcher-host").path)
        #expect(NodeCheck.macServerCode(token: token, job: genuineJob, prefix: realPrefix, pins: pins) == .runs)
        #expect(NodeCheck.macServerCode(token: token, job: rewritten, prefix: realPrefix, pins: pins) == .runs)
        await end()
    }

    /// The host's half of item 10: a node host finds its build by its own running code, and starts only the server that
    /// row pins. Another server image at its `--server`, or a host the record doesn't name, starts nothing.
    @Test func theHostStartsOnlyTheServerItsOwnRowPins() throws {
        let top = try scratch.shortFolder("vsph")
        let prefix = top.appendingPathComponent("builds")
        let genuine = try build(prefix, Self.genuine)
        let fakeServer = prefix.appendingPathComponent(Self.genuine).appendingPathComponent("bin/fake-server")
        let fakeHash = try image(fakeServer, "dev.vibeswitcher.test.fake-server")
        let server = prefix.appendingPathComponent(Self.genuine).appendingPathComponent("bin/vibeswitcher-server").path
        let pins: Result<NodePins, NodePins.Refused> = .success(NodePins(uid: uid, builds: [genuine]))
        #expect(HostImages.macServerPin(server: server, own: genuine.host, pins: pins) == .success(genuine.server))
        guard case .failure(let why) = HostImages.macServerPin(server: fakeServer.path, own: genuine.host, pins: pins) else {
            Issue.record("another server image at --server was taken (\(NodePins.hex(fakeHash)))")
            return
        }
        #expect(why.description.contains("isn't the server"), "\(why)")
        if case .success = HostImages.macServerPin(server: server, own: fakeHash, pins: pins) { Issue.record("a host the record doesn't name started a server") }
        if case .success = HostImages.macServerPin(server: server, own: nil, pins: pins) { Issue.record("a host whose code can't be read started a server") }
        if case .success = HostImages.macServerPin(server: server, own: genuine.host, pins: .failure(NodePins.Refused("missing"))) {
            Issue.record("a server started with no record")
        }
    }

    // MARK: (b) The command line swapped in <root>/bin after the host's start

    /// Item 3's owed half: the server takes the command line's cdhash from the record's row for its own running code,
    /// never from `<root>/bin/vibeswitcher`. A command line swapped there after the host's start (another image) is
    /// not the installed one: a process running it is refused, and the genuine one still passes.
    @Test func aCommandLineSwappedInTheBuildAfterTheStartIsRefused() async throws {
        let top = try scratch.shortFolder("vspb")
        let prefix = top.appendingPathComponent("builds")
        let genuine = try build(prefix, Self.genuine)
        let root = prefix.appendingPathComponent(Self.genuine).path
        let pins: Result<NodePins, NodePins.Refused> = .success(NodePins(uid: uid, builds: [genuine]))
        // Kept aside, to run: the genuine command line's image.
        let kept = top.appendingPathComponent("kept-cli")
        try #require(try runToEnd("/bin/cp", ["\(root)/bin/vibeswitcher", kept.path]) == 0)
        // The swap, after the host's start: another image renamed over `<root>/bin/vibeswitcher`.
        let swapped = top.appendingPathComponent("swapped-cli")
        let swappedHash = try image(swapped, "dev.vibeswitcher.test.swapped-cli")
        let staged = "\(root)/bin/vibeswitcher.new"
        try #require(try runToEnd("/bin/cp", [swapped.path, staged]) == 0)
        try #require(rename(staged, "\(root)/bin/vibeswitcher") == 0)
        // The server's start (a restart after the swap reads it again).
        let anchor = ApprovalVoice.commandLineAnchor(nodeRoot: root, own: genuine.server, pins: pins)
        #expect(anchor == genuine.cli, "the anchor is \(anchor.map(NodePins.hex) ?? "nil"), the swapped file's \(NodePins.hex(swappedHash))")
        let (swappedToken, endSwapped) = try await running(swapped.path)
        #expect(!anchor.map { Platform.CodeIdentity.runs(swappedToken, cdhash: $0) }.isTrue, "the swapped command line is taken for the installed one")
        await endSwapped()
        let (keptToken, endKept) = try await running(kept.path)
        #expect(anchor.map { Platform.CodeIdentity.runs(keptToken, cdhash: $0) }.isTrue, "the genuine command line isn't taken")
        await endKept()
        // A server the record doesn't name, or no record: no command line is the installed one.
        #expect(ApprovalVoice.commandLineAnchor(nodeRoot: root, own: swappedHash, pins: pins) == nil)
        #expect(ApprovalVoice.commandLineAnchor(nodeRoot: root, own: genuine.server, pins: .failure(NodePins.Refused("missing"))) == nil)
    }

    // MARK: (c) A record that isn't root's alone

    /// The record missing, a link, writable by its group or others, under a folder writable by others, owned by the
    /// user (by the owner fact), carrying an extra link, or naming another uid: each refused with a line naming it,
    /// and the check refuses the genuine server then (it can't be told). Read with the node's own facts (from `/`, the
    /// owners as they are), the same scratch record is refused: its folders are the user's.
    @Test func aRecordThatIsntRootsAloneIsRefused() async throws {
        let top = try scratch.shortFolder("vspc")
        let prefix = top.appendingPathComponent("builds")
        let genuine = try build(prefix, Self.genuine)
        let realPrefix = try #require(NodeCheck.resolved(prefix.path))
        let job = NodeAgent.Printed(pid: 1, program: prefix.appendingPathComponent(Self.genuine).appendingPathComponent("bin/vibeswitcher-host").path)
        let (token, end) = try await running(prefix.appendingPathComponent(Self.genuine).appendingPathComponent("bin/vibeswitcher-server").path)
        var cases = 0
        func refused(_ name: String, owner: ((String, uid_t) -> uid_t)? = nil, _ change: (URL, [String]) throws -> Void) throws {
            cases += 1
            let base = top.appendingPathComponent("base-\(cases)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            let components = try record([genuine], in: base)
            try change(base, components)
            let pins = NodePins.read(uid: uid, components: components, base: base.path, owner: owner ?? asRoot)
            guard case .failure(let why) = pins else { Issue.record("\(name): the record was taken"); return }
            #expect(why.description.contains(NodePins.remedy), "\(name): \(why)")
            let answer = NodeCheck.macServerCode(token: token, job: job, prefix: realPrefix, pins: pins)
            #expect(answer.told == nil, "\(name): \(answer)")
            #expect(answer.why == why.description, "\(name): \(answer)")
        }
        // First, the same tree untouched passes.
        let good = top.appendingPathComponent("base-good")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let goodComponents = try record([genuine], in: good)
        let pins = NodePins.read(uid: uid, components: goodComponents, base: good.path, owner: asRoot)
        #expect(NodeCheck.macServerCode(token: token, job: job, prefix: realPrefix, pins: pins) == .runs)

        func path(_ base: URL, _ components: [String], _ count: Int) -> String {
            components.prefix(count).reduce(base.path) { $0 + "/" + $1 }
        }
        try refused("missing") { base, components in try FileManager.default.removeItem(atPath: path(base, components, 4)) }
        try refused("the record a link") { base, components in
            let file = path(base, components, 4)
            try FileManager.default.moveItem(atPath: file, toPath: file + ".real")
            try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: file + ".real")
        }
        try refused("a folder above a link") { base, components in
            let folder = path(base, components, 3)
            try FileManager.default.moveItem(atPath: folder, toPath: folder + ".real")
            try FileManager.default.createSymbolicLink(atPath: folder, withDestinationPath: folder + ".real")
        }
        try refused("the record group-writable") { base, components in chmod(path(base, components, 4), 0o664) }
        try refused("the record world-writable") { base, components in chmod(path(base, components, 4), 0o646) }
        try refused("its folder writable by the group (admin)") { base, components in chmod(path(base, components, 3), 0o775) }
        try refused("a folder above it writable by others") { base, components in chmod(path(base, components, 2), 0o757) }
        try refused("the walk's top writable by others") { base, _ in chmod(base.path, 0o777) }
        try refused("an ACL on a folder above it") { base, components in
            try #require(try runToEnd("/bin/chmod", ["+a", "everyone allow add_file", path(base, components, 2)]) == 0)
        }
        try refused("a second link to the record") { base, components in
            #expect(link(path(base, components, 4), base.appendingPathComponent("other-link").path) == 0)
        }
        try refused("the record not a file") { base, components in
            let file = path(base, components, 4)
            try FileManager.default.removeItem(atPath: file)
            try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
        try refused("another uid's") { base, components in
            try Data(NodePins(uid: uid + 1, builds: [genuine]).text.utf8).write(to: URL(fileURLWithPath: path(base, components, 4)))
        }
        try refused("not parseable") { base, components in
            try Data("format 1\nuid \(uid)\nbuild x\n".utf8).write(to: URL(fileURLWithPath: path(base, components, 4)))
        }
        let me = uid
        let recordName = goodComponents.last!
        try refused("the record owned by the user (the uid fact)", owner: { path, owner in
            path.hasSuffix("/" + recordName) ? owner : (owner == me ? 0 : owner)
        }) { _, _ in }
        // The node's own facts: walked from `/`, the owners as they are. The scratch folders are this account's.
        let real = NodePins.read(uid: uid, components: good.path.split(separator: "/").map(String.init) + goodComponents)
        guard case .failure(let why) = real else { await end(); Issue.record("a record in the user's folders was taken"); return }
        #expect(why.description.contains(NodePins.remedy), "\(why)")
        // The installed record's own place on the Mac, root's folders from `/`.
        #expect(NodePins.installedPath(uid: 501) == ["Library", "Application Support", "VibeSwitcher", "node-501.pins"])
        await end()
    }

    // MARK: (d) A switch stays inside the record

    /// A switch or a rollback to a build the record pins passes; to a build outside it (a host image the record
    /// doesn't name) it is refused before the handover. And the check of the server (item 12) follows the running code,
    /// not the job's program: after an in-place switch (the plist rewritten to the next build, the host handed over)
    /// the genuine server running passes, and so does the next build's once it runs.
    @Test func aSwitchToAPinnedBuildPassesAndToAnotherIsRefused() async throws {
        let top = try scratch.shortFolder("vspd")
        let prefix = top.appendingPathComponent("builds")
        let first = try build(prefix, Self.genuine)
        let next = try build(prefix, Self.next)
        let outside = try build(prefix, Self.other)
        let pins: Result<NodePins, NodePins.Refused> = .success(NodePins(uid: uid, builds: [next, first]))
        func host(_ commit: String) -> String { prefix.appendingPathComponent(commit).appendingPathComponent("bin/vibeswitcher-host").path }
        #expect(HandoverTarget.macPinned(host(Self.next), pins: pins) == nil)
        #expect(HandoverTarget.macPinned(host(Self.genuine), pins: pins) == nil, "a rollback to a pinned build")
        let refused = HandoverTarget.macPinned(host(Self.other), pins: pins)
        #expect(refused?.description.contains("isn't a host the node's record pins") == true, "\(String(describing: refused)) (\(NodePins.hex(outside.host)))")
        #expect(HandoverTarget.macPinned(host(Self.next), pins: .failure(NodePins.Refused("missing"))) != nil)
        #expect(HandoverTarget.macPinned(top.appendingPathComponent("nothing").path, pins: pins) != nil)

        // Item 12: the job's program already names the next build while the first build's server still runs.
        let realPrefix = try #require(NodeCheck.resolved(prefix.path))
        let switched = NodeAgent.Printed(pid: 1, program: host(Self.next))
        let (token, end) = try await running(prefix.appendingPathComponent(Self.genuine).appendingPathComponent("bin/vibeswitcher-server").path)
        #expect(NodeCheck.macServerCode(token: token, job: switched, prefix: realPrefix, pins: pins) == .runs)
        await end()
    }
}

/// The record's text (`NodePins.parse`): the format, the uid, the builds, refused whole on anything else. Both systems.
struct NodePinsFormatTests {
    let a = Data(repeating: 0xaa, count: 20), b = Data(repeating: 0xbb, count: 20), c = Data(repeating: 0xcc, count: 20)
    let d = Data(repeating: 0xdd, count: 20), e = Data(repeating: 0xee, count: 20), f = Data(repeating: 0xff, count: 20)

    @Test func aRecordIsReadWholeOrRefused() {
        let one = NodePins.Build(commit: String(repeating: "1", count: 40), host: a, server: b, cli: c)
        let two = NodePins.Build(commit: String(repeating: "2", count: 40), host: d, server: e, cli: f)
        let pins = NodePins(uid: 501, builds: [one, two])
        #expect(NodePins.parse(Data(pins.text.utf8), uid: 501) == .success(pins))
        #expect(pins.build(server: e) == two && pins.build(host: a) == one && pins.build(server: a) == nil)
        let good = pins.text
        var bad: [(String, String)] = []
        bad.append(("another uid", good.replacingOccurrences(of: "uid 501", with: "uid 502")))
        bad.append(("no line's end", String(good.dropLast())))
        bad.append(("another format", good.replacingOccurrences(of: "format 1", with: "format 2")))
        bad.append(("uppercase", good.replacingOccurrences(of: "aaaa", with: "AAAA")))
        bad.append(("a short cdhash", good.replacingOccurrences(of: "aaaa", with: "aaa")))
        bad.append(("an empty line", good + "\n"))
        bad.append(("a tab", good.replacingOccurrences(of: " host ", with: "\thost ")))
        bad.append(("two spaces", good.replacingOccurrences(of: " host ", with: "  host ")))
        bad.append(("an unknown line", good + "trust everything\n"))
        bad.append(("a leading zero uid", good.replacingOccurrences(of: "uid 501", with: "uid 0501")))
        bad.append(("a commit twice", good + one.line + "\n"))
        bad.append(("a cdhash twice", good + NodePins.Build(commit: String(repeating: "3", count: 40), host: a, server: Data(repeating: 1, count: 20), cli: Data(repeating: 2, count: 20)).line + "\n"))
        bad.append(("no build", "format 1\nuid 501\n"))
        bad.append(("a NUL", good.replacingOccurrences(of: "uid 501", with: "uid 501\0")))
        bad.append(("not ASCII", good.replacingOccurrences(of: "# VibeSwitcher", with: "# VibéSwitcher")))
        for (name, text) in bad {
            guard case .failure = NodePins.parse(Data(text.utf8), uid: 501) else { Issue.record("\(name) was taken"); continue }
        }
        var builds: [NodePins.Build] = []
        for index in 0..<17 {
            let byte = UInt8(index * 3)
            builds.append(NodePins.Build(commit: String(format: "%040x", index), host: Data(repeating: byte, count: 20),
                                         server: Data(repeating: byte + 1, count: 20), cli: Data(repeating: byte + 2, count: 20)))
        }
        let many = NodePins(uid: 501, builds: builds)
        guard case .failure = NodePins.parse(Data(many.text.utf8), uid: 501) else { Issue.record("17 builds were taken"); return }
    }
}

private extension Optional where Wrapped == Bool {
    var isTrue: Bool { self == true }
}
