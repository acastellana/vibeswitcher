import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The session host's config look keeps far from the end of its stack (the plugins lane's report of 2026-11-22: a
/// tenth stored field on `LeadVaultV2.Book` read as a host SIGSEGV on `config held`, "a stack nearly used up"). Measured
/// here, not guessed: the vault's own answer path (`LeadVault.Book.answer` with a held first look: `ConfigSeal.hashes`
/// of a home and a main checkout, the state encoded after the change, the record read back, the whole vault restored
/// from its encoding) runs on a thread whose stack this test made and painted, and the deepest byte it touched is the
/// stack it used. The host runs it on a dispatch worker, whose stack is 8 MB on Linux (the main thread's too).
@Suite(.serialized) struct VaultStackTests {
    private let scratch = Scratch()

    /// Runs `body` on a thread whose `bytes` of stack this process allocated and painted; the most of it `body` used.
    static func peak(bytes: Int, _ body: @escaping () -> Void) -> Int {
        let stack = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16 * 1024)
        defer { stack.deallocate() }
        stack.initializeMemory(as: UInt8.self, repeating: 0xA5, count: bytes)
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_setstack(&attributes, stack, bytes)
        final class Work { let body: () -> Void; init(_ body: @escaping () -> Void) { self.body = body } }
        let work = Unmanaged.passRetained(Work(body)).toOpaque()
        #if canImport(Darwin)
        var thread: pthread_t?
        #else
        var thread = pthread_t()
        #endif
        let made = pthread_create(&thread, &attributes, { argument in
            Unmanaged<Work>.fromOpaque(argument!).takeRetainedValue().body()
            return nil
        }, work)
        guard made == 0 else { return -1 }
        #if canImport(Darwin)
        pthread_join(thread!, nil)
        #else
        pthread_join(thread, nil)
        #endif
        let painted = stack.assumingMemoryBound(to: UInt8.self)
        var untouched = 0
        while untouched < bytes, painted[untouched] == 0xA5 { untouched += 1 }
        return bytes - untouched
    }

    /// A home with the agents' files and a main checkout with workflow.md, and a vault holding its first look.
    private func vault() throws -> (vault: LeadVault, book: LeadVault.Book, home: String, root: String) {
        let home = scratch.url("home")
        for (path, text) in [(".claude/settings.json", "{\"hooks\":{}}"), (".claude.json", "{}"), (".claude/CLAUDE.md", "x\n"), (".bashrc", "x\n")] {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let repo = scratch.url("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".vibeswitcher"), withIntermediateDirectories: true)
        try "---\nbase_branch: main\n---\n".write(to: repo.appendingPathComponent(".vibeswitcher/workflow.md"), atomically: true, encoding: .utf8)
        let book = LeadVault.Book()
        book.configHome = home.path
        book.holdsFirstLook = true
        book.onChange = { _ in }
        return (book.vault(folder: scratch.url("vault"), as: { .app }), book, home.path, repo.path)
    }

    /// The look `config held` asks of the host, for the home folder and for a project, as the engine asks it.
    private static func look(_ vault: LeadVault, _ book: LeadVault.Book, roots: [String]) {
        for root in roots {
            _ = try? vault.guardedSettings(root: root)
            _ = try? vault.reviewFloor(root: root)
            vault.retrySealingAppWrites()
            _ = try? vault.checkConfig(root: root, shown: [:])
            _ = try? vault.guardedRecord(root: root)
            _ = try? vault.checkConfig(root: root)
        }
        _ = LeadVault.Book(restoring: book.serialized)
    }

    /// Measured: the look uses a small part of a thread's stack, far from the 8 MB a host thread has. A bound well
    /// above what it uses today (about 130 KB in a debug build) and far below 8 MB: a path that grew a recursion or
    /// stack-sized values fails here, with the number, not as a host crash.
    @Test func theConfigLookUsesASmallPartOfAThreadsStack() throws {
        let (vault, book, home, root) = try vault()
        let used = Self.peak(bytes: 16 << 20) { Self.look(vault, book, roots: [home, root]) }
        #expect(used > 0 && used < 512 * 1024, "the config look used \(used / 1024) KB of stack")
    }

    /// And it runs whole on a thread with a sixteenth of a host thread's stack (512 KB).
    @Test func theConfigLookRunsOnAHalfMegabyteStack() throws {
        let (vault, book, home, root) = try vault()
        let used = Self.peak(bytes: 512 * 1024) { Self.look(vault, book, roots: [home, root]) }
        #expect(used > 0 && used < 512 * 1024, "\(used)")
        #expect(try vault.guardedRecord(root: root) != nil, "the look was recorded")
    }
}
