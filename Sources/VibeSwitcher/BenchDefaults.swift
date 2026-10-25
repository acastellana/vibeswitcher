import Foundation
import ObjectiveC

/// The debug aids' defaults (`--chat-bench`, `--idle-bench`, `--ui-bench`, `--board-bench`, `--ui-bench-write`): a
/// suite of their own in scratch, in place of the build's domain. cfprefsd keeps an unbundled binary's defaults (domain:
/// its file name, `VibeSwitcher`) in the real ~/Library/Preferences whatever HOME and CFFIXED_USER_HOME say, and until
/// 2026-10-25 every bench wrote its window frames, split views, chat font and inspector tab there. The same move as the
/// sandbox's (`Sandbox.redirectDefaults`): `UserDefaults.standard` hands out a suite named by a path, which cfprefsd keeps
/// in that path's .plist; AppKit's own reads and writes (window frames, split views) go there too.
enum BenchDefaults {
    /// The flags whose runs get scratch defaults (main.swift calls `redirect` before running any of them).
    static let flags = ["--chat-bench", "--idle-bench", "--ui-bench", "--board-bench", "--ui-bench-write"]

    /// Where the suite goes: in the scratch home a bench runs on (`<home>/bench-defaults.plist`), or, on the account's
    /// own home (a chat bench run by hand), in a new folder in the temporary folder. Never in ~/Library/Preferences.
    static func path(home: String, accountHome: String, temporary: String) -> String {
        if (home as NSString).standardizingPath != (accountHome as NSString).standardizingPath {
            return (home as NSString).appendingPathComponent("bench-defaults")
        }
        var template = Array(((temporary as NSString).appendingPathComponent("vibeswitcher-bench.XXXXXX")).utf8CString)
        let folder = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }.map { String(cString: $0) }
        return ((folder ?? temporary) as NSString).appendingPathComponent("bench-defaults")
    }

    /// Points `UserDefaults.standard` at the suite, before anything reads a default. Exits when it can't: a bench never
    /// runs on the build's real domain.
    static func redirect() {
        let accountHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? ""
        let path = path(home: NSHomeDirectory(), accountHome: accountHome, temporary: NSTemporaryDirectory())
        BenchSuite.suite = UserDefaults(suiteName: path)
        guard BenchSuite.suite != nil,
              let standard = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)),
              let own = class_getClassMethod(BenchSuite.self, #selector(BenchSuite.benchStandard)) else {
            refuse()
        }
        method_setImplementation(standard, method_getImplementation(own))
        guard UserDefaults.standard === BenchSuite.suite else { refuse() }
    }

    /// What it says when it can't. The bench scripts look for it in a build (scripts/lib/bench-defaults.sh): a build
    /// without it writes the real defaults, and they don't run it.
    static let refusal = "couldn't give the bench defaults of its own: it doesn't run on the build's real ones"

    private static func refuse() -> Never {
        FileHandle.standardError.write(Data("\(refusal)\n".utf8))
        exit(64)
    }
}

/// Holds the bench's defaults for the replaced `UserDefaults.standard`.
private final class BenchSuite: NSObject {
    nonisolated(unsafe) static var suite: UserDefaults?
    @objc class func benchStandard() -> UserDefaults { suite! }
}
