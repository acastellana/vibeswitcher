import Foundation

extension Platform {
    /// Standard error and standard output, written with the raw `write(2)` and every failure ignored but said in the
    /// result. `Platform.Stdio.error(_:)` traps when the write fails (on Linux a SIGILL from its `try!`,
    /// on the Mac an Objective-C exception): a log line on a full disk (stderr on /dev/full, or a log file on a full
    /// volume) would end the server, then the host, then every session. A log line lost is better than the process.
    /// `StdioWriteLintTests` keeps `FileHandle.standardError`/`standardOutput` writes out of the node's targets.
    public enum Stdio {
        /// Writes `text` to standard error (fd 2). Whether every byte went out.
        @discardableResult public static func error(_ text: String) -> Bool { write(2, Data(text.utf8)) }

        /// Writes `data` to standard error (fd 2). Whether every byte went out.
        @discardableResult public static func error(_ data: Data) -> Bool { write(2, data) }

        /// Writes `text` to standard output (fd 1). Whether every byte went out.
        @discardableResult public static func output(_ text: String) -> Bool { write(1, Data(text.utf8)) }

        /// Writes `data` to standard output (fd 1). Whether every byte went out.
        @discardableResult public static func output(_ data: Data) -> Bool { write(1, data) }

        /// Writes all of `data` to `fd`, again after a short write or an interrupted one; any other failure (a full disk,
        /// a closed pipe, a descriptor that would block) ends the write and says false. Never traps.
        @discardableResult public static func write(_ fd: Int32, _ data: Data) -> Bool {
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
                guard let base = buffer.baseAddress else { return true }
                var offset = 0
                while offset < buffer.count {
                    let wrote = Sys.write(fd, base + offset, buffer.count - offset)
                    if wrote > 0 {
                        offset += wrote
                    } else if wrote < 0, errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
        }

        /// How big a log that standard error or a detached start appends to may grow before it is rotated: one older
        /// file (`.1`) is kept beside it, as `HostLog` keeps its own.
        public static let logLimit = 2_000_000

        /// At a start: `path` moved to `path.1` (replacing an older one) when it is a regular file of more than `limit`
        /// bytes, so what is opened next starts a new file. Whether it was moved.
        @discardableResult public static func rotate(path: String, limit: Int = logLimit) -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) > limit else { return false }
            return rename(path, path + ".1") == 0
        }

        /// While running: when standard error (fd 2) is a regular file opened to append, grown past `limit` (a detached
        /// host's `<root>/v2/host.log`, which its server child shares, both writing at its end), what it holds is
        /// copied to `<its path>.1` (replacing an older one) and the file emptied in place, so every process holding
        /// it writes from the start again. A line written between the copy and the emptying is lost. Nothing for a
        /// terminal, a pipe or the journal's socket, nor for a file not opened to append (emptied, its writer would
        /// go on at its old offset). Whether it was emptied.
        /// `fd`: another descriptor treated the same way (a test's).
        @discardableResult public static func capError(_ fd: Int32 = 2, limit: Int = logLimit) -> Bool {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) > limit else { return false }
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, flags & O_APPEND != 0 else { return false }
            if let path = path(of: fd) { copy(from: path, to: path + ".1") }
            return ftruncate(fd, 0) == 0
        }

        /// The path `fd` was opened by, while it still names it: Linux's /proc/self/fd/N, the Mac's F_GETPATH.
        private static func path(of fd: Int32) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            #if canImport(Darwin)
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
            let path = String(cString: buffer)
            #else
            let length = readlink("/proc/self/fd/\(fd)", &buffer, buffer.count - 1)
            guard length > 0 else { return nil }
            let path = String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            #endif
            // Removed or renamed away since: no `.1` beside a name it no longer has.
            var named = stat(), held = stat()
            guard path.hasPrefix("/"), stat(path, &named) == 0, fstat(fd, &held) == 0, named.st_dev == held.st_dev, named.st_ino == held.st_ino else { return nil }
            return path
        }

        /// `from`'s bytes into a new file (0600, not through a link) moved over `to`. Nothing when either step fails.
        private static func copy(from: String, to: String) {
            let source = open(from, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard source >= 0 else { return }
            defer { Sys.close(source) }
            let temporary = to + ".\(getpid()).tmp"
            unlink(temporary)
            let target = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard target >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var ok = true
            while true {
                let got = buffer.withUnsafeMutableBytes { Sys.read(source, $0.baseAddress, $0.count) }
                if got < 0, errno == EINTR { continue }
                if got <= 0 { ok = got == 0; break }
                guard write(target, Data(buffer[..<got])) else { ok = false; break }
            }
            Sys.close(target)
            if !ok || rename(temporary, to) != 0 { unlink(temporary) }
        }
    }
}
