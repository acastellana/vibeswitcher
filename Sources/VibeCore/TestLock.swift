import Darwin
import Foundation

/// One build or test run at a time on this Mac, for every project: the lock `vs-heavy` takes around the command it's
/// given (scripts/test.sh and scripts/build-app.sh around swift build and swift test, workers around a full suite or a
/// release build), which merge and an audit's shared run take around their commands too. Two suites side by side
/// starved each other and the benches (3–4 min each at load 30–50, measured 2026-10-21).
/// A flock on `<directory>/test-build.lock`: the kernel lets go of it when its holder exits, however it ends, so no
/// stale lock outlives a run. `<lock>.holder` says who holds it, for the one waiting.
public struct TestLock: Sendable {
    /// Set to the lock's path for the commands run under its holder: a script among them doesn't wait for its own
    /// ancestor (`vs-heavy` reads it).
    public static let heldVariable = "VIBESWITCHER_TEST_LOCK"
    /// Where the lock is kept instead of /private/tmp/vibeswitcher-<uid> (tests).
    public static let directoryVariable = "VIBESWITCHER_TEST_LOCK_DIR"

    public let path: String
    public var holderPath: String { path + ".holder" }

    public init(directory: String) {
        path = (directory as NSString).appendingPathComponent("test-build.lock")
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

    /// The Mac-wide lock; nil when this process runs under its holder already (`heldVariable` names it).
    public static func standard(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> TestLock? {
        let lock = TestLock(directory: environment[directoryVariable] ?? "/private/tmp/vibeswitcher-\(getuid())")
        return environment[heldVariable] == lock.path ? nil : lock
    }

    /// The lock while it's held: let go with `release` (or when it goes).
    public final class Held: @unchecked Sendable {
        private var fd: Int32
        init(fd: Int32) { self.fd = fd }

        public func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }

        deinit { release() }
    }

    /// How a wait for it ended.
    public enum Outcome {
        /// Taken: `waited` seconds, and whom it waited for (nil when it was free).
        case held(Held, waited: TimeInterval, after: String?)
        /// Still held by `holder` after `timeout`, or the wait was cancelled: nothing ran.
        case busy(holder: String?)
        case cancelled
        case failed(String)
    }

    /// Who holds it, as its holder wrote (nil when nothing says).
    public func holder() -> String? {
        (try? String(contentsOfFile: holderPath, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Waits for it up to `timeout` (checking `cancel`), takes it, and writes `what` as its holder.
    public func acquire(as what: String, timeout: TimeInterval, cancel: ShellCancel? = ShellCancel.current) -> Outcome {
        let directory = (path as NSString).deletingLastPathComponent
        do { try VibePaths.ensurePrivate(URL(fileURLWithPath: directory, isDirectory: true)) } catch {
            return .failed("Couldn't make \(directory) for the test and build lock (\(error.localizedDescription)).")
        }
        // /private/tmp is everyone's: a folder someone else made there (or a link) isn't taken as this user's.
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            return .failed("\(directory) isn't a folder of yours: the test and build lock can't be kept there.")
        }
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .failed("Couldn't open \(path) (\(String(cString: strerror(errno)))).") }
        let start = Date()
        var waitedFor: String?
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if waitedFor == nil { waitedFor = holder() ?? "a run that didn't say who it is" }
            if cancel?.isCancelled == true {
                close(fd)
                return .cancelled
            }
            if Date().timeIntervalSince(start) >= timeout {
                close(fd)
                return .busy(holder: holder())
            }
            usleep(500_000)
        }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        try? VibePaths.writePrivate(Data("pid \(getpid()), \(what), since \(stamp)\n".utf8), to: URL(fileURLWithPath: holderPath))
        return .held(Held(fd: fd), waited: Date().timeIntervalSince(start), after: waitedFor)
    }
}
