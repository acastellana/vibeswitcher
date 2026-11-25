import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The review of v2-mac-checked-start (2026-11-25, "ready with fixes"), each finding as a test: the checked start's
/// arguments, environment and lock (F1, F2, N5), what a new image takes (F1, N2), who the app is before the server child
/// (N1), a switch to a build whose server isn't its row's (N4), the keeper's deadline (N6), the server child's
/// `--node-root` (N3), and Linux left as it was (N7). Most are functions with a scratch record, as the anchor's tests
/// are; the wrapper of F1 and the keeper of N6 run real hardened host images on scratch roots (Mac only).
@Suite(.serialized, hostTestLimit)
struct MacCheckedFixRoundTests {
    let scratch = Scratch()

    struct Node { var home, data, build, server, lock: String }

    /// A scratch home: the data root, and a build folder `<home>/.vibeswitcher/v2/builds/<commit>` whose server is a copy
    /// of `program`.
    func node(commit: String = String(repeating: "a", count: 40), server program: String = "/usr/bin/true") throws -> Node {
        let home = scratch.url("vsfr").path
        let data = Platform.Service.nodeRoot(accountHome: home)
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        let build = (data as NSString).deletingLastPathComponent + "/builds/" + commit
        try FileManager.default.createDirectory(atPath: build + "/bin", withIntermediateDirectories: true)
        let server = build + "/bin/" + BuildInfo.server
        try FileManager.default.copyItem(atPath: program, toPath: server)
        return Node(home: home, data: data, build: build, server: server, lock: data + "/host.lock")
    }

    func started(_ n: Node, extra: [String] = []) -> [String] {
        ["vibeswitcher-host", HostImages.nodeFlag, HostImages.nodeRootFlag, n.build, "--server", n.server] + extra
    }

    func pins(_ builds: [NodePins.Build]) -> Result<NodePins, NodePins.Refused> { .success(NodePins(uid: getuid(), builds: builds)) }

