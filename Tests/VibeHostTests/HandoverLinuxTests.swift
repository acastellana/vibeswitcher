import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// What the host executes on Linux, checked against its build's record (the stage 2 plan's Tasks 9b to 9d, S2-D7,
/// S2-D8; the security architecture document's S8 and S9). Task 9b: a host started with `--node-root` runs only when
/// its own sealed copy, and its `--server`'s, are what that build folder's `build-info` records; a record of a newer
/// format is refused. Task 9c (below): the handover through sealed memory, writing no file, and its fallback through
/// the old image's sealed copy.
///
/// Serialized: a host here holds a sealed copy of this binary (some hundreds of megabytes) as its server.
@Suite(hostTestLimit, .serialized) struct HandoverLinuxTests {
    /// A build folder in `dir` (`<dir>/<name>`, with a `bin/`) whose `build-info` records `binaries` (name to
    /// SHA-256), in `format`.
    static func buildFolder(in dir: String, _ name: String = "build", binaries: [String: String], format: Int = BuildInfo.format) throws -> String {
        let folder = dir + "/" + name
        try FileManager.default.createDirectory(atPath: folder + "/bin", withIntermediateDirectories: true)
        var info = BuildInfo(commit: String(repeating: "c", count: 40), binaries: binaries, swift: "Swift version 6.4.2",
                             resolved: String(repeating: "e", count: 64))
        info.format = format
        try info.encoded.write(to: URL(fileURLWithPath: folder + "/" + BuildInfo.fileName))
        return folder
    }

    /// The SHA-256 of the file at `path`, taken as the host takes it: of a sealed copy's bytes.
    static func sha256(of path: String) throws -> String {
        let copy = try Platform.ProcessSelf.sealedCopy(of: path, name: "hash").get()
        defer { Sys.close(copy.fd) }
        return BuildInfo.sha256(of: copy)
    }

    /// A scratch host started on its own home, socket and lock with `extra` after them, which isn't expected to start:
    /// once it has ended, its exit status and what it said.
    static func refusedHost(in dir: String, _ extra: [String]) async throws -> (status: Int32, said: String) {
        let home = dir + "/home-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let output = home + "/out"
        FileManager.default.createFile(atPath: output, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hostLauncher)
        process.arguments = ["--socket", home + "/h.sock", "--lock", home + "/h.lock", "--idle-exit", "600", "--log", home + "/session.log"] + extra
        process.environment = ["HOME": home, "CFFIXED_USER_HOME": home, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "TMPDIR": dir + "/"]
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try TestHosts.run(process)
        defer { TestHosts.end(process) }
        #expect(await eventually { !process.isRunning })
        let said = (try? String(contentsOfFile: output, encoding: .utf8)) ?? ""
        return (process.isRunning ? -1 : process.terminationStatus, said)
    }

    /// A scratch `--node-root` whose `build-info` records another hash for the host's own image, or for its server, or
    /// none for either: the host exits non-zero, saying which binary, and binds no socket.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's sealed copies and build-info; the Mac has neither"))
    func aHostWhoseImageDiffersFromItsBuildInfoDoesNotStart() async throws {
        let dir = "\(shortScratchRoot)/vshl-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let host = try Self.sha256(of: hostLauncher)
        let other = BuildInfo.sha256(of: Data("another build".utf8))
        let server = "/bin/true"
        let serverHash = try Self.sha256(of: server)

        let wrongHost = try Self.buildFolder(in: dir, "wrong-host", binaries: [BuildInfo.host: other, BuildInfo.server: serverHash])
        var (status, said) = try await Self.refusedHost(in: dir, ["--node-root", wrongHost, "--server", server])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: vibeswitcher-host: its sha256 \(host) isn't the one build-info records (\(other))"), "\(said)")
        #expect(!said.contains("vibeswitcher-host: started"), "\(said)")

        let wrongServer = try Self.buildFolder(in: dir, "wrong-server", binaries: [BuildInfo.host: host, BuildInfo.server: other])
        (status, said) = try await Self.refusedHost(in: dir, ["--node-root", wrongServer, "--server", server])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: vibeswitcher-server: its sha256 \(serverHash) isn't the one build-info records (\(other))"), "\(said)")

        let noServer = try Self.buildFolder(in: dir, "no-server", binaries: [BuildInfo.host: host])
        (status, said) = try await Self.refusedHost(in: dir, ["--node-root", noServer, "--server", server])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: vibeswitcher-server: build-info holds no record for it"), "\(said)")

        let noHost = try Self.buildFolder(in: dir, "no-host", binaries: [:])
        (status, said) = try await Self.refusedHost(in: dir, ["--node-root", noHost])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: vibeswitcher-host: build-info holds no record for it"), "\(said)")

        (status, said) = try await Self.refusedHost(in: dir, ["--node-root", dir + "/no-such-build"])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: its build-info: \(dir)/no-such-build/build-info can't be read"), "\(said)")
    }

