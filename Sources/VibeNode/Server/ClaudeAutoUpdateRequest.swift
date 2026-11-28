import Foundation
import VibeCore

/// Claude Code's self-update switch as a kind (`claude.autoupdate`, the no-terminal inventory's E8, decision N8; group
/// G3 of v2-remaining): `on: false` puts `DISABLE_AUTOUPDATER=1` in the `env` of Claude Code's own settings
/// (`<home>/.claude/settings.json`), which stops the holds its self-updates cause (`ClaudeUpdateHint`); `on: true` takes
/// it out. The write is the app's own (`ClaudeAutoUpdate.set`: `appWrite`, then sealed), as `hooks.install` writes the
/// same file, so the switch itself is never held.
///
/// **A guarded change, not a page's yet** (`KindSpec`: `.terminalOnly`): it writes an agent's own settings, as
/// `hooks.install` does (N8 follows N1). Until the device keys track's slices 14 and 15 wire it behind the guarded-change
/// rule, only the user's voice sends it. Its one argument names the change in full (`on`); the settings' path is the
/// server's home's, never a caller's.
extension WireKinds {
    public enum ClaudeAutoUpdateSwitch: WireChangeKind {
        public static let kind = "claude.autoupdate"
        public struct Args: WireArgs, Equatable {
            /// Whether Claude Code updates itself: false writes `DISABLE_AUTOUPDATER=1`, true takes it out.
            public var on: Bool?
            public enum CodingKeys: String, CodingKey, CaseIterable { case on }
            public init(on: Bool?) { self.on = on }
        }
        /// `on`: as the settings say now; `changed`: whether this request changed them; `config`: the file.
        public struct Result: Codable, Sendable, Equatable {
            public var on: Bool?
            public var changed: Bool?
            public var config: String?
            public init(on: Bool, changed: Bool, config: String) {
                self.on = on
                self.changed = changed
                self.config = config
            }
        }
    }
}

extension Requests {
    /// `claude.autoupdate` with `on`, in this server's home: `ClaudeAutoUpdate.set` on the engine's read queue (the
    /// vault's seal asks the host), answered on `queue`.
    func claudeAutoUpdate(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let args: WireKinds.ClaudeAutoUpdateSwitch.Args
        switch request.typedArgs(WireKinds.ClaudeAutoUpdateSwitch.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let taken): args = taken
        }
        guard let on = args.on else {
            return reply(.init(re: request.id, error: .init(.badArgs, "claude.autoupdate needs on, true or false")))
        }
        let (home, vault, queue) = (self.home, link.vault, self.queue)
        DispatchQueue.global(qos: .userInitiated).async {
            let set = ClaudeAutoUpdate.set(on: on, home: home, appWrite: { paths, write in
                defer { vault.sealAppWrites() }
                try vault.appWrite(paths, home: home, write)
            })
            queue.async {
                switch set {
                case .failure(let refusal): reply(.init(re: request.id, error: .init(.refused, refusal.text)))
                case .success(let changed):
                    reply(.init(re: request.id, typed: WireKinds.ClaudeAutoUpdateSwitch.Result(on: on, changed: changed, config: ClaudeAutoUpdate.settingsPath(home: home))))
                }
            }
        }
    }
}
