import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// The node on the Mac's step 2 (docs/superpowers/specs/2026-11-19-v2-node-on-macos.md, "The root"): a host in the
/// environment a `--node` host gives itself (`HostImages.nodeEnvironment`) keeps its socket, its launcher copy and the
/// folders it makes in the node's root (`Platform.Service.nodeRoot`): on the Mac `~/.vibeswitcher/v2/node`, and nothing
/// of it at the app's `~/.vibeswitcher/host.*`; on Linux the account's `~/.vibeswitcher`, as before. A scratch host on
/// a scratch account home, never `--node` (that would be the user's, on their own home), on a lock of its own (not
/// the root's `host.lock`: a host on that is the user's host, whose vault key is the Keychain's on the Mac).
struct NodeRootHostTests {
    @Test func aHostInTheNodesEnvironmentKeepsItsFilesInTheNodesRoot() async throws {
        // Short: the root's socket, `<home>/.vibeswitcher/v2/node/host.sock`, is under the Mac's 104 bytes.
        let home = "\(shortScratchRoot)/vsnr-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let given = ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh", "VIBESWITCHER_HOME": home + "/elsewhere",
                     "CFFIXED_USER_HOME": home + "/fixed", "TMPDIR": ProcessInfo.processInfo.environment["TMPDIR"] ?? scratchRoot.path]
        var environment = HostImages.nodeEnvironment(given, accountHome: home, accountName: nil, shell: "/bin/sh")
        // The given VIBESWITCHER_HOME and CFFIXED_USER_HOME are gone; the root is the node's.
        #expect(environment["VIBESWITCHER_HOME"] != home + "/elsewhere" && environment["CFFIXED_USER_HOME"] == nil)
        let root = Platform.Service.nodeRoot(accountHome: home)
        // The Mac's `NSHomeDirectory()` follows CFFIXED_USER_HOME, not HOME: put back on the scratch home, so that
        // nothing in the host that asks it reaches the real one. It moves neither root: the Mac's is VIBESWITCHER_HOME's,
        // Linux's `<CFFIXED_USER_HOME>/.vibeswitcher`, the same home.
        environment["CFFIXED_USER_HOME"] = home
        #expect(VibePaths.root(environment: environment, fallbackHome: "/nonexistent").path == root)

        let host = Process()
        host.executableURL = URL(fileURLWithPath: hostLauncher)
        // No socket given: the root's own, `VibePaths.hostSocket`.
        host.arguments = ["--lock", root + "/scratch-host.lock", "--idle-exit", "60"]
        host.environment = environment
        host.standardInput = FileHandle.nullDevice
        host.standardError = FileHandle.nullDevice
        try TestHosts.run(host)
        defer { TestHosts.end(host) }
        let socket = root + "/host.sock"
        #expect(await eventually { Self.isSocket(socket) }, "no socket at \(socket)")
        #expect(host.isRunning)

        let accountFolder = home + "/.vibeswitcher"
        if Platform.Service.nodeRootIsTheAccountRoot {
            // Linux: the node's root is the account's folder.
            #expect(root == accountFolder)
        } else {
            // The Mac: the app's folder holds nothing but the way to the node's root; none of its host's files.
            #expect(root == accountFolder + "/v2/node")
            for name in ["host.sock", "host.lock", "host.log", "host", "lead", "state", "debug"] {
                #expect(!FileManager.default.fileExists(atPath: accountFolder + "/" + name), "\(accountFolder)/\(name)")
            }
            #expect((try? FileManager.default.contentsOfDirectory(atPath: accountFolder)) == ["v2"])
            #expect((try? FileManager.default.contentsOfDirectory(atPath: accountFolder + "/v2")) == ["node"])
        }
        // Nothing was made at the environment's own roots.
        #expect(!FileManager.default.fileExists(atPath: home + "/elsewhere"))
        #expect(!FileManager.default.fileExists(atPath: home + "/fixed"))
    }

    private static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
    }
}
