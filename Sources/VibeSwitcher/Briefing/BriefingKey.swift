import Foundation
import VibeCore

/// Where the briefing's ElevenLabs key comes from (Settings › General › Briefing names it, never the value).
enum BriefingKeySource: Equatable, Sendable {
    /// Typed in Settings: the login Keychain item (`AppProof.KeychainSecret`).
    case keychain
    /// Exported in the user's login shell (`.zshrc`, `.zprofile`).
    case shell(variable: String)
    /// A `KEY=value` line in a file (`~/.config/elevenlabs/key.env`), shown as written here.
    case file(path: String)
    /// No key anywhere: the Mac's voice reads the briefing.
    case absent

    /// Settings' line.
    var line: String {
        switch self {
        case .keychain: return "Saved in your Keychain"
        case .shell(let variable): return "From your shell: \(variable)"
        case .file(let path): return "From \(path)"
        case .absent: return "None: the Mac's voice reads it"
        }
    }

    /// Found outside the Keychain: Settings offers to save it there.
    var canSave: Bool {
        switch self {
        case .shell, .file: return true
        case .keychain, .absent: return false
        }
    }
}

/// The briefing's ElevenLabs key (the Mac's Brief me and Test voice, and the phone's), looked up in this order: the
/// key saved in the Keychain; `ELEVENLABS_API_KEY` from the user's login shell (`LoginShellVariable`: one shell per
/// launch, read again when Settings opens, never per briefing); a `ELEVENLABS_API_KEY=` line in
/// `~/.config/elevenlabs/key.env` (read, nothing in it run). Saving or removing touches the Keychain item only. The
/// value is held in memory only: never in the defaults, a log, the phone or a file.
final class BriefingKey: SecretStore, @unchecked Sendable {
    static let variable = "ELEVENLABS_API_KEY"
    /// The key file, from the home folder (looked up where it's read: a test's is its scratch home).
    static let fileInHome = ".config/elevenlabs/key.env"
    /// As Settings names it.
    static var filePath: String { "~/" + fileInHome }
    /// Bigger than this, it's not a key file: not read.
    static let fileLimit = 64 * 1024

    private let saved: SecretStore
    private let shell: @Sendable () -> String?
    private let file: @Sendable () -> String?
    /// Taken while the shell's value is read, so two briefings at once start one shell.
    private let shellLock = NSLock()
    /// The shell's value (nil inside: the shell hasn't it); nil: not read since launch or since `refresh()`.
    private var shellValue: String??

    /// `saved`: the Keychain item. `shell`: the login shell's ELEVENLABS_API_KEY. `file`: the key file's text. Tests
    /// give stand-ins for all three.
    init(saved: SecretStore, shell: @escaping @Sendable () -> String? = { nil }, file: @escaping @Sendable () -> String? = { nil }) {
        self.saved = saved
        self.shell = shell
        self.file = file
    }

    /// The app's: the Keychain item given, the user's login shell, and the key file in their home.
    static func live(saved: SecretStore) -> BriefingKey {
        BriefingKey(saved: saved, shell: {
            switch LoginShellVariable.read(variable) {
            case .found(let value): return value
            case .unset: return nil
            case .timedOut:
                NSLog("VibeSwitcher: the login shell didn't answer in time for \(variable); not using it")
                return nil
            case .failed:
                NSLog("VibeSwitcher: the login shell couldn't be read for \(variable); not using it")
                return nil
            }
        }, file: {
            readFile(NSHomeDirectory() + "/" + fileInHome)
        })
    }

    /// The key and where it came from. Blocks (the Keychain may ask; the shell's first read takes a moment): never on
    /// the main thread.
    func resolve() -> (key: String?, source: BriefingKeySource) {
        if let key = saved.read(), !key.isEmpty { return (key, .keychain) }
        if let key = shellKey() { return (key, .shell(variable: Self.variable)) }
        if let key = file().flatMap({ Self.parse($0, name: Self.variable) }) { return (key, .file(path: Self.filePath)) }
        return (nil, .absent)
    }

    /// The shell's value is read again the next time it's needed (Settings opening).
    func refresh() {
        shellLock.withLock { shellValue = nil }
    }

    private func shellKey() -> String? {
        shellLock.withLock {
            if let held = shellValue { return held }
            let value = Self.usable(shell())
            shellValue = .some(value)
            return value
        }
    }

    // MARK: SecretStore

    func read() -> String? { resolve().key }

    /// Saves to (or, nil, removes from) the Keychain item only: the shell's and the file's stay as they are.
    @discardableResult
    func write(_ value: String?) -> Bool { saved.write(value) }

    // MARK: The key file

    static func readFile(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.size] as? Int ?? .max) <= fileLimit,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `name`'s value in an env file: `NAME=value` or `export NAME=value`, the value bare (up to a ` #` comment) or in
    /// single or double quotes; `#` lines, blank lines and CRLF endings are fine. Nothing is expanded or run: a value
    /// that would need the shell (`$`, a backtick) or a line that doesn't parse (an unclosed quote) counts as none. The
    /// last good line wins, as in the shell.
    static func parse(_ text: String, name: String) -> String? {
        var found: String?
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = line.dropFirst("export ".count).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "="), line[..<equals] == name else { continue }
            if let value = usable(value(line[line.index(after: equals)...])) { found = value }
        }
        return found
    }

    /// An assignment's value: quoted (the quotes' content, nothing after but a comment) or bare.
    private static func value(_ text: Substring) -> String? {
        guard let quote = text.first, quote == "\"" || quote == "'" else {
            let bare = text.range(of: #"\s#"#, options: .regularExpression).map { text[..<$0.lowerBound] } ?? text
            return bare.trimmingCharacters(in: .whitespaces)
        }
        let inside = text.dropFirst()
        guard let close = inside.firstIndex(of: quote) else { return nil }
        let after = inside[inside.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after.hasPrefix("#") else { return nil }
        return String(inside[..<close])
    }

    /// A key as ElevenLabs gives them: printable ASCII without spaces, and nothing the shell would expand.
    static func usable(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 512,
              value.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f && $0 != "$" && $0 != "`" && $0 != "\"" && $0 != "'" })
        else { return nil }
        return value
    }
}
