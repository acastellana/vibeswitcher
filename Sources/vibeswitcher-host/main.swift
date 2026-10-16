import Foundation
import VibeCore
import VibeHost

// The session host: keeps the window's sessions running while VibeSwitcher quits, crashes or updates.
// The app starts it detached (its own session); it exits by itself once idle. One per user.

// First: as the launcher of a session's program (posix_spawned by the host itself), nothing else runs.
PTYSpawn.execIfLaunched(CommandLine.arguments)

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
var config = HostServer.Config(
    socketPath: value(after: "--socket") ?? VibePaths.hostSocket.path,
    lockPath: value(after: "--lock") ?? VibePaths.hostLock.path,
    shell: shell,
    launcher: Bundle.main.executablePath ?? arguments[0],
    baseEnvironment: environment.filter { inherited.contains($0.key) },
    hostBuild: HostBuild.id(ofExecutableAt: Bundle.main.executablePath ?? arguments[0]))
config.idleExit = value(after: "--idle-exit").flatMap(TimeInterval.init) ?? 600

let server = HostServer(config: config)
server.onExit = { exit(0) }
do {
    try server.start()
} catch HostServer.Failure.alreadyRunning {
    exit(0)
} catch {
    FileHandle.standardError.write(Data("vibeswitcher-host: \(error)\n".utf8))
    exit(1)
}
FileHandle.standardError.write(Data("vibeswitcher-host: started \(Date())\n".utf8))
dispatchMain()
