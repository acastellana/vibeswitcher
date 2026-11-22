import Foundation

/// What an agent's command of a feature plugin (`vs-shell`, `vs-wallet`) reads before it files anything: whether the
/// node has that plugin on (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md, "Off leaves no trace"). The node's
/// server writes `<root>/plugins.json` from what the vault keeps (`PluginRegistry.mirror`); it is only what the command
/// says, never what the server decides: the server drops what an off plugin's command files anyway, and reads which are
/// on from the vault, never from this file. No file (a node before plugins, the Mac): the command files as before.
public enum PluginGate {
    public struct Mirror: Codable, Equatable, Sendable {
        /// The ids of the plugins that are on.
        public var on: [String]
        /// Whether the server knew yet (it hadn't asked the vault: every plugin is off until it has).
        public var known: Bool
        public init(on: [String], known: Bool) {
            self.on = on
            self.known = known
        }
    }

    /// `<root>/plugins.json`.
    public static var file: URL { VibePaths.root.appendingPathComponent("plugins.json") }

    /// The mirror at `file`, read as a regular file (no link followed, 4 KiB at most); nil when there's none or it doesn't
    /// read.
    public static func mirror(at file: URL = PluginGate.file) -> Mirror? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4096,
              let data = try? handle.read(upToCount: 4097), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(Mirror.self, from: data)
    }

    /// Why `command` (plugin `id`'s) files nothing on this node, or nil: the node has it on, or says nothing.
    public static func refusal(_ id: String, command: String, at file: URL = PluginGate.file) -> String? {
        guard let mirror = mirror(at: file), !mirror.on.contains(id) else { return nil }
        let why = mirror.known ? "the user hasn't turned it on (`vibeswitcher plugin on \(id)` in their own terminal turns it on)"
            : "VibeSwitcher's server is starting: try again in a moment"
        return "\(command): this node doesn't have \(id) on: \(why). Nothing was filed."
    }
}
