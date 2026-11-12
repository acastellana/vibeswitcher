import Foundation

/// What `stat`, `lstat` and `fstat` fill, under the names both systems can share: the Mac calls the two times
/// `st_mtimespec` and `st_ctimespec`, Linux `st_mtim` and `st_ctim`, and the widths of the inode and the size differ
/// between the Mac, glibc and musl.
extension stat {
    /// When the file's contents last changed.
    public var modified: timespec {
        #if canImport(Darwin)
        st_mtimespec
        #else
        st_mtim
        #endif
    }

    /// When the file's inode last changed (its contents, mode, owner, links or name).
    public var changed: timespec {
        #if canImport(Darwin)
        st_ctimespec
        #else
        st_ctim
        #endif
    }

    /// The file's number on its volume.
    public var inode: UInt64 { UInt64(st_ino) }

    /// The file's length in bytes.
    public var byteSize: Int64 { Int64(st_size) }
}

extension Platform {
    /// Files and folders, where the systems differ. Its members are in extensions, here and in other files.
    public enum Files {}
}

extension Platform.Files {
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
