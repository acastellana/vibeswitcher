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
}
#endif
