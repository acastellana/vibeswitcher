import Foundation
import Testing
@testable import VibePlatform

/// `Platform.Files`' exclusive rename and locked create, and the two names beside them. Files and folders are a
/// test's own, in the run's scratch folder.
struct FilesExclusiveTests {
    struct Failure: Error { var what: String }

    /// A scratch folder and a descriptor on it, as the callers of the rename hold one. `close` ends both.
    struct Folder {
        var url: URL
        var descriptor: Int32

        init(_ name: String) throws {
            url = try TestScriptLinuxTests.scratch(name)
            descriptor = Sys.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else {
                try? FileManager.default.removeItem(at: url)
                throw Failure(what: "\(url.path) can't be opened: \(errno)")
            }
        }

        func path(_ name: String) -> String { url.appendingPathComponent(name).path }
        func write(_ text: String, to name: String) throws { try Data(text.utf8).write(to: url.appendingPathComponent(name)) }
        func text(_ name: String) -> String? { FileManager.default.contents(atPath: path(name)).map { String(decoding: $0, as: UTF8.self) } }
        func names() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

        func close() {
            Sys.close(descriptor)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Whether a rename onto a name something else has was refused as one should be. A name taken by a thing of
    /// another kind (a folder in a file's way, a file in a folder's) is refused on both systems, with `EEXIST` on
    /// Linux; the Mac's error for that pair isn't checked here.
    static func refusedAsTaken(_ outcome: (result: Int32, code: Int32), anotherKind: Bool = false) -> Bool {
        #if os(Linux)
        return outcome.result == -1 && outcome.code == EEXIST
        #else
        return outcome.result == -1 && (anotherKind || outcome.code == EEXIST)
        #endif
    }

    /// What a call returned, and `errno` after it.
    static func outcome(_ call: () -> Int32) -> (result: Int32, code: Int32) {
        errno = 0
        let result = call()
        return (result, errno)
    }

    // MARK: The rename

    /// The same for the rename itself and, on Linux, for what stands in for it where a file system has none.
    static func expectAFileIsRenamedOnlyToAFreeName(_ rename: (Int32, String, String) -> Int32,
                                                    sourceLocation: SourceLocation = #_sourceLocation) throws {
        let folder = try Folder("rename")
        defer { folder.close() }
        try folder.write("new", to: "from")
        try folder.write("old", to: "taken")

        let refused = outcome { rename(folder.descriptor, "from", "taken") }
        #expect(refused.result == -1, sourceLocation: sourceLocation)
        #expect(refused.code == EEXIST, sourceLocation: sourceLocation)
        #expect(folder.text("from") == "new", sourceLocation: sourceLocation)
        #expect(folder.text("taken") == "old", sourceLocation: sourceLocation)

        // Taken by a link that leads nowhere, or by a folder: taken all the same.
        try FileManager.default.createSymbolicLink(atPath: folder.path("link"), withDestinationPath: folder.path("nowhere"))
        try FileManager.default.createDirectory(atPath: folder.path("folder"), withIntermediateDirectories: false)
        for taken in ["link", "folder"] {
            let refused = outcome { rename(folder.descriptor, "from", taken) }
            #expect(refusedAsTaken(refused, anotherKind: taken == "folder"), "\(taken): \(refused)", sourceLocation: sourceLocation)
        }
        #expect(folder.text("from") == "new", sourceLocation: sourceLocation)
        #expect(folder.names() == ["folder", "from", "link", "taken"], sourceLocation: sourceLocation)

        let renamed = outcome { rename(folder.descriptor, "from", "free") }
        #expect(renamed.result == 0, "errno \(renamed.code)", sourceLocation: sourceLocation)
        #expect(folder.text("free") == "new", sourceLocation: sourceLocation)
        #expect(folder.names() == ["folder", "free", "link", "taken"], sourceLocation: sourceLocation)
        var info = stat()
        #expect(stat(folder.path("free"), &info) == 0 && info.st_nlink == 1, sourceLocation: sourceLocation)

        // Nothing to rename: the system's own error, and nothing made.
        let missing = outcome { rename(folder.descriptor, "from", "other") }
        #expect(missing.result == -1 && missing.code == ENOENT, "\(missing)", sourceLocation: sourceLocation)
        #expect(folder.names() == ["folder", "free", "link", "taken"], sourceLocation: sourceLocation)

        // By paths, with no folder open.
        let byPath = outcome { rename(AT_FDCWD, folder.path("free"), folder.path("taken")) }
        #expect(byPath.result == -1 && byPath.code == EEXIST, "\(byPath)", sourceLocation: sourceLocation)
        #expect(rename(AT_FDCWD, folder.path("free"), folder.path("moved")) == 0, sourceLocation: sourceLocation)
        #expect(folder.text("moved") == "new", sourceLocation: sourceLocation)
    }

    @Test func renameExclusiveRefusesAnExistingTarget() throws {
        // A file, as a request is put where its reader looks (WalletLocalLink).
        try Self.expectAFileIsRenamedOnlyToAFreeName { Platform.Files.renameExclusive(in: $0, from: $1, to: $2) }

        // A folder, as a worktree's memory is set aside (LeadLaunch): an empty folder is in the way too, which a
        // plain rename would replace.
        let folder = try Folder("rename")
        defer { folder.close() }
        for name in ["from", "taken"] { try FileManager.default.createDirectory(atPath: folder.path(name), withIntermediateDirectories: false) }
        try folder.write("kept", to: "from/inside")
        try folder.write("a file", to: "file")
        for taken in ["taken", "file"] {
            let refused = Self.outcome { Platform.Files.renameExclusive(in: folder.descriptor, from: "from", to: taken) }
            #expect(Self.refusedAsTaken(refused, anotherKind: taken == "file"), "\(taken): \(refused)")
        }
        #expect(folder.text("from/inside") == "kept")
        #expect(folder.text("file") == "a file")
        #expect(folder.names() == ["file", "from", "taken"])

        let renamed = Self.outcome { Platform.Files.renameExclusive(in: folder.descriptor, from: "from", to: "free") }
        #expect(renamed.result == 0, "errno \(renamed.code)")
        #expect(folder.text("free/inside") == "kept")
        #expect(folder.names() == ["file", "free", "taken"])
    }

    #if os(Linux)
    /// No file system here refuses the kernel's exclusive rename to a test (9p does, and this machine's only 9p is
    /// Windows' drives): what stands in for it is called as it is.
    @Test func withoutTheKernelsRenameAFileIsLinkedAndUnlinked() throws {
        try Self.expectAFileIsRenamedOnlyToAFreeName { Platform.Files.renameExclusiveByLink(in: $0, from: $1, to: $2) }
    }

    /// The file system's answer to the kernel's call, played: a refusal of the flag (EINVAL) or no such call (ENOSYS)
    /// sends a file by link and unlink; any other error is the answer, and nothing is tried after it.
    @Test func aRefusedFlagFallsBackAndAnyOtherErrorDoesNot() throws {
        for refusal in [EINVAL, ENOSYS] {
            try Self.expectAFileIsRenamedOnlyToAFreeName { directory, from, to in
                Platform.Files.renameExclusive(in: directory, from: from, to: to) { _, _, _ in
                    errno = refusal
                    return -1
                }
            }
        }

        let folder = try Folder("rename")
        defer { folder.close() }
        try folder.write("new", to: "from")
        for other in [EACCES, EXDEV, EEXIST, EROFS] {
            let failed = Self.outcome {
                Platform.Files.renameExclusive(in: folder.descriptor, from: "from", to: "free") { _, _, _ in
                    errno = other
                    return -1
                }
            }
            #expect(failed.result == -1 && failed.code == other, "\(other): \(failed)")
            #expect(folder.names() == ["from"])
        }
        // And the call that worked isn't done twice.
        var calls = 0
        let worked = Platform.Files.renameExclusive(in: folder.descriptor, from: "from", to: "free") { directory, from, to in
            calls += 1
            errno = EINVAL
            return renameat(directory, from, directory, to)
        }
        #expect(worked == 0 && calls == 1)
        #expect(folder.names() == ["free"])
    }

    /// A folder can't be given a second name: where the kernel's rename is refused, so is the folder's, with the
    /// refusal's own error, and it stays where it was. Never a plain rename in its place.
    @Test func withoutTheKernelsRenameAFolderIsRefused() throws {
        let folder = try Folder("rename")
        defer { folder.close() }
        try FileManager.default.createDirectory(atPath: folder.path("from"), withIntermediateDirectories: false)
        try folder.write("kept", to: "from/inside")
        for refusal in [EINVAL, ENOSYS] {
            let played = Self.outcome {
                Platform.Files.renameExclusive(in: folder.descriptor, from: "from", to: "free") { _, _, _ in
                    errno = refusal
                    return -1
                }
            }
            #expect(played.result == -1 && played.code == refusal, "\(refusal): \(played)")
        }
        let direct = Self.outcome { Platform.Files.renameExclusiveByLink(in: folder.descriptor, from: "from", to: "free") }
        #expect(direct.result == -1 && direct.code == EINVAL, "\(direct)")
        #expect(folder.names() == ["from"])
        #expect(folder.text("from/inside") == "kept")
    }

    /// The first name can't be removed (its folder takes no changes once the second name is made, played here by a
    /// second folder that never did): the rename fails with that error and the second name is taken back.
    @Test func aRenameByLinkThatCannotFinishLeavesNoSecondName() throws {
        // Not as root, whom no folder's mode stops.
        guard geteuid() != 0 else { return }
        let folder = try Folder("rename")
        defer { folder.close() }
        try FileManager.default.createDirectory(atPath: folder.path("locked"), withIntermediateDirectories: false)
        try folder.write("new", to: "locked/from")
        #expect(chmod(folder.path("locked"), 0o500) == 0)
        defer { chmod(folder.path("locked"), 0o700) }
        // A link out of a folder that can't be written is made; the unlink in it is what fails.
        #expect(linkat(folder.descriptor, "locked/from", folder.descriptor, "probe", 0) == 0)
        #expect(unlinkat(folder.descriptor, "probe", 0) == 0)

        let failed = Self.outcome { Platform.Files.renameExclusiveByLink(in: folder.descriptor, from: "locked/from", to: "free") }
        #expect(failed.result == -1 && failed.code == EACCES, "\(failed)")
        #expect(folder.names() == ["locked"])
        #expect(folder.text("locked/from") == "new")
    }
    #endif

    // MARK: The locked file

    /// What 8 readers and the maker of the files share.
    final class Line: @unchecked Sendable {
        private let condition = NSCondition()
        private var making = 0
        private var released: Set<Int> = []
        private var heldSightings: [Int: Int] = [:]
        private var stopped = false
        private var taken: [Int] = []

        private func locked<Value>(_ body: () -> Value) -> Value {
            condition.lock()
            defer { condition.unlock() }
            return body()
        }

        /// The maker: file `number` is about to be made.
        func make(_ number: Int) { locked { making = number } }

        /// A reader: whether to stop, and the file being made now.
        func now() -> (stopped: Bool, making: Int) { locked { (stopped, making) } }

        /// A reader opened file `number` and tried its lock.
        func tried(_ number: Int, gotTheLock: Bool) {
            locked {
                if !gotTheLock {
                    heldSightings[number, default: 0] += 1
                } else if !released.contains(number) {
                    taken.append(number)
                }
                condition.broadcast()
            }
        }

        /// The maker: waits until a reader has found file `number` held (or one took a held file's lock, which ends
        /// the test); false when none did within the hang guard.
        func waitUntilSeenHeld(_ number: Int) -> Bool {
            let deadline = Date().addingTimeInterval(TestScriptLinuxTests.hangGuard)
            return locked {
                while heldSightings[number] == nil, taken.isEmpty {
                    if !condition.wait(until: deadline) { return false }
                }
                return true
            }
        }

        /// The maker: file `number` is let go, said before its descriptor is closed.
        func release(_ number: Int) { locked { _ = released.insert(number) } }

        func stop() { locked { stopped = true } }

        /// The files a reader locked while their maker still held them, by number.
        var lockedWhileHeld: [Int] { locked { taken } }
        var filesSeenHeld: Int { locked { heldSightings.count } }
    }

    /// The gap a reader could fall into, which `TestLock.waiters` would take for a dead ticket and remove: a file is
    /// there under its name and not locked yet. 8 threads each open the file being made as soon as it has its name
    /// and try its lock, for as long as the maker makes, holds and lets go 200 files; the maker lets each go only once
    /// a reader has found it held. No reader ever locks a file its maker holds.
    @Test func createLockedIsNeverSeenUnlocked() throws {
        let folder = try Folder("locked")
        defer { folder.close() }
        let files = 200, readers = 8
        let line = Line()
        let name = { (number: Int) in folder.path("ticket-\(number)") }
        let done = DispatchGroup()
        for _ in 0..<readers {
            done.enter()
            Thread.detachNewThread {
                defer { done.leave() }
                // Each reader waits at the name of the file it hasn't seen yet, opening it the moment it is there.
                var number = 0, misses = 0
                while true {
                    let fd = open(name(number), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                    guard fd >= 0 else {
                        // Not there (yet, or any more): now and then, whether to stop, or to go on to a later file.
                        misses += 1
                        if misses % 64 == 0 {
                            let now = line.now()
                            if now.stopped { return }
                            number = max(number, now.making)
                        }
                        continue
                    }
                    line.tried(number, gotTheLock: flock(fd, LOCK_EX | LOCK_NB) == 0)
                    close(fd)
                    number += 1
                }
            }
        }
        defer {
            line.stop()
            done.wait()
        }

        var made = 0
        for number in 0..<files {
            line.make(number)
            let file = Self.outcome { Platform.Files.createLocked(name(number), mode: 0o600) }
            try #require(file.result >= 0, "file \(number) wasn't made: errno \(file.code)")
            made += 1
            let seen = line.waitUntilSeenHeld(number)
            line.release(number)
            close(file.result)
            unlink(name(number))
            try #require(seen, "no reader looked at file \(number)")
        }
        line.stop()
        done.wait()

        let lockedWhileHeld = line.lockedWhileHeld
        #expect(lockedWhileHeld == [], "\(Set(lockedWhileHeld).count) of \(made) files were locked by a reader while their maker held them")
        #expect(made == files)
        // Every file was looked at while it was held: the readers were there.
        if lockedWhileHeld.isEmpty { #expect(line.filesSeenHeld == files) }
        // Nothing of the making stays: no first name, no file.
        #expect(folder.names() == [])
    }

    @Test func createLockedMakesTheFileHeldAndRefusesATakenName() throws {
        let folder = try Folder("locked")
        defer { folder.close() }
        let path = folder.path("ticket-1")
        let made = Self.outcome { Platform.Files.createLocked(path, mode: 0o600) }
        try #require(made.result >= 0, "errno \(made.code)")
        var open = true
        defer { if open { close(made.result) } }
        #expect(folder.names() == ["ticket-1"])

        // The file is the one the descriptor is on, new, with the mode asked, open for writing and not for a
        // program this process starts.
        var info = stat(), byName = stat()
        #expect(fstat(made.result, &info) == 0 && stat(path, &byName) == 0)
        #expect(info.inode == byName.inode)
        #expect(info.st_nlink == 1)
        #expect(info.byteSize == 0)
        #expect(info.st_mode & 0o7777 == 0o600)
        #expect(info.st_mode & S_IFMT == S_IFREG)
        #expect(fcntl(made.result, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(made.result, F_GETFL) & O_ACCMODE == O_WRONLY)
        #expect(write(made.result, "note\n", 5) == 5)
        #expect(folder.text("ticket-1") == "note\n")

        // Held: another opening of it can't take the lock, of either kind.
        let other = Sys.open(path, O_RDONLY | O_CLOEXEC)
        try #require(other >= 0)
        defer { close(other) }
        for kind in [LOCK_EX, LOCK_SH] {
            let taken = Self.outcome { flock(other, kind | LOCK_NB) }
            #expect(taken.result == -1 && taken.code == EWOULDBLOCK, "\(taken)")
        }

        // The name is taken: by this file, by a link that leads nowhere, by a folder. Nothing is made or changed.
        try FileManager.default.createSymbolicLink(atPath: folder.path("link"), withDestinationPath: folder.path("nowhere"))
        try FileManager.default.createDirectory(atPath: folder.path("folder"), withIntermediateDirectories: false)
        for taken in ["ticket-1", "link", "folder"] {
            let refused = Self.outcome { Platform.Files.createLocked(folder.path(taken), mode: 0o600) }
            #expect(refused.result == -1 && refused.code == EEXIST, "\(taken): \(refused)")
            if refused.result >= 0 { close(refused.result) }
        }
        #expect(folder.names() == ["folder", "link", "ticket-1"])
        #expect(folder.text("ticket-1") == "note\n")
        // And in a folder that isn't there, the system's own error.
        let nowhere = Self.outcome { Platform.Files.createLocked(folder.path("none/ticket-1"), mode: 0o600) }
        #expect(nowhere.result == -1 && nowhere.code == ENOENT, "\(nowhere)")

        // Let go when the descriptor is closed (and the copy of it gone that a child another test starts meanwhile
        // holds until its program replaces it).
        close(made.result)
        open = false
        #expect(SocketsTests.eventually { flock(other, LOCK_EX | LOCK_NB) == 0 })
    }

    /// The mode is the one asked, a file its owner can't write included; and the path is taken as open(2) takes
    /// it, here with a doubled slash and a dot in it.
    @Test func createLockedTakesTheModeAndThePathAsGiven() throws {
        let folder = try Folder("locked")
        defer { folder.close() }
        let made = Self.outcome { Platform.Files.createLocked(folder.url.path + "/.//ticket-2", mode: 0o400) }
        try #require(made.result >= 0, "errno \(made.code)")
        defer { close(made.result) }
        #expect(folder.names() == ["ticket-2"])
        var info = stat()
        #expect(fstat(made.result, &info) == 0 && info.st_mode & 0o7777 == 0o400)
        #expect(write(made.result, "note\n", 5) == 5)
    }

    // MARK: The names

    @Test func eventsOnlyOpensAFolderToWatch() throws {
        let folder = try Folder("events")
        defer { folder.close() }
        try folder.write("a", to: "inside")
        let watched = Sys.open(folder.url.path, Platform.Files.eventsOnly | O_DIRECTORY | O_CLOEXEC)
        try #require(watched >= 0, "errno \(errno)")
        defer { close(watched) }
        var info = stat()
        #expect(fstat(watched, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR)
        #if os(Linux)
        // Linux reads: what is in the folder is reached through it.
        #expect(Platform.Files.eventsOnly == O_RDONLY)
        #expect(fstatat(watched, "inside", &info, AT_SYMLINK_NOFOLLOW) == 0 && info.byteSize == 1)
        #endif
    }

    /// Looked at, not written in: a test leaves nothing in the folder every process shares.
    @Test func sharedTemporaryRootExistsAndIsWritable() throws {
        let root = Platform.Files.sharedTemporaryRoot
        #if os(Linux)
        #expect(root == "/tmp")
        #else
        #expect(root == "/private/tmp")
        #endif
        var info = stat()
        try #require(lstat(root, &info) == 0, "\(root): errno \(errno)")
        // A folder itself, not a link to one: its real path.
        #expect(info.st_mode & S_IFMT == S_IFDIR)
        #expect(access(root, R_OK | W_OK | X_OK) == 0, "\(root) can't be written in: errno \(errno)")
        // Everyone's, and each one's files their own there (the sticky bit).
        #expect(info.st_mode & 0o1777 == 0o1777)
    }
}
