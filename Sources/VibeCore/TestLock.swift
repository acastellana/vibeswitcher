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
///
/// Waiters take slots first come, first served (flock has no queue: on 2026-10-22 a merge waited over 90 minutes for a
/// slot while pytests and merges arriving after it took it again and again). Each takes a number (a ticket) on
/// arriving and takes a slot only once no live ticket before it could take that one; `vs-heavy` keeps the same line:
/// - Taking a number: under a flock on `<directory>/queue.lock`, whose text is the last number given, the next is one
///   past that (or past the highest ticket there, if higher), and `<directory>/ticket-<n>` is created with O_EXCL and
///   O_EXLOCK, so it's never seen unlocked while its waiter lives. Numbers aren't given twice.
/// - A ticket's text is a holder's note ("pid P, WHAT in DIR, since T") and "slots N", the slots its waiter may take.
/// - Its waiter keeps it flocked while it waits, and removes it once it holds a slot or gives up. One that can be
///   flocked has no waiter (it died, however it ended): whoever finds it so removes it, and it's passed over.
/// - A waiter takes slot k only when no live ticket before its own has slots ≥ k: the first in line takes any of its
///   slots, and one behind a waiter with fewer slots takes the ones that waiter can't.
/// An older `vs-heavy` (or app) takes no ticket: it may take a slot ahead of the line, as before, but waits on nothing
/// in it, and holds a slot only while its command runs; so the line can be held up by one, never stuck.
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

    /// A waiter in line for a slot, as its ticket says.
    public struct Waiter: Equatable, Sendable {
        /// Its ticket's number: lower ones go first.
        public var number: Int
        /// The slots it may take (the ticket's "slots N"; any of them when it doesn't say).
        public var slots: Int
        /// Who it is, its ticket's note read as a holder's (slot 0); `since` is when it arrived.
        public var who: Holder

        public init(number: Int, slots: Int, who: Holder) {
            self.number = number
            self.slots = slots
            self.who = who
        }

        /// "merge of x (vibeswitcher)", or the note itself.
        public var name: String {
            guard let what = who.what else { return who.note ?? "a run that didn't say who it is" }
            return what + (who.project.map { " (\($0))" } ?? "")
        }
    }

    /// A place in line: "1st in line", "3rd in line, behind merge of a (alpha) and pytest -q (TGE)".
    public static func place(behind ahead: [Waiter]) -> String {
        let place = ahead.count + 1
        let suffix = (11...13).contains(place % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][place % 10] ?? "th"
        guard !ahead.isEmpty else { return "\(place)\(suffix) in line" }
        var names = ahead.prefix(3).map(\.name)
        if ahead.count > 3 { names.append("\(ahead.count - 3) more") }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "\(place)\(suffix) in line, behind " + list
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

    /// The line's lock, whose text is the last number given.
    public var queuePath: String { (directory as NSString).appendingPathComponent("queue.lock") }

    /// Ticket `number`'s file.
    public func ticketPath(_ number: Int) -> String { (directory as NSString).appendingPathComponent("ticket-\(number)") }

    /// The numbers of the tickets there, live or not.
    private func ticketNumbers() -> [Int] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).compactMap { name in
            guard name.hasPrefix("ticket-") else { return nil }
            let number = name.dropFirst("ticket-".count)
            return !number.isEmpty && number.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(number) : nil
        }
    }

    /// Takes the next number in line for `note` (a holder's line), waiting on up to `slots`: its ticket, flocked from
    /// its making on the returned fd. Nil when the folder won't have it.
    private func takeTicket(_ note: String, slots: Int) -> (fd: Int32, number: Int)? {
        let queue = open(queuePath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard queue >= 0 else { return nil }
        defer { close(queue) }
        guard flock(queue, LOCK_EX) == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = pread(queue, &bytes, bytes.count, 0)
        let given = Int(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let number = max(given, ticketNumbers().max() ?? 0) + 1
        let text = Array("\(number)\n".utf8)
        guard ftruncate(queue, 0) == 0, pwrite(queue, text, text.count, 0) == text.count else { return nil }
        let fd = open(ticketPath(number), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK, 0o600)
        guard fd >= 0 else { return nil }
        let line = Array("\(note)\nslots \(slots)\n".utf8)
        _ = write(fd, line, line.count)
        return (fd, number)
    }

    /// The waiters in line before ticket `number` (all of them by default), first first. A ticket no waiter holds is
    /// removed and passed over.
    public func waiters(before number: Int = .max) -> [Waiter] {
        ticketNumbers().filter { $0 < number }.sorted().compactMap { number in
            let path = ticketPath(number)
            let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                // Numbers aren't given twice: the name can only be this dead one's.
                unlink(path)
                return nil
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &bytes, bytes.count)
            let lines = String(decoding: bytes.prefix(max(0, count)), as: UTF8.self).split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let slots = lines.lazy.compactMap { $0.hasPrefix("slots ") ? Int($0.dropFirst("slots ".count)) : nil }.first ?? .max
            var info = stat()
            let since = fstat(fd, &info) == 0 ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : nil
            let note = lines.first.flatMap { $0.isEmpty || $0.hasPrefix("slots ") ? nil : $0 }
            return Waiter(number: number, slots: slots, who: Holder(slot: 0, note: note, since: note == nil ? nil : since))
        }
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

    /// Waits in line for a slot up to `timeout` (checking `cancel`), takes the first it may, and writes `what` (run in
    /// `directory`) as its holder. While it waits, `waiting` hears who holds them and who's in line before it (first
    /// first), at once and then every `every`.
    public func acquire(as what: String, in directory: String? = nil, timeout: TimeInterval, cancel: ShellCancel? = ShellCancel.current,
                        every: TimeInterval = 30, waiting: (([Holder], [Waiter], TimeInterval) -> Void)? = nil) -> Outcome {
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
        let place = directory.map { " in \($0)" } ?? ""
        func note() -> String {
            "pid \(getpid()), \(what)\(place), since \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"
        }
        guard let ticket = takeTicket(note(), slots: slots) else {
            return .failed("Couldn't take a number in line at \(queuePath) (\(String(cString: strerror(errno)))).")
        }
        // Out of line however this ends: removed first, so no one finds it let go.
        defer {
            unlink(ticketPath(ticket.number))
            close(ticket.fd)
        }
        let start = Date()
        var waitedFor: [Holder] = []
        var told: Date?
        while true {
            let ahead = waiters(before: ticket.number)
            // The slots no one before it may take.
            let from = min(slots, ahead.map(\.slots).max() ?? 0)
            if let free = fds.indices.dropFirst(from).first(where: { flock(fds[$0], LOCK_EX | LOCK_NB) == 0 }) {
                let fd = fds[free]
                fds[free] = -1
                let index = free + 1
                try? VibePaths.writePrivate(Data((note() + "\n").utf8), to: URL(fileURLWithPath: slotPath(index) + ".holder"))
                return .held(Held(fd: fd, path: slotPath(index)), waited: Date().timeIntervalSince(start), after: waitedFor)
            }
            if waitedFor.isEmpty { waitedFor = (1...slots).map(holder) }
            if cancel?.isCancelled == true { return .cancelled }
            let now = Date()
            if now.timeIntervalSince(start) >= timeout { return .busy(holders: (1...slots).map(holder)) }
            if let waiting, told.map({ now.timeIntervalSince($0) >= every }) ?? true {
                told = now
                waiting((1...slots).map(holder), ahead, now.timeIntervalSince(start))
            }
            usleep(useconds_t(min(500_000, max(10_000, every * 1_000_000 / 2))))
        }
    }
}