    /// A record of a newer format is refused (rule 11), as is one whose commit or hashes aren't of the format's shape;
    /// format 1 is read. A host whose `--node-root` holds a newer record doesn't start.
    @Test func aNewerBuildInfoFormatIsRefused() async throws {
        let hash = String(repeating: "a", count: 64)
        let valid = BuildInfo(commit: String(repeating: "0", count: 40), binaries: [BuildInfo.host: hash], swift: "Swift 6.4.2", resolved: hash)
        #expect(try BuildInfo.parse(valid.encoded).get() == valid)
        var newer = valid
        newer.format = 2
        #expect(BuildInfo.parse(newer.encoded) == .failure(.init("its format 2 is newer than this build's (1)")))
        // A newer format is refused by its number alone, whatever else it holds.
        #expect(BuildInfo.parse(Data(#"{"format":3,"layout":"another"}"#.utf8)) == .failure(.init("its format 3 is newer than this build's (1)")))
        #expect(BuildInfo.parse(Data("not json".utf8)) == .failure(.init("not a build record (no format)")))
        var shortCommit = valid
        shortCommit.commit = "abc"
        #expect(BuildInfo.parse(shortCommit.encoded) == .failure(.init("its commit isn't 40 hex digits")))
        var upperHash = valid
        upperHash.binaries[BuildInfo.host] = hash.uppercased()
        #expect(BuildInfo.parse(upperHash.encoded) == .failure(.init("its hash for vibeswitcher-host isn't 64 hex digits")))

        guard !Platform.CodeIdentity.isAvailable else { return }
        let dir = "\(shortScratchRoot)/vshl-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let folder = try Self.buildFolder(in: dir, binaries: [BuildInfo.host: try Self.sha256(of: hostLauncher)], format: 2)
        let (status, said) = try await Self.refusedHost(in: dir, ["--node-root", folder])
        #expect(status == 1, "\(said)")
        #expect(said.contains("not started: its build-info: \(folder)/build-info: its format 2 is newer than this build's (1)"), "\(said)")
    }

    /// A scratch host whose `--node-root` records its own image's hash and its server's starts, and its server child is
    /// told that folder as its `--node-root` (S2-D1), not the host's executable's.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's sealed copies and build-info; the Mac has neither"))
    func aHostWhoseImagesMatchItsBuildInfoStartsAndTellsItsServerTheFolder() async throws {
        let dir = "\(shortScratchRoot)/vshl-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let binary = try #require(Bundle.main.executablePath)
        let folder = try Self.buildFolder(in: dir, binaries: [BuildInfo.host: try Self.sha256(of: hostLauncher),
                                                              BuildInfo.server: try Self.sha256(of: binary)])
        let host = try await ServerChildHost(actions: ["sleep"], extra: ["--node-root", folder])
        defer { host.stop() }
        #expect(await host.firstHelper() != nil, "\(host.said)")
        let line = try #require(host.started.first?.line)
        #expect(line.contains(" node-root=\(folder) "), "\(line)")
        #expect(line.contains(" root=\(host.home)/.vibeswitcher "), "\(line)")
    }
}

// MARK: Task 9c: the handover through sealed memory

