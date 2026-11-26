import CryptoKit
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A vault that had to start over (its sealed file no longer opens under the Keychain key: a Keychain reset, or another
/// program of your account that replaced the key, 2026-11-26) takes no app key on its own: not the one the app hands
/// the host on stdin at its start, nor the one the app's connection enrolls. You're told, and the key goes in only
/// through the app's own "Teach It This App's Key" (`replaceAppKey`). A first start (no vault file yet) takes the app's
/// key as before, and a vault that opens is as it was. Scratch seams only: `VaultStorage(file:key:)` on a scratch
/// file, the app's key from `AppProof.MemoryStore`; no Keychain.
extension LeadVaultHostTests {
    /// The vault file `storage` keeps, holding `appKey`, sealed under `storage`'s key.
    func keptVault(_ storage: VaultStorage, appKey: Data) {
        #expect(storage.book().adoptAppKey(appKey))
        #expect(storage.load() != nil)
    }

    func appKey() throws -> Data { try #require(AppProof.MemoryStore().key()).data }

    @Test func aStartedOverVaultTakesNoAppKeyUntilYouConfirm() throws {
        let file = folder.appendingPathComponent("lead/vault.sealed")
        let before = SymmetricKey(size: .bits256)
        keptVault(VaultStorage(file: file, key: before), appKey: try appKey())

        // Another key in the Keychain now: the file doesn't open, and the vault starts over.
        let planted = SymmetricKey(size: .bits256)
        let storage = VaultStorage(file: file, key: planted)
        let book = storage.book()
        guard case .startedOver(let since?) = book.answer(.startedOver, from: .app) else { Issue.record("not started over"); return }
        #expect(since > 0)
        // The key the app passes at the host's start, and the one its connection enrolls: neither is taken.
        let key = try appKey()
        #expect(!book.adoptAppKey(key))
        #expect(book.appKey == nil)
        #expect(!book.adoptAppKey(key))
        // Nothing was sealed under the new key for it: the file is the one from before.
        #expect(VaultStorage(file: file, key: before).load() != nil)
        #expect(storage.load() == nil)

        // A change meanwhile seals the vault under the new key: opened later, it still started over and holds no
        // key, and still takes none on its own (fail closed: the next start isn't a first one).
        _ = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app)
        #expect(storage.load() != nil)
        let reopened = storage.book()
        guard case .startedOver(_?) = reopened.answer(.startedOver, from: .app) else { Issue.record("its start over forgotten"); return }
        #expect(!reopened.adoptAppKey(key))
        #expect(reopened.appKey == nil)

        // Your confirmation (the app's replaceAppKey): taken, kept, and from then on the vault is as any other.
        #expect(reopened.adoptAppKey(key, replacing: true))
        let confirmed = storage.book()
        #expect(confirmed.appKey?.data == key)
        #expect(confirmed.adoptAppKey(key))
        #expect(!confirmed.adoptAppKey(try appKey()))
        #expect(confirmed.appKey?.data == key)
    }

    /// A file that opens under the key but isn't a vault this build reads (junk sealed under a planted key, a vault of
    /// another shape) started over too: a vault file was there, so it isn't a first start.
    @Test func aSealedFileThatIsntAVaultStartsOverToo() throws {
        let file = folder.appendingPathComponent("junk/vault.sealed")
        let storage = VaultStorage(file: file, key: SymmetricKey(size: .bits256))
        try storage.save(Data("not a vault".utf8))
        let book = storage.book()
        guard case .startedOver(_?) = book.answer(.startedOver, from: .app) else { Issue.record("not started over"); return }
        #expect(!book.adoptAppKey(try appKey()))
        #expect(book.appKey == nil)
    }

    @Test func aFirstStartTakesTheAppsKeyAsBefore() throws {
        let file = folder.appendingPathComponent("first/vault.sealed")
        let storage = VaultStorage(file: file, key: SymmetricKey(size: .bits256))
        let book = storage.book()
        #expect(book.answer(.startedOver, from: .app) == .startedOver(nil))
        let key = try appKey()
        #expect(book.adoptAppKey(key))
        #expect(book.appKey?.data == key)
        #expect(storage.book().appKey?.data == key)
    }

    @Test func anIntactVaultWithItsKeyIsAsBefore() throws {
        let file = folder.appendingPathComponent("intact/vault.sealed")
        let storage = VaultStorage(file: file, key: SymmetricKey(size: .bits256))
        let key = try appKey()
        keptVault(storage, appKey: key)
        let book = storage.book()
        #expect(book.answer(.startedOver, from: .app) == .startedOver(nil))
        #expect(book.appKey?.data == key)
        // The same key from the app: as it was. Another: the vault's kept.
        #expect(book.adoptAppKey(key))
        #expect(!book.adoptAppKey(try appKey()))
        #expect(storage.book().appKey?.data == key)
    }

    /// The host's side: the app's connection enrolls its key with a keyless host as ever, and a started-over vault
    /// doesn't take it; the proof is refused in its own words, which the app's alert shows; the app's
    /// `replaceAppKey` (your "Teach It This App's Key") puts it in, and only then does the key prove the app.
    @Test func aStartedOverHostRefusesTheEnrolledKeyAndSaysWhy() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("host/vault.sealed")
        keptVault(VaultStorage(file: file, key: SymmetricKey(size: .bits256)), appKey: try appKey())
        let book = VaultStorage(file: file, key: SymmetricKey(size: .bits256)).book()
        let host = try TestHost(vault: book, appExecutable: "/usr/bin/nc", log: sessionLog(), holdsKey: false)
        let key = SymmetricKey(data: try appKey())
        let message = SteerMessage(text: "x", from: .user, agentPid: 1)

        _ = try await viaNC(host.socket, proof: nil, [.enrollApp(key: key.data), .screen(id: UUID())])
        #expect(book.appKey == nil)
        #expect(!logged(sessionLog()).contains("took the app's first key"))
        let proved = try await viaNC(host.socket, proof: key, [.vault(.seal(message))])
        guard case .error(let reason)? = proved[0] else { Issue.record("proved: \(proved)"); return }
        #expect(reason.lowercased().contains("the team's vault could not be opened and was started again"), "\(reason)")
        #expect(refused(proved[2]))

        await #expect(try viaNC(host.socket, proof: nil, [.replaceAppKey(key: key.data)])[2] == .ok)
        #expect(book.appKey?.data == key.data)
        await #expect(sealed(try viaNC(host.socket, proof: key, [.vault(.seal(message))])[2]))
        expectNoSecrets(logged(sessionLog()), [key])
    }
}
