import Foundation
import VibeCore

/// The user manager's own configuration in the home, `<home>/.config/systemd/user.conf` and `user.conf.d/*.conf`,
/// read whole and as systemd's `config_parse` reads it, so `start` sees every `DefaultEnvironment=` and
/// `ManagerEnvironment=` the manager would apply (security follow-up 21). What it can't read whole it refuses: a file
/// there that is no regular file, can't be read, is bigger than `fileLimit` or isn't UTF-8, a drop-in that is a link,
/// a `user.conf.d` that can't be listed. A key counts in any section (systemd takes it only under `[Manager]`) and
/// in any case, and the text is read both ways systemd versions treat a comment line inside a continuation: each
/// errs on refusing.
enum ManagerConfig {
    /// The keys that give the manager's units, or its generators, an environment.
    static let environmentKeys = ["DefaultEnvironment", "ManagerEnvironment"]

    /// What a key is trimmed of before it is compared.
    private static let keyTrimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    /// The largest file read: systemd's longest line is 1 MiB, and a real `user.conf` is a few kilobytes.
    static let fileLimit = 4 << 20

    /// Why `start` refuses the manager configuration in `accountHome`, or nil (`NodeFolders.managerConfigRefusal`).
    static func refusal(accountHome: String) -> StartRefusal? {
        let systemd = NodeFolders.join(accountHome, ".config/systemd")
        let main = NodeFolders.join(systemd, "user.conf")
        // user.conf: a link is followed, as the manager follows it; missing (or no folder above it) is no config.
        let fd = Sys.open(main, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            if code != ENOENT && code != ENOTDIR { return unread(main, "can't be opened (\(describe(code)))") }
        } else if let refused = check(fd: fd, path: main) {
            return refused
        }
        let dropIns = NodeFolders.join(systemd, "user.conf.d")
        guard let folder = opendir(dropIns) else {
            let code = errno
            if code == ENOENT || code == ENOTDIR && !exists(dropIns) { return nil }
            return unread(dropIns, "can't be listed (\(describe(code)))")
        }
        defer { closedir(folder) }
        var names: [[UInt8]] = []
        while true {
            errno = 0
            guard let entry = readdir(folder) else {
                if errno != 0 { return unread(dropIns, "can't be listed (\(describe(errno)))") }
                break
            }
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { field -> [UInt8] in
                let bytes = field.bindMemory(to: UInt8.self)
                return Array(bytes[..<(bytes.firstIndex(of: 0) ?? bytes.count)])
            }
            if name.count > 5, name.suffix(5).elementsEqual(".conf".utf8) { names.append(name) }
        }
        for name in names.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let path = NodeFolders.join(dropIns, String(decoding: name, as: UTF8.self))
            guard isUTF8(name) else { return unread(path, "has a name that isn't UTF-8") }
            // By its name in the folder listed, never following a link: a drop-in that is one is refused.
            let fd = openat(dirfd(folder), name.map { CChar(bitPattern: $0) } + [0], O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else {
                let code = errno
                return unread(path, code == ELOOP ? "is a link (a drop-in that is one isn't taken)" : "can't be opened (\(describe(code)))")
            }
            if let refused = check(fd: fd, path: path) { return refused }
        }
        return nil
    }

    /// Reads `fd` (closing it) whole and refuses what it can't read or what sets an environment key.
    private static func check(fd: Int32, path: String) -> StartRefusal? {
        switch text(fd: fd) {
        case .failure(let unreadable): return unread(path, unreadable.why)
        case .success(let bytes):
            for skipComments in [true, false] {
                for (key, value) in assignments(bytes, skipCommentLines: skipComments) {
                    // Unicode's spaces and a byte-order mark trimmed too: a key systemd wouldn't take still counts.
                    let name = String(decoding: key, as: UTF8.self).trimmingCharacters(in: keyTrimmed)
                    guard !value.isEmpty, let found = environmentKeys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
                    return StartRefusal("\(ConfigSeal.inert(path, limit: .max)) sets \(found)=, which the user manager gives to what it starts at its next daemon-reload or login, past start's check of its environment; remove that line (and run `systemctl --user daemon-reload`)")
                }
            }
            return nil
        }
    }

    /// Why a file isn't read whole.
    struct Unread: Error { let why: String }

