import Foundation

extension Platform {
    /// Files and folders, where the systems differ. Its members are in extensions, here and in other files.
    public enum Files {}
}

/// What `stat`, `lstat` and `fstat` fill, under the names both systems can share: the Mac calls the two times
/// `st_mtimespec` and `st_ctimespec`, Linux `st_mtim` and `st_ctim`, and the widths of the inode and the size differ
/// between the Mac, glibc and musl.
///
/// Functions that take a `stat`, not members of it: on Linux an extension of a C structure isn't found from another
/// module in every file. The C library's headers are read into each C module that includes them (Glibc's,
/// CoreFoundation's), the compiler takes `stat` from whichever copy it loads first, and it looks for a module's
/// extensions of `stat` under the one copy that module was built with: in a file with a `Date()` outside a function
/// body `stat` is CoreFoundation's, and `info.modified` was "value of type 'stat' has no member 'modified'" (at each
/// of VibeCore's uses, 2026-11-12; `StatTests.loaded` keeps the case). A function's parameter is found by either copy.
extension Platform.Files {
    /// When the file's contents last changed.
    public static func modified(_ info: stat) -> timespec {
        #if canImport(Darwin)
        return info.st_mtimespec
        #else
        return info.st_mtim
        #endif
    }

    /// When the file's inode last changed (its contents, mode, owner, links or name).
    public static func changed(_ info: stat) -> timespec {
        #if canImport(Darwin)
        return info.st_ctimespec
        #else
        return info.st_ctim
        #endif
    }

    /// The file's number on its volume.
    public static func inode(_ info: stat) -> UInt64 { UInt64(info.st_ino) }

    /// The file's length in bytes.
    public static func byteSize(_ info: stat) -> Int64 { Int64(info.st_size) }

    /// When the file at `path` was made (the file a link leads to), in seconds since 1970; nil when it can't be read
    /// or isn't known. The Mac's `stat` has it. On Linux it is asked with `statx`, and a file system that keeps none
    /// (tmpfs, 9p, /proc) reads nil.
    public static func birthTime(_ path: String) -> Double? {
        #if canImport(Darwin)
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let born = Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9
        return born > 0 ? born : nil
        #else
        var birth = timespec()
        guard vibe_birth_time(AT_FDCWD, path, 0, &birth) == 0 else { return nil }
        let born = Double(birth.tv_sec) + Double(birth.tv_nsec) / 1e9
        return born > 0 ? born : nil
        #endif
    }
}
