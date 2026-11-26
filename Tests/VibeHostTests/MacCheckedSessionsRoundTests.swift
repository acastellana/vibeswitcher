import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The review's round, taken over from the reviewer: what a starter plants in a checked-shaped scratch host's environment, and what reaches its session.
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's checked node"))
struct MacCheckedSessionsRoundTests {
    @Test func nothingTheStarterPlantsReachesASession() async throws {
        let scratch = Scratch()
        defer { withExtendedLifetime(scratch) {} }
        let outside = String(shortScratchRoot) + "/vsrp-\(UUID().uuidString.prefix(6))"
        scratch.adopt(URL(fileURLWithPath: outside))
        let markers = outside + "/markers", zdot = outside + "/zdot", hook = outside + "/hook.sh", plantedSocket = outside + "/a.sock"
        for folder in [markers, zdot] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try "touch \(markers)/hook-ran\n".write(toFile: hook, atomically: true, encoding: .utf8)
        for name in [".zshenv", ".zshrc", ".zprofile", ".zlogin"] {
            try "touch \(markers)/zdotdir-\(name)\n".write(toFile: zdot + "/" + name, atomically: true, encoding: .utf8)
        }
        let listener = try UnixSocket.listen(path: plantedSocket)
        defer { Sys.close(listener) }
        var home = ""
        let plantedHome = outside + "/home", plantedRoot = outside + "/root"
        for folder in [plantedHome, plantedRoot] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        for name in [".zshenv", ".zshrc", ".zprofile", ".zlogin", ".bash_profile", ".profile", ".bashrc"] {
            try "touch \(markers)/planted-home-\(name)\n".write(toFile: plantedHome + "/" + name, atomically: true, encoding: .utf8)
        }
        // No DYLD_INSERT_LIBRARIES: dyld aborts this unhardened scratch host on a missing one before main (its crash
        // report, 2026-11-26 02:10); a checked node is hardened, and start refuses one in launchd's environment.
        // A shell other than the account's own: the session's SHELL is the user database's, so planting that one
        // would prove nothing (GitHub's Mac runner's account has bash, a user's Mac zsh).
        let plantedShell = MacCheckedSessionsTests.accountShell == "/bin/bash" ? "/bin/zsh" : "/bin/bash"
        let planted = ["VIBESWITCHER_ANYTHING": "planted", "VIBESWITCHER_HOME": plantedRoot, "HOME": plantedHome, "CFFIXED_USER_HOME": plantedHome,
                       "DYLD_LIBRARY_PATH": "/planted-lib", "PATH": "/planted/bin:/usr/bin:/bin", "SSH_AUTH_SOCK": plantedSocket,
                       "BASH_ENV": hook, "ENV": hook, "ZDOTDIR": zdot,
                       "SHELL": plantedShell, "LANG": "xx_PLANTED.UTF-8", "LC_ALL": "xx_PLANTED.UTF-8", "VIBESWITCHER_LEAD_ROLE": "planted",
                       "SWIFT_BACKTRACE": "enable=yes"]
        let second = try await ScratchHostProcess(environment: planted, prepare: { dir in
            home = dir + "/shaped"
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            try MacCheckedSessionsTests.writeLoginMarker(home: home)
        }, late: { [CheckedSessions.testShapeFlag, home] })
        defer { second.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(second.socket, appKey: second.appKey)
        let session = try await client.spawn("env; echo umask=$(umask); echo shell=$0; echo DONE-ENV", cwd: home)
        await client.attach(session.id)
        #expect(await eventually { client.text(session.id).contains("DONE-ENV") }, "\(client.text(session.id))\n\(second.log)")
        let text = client.text(session.id).replacingOccurrences(of: "\r", with: "")
        let lines = text.split(separator: "\n").map(String.init)
        func value(_ name: String) -> String? { lines.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } }
        print("ROUND session env:\n" + lines.filter { $0.contains("=") }.sorted().joined(separator: "\n"))
        for (name, plantedValue) in planted where name != "PATH" {
            #expect(value(name) != plantedValue, "\(name)=\(plantedValue) reached the session")
        }
        #expect(value("PATH")?.contains("/planted/bin") == false, "PATH=\(value("PATH") ?? "none")")
        #expect(value("PATH")?.contains("/vs-login-marker") == true, "PATH=\(value("PATH") ?? "none")")
        #expect(!lines.contains { $0.hasPrefix("DYLD_") }, "a DYLD_ variable reached the session")
        #expect(value("SSH_AUTH_SOCK") == MacCheckedSessionsTests.launchdSocket())
        #expect(value("umask").flatMap { Int($0, radix: 8) } == 0o022)
        #expect(value("LANG") == "en_US.UTF-8")
        let ran = (try? FileManager.default.contentsOfDirectory(atPath: markers)) ?? []
        #expect(ran.isEmpty, "the starter's files ran in the session: \(ran)")
    }

