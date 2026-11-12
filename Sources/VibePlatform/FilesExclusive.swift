/// A name taken only when no one has it: a rename that never replaces, and a file that is locked from its making.
/// And the two names that go with them: how a folder is opened only to be watched, and the temporary folder every
/// process of the machine shares.
extension Platform.Files {
    /// Renames `from` to `to`, both names in the folder open as `directory` (or paths, with `AT_FDCWD`), only when
    /// nothing has the name `to`: 0, or -1 with `errno`, `EEXIST` when something has it. Never over another file.
    ///
    /// The Mac's `renameatx_np(RENAME_EXCL)`; Linux's `renameat2(RENAME_NOREPLACE)`, and on a file system that has no
    /// such rename (FilesExclusive+Linux.swift) a link and an unlink for a file, the file system's refusal for a
    /// folder.
    public static func renameExclusive(in directory: Int32, from: String, to: String) -> Int32 {
        #if canImport(Darwin)
        return renameatx_np(directory, from, directory, to, UInt32(RENAME_EXCL))
        #else
        return renameExclusive(in: directory, from: from, to: to) { directory, from, to in
            vibe_renameat2(directory, from, directory, to, UInt32(VIBE_RENAME_NOREPLACE))
        }
        #endif
    }

    /// Makes the file at `path` and holds it flocked (`LOCK_EX`) from its making: no other process ever opens it by
    /// that name and finds it unlocked while this one holds the descriptor returned, open for writing and closed in
    /// a program this process starts. -1 with `errno` when it can't be made, `EEXIST` when the name is taken (by a
    /// link too, wherever it leads). The lock goes when the descriptor is closed, or with this process.
    ///
    /// The Mac's open(2) makes and locks in one call (`O_EXLOCK`). Linux has none: the file is made under another
    /// name, locked, and only then given this one (FilesExclusive+Linux.swift).
    public static func createLocked(_ path: String, mode: mode_t) -> Int32 {
        createLockedByLink(path, mode: mode)
    }

    /// open(2)'s access mode for a folder opened only to be watched, or to open what is in it: the Mac's
    /// `O_EVTONLY`, which doesn't keep its volume from being unmounted; Linux has no such mode, and reads.
    public static var eventsOnly: Int32 {
        #if canImport(Darwin)
        O_EVTONLY
        #else
        O_RDONLY
        #endif
    }

    /// The temporary folder that is the same for every process of the machine, whatever its `TMPDIR`: where what
    /// they share is kept (the heavy slots' lock), by its real path. On the Mac `/tmp` is a link to it.
    public static var sharedTemporaryRoot: String {
        #if canImport(Darwin)
        "/private/tmp"
        #else
        "/tmp"
        #endif
    }
}
