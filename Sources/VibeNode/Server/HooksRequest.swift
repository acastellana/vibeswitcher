import Foundation
import VibeCore

/// `hooks.install` and `hooks.remove` (the start plan's S6, ST-D17): VibeSwitcher's hooks put into the agents' configs in
/// the server's own home, or taken out, written as the app (`LeadVault.appWrite`) and then sealed (`sealAppWrites`), as
/// the Mac app's `HookSetup` and `HookBinary` do. The server takes it in the user's voice, after the command line's own
/// typed code, and records it in the vault before it acts (`Requests.recorded`).
///
/// - Install opens each of `<node-root>/bin/vibeswitcher-hook` and `vibeswitcher-mcp` once (`O_NOFOLLOW`, a regular
///   file) and hashes the bytes it read. Each must equal the `binaries` entry of the `build-info` the host loaded at its
///   start (`HostNotes.binaries`, S5): a worker can rewrite the `build-info` on disk too, so the copy on disk isn't asked.
///   Those bytes, never a second read, are written to a file in a fresh 0700 folder of their own beside
///   `<home>/.vibeswitcher/bin` (in `<home>/.vibeswitcher`: the bin folder is watched, and a look while a temporary is
///   in it would hold it), flushed, its descriptor kept, and only then, inside `appWrite`, renamed in. Before the first
///   rename each staged name must still be the file written (`fstat` of the descriptor against `lstat` of the name:
///   device, inode, size), and after each rename the program in place is read and hashed again: a staged file another
///   process swapped or rewrote is refused (the security follow-ups' item 29), before anything is renamed for a swap,
///   and with the program taken out again for a rewrite, so what `appWrite` seals is never its bytes. Then each
///   agent's config (`HookInstaller.configURL(for:home:)`) gets the hooks, running
///   `<home>/.vibeswitcher/bin/vibeswitcher-hook`. Each config is asked first, before a program is staged, whether it
///   can take them (`HookInstaller.checkInstall`: read, parsed, edited in memory, nothing written): one that can't
///   refuses the install with nothing done, naming the file and why. A config that fails after that (changed or made
///   unwritable since) is named the same way, with what was done: the programs in place, the configs before it edited.
/// - Remove takes only VibeSwitcher's hooks out of each config (`HookInstaller.uninstall`); the programs stay. A
///   config that can't be edited is named with the reason, and the configs done before it.
/// - Every path is passed to `appWrite` as `ConfigSeal.homeWatched(home:)` spells it (`<home>/.vibeswitcher/bin/…`,
///   `<home>/.claude/settings.json`), never `VibePaths.binDir`: on a scratch node that is `<root>/bin`, reached through
///   the `<home>/.vibeswitcher` link, and would match no watched thing.
/// - Install is refused while the seal has a change under `~/.vibeswitcher/v2/builds` not accepted (held, or not what
///   the vault recorded: S7's listing sees a rewrite by its `ctime`). `HostNotes.binaries` is what the host's image read
///   at its last start or handover, so it holds against a rewrite after that, not one before (ST-D17's S5 note); this
///   check asks the user to look at the builds folder first. Before the vault has recorded the folder at all (a fresh
///   vault before its first accept) there is nothing to compare: the install goes on, and the first accept shows the
///   folder as it is.
///
/// - What is sealed: `appWrite` fingerprints each watched thing before the write and again after it, and the vault
///   seals a change from the sealed hash to what the vault itself reads then. So a change another process of the user's
///   makes between those two reads is sealed with the write. The programs are written and flushed before the first
///   read, so the window is the renames and the config edits. Closing it needs `appWrite` to seal only the result the
///   write itself made, a VibeCore change the start plan doesn't list (ST-D17's note of the S6 review).
/// - A seal the host didn't take is asked again at the next look (`ConfigHoldStore.held`, `retrySealingAppWrites`).
///
/// Blocking (the vault's calls go to the host): the server runs it on the engine's read queue, never its own.
public struct HooksRequest {
    /// What an install wrote: the programs' paths and the configs', as written.
    public struct Installed: Equatable, Sendable {
        public var programs: [String]
        public var configs: [String]
        /// Where this install's Codex hooks are in `~/.codex/hooks.json` (`NodeCodexTrust.positions`): the only ones
        /// the Codex trust takes.
        public var codexPositions: Set<String> = []
    }

