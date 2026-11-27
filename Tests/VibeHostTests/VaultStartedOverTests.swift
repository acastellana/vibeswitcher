import CryptoKit
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A vault that had to start over (its sealed file no longer opens under the Keychain key: a Keychain reset, or another
/// program of your account that replaced the key, 2026-11-26) takes no app key on its own: not the one the app hands
/// the host on stdin at its start, nor the one the app's connection enrolls. You're told, and the key goes in only
/// through the app's own "Teach It This App's Key" (`replaceAppKey`). A first start (no vault file yet) takes the app's
/// key as before, and a vault that opens is as it was. Until you've answered, nothing is saved over the file that didn't
/// open; once you have, it's set aside beside the new one. Scratch seams only: `VaultStorage(file:key:)` on a scratch
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

        // A change meanwhile isn't saved: the file that didn't open stays as it was, byte for byte, until you've
        // answered (fail closed, lose nothing: put the Keychain's old key back and it opens again).
        let kept = try Data(contentsOf: file)
        guard case .grant = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no grant"); return
        }
        #expect(try Data(contentsOf: file) == kept)
        #expect(VaultStorage(file: file, key: before).load() != nil)
        #expect(storage.load() == nil)
        #expect(asideFiles(file).isEmpty)
        // A host started again before you answered: the file still doesn't open, so it starts over again, and still
        // takes no key on its own (fail closed: the next start isn't a first one).
        let reopened = storage.book()
        guard case .startedOver(_?) = reopened.answer(.startedOver, from: .app) else { Issue.record("its start over forgotten"); return }
        #expect(!reopened.adoptAppKey(key))
        #expect(reopened.appKey == nil)
        #expect(try Data(contentsOf: file) == kept)

        // Your confirmation (the app's replaceAppKey): taken and saved, with what changed while it waited; the file
        // that didn't open is set aside beside it, as it was, under a name that says why and when.
        #expect(book.adoptAppKey(key, replacing: true))
        let confirmed = storage.book()
        #expect(confirmed.appKey?.data == key)
        guard case .member(let lead?) = confirmed.answer(.current(role: .lead, root: root, task: nil), from: .app) else {
            Issue.record("the change made while it waited is lost"); return
        }
        #expect(lead.role == .lead)
        let aside = asideFiles(file)
        #expect(aside.count == 1)
        #expect(aside.first.map { $0.lastPathComponent.hasPrefix("vault.sealed.didnt-open-") } == true, "\(aside)")
        #expect(aside.first.flatMap { try? Data(contentsOf: $0) } == kept)
        // From then on the vault is as any other.
        #expect(confirmed.adoptAppKey(key))
        #expect(!confirmed.adoptAppKey(try appKey()))
        #expect(confirmed.appKey?.data == key)
        _ = confirmed.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app)
        #expect(asideFiles(file).count == 1)
    }

    /// The files set aside beside `file`'s vault (`VaultStorage.setAsideSuffix`).
    func asideFiles(_ file: URL) -> [URL] {
        let folder = file.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(file.lastPathComponent + ".") }.map { folder.appendingPathComponent($0) }
    }

    /// The build before handed over a vault that started over and still waits for your answer: the new build doesn't
    /// save it over the file that didn't open either.
    @Test func aHandedOverStartedOverVaultKeepsTheFileThatDidntOpen() throws {
        let file = folder.appendingPathComponent("handover/vault.sealed")
        keptVault(VaultStorage(file: file, key: SymmetricKey(size: .bits256)), appKey: try appKey())
        let kept = try Data(contentsOf: file)
        let storage = VaultStorage(file: file, key: SymmetricKey(size: .bits256))
        let before = storage.book()
        #expect(before.awaitsAppKey)

        let book = storage.book(handedOver: before.serialized)
        #expect(book.awaitsAppKey)
        _ = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app)
        #expect(try Data(contentsOf: file) == kept)
        #expect(asideFiles(file).isEmpty)

        #expect(book.adoptAppKey(try appKey(), replacing: true))
        #expect(storage.book().appKey != nil)
        #expect(asideFiles(file).count == 1)
    }

    /// A build before without a key started over and hands its vault over to one whose key opens the file: that file
    /// isn't saved over either, before your answer or after it (set aside then).
    @Test func aHandedOverWaitingVaultKeepsAFileThatOpens() throws {
        let file = folder.appendingPathComponent("opens/vault.sealed")
        let storage = VaultStorage(file: file, key: SymmetricKey(size: .bits256))
        keptVault(storage, appKey: try appKey())
        let kept = try Data(contentsOf: file)
        let waiting = LeadVault.Book(startingOver: true)
        #expect(waiting.awaitsAppKey)

        let book = storage.book(handedOver: waiting.serialized)
        _ = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app)
        #expect(try Data(contentsOf: file) == kept)
        #expect(book.adoptAppKey(try appKey(), replacing: true))
        let aside = asideFiles(file)
        #expect(aside.count == 1)
        #expect(aside.first.flatMap { try? Data(contentsOf: $0) } == kept)
    }

    /// A first start with a key saves as ever, and sets nothing aside.
    @Test func aFirstStartSetsNothingAside() throws {
        let file = folder.appendingPathComponent("plain/vault.sealed")
        let storage = VaultStorage(file: file, key: SymmetricKey(size: .bits256))
        let book = storage.book()
        _ = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app)
        #expect(storage.load() != nil)
        _ = storage.book().answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app)
        #expect(asideFiles(file).isEmpty)
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

    /// No vault file, and a key the Keychain had already (`keyIsNew` false: a vault had been sealed under it, and its
    /// file moved aside or deleted): started over, the same as a file that didn't open. Nothing is saved until you
    /// answer, the host refuses the app's proof in the same words (the same alert), and your confirmation saves it.
    /// With a key made on this start it's a first start as ever.
    @Test func aMissingFileWithAKeyThereAlreadyStartsOver() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("missing/vault.sealed")
        let storage = VaultStorage(file: file, key: SymmetricKey(size: .bits256), keyIsNew: false)
        let book = storage.book()
        #expect(book.awaitsAppKey)
        let key = SymmetricKey(data: try appKey())
        #expect(!book.adoptAppKey(key.data))
        _ = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app)
        #expect(!FileManager.default.fileExists(atPath: file.path), "saved before you answered")

        let host = try TestHost(vault: book, appExecutable: "/usr/bin/nc", log: sessionLog(), holdsKey: false)
        let message = SteerMessage(text: "x", from: .user, agentPid: 1)
        _ = try await viaNC(host.socket, proof: nil, [.enrollApp(key: key.data), .screen(id: UUID())])
        #expect(book.appKey == nil)
        let proved = try await viaNC(host.socket, proof: key, [.vault(.seal(message))])
        #expect(proved[0] == .error(AppProof.vaultStartedOver), "\(proved)")
        await #expect(try viaNC(host.socket, proof: nil, [.replaceAppKey(key: key.data)])[2] == .ok)
        #expect(storage.book().appKey?.data == key.data)
        #expect(asideFiles(file).isEmpty)

        // A key made now, no file: a first start.
        let first = VaultStorage(file: folder.appendingPathComponent("made/vault.sealed"), key: SymmetricKey(size: .bits256), keyIsNew: true)
        #expect(first.book().adoptAppKey(key.data))
        // No key at all: in memory, as ever, whatever the Keychain had.
        #expect(VaultStorage(file: folder.appendingPathComponent("none/vault.sealed"), key: nil, keyIsNew: false).book().adoptAppKey(key.data))
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
