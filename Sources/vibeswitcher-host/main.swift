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
// As the probe of a handover (see `HostHandover`): only whether this build can take over, and for the account's host
// whether it gets the same vault key (asked only by the account's host on the Mac: `--handover-probe-key`). Which host
// the probe is, as the host below asks it (see `HostRole`), from its own command line and environment.
HostHandover.probeIfAsked(CommandLine.arguments) {
    let line = CommandLine.arguments
    let lock = line.firstIndex(of: "--lock").flatMap { line.indices.contains($0 + 1) ? line[$0 + 1] : nil }
    let role = HostRole(environment: ProcessInfo.processInfo.environment, fallbackHome: NSHomeDirectory(), lockArgument: lock,
                        accountHome: HostRole.accountHome)
    return role.vaultKey { VaultStorage.keychainKey() }?.key
}
// As the keeper of a Mac switch (V2/MacHandoverKeeper.swift): it proves its code, holds the state, gives it back only
// to a new image that proves its own, and exits.
MacHandoverKeeper.keepIfAsked(CommandLine.arguments)
// As the node's egress proxy for its confined sessions (the session sandbox plan's SB9, `EgressProxy`). Hardened first.
EgressProxy.runIfAsked(CommandLine.arguments)

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)
// The host, hardened before it reads or takes anything (see `HostHardening`); refused, it doesn't start (or goes back).
var hardening = HostHardening.atStart(mode: .host)
if let why = HostHardening.refusal(hardening, arguments: CommandLine.arguments) {
    Platform.Stdio.error("vibeswitcher-host: not started: \(why)\n")
    exit(1)
}

// The Mac's node (`--node` anywhere on its command line): that command line is read once, by the checked start's
// parser (`HostImages.startAsNode`, `CheckedCommandLine`), and every reader here and in the helpers sees the executable
// alone, so none can read it differently (the re-check's I1). What needs the node's values takes them from the value.
let isMacNode = Platform.CodeIdentity.isAvailable && CommandLine.arguments.dropFirst().contains(HostImages.nodeFlag)
let arguments = isMacNode ? Array(CommandLine.arguments.prefix(1)) : CommandLine.arguments
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
func notStarted(_ why: String) -> Never {
    Platform.Stdio.error("vibeswitcher-host: not started: \(why)\n")
    exit(1)
}

// The node's host (`--node`, Linux): HOME from the user database, VIBESWITCHER_HOME and CFFIXED_USER_HOME unset,
// before anything reads a path; its --node-root and its own --server needed (see V2/HostImages.swift). Refused, it
// doesn't start, or, as a new image of a handover, goes back (below).
var startRefusal = HostImages.startAsNode(arguments: isMacNode ? CommandLine.arguments : arguments)
// A Mac node refused stops here, whatever its command line said (no going back, no state read).
if isMacNode, let startRefusal { notStarted(startRefusal) }
// The Mac's checked node start (behind `isCheckedMacNode`, never yet): what it found, and its command line as the value
// renders it, for the helpers that take the node's values (its folders, its server child).
let checkedStart = isMacNode ? HostImages.takeCheckedMacNode() : nil
let nodeArguments = checkedStart.map { Array(CommandLine.arguments.prefix(1)) + $0.commandLine.rendered } ?? arguments
// A scratch host shaped as a checked node for its sessions' tests (`--test-checked-shape HOME`, V2/CheckedSessions.swift):
// reset as one is, HOME the given scratch home; refused for the user's host, a node and the node's lock.
var testShapeHome: String?
switch CheckedSessions.takeTestShape(arguments: arguments, isMacNode: isMacNode, lock: value(after: "--lock"), usersLock: VibePaths.hostLock.path) {
case .failure(let why)?: notStarted(why.description)
case .success(let home)?: testShapeHome = home
case nil: break
}

// Made first: which host this is is asked of the folder as it is on disk.
VibePaths.ensurePrivateDirectories()
// Which host this is (see `HostRole`): its folder, its lock, and whether it's the account's own host (its folder the
// account's real home, from the user database, and that folder's lock): only that one uses the vault's Keychain key.
// Asked after the node's start above, which on Linux has set HOME and VIBESWITCHER_HOME as the node's.
let role = HostRole(environment: ProcessInfo.processInfo.environment, fallbackHome: NSHomeDirectory(),
                    lockArgument: value(after: "--lock"), accountHome: HostRole.accountHome)
