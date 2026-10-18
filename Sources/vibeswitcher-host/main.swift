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
    lockPath: value(after: "--lock") ?? VibePaths.hostLock.path,
    shell: shell,
    launcher: ensureLauncher(),
    baseEnvironment: environment.filter { inherited.contains($0.key) },
    hostBuild: build)
config.idleExit = value(after: "--idle-exit").flatMap(TimeInterval.init) ?? 600
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

let server = HostServer(config: config)
server.onExit = { exit(0) }
if let statePath = value(after: "--handover") {
    // The build before handed its sessions over, by executing this one in its place (same process).
    do {
        // A test of the fallback: as if this build couldn't read the state.
        if arguments.contains("--handover-fail-restore") { throw HostHandover.Failure.unreadable("--handover-fail-restore") }
        let state = try HostHandover.read(from: statePath)
        _ = try server.start(restoring: state)
        unlink(statePath)
        log("took over \(state.sessions.count) sessions from build \(state.fromBuild) \(Date())")
    } catch {
        log("couldn't take over: \(error)")
        // Back to the build that handed over: it reads its own state (keeping every descriptor this image inherited).
        if let fallback = value(after: "--handover-fallback") {
            log("going back to \(fallback)")
            let failure = HostHandover.exec(fallback, arguments: config.arguments + ["--handover", statePath], inherit: nil)
            log("\(failure)")
        }
        // Nobody can carry the sessions: quitting hangs up their terminals, rather than leaving them running unreachable.
        unlink(statePath)
        exit(1)
    }
} else {
    do {
        try server.start()
    } catch HostServer.Failure.alreadyRunning {
        exit(0)
    } catch {
        log("\(error)")
        exit(1)
    }
}
// Holding the user's lock now: no other host runs, so other builds' launchers can go (not for a scratch host on
// its own lock, which runs beside the real one).
let ownsLaunchers = config.lockPath == VibePaths.hostLock.path
for name in (try? FileManager.default.contentsOfDirectory(atPath: launchers.path)) ?? [] where ownsLaunchers && name != "launcher-\(build)" {
    try? FileManager.default.removeItem(at: launchers.appendingPathComponent(name))
}
FileHandle.standardError.write(Data("vibeswitcher-host: started \(Date())\n".utf8))
dispatchMain()