    /// The bytes of the regular file open at `fd` (closed here), or why they aren't taken.
    static func text(fd: Int32) -> Result<[UInt8], Unread> {
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(Unread(why: "can't be read (\(describe(errno)))")) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(Unread(why: "isn't a regular file")) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let got = buffer.withUnsafeMutableBytes { Sys.read(fd, $0.baseAddress, $0.count) }
            if got < 0, errno == EINTR { continue }
            guard got >= 0 else { return .failure(Unread(why: "can't be read (\(describe(errno)))")) }
            if got == 0 { break }
            bytes += buffer[0..<got]
            guard bytes.count <= fileLimit else { return .failure(Unread(why: "is bigger than \(fileLimit) bytes")) }
        }
        guard isUTF8(bytes) else { return .failure(Unread(why: "isn't UTF-8")) }
        return .success(bytes)
    }

    /// The assignments (key, value) a systemd configuration text makes, as `config_parse` reads it: a line ends at
    /// `\n`, `\r` or NUL (`read_line`'s rules: `\r\n` or `\n\r` is one end, a NUL ends at once); a line ending in an
    /// unescaped backslash goes on with the next, the backslash a space, and one still open at the end is read; a
    /// byte-order mark is dropped; a blank line, a comment (`#` or `;` first) and a section header set nothing; key
    /// and value stripped of spaces, tabs, `\r` and `\n`. `skipCommentLines`: newer systemd drops a comment line
    /// before joining it (so it neither continues nor ends a continuation); older systemd joins it like any other.
    /// Assignments outside `[Manager]` and before any section are kept: systemd ignores them, and this errs on
    /// refusing.
    static func assignments(_ bytes: [UInt8], skipCommentLines: Bool) -> [(key: [UInt8], value: [UInt8])] {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        let comments: Set<UInt8> = [UInt8(ascii: "#"), UInt8(ascii: ";")]
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        func strip(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
            var line = line
            while let first = line.first, whitespace.contains(first) { line = line.dropFirst() }
            while let last = line.last, whitespace.contains(last) { line = line.dropLast() }
            return line
        }
        var found: [(key: [UInt8], value: [UInt8])] = []
        func parse(_ raw: [UInt8]) {
            let line = strip(raw[...])
            guard let first = line.first, !comments.contains(first), first != UInt8(ascii: "\n"), first != UInt8(ascii: "[") else { return }
            guard let equals = line.firstIndex(of: UInt8(ascii: "=")), equals != line.startIndex else { return }
            found.append((Array(strip(line[..<equals])), Array(strip(line[(equals + 1)...]))))
        }
        var bomSeen = false
        var continuation: [UInt8]?
        for var line in lines(bytes) {
            if skipCommentLines, let first = strip(line[...]).first, comments.contains(first) { continue }
            if !bomSeen, line.starts(with: bom) {
                line.removeFirst(bom.count)
                bomSeen = true
            }
            var joined = (continuation ?? []) + line
            var escaped = false
            for byte in joined {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true }
            }
            if escaped {
                joined[joined.count - 1] = 0x20
                continuation = joined
                continue
            }
            continuation = nil
            parse(joined)
        }
        if let continuation { parse(continuation) }
        return found
    }

    /// `bytes`' lines as systemd's `read_line` ends them: at `\n`, `\r` or NUL, a run of ends counting as one while no
    /// kind repeats and none follows a NUL.
    static func lines(_ bytes: [UInt8]) -> [[UInt8]] {
        let nul: UInt8 = 1, ten: UInt8 = 2, thirteen: UInt8 = 4
        func kind(_ byte: UInt8) -> UInt8 {
            switch byte {
            case 0x0A: return ten
            case 0x0D: return thirteen
            case 0x00: return nul
            default: return 0
            }
        }
        var lines: [[UInt8]] = []
        var line: [UInt8] = []
        var ended: UInt8 = 0
        for byte in bytes {
            let eol = kind(byte)
            if ended & nul != 0 || (eol == 0 && ended != 0) || (eol != 0 && ended & eol != 0) {
                lines.append(line)
                line = []
                ended = 0
            }
            if eol != 0 { ended |= eol } else { line.append(byte) }
        }
        if ended != 0 || !line.isEmpty { lines.append(line) }
        return lines
    }

    private static func unread(_ path: String, _ why: String) -> StartRefusal {
        StartRefusal("start reads the user manager's configuration whole before it starts anything, and \(ConfigSeal.inert(path, limit: .max)) \(why): the manager may still apply what it holds (a DefaultEnvironment= or ManagerEnvironment=) at its next daemon-reload or login. Make it a readable UTF-8 regular file or remove it")
    }

    /// Whether `bytes` is UTF-8: decoding it replaces nothing.
    static func isUTF8(_ bytes: [UInt8]) -> Bool { Array(String(decoding: bytes, as: UTF8.self).utf8) == bytes }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func describe(_ code: Int32) -> String { String(cString: strerror(code)) }
}