    /// The programs an agent's session runs that install puts in `<home>/.vibeswitcher/bin`.
    public static let programs = ["vibeswitcher-hook", "vibeswitcher-mcp"]
    /// The installed builds' folder, by its seal name (a name, not a path: nothing reads the home here).
    public static var buildsName: String { "~/.vibeswitcher/v2/builds" }

    public let nodeRoot: String
    public let home: String
    public let binaries: [String: String]?
    public let vault: LeadVault
    /// The commit the host runs (`HostNotes.build`) and this server's own (`Requests.commit`): while they differ the
    /// node is finishing a build switch (the host handed over; this server, whose build folder is `nodeRoot`, is
    /// replaced by the new build's once idle), and a program that isn't the host's `binaries` entry is said to be
    /// that, to try again in a moment. Nil: not known (either).
    public var hostBuild: String?
    public var serverBuild: String?
    /// Tests only: called inside `appWrite` with each staged program's path by name, just before the checks that
    /// precede the first rename (what another process of the user's could do to a staged file there, a test does).
    var beforeRenames: (([String: String]) -> Void)?

    public init(nodeRoot: String, home: String, binaries: [String: String]?, vault: LeadVault) {
        self.nodeRoot = nodeRoot
        self.home = home
        self.binaries = binaries
        self.vault = vault
    }

    /// The command a hint names for an install (2026-11-24: the user ran the plain form, which installed both agents'
    /// hooks; a hint naming one agent left the other out): `vibeswitcher hooks install`, every agent, as the user ran it.
    public static let installCommand = "vibeswitcher hooks install"

    /// `<home>/.vibeswitcher/bin`, as the seal spells it.
    public var binFolder: String { (home as NSString).appendingPathComponent(".vibeswitcher/bin") }

    /// Where `agent` reads its hooks in this home.
    public func configPath(_ agent: Agent) -> String { HookInstaller.configURL(for: agent, home: home).path }

