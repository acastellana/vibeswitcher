import Foundation
import Testing
@testable import VibePlatform

// Whether this system keeps settings in a file of its own making (`FileSettings`), for the trait below. The Mac's
// store is `UserDefaults`, which Apple tests.
#if os(Linux)
private let hasFileSettings = true
#else
private let hasFileSettings = false
#endif

/// A value shared with a thread a test starts.
private final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func change(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }
}

/// `Platform.settings(domain:)` as the shared code uses it, on the system's own store: a domain that is a path in the
/// test's scratch folder, which both systems keep in the file at that path (so nothing reaches ~/Library/Preferences
/// on the Mac, nor VibeSwitcher's folder on Linux), and which goes with the folder.
struct SettingsTests {
    @Test func aStoreNamedByAScratchPathKeepsWhatTheSharedCodeGivesIt() throws {
        let folder = try TestScriptLinuxTests.scratch("settings")
        defer { try? FileManager.default.removeItem(at: folder) }
        let domain = folder.appendingPathComponent("defaults").path
        let store = try #require(Platform.settings(domain: domain))
        let keys = ["claudeCommand", "letAgentsOpenShells", "leadMail", "pausedSessions"]
        defer { keys.forEach { store.set(nil, forKey: $0) } }

        // Nothing set: the answers the callers' defaults rest on.
        #expect(store.object(forKey: "leadMail") == nil)
        #expect(store.string(forKey: "claudeCommand") == nil)
        #expect(store.bool(forKey: "letAgentsOpenShells") == false)
        #expect(store.dictionary(forKey: "pausedSessions") == nil)

        // A second and a fraction, as `PauseStore` keeps a pause's end, and its "until resumed".
        let until = Date(timeIntervalSince1970: 1_800_000_000.25)
        store.set("claude --dangerously-skip-permissions", forKey: "claudeCommand")
        store.set(true, forKey: "letAgentsOpenShells")
        store.set(false, forKey: "leadMail")
        store.set(["proc:1": until, "session:a": Date.distantFuture], forKey: "pausedSessions")

        #expect(store.string(forKey: "claudeCommand") == "claude --dangerously-skip-permissions")
        #expect(store.bool(forKey: "letAgentsOpenShells") == true)
        // `LeadMail.isOn`'s read, and `PauseStore.init`'s.
        #expect((store.object(forKey: "leadMail") as? Bool) == false)
        #expect((store.dictionary(forKey: "pausedSessions") as? [String: Date]) == ["proc:1": until, "session:a": .distantFuture])
        #expect(store.string(forKey: "pausedSessions") == nil)

        store.set(nil, forKey: "claudeCommand")
        #expect(store.string(forKey: "claudeCommand") == nil)
        #expect(store.object(forKey: "claudeCommand") == nil)
        #expect(store.bool(forKey: "letAgentsOpenShells") == true)

        #if os(Linux)
        // The file is the domain's path with `.plist` after it, as the Mac names a suite's that is a path.
        #expect(FileManager.default.fileExists(atPath: domain + ".plist"))
        // While this store is held, the same domain is the same store.
        #expect(Platform.settings(domain: domain) === store)
        #endif
    }

    @Test func theAppsDomainIsTheDefaultAndAnEmptyOneIsNoStore() {
        #expect(Platform.appSettingsDomain == "dev.vibeswitcher.VibeSwitcher")
        #if os(Linux)
        #expect(Platform.settings(domain: "") == nil)
        // Read only: the run's scratch folder is every test's.
        let app = Platform.settings()
        #expect(app != nil)
        #expect(app === Platform.settings(domain: Platform.appSettingsDomain))
        #expect(app === Platform.standardSettings)
        #endif
    }
}

/// Linux's settings file: what a second store, another process and a reader in the middle of a write see of it.
/// Each store is on a file of the test's own.
@Suite(.enabled(if: hasFileSettings, "the Mac keeps settings in UserDefaults"))
struct FileSettingsTests {
    #if os(Linux)
    static func scratchFile() throws -> (folder: URL, file: URL) {
        let folder = try TestScriptLinuxTests.scratch("settings-file")
        return (folder, folder.appendingPathComponent("settings.plist"))
    }

