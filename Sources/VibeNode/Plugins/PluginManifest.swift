import Foundation
import VibeCore

/// An external plugin's manifest, `vibeswitcher-plugin.json` in its folder (the definition's "External plugins"): read
/// strictly (a field it doesn't know, a wrong type, a value past its rule: refused), never trusted beyond what it says
/// of itself, every text shown inert. What `plugin add` shows the user and records (its SHA-256 and its program's).
public struct PluginManifest: Codable, Equatable, Sendable {
    public struct Command: Codable, Equatable, Sendable {
        public var name: String
        public var about: String
    }

    public struct Setting: Codable, Equatable, Sendable {
        public var key: String
        public var title: String
        public var about: String
        public var form: String
        public var choices: [String]?
        public var defaultValue: String?
    }

    public var `protocol`: Int
    public var id: String
    public var version: String
    public var title: String
    public var summary: String
    /// The program to run, a path inside the folder.
    public var program: String
    public var commands: [Command]?
    public var settings: [Setting]?
    public var brief: [String]?
    /// A card's life in seconds (`PluginInfo.life`), and why when past 30 minutes.
    public var life: Int?
    public var lifeWhy: String?
    /// Whether it serves a one-request page (`PluginPage`).
    public var page: Bool?
    /// Ignored: an added plugin starts off.
    public var defaultOn: Bool?
    /// Whether it keeps data: a private folder of its own, named by VIBESWITCHER_PLUGIN_DATA, which it reads as
    /// untrusted input (the review of step C, H1). Without it the program has no writable place at all.
    public var data: Bool?

    /// The commands the node puts on sessions' PATH itself (`Resources/bin` as the Linux install ships it: the Mac app's
    /// `vs-wallet` filer isn't shipped there, so the wallet plugin's own `vs-wallet` is the one found). A plugin's command
    /// can't be one (the review of step C, L3); `PluginLintTests` holds this to the folder.
    public static let nodeCommands: Set<String> = ["vs-ask", "vs-heavy", "vs-shell"]
    /// What `Resources/bin` holds that the Linux install leaves out.
    public static let macOnlyCommands: Set<String> = ["vs-wallet"]

    public static let fileName = "vibeswitcher-plugin.json"
    public static let bytesAtMost = 64 * 1024
    /// The longest a card of an external plugin waits (the lead's decision of 2026-11-22: 24 hours, said why past 30 minutes).
    public static let longestLife = 24 * 3600

    /// Plain text a person reads: no control or format character, at most `limit` characters.
    static func plain(_ text: String, limit: Int, lines: Bool = false) -> Bool {
        !text.isEmpty && text.count <= limit && !PluginText.stackedMarks(text) && !text.unicodeScalars.contains { scalar in
            (PluginText.control(scalar) && !(lines && scalar == "\n")) || scalar.properties.generalCategory == .format || PluginText.blank(scalar)
        }
    }

    /// The manifest in `data`, or why not: strict JSON of exactly these fields, each by its rule.
    public static func read(_ data: Data, builtIn: Set<String>) -> Result<PluginManifest, PluginRefusal> {
        guard data.count <= bytesAtMost else { return .failure(PluginRefusal("the manifest is over \(bytesAtMost / 1024) KiB")) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(PluginRefusal("the manifest isn't a JSON object"))
        }
        let known: Set<String> = ["protocol", "id", "version", "title", "summary", "program", "commands", "settings", "brief", "life", "lifeWhy",
                                  "page", "defaultOn", "data"]
        if let stray = object.keys.sorted().first(where: { !known.contains($0) }) {
            return .failure(PluginRefusal("the manifest has a field this node doesn't read: \(ConfigSeal.inert(stray, limit: 40))"))
        }
        // The commands' and settings' own fields too: exactly theirs (the fuzz tests of 2026-11-23: a stray key inside
        // one was read past, the decoder ignoring it).
        let inner: [(String, Set<String>)] = [("commands", ["name", "about"]), ("settings", ["key", "title", "about", "form", "choices", "defaultValue"])]
        for (field, fields) in inner {
            for item in (object[field] as? [Any]) ?? [] {
                if let stray = (item as? [String: Any])?.keys.sorted().first(where: { !fields.contains($0) }) {
                    return .failure(PluginRefusal("the manifest's \(field) have a field this node doesn't read: \(ConfigSeal.inert(stray, limit: 40))"))
                }
            }
        }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) } catch {
            return .failure(PluginRefusal("the manifest doesn't read: \(ConfigSeal.inert("\(error)", limit: 200))"))
        }
        return manifest.refusal(builtIn: builtIn).map { .failure(PluginRefusal($0)) } ?? .success(manifest)
    }

    /// The node's own name a title holds (VibeSwitcher, the node, the session host), or nil.
    static func coreName(in title: String) -> String? {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.contains(where: { $0.contains("vibeswitcher") || $0 == "vs" }) { return "VibeSwitcher" }
        if words.contains("node") { return "the node" }
        if words.contains("host") { return "the session host" }
        return nil
    }

    /// Why this manifest isn't taken (nil: it is).
    func refusal(builtIn: Set<String>) -> String? {
        guard self.protocol == 1 else { return "protocol \(self.protocol): this node speaks 1" }
        guard LeadVaultV2.pluginID(id) else { return "id: 1 to 32 of a-z, 0-9 and -, starting with a letter" }
        guard !builtIn.contains(id) else { return "id \(id) is a built-in plugin's" }
        guard Self.plain(version, limit: 40), Self.plain(title, limit: 60), Self.plain(summary, limit: 300) else {
            return "version, title and summary are plain text (40, 60 and 300 characters at most)"
        }
        // A title is the plugin's; the node's own names are the core's (the review of step C, L2).
        if let named = Self.coreName(in: title) { return "title: \(named) is the node's own name" }
        let parts = program.split(separator: "/", omittingEmptySubsequences: false)
        guard !program.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), program.count <= 200 else {
            return "program: a path inside the plugin's folder"
        }
        for command in commands ?? [] {
            guard !Self.nodeCommands.contains(command.name) else { return "commands: \(command.name) is the node's own" }
            guard command.name.hasPrefix("vs-"), command.name.count <= 32, LeadVaultV2.pluginID(String(command.name.dropFirst(3))),
                  Self.plain(command.about, limit: 300) else { return "commands: each a vs-<word> with a plain line about it" }
        }
        guard (commands ?? []).count <= 8, (settings ?? []).count <= 16, (brief ?? []).count <= 8 else { return "8 commands, 16 settings, 8 brief lines at most" }
        for setting in settings ?? [] {
            guard LeadVaultV2.pluginID(setting.key), Self.plain(setting.title, limit: 80), Self.plain(setting.about, limit: 300),
                  ["flag", "count", "number", "choice", "text"].contains(setting.form),
                  (setting.choices ?? []).allSatisfy({ Self.plain($0, limit: 40) }), setting.defaultValue.map({ $0.count <= 1000 }) ?? true else {
                return "settings: each a key, a plain title and line, a form (flag, count, number, choice or text)"
            }
        }
        guard (brief ?? []).allSatisfy({ Self.plain($0, limit: 400) }) else { return "brief: plain lines" }
        if let life {
            guard life > 0, life <= Self.longestLife else { return "life: 1 to \(Self.longestLife) seconds" }
            guard life <= 1800 || lifeWhy.map({ Self.plain($0, limit: 300) }) == true else { return "life past 30 minutes needs a plain lifeWhy" }
        }
        return nil
    }

    /// What the registry declares for it (off by default, whatever the manifest says; its requests' folder the core's).
    var info: PluginInfo {
        PluginInfo(id: id, title: title, summary: summary, defaultOn: false,
                   commands: (commands ?? []).map { .init(name: $0.name, about: $0.about) }, tools: [],
                   folder: "plugin-requests/\(id)", life: TimeInterval(life ?? 1800), lifeWhy: lifeWhy,
                   settings: (settings ?? []).map { .init(key: $0.key, title: $0.title, about: $0.about, form: $0.form, choices: $0.choices ?? [],
                                                          defaultValue: $0.defaultValue ?? "") },
                   brief: brief ?? [])
    }
}

