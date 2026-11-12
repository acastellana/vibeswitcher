#if os(Linux)
// Linux's exclusive rename and locked create, and what each does where the kernel's own call isn't to be had. Only
// libc and the shim, on glibc and on musl.
extension Platform.Files {
    /// `renameExclusive(in:from:to:)` with the kernel's call as `exclusive` (renameat2 with `RENAME_NOREPLACE`; a
    /// test's own, to play a file system that has none). A file system refuses the flag with `EINVAL` (9p, as
    /// Windows' drives are under WSL; older FUSE and network ones), and a kernel or a sandbox without the call says
    /// `ENOSYS`: then `renameExclusiveByLink`. Any other answer is the call's own.
    static func renameExclusive(in directory: Int32, from: String, to: String,
                                exclusive: (_ directory: Int32, _ from: String, _ to: String) -> Int32) -> Int32 {
        let renamed = exclusive(directory, from, to)
        let refusal = errno
        guard renamed != 0, refusal == EINVAL || refusal == ENOSYS else { return renamed }
        return renameExclusiveByLink(in: directory, from: from, to: to, refusal: refusal)
    }

    /// The exclusive rename of a file without the kernel's call: `to` is made a second name of the file, which fails
    /// with `EEXIST` when something has that name, and then the first name is removed. Between the two the file has
    /// both names; should the first not go (`from` gone already is no failure), the second is taken back and the
    /// rename fails with that error.
    ///
    /// A folder can't have two names: for one, -1 with `refusal`, the error that sent the rename here. And a file
    /// system with no links at all (FAT) fails here with link's error (`EPERM`), as does a file of another user's
    /// that this one couldn't write.
    static func renameExclusiveByLink(in directory: Int32, from: String, to: String, refusal: Int32 = EINVAL) -> Int32 {
        var info = stat()
        guard fstatat(directory, from, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return -1 }
        guard info.st_mode & S_IFMT != S_IFDIR else {
            errno = refusal
            return -1
        }
        guard linkat(directory, from, directory, to, 0) == 0 else { return -1 }
        if unlinkat(directory, from, 0) == 0 || errno == ENOENT { return 0 }
        let failure = errno
        unlinkat(directory, to, 0)
        errno = failure
        return -1
    }

    /// `createLocked(_:mode:)` where open(2) can't lock as it makes: the file is made under a name of its own in the
    /// same folder (`.making-<pid>-<random>`: no reader of a folder's files looks for a name that starts with a dot),
    /// flocked, linked to `path`, which fails with `EEXIST` when that name is taken, and its first name removed. The
    /// lock is the open file's, whatever its names: whoever opens `path` finds it held.
    ///
    /// Made and flocked in two steps under the wanted name, the file could be opened and flocked between them by a
    /// reader that takes a file it can lock for one nobody holds, and removes it (`TestLock.waiters`).
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
#endif
