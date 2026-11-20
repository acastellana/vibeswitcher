import Foundation
import Testing
import VibeCore

/// The node on the Mac's step 3 (docs/superpowers/specs/2026-11-19-v2-node-on-macos.md): the server child on the Mac,
/// without a sealed copy. A scratch host (`--server`, on a scratch root, its own lock) reads the server file's cdhash at
/// its start, starts the built `vibeswitcher-server` from the file, and answers its connector (a stream pair) only for
/// that child running that code under the Hardened Runtime (`ServerChild`'s `Image.checked`, `AppConnector`'s Mac
/// form). The server is a copy signed here with `codesign -s - -o runtime` (the build's own linker signature has no
/// Hardened Runtime). Mac only: Linux's server child is `ServerChildTests`' (VibeHostTests). Written on Linux, run on
/// the hosted Mac; a real Mac's Hardened Runtime and `task_for_pid` are docs/process/v2-mac-tasks.md's.
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's server child; Linux's is ServerChildTests'"), .serialized)
struct MacServerChildTests {
    let scratch = Scratch()

    /// A scratch root with a copy of the built server in `<root>/server/`, re-signed with the Hardened Runtime when
    /// `hardened`.
    func root(hardened: Bool) throws -> (root: URL, server: String) {
        let root = try scratch.shortFolder("vsmc")
        let folder = root.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let server = folder.appendingPathComponent("vibeswitcher-server").path
        try #require(try runToEnd("/bin/cp", [builtProducts.appendingPathComponent("vibeswitcher-server").path, server]) == 0)
        if hardened { try #require(try runToEnd("/usr/bin/codesign", ["--force", "-s", "-", "-o", "runtime", server]) == 0) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        return (root, server)
    }

    /// The built host on `root` with `--server server`, ended with this process (`--exit-with`).
    func host(root: URL, server: String) throws -> SpawnedHost {
        let host = builtProducts.appendingPathComponent("vibeswitcher-host").path
        let arguments = [host, "--socket", root.appendingPathComponent("host.sock").path, "--lock", root.appendingPathComponent("scratch-host.lock").path,
                         "--log", root.appendingPathComponent("host.log").path, "--idle-exit", "120", "--server", server,
                         "--exit-with", String(getpid())]
        var spawn = Platform.Spawn(executable: host, arguments: arguments)
        let home = root.appendingPathComponent("home").path
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

    func said(_ root: URL) -> String {
        ["host.log", "host.out"].map { (try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) ?? "" }.joined(separator: "\n")
    }

    func end(_ host: SpawnedHost) async {
        kill(host.processIdentifier, SIGTERM)
        _ = await exited(host)
    }

    /// The pid of the last server child the log says started.
    func lastChild(_ text: String) -> pid_t? {
        text.components(separatedBy: "\n").last { $0.contains("server child pid ") && $0.contains(" started from ") }
            .flatMap { $0.components(separatedBy: "server child pid ").last?.split(separator: " ").first }.flatMap { pid_t(String($0)) }
    }

    @Test func aHardenedServerFromItsCheckedFileIsTheApp() async throws {
        let (root, server) = try root(hardened: true)
        let host = try host(root: root, server: server)
        defer { kill(host.processIdentifier, SIGKILL); _ = host.isRunning }
        let connected = await eventually(timeout: 120) { said(root).contains("app connection made through connector") }
        #expect(connected, "\(said(root))")
        #expect(said(root).contains("started from \(server), its cdhash checked"), "\(said(root))")
        #expect(!said(root).contains("refused an app connection"), "\(said(root))")
        await end(host)
    }

    /// A server without the Hardened Runtime (the build's own linker signature): its request is refused and it is ended,
    /// as a dumpable server is on Linux; started again, and refused again.
    @Test func aServerWithoutTheHardenedRuntimeIsRefusedAndEnded() async throws {
        let (root, server) = try root(hardened: false)
        let host = try host(root: root, server: server)
        defer { kill(host.processIdentifier, SIGKILL); _ = host.isRunning }
        let refused = await eventually(timeout: 120) { said(root).contains("ended: it was dumpable when it asked for a connection") }
        #expect(refused, "\(said(root))")
        #expect(said(root).contains("doesn't run under the Hardened Runtime"), "\(said(root))")
        #expect(!said(root).contains("app connection made through connector"), "\(said(root))")
        await end(host)
    }

    /// The server file replaced after the host read its cdhash: its next start is refused (no child from other code),
    /// and none of the new file's processes is ever the app.
    @Test func aServerFileReplacedAfterTheStartStartsNothing() async throws {
        let (root, server) = try root(hardened: true)
        let host = try host(root: root, server: server)
        defer { kill(host.processIdentifier, SIGKILL); _ = host.isRunning }
        try #require(await eventually(timeout: 120) { said(root).contains("app connection made through connector") }, "\(said(root))")
        let child = try #require(lastChild(said(root)), "\(said(root))")
        // Another signature (the build's own, no Hardened Runtime): another cdhash. Put in place by a rename.
        let replacement = root.appendingPathComponent("replacement").path
        try #require(try runToEnd("/bin/cp", [builtProducts.appendingPathComponent("vibeswitcher-server").path, replacement]) == 0)
        try #require(rename(replacement, server) == 0)
        kill(child, SIGKILL)
        let refused = await eventually(timeout: 120) { said(root).contains("isn't the code the host loaded") }
        #expect(refused, "\(said(root))")
        let made = said(root).components(separatedBy: "\n").filter { $0.contains("app connection made through connector") }
        #expect(made.allSatisfy { $0.hasSuffix("for pid \(child)") }, "only the first child's: \(made)")
        await end(host)
    }
}
