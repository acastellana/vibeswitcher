import Foundation

/// The user's known Startup shortcuts (2026-11-20): an app the user runs (a dictation app on the node) rewrites its own
/// shortcut in the Windows Startup folder at every sign-in, with the same target and a new version in its working
/// folder and icon, and the seal's listing of that folder (`LinuxSealList`, by metadata) held the team at every reboot.
///
/// The list is the user's, `~/.vibeswitcher/v2/known-startup` (`listFile`): one shortcut a line, written
/// `USER | NAME.lnk | TARGET` or `USER | NAME.lnk | TARGET | ARGUMENTS` (`|` is in no Windows name or path, so only the
/// arguments may hold one); blank lines and `#` lines are skipped. `vibeswitcher config startup` prints each shortcut
/// there is as such a line. No app is named in the code.
///
/// The rule (S7, the start plan's seal list): in user `USER`'s Startup folder, a top-level regular file named exactly
/// `NAME.lnk` (a line names it) whose bytes `read` takes, every target they carry naming exactly `TARGET` and with
/// exactly `ARGUMENTS` (none when the line gives none), is hashed by that line, not by its metadata; and while the list
/// names any shortcut of that user, the folder's own line is its type and mode, not its times (each rewrite changes
/// them). Everything else is hashed as ever, so held as ever: a same-named shortcut pointing anywhere else, with other
/// arguments or any part `read` doesn't take, a link or folder of that name, any other entry (added, removed, or
/// changed in place), and the list itself, which is on the seal's list (`LinuxSealList.homeEntries`), so a line added
/// is a held change the user accepts. The list is under `~/.vibeswitcher`, which no session's box shows
/// (`SandboxPolicy.hidden`). The shortcut is read once per look, a regular file of at most `shortcutLimit` bytes, no
/// link followed; a write after the look is seen by the next one.
///
/// What `read` takes (MS-SHLLINK), and refuses everything else, so no part Windows may launch from can name another
/// program: the link-target ID list (the shell's own target) of file-system items under My Computer and a drive, or
/// under the user's profile, each item's long name kept and its short name consistent with it; the link info's local
/// path on a fixed drive, and a network path only to this machine's share of the same folder; the relative path,
/// resolved from the Startup folder; a known-folder or special-folder block only for a folder whose path is known here
/// and only where the ID list has that path. All of them name the target. The working folder is the target's folder or
/// under it; the name and icon are display only. Refused: an environment-variable target, an MSI (Darwin) or shim
/// shortcut, a Vista ID list, a property store holding link-target properties, a link to a link, any block or flag not
/// named here.
///
/// *Doesn't promise*: the target file itself is not watched (as before: a worker that can write the Windows profile
/// can replace the program the shortcut names); the tracker block may find a moved target; a known folder the user's
/// registry redirects; a session that can run Windows programs (WSL interop) can change Windows without the Startup
/// folder at all.
public enum StartupShortcuts {
    /// Where the list is, under the account's home.
    public static let listFile = ".vibeswitcher/v2/known-startup"
    static let listLimit = 64 * 1024
    /// The most bytes a shortcut is read to.
    static let shortcutLimit = 64 * 1024

    /// A line of the list.
    public struct Known: Equatable, Sendable {
        public var user: String
        public var name: String
        public var target: String
        public var arguments: String

        public init(user: String, name: String, target: String, arguments: String = "") {
            self.user = user
            self.name = name
            self.target = target
            self.arguments = arguments
        }

        /// The line as the list writes it.
        public var line: String { [user, name, target].joined(separator: " | ") + (arguments.isEmpty ? "" : " | " + arguments) }

        /// What a known shortcut is hashed by in its folder's listing.
        var hashLine: String { "known \(name.utf8.count):\(name) -> \(target.utf8.count):\(target) \(arguments.utf8.count):\(arguments)" }
    }

    /// What a shortcut runs, as `read` takes it.
    public struct Shortcut: Equatable, Sendable {
        public var target: String
        public var arguments: String
    }

