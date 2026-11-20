import Foundation
import Testing
@testable import VibeCore

/// The user's known Startup shortcuts (`StartupShortcuts`, 2026-11-20): an app that rewrites its own shortcut in the
/// Windows Startup folder at each sign-in, with the same target, holds nothing once the user's list names it; a
/// same-named shortcut pointing anywhere else, any other entry, and any part of a shortcut that could run something else
/// are held as ever. Every shortcut here is built by `Link`, every folder is under a scratch root (never `/mnt/c`).
struct StartupShortcutsTests {
    let temp = Scratch()

    static let user = "someone"
    static let target = #"C:\Users\someone\AppData\Local\Dictate\Dictate.exe"#

    // MARK: A shortcut, built

    /// A shell link as Windows writes an app's Startup shortcut: rooted at the user's profile with a known folder block
    /// (or at My Computer and a drive), its link info's local path with a network path to this machine's share, its
    /// relative path, working folder and icon. Each field can be bent for a case.
    struct Link {
        var flags: UInt32 = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x40 | 0x80 | 0x4000
        var profileRoot = true
        /// The ID list's names under the root (the profile's, or the drive's), each with its short name.
        var names: [(short: String, long: String)] = [("AppData", "AppData"), ("Local", "Local"), ("Dictate", "Dictate"), ("DICTATE.EXE", "Dictate.exe")]
        var localBase = #"C:\Users\"#
        var suffix = #"someone\AppData\Local\Dictate\Dictate.exe"#
        var network: String? = #"\\HOST\Users"#
        var relative: String? = #"..\..\..\..\..\..\Local\Dictate\Dictate.exe"#
        var workingDir: String? = #"C:\Users\someone\AppData\Local\Dictate\app-1.0"#
        var arguments: String?
        var icon = #"C:\Users\someone\AppData\Local\Dictate\app-1.0\Dictate.exe"#
        var knownFolder: (guid: String, offset: Int)? = ("F3CE0F7C-4901-4ACC-8648-D5D44B04EF8F", 20)
        var specialFolder: (id: UInt32, offset: Int)? = (0xFFFF_FFFF, 20)
        var extraBlocks: [[UInt8]] = []
        var trailing: [UInt8] = []