let lockPath = role.lockPath
let environment = ProcessInfo.processInfo.environment
// What a fresh Terminal session would inherit from launchd, the login shell adding the rest (the Mac); on Linux no
// agent socket, interop, bus, display or runtime folder. Then what every session gets (see `Platform.Tools`).
let inherited = Platform.Tools.sessionEnvironmentNames
let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? Platform.Tools.loginShell
let executable = Bundle.main.executablePath ?? arguments[0]
// This build's folders: on Linux from --node-root, else --image-path, else the executable (see V2/HostImages.swift).
let folders = HostImages.folders(arguments: nodeArguments, executable: executable)
let build = HostBuild.id(ofExecutableAt: folders.image)
// The user's host, not a scratch host on its own lock (which runs beside it, and leaves its files alone). On the Mac on
// its folder's own lock (`HostRole.holdsRootLock`); on Linux by the lock file's identity, a link refused (see
// `HostHardening.lock`). On Linux a new image after a handover is the user's host too when the state the image before
// wrote says so (V2/HandoverMemory.swift).
let ownsLaunchers = HandoverMemory.ownsLaunchers(probed: Platform.CodeIdentity.isAvailable ? role.holdsRootLock
                                                     : HostHardening.ownsLaunchers(lockPath: lockPath, usersLock: VibePaths.hostLock.path),
                                                 arguments: arguments, hardening: hardening, refused: startRefusal != nil)
// A scratch host's test of a traced new image (Linux): refused as if traced, so it goes back (V2/HandoverMemory.swift).
if let traced = HandoverMemory.testTracer(arguments: arguments, ownsLaunchers: ownsLaunchers) { hardening = traced }
// On Linux the account's own lock is the node's host's alone, and the user's host (probed or carried) passes the same
// checks for the user's lock; its own image and, with --node-root, its server read into sealed copies, checked
// against build-info (see V2/HostImages.swift).
startRefusal = startRefusal ?? HostImages.mayStart(lockPath: lockPath, usersLock: VibePaths.hostLock.path,
                                                   accountRoot: (HostImages.accountHome ?? "/nonexistent") + "/.vibeswitcher",
                                                   node: arguments.contains(HostImages.nodeFlag), ownsLaunchers: ownsLaunchers)
var images = HostImages.Loaded(own: nil, server: nil)
if startRefusal == nil {
    switch HostImages.load(arguments: arguments) {
    case .success(let loaded): images = loaded
    case .failure(let why): startRefusal = why.description
    }
}
if let startRefusal, HostHardening.handover(in: arguments) == nil { notStarted(startRefusal) }
// Sessions are started through a launcher (see `PTYSpawn`). Not the app's copy: an update replaces that file while
// this host keeps running, and this host must keep starting its own build. A private copy, named by build.
let launchers = role.root.appendingPathComponent("host", isDirectory: true)
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
// Its socket: a host on a lock of its own on the account's folder, with none given, doesn't start (see
// `HostRole.socketPath`), before it touches that folder's files or the socket there. Not a handover's: the sessions are
// in this process already.
guard let socketPath = role.socketPath(argument: value(after: "--socket"), handingOver: value(after: "--handover") != nil) else {
    Platform.Stdio.error("vibeswitcher-host: on \(lockPath), not \(role.root.path)'s own lock, and no "
        + "--socket: not started (its host.sock is that folder's host's)\n")
    exit(1)
}
var config = HostServer.Config(
    socketPath: socketPath,
    lockPath: lockPath,
    shell: shell,
    // On Linux its own sealed copy (no launcher copy made); on the Mac a private copy, as always.
    launcher: images.own?.path ?? (startRefusal == nil ? ensureLauncher() : executable),
    // With vs-heavy on PATH (Mac-wide one-at-a-time heavy work, for every project's sessions); on Linux last (V2/HostImages.swift).
    // Then, on a Linux node, the folder of its external plugins' wrappers (`vs-wallet` while that plugin is on), last too.
    baseEnvironment: HostImages.sessionEnvironment(HostImages.sessionEnvironment(environment.filter { inherited.contains($0.key) }
                                                     .merging(Platform.Tools.sessionEnvironmentFixed) { $1 },
                                                 adding: folders.commandFolder),
                                                 adding: Platform.CodeIdentity.isAvailable ? nil : VibePaths.root.appendingPathComponent("plugins/bin").path),
    hostBuild: build)
