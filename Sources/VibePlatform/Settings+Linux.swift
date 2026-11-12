#if os(Linux)
import Foundation

/// Settings in one file, a binary property list (the form that keeps a Date whole: the XML form drops the fraction of
/// its second): Linux has no defaults server, and its Foundation's `UserDefaults` keeps a process's own domain only.
///
/// - The file is private (mode 0600), and so is a folder this makes for it (0700; one that is there is left as it is).
/// - A `set` writes the whole list to a new file beside it and renames that into place: a reader has the old list or
///   the new one, never part of one, and a process that ends halfway leaves the old one (and a `.tmp` file). The new
///   file is synced first, so the list survives the machine going down.
/// - A `set` takes the lock `<file>.lock` (flock) from reading the list to renaming the new one: two processes
///   setting different keys both keep theirs. A read takes no lock.
/// - A read asks the file's identity, time and size (one `stat`) and reads it again only when they changed, so it has
///   what another process wrote. The file last read is kept open: its number can't be given to a later file, so the
///   same number is the same file.
/// - No file: empty, and a `set` makes it.
/// - A file that is no property list of settings (cut short, another program's): empty, and no read changes it. A
///   `set` then moves it to `<file>.corrupt` (over an earlier one) and starts a new list with the one key.
/// - A file that can't be read (no permission, a folder in its place, no descriptor left to open it): empty, and
///   nothing writes to it: a `set` is kept in memory, for this store only, until the file reads again.
/// - A `set` that can't be written (a full disk, a folder that can't be made) is kept in memory the same way, and
///   lasts until another process's write is read.
/// - A value that is no property list (a URL, an object) is refused: nothing changes. `UserDefaults` raises there.
///
/// Every method may be called from any thread.
final class FileSettings: SettingsStore, @unchecked Sendable {
    /// What tells one state of the file from the next: which file it is, when its contents last changed, its length.
    struct Stamp: Equatable {
        var device: UInt64
        var inode: UInt64
        var seconds: Int64
        var nanoseconds: Int64
        var size: Int64

        init(_ info: stat) {
            device = UInt64(info.st_dev)
            inode = info.inode
            seconds = Int64(info.modified.tv_sec)
            nanoseconds = Int64(info.modified.tv_nsec)
            size = info.byteSize
        }
    }

    enum State: Equatable {
        /// Not looked at yet.
        case unread
        /// There is no file.
        case missing
        /// `values` is this file's list.
        case loaded(Stamp)
        /// This file is no list of settings.
        case corrupt(Stamp)
        /// There is something at the path, and it can't be read.
        case unreadable
    }

    /// A list larger than this isn't settings: it reads as unreadable.
    static let largest = 64 << 20

    let path: String
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var state = State.unread
    /// The file `values` was read from or written to, kept open (see the type's note); -1 when there is none.
    private var held: Int32 = -1

    /// The settings kept in `file`. Nothing is read or made until the first read or `set`.
    init(file: URL) {
        path = file.path
    }

    deinit {
        if held >= 0 { close(held) }
    }

    // MARK: SettingsStore

    func object(forKey key: String) -> Any? {
        current()[key]
    }

    func string(forKey key: String) -> String? {
        switch object(forKey: key) {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    func bool(forKey key: String) -> Bool {
        switch object(forKey: key) {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return NSString(string: text).boolValue
        default: return false
        }
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        object(forKey: key) as? [String: Any]
    }

    func set(_ value: Any?, forKey key: String) {
        if let value, !PropertyListSerialization.propertyList(value, isValidFor: .binary) { return }
        lock.lock()
        defer { lock.unlock() }
        Self.makeFolders((path as NSString).deletingLastPathComponent)
        let gate = Self.locked(path + ".lock")
        defer { if gate >= 0 { close(gate) } }
        refresh()
        var next = values
        if let value { next[key] = value } else { next.removeValue(forKey: key) }
        guard state != .unreadable,
              let data = try? PropertyListSerialization.data(fromPropertyList: next, format: .binary, options: 0) else {
            values = next
            return
        }
        if case .corrupt = state {
            guard rename(path, path + ".corrupt") == 0 else {
                values = next
                return
            }
            become(.missing, [:], holding: -1)
        }
        guard let written = Self.replace(path, with: data) else {
            values = next
            return
        }
        // As a later read of the file would have them: a number is an NSNumber whatever it was given as.
        become(.loaded(written.stamp), Self.list(data) ?? next, holding: written.descriptor)
    }

    // MARK: Reading

    /// The list as the file has it now.
    private func current() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        refresh()
        return values
    }

    /// Reads the file again when it isn't the one `values` came from. Under the lock.
    private func refresh() {
        var info = stat()
        let there = stat(path, &info) == 0
        let code = there ? 0 : errno
        switch state {
        case .loaded(let stamp), .corrupt(let stamp):
            if there, Stamp(info) == stamp { return }
        case .missing:
            if !there, code == ENOENT { return }
        case .unread, .unreadable:
            break
        }
        load()
    }

    private func load() {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { become(.missing, [:], holding: -1) } else { becomeUnreadable() }
            return
        }
        // A file another program writes in place is read again until it holds still: a few times, then as it is.
        var info = stat(), after = stat()
        var bytes: Data?
        for _ in 0..<4 {
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { break }
            bytes = Self.contents(fd, limit: Self.largest)
            guard bytes != nil, fstat(fd, &after) == 0, Stamp(after) != Stamp(info) else { break }
        }
        guard let bytes else {
            close(fd)
            becomeUnreadable()
            return
        }
        // An empty file is an empty list: there is nothing in it to keep.
        if let read = bytes.isEmpty ? [:] : Self.list(bytes) {
            become(.loaded(Stamp(info)), read, holding: fd)
        } else {
            become(.corrupt(Stamp(info)), [:], holding: fd)
        }
    }