    /// What an install would change now, one line each (none: the hooks are up to date): a program in the bin folder that
    /// isn't there or isn't the build's (its SHA-256 isn't `binaries`'), an agent's config without our hooks. A program the
    /// host's notes name no hash for is said unknown, never out of date. (`vibeswitcher approve`'s list.)
    /// `hash`: a program's SHA-256 (`sha256`; `status` passes one that keeps each by its file's stat, `HooksLook`).
    public func outOfDate(agents: [Agent], hash: (String) -> String? = HooksRequest.sha256) -> [String] {
        var said: [String] = []
        for name in Self.programs {
            let path = (binFolder as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(path, &info) == 0 else {
                said.append("\(name) isn't installed in \(Self.shown(binFolder))")
                continue
            }
            // A program is a plain file of a program's size: anything else is said, never read.
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.programLimit else {
                said.append("\(Self.shown(path)) isn't a plain file of a program's size")
                continue
            }
            if let expected = binaries?[name], hash(path) != expected {
                said.append("\(Self.shown(path)) isn't this build's \(name)")
            }
        }
        let hook = (binFolder as NSString).appendingPathComponent("vibeswitcher-hook")
        for agent in agents {
            switch Result(catching: { try HookInstaller.needsInstall(agent: agent, at: URL(fileURLWithPath: configPath(agent)), hookBinary: hook) }) {
            case .success(true): said.append("\(Self.shown(configPath(agent))) lacks VibeSwitcher's hooks for \(agent.rawValue)")
            case .success(false): break
            case .failure(let error): said.append("\(Self.shown(configPath(agent))) can't take the hooks: \(Self.why(error))")
            }
        }
        return said
    }

    /// The largest file `outOfDate` hashes as a program (the hook and tool server are tens of MB).
    static let programLimit: Int = 512 << 20

    /// `path`'s SHA-256, read in parts (never whole in memory), or nil when it can't be read.
    public static func sha256(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let part = try? handle.read(upToCount: 1 << 20), !part.isEmpty { hasher.update(data: part) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func install(agents: [Agent]) -> Result<Installed, StartRefusal> {
        guard !agents.isEmpty else { return .failure(StartRefusal("no agent named")) }
        if let refusal = buildsRefusal() { return .failure(refusal) }
        if let refusal = binFolderRefusal() { return .failure(refusal) }
        var read: [String: Data] = [:]
        for name in Self.programs {
            switch verified(name) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let data): read[name] = data
            }
        }
        let targets = Self.programs.map { (binFolder as NSString).appendingPathComponent($0) }
        let configs = agents.map(configPath)
        let hook = (binFolder as NSString).appendingPathComponent("vibeswitcher-hook")
        // Every config asked whether it can take the hooks before a program is written: one that can't (not JSON, not
        // an object, not readable) would leave the programs in place with no hook to run them.
        for agent in agents {
            do {
                try HookInstaller.checkInstall(agent: agent, at: URL(fileURLWithPath: configPath(agent)), hookBinary: hook)
            } catch {
                return .failure(StartRefusal("\(Self.shown(configPath(agent))) can't take the hooks: \(Self.why(error)): nothing was installed", exitCode: 1))
            }
        }
        let dot = URL(fileURLWithPath: home).appendingPathComponent(".vibeswitcher", isDirectory: true)
        var codexPositions: Set<String> = []
        // The programs' bytes written and flushed before `appWrite` takes its fingerprints, so only the renames and the
        // config edits fall between those and the ones it takes after (the S6 review: what changes in between is
        // sealed with the write).
        var staged: [String: Staged] = [:]
        defer { for program in staged.values { program.discard() } }
        do {
            try VibePaths.ensurePrivate(dot)
            for name in Self.programs { if let program = try stage(read[name] ?? Data(), name: name) { staged[name] = program } }
        } catch {
            return .failure(StartRefusal("the hooks' programs couldn't be written: \(ConfigSeal.inert(Self.describe(error), limit: .max)): nothing was installed", exitCode: 1))
        }
        do {
            try vault.appWrite(targets + configs, home: home) {
                beforeRenames?(staged.mapValues(\.path))
                // Every staged name still the file written, before anything is renamed (or the bin folder made).
                for name in Self.programs { try staged[name]?.checkUnswapped() }
                try VibePaths.ensurePrivate(URL(fileURLWithPath: binFolder, isDirectory: true), within: dot)
                for name in Self.programs {
                    guard let program = staged[name] else { continue }
                    try program.place(at: (binFolder as NSString).appendingPathComponent(name))
                }
                var done: [String] = []
                for agent in agents {
                    do {
                        try HookInstaller.install(agent: agent, at: URL(fileURLWithPath: configPath(agent)), hookBinary: hook)
                    } catch {
                        throw ConfigFailure(path: configPath(agent), error: error, done: done)
                    }
                    done.append(configPath(agent))
                    if agent == .codex, let written = FileManager.default.contents(atPath: configPath(agent)) {
                        codexPositions = NodeCodexTrust.positions(hooksJSON: written, command: HookInstaller.command(for: .codex, hookBinary: hook))
                    }
                }
            }
        } catch let failure as ConfigFailure {
            // `appWrite` has asked the vault already for what changed; this waits for that ask.
            vault.sealAppWrites()
            // The programs are in place by now (the file passed `checkInstall` and changed, or couldn't be written,
            // since): the line says what was done and what wasn't.
            let others = failure.done.isEmpty ? "" : ", and \(failure.done.map(Self.shown).joined(separator: " and ")) has its hooks"
            return .failure(StartRefusal("\(Self.shown(failure.path)) wasn't changed: \(Self.why(failure.error)): the hooks' programs are in \(Self.shown(binFolder))\(others)", exitCode: 1))
        } catch {
            vault.sealAppWrites()
            return .failure(StartRefusal("the hooks weren't all installed: \(ConfigSeal.inert(Self.describe(error), limit: .max))", exitCode: 1))
        }
        vault.sealAppWrites()
        return .success(Installed(programs: targets, configs: configs, codexPositions: codexPositions))
    }

    /// The Codex hooks just installed, trusted (`NodeCodexTrust`) by running `shown`, the Codex the user was shown
    /// before the typed code, when the node's Codex link (`NodePreflight.codex`) still resolves to it. The write it makes
    /// in `~/.codex/config.toml` is the app's own, sealed as the hooks' (`appWrite`). How many were trusted (nil: none was
    /// tried; else ours trusted now, those just trusted and those trusted before), and a note when one of ours is left
    /// untrusted or none was listed: the caller then says to run /hooks in Codex.
    /// `expected`: the places the install wrote ours in `~/.codex/hooks.json` (`Installed.codexPositions`); `scope`:
    /// `systemd-run` when the user's manager takes a transient scope (the user's node), nil for the process group.
    public func trustCodex(shown: String?, root: URL, expected: Set<String>, scope: String? = nil,
                           limit: TimeInterval = NodeCodexTrust.limit) -> (trusted: Int?, note: String?) {
        guard let shown else { return (nil, "no Codex was named to trust them with") }
        let found = NodePreflight.codex(root: root)
        guard let codex = found.path else { return (nil, ConfigSeal.inert(found.why ?? "no Codex", limit: 300)) }
        guard codex == shown else {
            return (nil, "the Codex link now names \(ConfigSeal.inert(codex, limit: 200)), not the \(ConfigSeal.inert(shown, limit: 200)) you confirmed: nothing was run")
        }
        let config = (home as NSString).appendingPathComponent(".codex/config.toml")
        let hook = (binFolder as NSString).appendingPathComponent("vibeswitcher-hook")
        // Sealed only when the file, read again as the vault decides, is our trust alone beside what it held
        // (`NodeCodexTrust.sealable`); else left as it is, held. Never put back.
        var seen = NodeCodexTrust.Seen()
        let (outcome, sealed) = vault.appWrite([config], home: home, sealIf: { _ in NodeCodexTrust.sealable(seen) }) {
            Result { try NodeCodexTrust.trust(codex: codex, home: home, hookBinary: hook, expected: expected,
                                              path: ProcessInfo.processInfo.environment["PATH"], scope: scope, limit: limit, seen: &seen) }
        }
        vault.sealAppWrites()
        if !sealed, FileManager.default.contents(atPath: config) != seen.before {
            return (nil, "~/.codex/config.toml changed while this ran (by Codex or something else): nothing of it was sealed; `vibeswitcher config held` shows it")
        }
        switch outcome {
        case .failure(let error): return (nil, ConfigSeal.inert("\(error)", limit: 300))
        case .success(let done):
            var notes: [String] = []
            if !done.notTaken.isEmpty {
                notes.append("\(done.notTaken.count) written and not taken by Codex")
            }
            if !done.refused.isEmpty { notes.append("\(done.refused.count) refused for a hash or key not in Codex's form") }
            let trusted = done.trusted + done.already
            if trusted == 0, notes.isEmpty { notes.append("Codex listed none of VibeSwitcher's hooks to trust") }
            return (trusted, notes.isEmpty ? nil : notes.joined(separator: "; "))
        }
    }

    public func remove(agents: [Agent]) -> Result<Void, StartRefusal> {
        guard !agents.isEmpty else { return .failure(StartRefusal("no agent named")) }
        do {
            try vault.appWrite(agents.map(configPath), home: home) {
                var done: [String] = []
                for agent in agents {
                    do {
                        try HookInstaller.uninstall(agent: agent, at: URL(fileURLWithPath: configPath(agent)))
                    } catch {
                        throw ConfigFailure(path: configPath(agent), error: error, done: done)
                    }
                    done.append(configPath(agent))
                }
            }
        } catch let failure as ConfigFailure {
            vault.sealAppWrites()
            let others = failure.done.isEmpty ? "" : ": the hooks are out of \(failure.done.map(Self.shown).joined(separator: " and "))"
            return .failure(StartRefusal("\(Self.shown(failure.path)) wasn't changed: \(Self.why(failure.error))\(others)", exitCode: 1))
        } catch {
            vault.sealAppWrites()
            return .failure(StartRefusal("the hooks weren't all removed: \(ConfigSeal.inert(Self.describe(error), limit: .max))", exitCode: 1))
        }
        vault.sealAppWrites()
        return .success(())
    }

    // MARK: The checks

    /// Refused while the builds folder has a change the seal holds, or one since the vault recorded it (`HeldChange`).
    func buildsRefusal() -> StartRefusal? {
        HeldChange.refusal([Self.buildsName], home: home, vault: vault, accept: "look with `vibeswitcher config held FOLDER` and accept it first")
    }

    /// `<home>/.vibeswitcher/bin` must be a folder or absent, never a link (the writes would land where it points).
    func binFolderRefusal() -> StartRefusal? {
        var info = stat()
        guard lstat(binFolder, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return StartRefusal("\(ConfigSeal.inert(binFolder, limit: .max)) isn't a folder: nothing was installed")
        }
        return nil
    }

    /// `<node-root>/bin/<name>`'s bytes, read once without following a link, when their SHA-256 is the host's
    /// `build-info`'s entry for it.
    func verified(_ name: String) -> Result<Data, StartRefusal> {
        let path = (nodeRoot as NSString).appendingPathComponent("bin/" + name)
        let shown = ConfigSeal.inert(path, limit: .max)
        guard let expected = binaries?[name] else {
            return .failure(StartRefusal("the host's build-info names no \(name): the host was started without one, so \(shown) isn't installed"))
        }
        switch BuildRecord.readRegular(path) {
        case .failure(let refusal): return .failure(StartRefusal("\(name) isn't installed: \(refusal.text)", exitCode: refusal.exitCode))
        case .success(let data):
            guard BuildInfo.sha256(of: data) == expected else {
                if let switching = switchingRefusal() { return .failure(switching) }
                return .failure(StartRefusal("\(shown) isn't the \(name) the host's build-info names (its SHA-256 differs): nothing was installed"))
            }
            return .success(data)
        }
    }

    /// What a mismatch says while the node is finishing a build switch (`hostBuild` known and not `serverBuild`): the
    /// programs here are this server's build's, the host's `binaries` the new build's, and the server restarts onto the
    /// host's build once it is idle (`ServerChild.idleLimit`). Nothing was installed.
    func switchingRefusal() -> StartRefusal? {
        guard let host = hostBuild, let server = serverBuild, host != server else { return nil }
        let short = { (commit: String) in ConfigSeal.inert(String(commit.prefix(12)), limit: 40) }
        return StartRefusal("the node is finishing a build switch: its host runs \(short(host)) and this server is still \(short(server)) "
                            + "until it restarts onto the new build, once idle (about 30 seconds); try again in a moment: nothing was installed")
    }

    // MARK: The write

    /// A program written for its rename into `<home>/.vibeswitcher/bin`: `path`, `<folder>/<name>` in a fresh 0700
    /// folder of its own, its descriptor kept open from its write, and the SHA-256 and size of the bytes written.
    final class Staged {
        let folder: String
        let path: String
        let fd: Int32
        let sha256: String
        let size: Int

        init(folder: String, path: String, fd: Int32, sha256: String, size: Int) {
            self.folder = folder
            self.path = path
            self.fd = fd
            self.sha256 = sha256
            self.size = size
        }

        /// Refused unless `path` still names the file written: a regular file, the descriptor's device and inode,
        /// its size what was written.
        func checkUnswapped() throws {
            var held = stat(), named = stat()
            guard fstat(fd, &held) == 0 else { throw Platform.Errno(code: errno) }
            guard lstat(path, &named) == 0, named.st_mode & S_IFMT == S_IFREG, named.st_dev == held.st_dev,
                  named.st_ino == held.st_ino, named.st_size == held.st_size, Int(held.st_size) == size else {
                throw Tampered("\(ConfigSeal.inert(path, limit: .max)) isn't the file written there any more: nothing was renamed")
            }
        }

        /// Renamed to `target`, and the program there read and hashed again: when it isn't the bytes written (a
        /// rewrite in place since), it is taken out again and the rename refused.
        func place(at target: String) throws {
            guard rename(path, target) == 0 else { throw Platform.Errno(code: errno) }
            guard case .success(let data) = BuildRecord.readRegular(target), BuildInfo.sha256(of: data) == sha256 else {
                unlink(target)
                throw Tampered("\(ConfigSeal.inert(target, limit: .max)) wasn't the bytes written after its rename: it was taken out again")
            }
        }

        /// The descriptor closed, the file (unless renamed) and its folder removed.
        func discard() {
            Sys.close(fd)
            unlink(path)
            rmdir(folder)
        }
    }

    /// A staged program changed by someone else between its write and its rename.
    struct Tampered: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    /// `data` written into a new 0700 folder in `<home>/.vibeswitcher` (the file 0755, never following a link) and
    /// flushed, its descriptor kept: for the caller to rename over `<home>/.vibeswitcher/bin/<name>`; nil when the
    /// program there is these bytes already, 0755.
    func stage(_ data: Data, name: String) throws -> Staged? {
        let target = (binFolder as NSString).appendingPathComponent(name)
        var info = stat()
        if lstat(target, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o755,
           case .success(let existing) = BuildRecord.readRegular(target), existing == data { return nil }
        var template = Array((((binFolder as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".\(name).tmp.XXXXXX")).utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else { throw Platform.Errno(code: errno) }
        let folder = String(cString: made)
        let path = (folder as NSString).appendingPathComponent(name)
        let fd = Sys.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o755)
        guard fd >= 0 else {
            let code = errno
            rmdir(folder)
            throw Platform.Errno(code: code)
        }
        let staged = Staged(folder: folder, path: path, fd: fd, sha256: BuildInfo.sha256(of: data), size: data.count)
        var failed: Int32 = 0
        if fchmod(fd, 0o755) != 0 { failed = errno }
        let bytes = [UInt8](data)
        var done = 0
        while failed == 0, done < bytes.count {
            let wrote = bytes.withUnsafeBytes { Sys.write(fd, $0.baseAddress! + done, bytes.count - done) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { failed = wrote < 0 ? errno : EIO; break }
            done += wrote
        }
        if failed == 0, fsync(fd) != 0 { failed = errno }
        guard failed == 0 else {
            staged.discard()
            throw Platform.Errno(code: failed)
        }
        return staged
    }

    static func describe(_ error: Error) -> String {
        if let errno = error as? Platform.Errno { return String(cString: strerror(errno.code)) }
        return error.localizedDescription
    }

    /// A config whose edit failed, with the configs edited before it: thrown out of `appWrite`, so the refusal names
    /// the file and the reason (the first Linux node's said "NSCocoaErrorDomain error 512" and no file).
    struct ConfigFailure: Error {
        let path: String
        let error: Error
        let done: [String]
    }

    /// A path, and why an edit of it failed (`HookInstaller.whyNot`), each for showing on the refusal's one line.
    static func shown(_ path: String) -> String { ConfigSeal.inert(path, limit: .max) }
    static func why(_ error: Error) -> String { ConfigSeal.inert(HookInstaller.whyNot(error), limit: .max) }
}