config.checkedNode = checkedStart
// A checked node's sessions are given back what its reset took, on their spawn alone (V2/CheckedSessions.swift), as are a
// scratch host's shaped as one; and no Swift child of the node (the server child, the launchers, the parsers) starts the
// backtracer, as Linux's fixed list gives (the plist's SWIFT_BACKTRACE acted on this process only, before its reset).
if Platform.CodeIdentity.isAvailable, checkedStart != nil || testShapeHome != nil, let home = testShapeHome ?? HostImages.accountHome {
    config.checkedSessions = CheckedSessions.read(uid: getuid(), accountHome: home)
    config.baseEnvironment["SWIFT_BACKTRACE"] = "enable=no"
}
if let why = HostImages.checkedNodeRefusal(config.checkedNode, ownsLaunchers: ownsLaunchers) { notStarted(why) }
// Only a checked node starts on the node's lock, by file (the re-check's I2c): one check, in place of refusing each test
// flag such a host might be given.
if config.checkedNode == nil, HostImages.isNodeLock(lockPath, accountHome: HostImages.accountHome) {
    notStarted("the lock \(lockPath) is the node's own: only a checked node start takes it")
}
// A scratch host's test of the Mac's switch through a keeper (`HostServer.Config.testKeeperHost`): never the user's
// host's, nor a checked node host's.
if Platform.CodeIdentity.isAvailable, !ownsLaunchers, config.checkedNode == nil {
    config.testKeeperHost = value(after: "--handover-test-keeper").flatMap(NodePins.bytes)
    config.testSwapAfterCheck = value(after: "--handover-test-swap-after-check")
    config.testSwapBeforeExec = value(after: "--handover-test-swap-before-exec")
    config.testKeeperLimit = value(after: "--handover-test-keeper-limit").flatMap(TimeInterval.init)
}
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
    config.toolServer = folders.toolServer
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
// The Mac: a host that isn't a checked node holds no lock that is the node's own once opened, by its descriptor (another
// letter case, a dangling link: the re-check's round 2, note 1).
if Platform.CodeIdentity.isAvailable, checkedStart == nil { config.heldLockIsAllowed = { HostImages.heldLockAllowed($0, accountHome: HostImages.accountHome) } }
// On Linux the node's host hands over only to a build installed under ~/.vibeswitcher/v2/builds that it checked; a
// scratch host to one under its --install-root; any other to any build, as before (see V2/HandoverTarget.swift).
config.installRoot = HandoverTarget.installRoot(arguments: arguments, ownsLaunchers: ownsLaunchers, accountHome: HostImages.accountHome)
// On Linux the node's host starts sessions only inside the repositories ~/.vibeswitcher/v2/projects names; every other
// host, and the Mac, anywhere, as before (see V2/ProjectAllowList.swift).
config.projectAllowList = ProjectAllowList.place(arguments: arguments, accountHome: HostImages.accountHome)
if let limit = value(after: "--parser-stall-limit").flatMap(TimeInterval.init), limit > 0 { config.parser.stallLimit = limit }
// The user's host logs its sessions (see `HostLog`); a scratch host only where it's told to.
config.logPath = value(after: "--log") ?? (ownsLaunchers ? role.root.appendingPathComponent("debug/host.log").path : nil)
// What a build this one hands over to is started with: the same, without this start's handover.
let handoverFlags: [String: Bool] = ["--handover": true, "--handover-fallback": true, "--handover-fail-restore": false,
                                     "--handover-fallback-app": true, "--app-executable": true, HostHandover.proofFlag: true,
                                     HostStart.appKeyFlag: false, HostImages.imagePathFlag: true, HandoverMemory.fallbackImageFlag: true,
                                     MacHandoverKeeper.channelFlag: true, MacHandoverKeeper.pidFlag: true].merging(TestAppPrincipal.handoverFlags) { $1 }
    // On Linux --node-root and --server too: a handover appends the target's, and its fallback's (V2/HandoverMemory.swift).
    .merging(HandoverMemory.handoverFlags) { $1 }
