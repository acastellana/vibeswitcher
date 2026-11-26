import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A handover the running host didn't make: another process of your account writes a state file and descriptors of
/// its own and starts the host's handover intake, as `main.swift` runs it. Scratch seams only: the vault file in a
/// Scratch folder, its key a `SymmetricKey` the test makes (`VaultStorage(file:key:)`); never the Keychain.
struct HandoverProofTests {
    let temp = Scratch()

    @Test func aForgedHandoverIsNotSealed() throws {
        let folder = temp.url("forged-handover")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("lead/vault.sealed")
        let key = SymmetricKey(size: .bits256)
        let storage = VaultStorage(file: file, key: key)
        // Your vault, with the app's key.
        let yours = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        #expect(storage.book().adoptAppKey(yours))
        let kept = try Data(contentsOf: file)

        // Another process's vault, with its own app key, and a state file of its own beside the lock.
        let theirs = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let forged = LeadVault.Book()
        #expect(forged.adoptAppKey(theirs))
        let lockPath = folder.appendingPathComponent("host.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        defer { close(lockFD) }
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listenFD) }
        let secretFD = try HostHandover.SecretChannel.make(forged.serialized)
        let statePath = lockPath + ".handover"
        try HostHandover.write(HostHandover.State(fromBuild: 1, startedAt: Date(), lockFD: lockFD, listenFD: listenFD, secretFD: secretFD,
                                                  sessions: []), to: statePath)

        // What main.swift does with `--handover statePath`: the vault is made only from a handover it took.
        let received = try? HostHandover.receive(from: statePath, lockPath: lockPath, userHost: true, proof: nil, logPath: nil) { key }
        let book = received.map { storage.book(handedOver: $0.secrets) }

        #expect(received == nil, "the handover was taken")
        #expect(try Data(contentsOf: file) == kept, "the vault file was sealed over")
        #expect(storage.book().appKey.map { $0.withUnsafeBytes { Data($0) } } == yours, "the saved vault isn't yours any more")
        #expect(book?.appKey.map { $0.withUnsafeBytes { Data($0) } } != theirs, "the host holds the other process's vault")
    }
}
