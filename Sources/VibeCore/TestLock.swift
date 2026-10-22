import Darwin
import Foundation

/// At most N builds or test runs at a time on this Mac, for every project: the slots `vs-heavy` takes around the command
/// it's given (scripts/test.sh and scripts/build-app.sh around swift build and swift test, workers around a full suite
/// or a release build), which merge and an audit's shared run take around their commands too. Two suites side by side
/// starved each other and the benches (3–4 min each at load 30–50, measured 2026-10-21); a single slot let one
/// 38-minute pytest hold up every project's builds, suites and merges (2026-10-22). N is `slotsVariable`, the
/// workflow's heavy_slots for merge and audits, else the Mac's cores ÷ 4 (at least 1).
/// Slot 1 is a flock on `<directory>/test-build.lock`, slot k on `<directory>/test-build-k.lock`: the kernel lets go of
/// it when its holder exits, however it ends, so no stale slot outlives a run. `<slot>.holder` says who holds it, for
/// the one waiting and for status.
public struct TestLock: Sendable {
    /// Set to the held slot's path for the commands run under its holder: a script among them doesn't wait for its own
    /// ancestor (`vs-heavy` reads it).
    public static let heldVariable = "VIBESWITCHER_TEST_LOCK"
    /// Where the slots are kept instead of /private/tmp/vibeswitcher-<uid> (tests).
    public static let directoryVariable = "VIBESWITCHER_TEST_LOCK_DIR"
    /// How many slots, when set (a whole number above 0); else `defaultSlots`.
    public static let slotsVariable = "VIBESWITCHER_HEAVY_SLOTS"
    /// A slot held this long is "long" in status, the witness and a waiter's words: only said, never acted on.
    public static let longAfter: TimeInterval = 30 * 60

    public let directory: String
    public let slots: Int
    /// Slot 1's file (an older `vs-heavy` knows only this one).
    public var path: String { slotPath(1) }

    public init(directory: String, slots: Int = 1) {
        self.directory = directory
        self.slots = max(1, slots)
    }

    /// The same slots, `count` of them.
    public func with(slots count: Int) -> TestLock { TestLock(directory: directory, slots: count) }

    /// Slot `index`'s file (from 1).
    public func slotPath(_ index: Int) -> String {
        (directory as NSString).appendingPathComponent(index == 1 ? "test-build.lock" : "test-build-\(index).lock")
    }

    /// Whether `path` is one of this folder's slots, whatever their number.
    public func isSlot(_ path: String) -> Bool {
        guard (path as NSString).deletingLastPathComponent == directory else { return false }
        let name = (path as NSString).lastPathComponent
        if name == "test-build.lock" { return true }
        guard name.hasPrefix("test-build-"), name.hasSuffix(".lock") else { return false }
        let number = name.dropFirst("test-build-".count).dropLast(".lock".count)
        return !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }

    /// The Mac's cores ÷ 4, at least 1: 3 on a 12-core Mac.
    public static var defaultSlots: Int { max(1, ProcessInfo.processInfo.processorCount / 4) }