config.arguments = HostHardening.withoutTestFlags(arguments.dropFirst().enumerated().reduce(into: (kept: [String](), skip: false)) { result, item in
    if result.skip { result.skip = false; return }
    if let takesValue = handoverFlags[item.element] { result.skip = takesValue; return }
    result.kept.append(item.element)
}.kept, ownsLaunchers: ownsLaunchers)
// A checked node's next image is started with its own command line, from the value (its keeper's flags left out).
if let checkedStart {
    var line = checkedStart.commandLine
    line.keeper = nil
    config.arguments = line.rendered
}
// This build's own copy, there for as long as it runs: if a build it hands over to can't restore, it comes back to it.
// On Linux what runs is its own sealed copy (`HostImages.ownCopy`, carried across the exec: V2/HandoverMemory.swift);
// this path only names it, as `--handover-fallback-image` (its build and folders). The Mac: its launcher copy, by path.
config.fallback = images.own != nil ? folders.image : config.launcher == executable ? nil : config.launcher

func log(_ text: String) { Platform.Stdio.error("vibeswitcher-host: \(text)\n") }

/// Back to the build that handed over, after this one couldn't take over: it reads its own state (keeping every
/// descriptor this image inherited). Nobody able to carry the sessions, this host quits: that hangs up their terminals,
/// rather than leaving them running where nothing reaches them.
func goBack(_ statePath: String, _ error: Error) -> Never {
    log("couldn't take over: \(error)")
    if let fallback = value(after: "--handover-fallback") {
        log("going back to \(fallback)")
        var arguments = config.arguments + ["--handover", statePath]
        if let app = value(after: "--handover-fallback-app") { arguments += ["--app-executable", app] }
        // The proof holds for the build before too: the same process, state and lock (the Mac's; Linux carries none).
        if let proof = value(after: HostHandover.proofFlag) { arguments += [HostHandover.proofFlag, proof] }
        // On Linux the old image's sealed copy, carried across the exec, by its path's name (V2/HandoverMemory.swift).
        log("\(HandoverMemory.goBack(to: fallback, image: value(after: HandoverMemory.fallbackImageFlag), arguments: arguments) ?? HostHandover.exec(fallback, arguments: arguments, inherit: nil))")
    }
    // On Linux the state is sealed memory, no file: nothing to remove.
    if HandoverMemory.descriptor(named: statePath) == nil { unlink(statePath) }
    exit(1)
}

