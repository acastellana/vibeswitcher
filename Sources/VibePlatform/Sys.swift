/// The C library's functions that the shared code calls by a qualified name, as it must where a bare one would be
/// the caller's own (`close(fd)` in a type with a `close()` is that method): the system's module was the qualifier
/// (`Darwin.close(fd)`), and no two systems name theirs alike. Each forwards to the C library's function of its name
/// and returns what that returns; `errno` is as it left it.
public enum Sys {
    public static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { libcRead(fd, buffer, count) }
    public static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { libcWrite(fd, buffer, count) }
    @discardableResult public static func close(_ fd: Int32) -> Int32 { libcClose(fd) }
    public static func pipe(_ fds: UnsafeMutablePointer<Int32>) -> Int32 { libcPipe(fds) }
    @discardableResult public static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 { libcKill(pid, signal) }
    public static func open(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 { libcOpen(path, flags, mode) }
    public static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { libcConnect(fd, address, length) }
    public static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { libcListen(fd, backlog) }
    public static func accept(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 { libcAccept(fd, address, length) }
    public static func truncate(_ path: String, _ length: off_t) -> Int32 { libcTruncate(path, length) }
}

// The C library's own, under names `Sys` doesn't have: inside `Sys` a bare `read` is `Sys.read`, and the module to
// qualify it with differs by system (Darwin, Glibc, Musl). Out here the bare name is the C library's.
@inline(__always) private func libcRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { read(fd, buffer, count) }
@inline(__always) private func libcWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { write(fd, buffer, count) }
@inline(__always) private func libcClose(_ fd: Int32) -> Int32 { close(fd) }
@inline(__always) private func libcPipe(_ fds: UnsafeMutablePointer<Int32>) -> Int32 { pipe(fds) }
@inline(__always) private func libcKill(_ pid: pid_t, _ signal: Int32) -> Int32 { kill(pid, signal) }
@inline(__always) private func libcOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 { open(path, flags, mode) }
@inline(__always) private func libcConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { connect(fd, address, length) }
@inline(__always) private func libcListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
@inline(__always) private func libcAccept(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 { accept(fd, address, length) }
@inline(__always) private func libcTruncate(_ path: String, _ length: off_t) -> Int32 { truncate(path, length) }
