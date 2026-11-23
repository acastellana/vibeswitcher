#if os(Linux)
import Foundation

// Linux's folder watch: a client of the process's one inotify instance (`InotifyHub`, Watches+Linux.swift), which
// reads the kernel's events on a thread of its own and tells each watch those its mask asks for. Events queued close
// together are one `Change`: a watch takes every event told to it, the kernel's queue read first, when it answers.
extension Platform.FolderWatch {
    final class System: @unchecked Sendable {
        /// An entry made, removed, renamed out or renamed in. Not IN_MODIFY: a write inside a file that is there
        /// isn't a change of the folder (the Mac's NOTE_WRITE on a folder doesn't fire for it, and callers count on
        /// that).
        static let entryEvents = UInt32(IN_CREATE) | UInt32(IN_DELETE) | UInt32(IN_MOVED_FROM) | UInt32(IN_MOVED_TO)
        /// The folder itself removed or renamed, or its file system unmounted.
        static let folderEvents = UInt32(IN_DELETE_SELF) | UInt32(IN_MOVE_SELF) | UInt32(IN_UNMOUNT)

        /// The watch's share of the instance. Not private: the tests ask it what it holds.
        let client: InotifyClient

        convenience init?(path: String) {
            self.init(watching: path)
        }

        /// The folder is watched by the name /proc gives the descriptor, and the descriptor closed: while one is
        /// open on a folder the kernel doesn't say the folder was removed (IN_DELETE_SELF comes when the last
        /// reference to it goes), and the watch itself needs none.
        convenience init?(descriptor: Int32) {
            defer { if descriptor >= 0 { close(descriptor) } }
            let proc = "/proc/self/fd/\(descriptor)"
            self.init(watching: proc, named: try? FileManager.default.destinationOfSymbolicLink(atPath: proc))
        }

        /// `named`: the folder's own path, which the hub adds again after an overflow (a descriptor's /proc name won't
        /// name it then).
        private init?(watching path: String, named: String? = nil) {
            // 9p (a Windows drive under WSL): the kernel takes the watch and tells only of what this system's own
            // processes change there, never of what the other side does. Refused rather than half heard.
            var kind: UInt = 0
            guard vibe_filesystem_type(path, &kind) == 0, kind != UInt(VIBE_9P_MAGIC) else { return nil }
            // IN_ONLYDIR: a file's watch would never tell of anything asked for here.
            guard let client = InotifyHub.shared.watch(path, mask: Self.entryEvents | Self.folderEvents, folder: true, named: named) else { return nil }
            self.client = client
        }

        /// Whether a thread is inside `wait()` now. For the tests.
        var isWaitedOn: Bool { client.isWaitedOn }

        func wait() -> Change? {
            while let events = client.wait() {
                let change = Self.change(events)
                if !change.isEmpty { return change }
            }
            return nil
        }

        func deliver(on queue: DispatchQueue, _ handler: @escaping @Sendable (Change) -> Void) {
            client.deliver(on: queue) { events in
                let change = Self.change(events)
                if !change.isEmpty { handler(change) }
            }
        }

        func stop() {
            client.stop()
        }

        /// What a read's events say. The kernel dropping events (its queue was full: IN_Q_OVERFLOW) is a change of
        /// the entries, which the caller then reads for itself; the kernel ending the watch (IN_IGNORED: the folder
        /// gone) is the folder gone, as nothing more will be told.
        static func change(_ mask: UInt32) -> Change {
            var change: Change = []
            if mask & (entryEvents | UInt32(IN_Q_OVERFLOW)) != 0 { change.insert(.entries) }
            if mask & (folderEvents | UInt32(IN_IGNORED)) != 0 { change.insert(.folderGone) }
            return change
        }
    }
}
#endif