// The build before handed its sessions over, by executing this one in its place (same process). Read before the
// server is made: what it kept in memory (`HostServer.secretsForHandover`) can go into this one's config.
let handoverPath = HostHardening.handover(in: arguments)
// A fresh start takes its lock first, before the vault's key or file is read: another host holding it, this one
// exits having read neither. A handover inherits the lock of the build before (checked by `HostHandover.receive` on the
// Mac, by `HandoverMemory` on Linux), and so does a checked node's switch through its keeper (`HostImages.mayTakeHandover`).
var heldLock: Int32 = -1
if handoverPath == nil, checkedStart?.commandLine.keeper == nil {
    do {
        heldLock = try role.takeLock()
    } catch HostServer.Failure.alreadyRunning {
        HostServer.note("host: another host holds the lock; this one (build \(build)) exits", logPath: config.logPath)
        exit(0)
    } catch {
        log("\(error)")
        exit(1)
    }
}
// The vault's Keychain key, for the account's host only, read once and only when first asked: whether it was made
// on this read is known from that one read alone (a second finds the one the first made).
// Nil for any host but the account's, which reads none, and on Linux, which has no Keychain.
var vaultKeyRead: VaultStorage.KeyRead??
func vaultKeyResult() -> VaultStorage.KeyRead? {
    if let read = vaultKeyRead { return read }
    let read = role.vaultKey { VaultStorage.keychainKey() }
    vaultKeyRead = .some(read)
    // Which status kept the key (never the key): a host without it can't open the vault, seal it, or take a handover.
    if let status = read?.failure { HostServer.note("vault key: Keychain status \(status)", logPath: config.logPath) }
    return read
}
func vaultKey() -> VaultStorage.Key? { vaultKeyResult()?.read }
var restoring: HostHandover.State?
var restoredSecrets: Data?
// The state as handed over, its secrets' descriptor still named: what `HandoverMemory.finish` closes once restored.
var handedOver: HostHandover.State?
if let checkedStart, let keeper = checkedStart.commandLine.keeper {
    // A checked node's switch: the state only from the keeper it proved, only a checked node's, only holding the node's
    // lock; any refusal closes everything with this process (the re-check's I2). No state file, no going back.
    switch MacHandoverKeeper.take(channel: keeper.channel, keeper: keeper.pid) {
    case .failure(let why): notStarted("couldn't take over: \(why.description)")
    case .success(var state):
        if let why = HostImages.mayTakeHandover(state, viaKeeper: true, checkedNode: checkedStart, lockPath: lockPath) { notStarted(why) }
        handedOver = state
        restoredSecrets = HostHandover.takeSecrets(from: &state)
        restoring = state
    }
} else if let handoverPath {
    // Refused at its start (traced): back to the build before, its state and secrets unread here.
    if case .refused(let why) = hardening { goBack(handoverPath, HostHardening.Refused(why)) }
    if let startRefusal { goBack(handoverPath, HostHardening.Refused(startRefusal)) }
    do {
        // A test of the fallback: as if this build couldn't read the state (on Linux, once it has read it and its
        // secrets, below: V2/HandoverMemory.swift).
        if arguments.contains("--handover-fail-restore"), !HandoverMemory.failsRestoreLate { throw HostHandover.Failure.unreadable("--handover-fail-restore") }
        // A checked node's state only to a checked start, and a checked start's only from a proven keeper: otherwise
        // nothing is taken, and the exit closes every descriptor this image was given (the review's F1, N2).
        func admit(_ state: HostHandover.State, viaKeeper: Bool) {
            if let why = HostImages.mayTakeHandover(state, viaKeeper: viaKeeper, checkedNode: config.checkedNode) { notStarted(why) }
        }
        // A Mac switch through a keeper: the state it held, given only once this image proved its code to it. A scratch
        // host's alone (`HostServer.Config.testKeeperHost`): the account's host takes a handover only with its proof
        // (`HostHandover.receive`), which a keeper a process of the account started itself wouldn't carry.
        if !role.isAccountHost, let kept = MacHandoverKeeper.takeIfAsked(arguments) {
            var state = try kept.get()
            admit(state, viaKeeper: true)
            handedOver = state
            restoredSecrets = HostHandover.takeSecrets(from: &state)
            restoring = state
        } else if Platform.CodeIdentity.isAvailable {
            // The Mac, from a state file: taken only from the running host this one replaces (see `HostHandover.receive`:
            // the lock it holds, and for the account's host the proof under its vault key).
            let received = try HostHandover.receive(from: handoverPath, lockPath: lockPath, userHost: role.isAccountHost,
                                                    proof: value(after: HostHandover.proofFlag), logPath: config.logPath,
                                                    key: { vaultKey()?.key }, admit: { admit($0, viaKeeper: false) })
            handedOver = received.state
            restoredSecrets = received.secrets
            restoring = received.state
        } else {
            // Linux: through sealed memory the image before wrote, non-dumpable (V2/HandoverMemory.swift); no Keychain,
            // so no key to prove it with.
            var state = try HostHandover.read(from: handoverPath)
            admit(state, viaKeeper: false)
            handedOver = state
            restoredSecrets = HostHandover.takeSecrets(from: &state)
            restoring = state
        }
    } catch {
        goBack(handoverPath, error)
    }
}

