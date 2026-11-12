import Foundation
import Testing
@testable import VibePlatform

/// `Platform.FolderWatch`: what a folder's watch tells of and what it doesn't, read by `wait()` and by `deliver`.
/// Each test has a folder of its own in the run's scratch folder, with the watched folder and one beside it inside.
/// A wait that should return is given the hang guard: past it the watch is stopped, the wait answers nil and the
/// test fails.
///
/// One at a time: the descriptor count below is of this suite's watches alone.
@Suite(.serialized)
struct FolderWatchTests {
    typealias Change = Platform.FolderWatch.Change

    static let hangGuard = TestScriptLinuxTests.hangGuard

    struct Failure: Error { var what: String }

    /// Shared with a thread or a queue a test starts.
    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var held: Value

        init(_ value: Value) { held = value }

        var value: Value {
            get { lock.withLock { held } }
            set { lock.withLock { held = newValue } }
        }
    }

    /// A test's folders: `watched`, and `outside` beside it. The test removes `root`.
    static func folders() throws -> (root: URL, watched: URL, outside: URL) {
        let root = try TestScriptLinuxTests.scratch("folder-watch")
        let watched = root.appendingPathComponent("watched", isDirectory: true), outside = root.appendingPathComponent("outside", isDirectory: true)
        for folder in [watched, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        return (root, watched, outside)
    }

    /// Makes an empty file, in one step: one entry made, and nothing renamed into place.
    static func make(_ file: URL) throws {
        let descriptor = open(file.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw Failure(what: "\(file.path) wasn't made: errno \(errno)") }
        close(descriptor)
    }

    /// The watch's next change; nil when none came within the hang guard (or the watch was stopped).
    static func next(_ watch: Platform.FolderWatch) -> Change? {
        let guardian = DispatchWorkItem { watch.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + hangGuard, execute: guardian)
        defer { guardian.cancel() }
        return watch.wait()
    }

    /// Waits until `condition` holds, asking every few milliseconds; false when it didn't within the hang guard.
    static func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(hangGuard)
        while !condition() {
            guard Date() < deadline else { return false }
            usleep(2_000)
        }
        return true
    }

    // MARK: What is a change

    @Test func aNewFileInTheFolderIsAnEntriesChange() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let watch = try #require(Platform.FolderWatch(path: folders.watched.path))
        defer { watch.stop() }
        let file = folders.watched.appendingPathComponent("new")
        try Self.make(file)
        #expect(Self.next(watch) == .entries)
        // And its removal.
        #expect(unlink(file.path) == 0)
        #expect(Self.next(watch) == .entries)
    }

    @Test func aRenameIntoTheFolderIsOne() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let outside = folders.outside.appendingPathComponent("file"), inside = folders.watched.appendingPathComponent("file")
        try Self.make(outside)
        let watch = try #require(Platform.FolderWatch(path: folders.watched.path))
        defer { watch.stop() }
        #expect(rename(outside.path, inside.path) == 0)
        #expect(Self.next(watch) == .entries)
        // Within the folder, and out of it again.
        let renamed = folders.watched.appendingPathComponent("renamed")
        #expect(rename(inside.path, renamed.path) == 0)
        #expect(Self.next(watch) == .entries)
        #expect(rename(renamed.path, outside.path) == 0)
        #expect(Self.next(watch) == .entries)
    }

    /// The one bounded wait here that is the assertion itself: nothing is told within 300 ms of the write. That the
    /// watch was listening all the while is shown after it, by a new file it does tell of.
    @Test func aWriteInsideAnExistingFileIsNotOne() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let existing = folders.watched.appendingPathComponent("existing")
        try Self.make(existing)
        let watch = try #require(Platform.FolderWatch(path: folders.watched.path))
        defer { watch.stop() }
        let heard = DispatchSemaphore(value: 0)
        watch.deliver(on: DispatchQueue(label: "folder-watch-tests.write")) { _ in heard.signal() }

        let descriptor = open(existing.path, O_WRONLY | O_APPEND)
        try #require(descriptor >= 0)
        #expect(write(descriptor, "written", 7) == 7)
        close(descriptor)
        #expect(heard.wait(timeout: .now() + 0.3) == .timedOut, "a write inside a file that was there was told as a change of the folder")

        try Self.make(folders.watched.appendingPathComponent("new"))
        #expect(heard.wait(timeout: .now() + Self.hangGuard) == .success, "the watch tells of nothing at all")
    }

    @Test func removingTheFolderIsFolderGone() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let watch = try #require(Platform.FolderWatch(path: folders.watched.path))
        defer { watch.stop() }
        #expect(rmdir(folders.watched.path) == 0)
        #expect(Self.next(watch)?.contains(.folderGone) == true)
    }

    @Test func renamingTheFolderIsFolderGone() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let watch = try #require(Platform.FolderWatch(path: folders.watched.path))
        defer { watch.stop() }
        #expect(rename(folders.watched.path, folders.root.appendingPathComponent("moved").path) == 0)
        #expect(Self.next(watch) == .folderGone)
    }

    /// Twenty files made before the watch is read are one change. And then quiet, shown without waiting for nothing:
    /// the next thing told is the next thing done (the folder's own rename), not the rest of the twenty.
    @Test func aBurstOfTwentyCreationsIsAtLeastOneChangeAndThenQuiet() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let watch = try #require(Platform.FolderWatch(path: folders.watched.path))
        defer { watch.stop() }
        for index in 0..<20 { try Self.make(folders.watched.appendingPathComponent("burst-\(index)")) }
        #expect(Self.next(watch) == .entries)
        #expect(rename(folders.watched.path, folders.root.appendingPathComponent("moved").path) == 0)
        #expect(Self.next(watch) == .folderGone, "a second change was told for one burst")
    }

    // MARK: Stopping

    /// The wait is under way on a thread of its own (the watch says so) when another thread stops the watch.
    @Test func stopEndsAWaitInProgress() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let watch = try #require(Platform.FolderWatch(path: folders.watched.path))
        let answer = Box<Change??>(nil)
        let answered = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            answer.value = .some(watch.wait())
            answered.signal()
        }
        #expect(Self.eventually { watch.system.isWaitedOn })
        watch.stop()
        #expect(answered.wait(timeout: .now() + Self.hangGuard) == .success, "the wait went on after stop()")
        #expect(answer.value == .some(nil))
        // Stopped for good: again is nothing, and so is a later wait.
        watch.stop()
        #expect(watch.wait() == nil)
        try Self.make(folders.watched.appendingPathComponent("after"))
        #expect(watch.wait() == nil)
    }

    @Test func aStoppedWatchIsNotWaitedOn() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let watch = try #require(Platform.FolderWatch(path: folders.watched.path))
        try Self.make(folders.watched.appendingPathComponent("before"))
        watch.stop()
        #expect(watch.wait() == nil)
    }

    // MARK: On a queue

    @Test func deliverCallsTheHandlerOnItsQueue() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let watch = try #require(Platform.FolderWatch(path: folders.watched.path))
        defer { watch.stop() }
        let queue = DispatchQueue(label: "folder-watch-tests.deliver")
        let mark = DispatchSpecificKey<String>()
        queue.setSpecific(key: mark, value: "the watch's queue")
        let told = Box<[(change: Change, queue: String?)]>([])
        let heard = DispatchSemaphore(value: 0)
        watch.deliver(on: queue) { change in
            told.value += [(change, DispatchQueue.getSpecific(key: mark))]
            heard.signal()
        }
        // A watch given to a queue isn't waited on as well.
        #expect(watch.wait() == nil)

        try Self.make(folders.watched.appendingPathComponent("new"))
        #expect(heard.wait(timeout: .now() + Self.hangGuard) == .success)
        #expect(told.value.first?.change == .entries)
        #expect(told.value.first?.queue == "the watch's queue")

        #expect(rename(folders.watched.path, folders.root.appendingPathComponent("moved").path) == 0)
        #expect(heard.wait(timeout: .now() + Self.hangGuard) == .success)
        #expect(told.value.last?.change == .folderGone)
        #expect(told.value.count == 2)
    }

    /// As WalletLocalLink's watch does on `folderGone`: the handler stops the watch it is called by.
    @Test func aHandlerCanStopItsOwnWatch() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let watch = try #require(Platform.FolderWatch(path: folders.watched.path))
        let calls = Box(0)
        let heard = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "folder-watch-tests.own-stop")
        watch.deliver(on: queue) { [weak watch] _ in
            calls.value += 1
            watch?.stop()
            heard.signal()
        }
        try Self.make(folders.watched.appendingPathComponent("first"))
        #expect(heard.wait(timeout: .now() + Self.hangGuard) == .success)
        #if os(Linux)
        // Closed, so nothing more can come: the file made now is told to nobody.
        #expect(watch.system.released.wait(timeout: .now() + Self.hangGuard) == .success)
        try Self.make(folders.watched.appendingPathComponent("second"))
        queue.sync {}
        #expect(calls.value == 1)
        #endif
    }

    // MARK: A descriptor, and what can't be watched

    /// The folder is watched through a descriptor open on it, as WalletLocalLink hands one over. Its removal is
    /// told at once too: on Linux only because the watch doesn't keep the descriptor open.
    @Test func aDescriptorIsTakenOver() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let descriptor = open(folders.watched.path, O_RDONLY)
        try #require(descriptor >= 0)
        let watch = try #require(Platform.FolderWatch(descriptor: descriptor))
        defer { watch.stop() }
        let file = folders.watched.appendingPathComponent("new")
        try Self.make(file)
        #expect(Self.next(watch) == .entries)
        #expect(unlink(file.path) == 0)
        #expect(Self.next(watch) == .entries)
        #expect(rmdir(folders.watched.path) == 0)
        #expect(Self.next(watch)?.contains(.folderGone) == true)
    }

    @Test func whatIsNotThereCantBeWatched() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        #expect(Platform.FolderWatch(path: folders.root.appendingPathComponent("never-made").path) == nil)
        #expect(Platform.FolderWatch(descriptor: -1) == nil)
    }

    #if os(Linux)
    @Test func aFileIsNotAFolderToWatch() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let file = folders.outside.appendingPathComponent("file")
        try Self.make(file)
        #expect(Platform.FolderWatch(path: file.path) == nil)
    }

    /// The mount points of this machine's 9p file systems (Windows drives under WSL), those whose path /proc writes
    /// without an escape.
    static func ninePMounts() -> [String] {
        let mounts = (try? String(contentsOfFile: "/proc/self/mounts", encoding: .utf8)) ?? ""
        return mounts.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= 3, fields[2] == "9p", !fields[1].contains("\\") else { return nil }
            return String(fields[1])
        }
    }

    /// inotify takes a watch on a 9p folder and then tells only of what this system's own processes change in it:
    /// such a folder is refused, which callers read as "can't be watched". Nothing is written there. On a machine
    /// without 9p there is nothing to ask, and only the number itself is checked.
    @Test func aNinePFolderCantBeWatched() {
        #expect(VIBE_9P_MAGIC == 0x0102_1997)
        for mount in Self.ninePMounts() where access(mount, R_OK | X_OK) == 0 {
            var kind: UInt = 0
            #expect(vibe_filesystem_type(mount, &kind) == 0)
            #expect(kind == UInt(VIBE_9P_MAGIC), "\(mount)")
            #expect(Platform.FolderWatch(path: mount) == nil, "\(mount)")
        }
        var kind: UInt = 0
        #expect(vibe_filesystem_type("/proc", &kind) == 0)
        // PROC_SUPER_MAGIC.
        #expect(kind == 0x9fa0)
    }

    /// This process's open descriptors: all of them, and those that are inotify's.
    static func descriptors() throws -> (all: Int, inotify: Int) {
        let names = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
        let inotify = names.filter { (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\($0)")) == "anon_inode:inotify" }
        return (names.count, inotify.count)
    }

    /// 200 watches made and stopped, each of the ways a watch is used in turn: none leaves a descriptor. Each is
    /// waited for to have closed what it held (`released`) before the next. The inotify descriptors are this
    /// suite's alone and counted exactly; the count of all descriptors is shared with the tests running beside
    /// this one, so it is only held to less than one a cycle of any one way (50 cycles each).
    @Test func twoHundredWatchesLeaveNoDescriptor() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let queue = DispatchQueue(label: "folder-watch-tests.cycles")
        let before = try Self.descriptors()
        for cycle in 0..<200 {
            let watch: Platform.FolderWatch
            switch cycle % 4 {
            case 0:
                // Made and stopped, never read.
                watch = try #require(Platform.FolderWatch(path: folders.watched.path))
            case 1:
                // A change read, then stopped.
                watch = try #require(Platform.FolderWatch(path: folders.watched.path))
                try Self.make(folders.watched.appendingPathComponent("cycle-\(cycle)"))
                #expect(Self.next(watch) == .entries)
            case 2:
                // Stopped under a wait.
                watch = try #require(Platform.FolderWatch(path: folders.watched.path))
                let answered = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    _ = watch.wait()
                    answered.signal()
                }
                #expect(Self.eventually { watch.system.isWaitedOn })
                watch.stop()
                #expect(answered.wait(timeout: .now() + Self.hangGuard) == .success)
            default:
                // A descriptor handed over, read on a queue.
                let descriptor = open(folders.watched.path, O_RDONLY)
                try #require(descriptor >= 0)
                watch = try #require(Platform.FolderWatch(descriptor: descriptor))
                watch.deliver(on: queue) { _ in }
            }
            watch.stop()
            try #require(watch.system.released.wait(timeout: .now() + Self.hangGuard) == .success, "cycle \(cycle) still holds a descriptor")
        }
        // A watch that can't be made holds nothing either.
        for _ in 0..<50 { #expect(Platform.FolderWatch(path: folders.root.appendingPathComponent("never-made").path) == nil) }
        let after = try Self.descriptors()
        #expect(after.inotify <= before.inotify, "\(after.inotify - before.inotify) inotify descriptors left open")
        #expect(after.all - before.all < 50, "\(after.all - before.all) descriptors more than before")
    }
    #endif
}
