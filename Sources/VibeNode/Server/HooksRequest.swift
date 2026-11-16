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
///   Those bytes, never a second read, are written to a temporary beside `<home>/.vibeswitcher/bin` (in
///   `<home>/.vibeswitcher`: the bin folder is watched, and a look while a temporary is in it would hold it) and renamed
///   in. Then each agent's config (`HookInstaller.configURL(for:home:)`) gets the hooks, running
///   `<home>/.vibeswitcher/bin/vibeswitcher-hook`.
/// - Remove takes only VibeSwitcher's hooks out of each config (`HookInstaller.uninstall`); the programs stay.
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
/// Blocking (the vault's calls go to the host): the server runs it on the engine's read queue, never its own.
public struct HooksRequest {
    /// What an install wrote: the programs' paths and the configs', as written.
    public struct Installed: Equatable, Sendable {
        public var programs: [String]
        public var configs: [String]
    }

    /// The programs an agent's session runs that install puts in `<home>/.vibeswitcher/bin`.
    public static let programs = ["vibeswitcher-hook", "vibeswitcher-mcp"]
    /// The installed builds' folder, by its seal name (a name, not a path: nothing reads the home here).
    public static var buildsName: String { "~/.vibeswitcher/v2/builds" }

    public let nodeRoot: String
    public let home: String
    public let binaries: [String: String]?
    public let vault: LeadVault

    public init(nodeRoot: String, home: String, binaries: [String: String]?, vault: LeadVault) {
        self.nodeRoot = nodeRoot
        self.home = home
        self.binaries = binaries
        self.vault = vault
    }

    /// `<home>/.vibeswitcher/bin`, as the seal spells it.
    public var binFolder: String { (home as NSString).appendingPathComponent(".vibeswitcher/bin") }

    /// Where `agent` reads its hooks in this home.
    public func configPath(_ agent: Agent) -> String { HookInstaller.configURL(for: agent, home: home).path }

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
        do {
            try vault.appWrite(targets + configs, home: home) {
                try VibePaths.ensurePrivate(URL(fileURLWithPath: binFolder, isDirectory: true),
                                            within: URL(fileURLWithPath: home).appendingPathComponent(".vibeswitcher", isDirectory: true))
                for name in Self.programs { try put(read[name] ?? Data(), name: name) }
                for agent in agents { try HookInstaller.install(agent: agent, at: URL(fileURLWithPath: configPath(agent)), hookBinary: hook) }
            }
        } catch {
            vault.sealAppWrites()
            return .failure(StartRefusal("the hooks weren't all installed: \(ConfigSeal.inert(Self.describe(error), limit: .max))", exitCode: 1))
        }
        vault.sealAppWrites()
        return .success(Installed(programs: targets, configs: configs))
    }

    public func remove(agents: [Agent]) -> Result<Void, StartRefusal> {
        guard !agents.isEmpty else { return .failure(StartRefusal("no agent named")) }
        do {
            try vault.appWrite(agents.map(configPath), home: home) {
                for agent in agents { try HookInstaller.uninstall(agent: agent, at: URL(fileURLWithPath: configPath(agent))) }
            }
        } catch {
            vault.sealAppWrites()
            return .failure(StartRefusal("the hooks weren't all removed: \(ConfigSeal.inert(Self.describe(error), limit: .max))", exitCode: 1))
        }
        vault.sealAppWrites()
        return .success(())
    }

    // MARK: The checks

    /// Refused while the builds folder has a change the seal holds, or one since the vault recorded it.
    func buildsRefusal() -> StartRefusal? {
        guard let builds = ConfigSeal.homeWatched(home: home).first(where: { $0.name == Self.buildsName }) else { return nil }
        let record: [String: String]?
        do { record = try vault.guardedRecord(root: home) } catch {
            return StartRefusal("the vault can't be asked what it holds of \(Self.buildsName): \(ConfigSeal.inert("\(error)", limit: .max))", exitCode: 1)
        }
        let accept = "look with `vibeswitcher config held FOLDER` and accept it first"
        if ConfigSeal.held(in: record).contains(Self.buildsName) {
            return StartRefusal("\(Self.buildsName) holds a change not accepted: \(accept)")
        }
        guard let recorded = record?[ConfigSeal.keyPrefix + Self.buildsName] else { return nil }
        guard ConfigSeal.fingerprint(builds) == recorded else {
            return StartRefusal("\(Self.buildsName) changed since the vault recorded it: \(accept)")
        }
        return nil
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
                return .failure(StartRefusal("\(shown) isn't the \(name) the host's build-info names (its SHA-256 differs): nothing was installed"))
            }
            return .success(data)
        }
    }

    // MARK: The write

    /// `data` written to a new temporary in `<home>/.vibeswitcher` (0755, never following a link), then renamed over
    /// `<home>/.vibeswitcher/bin/<name>`; nothing when the program there is these bytes already, 0755.
    func put(_ data: Data, name: String) throws {
        let target = (binFolder as NSString).appendingPathComponent(name)
        var info = stat()
        if lstat(target, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o755,
           case .success(let existing) = BuildRecord.readRegular(target), existing == data { return }
        let temporary = ((binFolder as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".\(name).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        let fd = Sys.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o755)
        guard fd >= 0 else { throw Platform.Errno(code: errno) }
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
        Sys.close(fd)
        if failed == 0, rename(temporary, target) != 0 { failed = errno }
        guard failed == 0 else {
            unlink(temporary)
            throw Platform.Errno(code: failed)
        }
    }

    static func describe(_ error: Error) -> String {
        if let errno = error as? Platform.Errno { return String(cString: strerror(errno.code)) }
        return error.localizedDescription
    }
}