// Only an actual restoration may carry the original app's location from the old host's argv.
// A fresh launch must not let a script designate itself as the app and replace a keyless host's key.
config.appExecutable = (restoring != nil ? value(after: "--app-executable") : nil)
    ?? folders.appExecutable
// The lead's vault: the account's host keeps it sealed under ~/.vibeswitcher/lead with its Keychain key; any other host
// keeps one in memory only, never touching the account's (see `HostRole.vault`).
// After a handover, the vault is the one the build before held in memory (its secrets), not what's on disk.
if Platform.CodeIdentity.isAvailable {
    do {
        config.vault = try role.vault(lockFD: restoring?.lockFD ?? heldLock, key: vaultKey(), keyUnreadable: vaultKeyResult()?.failure,
                                      handedOver: restoredSecrets, logPath: config.logPath)
    } catch {
        // The account's host no longer on the lock file at its path: it doesn't run (see `HostRole.vault`).
        HostServer.note("host: \(error); this one (build \(build)) exits", logPath: config.logPath)
        if let handoverPath { goBack(handoverPath, error) }
        log("\(error)")
        exit(1)
    }
} else {
    // Linux has no Keychain: the user's host (`ownsLaunchers`, by its lock's identity or the state carried) keeps its
    // vault in memory only, as `VaultStorage` with no key; a scratch host one of its own.
    let vaultFile = VibePaths.root.appendingPathComponent("lead/vault.sealed")
    config.vault = ownsLaunchers ? VaultStorage(file: vaultFile, key: nil, keyIsNew: false, logPath: config.logPath).book(handedOver: restoredSecrets)
        : LeadVault.Book(restoring: restoredSecrets)
}
// On Linux a fresh vault holds its first look for the user's accept; a restored one keeps its own (V2/VaultFirstLook.swift).
if VaultFirstLook.holds(arguments: arguments, ownsLaunchers: ownsLaunchers, restored: restoredSecrets.map(LeadVault.Book.reads) ?? false) { config.vault?.holdsFirstLook = true }
// A scratch host's test sets how long a `.user` seal verifies (V2/LeadVaultV2.swift); the user's host refuses the flag.
if HostHardening.takesTestFlags(ownsLaunchers: ownsLaunchers), let life = value(after: "--test-user-seal-life").flatMap(Double.init) { LeadVaultV2.sealLife = life }
// The app that started this host gives it its key on stdin (see `AppProof`), and says so: taken while the vault
// holds none, but not by a vault that started over (its file no longer opens under the Keychain key, or is gone though
// the key was there already, `VaultStorage.Key.made`): that one waits
// for your confirmation through the app (`LeadVault.Book.awaitsAppKey`).
if arguments.contains(HostStart.appKeyFlag), let key = HostStart.appKeyFromStdin(), let vault = config.vault, !vault.adoptAppKey(key) {
    log(vault.keyUnread ? "the vault's key couldn't be read from the Keychain: the app key on stdin waits for your confirmation"
        : vault.awaitsAppKey ? "the vault started over: the app key on stdin waits for your confirmation"
        : "the app key on stdin isn't the one the vault holds: kept the vault's")
}

