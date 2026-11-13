#if os(Linux)
// Linux's pseudo-terminals: posix_openpt and the slave opened by its path, each close-on-exec from the call that
// makes it, and the terminal's ioctls through the shim (Swift reaches no variadic ioctl, and glibc shows posix_openpt
// only under _XOPEN_SOURCE).
extension Platform.Terminals {
    /// A new pseudo-terminal of `rows` × `cols`: `posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)`, `grantpt`,
    /// `unlockpt`, its slave opened `O_RDWR | O_NOCTTY | O_CLOEXEC` by the path `ptsname_r` names, then its size
    /// (`TIOCSWINSZ`). Both ends are close-on-exec from their making, so no program another thread starts meanwhile
    /// holds either, and neither is this process's controlling terminal. On failure nothing is left open.
    public static func open(rows: UInt16, cols: UInt16) -> Result<PseudoTerminal, Platform.Errno> {
        let master = vibe_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard master >= 0 else { return .failure(Platform.Errno(code: errno)) }
        var buffer = [CChar](repeating: 0, count: 128)
        let named = vibe_ptsname_r(master, &buffer, buffer.count)
        guard named == 0 else {
            Sys.close(master)
            return .failure(Platform.Errno(code: named))
        }
        let path = String(cString: buffer)
        let slave = Sys.open(path, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard slave >= 0 else {
            let code = errno
            Sys.close(master)
            return .failure(Platform.Errno(code: code))
        }
        let sized = vibe_terminal_set_size(master, rows, cols)
        guard sized == 0 else {
            Sys.close(slave)
            Sys.close(master)
            return .failure(Platform.Errno(code: sized))
        }
        return .success(PseudoTerminal(master: master, slave: slave, devicePath: path, name: name(devicePath: path)))
    }

    /// The path of the slave of the terminal whose master is `master` (`ptsname_r`, which keeps no buffer shared
    /// between threads); nil when `master` is no pseudo-terminal's master.
    public static func devicePath(master: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        return vibe_ptsname_r(master, &buffer, buffer.count) == 0 ? String(cString: buffer) : nil
    }

    /// The terminal `fd` becomes the controlling terminal of this process (`TIOCSCTTY`), which must lead a session
    /// that has none: 0, or the error number (EPERM when another session has it).
    public static func makeControlling(_ fd: Int32) -> Int32 {
        vibe_make_controlling(fd)
    }

    /// `O_RDWR | O_NOCTTY`. glibc's posix_spawn starts the child's new session before it opens the child's files, so a
    /// slave opened without `O_NOCTTY` would be the child's controlling terminal before any of its code ran (measured
    /// here); with it, only the launcher's own `makeControlling` takes the terminal.
    public static let launcherOpenFlags: Int32 = O_RDWR | O_NOCTTY

    /// The session whose controlling terminal `fd`'s terminal is, when it is this process's own controlling terminal
    /// (`tcgetsid`, which is `TIOCGSID` here: glibc shows `tcgetsid` only under `_XOPEN_SOURCE`); nil for any other
    /// terminal, and for what is no terminal. (Given a master, it answers as `session(ofMaster:)` does.)
    public static func controllingSession(_ fd: Int32) -> pid_t? {
        var session: pid_t = 0
        return vibe_terminal_session(fd, &session) == 0 && session > 0 ? session : nil
    }

    /// The session whose controlling terminal the slave of `master` is (`TIOCGSID` on the master, which answers
    /// whoever asks); nil while no session has it, or when `master` is no terminal.
    public static func session(ofMaster master: Int32) -> pid_t? {
        var session: pid_t = 0
        return vibe_terminal_session(master, &session) == 0 && session > 0 ? session : nil
    }

    /// The size of `fd`'s terminal (`TIOCGWINSZ`); nil when `fd` is no terminal.
    public static func size(_ fd: Int32) -> (rows: UInt16, cols: UInt16)? {
        var rows: UInt16 = 0, cols: UInt16 = 0
        return vibe_terminal_size(fd, &rows, &cols) == 0 ? (rows, cols) : nil
    }
}
#endif
