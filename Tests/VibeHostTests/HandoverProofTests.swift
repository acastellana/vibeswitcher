#if canImport(Darwin)
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A handover the running host didn't make: another process of your account writes a state file and descriptors of
/// its own and starts the host's handover intake (`HostHandover.receive`, as `main.swift` runs it), hoping the user's
/// host takes its vault and seals it under the Keychain's key. Scratch seams only: the vault file in a Scratch folder,
/// its key a `SymmetricKey` the test makes (`VaultStorage(file:key:)`); never the Keychain.
struct HandoverProofTests {
    let temp = Scratch()

    /// Your vault, sealed in a scratch folder, and the lock beside it.
    final class Scene {
        let folder: URL
        let file: URL
        let lockPath: String
        let statePath: String
        let logPath: String
        let key = SymmetricKey(size: .bits256)
        let storage: VaultStorage
        let yours = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let theirs = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let kept: Data
        private var descriptors: [Int32] = []

        init(_ temp: Scratch) throws {
            folder = temp.url("handover-proof")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            file = folder.appendingPathComponent("lead/vault.sealed")
            lockPath = folder.appendingPathComponent("host.lock").path
            statePath = lockPath + ".handover"
            logPath = folder.appendingPathComponent("host.log").path
            storage = VaultStorage(file: file, key: key)
            #expect(storage.book().adoptAppKey(yours))
            kept = try Data(contentsOf: file)
        }

        deinit { descriptors.forEach { Darwin.close($0) } }

        /// A descriptor on the lock at `path` (this scene's), held through it when `held`.
        func lock(held: Bool, path: String? = nil) -> Int32 {
            let fd = open(path ?? lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            if held { #expect(flock(fd, LOCK_EX | LOCK_NB) == 0) }
            descriptors.append(fd)
            return fd
        }

        /// The other process's vault, with its own app key.
        var forged: Data {
            let book = LeadVault.Book()
            #expect(book.adoptAppKey(theirs))
            return book.serialized
        }

        /// A state file at the path the host looks for it, naming `lockFD` and a channel holding `secrets`: its bytes,
        /// and the channel's descriptor.
        /// `gone`: the state names a channel that isn't open (-1: never a descriptor, where a closed number could be
        /// another test's by then).
        func state(lockFD: Int32, secrets: Data?, sessions: Int = 0, gone: Bool = false) throws -> (bytes: Data, secretFD: Int32?) {
            let secretFD = gone ? -1 : try secrets.map(HostHandover.SecretChannel.make)
            if let secretFD, secretFD >= 0 { descriptors.append(secretFD) }
            let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
            descriptors.append(listenFD)
            let info = (0..<sessions).map { _ in
                HostHandover.Session(info: HostSession(id: UUID(), tty: "ttys001", childPID: 1, cwd: "/", command: "sh", label: "Shell",
                                                       agent: nil, title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil),
                                     masterFD: nil, output: Data(), pendingInput: Data())
            }
            let bytes = try HostHandover.write(HostHandover.State(fromBuild: 1, startedAt: Date(), lockFD: lockFD, listenFD: listenFD,
                                                                  secretFD: secretFD, sessions: info), to: statePath)
            return (bytes, secretFD)
        }

        /// What the running host's own handover would carry in argv (`HostServer.proofArguments`), under `key`.
        func proof(_ state: Data, secrets: Data?, lockFD: Int32, key: SymmetricKey? = nil, lockPath: String? = nil) throws -> String? {
            let arguments = try HostServer.proofArguments(key: key ?? self.key, state: state, secrets: secrets, lockFD: lockFD,
                                                          lockPath: lockPath ?? self.lockPath)
            #expect(arguments.first == HostHandover.proofFlag && arguments.count == 2)
            return arguments.last
        }

        /// The intake as the user's host runs it, with this scene's key (nil: refused, and why).
        func receive(proof: String?, userHost: Bool = true, key: SymmetricKey?? = nil, lockPath: String? = nil) -> Result<HostHandover.Received, Error> {
            let channel = (try? HostHandover.read(from: statePath))?.secretFD
            let result = Result { try HostHandover.receive(from: statePath, lockPath: lockPath ?? self.lockPath, userHost: userHost, proof: proof,
                                                           logPath: logPath) { key ?? self.key } }
            // A channel the intake took is closed already: not this scene's to close again.
            let taken: Bool
            switch result {
            case .success: taken = true
            case .failure(let error): taken = "\(error)".contains("its secrets aren't the ones its proof names")
            }
            if taken, let channel, let index = descriptors.firstIndex(of: channel) { descriptors.remove(at: index) }
            return result
        }

        /// The intake refused, saying `why` in the log and its error; the vault file as it was, byte for byte, and
        /// still yours; `secretFD`'s channel not read.
        func expectRefused(_ result: Result<HostHandover.Received, Error>, _ why: String, secretFD: Int32?,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
            guard case .failure(let error) = result else {
                Issue.record("the handover was taken", sourceLocation: sourceLocation)
                // What main.swift would do with it next.
                if case .success(let received) = result { _ = storage.book(handedOver: received.secrets) }
                return
            }
            #expect("\(error)".contains(why), "\(error)", sourceLocation: sourceLocation)
            let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            #expect(log.contains("host: handover refused: \(why)"), "\(log)", sourceLocation: sourceLocation)
            #expect(try Data(contentsOf: file) == kept, "the vault file was sealed over", sourceLocation: sourceLocation)
            #expect(storage.book().appKey.map { $0.withUnsafeBytes { Data($0) } } == yours, sourceLocation: sourceLocation)
            if let secretFD {
                var byte: UInt8 = 0
                #expect(HostHandover.isOpen(secretFD) && recv(secretFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 1,
                        "the secrets were read", sourceLocation: sourceLocation)
            }
        }
    }