// A scratch host's tests of its file watches (VibePlatform/Watches.swift); the user's host refuses the flags.
if HostHardening.takesTestFlags(ownsLaunchers: ownsLaunchers) {
    if arguments.contains(HostHardening.noInotifyFlag) { Platform.Watches.testNoInstance = true }
    if let census = value(after: HostHardening.inotifyCensusFlag), census.hasPrefix("/") { Platform.Watches.testCensus = census }
}
let server = HostServer(config: config)
server.onExit = { exit(0) }
// The test-only flags the user's host refuses, said; who an unreadable process is to this host (see `HostHardening`).
HostHardening.afterConfig(arguments: Array(arguments.dropFirst()), ownsLaunchers: ownsLaunchers, server: server)
HostHardening.watch(server)
// A detached host's log (its stderr, shared with its server child) kept to about 2 MB and one older copy (V2/StderrCap.swift).
StderrCap.start()
// Its soft limit on descriptors raised to the hard one; its sessions' programs get the old one back (V2/HostImages.swift).
HostImages.raiseDescriptorLimit(handedOver: handoverPath != nil || checkedStart?.commandLine.keeper != nil)
// The vault is what a build this one hands over to must hold in memory too.
if let vault = config.vault { server.secretsForHandover = { vault.serialized } }
// What a held first look kept from being recorded, in the host's log.
config.vault?.onHeld = { server.note($0) }
// The user's host proves to the build it hands over to that the handover is its own (see `HostHandover.receive`).
server.handoverKey = vaultKey()?.key
server.handoverNeedsKey = role.isAccountHost
// A test of the secret channel: these bytes are handed over, and the next build says whether it got them.
let testSecret = HostHardening.takesTestFlags(ownsLaunchers: ownsLaunchers) ? value(after: "--handover-test-secret").map { Data($0.utf8) }
    ?? HandoverMemory.testSecret(arguments: arguments, ownsLaunchers: ownsLaunchers) : nil
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
if let state = restoring {
    do {
        if arguments.contains("--handover-fail-restore") { throw HostHandover.Failure.unreadable("--handover-fail-restore, after its secrets") }
        _ = try server.start(restoring: state)
        // Each session's output is in its ring now: the decoded copies let go (V2/HandoverMemory.swift).
        restoring = restoring.map(HandoverMemory.withoutOutput)
        handedOver = handedOver.map(HandoverMemory.withoutOutput)
        if let handoverPath, HandoverMemory.descriptor(named: handoverPath) == nil { unlink(handoverPath) }
        if let testSecret { log("test secret carried: \(restoredSecrets == testSecret ? "yes" : "no")") }
        log("took over \(state.sessions.count) sessions\(restoredSecrets.map { " and \($0.count) bytes of secrets" } ?? "") from build \(state.fromBuild) \(Date())")
    } catch {
        // A checked node doesn't go back: its fallback would be an unchecked exec by path.
        guard let handoverPath else { notStarted("couldn't take over: \(error)") }
        goBack(handoverPath, error)
    }
} else {
    do {
        try server.start(holdingLock: heldLock)
        HandoverMemory.removeStaleStateFiles(lockPath: lockPath, server: server)
    } catch {
        log("\(error)")
        exit(1)
    }
}
// A scratch host's test stand-in for the app on Linux: refused by the user's host (see `TestAppPrincipal`).
TestAppPrincipal.adopt(arguments: arguments, restored: restoring?.testAppConnector, ownsLaunchers: ownsLaunchers, server: server)
// The app on Linux: the server child, from a sealed copy of `--server PATH`, through its connector (see `ServerChild`);
// after a handover, the one the build before ran, once checked.
ServerChild.adopt(arguments: nodeArguments, ownsLaunchers: ownsLaunchers, nodeRoot: folders.installFolder, config: config, server: server,
                  restored: restoring, copy: images.server)
// Restored and taken again: on Linux the state's and secrets' sealed memory and the old image's copy closed, every
// other descriptor kept marked close-on-exec (V2/HandoverMemory.swift).
if let handedOver, let handoverPath { HandoverMemory.finish(handedOver, statePath: handoverPath, server: server) }
// Holding the user's lock now: no other host runs, so other builds' launchers can go (not for a scratch host on
// its own lock, which runs beside the real one).
for name in (try? FileManager.default.contentsOfDirectory(atPath: launchers.path)) ?? [] where ownsLaunchers && images.own == nil && name != "launcher-\(build)" {
    try? FileManager.default.removeItem(at: launchers.appendingPathComponent(name))
}
// Earlier versions kept the user's sealing key and the teams in files any of the team could read: gone.
if ownsLaunchers {
    try? FileManager.default.removeItem(at: role.root.appendingPathComponent("steer/sender.key"))
    try? FileManager.default.removeItem(at: role.root.appendingPathComponent("lead/teams"))
}
// On Linux: its pid, its build and SWIFT_BACKTRACE, the journal's start line (see V2/HostStartLine.swift).
HostStartLine.say()
Platform.Stdio.error("vibeswitcher-host: started \(Date())\n")
dispatchMain()
