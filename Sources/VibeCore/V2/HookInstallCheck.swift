import Foundation

/// What the node's `hooks install` asks of the installer before and after its writes (`HooksRequest`, in
/// `Sources/VibeNode/Server/HooksRequest.swift`): whether a config can take the hooks, asked before the hooks'
/// programs are put in place, and why an edit failed, in words for the one line the command prints.
///
/// The first Linux node's install (2026-11-19) copied the two programs, then failed on `~/.claude/settings.json` and
/// said only "NSCocoaErrorDomain error 512". The fault was the installer's (`Platform.sameJSON`), but any config that
/// can't be edited (not JSON, not an object, a folder that can't be read) left the same half: programs with no hooks.
///
/// The Mac: the app's `HookSetup` doesn't ask either; `install` and `uninstall` are as they were.
extension HookInstaller {
    /// Throws what `install(agent:at:hookBinary:)` would throw before it writes anything, and writes nothing: the
    /// file read (through its links), parsed, given our hooks, and the text it would write read back as that config.
    /// `edit(_:backup:change:)`'s steps up to its backup; `HookInstallCheckTests` holds the two to the same answer.
    public static func checkInstall(agent: Agent, at url: URL? = nil, hookBinary: String = VibePaths.hookBinary.path) throws {
        let url = url ?? configURL(for: agent)
        let target = try fileBehindLinks(url)
        let data = Stamp(of: target) == nil ? Data() : try Data(contentsOf: target)
        let current = try parse(data, path: url.path)
        let changed = addingOurs(to: current, agent: agent, hookBinary: hookBinary)
        if Platform.sameJSON(changed, current) { return }
        let updated = try replacingHooks(in: data, with: changed["hooks"])
        guard Platform.sameJSON(try parse(updated, path: url.path), changed) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// Why an install, an uninstall or `checkInstall` threw, to follow the config's path in a sentence ("… wasn't
    /// changed: it isn't valid JSON (…)"). Linux's Foundation describes its own errors as "The operation could not be
    /// completed. (NSCocoaErrorDomain error 512.)", which names neither the file nor the reason.
    public static func whyNot(_ error: Error) -> String {
        if let error = error as? EditError {
            switch error {
            case .changed: return "it kept changing while VibeSwitcher was editing it; try again"
            }
        }
        if let error = error as? Platform.Errno { return String(cString: strerror(error.code)) }
        if let error = error as? POSIXError { return String(cString: strerror(error.code.rawValue)) }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case CocoaError.Code.fileWriteUnknown.rawValue:
                return "VibeSwitcher's edit didn't read back as the config it meant, so it wasn't written (the installer's fault, not the file's)"
            case CocoaError.Code.fileReadCorruptFile.rawValue:
                // `parse` names the file; `replacingHooks` and its reader of the text don't.
                return error.userInfo[NSFilePathErrorKey] != nil ? "it isn't a JSON object"
                    : "its text couldn't be followed to one top-level \"hooks\" key"
            case CocoaError.Code.propertyListReadCorrupt.rawValue:
                let detail = (error.userInfo[NSDebugDescriptionErrorKey] as? String).map { " (\($0))" } ?? ""
                return "it isn't valid JSON" + detail
            default:
                break
            }
        }
        let said = error.localizedDescription
        let preamble = "The operation could not be completed. "
        return said.hasPrefix(preamble) && said.count > preamble.count ? String(said.dropFirst(preamble.count)) : said
    }
}