    /// A state file planted where the host looks for it, its lock a descriptor nobody holds (no host runs).
    @Test func aStatePlantedAtTheHandoverPathIsRefused() throws {
        let scene = try Scene(temp)
        let (_, secretFD) = try scene.state(lockFD: scene.lock(held: false), secrets: scene.forged)
        try scene.expectRefused(scene.receive(proof: nil), "nobody held the lock", secretFD: secretFD)
    }

    /// The real host runs, holding its lock: another process's descriptor on the same lock file isn't the one holding it.
    @Test func aHandoverWhileTheHostRunsIsRefused() throws {
        let scene = try Scene(temp)
        _ = scene.lock(held: true)
        let (_, secretFD) = try scene.state(lockFD: scene.lock(held: false), secrets: scene.forged)
        try scene.expectRefused(scene.receive(proof: nil), "another process holds the lock", secretFD: secretFD)
    }

    /// No host runs, so another process can hold the lock itself and hand it on: without the running host's proof (none,
    /// junk, or one under another key) the user's host takes nothing, and its channel isn't read.
    @Test func aHandoverWhileNoHostRunsIsRefusedWithoutTheProof() throws {
        let scene = try Scene(temp)
        let lockFD = scene.lock(held: true)
        let forged = scene.forged
        let (bytes, secretFD) = try scene.state(lockFD: lockFD, secrets: forged)
        try scene.expectRefused(scene.receive(proof: nil), "it carries no proof", secretFD: secretFD)
        for junk in ["", "00", String(repeating: "0", count: 64) + "." + String(repeating: "0", count: 64), "zz.zz"] {
            try scene.expectRefused(scene.receive(proof: junk), "its proof doesn't hold", secretFD: secretFD)
        }
        let otherKey = try scene.proof(bytes, secrets: forged, lockFD: lockFD, key: SymmetricKey(size: .bits256))
        try scene.expectRefused(scene.receive(proof: otherKey), "its proof doesn't hold", secretFD: secretFD)
    }

    /// The running host's own handover is taken as ever: its secrets, exactly; and the vault they make isn't saved over
    /// the file that opens until it changes.
    @Test func theRunningHostsOwnHandoverIsTaken() throws {
        let scene = try Scene(temp)
        let lockFD = scene.lock(held: true)
        let secrets = scene.storage.book().serialized
        let (bytes, _) = try scene.state(lockFD: lockFD, secrets: secrets, sessions: 2)
        let proof = try scene.proof(bytes, secrets: secrets, lockFD: lockFD)
        let received = try scene.receive(proof: proof).get()
        #expect(received.secrets == secrets)
        #expect(received.state.sessions.count == 2 && received.state.secretFD == nil)
        let book = scene.storage.book(handedOver: received.secrets)
        #expect(book.appKey.map { $0.withUnsafeBytes { Data($0) } } == scene.yours)
        #expect(try Data(contentsOf: scene.file) == scene.kept)
        guard case .grant = book.answer(.issue(role: .lead, root: scene.folder.path, task: nil, auditing: nil), from: .app) else {
            Issue.record("no grant"); return
        }
        #expect(try Data(contentsOf: scene.file) != scene.kept)
        #expect(scene.storage.book().appKey.map { $0.withUnsafeBytes { Data($0) } } == scene.yours)
    }

