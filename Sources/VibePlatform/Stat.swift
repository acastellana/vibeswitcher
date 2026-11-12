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

    /// When the file was last read (as the volume keeps it: Linux's `relatime` moves it at most once a day).
    public static func accessed(_ info: stat) -> timespec {
        #if canImport(Darwin)
        return info.st_atimespec
        #else
        return info.st_atim
        #endif
    }

    /// The file's number on its volume.
    public static func inode(_ info: stat) -> UInt64 { UInt64(info.st_ino) }

    /// The file's length in bytes.
    public static func byteSize(_ info: stat) -> Int64 { Int64(info.st_size) }

    /// The bytes the file at `url` takes on its volume (a link's own, not followed); nil for a folder or when it can't
    /// be read. On the Mac it is Foundation's `totalFileAllocatedSize`, else `fileAllocatedSize` (a file's keys, which
    /// a folder hasn't). Linux's Foundation gives those as `st_blocks` × `st_blksize`, but `st_blocks` counts 512-byte
    /// units whatever the block size: 8 times the truth on ext4. So Linux's is `st_blocks` × 512, as `du` counts it.
    public static func allocatedSize(of url: URL) -> Int? {
        #if canImport(Darwin)
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return values?.totalFileAllocatedSize ?? values?.fileAllocatedSize
        #else
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR else { return nil }
        return Int(info.st_blocks) * 512
        #endif
    }

    /// Whether two changes to a file close together can leave its ctime (`changed`) the same. Linux stamps it from the
    /// kernel's tick (its coarse clock: 1 to 10 ms, 10 ms on WSL2's kernel), so a file patched in the tick of its last
    /// change, its mtime set back, reads unchanged by size, times and inode; the Mac's APFS stamps it to the nanosecond.
    public static var changeTimeIsCoarse: Bool {
        #if canImport(Darwin)
        return false
        #else
        return true
        #endif
    }

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
