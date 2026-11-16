import Foundation
import Testing
import VibeCore
import VibeNode

/// `vibeswitcher start` and the typed word (the engine plan's E1, EN-D5; the security architecture document's S1, S3
/// and S11), run as built against a scratch node, whose interop the test sets (`<root>/v2/test/binfmt_misc/`) and whose
/// journal is the recording stand-in; and the pieces `start` is made of (the start plan's S1): the unit's text, its
/// folders, the installed build and the preflight, driven in process with scratch folders. The cases on a scratch node
/// or a scratch folder are Linux's; the Mac runs the pure ones (the unit's text, parse, disjointness, the refusals,
/// the manager's refusal).
@Suite
struct StartCommandTests {
    private let scratch = Scratch()

    @Test(NodeTraits.linuxOnly) func startRefusesWhileInteropIsOnUnlessTold() async throws {
        let node = try await ScratchNode(scratch)
        // `WSLInterop` off, as `echo 0 >` leaves it; `WSLInterop-late`, which WSL with systemd registers too, still on.
        try "enabled\ninterpreter /init\nflags: P\n".write(to: node.testFolder.appendingPathComponent("binfmt_misc/WSLInterop-late"),
                                                          atomically: true, encoding: .utf8)
        let refused = try await node.run(["start"])
        #expect(refused.status == 77, "\(refused.errors)")
        #expect(refused.errors.contains("WSL interop is on") && refused.errors.contains("--interop-is-on"), "\(refused.errors)")
        // Nothing reached the server.
        let quiet = try #require(WireClient.reply(try WireClient(node).request("status", action: nil))?.result)
        #expect(quiet["accepted"]?.array?.isEmpty == true)
        // Told, it goes on, and says interop is on.
        let told = try await node.runOnTerminal(["start", "--interop-is-on"])
        #expect(told.status == 0, "\(told.output)")
        #expect(told.output.contains("interop: on"), "\(told.output)")
        #expect(told.output.contains("the node runs"), "\(told.output)")
    }

