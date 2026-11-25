import Foundation

extension Platform.Files {
    /// Why a root-owned record couldn't be taken: said in one plain line, naming the path and what is wrong with it.
    public struct RootRecordRefusal: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// The bytes of a record only root can write, or why it isn't one (the node on the Mac's design, "The anchor"): the
    /// file `components.last` in the folders `components.dropLast()` below `base` (`/` in the node; a test's scratch
    /// folder, which is then the walk's top). Walked, never resolved: `base` is opened, then each component with
    /// `openat(…, O_NOFOLLOW)` from the folder already held, so a link anywhere on the way is refused, not followed, and
    /// each step is checked by `fstat` on the descriptor it opened and the record read from the one it checked. Every
    /// folder (from `base` down) and the file must be owned by root (uid 0, as `owner` reports a uid: the file's own by
    /// default, a test's fact otherwise), writable by neither its group nor others, and carry no extended ACL
    /// (`hasExtendedACL`; unreadable is a refusal); the file a regular one with one link and at most `maxBytes` bytes.
    /// Anything unusual about a component's name (empty, `.`, `..`, a `/` or a NUL) is refused too.
    public static func readRootRecord(_ components: [String], base: String = "/", maxBytes: Int,
                                      owner: (String, uid_t) -> uid_t = { $1 }) -> Result<Data, RootRecordRefusal> {
        let path = components.reduce(base == "/" ? "" : base) { $0 + "/" + $1 }
        guard base.hasPrefix("/"), !components.isEmpty, maxBytes > 0,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }) else {
            return .failure(RootRecordRefusal("\(path): not a record's path"))
        }
        var held = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard held >= 0 else { return .failure(RootRecordRefusal("\(base): \(opened(errno, folder: true))")) }
        defer { _ = close(held) }
        if let why = rootOnly(held, path: base, folder: true, owner: owner) { return .failure(why) }
        var walked = base == "/" ? "" : base
        for (index, name) in components.enumerated() {
            walked += "/" + name
            let last = index == components.count - 1
            let next = openat(held, name, last ? O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC : O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return .failure(RootRecordRefusal("\(walked): \(opened(errno, folder: !last))")) }
            _ = close(held)
            held = next
            if let why = rootOnly(held, path: walked, folder: !last, owner: owner) { return .failure(why) }
        }
        var info = stat()
        guard fstat(held, &info) == 0 else { return .failure(RootRecordRefusal("\(path): can't be read (\(String(cString: strerror(errno))))")) }
        guard Int(info.st_nlink) == 1 else { return .failure(RootRecordRefusal("\(path): has \(info.st_nlink) links, not one")) }
        guard Int64(info.st_size) <= Int64(maxBytes) else { return .failure(RootRecordRefusal("\(path): larger than \(maxBytes) bytes")) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(held, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .failure(RootRecordRefusal("\(path): can't be read (\(String(cString: strerror(errno))))")) }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maxBytes else { return .failure(RootRecordRefusal("\(path): larger than \(maxBytes) bytes")) }
        }
        return .success(data)
    }

    /// Why `fd` (opened as `path`) isn't root's alone, or nil: a folder (or a regular file when `folder` is false), owned
    /// by root as `owner` reports it, not writable by its group or others, no extended ACL.
    static func rootOnly(_ fd: Int32, path: String, folder: Bool, owner: (String, uid_t) -> uid_t) -> RootRecordRefusal? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return RootRecordRefusal("\(path): can't be read (\(String(cString: strerror(errno))))") }
        let mode = UInt32(info.st_mode)
        let kind = mode & UInt32(S_IFMT)
        if folder, kind != UInt32(S_IFDIR) { return RootRecordRefusal("\(path): not a folder") }
        if !folder, kind != UInt32(S_IFREG) { return RootRecordRefusal("\(path): not a regular file") }
        let uid = owner(path, info.st_uid)
        guard uid == 0 else { return RootRecordRefusal("\(path): owned by uid \(uid), not root") }
        guard mode & UInt32(S_IWGRP | S_IWOTH) == 0 else {
            return RootRecordRefusal("\(path): writable by \(mode & UInt32(S_IWGRP) != 0 ? "its group" : "others") (mode \(String(mode & 0o7777, radix: 8)))")
        }
        switch hasExtendedACL(fd) {
        case false?: return nil
        case true?: return RootRecordRefusal("\(path): carries an access control list")
        case nil: return RootRecordRefusal("\(path): its access control list can't be read")
        }
    }

    static func opened(_ code: Int32, folder: Bool) -> String {
        switch code {
        case ENOENT: return "missing"
        case ELOOP: return "a symbolic link (never followed)"
        case ENOTDIR: return folder ? "not a folder (or a symbolic link, never followed)" : "not a regular file"
        default: return "can't be opened (\(String(cString: strerror(code))))"
        }
    }
}
