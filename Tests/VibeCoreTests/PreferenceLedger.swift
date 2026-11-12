#if canImport(Darwin)
import Foundation
import ObjectiveC

// What marks a run's own preference files (scripts/test.sh, `check_preferences`). cfprefsd writes every named suite to
// the one real ~/Library/Preferences, so neither the file's name nor its owner says which run asked for it, and up to 3
// suites run at once: a run judged by what appeared there was charged with what the others left. So the test processes
// say what they open: as the bundle loads, the initializer below (SwiftPM links every test target into one bundle, so
// this one covers them all) wraps NSUserDefaults' suite initializer to append each suite's name to
// $VIBESWITCHER_PREFERENCE_LEDGER, a file in the run's own scratch folder (scripts/test.sh and scripts/test-under-load.sh
// each give a run one). Without that variable nothing is wrapped.
//
// A suite opened another way, or in a program a test starts (it isn't this bundle), isn't in the ledger: the check names
// such a file and doesn't fail the run. PreferencesLintTests is what stops a test making a domain-named suite at all.

private typealias OpenSuite = @convention(c) (Unmanaged<AnyObject>, Selector, Unmanaged<NSString>?) -> Unmanaged<AnyObject>?

private var ledger: Int32 = -1
private var openSuite: OpenSuite?

/// Written by hand so that nothing here retains or releases: an init takes `self` and returns its result owned, which a
/// block or a plain Swift signature would get wrong. One `write` a name, O_APPEND: lines from the run's processes don't mix.
private let openSuiteNoted: OpenSuite = { me, selector, suite in
    if let suite {
        let line = Array((suite.takeUnretainedValue() as String + "\n").utf8)
        _ = line.withUnsafeBytes { write(ledger, $0.baseAddress, $0.count) }
    }
    return openSuite?(me, selector, suite)
}

@_used @_section("__DATA,__mod_init_func")
private let noteTheSuitesThisRunOpens: @convention(c) () -> Void = {
    guard let path = getenv("VIBESWITCHER_PREFERENCE_LEDGER") else { return }
    ledger = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard ledger >= 0, let method = class_getInstanceMethod(UserDefaults.self, NSSelectorFromString("initWithSuiteName:")) else { return }
    openSuite = unsafeBitCast(method_getImplementation(method), to: OpenSuite.self)
    method_setImplementation(method, unsafeBitCast(openSuiteNoted, to: IMP.self))
}
#endif