    /// A build that took the channel and then couldn't restore goes back to the build before, which finds the channel
    /// gone: its proof still holds for the state, and the vault comes from its file.
    @Test func aProvenHandoverWhoseChannelIsGoneIsTakenWithoutSecrets() throws {
        let scene = try Scene(temp)
        let lockFD = scene.lock(held: true)
        let secrets = scene.storage.book().serialized
        let (bytes, _) = try scene.state(lockFD: lockFD, secrets: secrets, gone: true)
        let proof = try scene.proof(bytes, secrets: secrets, lockFD: lockFD)
        let received = try scene.receive(proof: proof).get()
        #expect(received.secrets == nil)
    }

    /// What an earlier real handover left (its state file, its proof from argv) doesn't hold again: not for another
    /// process (a proof binds the pid and start time the kernel reports for the process checking), nor with secrets or
    /// a state of another process's.
    @Test func aReplayedHandoverIsRefused() throws {
        let scene = try Scene(temp)
        let lockFD = scene.lock(held: true)
        let secrets = scene.storage.book().serialized
        var (bytes, secretFD) = try scene.state(lockFD: lockFD, secrets: secrets)
        // Made by another process (an earlier host's, or this one's before a restart): same state, lock and secrets.
        let started = try #require(HostHandover.Proof.startTime(of: getpid()))
        for process in [HostHandover.Proof.Process(pid: getppid(), started: started),
                        HostHandover.Proof.Process(pid: getpid(), started: (started.seconds - 1, started.microseconds))] {
            let earlier = try #require(HostHandover.Proof.make(vaultKey: scene.key, state: bytes, secrets: secrets, lockFD: lockFD,
                                                               lockPath: scene.lockPath, process: process))
            try scene.expectRefused(scene.receive(proof: earlier.description), "its proof doesn't hold", secretFD: secretFD)
        }
        // A real proof, with other secrets in the channel: the state names them and the proof covers its bytes.
        let proof = try #require(try scene.proof(bytes, secrets: secrets, lockFD: lockFD))
        (bytes, secretFD) = try scene.state(lockFD: lockFD, secrets: scene.forged)
        try scene.expectRefused(scene.receive(proof: proof), "its proof doesn't hold", secretFD: secretFD)
        // The proven state's secrets digest, with a channel of other secrets under a state rewritten to its bytes.
        let provenState = try scene.state(lockFD: lockFD, secrets: secrets)
        let proven = try #require(try scene.proof(provenState.bytes, secrets: secrets, lockFD: lockFD))
        // Put in its place at once (dup2 closes the channel there and takes its number, with no moment between).
        let forgedFD = try HostHandover.SecretChannel.make(scene.forged)
        defer { Darwin.close(forgedFD) }
        #expect(dup2(forgedFD, try #require(provenState.secretFD)) >= 0)
        let refused = scene.receive(proof: proven)
        guard case .failure(let error) = refused else { Issue.record("other secrets were taken under a proof"); return }
        #expect("\(error)".contains("its secrets aren't the ones its proof names"))
        #expect(try Data(contentsOf: scene.file) == scene.kept)
    }

    /// VIBESWITCHER_HOME or `--lock` pointed elsewhere: the proof of a host on another lock (a scratch host's) doesn't
    /// hold for the user's lock, even with that lock's descriptor put at the number the state names.
    @Test func aProofForAnotherLockIsRefused() throws {
        let scene = try Scene(temp)
        let elsewhere = scene.folder.appendingPathComponent("elsewhere.lock").path
        let lockFD = scene.lock(held: true, path: elsewhere)
        let secrets = scene.storage.book().serialized
        let (bytes, secretFD) = try scene.state(lockFD: lockFD, secrets: secrets)
        let proof = try scene.proof(bytes, secrets: secrets, lockFD: lockFD, lockPath: elsewhere)
        // On the user's lock path with the other lock's descriptor: not the lock file.
        try scene.expectRefused(scene.receive(proof: proof), "its lock descriptor isn't the lock file", secretFD: secretFD)
        // The user's lock, held, put at that number: the proof named the other.
        let users = scene.lock(held: true)
        #expect(dup2(users, lockFD) == lockFD)
        try scene.expectRefused(scene.receive(proof: proof), "its proof doesn't hold", secretFD: secretFD)
        // And the user's lock path given as the other's: still that lock's file, not this one.
        let other = try scene.proof(bytes, secrets: secrets, lockFD: lockFD, lockPath: elsewhere)
        try scene.expectRefused(scene.receive(proof: other), "its proof doesn't hold", secretFD: secretFD)
    }

    /// A scratch host (on its own lock: its vault in memory only, never the user's) takes a handover once its lock
    /// holds, and still refuses one whose lock doesn't. The user's host without its key (a locked keychain, a build
    /// without the stable signing identity) can't check a proof: it takes none, proven or not.
    @Test func aKeylessHostTakesAHandoverOnlyWhenTheLockHolds() throws {
        let scene = try Scene(temp)
        let forged = scene.forged
        let (_, secretFD) = try scene.state(lockFD: scene.lock(held: false), secrets: forged)
        try scene.expectRefused(scene.receive(proof: nil, userHost: false), "nobody held the lock", secretFD: secretFD)
        try scene.expectRefused(scene.receive(proof: nil, key: .some(nil)), "nobody held the lock", secretFD: secretFD)
        let lockFD = scene.lock(held: true)
        let (bytes, heldFD) = try scene.state(lockFD: lockFD, secrets: forged)
        try scene.expectRefused(scene.receive(proof: nil, key: .some(nil)), "this host has no vault key", secretFD: heldFD)
        let proof = try scene.proof(bytes, secrets: forged, lockFD: lockFD)
        try scene.expectRefused(scene.receive(proof: proof, key: .some(nil)), "this host has no vault key", secretFD: heldFD)
        #expect(try scene.receive(proof: nil, userHost: false).get().secrets == forged)
    }

    /// A proof binds the process's start time as the kernel reports it, which a handover's exec in place must keep: a
    /// real exec of another program in the same process, its start time before and after.
    @Test func aProcessKeepsItsStartTimeThroughAnExec() async throws {
        let folder = temp.url("exec-start")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let go = folder.appendingPathComponent("go").path
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while [ ! -f '\(go)' ]; do sleep 0.05; done; exec /bin/sleep 600"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let pid = process.processIdentifier
        let before = try #require(HostHandover.Proof.startTime(of: pid))
        FileManager.default.createFile(atPath: go, contents: nil)
        #expect(await eventually { HostServer.executable(of: pid) == "/bin/sleep" })
        let after = try #require(HostHandover.Proof.startTime(of: pid))
        #expect(before.seconds == after.seconds && before.microseconds == after.microseconds)
    }

    /// The handover's own write: a handed-over vault is saved at once where no vault file opens, and never over one
    /// that does (a change it makes later saves it).
    @Test func aHandedOverVaultIsNotSavedOverAVaultThatOpens() throws {
        let scene = try Scene(temp)
        _ = scene.storage.book(handedOver: scene.forged)
        #expect(try Data(contentsOf: scene.file) == scene.kept)
        let fresh = VaultStorage(file: scene.folder.appendingPathComponent("fresh/vault.sealed"), key: scene.key)
        _ = fresh.book(handedOver: scene.forged)
        #expect(fresh.book().appKey.map { $0.withUnsafeBytes { Data($0) } } == scene.theirs)
    }
}

