import Foundation
import VibeCore
import VibeHost

// The session host: keeps the window's sessions running while VibeSwitcher quits, crashes or updates.
// The app starts it detached (its own session); it exits by itself once idle. One per user.

// First: as the launcher of a session's program (posix_spawned by the host itself), nothing else runs.
PTYSpawn.execIfLaunched(CommandLine.arguments)
// As the probe of a handover (see `HostHandover`): only whether this build can take over.
HostHandover.probeIfAsked(CommandLine.arguments)

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)

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
let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
let executable = Bundle.main.executablePath ?? arguments[0]
let build = HostBuild.id(ofExecutableAt: executable)
let lockPath = value(after: "--lock") ?? VibePaths.hostLock.path
// The user's host, not a scratch host on its own lock (which runs beside it, and leaves its files alone).
let ownsLaunchers = lockPath == VibePaths.hostLock.path
// Sessions are started through a launcher (see `PTYSpawn`). Not the app's copy: an update replaces that file while
// this host keeps running, and this host must keep starting its own build. A private copy, named by build.
let launchers = VibePaths.root.appendingPathComponent("host", isDirectory: true)
let launcher = launchers.appendingPathComponent("launcher-\(build)").path
func ensureLauncher() -> String {
    try? FileManager.default.createDirectory(at: launchers, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if HostBuild.id(ofExecutableAt: launcher) != build || !FileManager.default.isExecutableFile(atPath: launcher) {
        let partial = launcher + ".partial-\(getpid())"
        try? FileManager.default.removeItem(atPath: partial)
        guard (try? FileManager.default.copyItem(atPath: executable, toPath: partial)) != nil,
              rename(partial, launcher) == 0 else { return executable }
    }
    return launcher
}
var config = HostServer.Config(
    socketPath: value(after: "--socket") ?? VibePaths.hostSocket.path,
    lockPath: lockPath,
    shell: shell,
    launcher: ensureLauncher(),
    baseEnvironment: environment.filter { inherited.contains($0.key) },
    hostBuild: build)
config.idleExit = value(after: "--idle-exit").flatMap(TimeInterval.init) ?? 600
// The user's host logs its sessions (see `HostLog`); a scratch host only where it's told to.
config.logPath = value(after: "--log") ?? (ownsLaunchers ? VibePaths.root.appendingPathComponent("debug/host.log").path : nil)
// What a build this one hands over to is started with: the same, without this start's handover.
let handoverFlags: [String: Bool] = ["--handover": true, "--handover-fallback": true, "--handover-fail-restore": false]
config.arguments = arguments.dropFirst().enumerated().reduce(into: (kept: [String](), skip: false)) { result, item in
    if result.skip { result.skip = false; return }
    if let takesValue = handoverFlags[item.element] { result.skip = takesValue; return }
    result.kept.append(item.element)
}.kept
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
        log("\(HostHandover.exec(fallback, arguments: config.arguments + ["--handover", statePath], inherit: nil))")
    }
    unlink(statePath)
    exit(1)
}

// The build before handed its sessions over, by executing this one in its place (same process). Read before the
// server is made: what it kept in memory (`HostServer.secretsForHandover`) can go into this one's config.
let handoverPath = value(after: "--handover")
var restoring: HostHandover.State?
var restoredSecrets: Data?
if let handoverPath {
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

let server = HostServer(config: config)
server.onExit = { exit(0) }
// A test of the secret channel: these bytes are handed over, and the next build says whether it got them.
let testSecret = value(after: "--handover-test-secret").map { Data($0.utf8) }
if let testSecret { server.secretsForHandover = { testSecret } }
// Ended by a signal: said in the log first (with who sent it), then ended by it as before. Installed before
// `start()` (or `start(restoring:)`), which logs "host: started": a signal from then on is always logged. Sessions
// outlive the host either way; they lose their terminal. The handler only writes the signal and its sender to a
// pipe. A handover's exec puts the signals back to their defaults: the new build installs its own here.
var signalPipe: [Int32] = [-1, -1]
pipe(&signalPipe)
signalPipe.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
nonisolated(unsafe) var signalPipeWriter = signalPipe[1]
for number in [SIGTERM, SIGINT] {
    var action = sigaction()
    action.__sigaction_u.__sa_sigaction = { number, info, _ in
        var said: (Int32, Int32) = (number, info?.pointee.si_pid ?? 0)
        _ = withUnsafeBytes(of: &said) { write(signalPipeWriter, $0.baseAddress, $0.count) }
    }
    action.sa_flags = SA_SIGINFO
    sigaction(number, &action, nil)
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
// Holding the user's lock now: no other host runs, so other builds' launchers can go (not for a scratch host on
// its own lock, which runs beside the real one).
for name in (try? FileManager.default.contentsOfDirectory(atPath: launchers.path)) ?? [] where ownsLaunchers && name != "launcher-\(build)" {
    try? FileManager.default.removeItem(at: launchers.appendingPathComponent(name))
}
FileHandle.standardError.write(Data("vibeswitcher-host: started \(Date())\n".utf8))
dispatchMain()