        init(host: String) { network = #"\\"# + host.uppercased() + #"\Users"# }

        static func u16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        static func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * UInt32($0)) & 0xFF) } }
        static func guid(_ text: String) -> [UInt8] {
            let hex = text.replacingOccurrences(of: "-", with: "")
            let b = stride(from: 0, to: 32, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }
            return [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + b[8...]
        }
        static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }
        static func utf16(_ text: String, terminated: Bool = true) -> [UInt8] {
            text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + (terminated ? [0, 0] : [])
        }

        /// A long-name block (`0xBEEF0004`, version 9).
        static func longBlock(_ long: String) -> [UInt8] {
            let body = u32(0xBEEF_0004) + [UInt8](repeating: 0, count: 8) + u16(0x2E) + [UInt8](repeating: 0, count: 18) + u16(0)
                + [UInt8](repeating: 0, count: 8) + utf16(long) + u16(0x14)
            return u16(body.count + 4) + u16(9) + body
        }

        static func fileItem(_ short: String, _ long: String, directory: Bool) -> [UInt8] {
            var body: [UInt8] = [directory ? 0x31 : 0x32, 0] + u32(0) + u32(0) + u16(directory ? 0x10 : 0x20) + ascii(short)
            if body.count % 2 == 1 { body.append(0) }
            body += longBlock(long)
            return u16(body.count + 2) + body
        }

        /// The profile's file-system delegate item (`CFSF`) for `long`.
        static func delegateItem(_ short: String, _ long: String) -> [UInt8] {
            var inner: [UInt8] = [0x31, 0] + u32(0) + u32(0) + u16(0x10) + ascii(short)
            if inner.count % 2 == 1 { inner.append(0) }
            inner = u16(inner.count + 2) + inner
            let sub = Array("CFSF".utf8) + inner + [0, 0]
            let body: [UInt8] = [0x74, 0] + u16(sub.count) + sub + guid(StartupShortcuts.delegateItem) + guid(StartupShortcuts.usersFilesDelegate)
                + longBlock(long)
            return u16(body.count + 2) + body
        }

        var bytes: Data {
            var out = Self.u32(0x4C) + Self.guid(StartupShortcuts.shellLinkCLSID) + Self.u32(flags) + Self.u32(0x20)
            out += [UInt8](repeating: 0, count: 24) + Self.u32(0) + Self.u32(0) + Self.u32(1) + Self.u16(0) + [UInt8](repeating: 0, count: 10)
            // The ID list.
            var ids: [UInt8]
            if profileRoot {
                ids = Self.u16(20) + [0x1F, 0x49] + Self.guid(StartupShortcuts.usersFiles)
                for (index, name) in names.enumerated() {
                    ids += index == 0 ? Self.delegateItem(name.short, name.long) : Self.fileItem(name.short, name.long, directory: index < names.count - 1)
                }
            } else {
                ids = Self.u16(20) + [0x1F, 0x50] + Self.guid(StartupShortcuts.myComputer)
                let volume: [UInt8] = [0x2F] + Self.ascii(#"C:\"#) + [UInt8](repeating: 0, count: 15)
                ids += Self.u16(volume.count + 2) + volume
                for (index, name) in names.enumerated() { ids += Self.fileItem(name.short, name.long, directory: index < names.count - 1) }
            }
            ids += Self.u16(0)
            out += Self.u16(ids.count) + ids
            // The link info.
            let volume = Self.u32(0x11) + Self.u32(3) + Self.u32(0x1234) + Self.u32(0x10) + [0]
            let base = Self.ascii(localBase)
            let link: [UInt8] = network.map { net in
                let name = Self.ascii(net)
                return Self.u32(UInt32(0x14 + name.count)) + Self.u32(0x2) + Self.u32(0x14) + Self.u32(0) + Self.u32(0x20000) + name
            } ?? []
            let tail = Self.ascii(suffix)
            let volumeAt = 0x1C, baseAt = volumeAt + volume.count, linkAt = baseAt + base.count, suffixAt = linkAt + link.count
            let info = Self.u32(0x1C) + Self.u32(network == nil ? 1 : 3) + Self.u32(UInt32(volumeAt)) + Self.u32(UInt32(baseAt))
                + Self.u32(network == nil ? 0 : UInt32(linkAt)) + Self.u32(UInt32(suffixAt)) + volume + base + link + tail
            out += Self.u32(UInt32(info.count + 4)) + info
            // The strings.
            let strings: [(UInt32, String?)] = [(0x4, "Dictation"), (0x8, relative), (0x10, workingDir), (0x20, arguments), (0x40, icon)]
            for (flag, text) in strings where flags & flag != 0 {
                let text = text ?? ""
                out += Self.u16(text.utf16.count) + Self.utf16(text, terminated: false)
            }
            // The blocks.
            if let special = specialFolder { out += Self.u32(0x10) + Self.u32(0xA000_0005) + Self.u32(special.id) + Self.u32(UInt32(special.offset)) }
            if let known = knownFolder { out += Self.u32(0x1C) + Self.u32(0xA000_000B) + Self.guid(known.guid) + Self.u32(UInt32(known.offset)) }
            out += Self.u32(0x60) + Self.u32(0xA000_0003) + [UInt8](repeating: 0, count: 0x58)  // a tracker block
            for block in extraBlocks { out += block }
            out += Self.u32(0) + trailing
            return Data(out)
        }
    }

    var host: String { StartupShortcuts.hostName().isEmpty ? "node" : StartupShortcuts.hostName() }

    func read(_ link: Link) -> Result<StartupShortcuts.Shortcut, StartupShortcuts.Refusal> {
        StartupShortcuts.read(link.bytes, user: Self.user, host: host)
    }

    // MARK: Reading

    @Test func anAppsStartupShortcutIsReadToItsOneTarget() throws {
        var link = Link(host: host)
        #expect(try read(link).get() == .init(target: Self.target, arguments: ""))
        link.arguments = "--minimized"
        link.flags |= 0x20
        #expect(try read(link).get() == .init(target: Self.target, arguments: "--minimized"))
        // Rooted at My Computer and a drive, with no network path, relative path or blocks.
        var plain = Link(host: host)
        plain.profileRoot = false
        plain.names = [("Users", "Users"), ("someone", "someone"), ("AppData", "AppData"), ("Local", "Local"), ("Dictate", "Dictate"), ("DICTATE.EXE", "Dictate.exe")]
        plain.network = nil
        plain.knownFolder = nil
        plain.specialFolder = nil
        #expect(try read(plain).get() == .init(target: Self.target, arguments: ""))
    }

    /// Every part Windows may take the target from names the same program, or the shortcut isn't one the rule takes.
    @Test(arguments: [
        "id list elsewhere", "link info elsewhere", "relative elsewhere", "working folder elsewhere", "short name of another",
        "network to another machine", "network to another share", "environment target", "darwin", "shim", "link to link",
        "unknown block", "vista id list", "link target properties", "known folder elsewhere", "known folder unknown",
        "special folder alone", "bytes after the end", "no link info", "not a link",
    ])
    func aPartThatCouldRunSomethingElseIsRefused(bend: String) {
        var link = Link(host: host)
        switch bend {
        case "id list elsewhere": link.names[3] = ("EVIL.EXE", "Evil.exe")
        case "link info elsewhere": link.suffix = #"someone\Downloads\Dictate.exe"#
        case "relative elsewhere": link.relative = #"..\..\..\..\..\..\..\Downloads\Dictate.exe"#
        case "working folder elsewhere": link.workingDir = #"C:\Users\someone\Downloads"#
        case "short name of another": link.names[2] = ("EVIL~1", "Dictate")
        case "network to another machine": link.network = #"\\ELSEWHERE\Users"#
        case "network to another share": link.network = #"\\"# + host + #"\Shared"#
        case "environment target":
            link.flags |= 0x200
            link.extraBlocks = [Link.u32(0x314) + Link.u32(0xA000_0001) + [UInt8](repeating: 0, count: 0x30C)]
        case "darwin": link.flags |= 0x1000
        case "shim": link.flags |= 0x20000
        case "link to link": link.flags |= 0x800000
        case "unknown block": link.extraBlocks = [Link.u32(0x10) + Link.u32(0xA000_00FF) + Link.u32(0) + Link.u32(0)]
        case "vista id list": link.extraBlocks = [Link.u32(0x0A) + Link.u32(0xA000_000C) + Link.u16(0)]
        case "link target properties":
            let storage = Link.u32(24) + Link.u32(0x5350_5331) + Link.guid(StartupShortcuts.linkProperties)
            link.extraBlocks = [Link.u32(UInt32(8 + storage.count + 4)) + Link.u32(0xA000_0009) + storage + Link.u32(0)]
        case "known folder elsewhere": link.knownFolder = ("F1B32785-6FBA-4FCF-9D55-7B8E7F157091", 20)  // LocalAppData, where the list has the profile
        case "known folder unknown": link.knownFolder = ("374DE290-123F-4565-9164-39C4925E467B", 20)  // Downloads
        case "special folder alone": link.knownFolder = nil
        case "bytes after the end": link.trailing = [1, 2, 3, 4]
        case "no link info": link.flags &= ~0x2
        default: link.flags = 0
        }
        guard case .failure(let refusal) = read(link) else {
            Issue.record("\(bend) was taken")
            return
        }
        #expect(!refusal.reason.isEmpty)
    }

    /// No cut of a shortcut is taken, and none crashes the read.
    @Test func everyCutOfAShortcutIsRefused() {
        let whole = Link(host: host).bytes
        for length in 0..<whole.count {
            if case .success = StartupShortcuts.read(whole.prefix(length), user: Self.user, host: host) { Issue.record("a cut at \(length) was taken") }
        }
    }

    @Test func shortNamesAreTheLongNamesOwn() {
        #expect(StartupShortcuts.isShortName("WISPRF~1.EXE", of: "Wispr Flow.exe"))
        #expect(StartupShortcuts.isShortName("WISPRF~1", of: "WisprFlow"))
        #expect(StartupShortcuts.isShortName("WI1A2B~1.EXE", of: "Wispr Flow.exe"))
        #expect(StartupShortcuts.isShortName("appdata", of: "AppData"))
        #expect(!StartupShortcuts.isShortName("EVIL~1.EXE", of: "Wispr Flow.exe"))
        #expect(!StartupShortcuts.isShortName("WISPRF~1.BAT", of: "Wispr Flow.exe"))
        #expect(!StartupShortcuts.isShortName("WISPRF~X.EXE", of: "Wispr Flow.exe"))
    }

    @Test func theListsLinesAreUserNameTargetAndArguments() {
        let text = """
            # known Startup shortcuts
            someone | Dictate.lnk | C:\\Users\\someone\\AppData\\Local\\Dictate\\Dictate.exe

            someone | Tray.lnk | C:\\Program Files\\Tray\\tray.exe | --quiet | --log=a|b
            someone | NoTarget.lnk
            someone | Relative.lnk | Tray\\tray.exe
            someone | NotALink.exe | C:\\x.exe
            some/one | Bad.lnk | C:\\x.exe
            """
        #expect(StartupShortcuts.known(in: text) == [
            .init(user: "someone", name: "Dictate.lnk", target: Self.target),
            .init(user: "someone", name: "Tray.lnk", target: #"C:\Program Files\Tray\tray.exe"#, arguments: "--quiet | --log=a|b"),
        ])
        #expect(StartupShortcuts.known(in: text)[1].line == #"someone | Tray.lnk | C:\Program Files\Tray\tray.exe | --quiet | --log=a|b"#)
    }

    // MARK: The seal

    /// A scratch root with `someone`'s Startup folder holding the app's shortcut and `desktop.ini`; the list, when
    /// given, where the seal reads it under that root (the account's home under it).
    func startup(list: String?) throws -> (root: String, folder: ConfigSeal.Watched) {
        let root = temp.url("outside-\(UUID().uuidString.prefix(8))").path
        let name = "/mnt/c/Users/\(Self.user)/" + LinuxSealList.windowsStartup
        try FileManager.default.createDirectory(atPath: root + name, withIntermediateDirectories: true)
        try Link(host: host).bytes.write(to: URL(fileURLWithPath: root + name + "/Dictate.lnk"))
        try "[.ShellClassInfo]\n".write(toFile: root + name + "/desktop.ini", atomically: false, encoding: .utf8)
        if let list {
            let home = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) })
            let path = root + home + "/" + StartupShortcuts.listFile
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try list.write(toFile: path, atomically: false, encoding: .utf8)
        }
        return (root, ConfigSeal.Watched(name: name, path: root + name, kind: .listing))
    }

    /// The app's rewrite: removed and written again, its working folder and icon at a new version.
    func rewrite(_ folder: ConfigSeal.Watched, _ change: (inout Link) -> Void = { _ in }) throws {
        let path = folder.path + "/Dictate.lnk"
        try FileManager.default.removeItem(atPath: path)
        var link = Link(host: host)
        link.workingDir = #"C:\Users\someone\AppData\Local\Dictate\app-2.0"#
        link.icon = #"C:\Users\someone\AppData\Local\Dictate\app-2.0\Dictate.exe"#
        change(&link)
        try link.bytes.write(to: URL(fileURLWithPath: path))
    }

    static let line = "someone | Dictate.lnk | C:\\Users\\someone\\AppData\\Local\\Dictate\\Dictate.exe\n"

    @Test(LinuxSealListTests.linux) func aKnownShortcutRewrittenWithTheSameTargetHoldsNothing() throws {
        let (_, folder) = try startup(list: Self.line)
        let sealed = try #require(ConfigSeal.fingerprint(folder))
        try rewrite(folder)
        #expect(ConfigSeal.fingerprint(folder) == sealed)
        try rewrite(folder)
        #expect(ConfigSeal.fingerprint(folder) == sealed)
    }

    /// Without the list, or with a line for another shortcut or user, the rewrite is held as ever.
    @Test(LinuxSealListTests.linux, arguments: [nil, "someone | Other.lnk | C:\\x.exe\n", "another | Dictate.lnk | C:\\Users\\someone\\AppData\\Local\\Dictate\\Dictate.exe\n"])
    func anUnlistedShortcutsRewriteIsHeld(list: String?) throws {
        let (_, folder) = try startup(list: list)
        let sealed = try #require(ConfigSeal.fingerprint(folder))
        try rewrite(folder)
        #expect(ConfigSeal.fingerprint(folder) != sealed)
    }

    @Test(LinuxSealListTests.linux, arguments: ["elsewhere", "arguments", "id list", "another entry", "removed", "desktop.ini", "a folder", "a link"])
    func anythingElseInAKnownFolderIsHeld(change: String) throws {
        let (_, folder) = try startup(list: Self.line)
        let sealed = try #require(ConfigSeal.fingerprint(folder))
        let path = folder.path + "/Dictate.lnk"
        switch change {
        case "elsewhere": try rewrite(folder) { $0.suffix = #"someone\AppData\Local\Other\Dictate.exe"# }
        case "arguments": try rewrite(folder) { $0.flags |= 0x20; $0.arguments = "--evil" }
        case "id list": try rewrite(folder) { $0.names[2] = ("OTHER", "Other") }
        case "another entry": try Link(host: host).bytes.write(to: URL(fileURLWithPath: folder.path + "/Another.lnk"))
        case "removed": try FileManager.default.removeItem(atPath: path)
        case "desktop.ini": try "[.ShellClassInfo]\nIconFile=x\n".write(toFile: folder.path + "/desktop.ini", atomically: true, encoding: .utf8)
        case "a folder":
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        default:
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: folder.path + "/desktop.ini")
        }
        #expect(ConfigSeal.fingerprint(folder) != sealed, "\(change)")
    }

    /// The list is on the seal's list: a line added is a change of its own, held for the user's accept.
    @Test(LinuxSealListTests.linux) func theListIsSealedItself() throws {
        #expect(LinuxSealList.homeEntries.contains { $0.0 == StartupShortcuts.listFile && $0.1 == .file })
        let home = temp.url("seal-home").path
        let item = try #require(LinuxSealList.watched(home: home, uid: getuid()).first { $0.name == "~/" + StartupShortcuts.listFile })
        let before = ConfigSeal.fingerprint(item)
        try FileManager.default.createDirectory(atPath: home + "/.vibeswitcher/v2", withIntermediateDirectories: true)
        try Self.line.write(toFile: home + "/" + StartupShortcuts.listFile, atomically: false, encoding: .utf8)
        #expect(ConfigSeal.fingerprint(item) != before)
    }

    /// `config startup`'s report: each shortcut as the list's line, known or not, and why one can't be.
    @Test(LinuxSealListTests.linux) func theReportGivesEachShortcutsLine() throws {
        let (root, folder) = try startup(list: Self.line)
        try "not a link".write(toFile: folder.path + "/Broken.lnk", atomically: false, encoding: .utf8)
        let mounts = temp.url("mounts-\(UUID().uuidString.prefix(8))").path
        try #"C:\134 /mnt/c 9p rw 0 0"#.appending("\n").write(toFile: mounts, atomically: true, encoding: .utf8)
        let lines = StartupShortcuts.report(root: root, mounts: mounts, host: host)
        #expect(lines.count == 3, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("someone | Broken.lnk: the seal can't take it as known") }, "\(lines)")
        #expect(lines.contains("known:   " + Self.line.trimmingCharacters(in: .newlines)), "\(lines)")
    }
}
