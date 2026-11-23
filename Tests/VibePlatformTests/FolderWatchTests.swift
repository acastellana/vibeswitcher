import Foundation
import Testing
@testable import VibePlatform

/// `Platform.FolderWatch`: what a folder's watch tells of and what it doesn't, read by `wait()` and by `deliver`.
/// Each test has a folder of its own in the run's scratch folder, with the watched folder and one beside it inside.
/// A wait that should return is given the hang guard: past it the watch is stopped, the wait answers nil and the
/// test fails.
///
/// One at a time.
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
        // Stopped, so nothing more can come: the file made now, read by the instance, is told to nobody.
        #expect(watch.system.client.isStopped)
        try Self.make(folders.watched.appendingPathComponent("second"))
        InotifyHub.shared.flush()
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

    /// What of this process's descriptors is one test's own: inotify ones watching `folder` (an inotify descriptor's
    /// /proc/self/fdinfo lists each of its watches by the watched inode and device, so another test's watch of a
    /// folder of its own never counts), ones open on `folder` itself, and ones on a pipe whose inode is in `pipes`.
    /// A descriptor closed between the listing and its reading isn't counted.
    static func owned(watching folder: URL, pipes: Set<UInt64> = []) throws -> (inotify: Int, folder: Int, pipes: Int) {
        var status = stat()
        guard stat(folder.path, &status) == 0 else { throw Failure(what: "\(folder.path): errno \(errno)") }
        // fdinfo gives the device as the kernel keeps it (major << 20 | minor), stat as glibc encodes it.
        let device = UInt64(status.st_dev)
        let major = ((device >> 8) & 0xfff) | ((device >> 32) & ~UInt64(0xfff))
        let minor = (device & 0xff) | ((device >> 12) & ~UInt64(0xff))
        let watch = "ino:\(String(UInt64(status.st_ino), radix: 16)) sdev:\(String(major << 20 | minor, radix: 16)) "
        let real = ProcessesTests.real(folder.path)
        var counts = (inotify: 0, folder: 0, pipes: 0)
        for name in try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(name)") else { continue }
            if target == "anon_inode:inotify" {
                let info = (try? String(contentsOfFile: "/proc/self/fdinfo/\(name)", encoding: .utf8)) ?? ""
                if info.split(separator: "\n").contains(where: { $0.hasPrefix("inotify wd:") && $0.contains(watch) }) { counts.inotify += 1 }
            } else if target == real {
                counts.folder += 1
            } else if target.hasPrefix("pipe:["), let inode = UInt64(target.dropFirst(6).dropLast()), pipes.contains(inode) {
                counts.pipes += 1
            }
        }
        return counts
    }

    /// 200 watches made and stopped, each of the ways a watch is used in turn: none leaves a kernel watch, and none
    /// holds a descriptor of its own (they share the process's one inotify instance). Only what is this test's own is
    /// counted (`owned`): the inotify descriptors with a watch on its folder, and descriptors on the folder. A live watch
    /// of two of the ways checks the count sees what a watch holds: the instance, once, whatever else it watches.
    @Test func twoHundredWatchesLeaveNoWatchAndHoldNoDescriptor() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let queue = DispatchQueue(label: "folder-watch-tests.cycles")
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
            if cycle == 0 || cycle == 3 {
                // Live: one inotify descriptor watches the folder (the process's instance); the handed descriptor is
                // closed by the watch as it is made. (Only twice: each count lists /proc/self/fd, a descriptor
                // ProcessesTests' own-list check sees when it reads at that moment.)
                let live = try Self.owned(watching: folders.watched)
                #expect(live.inotify == 1 && live.folder == 0, "cycle \(cycle): \(live)")
            }
            watch.stop()
            // The last watch of the folder gone: its kernel watch removed with it.
            try #require(try Self.owned(watching: folders.watched).inotify == 0, "cycle \(cycle) left its kernel watch")
        }
        // A watch that can't be made holds nothing either.
        for _ in 0..<50 { #expect(Platform.FolderWatch(path: folders.root.appendingPathComponent("never-made").path) == nil) }
        let after = try Self.owned(watching: folders.watched)
        #expect(after.inotify == 0 && after.folder == 0, "\(after)")
    }

    /// Several hundred watches, of folders and of files, in this process: one inotify instance holds them all.
    @Test func severalHundredWatchesUseOneInstance() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        var watches: [AnyObject] = []
        defer {
            for watch in watches {
                (watch as? Platform.FolderWatch)?.stop()
                (watch as? Platform.FileWatch)?.stop()
            }
        }
        for index in 0..<300 {
            let folder = folders.watched.appendingPathComponent("f\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let file = folder.appendingPathComponent("file")
            try Self.make(file)
            watches.append(try #require(Platform.FolderWatch(path: folder.path), "watch \(index)"))
            watches.append(try #require(Platform.FileWatch(path: file.path), "file watch \(index)"))
        }
        // Two watches of one folder share its kernel watch.
        watches.append(try #require(Platform.FolderWatch(path: folders.watched.appendingPathComponent("f0").path)))
        let descriptors = try Self.descriptors()
        #expect(descriptors.inotify == 1, "\(descriptors.inotify) inotify instances for \(watches.count) watches")
        let census = InotifyHub.shared.census
        #expect(census.watches >= 600 && census.clients >= 601, "\(census)")
        // And each is heard.
        try Self.make(folders.watched.appendingPathComponent("f299/new"))
        let last = try #require(watches[598] as? Platform.FolderWatch)
        #expect(Self.next(last) == .entries)
    }

    /// Two clients of one folder's kernel watch, asking for different events: each is told only its own; one stopped,
    /// the other still hears (the kernel watch goes with the last).
    @Test func twoClientsOfOnePathEachGetOnlyTheirs() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let hub = InotifyHub.shared
        let made = try #require(hub.watch(folders.watched.path, mask: UInt32(IN_CREATE), folder: true))
        let removed = try #require(hub.watch(folders.watched.path, mask: UInt32(IN_DELETE), folder: true))
        defer {
            made.stop()
            removed.stop()
        }
        #expect(made.wd == removed.wd, "one kernel watch for the folder")
        let (madeTold, removedTold) = (Box<[UInt32]>([]), Box<[UInt32]>([]))
        let (madeQueue, removedQueue) = (DispatchQueue(label: "fw.made"), DispatchQueue(label: "fw.removed"))
        let heard = DispatchSemaphore(value: 0)
        made.deliver(on: madeQueue) { madeTold.value.append($0); heard.signal() }
        removed.deliver(on: removedQueue) { removedTold.value.append($0); heard.signal() }
        let file = folders.watched.appendingPathComponent("file")
        try Self.make(file)
        #expect(heard.wait(timeout: .now() + Self.hangGuard) == .success)
        hub.flush()
        madeQueue.sync {}
        removedQueue.sync {}
        #expect(madeTold.value.count == 1 && madeTold.value[0] & UInt32(IN_CREATE) != 0, "\(madeTold.value)")
        #expect(removedTold.value.isEmpty, "the delete client was told of a creation: \(removedTold.value)")
        #expect(unlink(file.path) == 0)
        #expect(heard.wait(timeout: .now() + Self.hangGuard) == .success)
        hub.flush()
        madeQueue.sync {}
        removedQueue.sync {}
        #expect(removedTold.value.count == 1 && removedTold.value[0] & UInt32(IN_DELETE) != 0, "\(removedTold.value)")
        #expect(madeTold.value.count == 1, "the create client was told of a removal: \(madeTold.value)")
        // The first stopped: the kernel watch stays for the other, which still hears.
        made.stop()
        #expect(try Self.owned(watching: folders.watched).inotify == 1)
        try Self.make(file)
        #expect(unlink(file.path) == 0)
        #expect(heard.wait(timeout: .now() + Self.hangGuard) == .success)
        removed.stop()
        #expect(try Self.owned(watching: folders.watched).inotify == 0, "the last client gone, its kernel watch stays")
    }

    /// A watch the system couldn't give is counted, and the first such told once, through the process's own line.
    @Test func aWatchThatCouldntBeMadeIsCountedAndToldOnce() {
        let told = Box<[String]>([])
        let was = Platform.Watches.whenFirstUnmade
        Platform.Watches.whenFirstUnmade = { line in told.value.append(line) }
        defer { Platform.Watches.whenFirstUnmade = was }
        let before = Platform.Watches.unmade
        Platform.Watches.noteUnmade("/a", "no inotify instance (errno 24)")
        Platform.Watches.noteUnmade("/b", "no inotify instance (errno 24)")
        #expect(Platform.Watches.unmade == before + 2)
        // Told at the process's first only.
        #expect(told.value.count == (before == 0 ? 1 : 0), "\(told.value)")
        #expect(told.value.allSatisfy { $0.contains("/a") && $0.contains("next housekeeping") })
    }

    /// The kernel's queue for the instance overflowing (its reads held while more events come than it keeps): every
    /// watch is told to look again, one of a folder where nothing happened included.
    @Test func anOverflowIsToldToEveryWatch() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let busy = try #require(Platform.FolderWatch(path: folders.watched.path))
        let quiet = try #require(Platform.FolderWatch(path: folders.outside.path))
        defer {
            busy.stop()
            quiet.stop()
        }
        let queued = Int((try? String(contentsOfFile: "/proc/sys/fs/inotify/max_queued_events", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 16_384
        try InotifyHub.shared.holdingReads {
            // A creation and a removal each: two events a turn, past what the kernel keeps.
            let file = folders.watched.appendingPathComponent("churn")
            for _ in 0..<(queued / 2 + 64) {
                try Self.make(file)
                guard unlink(file.path) == 0 else { throw Failure(what: "errno \(errno)") }
            }
        }
        #expect(Self.next(quiet) == .entries, "the quiet folder's watch wasn't told of the overflow")
        #expect(Self.next(busy) == .entries)
    }

    /// A watch stopped while its events are on their way (read and waiting on its queue behind a block, or still in the
    /// kernel's queue): its handler is never called.
    @Test func aWatchStoppedWithEventsInFlightIsToldNothing() throws {
        let folders = try Self.folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let calls = Box(0)
        let queue = DispatchQueue(label: "folder-watch-tests.in-flight")
        // Told, and its block behind one that waits.
        let first = try #require(Platform.FolderWatch(path: folders.watched.path))
        first.deliver(on: queue) { _ in calls.value += 1 }
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        try Self.make(folders.watched.appendingPathComponent("one"))
        InotifyHub.shared.flush()
        first.stop()
        release.signal()
        queue.sync {}
        // Still in the kernel's queue when it stops.
        let second = try #require(Platform.FolderWatch(path: folders.watched.path))
        second.deliver(on: queue) { _ in calls.value += 1 }
        try InotifyHub.shared.holdingReads {
            try Self.make(folders.watched.appendingPathComponent("two"))
            second.stop()
        }
        InotifyHub.shared.flush()
        queue.sync {}
        #expect(calls.value == 0)
        // A watch made after both still hears.
        let third = try #require(Platform.FolderWatch(path: folders.watched.path))
        defer { third.stop() }
        try Self.make(folders.watched.appendingPathComponent("three"))
        #expect(Self.next(third) == .entries)
    }
    #endif
}
