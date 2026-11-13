import Foundation

extension Platform.Files {
    /// Copies the file at `path` to `destination` (which must not exist), keeping its permissions and its modification
    /// date: the session host's launcher copy is named by that date (`HostBuild.id`), and a copy dated otherwise is
    /// taken for another build. Throws as FileManager's copy does.
    ///
    /// The Mac's FileManager copy keeps the date by itself (a clone). Linux's (swift-corelibs-foundation) gives the
    /// copy the time it was made (measured 2026-11-13), so the original's date is set on it after.
    public static func copyKeepingModificationDate(atPath path: String, toPath destination: String) throws {
        #if canImport(Darwin)
        try FileManager.default.copyItem(atPath: path, toPath: destination)
        #else
        let date = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        try FileManager.default.copyItem(atPath: path, toPath: destination)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: destination) }
        #endif
    }
}