    @Test(NodeTraits.linuxOnly) func startPrintsTheNotPromisedListOnceAndRecordsTheAck() async throws {
        let node = try await ScratchNode(scratch)
        let first = try await node.runOnTerminal(["start"])
        #expect(first.status == 0, "\(first.output)")
        #expect(first.output.contains(NotPromised.heading), "\(first.output)")
        #expect(first.output.contains("1. While WSL interop is on"), "\(first.output)")
        #expect(first.output.contains("recorded: you read what plain mode doesn't promise"), "\(first.output)")
        let acks = node.recorder?.entries.filter { $0.event == NotPromised.ackEvent } ?? []
        #expect(acks.count == 1)
        #expect(acks.first.map { NodeJournal.passes($0, rule: VoiceRule(mode: .systemd, scopes: [.init(ScratchNode.ownScope ?? "/", basis: "t")],
                                                                          uid: getuid(), says: "")) } == true)
        // The second start prints nothing of it, and asks for nothing (no terminal needed).
        let second = try await node.run(["start"])
        #expect(second.status == 0, "\(second.errors)")
        #expect(!second.output.contains(NotPromised.heading), "\(second.output)")
        #expect(node.recorder?.entries.filter { $0.event == NotPromised.ackEvent }.count == 1)
    }

    @Test(NodeTraits.linuxOnly) func aStateChangeWithNoTerminalIsRefused() async throws {
        let node = try await ScratchNode(scratch)
        // stdin from /dev/null, in a session of its own: no /dev/tty.
        let ran = try await run(URL(fileURLWithPath: "/usr/bin/setsid"), ["--wait", commandLine.path, "stop"], environment: node.environment())
        #expect(ran.status == 77, "\(ran.errors)")
        #expect(ran.errors.contains("needs a code typed on a terminal"), "\(ran.errors)")
        // The server got no stop: it runs, and accepted nothing.
        let status = try #require(WireClient.reply(try WireClient(node).request("status", action: nil))?.result)
        #expect(status["accepted"]?.array?.isEmpty == true)
        #expect(node.process.isRunning)
        // A wrong code typed: refused the same.
        let wrong = try await node.runOnTerminal(["stop"]) { _ in "ZZZZ" }
        #expect(wrong.status == 77, "\(wrong.output)")
        #expect(node.process.isRunning)
        // With a terminal and the right code, it goes.
        let typed = try await node.runOnTerminal(["stop"])
        #expect(typed.status == 0, "\(typed.output)")
        #expect(await exited(node.process, within: 60), "\(node.said)")
    }

    @Test(NodeTraits.linuxOnly) func aTerminalOnStdinThatIsntTheControllingOneIsNotAskedOn() async throws {
        // In a session of its own (`setsid`: no controlling terminal, so no `/dev/tty`) with a pty on stdin it doesn't
        // control. The server's weaker rule refuses a state change from a peer with no controlling terminal, so the
        // command line asks no code there: it refuses before the user types one. The pty's other end types the code
        // shown, as a user would, should one be asked.
        let node = try await ScratchNode(scratch)
        let pty = try Platform.Terminals.open(rows: 24, cols: 80).get()
        defer { Sys.close(pty.master) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/setsid")
        process.arguments = ["--wait", commandLine.path, "stop"]
        process.environment = node.environment()
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle(fileDescriptor: pty.slave, closeOnDealloc: false)
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        Sys.close(pty.slave)
        // What the pty showed, read until its last holder (the command line's stdin) closes it.
        let shown = await offPool { () -> String in
            var seen = Data()
            var answered = false
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let got = Sys.read(pty.master, &buffer, buffer.count)
                if got < 0, errno == EINTR { continue }
                guard got > 0 else { break }
                seen.append(contentsOf: buffer[0..<got])
                let text = String(decoding: seen, as: UTF8.self)
                if !answered, let range = text.range(of: #"Type ([A-Z]{4}) and Enter"#, options: .regularExpression) {
                    answered = true
                    let typed = Array((String(text[range].dropFirst(5).prefix(4)) + "\r").utf8)
                    _ = typed.withUnsafeBufferPointer { Sys.write(pty.master, $0.baseAddress!, $0.count) }
                }
            }
            return String(decoding: seen, as: UTF8.self)
        }
        #expect(await exited(process, within: 120), "stop with a pty on stdin never ended")
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 77, "\(said) \(shown)")
        #expect(said.contains("no controlling terminal"), "\(said)")
        #expect(!shown.contains("Type "), "a code was asked on a terminal that isn't the controlling one: \(shown)")
        // The server got no stop.
        let status = try #require(WireClient.reply(try WireClient(node).request("status", action: nil))?.result)
        #expect(status["accepted"]?.array?.isEmpty == true, "\(status)")
        #expect(node.process.isRunning)
    }
}

// MARK: - The unit, the folders and the preflight (the start plan's S1)

extension StartCommandTests {
    static let commit = "0123456789abcdef0123456789abcdef01234567"
    static let other = "89abcdef0123456789abcdef0123456789abcdef"
    static let inputs = NodeUnit.Inputs(prefix: "/home/u/.vibeswitcher/v2/builds", commit: commit, home: "/home/u",
                                        swiftBin: "/home/u/.local/share/swiftly/bin",
                                        nodeBin: "/home/u/.nvm/versions/node/v22.1.0/bin")

    /// The names a unit's text assigns with `Environment=` that its `UnsetEnvironment=` also names: systemd applies
    /// that line last, and a name there removes the unit's own assignment too (`systemd.exec(5)`).
    static func unsetAndAssigned(_ text: String) -> [String] {
        let unit = NodeUnit.parse(text)
        let unset = Set((unit["UnsetEnvironment"] ?? []).flatMap(NodeUnit.words))
        let assigned = (unit["Environment"] ?? []).flatMap(NodeUnit.words).compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
        return assigned.filter(unset.contains).sorted()
    }