    /// The count `environment` sets (`slotsVariable`), else `defaultSlots`.
    public static func slotCount(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        environment[slotsVariable].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil } ?? defaultSlots
    }

    /// `vs-heavy`, the command that runs its arguments under this lock, for any project (Resources/bin/vs-heavy in the
    /// repository): in the app bundle's Contents/Resources/bin, which every session the app starts has on its PATH.
    public static let command = "vs-heavy"

    /// The folder holding `vs-heavy` for a program at `executable` in the app bundle's Contents/MacOS (the session
    /// host); nil when there's none there (a `swift build`'s binaries).
    public static func commandFolder(besideExecutable executable: String) -> String? {
        let contents = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let folder = contents.appendingPathComponent("Resources/bin").path
        return FileManager.default.isExecutableFile(atPath: (folder as NSString).appendingPathComponent(command)) ? folder : nil
    }

    /// The sessions' environment `base` with `folder` first on its PATH (once): the login shell's path_helper keeps
    /// what PATH had after the system's folders, and the user's own startup files add to it.
    public static func sessionEnvironment(_ base: [String: String], adding folder: String?) -> [String: String] {
        guard let folder else { return base }
        var environment = base
        let rest = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init).filter { $0 != folder }
        environment["PATH"] = ([folder] + rest).joined(separator: ":")
        return environment
    }

    /// The Mac-wide slots (`slotCount` of them); nil when this process runs under a holder of one already
    /// (`heldVariable` names it).
    public static func standard(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> TestLock? {
        let lock = TestLock(directory: environment[directoryVariable] ?? "/private/tmp/vibeswitcher-\(getuid())", slots: slotCount(environment))
        return environment[heldVariable].map(lock.isSlot) == true ? nil : lock
    }

    /// A slot while it's held: let go with `release` (or when it goes).
    public final class Held: @unchecked Sendable {
        private var fd: Int32
        /// The slot's file.
        public let path: String
        init(fd: Int32, path: String) {
            self.fd = fd
            self.path = path
        }

        public func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }

        deinit { release() }
    }

    /// Who holds a slot, as its note says.
    public struct Holder: Equatable, Sendable {
        public var slot: Int
        /// The note's line ("pid 30098, scripts/test.sh in /Users/a/dev/p, since 02:53:22"); nil when there's none.
        public var note: String?
        /// When the note was written: when the slot was taken.
        public var since: Date?

        public init(slot: Int, note: String?, since: Date?) {
            self.slot = slot
            self.note = note
            self.since = since
        }

        /// The note's parts: "pid P, WHAT in DIR, since T" (vs-heavy's, merge's and audits'), or without " in DIR".
        private var parts: (pid: String, what: String, directory: String?)? {
            guard let note, let match = note.firstMatch(of: #/^pid (\d+), (.*?)(?: in (/.*))?, since [^,]*$/#) else { return nil }
            return (String(match.1), String(match.2), match.3.map(String.init))
        }

        /// The command (or what it said it is).
        public var what: String? { parts?.what }

        /// The project it runs for: the folder it ran in, or the repository a worktree of VibeSwitcher's belongs to.
        public var project: String? {
            guard var directory = parts?.directory ?? nil else { return nil }
            if let range = directory.range(of: "/.vibeswitcher/worktrees/") { directory = String(directory[..<range.lowerBound]) }
            return URL(fileURLWithPath: directory).lastPathComponent
        }

        public func held(now: Date = Date()) -> TimeInterval { since.map { max(0, now.timeIntervalSince($0)) } ?? 0 }
        public func isLong(now: Date = Date()) -> Bool { since != nil && held(now: now) >= TestLock.longAfter }

        /// "pid 30098, pytest -q in /Users/a/dev/TGE (TGE), for 38 min, long".
        public func text(now: Date = Date()) -> String {
            var text = parts.map { parts in
                "pid \(parts.pid), \(parts.what)" + (parts.directory.map { " in \($0) (\(project ?? "?"))" } ?? "")
            } ?? note ?? "a run that didn't say who it is"
            if since != nil {
                let seconds = Int(held(now: now))
                text += ", for " + (seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min") + (isLong(now: now) ? ", long" : "")
            }
            return text
        }

        /// Status's and the witness's words for a long one: "TGE (pytest -q) for 38 min".
        public func short(now: Date = Date()) -> String {
            "\(project ?? "a run") (\((what ?? note ?? "it didn't say what").prefix(80))) for \(Int(held(now: now)) / 60) min"
        }
    }

    /// "slot 1 held by pid 1, a in /r (r), for 3 min; slot 2 held by …".
    public static func text(_ holders: [Holder], now: Date = Date()) -> String {
        holders.isEmpty ? "nothing says who" : holders.map { "slot \($0.slot) held by \($0.text(now: now))" }.joined(separator: "; ")
    }

    /// How a wait for a slot ended.
    public enum Outcome {
        /// Taken: `waited` seconds, and who held every slot when it started waiting (empty when one was free).
        case held(Held, waited: TimeInterval, after: [Holder])
        /// Every slot still held, by `holders`, after `timeout`: nothing ran.
        case busy(holders: [Holder])
        case cancelled
        case failed(String)
    }

    /// Who holds slot `index`, as its note says (written when it was taken).
    public func holder(_ index: Int) -> Holder {
        let note = slotPath(index) + ".holder"
        let line = (try? String(contentsOfFile: note, encoding: .utf8))?.split(separator: "\n").first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let since = (try? FileManager.default.attributesOfItem(atPath: note))?[.modificationDate] as? Date
        return Holder(slot: index, note: line, since: line == nil ? nil : since)
    }

    /// The slots held now, with who holds them: a slot is tried (and let go at once), so a holder that died isn't
    /// counted, whatever its note says.
    public func holders() -> [Holder] {
        // Every slot there is: another project's heavy_slots may be more than this one's.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let highest = files.compactMap { name -> Int? in
            guard isSlot((directory as NSString).appendingPathComponent(name)) else { return nil }
            return name == "test-build.lock" ? 1 : Int(name.dropFirst("test-build-".count).dropLast(".lock".count))
        }.max() ?? 1
        return (1...max(slots, highest)).compactMap { index in
            let fd = open(slotPath(index), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                flock(fd, LOCK_UN)
                return nil
            }
            return holder(index)
        }
    }

    /// Waits for a free slot up to `timeout` (checking `cancel`), takes the first, and writes `what` (run in
    /// `directory`) as its holder. While it waits, `waiting` hears who holds them, at once and then every `every`.
    public func acquire(as what: String, in directory: String? = nil, timeout: TimeInterval, cancel: ShellCancel? = ShellCancel.current,
                        every: TimeInterval = 30, waiting: (([Holder], TimeInterval) -> Void)? = nil) -> Outcome {
        let folder = self.directory
        do { try VibePaths.ensurePrivate(URL(fileURLWithPath: folder, isDirectory: true)) } catch {
            return .failed("Couldn't make \(folder) for the test and build lock (\(error.localizedDescription)).")
        }
        // /private/tmp is everyone's: a folder someone else made there (or a link) isn't taken as this user's.
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            return .failed("\(folder) isn't a folder of yours: the test and build lock can't be kept there.")
        }
        var fds: [Int32] = []
        defer { fds.forEach { if $0 >= 0 { close($0) } } }
        for index in 1...slots {
            let fd = open(slotPath(index), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return .failed("Couldn't open \(slotPath(index)) (\(String(cString: strerror(errno)))).") }
            fds.append(fd)
        }
        let start = Date()
        var waitedFor: [Holder] = []
        var told: Date?
        while true {
            if let free = fds.firstIndex(where: { flock($0, LOCK_EX | LOCK_NB) == 0 }) {
                let fd = fds[free]
                fds[free] = -1
                let index = free + 1
                let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                let place = directory.map { " in \($0)" } ?? ""
                try? VibePaths.writePrivate(Data("pid \(getpid()), \(what)\(place), since \(stamp)\n".utf8),
                                            to: URL(fileURLWithPath: slotPath(index) + ".holder"))
                return .held(Held(fd: fd, path: slotPath(index)), waited: Date().timeIntervalSince(start), after: waitedFor)
            }
            if waitedFor.isEmpty { waitedFor = (1...slots).map(holder) }
            if cancel?.isCancelled == true { return .cancelled }
            let now = Date()
            if now.timeIntervalSince(start) >= timeout { return .busy(holders: (1...slots).map(holder)) }
            if let waiting, told.map({ now.timeIntervalSince($0) >= every }) ?? true {
                told = now
                waiting((1...slots).map(holder), now.timeIntervalSince(start))
            }
            usleep(useconds_t(min(500_000, max(10_000, every * 1_000_000 / 2))))
        }
    }
}
