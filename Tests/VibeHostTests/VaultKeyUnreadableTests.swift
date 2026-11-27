#if canImport(Darwin)
import CryptoKit
import Foundation
import Security
import Testing
@testable import VibeCore
@testable import VibeHost

/// A vault whose Keychain key can't be read (2026-11-27: after a power cut the host started cold, the Keychain didn't
/// give it the vault's key, and the vault "could not be opened and was started again" though its file was never tried)
/// isn't started over: its sealed file is kept byte for byte, nothing is written or set aside, and the log says which
/// status the Keychain gave. It takes the app's key only once you confirm it (the app's `replaceAppKey`), and then
/// runs in memory only, the file still kept as it was. Scratch seams only: the read's status is given to
/// `VaultStorage` as the Keychain would give it; no Keychain is reached.
extension LeadVaultHostTests {
    /// What the Keychain may answer instead of the vault's key: a read it won't allow without asking (a rebuilt host
    /// the item doesn't trust), a locked keychain, a keychain gone, an item that isn't a key, an add that failed, and
    /// statuses nobody expects.
    static let unreadableStatuses: [OSStatus] = [errSecInteractionNotAllowed, errSecAuthFailed, errSecNoSuchKeychain,
                                                 errSecNotAvailable, errSecUserCanceled, errSecDuplicateItem,
                                                 VaultStorage.notAKey, -1]

    @Test(arguments: unreadableStatuses)
    func aVaultWhoseKeyCantBeReadIsntStartedOver(status: OSStatus) throws {
        let file = folder.appendingPathComponent("lead-\(status)/vault.sealed")
        let before = SymmetricKey(size: .bits256)
        let held = try appKey()
        keptVault(VaultStorage(file: file, key: before), appKey: held)
        let kept = try Data(contentsOf: file)
        let log = folder.appendingPathComponent("host-\(status).log").path

        let storage = VaultStorage(file: file, key: nil, keyIsNew: false, keyUnreadable: status, logPath: log)
        let book = storage.book()
        // Not started over: nothing says what it held is lost, since its file was never tried.
        #expect(book.answer(.startedOver, from: .app) == .startedOver(nil))
        #expect(book.awaitsAppKey)
        #expect(logged(log).contains("Keychain status \(status)"), "\(logged(log))")
        // The key the app passes at the host's start, or enrolls: not taken on its own.
        let key = try appKey()
        #expect(!book.adoptAppKey(key))
        #expect(book.appKey == nil)
        // A change meanwhile writes nothing: the file is kept byte for byte, nothing set aside.
        _ = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app)
        #expect(try Data(contentsOf: file) == kept)
        #expect(asideFiles(file).isEmpty)

        // Your confirmation: the app's key, for a vault in memory only that started over now; the file still as it was.
        #expect(book.adoptAppKey(key, replacing: true))
        #expect(book.appKey?.data == key)
        guard case .startedOver(_?) = book.answer(.startedOver, from: .app) else { Issue.record("not started over once you confirmed"); return }
        _ = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app)
        #expect(try Data(contentsOf: file) == kept)
        #expect(asideFiles(file).isEmpty)
        // The Keychain's key read again: the vault opens as it was sealed.
        #expect(VaultStorage(file: file, key: before).book().appKey?.data == held)
    }

    /// No file either: still not a first start, since a key that can't be read is no key made on this start.
    @Test func aVaultWhoseKeyCantBeReadWithNoFileWaitsForYou() throws {
        let file = folder.appendingPathComponent("gone/vault.sealed")
        let book = VaultStorage(file: file, key: nil, keyIsNew: false, keyUnreadable: errSecInteractionNotAllowed).book()
        #expect(book.awaitsAppKey)
        #expect(!book.adoptAppKey(try appKey()))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// The host's side: the proof is refused in the words of a key that couldn't be read, not of a vault that started
    /// over; the enrolled key isn't taken; your "Teach It This App's Key" puts it in, and the file stays as it was.
    @Test func aHostWhoseVaultKeyCantBeReadSaysSoAndKeepsTheFile() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("host/vault.sealed")
        keptVault(VaultStorage(file: file, key: SymmetricKey(size: .bits256)), appKey: try appKey())
        let kept = try Data(contentsOf: file)
        let book = VaultStorage(file: file, key: nil, keyIsNew: false, keyUnreadable: errSecInteractionNotAllowed,
                                logPath: sessionLog()).book()
        let host = try TestHost(vault: book, appExecutable: "/usr/bin/nc", log: sessionLog(), holdsKey: false)
        let key = SymmetricKey(data: try appKey())
        let message = SteerMessage(text: "x", from: .user, agentPid: 1)

        _ = try await viaNC(host.socket, proof: nil, [.enrollApp(key: key.data), .screen(id: UUID())])
        #expect(book.appKey == nil)
        #expect(!logged(sessionLog()).contains("took the app's first key"))
        let proved = try await viaNC(host.socket, proof: key, [.vault(.seal(message))])
        #expect(proved[0] == .error(AppProof.vaultKeyUnreadable), "\(proved)")
        #expect(refused(proved[2]))

        await #expect(try viaNC(host.socket, proof: nil, [.replaceAppKey(key: key.data)])[2] == .ok)
        await #expect(sealed(try viaNC(host.socket, proof: key, [.vault(.seal(message))])[2]))
        #expect(try Data(contentsOf: file) == kept)
        #expect(asideFiles(file).isEmpty)
        expectNoSecrets(logged(sessionLog()), [key])
    }
}
#endif
