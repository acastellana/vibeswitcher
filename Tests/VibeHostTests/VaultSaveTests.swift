import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A vault save that fails isn't lost silently: it's logged, by the file's name only, tried again, and goes through when
/// it can; a save reaches the disk before it takes the vault's place.
struct VaultSaveTests {
    let root = "/repos/vault-save"
    let temp = Scratch()
    let folder: URL
    init() throws {
        folder = temp.url("vault-save")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Retries held by the test, fired when it says.
    final class Later {
        var delays: [TimeInterval] = []
        var waiting: [() -> Void] = []
        func arm(_ delay: TimeInterval, _ fire: @escaping () -> Void) {
            delays.append(delay)
            waiting.append(fire)
        }
        func fire() {
            let due = waiting
            waiting = []
            due.forEach { $0() }
        }
    }

    @Test func aFailedSaveIsLoggedByNameRetriedAndGoesThroughLater() throws {
        // A plain file where the vault's folder goes: a save really fails until it's gone.
        let blocker = folder.appendingPathComponent("lead")
        #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        let file = blocker.appendingPathComponent("vault.sealed")
        let logFile = folder.appendingPathComponent("host.log")
        let key = SymmetricKey(size: .bits256)
        let later = Later()
        let storage = VaultStorage(file: file, key: key, logPath: logFile.path, retryLater: later.arm)
        let book = storage.book()

        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no grant")
            return
        }
        #expect(later.delays == VaultStorage.retryDelays.prefix(1).map { $0 })
        // Another change meanwhile fails too, and doesn't start a second retry.
        _ = book.answer(.bind(grant: grant, root: root, session: "lead-session"), from: .app)
        #expect(later.waiting.count == 1)
        later.fire()
        #expect(later.delays == Array(VaultStorage.retryDelays.prefix(2)), "still failing: backed off, tried again")

        let log = try String(contentsOf: logFile, encoding: .utf8)
        #expect(log.components(separatedBy: "\n").filter { $0.contains("couldn't save vault.sealed") }.count == 1, "\(log)")

        try FileManager.default.removeItem(at: blocker)
        later.fire()
        #expect(later.waiting.isEmpty)
        // The newest vault went to disk, the change made after the first failure included.
        #expect(VaultStorage(file: file, key: key).book().answer(.whoami(root: root), from: .session("lead-session")) != .member(nil))

        let saved = try String(contentsOf: logFile, encoding: .utf8)
        #expect(saved.contains("vault.sealed saved after failing"), "\(saved)")
        let senderKey = try #require(JSONSerialization.jsonObject(with: book.serialized) as? [String: Any])["senderKey"] as? String
        let keyText = key.withUnsafeBytes { Data($0).base64EncodedString() }
        for secret in [grant, "lead-session", keyText, try #require(senderKey), folder.path, "senderKey", "teams"] {
            #expect(!saved.contains(secret), "\(secret)")
        }

        // Saving works again: a later change is on disk at once, with nothing left to retry.
        #expect(book.adoptAppKey(Data(repeating: 9, count: 32)))
        #expect(later.waiting.isEmpty)
        #expect(VaultStorage(file: file, key: key).book().appKey?.data == Data(repeating: 9, count: 32))
    }

    @Test func aSaveIsSyncedBeforeItsRename() throws {
        let file = folder.appendingPathComponent("vault.sealed")
        let key = SymmetricKey(size: .bits256)
        var synced = 0
        var replaced: Bool?
        var wrote = -1
        let saving = VaultStorage(file: file, key: key, sync: { fd in
            synced += 1
            replaced = FileManager.default.fileExists(atPath: file.path)
            var info = stat()
            wrote = fstat(fd, &info) == 0 ? Int(info.st_size) : -1
            return fsync(fd) == 0
        }, retryLater: { _, _ in })
        try saving.save(Data("one".utf8))
        #expect(synced == 1)
        #expect(replaced == false, "the vault took its place before it was synced")
        #expect(wrote == (try Data(contentsOf: file)).count, "synced before all of it was written")
        #expect(saving.load() == Data("one".utf8))

        // A sync that fails keeps the vault as it was, and leaves no half-written file beside it.
        let failing = VaultStorage(file: file, key: key, sync: { _ in false }, retryLater: { _, _ in })
        #expect(throws: (any Error).self) { try failing.save(Data("two".utf8)) }
        #expect(failing.load() == Data("one".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["vault.sealed"])
    }
}
