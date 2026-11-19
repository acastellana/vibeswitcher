import Foundation

extension Platform.Files {
    /// What `readRegular(in:path:limit:)` found.
    public enum Under: Equatable, Sendable {
        /// Nothing there (no such file, or a folder on the way missing).
        case absent
        /// The file's bytes, at most the limit.
        case data(Data)
        /// Something there that isn't read, and why: a link on the way or at the end, not a regular file, over the
        /// limit, or a read that failed.
        case refused(String)
    }

    /// The regular file at `path` (relative names, `components`) under the folder `root`, read without following a
    /// link anywhere below `root`: each folder opened with `openat(O_DIRECTORY | O_NOFOLLOW)` from the one before, the
    /// file with `O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` (a FIFO or a device opens without waiting, and is then
    /// refused), `fstat` on that descriptor (a regular file, at most `limit` bytes), and its bytes read from it, at
    /// most `limit + 1`. One open, so nothing can be swapped in between a check and the read. `root` itself is the
    /// caller's own folder and may be reached through links. A component that is empty, `.`, `..` or holds a `/` is
    /// refused.
    public static func readRegular(in root: String, path components: [String], limit: Int) -> Under {
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else {
            return .refused("not a plain relative path")
        }
        var folder = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { return errno == ENOENT || errno == ENOTDIR ? .absent : .refused("its folder can't be opened") }
        defer { Sys.close(folder) }
        for name in components.dropLast() {
            let next = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let code = errno
                if code == ENOENT { return .absent }
                return .refused(code == ELOOP || code == ENOTDIR ? "\(name) isn't a folder (a link, or a file)" : "\(name) can't be opened")
            }
            Sys.close(folder)
            folder = next
        }
        let name = components[components.count - 1]
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return .absent }
            return .refused(code == ELOOP ? "\(name) is a link" : "\(name) can't be opened")
        }
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .refused("\(name) can't be read") }
        guard info.st_mode & S_IFMT == S_IFREG else { return .refused("\(name) isn't a regular file") }
        guard Int64(info.st_size) <= Int64(limit) else { return .refused("\(name) is \(Int64(info.st_size) >> 20) MB, more than the \(limit >> 20) MB read") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes { Sys.read(fd, $0.baseAddress, min($0.count, limit + 1 - data.count)) }
            if count < 0 {
                if errno == EINTR { continue }
                return .refused("\(name) can't be read")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard data.count <= limit else { return .refused("\(name) is more than the \(limit >> 20) MB read") }
        return .data(data)
    }
}