    private func become(_ next: State, _ list: [String: Any], holding fd: Int32) {
        if held >= 0 { close(held) }
        held = fd
        state = next
        values = list
    }

    /// What was set while there was no file to read stays, for as long as there is none: only a list that was read
    /// from a file goes with it.
    private func becomeUnreadable() {
        become(.unreadable, state == .unreadable || state == .missing ? values : [:], holding: -1)
    }

    /// `bytes` as a list of settings; nil when they are no property list, or one that isn't a dictionary (Foundation
    /// reads any plain text as an old-style list of one string).
    static func list(_ bytes: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)) as? [String: Any]
    }

    /// Everything `fd` holds, from its start; nil when it can't be read or is longer than `limit`.
    static func contents(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var offset: off_t = 0
        while true {
            let got = chunk.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
            if got < 0, errno == EINTR { continue }
            guard got >= 0, data.count + got <= limit else { return nil }
            if got == 0 { return data }
            data.append(contentsOf: chunk[0..<got])
            offset += off_t(got)
        }
    }

    // MARK: Writing

    /// Puts `data` at `path` in one step: a new private file beside it, written, synced and renamed over it. The new
    /// file, open, and its stamp; nil when any of that failed, and then `path` is as it was.
    static func replace(_ path: String, with data: Data) -> (descriptor: Int32, stamp: Stamp)? {
        let temporary = "\(path).\(getpid())-\(String(UInt64.random(in: 0...UInt64.max), radix: 16)).tmp"
        let fd = open(temporary, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        // The mode again: the process's umask may have taken from it. A file system that can't sync says EINVAL.
        guard fchmod(fd, 0o600) == 0, writeAll(fd, data), fsync(fd) == 0 || errno == EINVAL, fstat(fd, &info) == 0,
              rename(temporary, path) == 0 else {
            close(fd)
            unlink(temporary)
            return nil
        }
        return (fd, Stamp(info))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let wrote = write(fd, bytes.baseAddress! + done, bytes.count - done)
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else { return false }
                done += wrote
            }
            return true
        }
    }

    /// The lock file at `path`, made when it isn't there, locked for this caller alone until the descriptor is
    /// closed; -1 when it can't be opened. A file system that can't lock gives it unlocked.
    static func locked(_ path: String) -> Int32 {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return -1 }
        while flock(fd, LOCK_EX) != 0, errno == EINTR {}
        return fd
    }

    /// Makes `folder` and the folders above it that aren't there, each private.
    static func makeFolders(_ folder: String) {
        var info = stat()
        guard !folder.isEmpty, stat(folder, &info) != 0 else { return }
        let parent = (folder as NSString).deletingLastPathComponent
        if parent != folder { makeFolders(parent) }
        if mkdir(folder, 0o700) == 0 { chmod(folder, 0o700) }
    }

    // MARK: Where a domain is kept

    /// VibeSwitcher's folder, by VibeCore's rule (`VibePaths.root`, kept in step with it by hand: this module is
    /// below VibeCore): `VIBESWITCHER_HOME`, else `.vibeswitcher` in `CFFIXED_USER_HOME`, in `HOME`, in
    /// `fallbackHome`. A variable counts only when it is an absolute path.
    static func root(variable: (String) -> String?, fallbackHome: @autoclosure () -> String) -> URL {
        func absolute(_ name: String) -> String? {
            guard let path = variable(name), path.hasPrefix("/") else { return nil }
            return path
        }
        if let own = absolute("VIBESWITCHER_HOME") { return URL(fileURLWithPath: own, isDirectory: true) }
        let home = absolute("CFFIXED_USER_HOME") ?? absolute("HOME") ?? fallbackHome()
        return URL(fileURLWithPath: home).appendingPathComponent(".vibeswitcher")
    }

    /// The file `domain`'s settings are kept in (see `Platform.settings(domain:)`); nil for an empty domain.
    static func file(domain: String, variable: (String) -> String? = { name in getenv(name).map { String(cString: $0) } },
                     fallbackHome: @autoclosure () -> String = NSHomeDirectory()) -> URL? {
        guard !domain.isEmpty else { return nil }
        if domain.hasPrefix("/") { return URL(fileURLWithPath: domain + ".plist") }
        let folder = root(variable: variable, fallbackHome: fallbackHome())
        guard domain != Platform.appSettingsDomain else { return folder.appendingPathComponent("settings.plist") }
        let plain = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_".utf8)
        let name = domain.utf8.map { plain.contains($0) ? String(UnicodeScalar($0)) : "%" + (($0 < 16 ? "0" : "") + String($0, radix: 16, uppercase: true)) }
        return folder.appendingPathComponent("settings-\(name.joined()).plist")
    }

    // MARK: One store a file

    /// The stores in use, by their file: held weakly, so one nobody holds goes, and its descriptor with it.
    private static let registryLock = NSLock()
    private static var registry: [String: Weak] = [:]
    /// The app's domain's store last asked for, kept: the callers ask at each read and hold nothing.
    private static var kept: FileSettings?

    private struct Weak {
        weak var store: FileSettings?
    }

    static func shared(domain: String) -> FileSettings? {
        file(domain: domain).map { shared(file: $0, keep: domain == Platform.appSettingsDomain) }
    }

    static func shared(file: URL, keep: Bool = true) -> FileSettings {
        registryLock.lock()
        defer { registryLock.unlock() }
        let path = file.path
        let store: FileSettings
        if let known = registry[path]?.store {
            store = known
        } else {
            store = FileSettings(file: file)
            registry = registry.filter { $0.value.store != nil }
            registry[path] = Weak(store: store)
        }
        if keep { kept = store }
        return store
    }
}
#endif
