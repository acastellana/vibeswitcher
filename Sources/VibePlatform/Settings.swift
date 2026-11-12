import Foundation

/// A place settings are kept by name, as much of `UserDefaults` as the shared code uses: the Mac's is `UserDefaults`
/// itself, Linux's a property list in VibeSwitcher's folder (`FileSettings`, Settings+Linux.swift).
///
/// A value is a property list's: a String, a Bool, a number, a Date, a Data, an array or a dictionary (keyed by
/// Strings) of those. A Date comes back the Date it was, to the fraction of a second (`PauseStore` keeps the ends of
/// its pauses so). What one process sets, another reads at its next read.
public protocol SettingsStore: AnyObject {
    /// The value kept under `key`, nil when there is none.
    func object(forKey key: String) -> Any?
    /// The value when it is a String (a number reads as its digits); else nil.
    func string(forKey key: String) -> String?
    /// The value when it is a Bool (a number other than 0 and a String saying yes or true read true); else false.
    func bool(forKey key: String) -> Bool
    /// The value when it is a dictionary; else nil.
    func dictionary(forKey key: String) -> [String: Any]?
    /// Keeps `value` under `key`; nil removes what is kept there.
    func set(_ value: Any?, forKey key: String)
}

extension Platform {
    /// The app's own settings domain: what `settings(domain:)` reads when it isn't told another.
    public static let appSettingsDomain = "dev.vibeswitcher.VibeSwitcher"

    /// The settings of `domain`, by default the app's: what a helper process (the tool server) reads the app's
    /// settings through.
    ///
    /// The Mac: `UserDefaults(suiteName: domain)`, a new one at each call, as the callers made theirs; nil where
    /// that is (the global domain, or the process's own bundle identifier). A domain that is an absolute path is
    /// kept in the file at that path with `.plist` after it, not in ~/Library/Preferences.
    ///
    /// Linux: the property list `settings.plist` in VibeSwitcher's folder (as `VibePaths.root` resolves it:
    /// `VIBESWITCHER_HOME`, else `.vibeswitcher` in `CFFIXED_USER_HOME`, in `HOME`, in the account's home), looked up
    /// at each call. Another domain is `settings-<domain>.plist` there, each byte of the domain that isn't a letter,
    /// a digit, `.`, `-` or `_` written `%XX`; a domain that is an absolute path is the file at that path with
    /// `.plist` after it, as on the Mac. nil only for an empty domain. While a caller holds a file's store, every
    /// call for that file gives the same one.
    public static func settings(domain: String = "dev.vibeswitcher.VibeSwitcher") -> (any SettingsStore)? {
        #if canImport(Darwin)
        return UserDefaults(suiteName: domain)
        #else
        return FileSettings.shared(domain: domain)
        #endif
    }

    /// This process's own settings: the Mac's `UserDefaults.standard` (the app's domain in the app, the binary's
    /// name in an unbundled build); on Linux the app's domain, which is every process's there.
    public static var standardSettings: any SettingsStore {
        #if canImport(Darwin)
        return UserDefaults.standard
        #else
        return FileSettings.shared(file: FileSettings.file(domain: appSettingsDomain)!)
        #endif
    }
}

extension Platform {
    /// VibeSwitcher's folder, where Linux keeps the settings files (`FileSettings`): `VIBESWITCHER_HOME`, else
    /// `.vibeswitcher` in `CFFIXED_USER_HOME`, in `HOME`, in `fallbackHome`. A variable counts only when it is an
    /// absolute path. VibeCore's rule (`VibePaths.root(environment:fallbackHome:)`) said again, this module being below
    /// VibeCore; `SettingsRootTests` holds the two the same, on both systems. The Mac's store is `UserDefaults`, which
    /// doesn't ask it.
    static func settingsRoot(variable: (String) -> String?, fallbackHome: @autoclosure () -> String) -> URL {
        func absolute(_ name: String) -> String? {
            guard let path = variable(name), path.hasPrefix("/") else { return nil }
            return path
        }
        if let own = absolute("VIBESWITCHER_HOME") { return URL(fileURLWithPath: own, isDirectory: true) }
        let home = absolute("CFFIXED_USER_HOME") ?? absolute("HOME") ?? fallbackHome()
        return URL(fileURLWithPath: home).appendingPathComponent(".vibeswitcher")
    }
}

#if canImport(Darwin)
extension UserDefaults: SettingsStore {}
#endif