/// The genuine host binary started with `--handover` by another process (this test, an unrelated parent), with a state
/// file planted where the running host's would be and descriptors of its own: refused before it reads the secrets,
/// and the running host carries on. A scratch host on its own lock (no Keychain); the user's host's proof is
/// `HandoverProofTests`'.
@Suite(.serialized, hostTestLimit) struct ForeignHandoverProcessTests {
    @Test func theHostBinaryRefusesAHandoverFromAnotherProcess() async throws {
        let host = try await ScratchHostProcess()
        defer { host.stop() }
        let (client, _, _, _, _, pid, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("sleep 600")
        defer { kill(-session.childPID, SIGKILL) }

        // Its own descriptors: the lock file (which the running host holds through its own), a socket, a channel.
        let lockFD = open(host.lock, O_RDWR | O_CLOEXEC)
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        let secret = "forged-\(UUID().uuidString)"
        let secretFD = try HostHandover.SecretChannel.make(Data(secret.utf8))
        defer { [lockFD, listenFD, secretFD].forEach { close($0) } }
        let statePath = host.lock + ".handover"
        try HostHandover.write(HostHandover.State(fromBuild: 1, startedAt: Date(), lockFD: lockFD, listenFD: listenFD, secretFD: secretFD,
                                                  sessions: []), to: statePath)
        let output = host.dir + "/foreign.log"
        let started = try spawn(hostLauncher, ["--socket", host.socket, "--lock", host.lock, "--idle-exit", "600", "--log", output,
                                               "--exit-with", String(getpid()), "--handover", statePath],
                                environment: ["HOME=\(host.home)", "CFFIXED_USER_HOME=\(host.home)", "PATH=/usr/bin:/bin", "TMPDIR=\(host.dir)/"],
                                inherit: [lockFD, listenFD, secretFD], output: output)
        var status: Int32 = 0
        var reaped = false
        defer { if !reaped { kill(started, SIGKILL); waitpid(started, &status, 0) } }
        let said = { (try? String(contentsOfFile: output, encoding: .utf8)) ?? "" }
        #expect(await eventually {
            if !reaped, waitpid(started, &status, WNOHANG) == started { reaped = true }
            return reaped || said().contains("took over")
        })
        #expect(reaped, "it took over: \(said())")
        #expect(reaped && (status >> 8) & 0xff == 1, "status \(status)")
        #expect(said().contains("handover refused: another process holds the lock"), "\(said())")
        #expect(!said().contains("bytes of secrets"))
        // The secrets weren't read, and the running host is as it was, its session with it.
        var byte: UInt8 = 0
        #expect(recv(secretFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 1)
        let (_, _, _, sessions, _, after, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(after == pid && sessions.map(\.id) == [session.id])
    }