/// What the vault keeps of an added plugin: its folder's resolved path and the SHA-256 of its manifest and program.
public struct PluginRecord: Codable, Equatable, Sendable {
    public var folder: String
    public var manifest: String
    public var program: String
    /// The program's size at its add: compared before it is copied at a start (the review of bd001923, N4).
    public var size: Int

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    static func read(_ text: String) -> PluginRecord? { try? JSONDecoder().decode(PluginRecord.self, from: Data(text.utf8)) }
}

/// A plugin's folder as `plugin add` reads it: the manifest, the program's resolved path, the SHA-256 of both.
struct PluginFolder: Equatable {
    var folder: String
    var manifest: PluginManifest
    var manifestBytes: Data
    var program: String
    var record: PluginRecord

    /// The folder at `path` (resolved), its manifest read strictly and its program a regular file inside it; or why not.
    /// Reads the disk.
    static func inspect(_ path: String, builtIn: Set<String>) -> Result<PluginFolder, PluginRefusal> {
        guard path.hasPrefix("/"), let real = realpath(path, nil) else { return .failure(PluginRefusal("no folder \(ConfigSeal.inert(path, limit: 200))")) }
        let folder = String(cString: real)
        free(real)
        guard let bytes = PluginDesk.bounded(URL(fileURLWithPath: folder).appendingPathComponent(PluginManifest.fileName), limit: PluginManifest.bytesAtMost) else {
            return .failure(PluginRefusal("no \(PluginManifest.fileName) in \(ConfigSeal.inert(folder, limit: 200)) (a regular file, 64 KiB at most)"))
        }
        let manifest: PluginManifest
        switch PluginManifest.read(bytes, builtIn: builtIn) {
        case .failure(let why): return .failure(why)
        case .success(let read): manifest = read
        }
        let joined = (folder as NSString).appendingPathComponent(manifest.program)
        guard let resolved = realpath(joined, nil) else { return .failure(PluginRefusal("its program \(ConfigSeal.inert(manifest.program, limit: 200)) isn't there")) }
        let program = String(cString: resolved)
        free(resolved)
        var info = stat()
        guard program.hasPrefix(folder + "/"), stat(program, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o100 != 0 else {
            return .failure(PluginRefusal("its program is an executable regular file inside its folder"))
        }
        switch PluginProgram.sealed(program, expected: nil, name: "plugin-inspect") {
        case .failure(let why): return .failure(why)
        case .success(let copy):
            defer { Sys.close(copy.fd) }
            let (digest, refused) = copy.withBytes { (BuildInfo.sha256(of: Data($0)), PluginProgram.refusal(Data($0))) }
            // What it loads before its own code is root's (the review of step C, H1): checked here and at every start.
            if let refused { return .failure(PluginRefusal(refused)) }
            return .success(PluginFolder(folder: folder, manifest: manifest, manifestBytes: bytes, program: program,
                                         record: PluginRecord(folder: folder, manifest: BuildInfo.sha256(of: bytes), program: digest, size: copy.size)))
        }
    }
}