    @Test func theUnitStartsTheCommitsFolderNotCurrent() throws {
        let p = Self.inputs.prefix, c = Self.commit
        #expect(NodeUnit.execStart(prefix: p, commit: c) == ["\(p)/\(c)/bin/vibeswitcher-host", "--node", "--node-root", "\(p)/\(c)",
                                                             "--server", "\(p)/\(c)/bin/vibeswitcher-server"])
        let text = try NodeUnit.text(Self.inputs).get()
        let unit = NodeUnit.parse(text)
        #expect(unit["ExecStart"] == [NodeUnit.execStart(prefix: p, commit: c).joined(separator: " ")], "\(text)")
        #expect(!text.contains("current"), "\(text)")
        // Read back, the unit names the same build and folders.
        #expect(NodeUnit.inputs(parsing: text, prefix: p) == .success(Self.inputs))
        #expect(NodeUnit.fileName == VoiceRule.nodeUnit)
    }

    @Test func theUnitIsRestartNoKillModeControlGroupWithATimeout() throws {
        let text = try NodeUnit.text(Self.inputs).get()
        let unit = NodeUnit.parse(text)
        #expect(unit["Restart"] == ["no"])
        #expect(unit["KillMode"] == ["control-group"])
        #expect(unit["TimeoutStopSec"] == ["45"] && NodeUnit.timeoutStop == 45)
        #expect(unit["Type"] == ["simple"])
        #expect(unit["WantedBy"] == ["default.target"])
        #expect(unit["Description"] == ["VibeSwitcher node"])
        #expect(NodeUnit.killModeConsequence.contains("every session"), "\(NodeUnit.killModeConsequence)")
        // What the manager shows of it after `daemon-reload` (ST-D2), compared field by field.
        let file = "/home/u/.config/systemd/user/vibeswitcher-node.service"
        let expected = NodeUnit.expectedShow(Self.inputs, unitFile: file)
        #expect(expected["FragmentPath"] == file && expected["DropInPaths"] == "" && expected["NeedDaemonReload"] == "no")
        #expect(expected["Restart"] == "no" && expected["KillMode"] == "control-group")
        #expect(expected["UnsetEnvironment"] == NodeUnit.unset.joined(separator: " "))
        let host = NodeUnit.execStart(prefix: Self.inputs.prefix, commit: Self.commit)
        let shown = """
            Restart=no
            ExecStart={ path=\(host[0]) ; argv[]=\(host.joined(separator: " ")) ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }
            Environment=SWIFT_BACKTRACE=enable=no HOME=/home/u PATH=\(NodeUnit.path(swiftBin: Self.inputs.swiftBin, nodeBin: Self.inputs.nodeBin))
            UnsetEnvironment=\(NodeUnit.unset.joined(separator: " "))
            KillMode=control-group
            FragmentPath=\(file)
            DropInPaths=
            NeedDaemonReload=no
            """
        #expect(NodeUnit.showMismatch(shown, expected: expected) == nil)
        // An ExecStart that ran before (its runtime fields filled) is the same ExecStart.
        let ran = shown.replacingOccurrences(of: "start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null)",
                                             with: "start_time=[Mon 2026-11-16 10:00:00 UTC] ; stop_time=[Mon 2026-11-16 11:00:00 UTC] ; pid=4242 ; code=exited")
        #expect(NodeUnit.showMismatch(ran, expected: expected) == nil)
        // A drop-in, another fragment, an ExecStartPre or another KillMode is named.
        let dropIn = shown.replacingOccurrences(of: "DropInPaths=", with: "DropInPaths=/home/u/.config/systemd/user/service.d/x.conf")
        #expect(NodeUnit.showMismatch(dropIn, expected: expected)?.contains("DropInPaths") == true)
        let shadow = shown.replacingOccurrences(of: "FragmentPath=\(file)", with: "FragmentPath=/home/u/.local/share/systemd/user/vibeswitcher-node.service")
        #expect(NodeUnit.showMismatch(shadow, expected: expected)?.contains("FragmentPath") == true)
        let pre = shown + "\nExecStartPre={ path=/bin/sh ; argv[]=/bin/sh -c x ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
        #expect(NodeUnit.showMismatch(pre, expected: expected)?.contains("ExecStartPre") == true)
        let mode = shown.replacingOccurrences(of: "KillMode=control-group", with: "KillMode=process")
        #expect(NodeUnit.showMismatch(mode, expected: expected)?.contains("KillMode") == true)
        let missing = shown.replacingOccurrences(of: "Restart=no\n", with: "")
        #expect(NodeUnit.showMismatch(missing, expected: expected)?.contains("Restart") == true)
    }

    @Test func theUnitUnsetsTheListedNamesAndSetsBacktraceOff() throws {
        #expect(NodeUnit.unset == ["LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH", "GCONV_PATH", "BASH_ENV", "ENV", "VIBESWITCHER_HOME",
                                   "CFFIXED_USER_HOME", "SSH_AUTH_SOCK"])
        let unit = NodeUnit.parse(try NodeUnit.text(Self.inputs).get())
        #expect(unit["UnsetEnvironment"] == [NodeUnit.unset.joined(separator: " ")])
        #expect(unit["Environment"]?.contains("SWIFT_BACKTRACE=enable=no") == true, "\(unit)")
    }

    @Test func noNameIsBothUnsetAndAssigned() throws {
        let text = try NodeUnit.text(Self.inputs).get()
        #expect(Self.unsetAndAssigned(text).isEmpty, "\(text)")
        // The check sees a mutant that unsets SWIFT_BACKTRACE as well (the security document's S9 had it in both).
        let mutant = text.replacingOccurrences(of: "UnsetEnvironment=", with: "UnsetEnvironment=SWIFT_BACKTRACE ")
        #expect(Self.unsetAndAssigned(mutant) == ["SWIFT_BACKTRACE"])
    }

    @Test func theUnitsPathIsQuotedAndHasNoMnt() throws {
        let path = NodeUnit.path(swiftBin: Self.inputs.swiftBin, nodeBin: Self.inputs.nodeBin)
        #expect(path == "/usr/local/bin:/usr/bin:/bin:/home/u/.local/share/swiftly/bin:/home/u/.nvm/versions/node/v22.1.0/bin")
        let unit = NodeUnit.parse(try NodeUnit.text(Self.inputs).get())
        #expect(unit["Environment"]?.contains("\"PATH=\(path)\"") == true, "\(unit)")
        #expect(unit["Environment"]?.contains("\"HOME=/home/u\"") == true, "\(unit)")
        var mounted = Self.inputs
        mounted.swiftBin = "/mnt/c/Users/u/swift/bin"
        guard case .failure(let refused) = NodeUnit.text(mounted) else { Issue.record("a swift folder under /mnt/ was taken"); return }
        #expect(refused.text.contains("/mnt/c/Users/u/swift/bin") && refused.text.contains("/mnt/"), "\(refused)")
        var relative = Self.inputs
        relative.nodeBin = "home/u/node/bin"
        guard case .failure(let notAbsolute) = NodeUnit.text(relative) else { Issue.record("a relative node folder was taken"); return }
        #expect(notAbsolute.text.contains("home/u/node/bin"), "\(notAbsolute)")
    }

    @Test func aPathSystemdWouldExpandIsRefused() {
        for (bad, named) in [("%h", "%"), (" ", "whitespace"), ("\t", "whitespace"), ("\"", "\""), ("$", "$"), ("\\", "\\"),
                             ("'", "'"), ("\u{7}", "a control character")] {
            var inputs = Self.inputs
            inputs.prefix = "/home/u/b\(bad)x"
            guard case .failure(let refused) = NodeUnit.text(inputs) else { Issue.record("a prefix with \(named) was taken"); continue }
            #expect(refused.text.contains("the prefix") && refused.text.contains("holds \(named)"), "\(named): \(refused)")
        }
        var home = Self.inputs
        home.home = "/home/u%u"
        guard case .failure(let refused) = NodeUnit.text(home) else { Issue.record("a home with % was taken"); return }
        #expect(refused.text.contains("the home"), "\(refused)")
        var commit = Self.inputs
        commit.commit = "../x"
        guard case .failure(let notACommit) = NodeUnit.text(commit) else { Issue.record("a commit ../x was taken"); return }
        #expect(notACommit.text.contains("40"), "\(notACommit)")
    }

    @Test func theUnitFolderIsTheAccountsWhateverTheEnvironmentSays() {
        #expect(NodeFolders.unitFolder(accountHome: "/home/u") == "/home/u/.config/systemd/user")
        #expect(NodeFolders.runtimeFolder(uid: 1000) == "/run/user/1000")
        #expect(NodeFolders.defaultPrefix(accountHome: "/home/u") == "/home/u/.vibeswitcher/v2/builds")
        // The manager's XDG_CONFIG_HOME doesn't choose the folder (nothing reads it there); `start` refuses it instead.
        let shown = "HOME=/home/u\nPATH=/usr/bin:/bin\nXDG_CONFIG_HOME=/srv/x\n"
        #expect(NodeFolders.managerRefusal(showEnvironment: shown)?.text.contains("XDG_CONFIG_HOME") == true)
        // The process's own XDG_CONFIG_HOME, whatever it is, plays no part: the folder is the account's home's.
        let own = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        #expect(NodeFolders.unitFolder(accountHome: VibePaths.accountHome) == VibePaths.accountHome + "/.config/systemd/user", "XDG_CONFIG_HOME=\(own ?? "unset")")
    }

    @Test func anExtraManagerVariableRefusesStart() throws {
        let expected = """
            HOME=/home/u
            LANG=C.UTF-8
            LC_TIME=en_GB.UTF-8
            PATH=/usr/local/bin:/usr/bin:/bin
            XDG_RUNTIME_DIR=/run/user/1000
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
            QT_ACCESSIBILITY=1
            GSM_SKIP_SSH_AGENT_WORKAROUND=true
            SSH_AUTH_SOCK=/run/user/1000/keyring/ssh
            """
        // The lead's measurement (ST-D2, 2026-11-16): a desktop session's two names are expected, and the agent socket
        // is unset by the unit, so none of the three refuses.
        #expect(NodeFolders.managerRefusal(showEnvironment: expected) == nil)
        #expect(NodeFacts.extraVariables(showEnvironment: expected) == ["SSH_AUTH_SOCK"])
        let refused = try #require(NodeFolders.managerRefusal(showEnvironment: expected + "\nGIT_CONFIG_GLOBAL=/srv/g\nXDG_CONFIG_HOME=/srv/x"))
        #expect(refused.text.contains("GIT_CONFIG_GLOBAL") && refused.text.contains("XDG_CONFIG_HOME"), "\(refused)")
        #expect(refused.text.contains("systemctl --user unset-environment") && refused.text.contains("environment.d"), "\(refused)")
        #expect(!refused.text.contains("SSH_AUTH_SOCK"), "\(refused)")
    }

    @Test(NodeTraits.linuxOnly) func aMissingManagerSocketOnASystemdMachineRefusesNotDetaches() throws {
        let folder = scratch.url("mode")
        let system = folder.appendingPathComponent("run-systemd-system"), comm = folder.appendingPathComponent("comm")
        let runtime = folder.appendingPathComponent("run-user")
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("systemd"), withIntermediateDirectories: true)
        func mode() -> NodeFolders.Mode { NodeFolders.mode(runtimeFolder: runtime.path, systemdSystem: system.path, initComm: comm.path) }
        // Neither: no systemd.
        #expect(mode() == .noSystemd)
        // pid 1 is systemd, and the user manager's socket is missing: refused, never taken as "no systemd".
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try "systemd\n".write(to: comm, atomically: true, encoding: .utf8)
        #expect(mode() == .socketMissing)
        // With the socket: systemd.
        try Data().write(to: runtime.appendingPathComponent("systemd/private"))
        #expect(mode() == .systemd)
        // pid 1 another init: no systemd, whatever the folder says.
        try "init\n".write(to: comm, atomically: true, encoding: .utf8)
        #expect(mode() == .noSystemd)
    }

    /// A folder made with every folder from `base` down to it 0755 (the scratch home is 0700).
    private static func makeFolder(_ url: URL, below base: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var folder = url.standardizedFileURL
        while folder.path.count > base.standardizedFileURL.path.count {
            chmod(folder.path, 0o755)
            folder.deleteLastPathComponent()
        }
    }

    /// An executable file at `url` holding `text`.
    private static func makeProgram(_ url: URL, _ text: String = "#!/bin/sh\nexit 0\n") throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }

    /// A scratch home with swiftly's folder holding `swift` and nvm's `versions` holding `node` for each of `versions`.
    private func toolHome(versions: [String] = ["v22.1.0"]) throws -> URL {
        let home = scratch.url("toolhome").appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(home.path, 0o700)
        let swift = home.appendingPathComponent(".local/share/swiftly/bin")
        try Self.makeFolder(swift, below: home)
        try Self.makeProgram(swift.appendingPathComponent("swift"))
        for version in versions {
            let bin = home.appendingPathComponent(".nvm/versions/node/\(version)/bin")
            try Self.makeFolder(bin, below: home)
            try Self.makeProgram(bin.appendingPathComponent("node"))
        }
        return home
    }

    @Test(NodeTraits.linuxOnly) func theToolFoldersComeFromFixedPlaces() throws {
        let home = try toolHome()
        let swiftBin = home.appendingPathComponent(".local/share/swiftly/bin").path
        let nodeBin = { (version: String) in home.appendingPathComponent(".nvm/versions/node/\(version)/bin").path }
        // Found in their fixed places: nothing is looked up on PATH (the function reads no environment at all).
        let found = try NodeFolders.toolFolders(accountHome: home.path, nodeVersion: nil, existingUnit: nil).get()
        #expect(found.swiftBin == swiftBin && found.nodeBin == nodeBin("v22.1.0"), "\(found)")

        // Two node versions: refused without --node-version, naming both; with it, that one; an existing unit's kept.
        try Self.makeFolder(URL(fileURLWithPath: nodeBin("v20.0.0")), below: home)
        try Self.makeProgram(URL(fileURLWithPath: nodeBin("v20.0.0")).appendingPathComponent("node"))
        guard case .failure(let two) = NodeFolders.toolFolders(accountHome: home.path, nodeVersion: nil, existingUnit: nil) else {
            Issue.record("two node versions were taken without --node-version"); return
        }
        #expect(two.text.contains("--node-version") && two.text.contains("v20.0.0") && two.text.contains("v22.1.0"), "\(two)")
        #expect(try NodeFolders.toolFolders(accountHome: home.path, nodeVersion: "v20.0.0", existingUnit: nil).get().nodeBin == nodeBin("v20.0.0"))
        var unit = Self.inputs
        unit.nodeBin = nodeBin("v20.0.0")
        #expect(try NodeFolders.toolFolders(accountHome: home.path, nodeVersion: nil, existingUnit: unit).get().nodeBin == nodeBin("v20.0.0"))
        #expect(try NodeFolders.toolFolders(accountHome: home.path, nodeVersion: "v22.1.0", existingUnit: unit).get().nodeBin == nodeBin("v22.1.0"))
        guard case .failure(let climbing) = NodeFolders.toolFolders(accountHome: home.path, nodeVersion: "../../x", existingUnit: nil) else {
            Issue.record("--node-version ../../x was taken"); return
        }
        #expect(climbing.text.contains("../../x"), "\(climbing)")
        try FileManager.default.removeItem(atPath: (nodeBin("v20.0.0") as NSString).deletingLastPathComponent)

        // A folder its group may write: refused, naming it.
        chmod(swiftBin, 0o775)
        guard case .failure(let writable) = NodeFolders.toolFolders(accountHome: home.path, nodeVersion: nil, existingUnit: nil) else {
            Issue.record("a group-writable swift folder was taken"); return
        }
        #expect(writable.text.contains(swiftBin) && writable.text.contains("writ"), "\(writable)")
        chmod(swiftBin, 0o755)
        // A folder above it, up to the home, the same.
        let share = home.appendingPathComponent(".local/share").path
        chmod(share, 0o757)
        guard case .failure(let above) = NodeFolders.toolFolders(accountHome: home.path, nodeVersion: nil, existingUnit: nil) else {
            Issue.record("a swift folder below an others-writable folder was taken"); return
        }
        #expect(above.text.contains(share), "\(above)")
        chmod(share, 0o755)

        // A folder owned by another uid (the check's lstat stood in for).
        let stranger = { (path: String) -> Platform.Tools.FileStatus? in
            guard var status = NodeFolders.fileStatus(path) else { return nil }
            if path == nodeBin("v22.1.0") { status.owner = 4242 }
            return status
        }
        guard case .failure(let owned) = NodeFolders.toolFolders(accountHome: home.path, nodeVersion: nil, existingUnit: nil, status: stranger) else {
            Issue.record("a node folder owned by another uid was taken"); return
        }
        #expect(owned.text.contains(nodeBin("v22.1.0")) && owned.text.contains("owned"), "\(owned)")

        // A relative home, and a missing swift folder.
        guard case .failure(let relative) = NodeFolders.toolFolders(accountHome: "relative/home", nodeVersion: nil, existingUnit: nil) else {
            Issue.record("a relative folder was taken"); return
        }
        #expect(relative.text.contains("relative/home"), "\(relative)")
        try FileManager.default.removeItem(atPath: swiftBin)
        guard case .failure(let missing) = NodeFolders.toolFolders(accountHome: home.path, nodeVersion: nil, existingUnit: nil) else {
            Issue.record("a missing swift folder was taken"); return
        }
        #expect(missing.text.contains(swiftBin), "\(missing)")
    }

    /// An installed build in `prefix`: `<prefix>/<folderName>/bin/` with the cli, host and server (small stand-ins), and
    /// a `build-info` naming `commit` with their hashes.
    @discardableResult
    private static func makeBuild(prefix: URL, commit: String, folderName: String? = nil) throws -> URL {
        let folder = prefix.appendingPathComponent(folderName ?? commit)
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        var binaries: [String: String] = [:]
        for name in [NodeFolders.installedCLI, BuildInfo.host, BuildInfo.server] {
            let bytes = Data("#!/bin/sh\n# \(name) of \(commit)\n".utf8)
            try bytes.write(to: bin.appendingPathComponent(name))
            chmod(bin.appendingPathComponent(name).path, 0o755)
            binaries[name] = BuildInfo.sha256(of: bytes)
        }
        let info = BuildInfo(commit: commit, binaries: binaries, swift: "Swift version 6.4.2", resolved: String(repeating: "a", count: 64))
        try info.encoded.write(to: folder.appendingPathComponent(BuildInfo.fileName))
        return folder
    }

    private static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }

    @Test(NodeTraits.linuxOnly) func aCommandLineOutsideAnInstallDoesntStartTheNode() throws {
        let prefix = scratch.url("builds")
        let folder = try Self.makeBuild(prefix: prefix, commit: Self.commit)
        let cli = folder.appendingPathComponent("bin/\(NodeFolders.installedCLI)")
        let installed = try NodeFolders.installedBuild(executable: cli.path, prefix: prefix.path).get()
        #expect(installed.commit == Self.commit)
        #expect(installed.folder == folder.resolvingSymlinksInPath().path)
        // Through a link (`current/bin/vibeswitcher`, as `vs` runs it): resolved first.
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("current").path, withDestinationPath: Self.commit)
        #expect(try NodeFolders.installedBuild(executable: prefix.appendingPathComponent("current/bin/vibeswitcher").path, prefix: prefix.path).get().commit == Self.commit)

        // A command line under .build.
        let built = scratch.url("checkout").appendingPathComponent(".build/debug")
        try FileManager.default.createDirectory(at: built, withIntermediateDirectories: true)
        try Self.makeProgram(built.appendingPathComponent("vibeswitcher-cli"))
        guard case .failure(let outside) = NodeFolders.installedBuild(executable: built.appendingPathComponent("vibeswitcher-cli").path, prefix: prefix.path) else {
            Issue.record("a command line under .build was taken for an installed one"); return
        }
        #expect(outside.text.contains("start runs only from an installed build"), "\(outside)")

        // A folder whose name isn't its build-info's commit.
        let renamed = try Self.makeBuild(prefix: prefix, commit: Self.commit, folderName: Self.other)
        guard case .failure(let misnamed) = NodeFolders.installedBuild(executable: renamed.appendingPathComponent("bin/vibeswitcher").path, prefix: prefix.path) else {
            Issue.record("a folder named for another commit was taken"); return
        }
        #expect(misnamed.text.contains("start runs only from an installed build") && misnamed.text.contains(Self.other), "\(misnamed)")

        // A command line whose bytes aren't the ones build-info records.
        try Self.append("changed\n", to: cli)
        guard case .failure(let changed) = NodeFolders.installedBuild(executable: cli.path, prefix: prefix.path) else {
            Issue.record("a command line whose hash differs was taken"); return
        }
        #expect(changed.text.contains(NodeFolders.installedCLI) && changed.text.contains("sha256"), "\(changed)")
    }

    @Test(NodeTraits.linuxOnly) func theUnitsBuildIsCheckedBeforeItIsStarted() throws {
        let prefix = scratch.url("builds")
        let folder = try Self.makeBuild(prefix: prefix, commit: Self.commit)
        var inputs = Self.inputs
        inputs.prefix = prefix.path
        let text = try NodeUnit.text(inputs).get()
        #expect(NodeFolders.unitBuild(unitText: text, prefix: prefix.path) == .success(inputs))

        let execStart = "ExecStart=" + NodeUnit.execStart(prefix: prefix.path, commit: Self.commit).joined(separator: " ")
        func refusal(_ replaced: String) -> StartRefusal? {
            let changed = text.replacingOccurrences(of: execStart, with: replaced)
            guard case .failure(let refused) = NodeFolders.unitBuild(unitText: changed, prefix: prefix.path) else { return nil }
            return refused
        }
        // `../x` as its commit.
        let climbing = refusal("ExecStart=" + NodeUnit.execStart(prefix: prefix.path, commit: "../x").joined(separator: " "))
        #expect(climbing?.text.contains("40") == true && climbing?.text.contains("current") == true, "\(String(describing: climbing))")
        // A folder outside the prefix.
        let elsewhere = refusal("ExecStart=" + NodeUnit.execStart(prefix: "/srv/elsewhere", commit: Self.commit).joined(separator: " "))
        #expect(elsewhere?.text.contains("/srv/elsewhere") == true, "\(String(describing: elsewhere))")
        // An extra argument.
        let extra = refusal(execStart + " --lock /srv/l")
        #expect(extra?.text.contains("ExecStart") == true && extra?.text.contains("--lock") == true, "\(String(describing: extra))")
        // A host whose bytes aren't the ones build-info records.
        try Self.append("changed\n", to: folder.appendingPathComponent("bin/vibeswitcher-host"))
        guard case .failure(let host) = NodeFolders.unitBuild(unitText: text, prefix: prefix.path) else {
            Issue.record("a unit whose host differs from its build-info was taken"); return
        }
        #expect(host.text.contains("vibeswitcher-host") && host.text.contains("sha256"), "\(host)")
        // A commit folder that isn't a direct child of the prefix (a link out of it).
        let outside = scratch.url("outside")
        try Self.makeBuild(prefix: outside, commit: Self.other)
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent(Self.other).path,
                                                   withDestinationPath: outside.appendingPathComponent(Self.other).path)
        var linked = inputs
        linked.commit = Self.other
        guard case .failure(let away) = NodeFolders.unitBuild(unitText: try NodeUnit.text(linked).get(), prefix: prefix.path) else {
            Issue.record("a commit folder linked out of the prefix was taken"); return
        }
        #expect(away.text.contains("prefix"), "\(away)")
    }

    @Test(NodeTraits.linuxOnly) func thePreflightNamesWhatIsMissing() throws {
        let folder = scratch.url("preflight")
        let swiftBin = folder.appendingPathComponent("swiftly-bin"), nodeBin = folder.appendingPathComponent("node-bin")
        for made in [swiftBin, nodeBin] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
        let link = folder.appendingPathComponent("claude-link"), claude = folder.appendingPathComponent("claude-2.1")
        func refused(git: String = Platform.Tools.absentGit) -> String? {
            guard case .failure(let refusal) = StartPreflight(claudeLink: link.path, swiftBin: swiftBin.path, nodeBin: nodeBin.path, git: git).check() else { return nil }
            return refusal.text
        }
        // Each missing piece is named by its label, the paths read with it (a scratch path may hold any word).
        #expect(refused()?.contains("claude: ") == true, "\(String(describing: refused()))")
        try Self.makeProgram(claude)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: claude.path)
        #expect(refused()?.contains("claude: ") == false && refused()?.contains("swift in ~/.local/share/swiftly/bin") == true, "\(String(describing: refused()))")
        try Self.makeProgram(swiftBin.appendingPathComponent("swift"))
        #expect(refused()?.contains("swift: ") == false && refused()?.contains("node: ") == true, "\(String(describing: refused()))")
        try Self.makeProgram(nodeBin.appendingPathComponent("node"))
        #expect(refused() == "start's preflight: git: no git in a folder only root can write (on PATH, owned by root up to /)", "\(String(describing: refused()))")
        let git = folder.appendingPathComponent("git")
        try Self.makeProgram(git)
        let found = try StartPreflight(claudeLink: link.path, swiftBin: swiftBin.path, nodeBin: nodeBin.path, git: git.path).check().get()
        #expect(found == StartPreflight.Found(claude: claude.resolvingSymlinksInPath().path, swift: swiftBin.appendingPathComponent("swift").path,
                                              node: nodeBin.appendingPathComponent("node").path, git: git.path), "\(found)")
    }
}