    static func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        try #require(stat(url.path, &info) == 0, "stat \(url.path): errno \(errno)")
        return info.st_mode & 0o7777
    }

    /// The file as another program reads it: opened, read to its end, closed. nil when it isn't there.
    static func bytes(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return FileSettings.contents(fd, limit: Int.max)
    }

    @Test func aStringABoolADateInADictionaryAndARemovalSurviveASecondStore() throws {
        let (folder, file) = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let until = Date(timeIntervalSince1970: 1_800_000_000.123456)
        let first = FileSettings(file: file)
        first.set("codex --full-auto", forKey: "codexCommand")
        first.set(true, forKey: "letAgentsOpenShells")
        first.set(["proc:41": until, "session:b": Date.distantFuture], forKey: "pausedSessions")
        first.set("going", forKey: "gone")
        first.set(7, forKey: "count")
        first.set(Data([0, 1, 254, 255]), forKey: "bytes")
        first.set(["a", 2, false] as [Any], forKey: "list")
        first.set(nil, forKey: "gone")

        for store in [FileSettings(file: file), first] {
            #expect(store.string(forKey: "codexCommand") == "codex --full-auto")
            #expect(store.bool(forKey: "letAgentsOpenShells") == true)
            #expect((store.object(forKey: "letAgentsOpenShells") as? Bool) == true)
            #expect((store.dictionary(forKey: "pausedSessions") as? [String: Date]) == ["proc:41": until, "session:b": .distantFuture])
            #expect(store.object(forKey: "gone") == nil)
            #expect(store.string(forKey: "gone") == nil)
            #expect((store.object(forKey: "count") as? Int) == 7)
            // As `UserDefaults` reads a number: its digits, and true when it isn't 0.
            #expect(store.string(forKey: "count") == "7")
            #expect(store.bool(forKey: "count") == true)
            #expect((store.object(forKey: "bytes") as? Data) == Data([0, 1, 254, 255]))
            let list = try #require(store.object(forKey: "list") as? [Any])
            #expect(list.count == 3 && (list[0] as? String) == "a" && (list[1] as? Int) == 2 && (list[2] as? Bool) == false)
            #expect(store.dictionary(forKey: "codexCommand") == nil)
            #expect(store.bool(forKey: "never-set") == false)
        }
        // The file is a property list any reader of them reads.
        let read = try PropertyListSerialization.propertyList(from: try #require(Self.bytes(file)), options: [], format: nil)
        #expect(((read as? [String: Any])?.keys.sorted() ?? []) == ["bytes", "codexCommand", "count", "letAgentsOpenShells", "list", "pausedSessions"])
    }

    @Test func theFileIsPrivateAndSoIsTheFolderMadeForIt() throws {
        let scratch = try TestScriptLinuxTests.scratch("settings-file")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("made/.vibeswitcher", isDirectory: true)
        let file = folder.appendingPathComponent("settings.plist")
        let store = FileSettings(file: file)
        // A read makes nothing.
        #expect(store.object(forKey: "claudeCommand") == nil)
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("made").path))

        store.set("claude", forKey: "claudeCommand")
        store.set("codex", forKey: "codexCommand")
        #expect(try Self.mode(file) == 0o600)
        #expect(try Self.mode(folder) == 0o700)
        #expect(try Self.mode(scratch.appendingPathComponent("made")) == 0o700)
        // Nothing of a write is left beside the file but its lock.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["settings.plist", "settings.plist.lock"])
        #expect(try Self.mode(folder.appendingPathComponent("settings.plist.lock")) == 0o600)

        // A folder that is there keeps the mode it has.
        let open = scratch.appendingPathComponent("open", isDirectory: true)
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        #expect(chmod(open.path, 0o755) == 0)
        FileSettings(file: open.appendingPathComponent("settings.plist")).set(true, forKey: "leadMail")
        #expect(try Self.mode(open) == 0o755)
        #expect(try Self.mode(open.appendingPathComponent("settings.plist")) == 0o600)
    }

    /// Readers that open the file at any moment of 200 writes have a whole property list, the one before a write or
    /// the one after: never an empty file, part of one, or none. They read as fast as they can (the list is small,
    /// so most of a reader's time is spent with the file open), and a write in place is caught within a few writes.
    @Test func aReaderNeverSeesAWriteHalfDone() throws {
        let (folder, file) = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let filler = String(repeating: "settings ", count: 200)
        let store = FileSettings(file: file)
        store.set(filler, forKey: "filler")
        store.set(-1, forKey: "count")

        let readers = 3
        let stop = Shared(false), reads = Shared(0), broken = Shared([String]())
        let reading = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        for _ in 0..<readers {
            Thread.detachNewThread {
                var whole = 0, first = true
                while !stop.get() {
                    let bytes = Self.bytes(file)
                    let list = bytes.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) } as? [String: Any]
                    if let count = list?["count"] as? Int, (-1..<200).contains(count), (list?["filler"] as? String) == filler {
                        whole += 1
                    } else {
                        broken.change { if $0.count < 5 { $0.append(bytes.map { "\($0.count) bytes" } ?? "no file") } }
                    }
                    if first {
                        first = false
                        reading.signal()
                    }
                }
                reads.change { $0 += whole }
                finished.signal()
            }
        }
        for _ in 0..<readers { reading.wait() }
        for count in 0..<200 { store.set(count, forKey: "count") }
        stop.change { $0 = true }
        for _ in 0..<readers { finished.wait() }

        #expect(broken.get() == [], "a reader saw something that wasn't a whole list (\(reads.get()) whole ones)")
        #expect(reads.get() > 0)
        #expect((FileSettings(file: file).object(forKey: "count") as? Int) == 199)
    }

    @Test func aSecondStoreSeesTheFirstsLaterWrite() throws {
        let (folder, file) = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = FileSettings(file: file), second = FileSettings(file: file)
        #expect(second.string(forKey: "claudeCommand") == nil)
        first.set("claude", forKey: "claudeCommand")
        #expect(second.string(forKey: "claudeCommand") == "claude")
        // A write of the same length, given the time of the file it replaced to the nanosecond (two writes inside
        // one tick of the file system's clock have that by themselves): only the file itself is another.
        let before = try StatTests.status(file.path)
        first.set("clause", forKey: "claudeCommand")
        var times = [before.st_mtim, before.st_mtim]
        try #require(utimensat(AT_FDCWD, file.path, &times, 0) == 0, "utimensat: errno \(errno)")
        let after = try StatTests.status(file.path)
        #expect(after.st_mtim.tv_sec == before.st_mtim.tv_sec && after.st_mtim.tv_nsec == before.st_mtim.tv_nsec)
        #expect(after.st_size == before.st_size)
        #expect(after.st_ino != before.st_ino)
        #expect(second.string(forKey: "claudeCommand") == "clause")
        // Several writes between two reads: the last one is read.
        for round in 0..<20 {
            first.set("clause", forKey: "claudeCommand")
            first.set("round-\(10 + round)", forKey: "claudeCommand")
            #expect(second.string(forKey: "claudeCommand") == "round-\(10 + round)")
        }
        first.set("claude", forKey: "claudeCommand")
        // And back: each has what the other set last, and keeps the other's keys when it sets its own.
        second.set(true, forKey: "leadMail")
        first.set("codex", forKey: "codexCommand")
        for store in [first, second] {
            #expect(store.bool(forKey: "leadMail") == true)
            #expect(store.string(forKey: "claudeCommand") == "claude")
            #expect(store.string(forKey: "codexCommand") == "codex")
        }
        first.set(nil, forKey: "leadMail")
        #expect(second.object(forKey: "leadMail") == nil)

        // A program that writes the file in place (the same file, a later time or another length) is seen too.
        let edited = try PropertyListSerialization.data(fromPropertyList: ["claudeCommand": "claude --edited-by-hand"], format: .xml, options: 0)
        let fd = open(file.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        try #require(fd >= 0)
        #expect(FileSettings.writeAll(fd, edited))
        close(fd)
        for store in [first, second] {
            #expect(store.string(forKey: "claudeCommand") == "claude --edited-by-hand")
            #expect(store.string(forKey: "codexCommand") == nil)
        }
        // The file gone: empty again.
        try FileManager.default.removeItem(at: file)
        #expect(first.string(forKey: "claudeCommand") == nil)
        #expect(second.object(forKey: "claudeCommand") == nil)
    }

    /// A file that is no list of settings (cut short, plain text, a list that isn't a dictionary) reads as empty and
    /// stays as it is however often it's read; the first `set` keeps it beside the new list.
    @Test func aCorruptFileReadsAsEmptyAndIsKeptAside() throws {
        let whole = try PropertyListSerialization.data(fromPropertyList: ["claudeCommand": "claude", "leadMail": false], format: .binary, options: 0)
        let list = try PropertyListSerialization.data(fromPropertyList: ["claude", "codex"], format: .binary, options: 0)
        for garbage in [whole.prefix(whole.count / 2), Data("not a property list".utf8), list, Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30, 0xFF])] {
            let (folder, file) = try Self.scratchFile()
            defer { try? FileManager.default.removeItem(at: folder) }
            try garbage.write(to: file)
            let store = FileSettings(file: file)
            #expect(store.object(forKey: "claudeCommand") == nil)
            #expect(store.string(forKey: "claudeCommand") == nil)
            #expect(store.bool(forKey: "leadMail") == false)
            #expect(store.dictionary(forKey: "pausedSessions") == nil)
            #expect(Self.bytes(file) == garbage, "a read changed the file")
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["settings.plist"])

            store.set("codex", forKey: "codexCommand")
            #expect(Self.bytes(folder.appendingPathComponent("settings.plist.corrupt")) == garbage)
            for reader in [store, FileSettings(file: file)] {
                #expect(reader.string(forKey: "codexCommand") == "codex")
                #expect(reader.object(forKey: "claudeCommand") == nil)
            }
        }
    }

    /// A file put right by hand is read again: a corrupt file isn't remembered as empty.
    @Test func aCorruptFilePutRightIsRead() throws {
        let (folder, file) = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{{{".utf8).write(to: file)
        let store = FileSettings(file: file)
        #expect(store.object(forKey: "claudeCommand") == nil)
        try PropertyListSerialization.data(fromPropertyList: ["claudeCommand": "claude"], format: .xml, options: 0).write(to: file, options: .atomic)
        #expect(store.string(forKey: "claudeCommand") == "claude")
        // An empty file is an empty list, and a `set` on it keeps nothing aside.
        try Data().write(to: file, options: .atomic)
        #expect(store.object(forKey: "claudeCommand") == nil)
        store.set(true, forKey: "leadMail")
        #expect(store.bool(forKey: "leadMail") == true)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".corrupt"))
    }

    /// What can't be read (here a folder where the file should be) reads as empty and is never written over: a `set`
    /// lasts in the store that made it, and the file is read once it can be.
    @Test func whatCannotBeReadIsLeftAsItIs() throws {
        let (folder, file) = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: file.appendingPathComponent("inside"), withIntermediateDirectories: true)
        let store = FileSettings(file: file)
        #expect(store.object(forKey: "claudeCommand") == nil)
        store.set("claude", forKey: "claudeCommand")
        store.set(true, forKey: "leadMail")
        #expect(store.string(forKey: "claudeCommand") == "claude")
        #expect(store.bool(forKey: "leadMail") == true)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathComponent("inside").path))
        #expect(!FileManager.default.fileExists(atPath: file.path + ".corrupt"))
        #expect(FileSettings(file: file).object(forKey: "claudeCommand") == nil)

        try FileManager.default.removeItem(at: file)
        try PropertyListSerialization.data(fromPropertyList: ["codexCommand": "codex"], format: .binary, options: 0).write(to: file)
        #expect(store.string(forKey: "codexCommand") == "codex")
        #expect(store.object(forKey: "claudeCommand") == nil)

        // The same for a folder that can't be made: a file stands where it should be.
        let blocker = folder.appendingPathComponent("blocker")
        try Data("in the way".utf8).write(to: blocker)
        let blocked = FileSettings(file: blocker.appendingPathComponent("settings.plist"))
        #expect(blocked.object(forKey: "claudeCommand") == nil)
        blocked.set("claude", forKey: "claudeCommand")
        #expect(blocked.string(forKey: "claudeCommand") == "claude")
        #expect(Self.bytes(blocker) == Data("in the way".utf8))
    }

    /// A value no property list holds is refused, and what was there stays.
    @Test func aValueThatIsNoPropertyListIsRefused() throws {
        let (folder, file) = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSettings(file: file)
        store.set(URL(fileURLWithPath: "/tmp"), forKey: "place")
        #expect(store.object(forKey: "place") == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        store.set("claude", forKey: "claudeCommand")
        store.set(["inside": NSNull()], forKey: "claudeCommand")
        store.set([1: "numbered"], forKey: "claudeCommand")
        #expect(store.string(forKey: "claudeCommand") == "claude")
    }

    /// Two stores on one file, as two processes are, each setting keys of its own from several threads at once: every
    /// key is there at the end. Without the lock around a `set`, each would write its list over the other's.
    @Test func storesWritingAtOnceLoseNothing() throws {
        let (folder, file) = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stores = [FileSettings(file: file), FileSettings(file: file), FileSettings(file: file)]
        let writers = 6, each = 25
        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            let store = stores[writer % stores.count]
            for number in 0..<each {
                store.set(writer * 1_000 + number, forKey: "key-\(writer)-\(number)")
                // A read between the writes, as a caller's would come.
                _ = store.bool(forKey: "key-\(writer)-0")
            }
        }
        for store in stores + [FileSettings(file: file)] {
            for writer in 0..<writers {
                let values = (0..<each).map { store.object(forKey: "key-\(writer)-\($0)") as? Int }
                #expect(values == (0..<each).map { writer * 1_000 + $0 }, "writer \(writer)")
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["settings.plist", "settings.plist.lock"])
    }

    @Test func aDomainNamesItsFile() {
        func file(_ domain: String, _ variables: [String: String] = ["HOME": "/home/someone"]) -> String? {
            FileSettings.file(domain: domain, variable: { variables[$0] }, fallbackHome: "/fallback")?.path
        }
        #expect(file("dev.vibeswitcher.VibeSwitcher") == "/home/someone/.vibeswitcher/settings.plist")
        #expect(file("dev.vibeswitcher.tests") == "/home/someone/.vibeswitcher/settings-dev.vibeswitcher.tests.plist")
        #expect(file("a b/../c%") == "/home/someone/.vibeswitcher/settings-a%20b%2F..%2Fc%25.plist")
        #expect(file("naïve") == "/home/someone/.vibeswitcher/settings-na%C3%AFve.plist")
        #expect(file("/scratch/run/defaults") == "/scratch/run/defaults.plist")
        #expect(file("") == nil)
        // VibeSwitcher's folder, in VibeCore's order (`VibePaths.root`).
        #expect(file("dev.vibeswitcher.VibeSwitcher", ["VIBESWITCHER_HOME": "/own", "CFFIXED_USER_HOME": "/fixed", "HOME": "/home"]) == "/own/settings.plist")
        #expect(file("dev.vibeswitcher.VibeSwitcher", ["VIBESWITCHER_HOME": "relative", "CFFIXED_USER_HOME": "/fixed", "HOME": "/home"]) == "/fixed/.vibeswitcher/settings.plist")
        #expect(file("dev.vibeswitcher.VibeSwitcher", ["HOME": ""]) == "/fallback/.vibeswitcher/settings.plist")
        // The same folder the tests' own guard resolves (TestSupport.swift), for the run's real variables.
        let real = TestHome.root(variable: { name in getenv(name).map { String(cString: $0) } }, fallbackHome: NSHomeDirectory())
        #expect(FileSettings.file(domain: Platform.appSettingsDomain)?.path == real.appendingPathComponent("settings.plist").path)
    }

    /// A store nobody holds goes, and the file it kept open with it: a process that asks for many domains (a test
    /// run's scratch ones) doesn't run out of descriptors.
    @Test func aStoreNobodyHoldsIsLetGo() throws {
        let (folder, file) = try Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        weak var gone: FileSettings?
        do {
            let store = FileSettings.shared(file: file, keep: false)
            store.set(true, forKey: "leadMail")
            #expect(FileSettings.shared(file: file, keep: false) === store)
            gone = store
        }
        #expect(gone == nil)
        #expect(FileSettings.shared(file: file, keep: false).bool(forKey: "leadMail") == true)
    }
    #endif
}
