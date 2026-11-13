#if canImport(Darwin)
// The Mac's pseudo-terminals: openpty behind its lock, then both ends marked close-on-exec, as the host's PTYSpawn
// made them (moved here unchanged); the launcher's controlling terminal taken with TIOCSCTTY, as its launcher does.
import Foundation

extension Platform.Terminals {
    private static let openptyLock = NSLock()

    /// A new pseudo-terminal of `rows` × `cols` (`openpty`, given its size), both ends then marked close-on-exec:
    /// the Mac has no flag to make them so. On failure nothing is left open.
    public static func open(rows: UInt16, cols: UInt16) -> Result<PseudoTerminal, Platform.Errno> {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        var slave: Int32 = -1
        // One at a time: on macOS 27, openpty called from several threads at once fails for some of them (errno -6),
        // and sessions start from several threads at once.
        openptyLock.lock()
        let opened = openpty(&master, &slave, nil, nil, &size)
        let code = errno
        openptyLock.unlock()
        guard opened == 0 else { return .failure(Platform.Errno(code: code)) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        // From the master (the kernel names it): ttyname's buffer is shared between threads, and on a busy Mac it
        // can find no name yet for a terminal just made.
        var buffer = [CChar](repeating: 0, count: 128)
        let named = ptsname_r(master, &buffer, buffer.count)
        guard named == 0 else {
            let failed = errno
            Sys.close(slave)
            Sys.close(master)
            return .failure(Platform.Errno(code: failed))
        }
        let path = String(cString: buffer)
        return .success(PseudoTerminal(master: master, slave: slave, devicePath: path, name: name(devicePath: path)))
    }

    /// The path of the slave of the terminal whose master is `master` (`ptsname_r`); nil when it has none.
    public static func devicePath(master: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        return ptsname_r(master, &buffer, buffer.count) == 0 ? String(cString: buffer) : nil
    }

    /// The terminal `fd` becomes the controlling terminal of this process (`TIOCSCTTY`, which the Mac needs even of
    /// a session leader that opened it): 0, or the error number.
    public static func makeControlling(_ fd: Int32) -> Int32 {
        ioctl(fd, TIOCSCTTY, 0) == 0 ? 0 : errno
    }

    /// `O_RDWR`, as the host's launcher has always opened its terminal: opening it doesn't make it the launcher's
    /// controlling terminal on the Mac; its `makeControlling` does.
    public static let launcherOpenFlags: Int32 = O_RDWR

    /// The session whose controlling terminal `fd`'s terminal is, when it is this process's own controlling terminal
    /// (`tcgetsid`); nil otherwise.
    public static func controllingSession(_ fd: Int32) -> pid_t? {
        let session = tcgetsid(fd)
        return session > 0 ? session : nil
    }

    /// Nothing on the Mac (nil): its launcher's path is unchanged, and the check this answers (a session is live only
    /// once its launcher holds its terminal) is Linux's.
    public static func session(ofMaster master: Int32) -> pid_t? { nil }

    /// The size of `fd`'s terminal (`TIOCGWINSZ`); nil when `fd` is no terminal.
    public static func size(_ fd: Int32) -> (rows: UInt16, cols: UInt16)? {
        var size = winsize()
        return ioctl(fd, TIOCGWINSZ, &size) == 0 ? (size.ws_row, size.ws_col) : nil
    }
}
#endif