    /// The lines of the list's `text`: a user, a name ending `.lnk` and an absolute target (`isAbsolute`), arguments the
    /// rest; anything else skipped.
    public static func known(in text: String) -> [Known] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, isName(parts[0]), isName(parts[1]), parts[1].lowercased().hasSuffix(".lnk"), isAbsolute(parts[2]) else { return nil }
            return Known(user: parts[0], name: parts[1], target: parts[2], arguments: parts.count == 4 ? parts[3] : "")
        }
    }

    /// The list for a Startup folder read under `root` ("/" on the node): the account's own home's `listFile`, read
    /// under the same root (a test's scratch root). Nil when it can't be read.
    static func list(root: String) -> [Known]? {
        guard let home = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_dir) }), home.hasPrefix("/") else { return nil }
        let path = (root == "/" ? "" : root) + (home as NSString).appendingPathComponent(listFile)
        return ConfigSeal.regularContents(path, limit: listLimit, followLink: false).map { known(in: String(decoding: $0, as: UTF8.self)) }
    }

    /// The root a Startup folder at `path` is read under and its Windows user, when `path` is one
    /// (`<root>/mnt/c/Users/<user>/<LinuxSealList.windowsStartup>`).
    static func startupFolder(_ path: String) -> (root: String, user: String)? {
        let tail = "/" + LinuxSealList.windowsStartup
        guard path.hasSuffix(tail) else { return nil }
        let above = String(path.dropLast(tail.count))
        guard let range = above.range(of: "/mnt/c/Users/", options: .backwards) else { return nil }
        let user = String(above[range.upperBound...])
        guard isName(user) else { return nil }
        let root = String(above[..<range.lowerBound])
        return (root.isEmpty ? "/" : root, user)
    }

    /// The known lines for each top-level entry of `user`'s Startup folder at `folder` that `read` takes and that
    /// matches its line (by name), by entry name.
    static func knownEntries(in folder: String, user: String, list: [Known], host: String = hostName()) -> [String: Known] {
        var found: [String: Known] = [:]
        for line in list where line.user == user {
            let path = (folder as NSString).appendingPathComponent(line.name)
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  let data = ConfigSeal.regularContents(path, limit: shortcutLimit, followLink: false),
                  case .success(let shortcut) = read(data, user: user, host: host),
                  same(shortcut.target, line.target), shortcut.arguments == line.arguments else { continue }
            found[line.name] = line
        }
        return found
    }

    /// This machine's name (WSL's is Windows'), lowercased.
    public static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return String(cString: buffer).lowercased()
    }

    /// What `vibeswitcher config startup` prints: for each Windows user's Startup folder under `root` (while `/mnt/c` is
    /// mounted, `mounts` telling), each shortcut as the list's line (marked known when the list has it and the seal takes
    /// it so), or why the rule can't take it; then where the list is. Names are the files', for the caller to print inert.
    public static func report(root: String = "/", mounts: String = "/proc/mounts", host: String = hostName()) -> [String] {
        guard LinuxSealList.windowsMounted(mounts) else { return ["/mnt/c isn't mounted: no Windows Startup folder is watched"] }
        let at = { (name: String) in root == "/" ? name : (root as NSString).appendingPathComponent(name) }
        let list = self.list(root: root) ?? []
        var lines: [String] = []
        let users = "/mnt/c/Users"
        for user in ((try? FileManager.default.contentsOfDirectory(atPath: at(users))) ?? []).sorted() where !LinuxSealList.notUsers.contains(user) {
            let folder = at(users + "/" + user + "/" + LinuxSealList.windowsStartup)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            let known = knownEntries(in: folder, user: user, list: list, host: host)
            for name in names.sorted() where name.lowercased().hasSuffix(".lnk") {
                let path = (folder as NSString).appendingPathComponent(name)
                var info = stat()
                guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                      let data = ConfigSeal.regularContents(path, limit: shortcutLimit, followLink: false) else {
                    lines.append("\(user) | \(name): not a regular file of at most \(shortcutLimit) bytes")
                    continue
                }
                switch read(data, user: user, host: host) {
                case .success(let shortcut):
                    let line = Known(user: user, name: name, target: shortcut.target, arguments: shortcut.arguments).line
                    lines.append((known[name] != nil ? "known:   " : "unknown: ") + line)
                case .failure(let refusal): lines.append("\(user) | \(name): the seal can't take it as known: \(refusal.reason)")
                }
            }
        }
        if lines.isEmpty { lines.append("no shortcut in any Windows user's Startup folder") }
        lines.append("the list: ~/\(listFile), a line each (USER | NAME.lnk | TARGET [| ARGUMENTS]); a line added is held once for your accept")
        return lines
    }

    // MARK: Windows paths

    /// A name Windows allows for a file or a user: not empty, not `.` or `..`, none of `\/:*?"<>|`, no control.
    static func isName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255 else { return false }
        return name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !"\\/:*?\"<>|".unicodeScalars.contains($0) }
    }

    /// `X:\name\name…`: a drive and names (`isName`), no empty part, no trailing backslash.
    static func isAbsolute(_ path: String) -> Bool {
        let parts = path.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, isDrive(parts[0]) else { return false }
        return parts.dropFirst().allSatisfy(isName)
    }

    static func isDrive(_ part: String) -> Bool {
        let scalars = Array(part.unicodeScalars)
        return scalars.count == 2 && scalars[1] == ":" && scalars[0].isASCII && CharacterSet.letters.contains(scalars[0])
    }

    /// Whether two Windows paths name the same thing on a case-insensitive file system.
    static func same(_ one: String, _ other: String) -> Bool { one.lowercased() == other.lowercased() }

    /// Whether `inner` is `outer` or under it.
    static func within(_ inner: String, _ outer: String) -> Bool {
        same(inner, outer) || inner.lowercased().hasPrefix(outer.lowercased() + "\\")
    }

    static func profile(_ user: String) -> String { "C:\\Users\\" + user }

    static func startupWindowsPath(_ user: String) -> String {
        profile(user) + "\\" + LinuxSealList.windowsStartup.replacingOccurrences(of: "/", with: "\\")
    }

    /// The known folders a shortcut's block may name, by GUID: their path for `user`.
    static func knownFolder(_ guid: String, user: String) -> String? {
        switch guid {
        case "F3CE0F7C-4901-4ACC-8648-D5D44B04EF8F", "5E6C858F-0E22-4760-9AFE-EA3317B67173": return profile(user)  // UsersFiles, Profile
        case "F1B32785-6FBA-4FCF-9D55-7B8E7F157091": return profile(user) + "\\AppData\\Local"
        case "3EB685DB-65F9-4CF6-A03A-E3EF65729F3D": return profile(user) + "\\AppData\\Roaming"
        case "5CD7AEE2-2219-4A67-B85D-6C9CE15660CB": return profile(user) + "\\AppData\\Local\\Programs"
        case "905E63B6-C1BF-494E-B29C-65B732D3D21A", "6D809377-6AF0-444B-8957-A3773F02200E": return "C:\\Program Files"
        case "7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E": return "C:\\Program Files (x86)"
        default: return nil
        }
    }

    /// The special folders (CSIDL) a shortcut's block may name: their path for `user`.
    static func specialFolder(_ id: UInt32, user: String) -> String? {
        switch id {
        case 0x28: return profile(user)
        case 0x1C: return profile(user) + "\\AppData\\Local"
        case 0x1A: return profile(user) + "\\AppData\\Roaming"
        case 0x26: return "C:\\Program Files"
        case 0x2A: return "C:\\Program Files (x86)"
        default: return nil
        }
    }

    // MARK: Reading a shortcut (MS-SHLLINK)

    static let shellLinkCLSID = "00021401-0000-0000-C000-000000000046"
    static let myComputer = "20D04FE0-3AEA-1069-A2D8-08002B30309D"
    static let usersFiles = "59031A47-3F72-44A7-89C5-5595FE6B30EE"
    static let delegateItem = "5E591A74-DF96-48D3-8D67-1733BCEE28BA"
    static let usersFilesDelegate = "DFFACDC5-679F-4156-8947-C5C76BC0B67F"
    static let linkProperties = "B9B4B3FC-2B51-4A42-B5D8-324146AFCF25"

    enum Flag {
        static let idList: UInt32 = 0x1, linkInfo: UInt32 = 0x2, name: UInt32 = 0x4, relativePath: UInt32 = 0x8
        static let workingDir: UInt32 = 0x10, arguments: UInt32 = 0x20, icon: UInt32 = 0x40, unicode: UInt32 = 0x80
        /// The flags `read` takes: the strings above, RunInSeparateProcess, RunAsUser, HasExpIcon, NoPidlAlias,
        /// ForceNoLinkTrack, EnableTargetMetadata, the tracking and alias switches, UnaliasOnSave,
        /// KeepLocalIDListForUNCTarget. Not: ForceNoLinkInfo, HasExpString, HasDarwinID, RunWithShimLayer,
        /// AllowLinkToLink, PreferEnvironmentPath, or a bit the format doesn't name.
        static let taken: UInt32 = 0xFF | 0x400 | 0x2000 | 0x4000 | 0x8000 | 0x40000 | 0x80000 | 0x100000 | 0x200000 | 0x400000
            | 0x1000000 | 0x4000000
    }

    /// Why a shortcut isn't one the rule takes.
    public struct Refusal: Error, Equatable, Sendable {
        public var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// What the shortcut `data` in `user`'s Startup folder runs, when every part of it is one `read` takes and every
    /// target it carries names the same program; why not otherwise. `host`: this machine's name, lowercased.
    public static func read(_ data: Data, user: String, host: String = hostName()) -> Result<Shortcut, Refusal> {
        do { return .success(try Reader(Array(data), user: user, host: host).read()) } catch let refusal as Refusal {
            return .failure(refusal)
        } catch { return .failure(Refusal("\(error)")) }
    }

    private struct Reader {
        let bytes: [UInt8]
        let user: String
        let host: String

        init(_ bytes: [UInt8], user: String, host: String) {
            self.bytes = bytes
            self.user = user
            self.host = host
        }

        func u16(_ at: Int) throws -> Int {
            guard at >= 0, at + 2 <= bytes.count else { throw Refusal("cut short at \(at)") }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }

        func u32(_ at: Int) throws -> UInt32 {
            guard at >= 0, at + 4 <= bytes.count else { throw Refusal("cut short at \(at)") }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
        }

        func int(_ at: Int) throws -> Int { Int(try u32(at)) }

        /// A GUID stored as Windows stores it (the first three fields little-endian), in its usual upper-case form.
        func guid(_ at: Int) throws -> String {
            guard at >= 0, at + 16 <= bytes.count else { throw Refusal("cut short at \(at)") }
            let b = bytes[at..<(at + 16)].map { String(format: "%02X", $0) }
            let s = Array(b)
            return [s[3], s[2], s[1], s[0], "-", s[5], s[4], "-", s[7], s[6], "-", s[8], s[9], "-"].joined() + s[10...].joined()
        }

        /// An ASCII string from `at` to its NUL, before `end`.
        func ascii(_ at: Int, end: Int) throws -> String {
            guard at >= 0, at < end, end <= bytes.count, let nul = bytes[at..<end].firstIndex(of: 0) else { throw Refusal("a string past its part at \(at)") }
            let text = bytes[at..<nul]
            guard text.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { throw Refusal("a non-ASCII string at \(at)") }
            return String(decoding: text, as: UTF8.self)
        }

        /// A UTF-16LE string from `at` to its NUL, before `end`.
        func utf16(_ at: Int, end: Int) throws -> String {
            var units: [UInt16] = []
            var at = at
            while true {
                guard at + 2 <= end, end <= bytes.count else { throw Refusal("a string past its part") }
                let unit = UInt16(try u16(at))
                if unit == 0 { break }
                units.append(unit)
                at += 2
            }
            return String(decoding: units, as: UTF16.self)
        }

        func read() throws -> Shortcut {
            guard bytes.count >= 0x4C, try u32(0) == 0x4C, try guid(4) == shellLinkCLSID else { throw Refusal("not a shell link") }
            let flags = try u32(0x14)
            guard flags & ~Flag.taken == 0 else { throw Refusal(String(format: "flags 0x%08X: a part that can run something else", flags & ~Flag.taken)) }
            guard flags & Flag.idList != 0, flags & Flag.linkInfo != 0, flags & Flag.unicode != 0 else {
                throw Refusal("no ID list, no link info, or no Unicode strings")
            }
            var at = 0x4C
            let idSize = try u16(at)
            let idStart = at + 2, idEnd = at + 2 + idSize
            let ids = try idList(from: idStart, to: idEnd)
            at = idEnd

            let infoSize = try int(at)
            guard infoSize >= 0x1C, at + infoSize <= bytes.count else { throw Refusal("link info past the file") }
            let local = try linkInfo(at, size: infoSize)
            at += infoSize

            var strings: [UInt32: String] = [:]
            for flag in [Flag.name, Flag.relativePath, Flag.workingDir, Flag.arguments, Flag.icon] where flags & flag != 0 {
                let count = try u16(at)
                guard at + 2 + 2 * count <= bytes.count else { throw Refusal("a string past the file") }
                strings[flag] = String(decoding: (0..<count).map { UInt16(bytes[at + 2 + 2 * $0]) | UInt16(bytes[at + 3 + 2 * $0]) << 8 }, as: UTF16.self)
                at += 2 + 2 * count
            }
            let folders = try extraData(from: at)

            // Every target names the same program.
            guard isAbsolute(local) else { throw Refusal("the link info's path \(local) isn't a whole Windows path") }
            guard same(ids.path, local) else { throw Refusal("the ID list names \(ids.path), the link info \(local)") }
            for (path, offset) in folders {
                guard let named = ids.prefixes[offset], same(named, path) else { throw Refusal("a known folder block names \(path) where the ID list doesn't") }
            }
            if let relative = strings[Flag.relativePath] {
                guard let resolved = resolve(relative, from: startupWindowsPath(user)), same(resolved, local) else {
                    throw Refusal("the relative path \(relative) names another file than \(local)")
                }
            }
            if let folder = strings[Flag.workingDir], !folder.isEmpty {
                let own = local.split(separator: "\\").dropLast().joined(separator: "\\")
                guard isAbsolute(folder), within(folder, own) else { throw Refusal("the working folder \(folder) isn't the target's folder or under it") }
            }
            return Shortcut(target: local, arguments: strings[Flag.arguments] ?? "")
        }

        /// The ID list's path, and the path after each item, by the item's end offset from the list's start.
        func idList(from start: Int, to end: Int) throws -> (path: String, prefixes: [Int: String]) {
            guard end <= bytes.count, end - start >= 2, try u16(end - 2) == 0 else { throw Refusal("an ID list without its end") }
            var at = start
            var drive: String?
            var names: [String] = []
            var prefixes: [Int: String] = [:]
            var first = true
            func path() -> String? { drive.map { ([$0] + names).joined(separator: "\\") } }
            while at < end - 2 {
                let size = try u16(at)
                guard size >= 3, at + size <= end - 2 else { throw Refusal("an ID list item past its list") }
                let type = bytes[at + 2]
                if first {
                    guard type == 0x1F, size >= 20 else { throw Refusal("an ID list not rooted at My Computer or the profile") }
                    switch try guid(at + 4) {
                    case myComputer: break
                    case usersFiles:
                        drive = "C:"
                        names = ["Users", user]
                    default: throw Refusal("an ID list rooted at \(try guid(at + 4))")
                    }
                    first = false
                } else if type & 0x70 == 0x20 {
                    guard drive == nil, names.isEmpty else { throw Refusal("a drive item inside a path") }
                    let volume = try ascii(at + 3, end: at + size)
                    guard volume.count == 3, volume.hasSuffix("\\"), isDrive(String(volume.prefix(2))) else { throw Refusal("the drive item \(volume)") }
                    drive = String(volume.prefix(2))
                } else if [0x31, 0x32, 0x35, 0x36].contains(type) {
                    guard drive != nil else { throw Refusal("a file item before a drive") }
                    names.append(try fileItemName(at, size: size, itemStart: at, end: at + size))
                } else if type == 0x74 {
                    guard drive != nil else { throw Refusal("a delegate item before a drive") }
                    names.append(try delegateItemName(at, size: size))
                } else {
                    throw Refusal(String(format: "an ID list item of type 0x%02X", type))
                }
                at += size
                if let path = path() { prefixes[at - start] = path }
            }
            guard let whole = path(), !names.isEmpty else { throw Refusal("an ID list naming no file") }
            return (whole, prefixes)
        }

        /// A file-system item's long name (its `0xBEEF0004` block), its short name consistent with it (`isShortName`).
        /// The item's fields start at `at` (its size), the long-name block is searched from after its short name.
        func fileItemName(_ at: Int, size: Int, itemStart: Int, end: Int) throws -> String {
            let type = bytes[at + 2]
            let nameStart = at + 14
            let short: String
            var after: Int
            if type & 0x04 != 0 {
                short = try utf16(nameStart, end: end)
                after = nameStart + 2 * (short.utf16.count + 1)
            } else {
                short = try ascii(nameStart, end: end)
                after = nameStart + short.utf8.count + 1
            }
            if after % 2 != itemStart % 2 { after += 1 }
            let long = try longName(from: after, end: end)
            guard isName(long) else { throw Refusal("an item's long name \(long)") }
            guard isShortName(short, of: long) else { throw Refusal("an item's short name \(short) isn't \(long)'s") }
            return long
        }

        /// A delegate item (`CFSF`, the profile's file-system delegate): its inner file item's name.
        func delegateItemName(_ at: Int, size: Int) throws -> String {
            let end = at + size
            guard size >= 48 else { throw Refusal("a delegate item too short for a file's") }
            let sub = try u16(at + 4)
            guard Array(bytes[(at + 6)..<(at + 10)]) == Array("CFSF".utf8), sub >= 4, at + 6 + sub + 32 <= end else { throw Refusal("a delegate item that isn't a file's") }
            let inner = at + 10
            let innerSize = try u16(inner)
            guard innerSize >= 15, inner + innerSize <= at + 6 + sub, [0x31, 0x32, 0x35, 0x36].contains(bytes[inner + 2]) else {
                throw Refusal("a delegate item's inner item")
            }
            guard try guid(at + 6 + sub) == delegateItem, try guid(at + 22 + sub) == usersFilesDelegate else {
                throw Refusal("a delegate item of another folder (\(try guid(at + 22 + sub)))")
            }
            // The short name is the inner item's; the long name is in the blocks after the two GUIDs.
            let type = bytes[inner + 2]
            let short = type & 0x04 != 0 ? try utf16(inner + 14, end: inner + innerSize) : try ascii(inner + 14, end: inner + innerSize)
            let long = try longName(from: at + 38 + sub, end: end)
            guard isName(long), isShortName(short, of: long) else { throw Refusal("a delegate item's names \(short), \(long)") }
            return long
        }

        /// The long name in the first `0xBEEF0004` block at or after `from`, before `end`.
        func longName(from: Int, end: Int) throws -> String {
            var at = from
            while at + 8 <= end {
                if try u32(at + 4) == 0xBEEF_0004 {
                    let size = try u16(at), version = try u16(at + 2)
                    guard size >= 8, at + size <= end else { throw Refusal("a long-name block past its item") }
                    let offset: Int
                    switch version {
                    case 3: offset = 20
                    case 7: offset = 38
                    case 8: offset = 42
                    case 9: offset = 46
                    default: throw Refusal("a long-name block of version \(version)")
                    }
                    return try utf16(at + offset, end: at + size)
                }
                at += 2
            }
            throw Refusal("an item without its long name")
        }

        /// The link info's local path (`LocalBasePath` + `CommonPathSuffix`) on a fixed drive; a network path, when
        /// there is one, only to this machine's share named as the local base's last folder; the Unicode forms, when
        /// there are any, the same.
        func linkInfo(_ at: Int, size: Int) throws -> String {
            let end = at + size
            let header = try int(at + 4), flags = try u32(at + 8)
            guard header == 0x1C || header >= 0x24, flags & 0x1 != 0, flags & ~UInt32(0x3) == 0 else { throw Refusal("link info without a local path") }
            let volume = at + (try int(at + 12)), base = at + (try int(at + 16)), network = try int(at + 20), suffixAt = at + (try int(at + 24))
            guard try u32(volume + 4) == 3 else { throw Refusal("a target that isn't on a fixed drive") }
            let localBase = try ascii(base, end: end), suffix = try ascii(suffixAt, end: end)
            let local = localBase + suffix
            if header >= 0x24 {
                let unicodeBase = try utf16(at + (try int(at + 28)), end: end), unicodeSuffix = try utf16(at + (try int(at + 32)), end: end)
                guard unicodeBase + unicodeSuffix == local else { throw Refusal("link info's two paths differ") }
            }
            if flags & 0x2 != 0 {
                let link = at + network
                let linkSize = try int(link), linkFlags = try u32(link + 4), nameOffset = try int(link + 8)
                guard link + linkSize <= end, linkFlags & 0x1 == 0, nameOffset == 0x14 else { throw Refusal("a network link with a device or Unicode names") }
                let net = try ascii(link + nameOffset, end: link + linkSize)
                let parts = net.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
                let share = localBase.split(separator: "\\").last.map(String.init) ?? ""
                guard parts.count == 4, parts[0].isEmpty, parts[1].isEmpty, !host.isEmpty, parts[2].lowercased() == host, same(parts[3], share) else {
                    throw Refusal("a network path \(net) to another machine or share")
                }
            }
            return local
        }

        /// The extra data blocks to their end, which is the file's: the known- and special-folder blocks' paths by
        /// their ID list offset. Only the blocks `read` takes.
        func extraData(from start: Int) throws -> [(String, Int)] {
            var at = start
            var folders: [(String, Int)] = []
            var unnamed: [Int] = []
            while true {
                let size = try int(at)
                if size < 4 {
                    guard size == 0, at + 4 == bytes.count else { throw Refusal("bytes after the last block") }
                    break
                }
                guard size >= 8, at + size <= bytes.count else { throw Refusal("a block past the file") }
                switch try u32(at + 4) {
                case 0xA000_0002, 0xA000_0003, 0xA000_0004, 0xA000_0007: break  // console, tracker, console code page, icon
                case 0xA000_0009: try propertyStore(at + 8, end: at + size)
                case 0xA000_0005:
                    guard size == 0x10 else { throw Refusal("a special folder block's size") }
                    let id = try u32(at + 8), offset = try int(at + 12)
                    if let path = specialFolder(id, user: user) { folders.append((path, offset)) } else if id == 0xFFFF_FFFF { unnamed.append(offset) } else {
                        throw Refusal("a special folder block for folder \(id)")
                    }
                case 0xA000_000B:
                    guard size == 0x1C else { throw Refusal("a known folder block's size") }
                    let id = try guid(at + 8)
                    guard let path = knownFolder(id, user: user) else { throw Refusal("a known folder block for \(id)") }
                    folders.append((path, try int(at + 24)))
                default:
                    throw Refusal(String(format: "a block 0x%08X that can name another target", try u32(at + 4)))
                }
                at += size
            }
            // A special folder block that names no folder only beside a known folder block at the same place.
            for offset in unnamed where !folders.contains(where: { $0.1 == offset }) { throw Refusal("a special folder block that names no folder") }
            return folders
        }

        /// A property store's storages, none of the link-target properties.
        func propertyStore(_ start: Int, end: Int) throws {
            var at = start
            while at + 4 <= end {
                let size = try int(at)
                if size == 0 { return }
                guard size >= 24, at + size <= end, try u32(at + 4) == 0x5350_5331 else { throw Refusal("a property store out of form") }
                guard try guid(at + 8) != linkProperties else { throw Refusal("a property store holding the link's target") }
                at += size
            }
            throw Refusal("a property store without its end")
        }

        /// `relative` (`..` and names, by backslashes) from the Windows folder `folder`.
        func resolve(_ relative: String, from folder: String) -> String? {
            var parts = folder.split(separator: "\\").map(String.init)
            for part in relative.split(separator: "\\", omittingEmptySubsequences: false).map(String.init) {
                switch part {
                case ".": continue
                case "..":
                    guard parts.count > 1 else { return nil }
                    parts.removeLast()
                default:
                    guard isName(part) else { return nil }
                    parts.append(part)
                }
            }
            return parts.joined(separator: "\\")
        }
    }

    /// Whether `short` is `long` itself or an 8.3 alias Windows makes of it: the long name's first letters (spaces and
    /// dots but the last left out, upper case), up to four hex digits, `~` and a number, and its extension's first
    /// three letters.
    static func isShortName(_ short: String, of long: String) -> Bool {
        if same(short, long) { return true }
        let upper = long.uppercased()
        let dot = upper.lastIndex(of: ".")
        let base = (dot.map { String(upper[..<$0]) } ?? upper).filter { $0 != " " && $0 != "." }
        let ext = dot.map { String(upper[upper.index(after: $0)...]).filter { $0 != " " }.prefix(3) }.map(String.init) ?? ""
        let shortUpper = short.uppercased()
        let shortDot = shortUpper.lastIndex(of: ".")
        let shortBase = shortDot.map { String(shortUpper[..<$0]) } ?? shortUpper
        let shortExt = shortDot.map { String(shortUpper[shortUpper.index(after: $0)...]) } ?? ""
        guard shortExt == ext, shortBase.count <= 8, let tilde = shortBase.lastIndex(of: "~") else { return false }
        let number = shortBase[shortBase.index(after: tilde)...]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return false }
        let head = String(shortBase[..<tilde])
        let replaced = String(base.map { "+,;=[]".contains($0) ? "_" : $0 })
        // The long name's first letters, then (when Windows hashed the name) up to four hex digits.
        for kept in stride(from: min(6, head.count), through: 1, by: -1) {
            let prefix = String(head.prefix(kept)), rest = head.dropFirst(kept)
            if replaced.hasPrefix(prefix), rest.count <= 4, rest.allSatisfy(\.isHexDigit) { return true }
        }
        return false
    }
}