    /// `CheckedSessions.read`'s socket rule with injected readers: only an absolute path whose owner (a socket, no link
    /// followed) is the uid is taken.
    @Test func theSocketRuleTakesOnlyTheUsersOwnSocket() throws {
        let uid = getuid()
        func read(_ value: String?, owner: uid_t?) -> String? {
            CheckedSessions.read(uid: uid, accountHome: "/nowhere", variable: { _ in value }, socketOwner: { _ in owner }, file: { _ in nil }).environment["SSH_AUTH_SOCK"]
        }
        #expect(read("/s/Listeners", owner: uid) == "/s/Listeners")
        #expect(read("/s/Listeners", owner: uid + 1) == nil)
        #expect(read("/s/Listeners", owner: nil) == nil)
        #expect(read("relative/sock", owner: uid) == nil)
        #expect(read("/s/a\nb", owner: uid) == nil)
        #expect(read(nil, owner: uid) == nil)
        // The real reader: a link to the user's socket, a regular file, the socket itself.
        let dir = String(shortScratchRoot) + "/vsrq-\(UUID().uuidString.prefix(6))"
        let scratch = Scratch()
        defer { withExtendedLifetime(scratch) {} }
        scratch.adopt(URL(fileURLWithPath: dir))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = try UnixSocket.listen(path: dir + "/s")
        defer { Sys.close(fd) }
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/s")
        FileManager.default.createFile(atPath: dir + "/file", contents: Data())
        #expect(CheckedSessions.socketOwner(dir + "/s") == uid)
        #expect(CheckedSessions.socketOwner(dir + "/link") == nil)
        #expect(CheckedSessions.socketOwner(dir + "/file") == nil)
        #expect(CheckedSessions.textEncoding(uid: 501, file: "0x8000100:0x0\n") == "0x1F5:0x8000100:0x0")
        #expect(CheckedSessions.textEncoding(uid: 501, file: "junk") == "0x1F5:0x0:0x0")
    }

    /// `--test-checked-shape`'s refusals: with `--node`, without `--lock`, the user's host's lock (and another spelling of
    /// it), the node's lock; a relative home.
    @Test func theTestShapeIsRefusedForTheUsersHostAndTheNode() {
        let users = VibePaths.hostLock.path
        let flag = CheckedSessions.testShapeFlag
        func refused(_ arguments: [String], node: Bool = false, lock: String?) -> Bool {
            if case .failure? = CheckedSessions.takeTestShape(arguments: arguments, isMacNode: node, lock: lock, usersLock: users) { return true }
            return false
        }
        #expect(refused([flag, "/h"], node: true, lock: "/x/l"))
        #expect(refused([flag, "/h"], lock: nil))
        #expect(refused([flag, "/h"], lock: users))
        // Another spelling of the user's lock, the same file: refused by file (the nit). Red before: compared as text.
        let folder = (users as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: users, contents: Data())
        #expect(refused([flag, "/h"], lock: folder + "/./" + (users as NSString).lastPathComponent))
        // (Only cases refused before the reset: one that passed would reset this test process itself.)
        #expect(refused([flag, "relative"], lock: "/x/l"))
        #expect(refused([flag], lock: "/x/l"))
    }

    /// A token taken before the host's process execs (an in-place switch at the same pid): after the exec Security runs
    /// neither image for it, and the process isn't the token's any more, so `see`'s reads refuse a token read before.
    @Test func aTokenReadBeforeAnExecNamesNoProcessAfterIt() async throws {
        let keeper = MacKeeperHandoverTests()
        let scene = try await keeper.scene { ["--handover-test-keeper", NodePins.hex($0.new)] }
        defer { scene.host.stop() }
        let old = try #require(Platform.CodeIdentity.cdhash(atPath: scene.host.oldBinary))
        let fd = try UnixSocket.connect(path: scene.host.socket)
        defer { Sys.close(fd) }
        let before = try #require(Platform.Sockets.peerToken(fd))
        #expect(Platform.CodeIdentity.runs(before, cdhash: old))
        #expect(Platform.Processes.link(scene.host.pid)?.isProcess(of: before) == true)
        #expect(await keeper.handOver(scene.client, scene.host) == .ok, "\(scene.host.log)")
        #expect(await eventually { scene.host.log.contains("took over 1 sessions") }, "\(scene.host.log)")
        #expect(!Platform.CodeIdentity.runs(before, cdhash: old), "a stale token still runs the old image")
        #expect(!Platform.CodeIdentity.runs(before, cdhash: scene.images.new), "a stale token runs the new image")
        #expect(Platform.Processes.link(scene.host.pid)?.isProcess(of: before) != true, "the exec'd process is still the stale token's")
    }
}
