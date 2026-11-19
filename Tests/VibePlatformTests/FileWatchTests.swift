import Foundation
import Testing
@testable import VibePlatform

/// `Platform.FileWatch`: a file's watch tells of a write inside the file (which a folder's watch never does) and of the
/// file removed or renamed, on the queue it was given. Each test has a folder of its own in the run's scratch folder.
/// Each wait is on the change itself, with the hang guard: past it the test fails.
@Suite(.serialized)
struct FileWatchTests {
    typealias Change = Platform.FileWatch.Change

    static let hangGuard = TestScriptLinuxTests.hangGuard

    /// The changes a watch delivers, in order, each signalling `heard`.
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [Change] = []
        let signal = DispatchSemaphore(value: 0)

        func add(_ change: Change) {
            lock.withLock { held.append(change) }
            signal.signal()
        }

        var changes: [Change] { lock.withLock { held } }

        /// Waits for a change that contains `wanted`; false when none came within the hang guard.
        func wait(for wanted: Change) -> Bool {
            let deadline = Date().addingTimeInterval(FileWatchTests.hangGuard)
            while !changes.contains(where: { $0.contains(wanted) }) {
                guard signal.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else { return false }
            }
            return true
        }
    }

    static func file() throws -> (root: URL, file: URL) {
        let root = try TestScriptLinuxTests.scratch("file-watch")
        let file = root.appendingPathComponent("transcript.jsonl")
        try Data("first\n".utf8).write(to: file)
        return (root, file)
    }

    static func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func anAppendIsAWrite() throws {
        let (root, file) = try Self.file()
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = try #require(Platform.FileWatch(path: file.path))
        defer { watch.stop() }
        let heard = Heard()
        let queue = DispatchQueue(label: "file-watch-tests.append")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let onQueue = Heard()
        watch.deliver(on: queue) { change in
            if DispatchQueue.getSpecific(key: key) == true { onQueue.add(change) }
            heard.add(change)
        }
        try Self.append("second\n", to: file)
        #expect(heard.wait(for: .written), "an append was never told")
        #expect(onQueue.changes.count == heard.changes.count, "every change on the queue it was given")
        #expect(!heard.changes.contains { $0.contains(.gone) })
    }

    @Test func aRemovalAndARenameAreGone() throws {
        let (root, file) = try Self.file()
        defer { try? FileManager.default.removeItem(at: root) }
        for removing in [true, false] {
            try Data("again\n".utf8).write(to: file)
            let watch = try #require(Platform.FileWatch(path: file.path))
            let heard = Heard()
            watch.deliver(on: DispatchQueue(label: "file-watch-tests.gone")) { heard.add($0) }
            if removing {
                try FileManager.default.removeItem(at: file)
            } else {
                try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("moved.jsonl"))
            }
            #expect(heard.wait(for: .gone), removing ? "a removal was never told" : "a rename was never told")
            watch.stop()
        }
    }

    @Test func aFolderOrNothingCantBeWatched() throws {
        let (root, file) = try Self.file()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Platform.FileWatch(path: root.path) == nil, "a folder")
        #expect(Platform.FileWatch(path: file.path + ".missing") == nil, "nothing there")
    }

    /// Stopped, it tells nothing more, and stopping again does nothing.
    @Test func aStoppedWatchTellsNothing() throws {
        let (root, file) = try Self.file()
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = try #require(Platform.FileWatch(path: file.path))
        let heard = Heard()
        let queue = DispatchQueue(label: "file-watch-tests.stopped")
        watch.deliver(on: queue) { heard.add($0) }
        watch.stop()
        watch.stop()
        try Self.append("unheard\n", to: file)
        // A second watch on the same file hears the next write: by then the first, stopped, would have heard both.
        let other = try #require(Platform.FileWatch(path: file.path))
        defer { other.stop() }
        let witness = Heard()
        other.deliver(on: queue) { witness.add($0) }
        try Self.append("heard\n", to: file)
        #expect(witness.wait(for: .written))
        queue.sync {}
        #expect(heard.changes.isEmpty, "\(heard.changes)")
    }
}