/// A new build that can't take over (it passes the probe, then is told it couldn't read its state), and one that takes
/// itself for traced; `hold`: before it runs, it says so (`<hold>.waiting`) and waits for `<hold>.go`.
extension ScratchHostProcess {
    func failingBuild(_ flag: String = "--handover-fail-restore", hold: String? = nil) -> String {
        let wait = hold.map { "touch '\($0).waiting'; while [ ! -e '\($0).go' ]; do sleep 0.05; done" } ?? ":"
        return script("failing-\(UUID().uuidString.prefix(6))", """
            case " $* " in *" --handover-probe "*) exec '\(newBinary)' "$@";; esac
            \(wait)
            exec '\(newBinary)' "$@" \(flag)
            """)
    }

    /// Hands over to `executable` through `client` and waits for the answer: ok, or what it was.
    func handOver(to executable: String, through client: TestClient) async -> HostEvent? {
        let seq = client.send(.handover(executable: executable))
        _ = await eventually { client.reply(to: seq) != nil }
        return client.reply(to: seq)
    }

    /// The lines of its log after `prefix`, each with the prefix taken off.
    func lines(after prefix: String) -> [String] {
        log.components(separatedBy: "\n").compactMap { line in line.range(of: prefix).map { String(line[$0.upperBound...]) } }
    }
}

/// The app's lead grant, bound to a session it started: what a vault handed over must still hold.
struct BoundGrant {
    static let root = "/scratch/handover-vault-repo"
    let grant: String
    let session: HostSession

    init(_ app: TestClient) async throws {
        session = try await app.spawn("exec sleep 600")
        guard case .grant(let grant)? = app.vault(.issue(role: .lead, root: Self.root, task: nil, auditing: nil)) else {
            throw TestClient.NoWelcome(description: "the app got no lead grant")
        }
        self.grant = grant
        #expect(app.vault(.bind(grant: grant, root: Self.root, session: session.id.uuidString)) == .ok)
    }

    /// Whether the vault `client` reaches still binds the grant to its session.
    func isBound(in client: TestClient) -> Bool {
        guard case .member(let member?)? = client.vault(.current(role: .lead, root: Self.root, task: nil)) else { return false }
        return member.id == grant && member.session == session.id.uuidString
    }
}

