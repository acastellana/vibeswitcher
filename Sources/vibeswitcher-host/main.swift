import Foundation
import VibeCore
import VibeHost

// The session host: keeps the window's sessions running while VibeSwitcher quits, crashes or updates.
// The app starts it detached (its own session); it exits by itself once idle. One per user.

// First: as the launcher of a session's program (posix_spawned by the host itself), nothing else runs.
PTYSpawn.execIfLaunched(CommandLine.arguments)
// As a session's parser (see `SessionParser`): its headless terminal, fed by the host. Hardened first (see
// `HostHardening`).
SessionParser.runIfAsked(CommandLine.arguments)
// As the probe of a handover (see `HostHandover`): only whether this build can take over.
HostHandover.probeIfAsked(CommandLine.arguments)

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)
// The host, hardened before it reads or takes anything (see `HostHardening`); refused, it doesn't start (or goes back).
let hardening = HostHardening.atStart(mode: .host)
if let why = HostHardening.refusal(hardening, arguments: CommandLine.arguments) {
    FileHandle.standardError.write(Data("vibeswitcher-host: not started: \(why)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

VibePaths.ensurePrivateDirectories()
let environment = ProcessInfo.processInfo.environment
// What a fresh Terminal session would inherit from launchd; the login shell adds the rest.
let inherited = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK",
                 "__CF_USER_TEXT_ENCODING"]
let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? Platform.Tools.loginShell
let executable = Bundle.main.executablePath ?? arguments[0]
let build = HostBuild.id(ofExecutableAt: executable)
let lockPath = value(after: "--lock") ?? VibePaths.hostLock.path
// The user's host, not a scratch host on its own lock (which runs beside it, and leaves its files alone). On Linux by
// the lock file's identity, a link refused (see `HostHardening.lock`); on the Mac by its path, as always.
let ownsLaunchers = HostHardening.ownsLaunchers(lockPath: lockPath, usersLock: VibePaths.hostLock.path)
// Sessions are started through a launcher (see `PTYSpawn`). Not the app's copy: an update replaces that file while
// this host keeps running, and this host must keep starting its own build. A private copy, named by build.
let launchers = VibePaths.root.appendingPathComponent("host", isDirectory: true)
let launcher = launchers.appendingPathComponent("launcher-\(build)").path
func ensureLauncher() -> String {
    try? FileManager.default.createDirectory(at: launchers, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if HostBuild.id(ofExecutableAt: launcher) != build || !FileManager.default.isExecutableFile(atPath: launcher) {
        let partial = launcher + ".partial-\(getpid())"
        try? FileManager.default.removeItem(atPath: partial)
        guard (try? Platform.Files.copyKeepingModificationDate(atPath: executable, toPath: partial)) != nil,
              rename(partial, launcher) == 0 else { return executable }
    }
    return launcher
}
var config = HostServer.Config(
    socketPath: value(after: "--socket") ?? VibePaths.hostSocket.path,
    lockPath: lockPath,
    shell: shell,
    launcher: ensureLauncher(),
    // With vs-heavy on PATH (Mac-wide one-at-a-time heavy work, for every project's sessions).
    baseEnvironment: TestLock.sessionEnvironment(environment.filter { inherited.contains($0.key) },
                                                 adding: TestLock.commandFolder(besideExecutable: executable)),
    hostBuild: build)
config.idleExit = value(after: "--idle-exit").flatMap(TimeInterval.init) ?? 600
// A bench's host: it ends, sessions and all, with the bench (see `HostServer.Config.owner`). Kept through a handover.
config.owner = value(after: "--exit-with").flatMap(pid_t.init).flatMap { $0 > 0 ? $0 : nil }
if let interval = value(after: "--housekeeping").flatMap(TimeInterval.init), interval > 0 { config.housekeepingInterval = interval }
// This process's children are its own sessions' programs and parsers: a parser none holds is ended.
config.endsStrayParsers = true
// The tool servers of this build's sessions sit beside it: one whose agent ended is ended (see `HostServer.endOrphans`).
// By the user's host only (a scratch host beside a build folder would end that folder's, a test's or another run's),
// or a scratch host told to (OrphanSweepTests).
if ownsLaunchers || arguments.contains("--end-orphaned-tool-servers") {
    config.toolServer = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
}
// A scratch host's parsers can be told to stall or trap (tests), and watched more closely.
config.parser.testHooks = !ownsLaunchers && arguments.contains("--parser-test-hooks")
// On Linux the user's host starts a session only for the app and for a session the vault binds to the lead role
// (`HostServer.Config.spawnNeedsLead`); on the Mac, and in a scratch host, any client may, as before.
config.spawnNeedsLead = ownsLaunchers && !Platform.CodeIdentity.isAvailable
// On Linux the user's host takes its socket's and lock's paths back when something else is put there (see
// `HostPathWatch`); on the Mac, and in a scratch host, it doesn't, as before.
config.watchesItsPath = ownsLaunchers && !Platform.CodeIdentity.isAvailable
// On Linux a host that took itself for a scratch host never holds the user's lock (see `HostHardening`).
config.heldLockIsAllowed = HostHardening.heldLockIsAllowed(ownsLaunchers: ownsLaunchers, usersLock: VibePaths.hostLock.path)
if let limit = value(after: "--parser-stall-limit").flatMap(TimeInterval.init), limit > 0 { config.parser.stallLimit = limit }
// The user's host logs its sessions (see `HostLog`); a scratch host only where it's told to.
config.logPath = value(after: "--log") ?? (ownsLaunchers ? VibePaths.root.appendingPathComponent("debug/host.log").path : nil)
// What a build this one hands over to is started with: the same, without this start's handover.
let handoverFlags: [String: Bool] = ["--handover": true, "--handover-fallback": true, "--handover-fail-restore": false,
                                     "--handover-fallback-app": true, "--app-executable": true,
                                     HostStart.appKeyFlag: false].merging(TestAppPrincipal.handoverFlags) { $1 }
config.arguments = HostHardening.withoutTestFlags(arguments.dropFirst().enumerated().reduce(into: (kept: [String](), skip: false)) { result, item in
    if result.skip { result.skip = false; return }
    if let takesValue = handoverFlags[item.element] { result.skip = takesValue; return }
    result.kept.append(item.element)
}.kept)
// This build's own copy, there for as long as it runs: if a build it hands over to can't restore, it comes back to it.
config.fallback = config.launcher == executable ? nil : config.launcher

func log(_ text: String) { FileHandle.standardError.write(Data("vibeswitcher-host: \(text)\n".utf8)) }

/// Back to the build that handed over, after this one couldn't take over: it reads its own state (keeping every
/// descriptor this image inherited). Nobody able to carry the sessions, this host quits: that hangs up their terminals,
/// rather than leaving them running where nothing reaches them.
func goBack(_ statePath: String, _ error: Error) -> Never {
    log("couldn't take over: \(error)")
    if let fallback = value(after: "--handover-fallback") {
        log("going back to \(fallback)")
        var arguments = config.arguments + ["--handover", statePath]
        if let app = value(after: "--handover-fallback-app") { arguments += ["--app-executable", app] }
        log("\(HostHandover.exec(fallback, arguments: arguments, inherit: nil))")
    }
    unlink(statePath)
    exit(1)
}

// The build before handed its sessions over, by executing this one in its place (same process). Read before the
// server is made: what it kept in memory (`HostServer.secretsForHandover`) can go into this one's config.
let handoverPath = HostHardening.handover(in: arguments)
var restoring: HostHandover.State?
var restoredSecrets: Data?
if let handoverPath {
    // Refused at its start (traced): back to the build before, its state and secrets unread here.
    if case .refused(let why) = hardening { goBack(handoverPath, HostHardening.Refused(why)) }
    do {
        // A test of the fallback: as if this build couldn't read the state.
        if arguments.contains("--handover-fail-restore") { throw HostHandover.Failure.unreadable("--handover-fail-restore") }
        var state = try HostHandover.read(from: handoverPath)
        restoredSecrets = HostHandover.takeSecrets(from: &state)
        restoring = state
    } catch {
        goBack(handoverPath, error)
    }
}

// Only an actual restoration may carry the original app's location from the old host's argv.
// A fresh launch must not let a script designate itself as the app and replace a keyless host's key.
config.appExecutable = (restoring != nil ? value(after: "--app-executable") : nil)
    ?? URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("VibeSwitcher").path
// The lead's vault: the user's host keeps it sealed under ~/.vibeswitcher/lead with its Keychain key; a scratch host
// (on its own lock) keeps one in memory only, never touching the user's.
// After a handover, the vault is the one the build before held in memory (its secrets), not what's on disk.
let vaultFile = VibePaths.root.appendingPathComponent("lead/vault.sealed")
config.vault = ownsLaunchers ? VaultStorage(file: vaultFile, key: VaultStorage.keychainKey(), logPath: config.logPath).book(handedOver: restoredSecrets)
    : LeadVault.Book(restoring: restoredSecrets)
// The app that started this host gives it its key on stdin (see `AppProof`), and says so: taken while the vault
// holds none.
if arguments.contains(HostStart.appKeyFlag), let key = HostStart.appKeyFromStdin(), let vault = config.vault, !vault.adoptAppKey(key) {
    log("the app key on stdin isn't the one the vault holds: kept the vault's")
}

let server = HostServer(config: config)
server.onExit = { exit(0) }
// The test-only flags the user's host refuses, said; who an unreadable process is to this host (see `HostHardening`).
HostHardening.afterConfig(arguments: Array(arguments.dropFirst()), ownsLaunchers: ownsLaunchers, server: server)
HostHardening.watch(server)
// The vault is what a build this one hands over to must hold in memory too.
if let vault = config.vault { server.secretsForHandover = { vault.serialized } }
// A test of the secret channel: these bytes are handed over, and the next build says whether it got them.
let testSecret = HostHardening.takesTestFlags(ownsLaunchers: ownsLaunchers) ? value(after: "--handover-test-secret").map { Data($0.utf8) } : nil
if let testSecret { server.secretsForHandover = { testSecret } }
// Ended by a signal: said in the log first (with who sent it), then ended by it as before. Installed before
// `start()` (or `start(restoring:)`), which logs "host: started": a signal from then on is always logged. Sessions
// outlive the host either way; they lose their terminal. The handler only writes the signal and its sender to a
// pipe. A handover's exec puts the signals back to their defaults: the new build installs its own here.
var signalPipe: [Int32] = [-1, -1]
_ = Sys.pipeClosedOnExec(&signalPipe)
nonisolated(unsafe) var signalPipeWriter = signalPipe[1]
for number in [SIGTERM, SIGINT] {
    Platform.Signals.onSignal([number]) { number, info, _ in
        var said: (Int32, Int32) = (number, Platform.Signals.sender(info))
        _ = withUnsafeBytes(of: &said) { write(signalPipeWriter, $0.baseAddress, $0.count) }
    }
}
let signals = DispatchSource.makeReadSource(fileDescriptor: signalPipe[0], queue: server.queue)
signals.setEventHandler {
    var said: (Int32, Int32) = (0, 0)
    guard withUnsafeMutableBytes(of: &said, { read(signalPipe[0], $0.baseAddress, $0.count) }) == MemoryLayout.size(ofValue: said) else { return }
    let (number, sender) = said
    let who = sender > 0 ? "pid \(sender)" + (ProcessTable.info(pid: sender).map { " (\($0.comm))" } ?? "") : "an unknown process"
    server.note("host: got \(HostSession.Exit.signalName(number)) from \(who), exiting")
    signal(number, SIG_DFL)
    // To the process (this queue's thread blocks it); exiting outright if it still isn't delivered.
    kill(getpid(), number)
    server.queue.asyncAfter(deadline: .now() + 1) { _exit(128 + number) }
}
signals.resume()
if let handoverPath, let state = restoring {
    do {
        _ = try server.start(restoring: state)
        unlink(handoverPath)
        if let testSecret { log("test secret carried: \(restoredSecrets == testSecret ? "yes" : "no")") }
        log("took over \(state.sessions.count) sessions\(restoredSecrets.map { " and \($0.count) bytes of secrets" } ?? "") from build \(state.fromBuild) \(Date())")
    } catch {
        goBack(handoverPath, error)
    }
} else {
    do {
        try server.start()
    } catch HostServer.Failure.alreadyRunning {
        server.note("host: another host holds the lock; this one (build \(build)) exits")
        exit(0)
    } catch {
        log("\(error)")
        exit(1)
    }
}
// A scratch host's test stand-in for the app on Linux: refused by the user's host (see `TestAppPrincipal`).
TestAppPrincipal.adopt(arguments: arguments, restored: restoring?.testAppConnector, ownsLaunchers: ownsLaunchers, server: server)
// The app on Linux: the server child, from a sealed copy of `--server PATH`, through its connector (see `ServerChild`);
// after a handover, the one the build before ran, once checked.
ServerChild.adopt(arguments: arguments, ownsLaunchers: ownsLaunchers, executable: executable, config: config, server: server, restored: restoring)
// Holding the user's lock now: no other host runs, so other builds' launchers can go (not for a scratch host on
// its own lock, which runs beside the real one).
for name in (try? FileManager.default.contentsOfDirectory(atPath: launchers.path)) ?? [] where ownsLaunchers && name != "launcher-\(build)" {
    try? FileManager.default.removeItem(at: launchers.appendingPathComponent(name))
}
// Earlier versions kept the user's sealing key and the teams in files any of the team could read: gone.
if ownsLaunchers {
    try? FileManager.default.removeItem(at: VibePaths.root.appendingPathComponent("steer/sender.key"))
    try? FileManager.default.removeItem(at: VibePaths.root.appendingPathComponent("lead/teams"))
}
FileHandle.standardError.write(Data("vibeswitcher-host: started \(Date())\n".utf8))
dispatchMain()