    /// Starts `path` with `arguments`, inheriting only `inherit` (and stdin from /dev/null, stdout and stderr to
    /// `output`): what a process of your account can do. Its pid.
    func spawn(_ path: String, _ arguments: [String], environment: [String], inherit: [Int32], output: String) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        // Inherited as they are: an exec refuses one marked close-on-exec, so unmark them for the spawn.
        for fd in inherit {
            _ = fcntl(fd, F_SETFD, 0)
            posix_spawn_file_actions_addinherit_np(&actions, fd)
        }
        defer { inherit.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) } }
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw HostHandover.Failure.exec(result) }
        return pid
    }
}

/// The sending side: what the user's host does before it hands over, so a build that would refuse is never executed in
/// its place (refused there, it would go back to this build's copy, which would refuse too and quit, sessions and all).
struct HandoverSenderTests {
    let temp = Scratch()

    /// The user's host without its vault key hands over to no build: it says why and carries on. The build is never
    /// probed nor run.
    @Test func theUsersHostWithoutItsKeyDoesntHandOver() async throws {
        let host = try TestHost()
        host.server.queue.sync { host.server.handoverNeedsKey = true }
        let folder = temp.url("keyless-sender")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ran = folder.appendingPathComponent("ran").path
        let build = folder.appendingPathComponent("build").path
        FileManager.default.createFile(atPath: build, contents: Data("#!/bin/sh\ntouch '\(ran)'\nexit 1\n".utf8), attributes: [.posixPermissions: 0o755])
        let client = try TestClient(host)
        let seq = client.send(.handover(executable: build))
        #expect(await eventually { client.reply(to: seq) != nil })
        guard case .error(let message)? = client.reply(to: seq) else { Issue.record("\(String(describing: client.reply(to: seq)))"); return }
        #expect(message.contains("no vault key"), "\(message)")
        #expect(!FileManager.default.fileExists(atPath: ran))
        let again = client.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(await eventually { client.reply(to: again) != nil })
    }

    /// The probe asked by the user's host checks the new build gets the same vault key (by its id, never the key), and
    /// reads the Keychain only when asked.
    @Test func theProbeChecksTheNewBuildGetsTheSameKey() throws {
        let folder = temp.url("probe-key")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("state").path
        try HostHandover.write(HostHandover.State(fromBuild: 1, startedAt: Date(), lockFD: 3, listenFD: 4, secretFD: nil, sessions: []), to: path)
        let key = SymmetricKey(size: .bits256)
        let asked = ["--handover-probe", path, HostHandover.probeKeyFlag, HostHandover.Proof.keyID(key)]
        var read = false
        try HostHandover.probeCheck(["--handover-probe", path], statePath: path) { read = true; return nil }
        #expect(!read)
        try HostHandover.probeCheck(asked, statePath: path) { key }
        #expect(throws: HostHandover.Failure.self) { try HostHandover.probeCheck(asked, statePath: path) { SymmetricKey(size: .bits256) } }
        #expect(throws: HostHandover.Failure.self) { try HostHandover.probeCheck(asked, statePath: path) { nil } }
        #expect(throws: HostHandover.Failure.self) { try HostHandover.probeCheck(Array(asked.dropLast()), statePath: path) { key } }
        #expect(HostHandover.Proof.keyID(key) != HostHandover.Proof.hex(key.withUnsafeBytes { Data($0) }))
    }
}
#endif