extension HandoverLinuxTests {
    /// A handover writes no file: a watch on the lock's folder (where the state file was written, and its `.partial`)
    /// sees no entry made or removed from the handover's ask until the new image serves, and none is left.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux hands over through sealed memory; the Mac writes its state file"))
    func aHandoverWritesNoFile() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("printf 'up\\n'; exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        #expect(await eventually { client.screen(session.id)?.contains("up") == true })
        let before = try FileManager.default.contentsOfDirectory(atPath: host.dir).sorted()

        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var changes = 0
        }
        let seen = Seen()
        let watch = try #require(Platform.FolderWatch(path: host.dir))
        defer { watch.stop() }
        watch.deliver(on: DispatchQueue(label: "handover-folder-watch")) { change in
            if change.contains(.entries) { seen.lock.withLock { seen.changes += 1 } }
        }
        #expect(await host.handOver(to: host.newBinary, through: client) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("took over 1 sessions") }, "\(host.log)")
        _ = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        // A change of the test's own, after the handover: once the watch has told it, it has told everything before.
        FileManager.default.createFile(atPath: host.dir + "/marker", contents: nil)
        #expect(await eventually { seen.lock.withLock { seen.changes } >= 1 })
        #expect(seen.lock.withLock { seen.changes } == 1, "the lock's folder changed during the handover")
        let after = try FileManager.default.contentsOfDirectory(atPath: host.dir).filter { $0 != "marker" }.sorted()
        #expect(after == before)
        #expect(!after.contains { $0.contains(".handover") }, "\(after)")
    }

    /// The state and the secrets reach the new image in sealed memory: the old image says what it wrote (each
    /// descriptor's seals, size and SHA-256, a scratch host's report), and the new image, which read them, finds the
    /// same descriptors sealed, holding the same bytes.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux hands over through sealed memory; the Mac writes its state file"))
    func theStateAndSecretsAreSealed() async throws {
        let secret = "secret-\(UUID().uuidString)"
        let host = try await ScratchHostProcess(arguments: ["--handover-test-secret", secret])
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("printf 'up\\n'; exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        #expect(await host.handOver(to: host.newBinary, through: client) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("handover memory kept") }, "\(host.log)")
        let written = try #require(host.lines(after: "handover memory written: ").first, "\(host.log)")
        let taken = try #require(host.lines(after: "handover memory taken: ").first, "\(host.log)")
        #expect(written == taken)
        let parts = written.components(separatedBy: "; ")
        #expect(parts.count == 2, "\(written)")
        #expect(parts.first?.hasPrefix("state fd ") == true && parts.last?.hasPrefix("secrets fd ") == true, "\(written)")
        for part in parts { #expect(part.contains(" sealed, ") && part.contains(" bytes, sha256 "), "\(part)") }
        #expect(parts.last?.contains(" \(secret.utf8.count) bytes, sha256 \(BuildInfo.sha256(of: Data(secret.utf8)))") == true, "\(written)")
    }

    /// The new build passes the probe, then can't restore: the old build, back through its sealed copy, serves on with
    /// the vault it held (a lead grant issued before is still bound to its session).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux hands over through sealed memory; the Mac through its channel"))
    func aFallbackAfterAFailedRestoreKeepsTheVault() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (app, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let bound = try await BoundGrant(app)
        defer { kill(bound.session.childPID, SIGKILL) }
        #expect(bound.isBound(in: app))
        #expect(await host.handOver(to: host.failingBuild(), through: app) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("took over 1 sessions") }, "\(host.log)")
        #expect(host.log.contains("couldn't take over") && host.log.contains("going back to /proc/self/fd/"), "\(host.log)")
        #expect(host.log.contains("bytes of secrets"), "\(host.log)")
        let (again, _, build, _, _, pid, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(build == host.oldBuild && pid == host.pid)
        #expect(bound.isBound(in: again), "\(host.log)")
    }

    /// The same, with every session the old build held: each listed with its id and terminal, the counter unbroken, each
    /// still writable, a job's own status at its end.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's fallback through the old image's sealed copy"))
    func aFallbackAfterAFailedRestoreKeepsEverySession() async throws {
        let tests = HostHandoverTests()
        let scene = try await tests.scene()
        defer { tests.end(scene) }
        let screens = Dictionary(uniqueKeysWithValues: [scene.shell, scene.job, scene.painted, scene.done].map { ($0.id, scene.client.screen($0.id) ?? "") })
        await scene.client.attach(scene.counter.id)
        let counterBefore = counted(scene.client.text(scene.counter.id)).last ?? 0
        #expect(await scene.host.handOver(to: scene.host.failingBuild(), through: scene.client) == .ok, "\(scene.host.log)")
        #expect(await eventually { scene.client.closed })
        try await tests.expectCarriedOn(scene, build: scene.host.oldBuild, screens: screens, counterBefore: counterBefore)
        #expect(scene.host.log.contains("going back to /proc/self/fd/"), "\(scene.host.log)")
        #expect(scene.host.runningExecutable == URL(fileURLWithPath: scene.host.oldBinary).resolvingSymlinksInPath().path)
    }

    /// A megabyte of secrets (no argument can hold it: one is at most 128 KiB here) is handed over whole.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's sealed memory and its test flag"))
    func aMegabyteOfSecretsIsHandedOver() async throws {
        let file = "\(shortScratchRoot)/vshm-\(UUID().uuidString.prefix(8))"
        defer { unlink(file) }
        let secret = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        try secret.write(to: URL(fileURLWithPath: file))
        let host = try await ScratchHostProcess(arguments: ["--handover-test-secret-file", file])
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(await host.handOver(to: host.newBinary, through: client) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("took over") }, "\(host.log)")
        #expect(host.log.contains("and \(1 << 20) bytes of secrets"), "\(host.log)")
        #expect(host.lines(after: "handover memory taken: ").first?.contains("sha256 \(BuildInfo.sha256(of: secret))") == true, "\(host.log)")
    }

    /// A state of a newer format than this build's is refused, by its read and by the probe (rule 11): the probe's
    /// refusal ends the handover before the exec, and the new image's goes back, as any failed read does
    /// (`aFallbackAfterAFailedRestoreKeepsTheVault`). Linux reads it from sealed memory, the Mac from its file.
    @Test func aDowngradeIsRefused() throws {
        var state = HostHandover.State(fromBuild: 7, startedAt: Date(), lockFD: 3, listenFD: 4, secretFD: nil, sessions: [])
        state.format = HostHandover.format + 1
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(state)
        let path: String
        var memory: Int32?
        if Platform.CodeIdentity.isAvailable {
            path = "\(shortScratchRoot)/vsho-newer-\(UUID().uuidString.prefix(8))"
            try bytes.write(to: URL(fileURLWithPath: path))
        } else {
            let fd = try HandoverMemory.seal(bytes, name: "newer-state")
            memory = fd
            path = HandoverMemory.path(of: fd)
        }
        defer { if let memory { Sys.close(memory) } else { unlink(path) } }
        #expect(throws: HostHandover.Failure.wrongFormat(HostHandover.format + 1)) { try HostHandover.read(from: path) }

        // The probe of this build refuses it too.
        var target = hostLauncher
        var copy: Platform.ProcessSelf.SealedCopy?
        if !Platform.CodeIdentity.isAvailable {
            copy = try Platform.ProcessSelf.sealedCopy(of: hostLauncher, name: "probe").get()
            target = copy!.path
        }
        defer { if let copy { Sys.close(copy.fd) } }
        #expect(throws: HostHandover.Failure.self) { try HostHandover.probe(target, statePath: path, timeout: hangGuard) }
    }

    /// A fresh host that holds the lock removes a state file and its `.partial` left beside the lock (the Mac's format,
    /// or a scratch host's from before), and says so.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux writes no state file; the Mac's own handover reads and removes it"))
    func aFreshHostRemovesAStaleStateFile() async throws {
        let host = try await ScratchHostProcess { dir in
            for stale in ["/h.lock.handover", "/h.lock.handover.partial"] {
                FileManager.default.createFile(atPath: dir + stale, contents: Data("stale".utf8))
            }
        }
        defer { host.stop() }
        #expect(await eventually { host.log.contains("vibeswitcher-host: started") })
        for stale in [host.lock + ".handover", host.lock + ".handover.partial"] {
            #expect(!FileManager.default.fileExists(atPath: stale), "\(stale)")
            #expect(host.log.contains("removed a stale handover state file: \(stale)"), "\(host.log)")
        }
    }

    /// Every descriptor the new image kept (the sessions' terminals, the state, the image copies, the connectors) is
    /// closed or close-on-exec once it has restored (its report), and a session it starts after the handover holds
    /// none of them: only its terminal.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's sealed memory, images and connectors"))
    func everyDescriptorTheNewImageKeepsIsCloseOnExec() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let before = try await client.spawn("printf 'up\\n'; exec sleep 600")
        defer { kill(before.childPID, SIGKILL) }
        #expect(await eventually { client.screen(before.id)?.contains("up") == true })
        #expect(await host.handOver(to: host.newBinary, through: client) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("handover memory kept: ") }, "\(host.log)")
        let kept = try #require(host.lines(after: "handover memory kept: ").first).components(separatedBy: ", ")
        #expect(kept.count >= 6, "\(kept)")
        for entry in kept { #expect(entry.hasSuffix(" close-on-exec") || entry.hasSuffix(" closed"), "\(kept)") }

        let (again, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let after = try await again.spawn("printf 'fds:'; for f in /proc/$$/fd/*; do printf ' %s' \"$(readlink $f)\"; done; printf ' end\\n'; exec sleep 600")
        defer { kill(after.childPID, SIGKILL) }
        await again.attach(after.id)
        #expect(await eventually { again.text(after.id).contains(" end") }, "\(again.text(after.id))")
        let listed = again.text(after.id)
        for held in ["memfd:", "socket:", "ptmx", "h.lock"] { #expect(!listed.contains(held), "\(listed)") }
        #expect(listed.contains("/dev/pts/"), "\(listed)")
    }

    /// The probe and the new image run from the target's sealed copy, so neither is reachable from its exec: every
    /// open of the probe's memory, and of the host's across the exec, is refused (`pidfd_getfd` is refused alike: both
    /// ask that the process be dumpable).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's sealed copies; the Mac has none"))
    func aHandoverImageIsNotDumpableFromItsExec() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)

        final class Polls: @unchecked Sendable {
            let lock = NSLock()
            var stop = false
            var host: [Int32] = []
            var probe: [Int32] = []
        }
        let polls = Polls()
        let pid = host.pid
        let poller = Thread {
            while !polls.lock.withLock({ polls.stop }) {
                let hostOpen = HostHardeningTests.openMemory(of: pid)
                let probes = HostProcesses.children(of: pid).filter { Platform.Processes.arguments($0).contains("--handover-probe") }
                let probeOpens = probes.map(HostHardeningTests.openMemory(of:)).filter { $0 != ENOENT && $0 != ESRCH }
                polls.lock.withLock {
                    polls.host.append(hostOpen)
                    polls.probe += probeOpens
                }
                usleep(500)
            }
        }
        poller.start()
        #expect(await host.handOver(to: host.newBinary, through: client) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("took over") }, "\(host.log)")
        polls.lock.withLock { polls.stop = true }
        let (onHost, onProbe) = polls.lock.withLock { (polls.host, polls.probe) }
        #expect(onHost.count > 10 && Set(onHost) == [EACCES], "\(Set(onHost)) over \(onHost.count) polls")
        #expect(Set(onProbe).isSubset(of: [EACCES]), "\(Set(onProbe)) over \(onProbe.count) polls of the probe")
        print("aHandoverImageIsNotDumpableFromItsExec: \(onHost.count) polls of the host, \(onProbe.count) of the probe, all refused")
    }

    /// The new build can't restore and the old build's file is gone: the old build serves again, from the sealed copy
    /// carried across the exec.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's fallback through the old image's sealed copy"))
    func aFailedTakeOverGoesBackThroughTheSealedCopy() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("printf 'up\\n'; exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        try FileManager.default.removeItem(atPath: host.oldBinary)
        #expect(await host.handOver(to: host.failingBuild(), through: client) == .ok, "\(host.log)")
        #expect(await eventually { host.log.contains("took over 1 sessions") }, "\(host.log)")
        #expect(host.log.contains("couldn't take over"), "\(host.log)")
        let (again, _, _, sessions, _, pid, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(pid == host.pid && sessions.map(\.id) == [session.id])
        await again.attach(session.id)
        again.send(.input(id: session.id, bytes: Data("x".utf8), reply: false))
        #expect(host.process.isRunning)
    }

    /// The old build's file rewritten in place after the exec (it runs no longer, so no `ETXTBSY`) and before the new
    /// build's failed restore (its modification time put back, so its build id is the same): what serves again is the
    /// old build, from its sealed copy, not what the file now holds.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's fallback through the old image's sealed copy"))
    func aFallbackImageRewrittenInPlaceIsNotWhatRuns() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("printf 'up\\n'; exec sleep 600")
        defer { kill(session.childPID, SIGKILL) }
        let hold = host.dir + "/hold"
        let modified = try FileManager.default.attributesOfItem(atPath: host.oldBinary)[.modificationDate] as? Date
        #expect(await host.handOver(to: host.failingBuild(hold: hold), through: client) == .ok, "\(host.log)")
        #expect(await eventually { FileManager.default.fileExists(atPath: hold + ".waiting") }, "\(host.log)")
        let file = open(host.oldBinary, O_WRONLY | O_TRUNC | O_CLOEXEC)
        try #require(file >= 0, "errno \(errno)")
        let other = Array("#!/bin/sh\necho replaced-build >&2\nexit 9\n".utf8)
        #expect(write(file, other, other.count) == other.count)
        Sys.close(file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: host.oldBinary) }
        FileManager.default.createFile(atPath: hold + ".go", contents: nil)

        #expect(await eventually { host.log.contains("took over 1 sessions") }, "\(host.log)")
        let (_, _, build, sessions, _, pid, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(build == host.oldBuild && pid == host.pid && sessions.map(\.id) == [session.id])
        #expect(!host.log.contains("replaced-build"), "\(host.log)")
    }
}
