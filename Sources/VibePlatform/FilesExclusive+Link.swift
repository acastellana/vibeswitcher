// The locked create both systems use. Only POSIX calls (open, flock, link, unlink): no `#if`.
extension Platform.Files {
    /// `createLocked(_:mode:)`, on both systems: the file is made under a name of its own in the
    /// same folder (`.making-<pid>-<random>`: no reader of a folder's files looks for a name that starts with a dot),
    /// flocked, linked to `path`, which fails with `EEXIST` when that name is taken, and its first name removed. The
    /// lock is the open file's, whatever its names: whoever opens `path` finds it held.
    ///
    /// Made and flocked in two steps under the wanted name, the file could be opened and flocked between them by a
    /// reader that takes a file it can lock for one nobody holds, and removes it (`TestLock.waiters`). On the Mac,
    /// open(2)'s `O_EXLOCK` was used until 2026-11-12, and it has that gap too: on GitHub's Mac runner a reader
    /// locked 13 of 200 files while their maker held them (`createLockedIsNeverSeenUnlocked`), and
    /// `TestLock.waiters` runs without the queue's lock.
    ///
    /// A process killed between the making and the unlink leaves the first name behind, empty. A file system with
    /// no links fails here with link's error (`EPERM`).
    static func createLockedByLink(_ path: String, mode: mode_t) -> Int32 {
        // The folder's path with its slash; none: the working directory.
        let folder = path.utf8.lastIndex(of: UInt8(ascii: "/")).map { String(path[...$0]) } ?? ""
        while true {
            let temporary = "\(folder).making-\(getpid())-\(String(UInt64.random(in: 0 ... UInt64.max), radix: 16))"
            let fd = open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode)
            guard fd >= 0 else {
                // A name another maker took: another name, never its file.
                if errno == EEXIST { continue }
                return -1
            }
            var failure: Int32 = 0
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                failure = errno
            } else if link(temporary, path) != 0 {
                failure = errno
            }
            unlink(temporary)
            guard failure == 0 else {
                close(fd)
                errno = failure
                return -1
            }
            return fd
        }
    }
}
