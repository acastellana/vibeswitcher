import Foundation
import Testing
import VibeCore
import VibeNode

/// The command line's check of the server it reached (the engine plan's EN-D8, the security architecture document's
/// S3), run as built.
@Suite(NodeTraits.linuxOnly)
struct ServerCheckTests {
    private let scratch = Scratch()

    /// A root of a test's own with its `v2/` folder, and the command line's environment on it.
    private func root(_ prefix: String) throws -> (root: URL, environment: [String: String]) {
        let root = try scratch.shortFolder(prefix)
        try VibePaths.ensurePrivate(root.appendingPathComponent("v2"))
        var environment = scratchEnvironment(root)
        environment["VIBESWITCHER_HOME"] = root.path
        return (root, environment)
    }

    @Test func theCommandLineRefusesADumpableListener() async throws {
        let (root, environment) = try self.root("vsd")
        // A plain socket this test process (dumpable) listens on, at the server's path.
        let listener = try UnixSocket.listen(path: root.appendingPathComponent("v2/server.sock").path)
        defer { Sys.close(listener) }
        let ran = try await run(commandLine, ["status"], environment: environment)
        #expect(ran.status == 77, "\(ran.errors)")
        #expect(ran.errors.contains("is dumpable: not the node's server"), "\(ran.errors)")
    }

    @Test func theCommandLineRefusesAServerThatIsntTheHostsChild() async throws {
        let (root, environment) = try self.root("vsf")
        // A hardened listener: the built server, started by this test, not by the process holding the scratch lock.
        let lock = root.appendingPathComponent(NodeCheck.scratchLock).path
        FileManager.default.createFile(atPath: lock, contents: nil)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/flock")
        // `-o`: the lock stays flock's own, not its command's, so it goes with flock.
        holder.arguments = ["-o", lock, "sleep", "600"]
        holder.standardInput = FileHandle.nullDevice
        try holder.run()
        defer {
            for child in Platform.Processes.children(holder.processIdentifier) { kill(child, SIGKILL) }
            kill(holder.processIdentifier, SIGKILL)
        }
        try #require(await eventually(timeout: 30) { Platform.Processes.lockHolder(path: lock) == holder.processIdentifier })
        guard let (serverEnd, testEnd) = Platform.Sockets.pair(type: Platform.Sockets.seqpacket) else { throw CancellationError() }
        defer { Sys.close(testEnd) }
        let server = Process()
        server.executableURL = builtProducts.appendingPathComponent("vibeswitcher-server")
        server.arguments = ["--host-connector", "0", "--host-socket", root.appendingPathComponent("host.sock").path, "--root", root.path]
        server.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
        server.standardInput = FileHandle(fileDescriptor: serverEnd, closeOnDealloc: false)
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        Sys.close(serverEnd)
        defer { kill(server.processIdentifier, SIGKILL) }
        try #require(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: root.appendingPathComponent("v2/server.sock").path) })
        #expect(Platform.Processes.isDumpable(server.processIdentifier) == false)
        let ran = try await run(commandLine, ["status"], environment: environment)
        #expect(ran.status == 77, "\(ran.errors)")
        #expect(ran.errors.contains("isn't a child of the node's host (pid \(holder.processIdentifier))"), "\(ran.errors)")
        // With no one holding the lock, it can't be checked at all: refused too.
        for child in Platform.Processes.children(holder.processIdentifier) { kill(child, SIGKILL) }
        kill(holder.processIdentifier, SIGKILL)
        _ = await exited(holder, within: 30)
        try #require(await eventually(timeout: 30) { Platform.Processes.lockHolder(path: lock) == nil })
        let unheld = try await run(commandLine, ["status"], environment: environment)
        #expect(unheld.status == 77 && unheld.errors.contains("no process holds the scratch node's lock"), "\(unheld.errors)")
    }

    @Test func theCommandLineWithNoNodeSaysSoNotConnectionRefused() async throws {
        let (root, environment) = try self.root("vsx")
        for arguments in [["status"], ["stop"], ["start", "--interop-is-on"]] {
            let ran = try await run(commandLine, arguments, environment: environment)
            #expect(ran.status == 69, "\(arguments): \(ran.errors)")
            #expect(ran.errors.contains("the node isn't running"), "\(arguments): \(ran.errors)")
            #expect(!ran.errors.contains("Connection refused") && !ran.errors.contains("connect:"), "\(ran.errors)")
        }
        let status = try await run(commandLine, ["status"], environment: environment)
        #expect(status.errors.contains("status --probe"), "\(status.errors)")
        // A socket file no one listens on any more: the same.
        let listener = try UnixSocket.listen(path: root.appendingPathComponent("v2/server.sock").path)
        Sys.close(listener)
        let stale = try await run(commandLine, ["status"], environment: environment)
        #expect(stale.status == 69 && stale.errors.contains("the node isn't running"), "\(stale.errors)")
    }

    @Test func aScratchNodeIsNamedOnStderr() async throws {
        let node = try await ScratchNode(scratch)
        for arguments in [["status"], ["status", "--json"]] {
            let ran = try await node.run(arguments)
            #expect(ran.status == 0, "\(ran.errors)")
            #expect(ran.errors.contains("scratch node at \(node.root.standardizedFileURL.path)"), "\(arguments): \(ran.errors)")
            #expect(!ran.output.contains("scratch node at"))
        }
    }

    @Test func aScratchHomeThatIsTheAccountsOwnGetsTheNodesCheck() {
        let account = "/home/someone"
        #expect(NodeCheck.mode(vibeswitcherHome: "/home/someone/.vibeswitcher", accountHome: account) == .node)
        #expect(NodeCheck.mode(vibeswitcherHome: "/home/someone/./.vibeswitcher/", accountHome: account) == .node)
        #expect(NodeCheck.mode(vibeswitcherHome: "/home/someone/x/../.vibeswitcher", accountHome: account) == .node)
        #expect(NodeCheck.mode(vibeswitcherHome: nil, accountHome: account) == .node)
        #expect(NodeCheck.mode(vibeswitcherHome: "relative/root", accountHome: account) == .node)
        #expect(NodeCheck.mode(vibeswitcherHome: "/srv/vsn-1", accountHome: account) == .scratch(root: "/srv/vsn-1"))
        #expect(NodeCheck.mode(vibeswitcherHome: "/home/someone/.build/scratchhome", accountHome: account) == .scratch(root: "/home/someone/.build/scratchhome"))
        // The node's check: non-dumpable, in the node's unit, a child of the unit's main process.
        let unit = ["0::/user.slice/user-1000.slice/user@1000.service/app.slice/vibeswitcher-node.service"]
        let good = NodeCheck.Listener(pid: 50, dumpable: false, parent: 40, cgroup: unit)
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: 40) == nil)
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: 41) != nil)
        #expect(NodeCheck.refusal(good, mode: .node, expectedParent: nil) != nil)
        var outside = good
        outside.cgroup = ["0::/init.scope"]
        #expect(NodeCheck.refusal(outside, mode: .node, expectedParent: 40)?.contains("isn't in vibeswitcher-node.service") == true)
        // A scratch node doesn't ask the cgroup; both ask dumpable and the parent.
        #expect(NodeCheck.refusal(outside, mode: .scratch(root: "/srv/x"), expectedParent: 40) == nil)
        var dumpable = good
        dumpable.dumpable = true
        #expect(NodeCheck.refusal(dumpable, mode: .scratch(root: "/srv/x"), expectedParent: 40) != nil)
        dumpable.dumpable = nil
        #expect(NodeCheck.refusal(dumpable, mode: .node, expectedParent: 40) != nil)
    }
}
