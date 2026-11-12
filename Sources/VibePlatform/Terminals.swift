// The Mac's names are kept behind a lock and spelled with a format: Foundation's, there only.
#if canImport(Darwin)
import Foundation
#endif

extension Platform {
    /// A terminal's name: what a session is known by (its state file `state/<name>.json`, its steer inbox), so one
    /// word with no slash in it.
    public enum Terminals {
        /// The name of the terminal at `devicePath`: its path under /dev, and when that is inside a folder there (as
        /// Linux's pseudo-terminals are, /dev/pts/3) without the slashes and with `tty` before it unless it starts so.
        /// "/dev/ttys009" is "ttys009", "/dev/pts/3" is "ttypts3", "/dev/tty" is "tty". The same on every system, and
        /// the same name `name(device:)` gives that terminal from its device number.
        public static func name(devicePath: String) -> String {
            let prefix = "/dev/"
            let name = devicePath.hasPrefix(prefix) ? String(devicePath.dropFirst(prefix.count)) : devicePath
            guard name.contains("/") else { return name }
            let flat = String(name.filter { $0 != "/" })
            return flat.hasPrefix("tty") ? flat : "tty" + flat
        }
    }
}

#if canImport(Darwin)
extension Platform.Terminals {
    // devname() scans /dev on every call, and a device's name never changes, so the names found are kept.
    static let names = TerminalNames()

    /// The name of the terminal with this device number (a process's controlling terminal, as its record gives it);
    /// nil for none (-1) and for one that is closed.
    public static func name(device: dev_t) -> String? { names.name(device) }
}

/// Terminals' names by device. A pseudo-terminal's is its number's (`ttys` and three digits, as the kernel names them),
/// checked with one stat: devname() scans /dev, 1 to 54 ms a device at load 176, where 116 devices cost a read 0.1 to
/// 0.5 s, mostly closed terminals some process still has as its own, each a scan of all of /dev for nothing. A name
/// found is kept (a device's never changes); a closed one's absence isn't: its number is the next one opened's.
public final class TerminalNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [dev_t: String] = [:]
    /// Pseudo-terminals' major device number, once one has been named.
    private var ptyMajor: Int32?

    public init() {}

    public func name(_ device: dev_t) -> String? {
        guard device != -1 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached = names[device] { return cached }
        let major = Int32(truncatingIfNeeded: UInt32(bitPattern: device) >> 24 & 0xff)
        let pty = String(format: "ttys%03d", device & 0xffffff)
        var node = stat()
        if stat("/dev/" + pty, &node) == 0, node.st_mode & S_IFMT == S_IFCHR, node.st_rdev == device {
            ptyMajor = major
            names[device] = pty
            return pty
        }
        // A closed pseudo-terminal.
        if major == ptyMajor { return nil }
        // Another device (or no pseudo-terminal named yet).
        guard let raw = devname(device, S_IFCHR) else { return nil }
        let name = String(cString: raw)
        guard name != "??" else { return nil }
        names[device] = name
        return name
    }
}
#elseif os(Linux)
extension Platform.Terminals {
    /// The name of the terminal with this device number (a process's controlling terminal, as /proc/<pid>/stat's
    /// tty_nr gives it, or a device file's `st_rdev`); nil for none (0) and for a device the system doesn't name.
    ///
    /// A pseudo-terminal (major 136 to 143) is /dev/pts/<minor>, so "ttypts<minor>", with nothing read. Any other
    /// (a console, a serial line) is named as the kernel names its file under /dev: `DEVNAME` in
    /// /sys/dev/char/<major>:<minor>/uevent, one small read a call and nothing kept (few processes sit on one).
    public static func name(device: dev_t) -> String? {
        // The kernel's and the C library's layouts agree on a number of 32 bits: the major in bits 8 to 19, the
        // minor in bits 0 to 7 and 20 to 31.
        let number = UInt64(device)
        guard number != 0 else { return nil }
        let major = number >> 8 & 0xfff
        let minor = number & 0xff | number >> 12 & 0xfff00
        if (136...143).contains(major) { return "ttypts\(minor)" }
        guard case .success(let event) = Platform.Processes.System.contents("/sys/dev/char/\(major):\(minor)/uevent") else { return nil }
        let key = Array("DEVNAME=".utf8)
        for line in event.split(separator: UInt8(ascii: "\n")) where line.starts(with: key) {
            let path = String(decoding: line.dropFirst(key.count), as: UTF8.self)
            return path.isEmpty ? nil : name(devicePath: "/dev/" + path)
        }
        return nil
    }
}
#endif