    func row(host: Data, server: String, commit: String = String(repeating: "a", count: 40)) throws -> NodePins.Build {
        NodePins.Build(commit: commit, host: host, server: try #require(Platform.CodeIdentity.cdhash(atPath: server)), cli: Data(repeating: 0xc1, count: 20))
    }

    func refused(_ result: Result<HostImages.CheckedNode, HostImages.Refused>) -> String? {
        if case .failure(let why) = result { return why.description }
        return nil
    }

    // MARK: F1, N5: a checked node takes no argument it has no use for

    /// F1 (and N5): a checked node's start refuses every argument but its own (`--node`, `--node-root`, `--server`, and a
    /// handover's), each at most once: one that changes who the app is (`--app-executable`, the app key on stdin), where
    /// it logs (`--log`), what it listens or locks on (`--socket`, `--lock`), what it runs (`--server-arg`, test flags,
    /// `--handover-fallback`), or a second `--server` or `--node-root` put first by a wrapper. Red before: all accepted.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's checked start: code identity"))
    func aCheckedNodeRefusesEveryArgumentItHasNoUseFor() throws {
        let n = try node()
        let own = try #require(Platform.CodeIdentity.ownCdhash())
        let record = pins([try row(host: own, server: n.server)])
        if let why = refused(HostImages.macNodeStart(arguments: started(n), lockPath: n.lock, own: own, pins: record, accountHome: n.home)) {
            Issue.record("the node's own arguments refused: \(why)")
        }
        let given: [[String]] = [["--app-executable", "/x/VibeSwitcher"], ["--log", "/x/log"], ["--socket", "/x/s"], ["--lock", n.lock],
                                 ["--handover-test-secret", "S"], ["--test-user-seal-life", "5"], ["--server-arg", "x"],
                                 ["--handover-fallback", "/x/h"], ["--exit-with", "1"], ["--idle-exit", "1"], [HostStart.appKeyFlag],
                                 ["--handover-test-keeper", String(repeating: "0f", count: 20)], ["--install-root", "/x"],
                                 ["--server", n.server], [HostImages.nodeRootFlag, n.build]]
        for extra in given {
            let why = refused(HostImages.macNodeStart(arguments: started(n, extra: extra), lockPath: n.lock, own: own, pins: record, accountHome: n.home))
            #expect(why != nil, "a checked node took \(extra)")
        }
        // A wrapper's arguments put first (the review's probe): refused too.
        let wrapped = ["vibeswitcher-host", "--log", "/x/log", "--app-executable", "/x/app"] + started(n).dropFirst()
        #expect(refused(HostImages.macNodeStart(arguments: wrapped, lockPath: n.lock, own: own, pins: record, accountHome: n.home)) != nil)
    }

    /// F1: a checked node's environment keeps no variable of this program's that changes where it logs or what it runs
    /// (`VIBESWITCHER_HOST_LOG`, the launcher's test hold, `SWIFT_BACKTRACE`'s backtracer), but `VIBESWITCHER_HOME` (the
    /// start sets it) and what the host carries across its own exec (`VIBESWITCHER_HOST_NOFILE_BEFORE`). Red before: as
    /// given.
    @Test func aCheckedNodesEnvironmentKeepsNothingThatMovesItsLogOrItsCode() {
        let given = ["VIBESWITCHER_HOST_LOG": "/x/log", "VIBESWITCHER_LAUNCHER_TEST_HOLD": "/x/hold", "SWIFT_BACKTRACE": "enable=yes,swift-backtrace=/x/bt",
                     "VIBESWITCHER_CODEX_WORKERS": "1", "VIBESWITCHER_HOME": "/h/.vibeswitcher/v2/node", "VIBESWITCHER_HOST_NOFILE_BEFORE": "256",
                     "PATH": "/usr/bin:/bin", "HOME": "/h"]
        #expect(HostImages.checkedNodeEnvironment(given) == ["VIBESWITCHER_HOME": "/h/.vibeswitcher/v2/node", "VIBESWITCHER_HOST_NOFILE_BEFORE": "256",
                                                             "PATH": "/usr/bin:/bin", "HOME": "/h"])
    }

    // MARK: F2: the lock by its exact path only

    /// F2: the node's lock by another spelling (`/./`) or by a hard link elsewhere is refused by the start (`main`'s
    /// `ownsLaunchers` compares the path, so it would take such a node for a scratch host), and `main` refuses a checked
    /// start it doesn't take for the user's host. Red before: both accepted.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's checked start: code identity"))
    func theNodesLockIsTakenOnlyByItsExactPath() throws {
        let n = try node()
        let own = try #require(Platform.CodeIdentity.ownCdhash())
        let record = pins([try row(host: own, server: n.server)])
        FileManager.default.createFile(atPath: n.lock, contents: nil)
        let hard = scratch.url("vsfr-hard.lock").path
        #expect(link(n.lock, hard) == 0)
        for alias in [n.data + "/./host.lock", hard, n.data + "//host.lock"] {
            #expect(refused(HostImages.macNodeStart(arguments: started(n), lockPath: alias, own: own, pins: record, accountHome: n.home)) != nil,
                    "the node's lock taken as \(alias)")
        }
        guard case .success(let checked) = HostImages.macNodeStart(arguments: started(n), lockPath: n.lock, own: own, pins: record, accountHome: n.home) else {
            Issue.record("the exact lock refused")
            return
        }
        #expect(HostImages.checkedNodeRefusal(checked, ownsLaunchers: false) != nil, "main took a checked node for a scratch host")
        #expect(HostImages.checkedNodeRefusal(checked, ownsLaunchers: true) == nil)
        #expect(HostImages.checkedNodeRefusal(nil, ownsLaunchers: false) == nil)
    }

    // MARK: F1, N2: what a new image takes

    /// F1 and N2: a checked node's state goes only to a new image holding its own checked start (the parcel says it came
    /// from one, `fromCheckedNode`), and a checked node takes state only through a keeper it proved, never from
    /// `--handover PATH`. A scratch host's switch, as before. Red before: every state taken.
    @Test func aCheckedNodesStateGoesOnlyToACheckedStartThroughAKeeper() throws {
        let row = NodePins.Build(commit: String(repeating: "a", count: 40), host: Data(repeating: 1, count: 20), server: Data(repeating: 2, count: 20),
                                 cli: Data(repeating: 3, count: 20))
        let checked = HostImages.CheckedNode(build: row, serverPath: "/b/bin/vibeswitcher-server", server: row.server)
        var state = HostHandover.State(fromBuild: 1, startedAt: Date(), lockFD: 3, listenFD: 4, secretFD: nil, sessions: [])
        state.fromCheckedNode = true
        #expect(HostImages.mayTakeHandover(state, viaKeeper: true, checkedNode: nil) != nil, "a checked node's state went to an image with no checked start")
        #expect(HostImages.mayTakeHandover(state, viaKeeper: true, checkedNode: checked) == nil)
        #expect(HostImages.mayTakeHandover(state, viaKeeper: false, checkedNode: checked) != nil, "a checked node took a state file")
        state.fromCheckedNode = nil
        #expect(HostImages.mayTakeHandover(state, viaKeeper: false, checkedNode: checked) != nil, "a checked node took a state file")
        #expect(HostImages.mayTakeHandover(state, viaKeeper: true, checkedNode: nil) == nil, "a scratch host's switch refused")
        #expect(HostImages.mayTakeHandover(state, viaKeeper: false, checkedNode: nil) == nil, "a plain handover refused")

        // The state a checked node host writes says so.
        let host = try TestHost(vault: LeadVault.Book(), appConnector: false, checkedNode: checked)
        #expect(host.server.queue.sync { host.server.handoverState(secretFD: nil).fromCheckedNode } == true)
        let plain = try TestHost(appConnector: false)
        #expect(plain.server.queue.sync { plain.server.handoverState(secretFD: nil).fromCheckedNode } == nil)
    }

    /// F1, end to end (the review's probe `aWrapperThatRunsTheGenuineImageWithItsOwnArguments`): the file renamed over
    /// the target after the path check is a wrapper that runs a byte copy of the pinned host, the attacker's arguments
    /// first. It passes both gates (the genuine code runs), but the parcel says it is a checked node's
    /// (`--handover-test-checked-parcel`, a scratch host's stand-in for one) and the image the wrapper started holds no
    /// checked start of its own: it takes nothing and exits; no session is taken over and no secret read. Red before: it
    /// took the sessions and the secrets ("took over 1 sessions and 22 bytes of secrets").
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's switch through a keeper: code identity"))
    func aWrapperRunningThePinnedImageWithItsOwnArgumentsTakesNothing() async throws {
        let images = MacKeeperHandoverTests.Images()
        var extra: [String] = []
        var chosenLog = ""
        let host = try await ScratchHostProcess(prepare: { dir in
            _ = try MacKeeperHandoverTests.sign(dir + "/old/vibeswitcher-host", "dev.vibeswitcher.test.fix.old")
            images.new = try MacKeeperHandoverTests.sign(dir + "/new/vibeswitcher-host", "dev.vibeswitcher.test.fix.new")
            try FileManager.default.createDirectory(atPath: dir + "/kept", withIntermediateDirectories: true)
            try installProgram(dir + "/new/vibeswitcher-host", atPath: dir + "/kept/vibeswitcher-host")
            chosenLog = dir + "/attacker-chosen.log"
            try installScript("""
            #!/bin/sh
            case "$1" in
              --handover-keeper) exec "\(dir)/kept/vibeswitcher-host" "$@" ;;
              *) exec "\(dir)/kept/vibeswitcher-host" --log "\(chosenLog)" --app-executable "\(dir)/attacker-app" "$@" ;;
            esac
            """ + "\n", atPath: dir + "/wrapper")
            extra = ["--handover-test-keeper", NodePins.hex(images.new), "--handover-test-swap-after-check", dir + "/wrapper",
                     "--handover-test-checked-parcel", "--handover-test-secret", "S3CRET-OF-THE-OLD-HOST"]
        }, late: { extra })
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let counter = try await client.spawn(HostHandoverTests.counter)
        await client.attach(counter.id)
        #expect(await eventually { counted(client.text(counter.id)).last ?? 0 >= 3 })
        let seq = client.send(.handover(executable: host.newBinary))
        _ = await eventually { client.reply(to: seq) != nil }
        #expect(await eventually { !host.process.isRunning || host.log.contains("took over") }, "\(host.log)")
        #expect(!host.log.contains("took over"), "the wrapper's image took the sessions over: \(host.log)")
        #expect(!host.log.contains("bytes of secrets"), "the wrapper's image read the secrets: \(host.log)")
        #expect(host.log.contains("a checked node's state goes only to an image holding its own checked start"), "\(host.log)")
    }

    // MARK: N1: who the app is before the server child

    /// N1: a checked node host is the node host from its start, not only once its server child is adopted: no peer is
    /// checked against `<exe folder>/VibeSwitcher` or `--app-executable` before then. Red before: the app's executable
    /// was in force until the child was set.
    @Test func aCheckedNodeHostTakesNoAppExecutableBeforeItsServerChild() throws {
        let row = NodePins.Build(commit: String(repeating: "a", count: 40), host: Data(repeating: 1, count: 20), server: Data(repeating: 2, count: 20),
                                 cli: Data(repeating: 3, count: 20))
        let checked = HostImages.CheckedNode(build: row, serverPath: "/b/bin/vibeswitcher-server", server: row.server)
        let host = try TestHost(vault: LeadVault.Book(), appExecutable: "/x/VibeSwitcher", appConnector: false, checkedNode: checked)
        let inForce = host.server.queue.sync { host.server.appExecutableInForce }
        if Platform.CodeIdentity.isAvailable { #expect(inForce == nil, "a checked node host took \(inForce ?? "") as the app") }
        let plain = try TestHost(appExecutable: "/x/VibeSwitcher", appConnector: false)
        #expect(plain.server.queue.sync { plain.server.appExecutableInForce } == "/x/VibeSwitcher")
    }

    // MARK: N4: the target's server, before the keeper

    /// N4: a switch to a pinned host whose build's server isn't its row's is refused before the keeper starts, the old
    /// host as it was (the new image's own start would find it only after the old one was gone). Red before: passed.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's switch through a keeper: code identity"))
    func aSwitchToABuildWhoseServerIsntItsRowsIsRefusedFirst() throws {
        let own = try #require(Platform.CodeIdentity.ownCdhash())
        let next = Data(repeating: 0x22, count: 20)
        let mine = NodePins.Build(commit: String(repeating: "a", count: 40), host: own, server: Data(repeating: 0x5e, count: 20), cli: Data(repeating: 0xc1, count: 20))
        let theirs = NodePins.Build(commit: String(repeating: "c", count: 40), host: next, server: Data(repeating: 0x5f, count: 20), cli: Data(repeating: 0xc2, count: 20))
        let checked = HostImages.CheckedNode(build: mine, serverPath: "/usr/bin/true", server: mine.server)
        let host = try TestHost(vault: LeadVault.Book(), appConnector: false, checkedNode: checked)
        let target = "/builds/c/bin/vibeswitcher-host"
        let files = [target: next, "/builds/c/bin/" + BuildInfo.server: Data(repeating: 0x77, count: 20)]
        let answer = host.server.queue.sync {
            host.server.keeperTarget(target, pins: .success(NodePins(uid: getuid(), builds: [mine, theirs])), cdhashOf: { files[$0] })
        }
        guard case .failure(let why)? = answer else { Issue.record("a build whose server isn't its row's passed: \(String(describing: answer))"); return }
        #expect(why.description.contains("server"), "\(why)")
        let good = [target: next, "/builds/c/bin/" + BuildInfo.server: theirs.server]
        let passed = host.server.queue.sync {
            host.server.keeperTarget(target, pins: .success(NodePins(uid: getuid(), builds: [mine, theirs])), cdhashOf: { good[$0] })
        }
        #expect(passed == .success(next))
    }

    // MARK: N6: the keeper's deadline

    /// N6: a keeper that holds the state and sees no new image within its limit closes everything and exits (the cost
    /// stays the residual's: the sessions end), rather than holding the lock, the listener and the terminals for ever.
    /// Here the keeper is a hardened copy of the built host started by this process, given a 3 s limit; no exec follows.
    /// Red before: it waited with no deadline.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's switch through a keeper: code identity"))
    func aKeeperThatSeesNoNewImageExitsByItsDeadline() async throws {
        let folder = scratch.url("vsfr-keeper").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let image = folder + "/vibeswitcher-host"
        try installProgram(hostLauncher, atPath: image)
        let cdhash = try MacKeeperHandoverTests.sign(image, "dev.vibeswitcher.test.fix.keeper")
        guard case .success(let keeper) = MacHandoverKeeper.start(image, expected: cdhash, limit: 3) else {
            Issue.record("the keeper didn't prove itself")
            return
        }
        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        defer { Sys.close(ends[0]); Sys.close(ends[1]) }
        let state = HostHandover.State(fromBuild: 1, startedAt: Date(), lockFD: ends[0], listenFD: ends[1], secretFD: nil, sessions: [])
        guard case .success = MacHandoverKeeper.park(state, with: keeper) else {
            MacHandoverKeeper.abandon(keeper)
            Issue.record("the keeper didn't take the state")
            return
        }
        var status: Int32 = 0
        let ended = await eventually(timeout: 60) { waitpid(keeper.pid, &status, WNOHANG) == keeper.pid }
        if !ended { MacHandoverKeeper.abandon(keeper) } else { Sys.close(keeper.proven); Sys.close(keeper.channel) }
        #expect(ended, "the keeper held the state with no new image past its deadline")
    }

    // MARK: N3: the server child's --node-root

    /// N3: a `--node` host's server child is told the build's folder (`--node-root`) as its install folder, on the Mac as
    /// on Linux, not the executable's `bin`. Red before (the Mac): `<build>/bin`.
    @Test func aNodesServerChildIsToldItsBuildsFolder() {
        let folders = HostImages.folders(arguments: ["vibeswitcher-host", HostImages.nodeFlag, HostImages.nodeRootFlag, "/b/c"],
                                         executable: "/b/c/bin/vibeswitcher-host")
        #expect(folders.installFolder == "/b/c")
        let plain = HostImages.folders(arguments: ["vibeswitcher-host"], executable: "/e/bin/vibeswitcher-host")
        #expect(plain.installFolder == "/e/bin")
    }

    // MARK: N7: Linux as it was

    /// N7: where there is no code identity (Linux), a host given `--handover-keeper-channel FD` takes nothing through it
    /// (it reads its state as before). Red before: it tried a keeper and failed its restore. (`keepIfAsked` has the same
    /// first line; a test can't call it without the process exiting when it is wrong.)
    @Test func withoutCodeIdentityNoKeeperIsAsked() {
        #expect(MacHandoverKeeper.takeIfAsked(["vibeswitcher-host", MacHandoverKeeper.channelFlag, "987"], isAvailable: false) == nil)
    }
}
