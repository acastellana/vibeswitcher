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
            Type=simple
            StandardInput=null
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
        // A path Linux reads as another one: `//mnt/c/…` is `/mnt/c/…`; an empty name or a trailing `/` isn't the
        // path's own form either (the review of S1).
        for (bad, named) in [("//mnt/c/Users/u/swift/bin", "/mnt/"), ("/home/u//swift/bin", "empty name"), ("/home/u/swift/bin/", "empty name")] {
            var odd = Self.inputs
            odd.swiftBin = bad
            guard case .failure(let refused) = NodeUnit.text(odd) else { Issue.record("the swift folder \(bad) was taken"); continue }
            #expect(refused.text.contains(bad) && refused.text.contains(named), "\(bad): \(refused)")
        }
        // A unit someone else wrote with such a folder in its PATH isn't read as start's.
        let written = try NodeUnit.text(Self.inputs).get()
        let windows = written.replacingOccurrences(of: Self.inputs.swiftBin + ":", with: "//mnt/c/x:")
        guard case .failure(let read) = NodeUnit.inputs(parsing: windows, prefix: Self.inputs.prefix) else {
            Issue.record("a unit whose PATH holds //mnt/c/x was read as start's"); return
        }
        #expect(read.text.contains("//mnt/c/x"), "\(read)")
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

    /// `~/.config/systemd/user.conf` (and `user.conf.d`) setting `DefaultEnvironment=` reaches every unit after the
    /// next `daemon-reload` or login, past a `show-environment` read before it (the review of S1): refused, naming the
    /// file and the key.
    @Test(NodeTraits.linuxOnly) func aManagerConfigThatSetsAnEnvironmentRefusesStart() throws {
        let home = scratch.url("confhome")
        let systemd = home.appendingPathComponent(".config/systemd")
        try FileManager.default.createDirectory(at: systemd.appendingPathComponent("user.conf.d"), withIntermediateDirectories: true)
        #expect(NodeFolders.managerConfigRefusal(accountHome: home.path) == nil)
        let conf = systemd.appendingPathComponent("user.conf")
        // Stock lines, commented out, and a key that sets no environment: taken.
        try "[Manager]\n#DefaultEnvironment=\n;ManagerEnvironment=\nLogLevel=info\nDefaultEnvironment=\n".write(to: conf, atomically: true, encoding: .utf8)
        #expect(NodeFolders.managerConfigRefusal(accountHome: home.path) == nil)
        try "[Manager]\nDefaultEnvironment=GIT_CONFIG_GLOBAL=/srv/evil.gitconfig XDG_CONFIG_HOME=/srv/x\n".write(to: conf, atomically: true, encoding: .utf8)
        let refused = try #require(NodeFolders.managerConfigRefusal(accountHome: home.path))
        #expect(refused.text.contains(conf.path) && refused.text.contains("DefaultEnvironment"), "\(refused)")
        try FileManager.default.removeItem(at: conf)
        let dropIn = systemd.appendingPathComponent("user.conf.d/10-x.conf")
        try "[Manager]\n ManagerEnvironment = XDG_CONFIG_HOME=/srv/x\n".write(to: dropIn, atomically: true, encoding: .utf8)
        let fromDropIn = try #require(NodeFolders.managerConfigRefusal(accountHome: home.path))
        #expect(fromDropIn.text.contains(dropIn.path) && fromDropIn.text.contains("ManagerEnvironment"), "\(fromDropIn)")
        // A file there not named *.conf is one the manager doesn't read.
        try FileManager.default.moveItem(at: dropIn, to: systemd.appendingPathComponent("user.conf.d/10-x.conf.off"))
        #expect(NodeFolders.managerConfigRefusal(accountHome: home.path) == nil)
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
        // A commit folder that is a link to a sibling build: the unit would say one commit and run another's bytes
        // (the review of S1). Refused, naming the link.
        let third = "fedcba9876543210fedcba9876543210fedcba98"
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent(third).path, withDestinationPath: Self.commit)
        var sibling = inputs
        sibling.commit = third
        guard case .failure(let alias) = NodeFolders.unitBuild(unitText: try NodeUnit.text(sibling).get(), prefix: prefix.path) else {
            Issue.record("a commit folder linked to a sibling build was taken"); return
        }
        #expect(alias.text.contains(third) && alias.text.contains("link"), "\(alias)")
        guard case .failure = NodeFolders.verifyBuild(folder: prefix.appendingPathComponent(third).path, prefix: prefix.path) else {
            Issue.record("verifyBuild took a commit folder that is a link"); return
        }
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

// MARK: - `start` through systemd (the start plan's S2)

/// What a `StartSequence` stand-in saw, in order: each step's name as it ran (`typed:` with what it said, `journal:`
/// with the entry's event, `starter:` with the commit, then `unit:start` once its `beforeStart` passed), the entries'
/// fields and what was said.
final class StartWorld: @unchecked Sendable {
    static let home = "/home/u"
    static let prefix = "/home/u/.vibeswitcher/v2/builds"
    static let installed = StartCommandTests.commit
    static let swiftBin = "/home/u/.local/share/swiftly/bin"
    static let nodeBin = "/home/u/.nvm/versions/node/v22.1.0/bin"

    private let lock = NSLock()
    private var _log: [String] = []
    private var _entries: [[(name: String, value: String)]] = []
    private var _said: [String] = []
    private var _started: [(NodeUnit.Inputs, Bool)] = []

    var kind = StartSequence.Kind.node(.systemd)
    var installedBuild: Result<(commit: String, folder: String), StartRefusal> = .success((commit: installed, folder: prefix + "/" + installed))
    var facts = NodeFacts(interop: false, automounts: [], kernelLines: [], manager: .extra([]))
    var managerEnvironment: Result<String, NodeFacts.Failure> = .success("HOME=/home/u\nPATH=/usr/bin:/bin\nXDG_RUNTIME_DIR=/run/user/1000\n")
    var managerConfig: StartRefusal?
    var server = StartSequence.ServerAnswer.notRunning("the node isn't running: no server answers at /x/v2/server.sock")
    var acknowledged: Result<Bool, NodeFacts.Failure> = .success(false)
    /// What each typed code gives, in turn (the last repeated).
    var typed: [TypedOutcome] = [.typed]
    var journalWrites = true
    var existingUnit: String?
    var unitBuild: Result<NodeUnit.Inputs, StartRefusal> = .failure(StartRefusal("no unit"))
    var current: String? = installed
    var enabledBy: [String] = []
    var toolFolders: Result<(swiftBin: String, nodeBin: String), StartRefusal> = .success((swiftBin: swiftBin, nodeBin: nodeBin))
    var toolFoldersAsked: [NodeUnit.Inputs?] = []
    var preflight: Result<StartPreflight.Found, StartRefusal> = .success(.init(claude: "/home/u/.local/share/claude/versions/2.1", swift: swiftBin + "/swift",
                                                                                 node: nodeBin + "/node", git: "/usr/bin/git"))
    var starter: Result<NodeStarter.Started, StartRefusal>?
    /// The starter refuses before it runs `beforeStart`, as a show check that fails does.
    var starterRefusesBeforeStart: StartRefusal?

    var log: [String] { lock.withLock { _log } }
    var entries: [[(name: String, value: String)]] { lock.withLock { _entries } }
    var said: String { lock.withLock { _said.joined(separator: "\n") } }
    var started: [(NodeUnit.Inputs, Bool)] { lock.withLock { _started } }

    private func note(_ step: String) { lock.withLock { _log.append(step) } }

    /// The steps, each noting itself.
    var steps: StartSequence.Steps {
        var typedCount = 0
        return StartSequence.Steps(
            home: Self.home, prefix: Self.prefix,
            kind: { self.note("kind"); return self.kind },
            installedBuild: { self.note("installedBuild"); return self.installedBuild },
            facts: { self.note("facts"); return self.facts },
            managerEnvironment: { self.note("managerEnvironment"); return self.managerEnvironment },
            managerConfig: { self.note("managerConfig"); return self.managerConfig },
            serverAnswers: { self.note("server"); return self.server },
            acknowledged: { self.note("acknowledged"); return self.acknowledged },
            showList: { self.note("showList") },
            typed: { _, what in
                self.note("typed:" + what)
                defer { typedCount += 1 }
                return self.typed[min(typedCount, self.typed.count - 1)]
            },
            say: { line in self.lock.withLock { self._said.append(line) } },
            journal: { fields in
                self.note("journal:" + (fields.first { $0.name == "VIBESWITCHER_EVENT" }?.value ?? "?"))
                guard self.journalWrites else { return false }
                self.lock.withLock { self._entries.append(fields) }
                return true
            },
            existingUnit: { self.note("existingUnit"); return self.existingUnit },
            unitBuild: { _ in self.note("unitBuild"); return self.unitBuild },
            current: { self.note("current"); return self.current },
            enabledBy: { self.note("enabledBy"); return self.enabledBy },
            toolFolders: { _, unit in
                self.note("toolFolders")
                self.lock.withLock { self.toolFoldersAsked.append(unit) }
                return self.toolFolders
            },
            preflight: { _, _ in self.note("preflight"); return self.preflight },
            starter: { inputs, atLogin, beforeStart in
                self.note("starter:" + inputs.commit)
                self.lock.withLock { self._started.append((inputs, atLogin)) }
                if let refused = self.starterRefusesBeforeStart { return .failure(refused) }
                if let refused = beforeStart() { return .failure(refused) }
                self.note("unit:start")
                return self.starter ?? .success(NodeStarter.Started(commit: inputs.commit, enabledAtLogin: atLogin))
            })
    }

    func run(_ arguments: StartArguments = StartArguments()) -> Result<StartSequence.Outcome, StartRefusal> {
        StartSequence(steps: steps).run(arguments)
    }

    /// Whether any step after the checks wrote, called or recorded anything.
    var touchedNothing: Bool { !log.contains { $0.hasPrefix("starter:") || $0.hasPrefix("journal:") } && entries.isEmpty }
}

extension StartCommandTests {
    // MARK: StartSequence (pure: the Mac runs these)

    @Test func theS11ListComesBeforeAnythingIsStarted() throws {
        let world = StartWorld()
        #expect(try world.run().get() == .started(commit: StartWorld.installed))
        let log = world.log
        let ack = try #require(log.firstIndex(of: "journal:" + NotPromised.ackEvent), "\(log)")
        let list = try #require(log.firstIndex(of: "showList"), "\(log)")
        let started = try #require(log.firstIndex { $0.hasPrefix("starter:") }, "\(log)")
        #expect(list < ack && ack < started, "\(log)")
        // Before the preflight, the unit's build and the confirmation, too: "the first time … before anything".
        #expect(ack < (log.firstIndex(of: "preflight") ?? 0) && ack < (log.firstIndex(of: "existingUnit") ?? 0), "\(log)")
        #expect(world.entries.first?.contains { $0.name == "VIBESWITCHER_EVENT" && $0.value == NotPromised.ackEvent } == true)

        // The acknowledgment's code typed wrong: nothing is called, written or recorded.
        let wrong = StartWorld()
        wrong.typed = [.wrong]
        guard case .failure(let refused) = wrong.run() else { Issue.record("a wrong acknowledgment code started the node"); return }
        #expect(refused.text == TypedOutcome.wrong.refusal, "\(refused)")
        #expect(wrong.touchedNothing, "\(wrong.log)")
        #expect(!wrong.log.contains("preflight") && !wrong.log.contains("existingUnit"), "\(wrong.log)")

        // Acknowledged before: the list isn't shown, and only the start's own code is asked.
        let known = StartWorld()
        known.acknowledged = .success(true)
        #expect(try known.run().get() == .started(commit: StartWorld.installed))
        #expect(!known.log.contains("showList") && known.log.filter { $0.hasPrefix("typed:") }.count == 1, "\(known.log)")
        #expect(!known.entries.contains { $0.contains { $0.value == NotPromised.ackEvent } })
    }

    @Test func startJournalsItsOwnStartBeforeTheManagerIsAsked() throws {
        let world = StartWorld()
        world.acknowledged = .success(true)
        _ = try world.run().get()
        let log = world.log
        let typed = try #require(log.firstIndex { $0.hasPrefix("typed:") }, "\(log)")
        let entry = try #require(log.firstIndex(of: "journal:start"), "\(log)")
        let starter = try #require(log.firstIndex { $0.hasPrefix("starter:") }, "\(log)")
        let started = try #require(log.firstIndex(of: "unit:start"), "\(log)")
        // The entry is the starter's `beforeStart`: written after the code, once the starter's checks passed, and
        // before the manager is asked to start the unit (the review of S2).
        #expect(typed < starter && starter < entry && entry < started, "\(log)")
        // The entry is `NodeJournal.entry(event: "start", action:)`: stamped as journald stamps a terminal scope's
        // entry, and followed 2 s later by systemd's start of the unit, it explains that start.
        let fields = try #require(world.entries.last)
        #expect(fields.contains { $0.name == "VIBESWITCHER_EVENT" && $0.value == "start" } && fields.contains { $0.name == "VIBESWITCHER_ACTION" })
        var stamped: [String: Any] = ["_UID": "1000", "_SYSTEMD_CGROUP": "/init.scope"]
        for field in fields { stamped[field.name] = field.value }
        let at = NodeJournalTests.start
        let entries = NodeJournalTests.read([NodeJournalTests.line(stamped, at: at), NodeJournalTests.job("start", at: at.addingTimeInterval(2))])
        let starts = NodeJournal.events(entries)
        #expect(starts.count == 1)
        #expect(NodeJournal.unexplained(starts: starts, entries: entries, rule: NodeJournalTests.rule).isEmpty)

        // An entry that can't be written: refused, nothing started.
        let unwritten = StartWorld()
        unwritten.acknowledged = .success(true)
        unwritten.journalWrites = false
        guard case .failure(let refused) = unwritten.run() else { Issue.record("a start with no journal entry went on"); return }
        #expect(refused.text.contains("journal"), "\(refused)")
        #expect(!unwritten.log.contains("unit:start"), "\(unwritten.log)")
    }

    /// The review of S2: a start the starter's checks refuse (a drop-in, a variable the manager shows after the
    /// reload) leaves no `start` entry, so a job someone starts within the entry's window is still unexplained.
    @Test func aRefusedStartLeavesNoEntryThatExplainsALaterJob() throws {
        let world = StartWorld()
        world.acknowledged = .success(true)
        world.starterRefusesBeforeStart = StartRefusal("the manager doesn't run the unit start wrote: the manager shows DropInPaths=x")
        guard case .failure(let refused) = world.run() else { Issue.record("a refused start went on"); return }
        #expect(refused.text.contains("DropInPaths"), "\(refused)")
        #expect(!world.log.contains("journal:start") && !world.log.contains("unit:start"), "\(world.log)")
        #expect(!world.entries.contains { $0.contains { $0.name == "VIBESWITCHER_EVENT" && $0.value == "start" } })
    }

    /// ST-D4's "says when the unit is found enabled", before the code (the review of S2): a plain start of a unit an
    /// earlier `--at-login` (or anyone) enabled doesn't say "It isn't enabled".
    @Test func aPlainStartOfAnEnabledUnitSaysSoBeforeItsCode() throws {
        let world = StartWorld()
        world.acknowledged = .success(true)
        world.enabledBy = ["default.target.wants"]
        _ = try world.run().get()
        #expect(world.said.contains("It is enabled already (a link to it in default.target.wants)"), "\(world.said)")
        #expect(world.said.contains("without start's checks") && !world.said.contains("isn't enabled"), "\(world.said)")
        let read = try #require(world.log.firstIndex(of: "enabledBy"), "\(world.log)")
        let typed = try #require(world.log.firstIndex { $0.hasPrefix("typed:") }, "\(world.log)")
        #expect(read < typed, "\(world.log)")
        // Not enabled: said so, as before.
        let plain = StartWorld()
        plain.acknowledged = .success(true)
        _ = try plain.run().get()
        #expect(plain.said.contains("It isn't enabled") && !plain.said.contains("enabled already"), "\(plain.said)")
    }

    @Test func aStartWithNoTerminalIsRefused() {
        for acknowledged in [false, true] {
            let world = StartWorld()
            world.acknowledged = .success(acknowledged)
            world.typed = [.noTerminal]
            guard case .failure(let refused) = world.run() else { Issue.record("a start with no terminal went on"); return }
            #expect(refused.text == TypedOutcome.noTerminal.refusal, "\(refused)")
            #expect(refused.text.contains("controlling terminal"), "\(refused)")
            #expect(world.touchedNothing, "\(world.log)")
        }
    }

    @Test func aCommandLineBuiltInDotBuildRefusesNodeModeBeforeAnyWrite() {
        let world = StartWorld()
        world.installedBuild = .failure(StartRefusal("start runs only from an installed build: this command line is /src/.build/debug/vibeswitcher-cli"))
        guard case .failure(let refused) = world.run() else { Issue.record("a command line under .build started the node"); return }
        #expect(refused.text.contains("start runs only from an installed build"), "\(refused)")
        // The mode was read (a file read), and nothing after the check: no facts (the manager's environment is a
        // systemctl call), no server, no unit, no call, no entry.
        #expect(world.log == ["kind", "installedBuild"], "\(world.log)")
        // A scratch node isn't asked for an installed build (its harness starts it).
        let scratch = StartWorld()
        scratch.kind = .scratch
        scratch.installedBuild = world.installedBuild
        _ = scratch.run()
        #expect(!scratch.log.contains("installedBuild"), "\(scratch.log)")
    }

    @Test func startStartsTheUnitsCommitNotCurrent() throws {
        let unitCommit = Self.other, current = StartWorld.installed
        let world = StartWorld()
        world.acknowledged = .success(true)
        world.existingUnit = "a unit naming \(unitCommit)"
        // What the unit's text says of its home and swift folder isn't taken: the unit is made again from the
        // account's home and the fixed places (the review of S1).
        let unitInputs = NodeUnit.Inputs(prefix: StartWorld.prefix, commit: unitCommit, home: "/srv/other", swiftBin: "/srv/swift/bin",
                                         nodeBin: "/home/u/.nvm/versions/node/v20.0.0/bin")
        world.unitBuild = .success(unitInputs)
        world.current = current
        world.toolFolders = .success((swiftBin: StartWorld.swiftBin, nodeBin: "/home/u/.nvm/versions/node/v20.0.0/bin"))
        #expect(try world.run().get() == .started(commit: unitCommit))
        let (inputs, atLogin) = try #require(world.started.first)
        #expect(inputs == NodeUnit.Inputs(prefix: StartWorld.prefix, commit: unitCommit, home: StartWorld.home, swiftBin: StartWorld.swiftBin,
                                          nodeBin: "/home/u/.nvm/versions/node/v20.0.0/bin"))
        #expect(!atLogin)
        // The unit's node folder went to toolFolders (kept unless --node-version is given).
        #expect(world.toolFoldersAsked == [unitInputs])
        // The confirmation names both commits, and how to run current.
        #expect(world.said.contains(unitCommit) && world.said.contains(current), "\(world.said)")
        #expect(world.said.contains("`vs switch \(current)`"), "\(world.said)")

        // No unit: the command line's own installed build, and nothing said of current.
        let fresh = StartWorld()
        fresh.acknowledged = .success(true)
        #expect(try fresh.run(StartArguments(atLogin: true)).get() == .started(commit: StartWorld.installed))
        #expect(fresh.started.first?.0.commit == StartWorld.installed && fresh.started.first?.1 == true)
        #expect(!fresh.said.contains("vs switch"), "\(fresh.said)")
        #expect(!fresh.log.contains("unitBuild"), "\(fresh.log)")

        // A unit start won't take: refused, naming why, nothing started.
        let broken = StartWorld()
        broken.acknowledged = .success(true)
        broken.existingUnit = "x"
        broken.unitBuild = .failure(StartRefusal("the unit's build isn't started: …; removing the unit file lets `start` run `current`"))
        guard case .failure(let refused) = broken.run() else { Issue.record("a unit start can't take was started"); return }
        #expect(refused.text.contains("removing the unit file"), "\(refused)")
        #expect(broken.touchedNothing, "\(broken.log)")
    }

    @Test func aRunningNodeIsNotStartedAndAcknowledgesAfterItsAnswer() throws {
        let world = StartWorld()
        world.server = .running
        #expect(try world.run().get() == .running)
        let log = world.log
        #expect(!log.contains { $0.hasPrefix("starter:") || $0 == "journal:start" || $0 == "preflight" || $0 == "existingUnit" }, "\(log)")
        // The acknowledgment, the first time, after the server's answer (as before S2).
        let server = try #require(log.firstIndex(of: "server"))
        let ack = try #require(log.firstIndex(of: "journal:" + NotPromised.ackEvent), "\(log)")
        #expect(server < ack)
        // A journal that can't be read: the list shown, and said that it can't be recorded; the node still runs.
        let unread = StartWorld()
        unread.server = .running
        unread.acknowledged = .failure(.init("journalctl --user didn't answer"))
        #expect(try unread.run().get() == .running)
        #expect(unread.log.contains("showList") && unread.said.contains("can't be recorded"), "\(unread.log) \(unread.said)")
    }

    @Test func aScratchNodeWithNoServerIsRefusedByTheSequence() {
        let world = StartWorld()
        world.kind = .scratch
        guard case .failure(let refused) = world.run() else { Issue.record("a scratch node was started by the command line"); return }
        #expect(refused.exitCode == 69, "\(refused)")
        #expect(refused.text.contains("the node isn't running") && refused.text.contains("started by its harness"), "\(refused)")
        #expect(world.touchedNothing && !world.log.contains("typed:") && !world.log.contains("managerEnvironment"), "\(world.log)")
        // A listener that fails the check, on a scratch node: refused as before (77).
        let squatted = StartWorld()
        squatted.kind = .scratch
        squatted.server = .refusedByCheck("the process listening on the server's socket (pid 9) is dumpable: not the node's server")
        guard case .failure(let check) = squatted.run() else { Issue.record("a scratch node with a squatter went on"); return }
        #expect(check.exitCode == 77 && check.text.contains("is dumpable"), "\(check)")
    }

    @Test func theManagerAndTheMachineAreRefusedBeforeTheServerIsAsked() {
        let extra = StartWorld()
        extra.managerEnvironment = .success("HOME=/home/u\nPATH=/usr/bin:/bin\nGIT_CONFIG_GLOBAL=/srv/g\n")
        guard case .failure(let manager) = extra.run() else { Issue.record("an extra manager variable started the node"); return }
        #expect(manager.text.contains("GIT_CONFIG_GLOBAL") && manager.text.contains("unset-environment"), "\(manager)")
        #expect(!extra.log.contains("server") && extra.touchedNothing, "\(extra.log)")

        let config = StartWorld()
        config.managerConfig = StartRefusal("/home/u/.config/systemd/user.conf sets DefaultEnvironment=")
        guard case .failure(let conf) = config.run() else { Issue.record("a user.conf setting an environment started the node"); return }
        #expect(conf.text.contains("DefaultEnvironment"), "\(conf)")
        #expect(!config.log.contains("server"), "\(config.log)")

        let unread = StartWorld()
        unread.managerEnvironment = .failure(.init("systemctl --user show-environment didn't answer"))
        guard case .failure(let notRead) = unread.run() else { Issue.record("an unread manager environment started the node"); return }
        #expect(notRead.text.contains("show-environment"), "\(notRead)")

        let interop = StartWorld()
        interop.facts.interop = true
        guard case .failure(let on) = interop.run() else { Issue.record("interop on started the node"); return }
        #expect(on.text.contains("WSL interop is on"), "\(on)")
        #expect(interop.log == ["kind", "installedBuild", "facts"], "\(interop.log)")

        // A machine whose pid 1 is systemd and whose manager's socket is missing: refused, never started detached.
        let missing = StartWorld()
        missing.kind = .node(.socketMissing)
        guard case .failure(let socket) = missing.run() else { Issue.record("a missing manager socket started the node"); return }
        #expect(socket.text.contains("socket is missing"), "\(socket)")
        #expect(missing.touchedNothing, "\(missing.log)")
        // No systemd: S3's detached start, not yet.
        let none = StartWorld()
        none.kind = .node(.noSystemd)
        guard case .failure(let detached) = none.run() else { Issue.record("a machine without systemd started the node"); return }
        #expect(detached.text.contains("no systemd"), "\(detached)")
        #expect(none.touchedNothing, "\(none.log)")
    }

    @Test func startArgumentsAreTheUsagesOnly() {
        #expect(StartArguments.parse([]) == StartArguments())
        #expect(StartArguments.parse(["--interop-is-on", "--at-login", "--node-version", "v22.1.0"])
                == StartArguments(interopIsOn: true, atLogin: true, nodeVersion: "v22.1.0"))
        for bad in [["--node-version"], ["--at-login", "--at-login"], ["x"], ["--node-version", "--at-login"]] {
            #expect(StartArguments.parse(bad) == nil, "\(bad)")
        }
        #expect(StartArguments.usage == "usage: vibeswitcher start [--interop-is-on] [--at-login] [--node-version vX.Y.Z]")
    }

    @Test func theStartConfirmationSaysWhatKillModeMeans() {
        let text = NodeTexts.start(unit: Self.inputs, current: Self.other, previousCommit: Self.commit, atLogin: false, enabledBy: [])
        #expect(text.contains(NodeUnit.killModeConsequence), "\(text)")
        #expect(text.contains("KillMode=control-group") && text.contains("Restart=no") && text.contains("TimeoutStopSec=45"), "\(text)")
        #expect(text.contains(NodeUnit.execStart(prefix: Self.inputs.prefix, commit: Self.commit).joined(separator: " ")), "\(text)")
        #expect(text.contains("the unit runs \(Self.commit); current is \(Self.other) (installed later): `vs switch \(Self.other)` runs it"), "\(text)")
        #expect(text.contains("named \(Self.commit) before"), "\(text)")
        #expect(text.contains(Self.inputs.swiftBin) && text.contains(Self.inputs.nodeBin), "\(text)")
        #expect(!text.contains("at login"), "\(text)")
        let plain = NodeTexts.start(unit: Self.inputs, current: Self.commit, previousCommit: nil, atLogin: true, enabledBy: [])
        #expect(!plain.contains("vs switch") && !plain.contains("before"), "\(plain)")
        #expect(plain.contains("at login"), "\(plain)")
        // Found enabled: said, with the folders inert, whatever the flag.
        for atLogin in [false, true] {
            let enabled = NodeTexts.start(unit: Self.inputs, current: nil, previousCommit: nil, atLogin: atLogin, enabledBy: ["default.target.wants", "x\u{1b}.wants"])
            #expect(enabled.contains("It is enabled already (a link to it in default.target.wants, x"), "\(enabled)")
            #expect(!enabled.contains("\u{1b}") && !enabled.contains("isn't enabled") && !enabled.contains("enabled too"), "\(enabled)")
        }
    }

    // MARK: The wait (the app's HostClientSlowStartTests, port-map row 99), on an injected clock

    /// A clock the wait's pauses move, and a starter whose probe is `probe` at each time.
    private static func waiting(_ probe: @escaping @Sendable (TimeInterval) -> NodeStarter.Probe) -> (NodeStarter, () -> TimeInterval) {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 0 }
        let clock = Clock()
        let starter = NodeStarter(tools: .init(systemctl: "/nonexistent/systemctl", unitFolder: "/nonexistent/unit", runtimeFolder: "/nonexistent/run"),
                                  listen: { probe(clock.now) }, now: { clock.now }, pause: { clock.now += $0 })
        return (starter, { clock.now })
    }

    @Test func aNodeThatTakesSecondsToListenIsWaitedFor() {
        // 5 s late: past the 3 s the app's client once gave its host.
        let (starter, now) = Self.waiting { $0 < 5 ? .notYet : .listening }
        #expect(starter.awaitListening() == nil)
        #expect(now() >= 5 && now() < NodeStarter.listenLimit, "\(now())")
    }

    @Test func aNodeThatEndsWithoutListeningIsFailed() {
        let (starter, now) = Self.waiting { _ in .unitEnded(result: "exit-code") }
        #expect(starter.awaitListening() == StartRefusal("the node didn't start (exit-code); see journalctl --user -u vibeswitcher-node", exitCode: 1))
        // At once, not at the limit.
        #expect(now() < 1, "\(now())")
    }

    /// The node form of `anotherHostListeningIsConnectedToWhileOursStillStarts`: what listens on the node's socket and
    /// fails the server check isn't the node starting. It is waited past, never taken; once the node's own server
    /// answers, that one is; at the limit the refusal names the check's reason.
    @Test func aListenerThatFailsTheServerCheckIsNotTheNodeStarting() {
        let reason = "not the unit's MainPID's child"
        let (passing, passed) = Self.waiting { $0 < 3 ? .refusedByCheck(reason) : .listening }
        #expect(passing.awaitListening() == nil)
        #expect(passed() >= 3, "\(passed())")
        let (starter, now) = Self.waiting { _ in .refusedByCheck(reason) }
        guard let refused = starter.awaitListening() else { Issue.record("a listener failing the check was taken"); return }
        #expect(refused.text.contains(reason), "\(refused)")
        #expect(now() >= NodeStarter.listenLimit, "\(now())")
    }

    @Test func theWaitIsTheAppsHostStartLimit() {
        #expect(NodeStarter.listenLimit == 180)
    }

    @Test func theInstalledCommandLineRunsUsrBinSystemctl() throws {
        let tools = NodeStarter.node(accountHome: "/home/u", uid: 1000)
        #expect(tools == NodeStarter.Tools(systemctl: "/usr/bin/systemctl", unitFolder: "/home/u/.config/systemd/user", runtimeFolder: "/run/user/1000"))
        // systemctl runs with the manager's socket named and nothing else of this process's environment (no
        // XDG_RUNTIME_DIR or DBUS_SESSION_BUS_ADDRESS a worker set picks the manager it talks to).
        #expect(NodeStarter.environment(runtimeFolder: tools.runtimeFolder) == ["PATH=/usr/bin:/bin", "XDG_RUNTIME_DIR=/run/user/1000"])
        // Whatever the environment holds: the start's code reads none of it. (Setting PATH or XDG_* in this process
        // would race the suite's other cases, so the code is read instead: comments and strings aside, no getenv,
        // ProcessInfo or environ in Sources/VibeNode/Start.)
        let folder = ServerLintTests.repo.appendingPathComponent("Sources/VibeNode/Start")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        #expect(files.contains("NodeStarter.swift") && files.contains("NodeFolders.swift"), "\(files)")
        for file in files {
            let code = ServerLintTests.code(try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8))
            for word in ["getenv", "ProcessInfo", "environ"] {
                #expect(!code.contains(try Regex("\\b\(word)\\b")), "\(file) reads \(word)")
            }
        }
    }
}

// MARK: NodeStarter against a recording systemctl (Linux: a scratch folder and a spawned stand-in)

extension StartCommandTests {
    /// A scratch unit folder, a runtime folder holding `systemd/private`, and a recording `systemctl` in `folder`: each
    /// call's arguments appended to `calls`, the environment it saw (`XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`)
    /// to `environments`; `show -p ActiveState <unit>` answered with `state` (`inactive` at first), `show <unit> -p …`
    /// with `show`, `show-environment` with `environment`; the call `fail` holds exits 1.
    struct Manager {
        let folder: URL
        let unitFolder: URL
        let runtime: URL
        let systemctl: URL

        var tools: NodeStarter.Tools { .init(systemctl: systemctl.path, unitFolder: unitFolder.path, runtimeFolder: runtime.path) }
        var unitFile: URL { unitFolder.appendingPathComponent(NodeUnit.fileName) }

        init(_ scratch: Scratch) throws {
            folder = scratch.url("manager")
            unitFolder = folder.appendingPathComponent("home/.config/systemd/user")
            runtime = folder.appendingPathComponent("run-user")
            systemctl = folder.appendingPathComponent("systemctl")
            try FileManager.default.createDirectory(at: runtime.appendingPathComponent("systemd"), withIntermediateDirectories: true)
            try Data().write(to: runtime.appendingPathComponent("systemd/private"))
            try ScratchNode.script("""
                #!/bin/sh
                printf '%s\\n' "$*" >> '\(folder.path)/calls'
                printf 'XDG_RUNTIME_DIR=%s DBUS_SESSION_BUS_ADDRESS=%s\\n' "${XDG_RUNTIME_DIR-unset}" "${DBUS_SESSION_BUS_ADDRESS-unset}" >> '\(folder.path)/environments'
                if [ -f '\(folder.path)/fail' ] && [ "$*" = "$(cat '\(folder.path)/fail')" ]; then exit 1; fi
                case "$*" in
                  *show-environment*) cat '\(folder.path)/environment' ;;
                  "--user show -p ActiveState vibeswitcher-node") cat '\(folder.path)/state' ;;
                  "--user show "*) cat '\(folder.path)/show' ;;
                esac
                exit 0

                """, at: systemctl)
            try "HOME=/home/u\nLANG=C.UTF-8\nPATH=/usr/local/bin:/usr/bin:/bin\nXDG_RUNTIME_DIR=/run/user/1000\n"
                .write(to: folder.appendingPathComponent("environment"), atomically: true, encoding: .utf8)
            try setState("inactive")
        }

        /// What a user unit shows that `expectedShow` doesn't hold as one value (`NodeUnit.defaultsMismatch`), as
        /// measured here (2026-11-16): its slice and `basic.target`, the manager's home, the user's umask.
        static let defaults = ["Requires": "app.slice basic.target", "WorkingDirectory": "!/home/u", "UMask": "0002"]

        /// `show`'s answer: what the manager prints for `expected` (an empty command list left out, as systemd does),
        /// each of `changed` put in its place (nil: left out).
        func answer(_ expected: [String: String], changing changed: [String: String?] = [:]) throws {
            var lines: [String] = []
            for key in NodeUnit.showProperties {
                let value: String? = changed.keys.contains(key) ? changed[key]! : expected[key] ?? Self.defaults[key]
                guard let value else { continue }
                if key.hasPrefix("Exec"), value.isEmpty { continue }
                lines.append(key == "ExecStart" ? "\(key)=\(value) start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }" : "\(key)=\(value)")
            }
            try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("show"), atomically: true, encoding: .utf8)
        }

        func setEnvironment(_ text: String) throws {
            try text.write(to: folder.appendingPathComponent("environment"), atomically: true, encoding: .utf8)
        }

        func setState(_ state: String) throws {
            try "ActiveState=\(state)\n".write(to: folder.appendingPathComponent("state"), atomically: true, encoding: .utf8)
        }

        /// The call that exits 1 from now on.
        func fail(_ call: String) throws {
            try call.write(to: folder.appendingPathComponent("fail"), atomically: true, encoding: .utf8)
        }

        /// Notes `what` among the calls, in order (a `beforeStart` stand-in).
        func note(_ what: String) {
            let url = folder.appendingPathComponent("calls")
            let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (before + what + "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        var calls: [String] { ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        var environments: [String] { ((try? String(contentsOf: folder.appendingPathComponent("environments"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

        func starter() -> NodeStarter { NodeStarter(tools: tools, listen: { .listening }) }
    }

    static let showCall = "--user show vibeswitcher-node -p " + NodeUnit.showProperties.joined(separator: ",")
    static let stateCall = "--user show -p ActiveState vibeswitcher-node"

    @Test(NodeTraits.linuxOnly) func startWritesTheUnitAndAsksTheManagerToStartIt() throws {
        let manager = try Manager(scratch)
        try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path))
        let started = try manager.starter().startUnit(Self.inputs, atLogin: false).get()
        #expect(started == NodeStarter.Started(commit: Self.commit, enabledAtLogin: false))
        // The unit file is NodeUnit.text, 0644, and nothing else is left in the folder (its temporary renamed in).
        #expect(try String(contentsOf: manager.unitFile, encoding: .utf8) == NodeUnit.text(Self.inputs).get())
        #expect(NodeFolders.fileStatus(manager.unitFile.path).map { $0.mode & 0o777 } == 0o644)
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.unitFolder.path) == [NodeUnit.fileName])
        // The calls, exactly: the unit's state, the reload, the show check, the manager's environment read again, the
        // start.
        #expect(manager.calls == [Self.stateCall, "--user daemon-reload", Self.showCall, "--user show-environment", "--user start vibeswitcher-node"], "\(manager.calls)")
        // Each with the manager's socket given and no bus address of this process's.
        #expect(manager.environments == Array(repeating: "XDG_RUNTIME_DIR=\(manager.runtime.path) DBUS_SESSION_BUS_ADDRESS=unset", count: 5), "\(manager.environments)")
    }

    @Test(NodeTraits.linuxOnly) func startAtLoginEnablesFirst() throws {
        let manager = try Manager(scratch)
        try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path))
        _ = try manager.starter().startUnit(Self.inputs, atLogin: true).get()
        #expect(manager.calls == [Self.stateCall, "--user daemon-reload", Self.showCall, "--user show-environment", "--user enable vibeswitcher-node",
                                  "--user start vibeswitcher-node"], "\(manager.calls)")
        // A plain start never enables (startWritesTheUnitAndAsksTheManagerToStartIt's calls).
        let plain = try Manager(scratch)
        try plain.answer(NodeUnit.expectedShow(Self.inputs, unitFile: plain.unitFile.path))
        _ = try plain.starter().startUnit(Self.inputs, atLogin: false).get()
        #expect(!plain.calls.contains { $0.contains("enable") }, "\(plain.calls)")
    }

    @Test(NodeTraits.linuxOnly) func aDropInMakesStartRefuse() throws {
        let cases: [(field: String, value: String?)] = [
            ("DropInPaths", "<units>/vibeswitcher-node.service.d/x.conf"),
            ("ExecStartPre", "{ path=/bin/sh ; argv[]=/bin/sh -c x ; ignore_errors=no ;"),
            ("UnsetEnvironment", ""),
        ]
        for (field, value) in cases {
            let manager = try Manager(scratch)
            try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path),
                               changing: [field: value?.replacingOccurrences(of: "<units>", with: manager.unitFolder.path)])
            guard case .failure(let refused) = manager.starter().startUnit(Self.inputs, atLogin: false) else {
                Issue.record("\(field) changed and start went on"); continue
            }
            #expect(refused.text.contains(field), "\(field): \(refused)")
            #expect(manager.calls == [Self.stateCall, "--user daemon-reload", Self.showCall], "\(field): \(manager.calls)")
        }
    }

    @Test(NodeTraits.linuxOnly) func aManagerXdgConfigHomeDoesntMoveTheUnit() throws {
        let manager = try Manager(scratch)
        // The manager reads a unit elsewhere (its environment's XDG_CONFIG_HOME, say): it shows that file.
        let elsewhere = manager.folder.appendingPathComponent("xdg/systemd/user/vibeswitcher-node.service")
        try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path), changing: ["FragmentPath": elsewhere.path])
        guard case .failure(let refused) = manager.starter().startUnit(Self.inputs, atLogin: false) else {
            Issue.record("a unit the manager reads elsewhere was started"); return
        }
        #expect(refused.text.contains("FragmentPath") && refused.text.contains(elsewhere.path), "\(refused)")
        #expect(!manager.calls.contains("--user start vibeswitcher-node"), "\(manager.calls)")
        // The unit was written in the unit folder given, and only there.
        #expect(FileManager.default.fileExists(atPath: manager.unitFile.path))
        #expect(!FileManager.default.fileExists(atPath: elsewhere.path))
    }

    /// The review of S1: a `daemon-reload` applies `user.conf`'s `DefaultEnvironment=` and `environment.d`, so a name
    /// written after the facts were read shows only now. The manager's environment read again after the show check
    /// refuses, and nothing is enabled or started.
    @Test(NodeTraits.linuxOnly) func aManagerVariableThatShowsAfterTheReloadRefusesStart() throws {
        let manager = try Manager(scratch)
        try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path))
        try manager.setEnvironment("HOME=/home/u\nPATH=/usr/bin:/bin\nGIT_CONFIG_GLOBAL=/srv/evil.gitconfig\n")
        guard case .failure(let refused) = manager.starter().startUnit(Self.inputs, atLogin: true) else {
            Issue.record("a manager variable that showed after the reload was started past"); return
        }
        #expect(refused.text.contains("GIT_CONFIG_GLOBAL"), "\(refused)")
        #expect(manager.calls == [Self.stateCall, "--user daemon-reload", Self.showCall, "--user show-environment"], "\(manager.calls)")
    }

    /// The review of S2: a `vibeswitcher-node.service.wants/` (or `.requires/`, `.upholds/`) link starts another unit
    /// with the node's, between start's last check and the host's exec, with no drop-in; a unit file put in place of
    /// start's before the reload can add a directive the eleven properties don't hold. The manager shows each: start
    /// refuses, naming the field, before `beforeStart` and the start.
    @Test(NodeTraits.linuxOnly) func aDependencyOrDirectiveStartDidntWriteMakesStartRefuse() throws {
        let cases: [(field: String, value: String)] = [
            ("Wants", "evil.service"),
            ("Requires", "app.slice basic.target evil.service"),
            ("Upholds", "evil.service"),
            ("OnSuccess", "evil.service"),
            ("BindsTo", "evil.service"),
            ("EnvironmentFiles", "/home/u/.evil.env (ignore_errors=no)"),
            ("PassEnvironment", "GIT_CONFIG_GLOBAL"),
            ("ExecCondition", "{ path=/bin/sh ; argv[]=/bin/sh -c x ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"),
            ("BindPaths", "/srv/evil:/home/u/.vibeswitcher"),
            ("WorkingDirectory", "/srv/repo"),
            ("UMask", "0000"),
            ("StandardInput", "tty"),
        ]
        for (field, value) in cases {
            let manager = try Manager(scratch)
            try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path), changing: [field: value])
            guard case .failure(let refused) = manager.starter().startUnit(Self.inputs, atLogin: true, beforeStart: { manager.note("<entry>"); return nil }) else {
                Issue.record("\(field)=\(value) shown and start went on"); continue
            }
            #expect(refused.text.contains(field), "\(field): \(refused)")
            #expect(manager.calls == [Self.stateCall, "--user daemon-reload", Self.showCall], "\(field): \(manager.calls)")
        }
        // A user unit's defaults in another order or form pass: its slice and basic.target, the home as written or
        // empty, a stricter umask.
        for (requires, directory, umask) in [("basic.target app.slice", "", "0077"), ("-.slice basic.target", "/home/u", "0022"), ("", "!/home/u", "002")] {
            let manager = try Manager(scratch)
            try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path),
                               changing: ["Requires": requires, "WorkingDirectory": directory, "UMask": umask])
            #expect(throws: Never.self, "\(requires) \(directory) \(umask)") { try manager.starter().startUnit(Self.inputs, atLogin: false).get() }
        }
        // A umask the manager doesn't print is refused too: it can't be judged.
        let unprinted = try Manager(scratch)
        try unprinted.answer(NodeUnit.expectedShow(Self.inputs, unitFile: unprinted.unitFile.path), changing: ["UMask": nil])
        guard case .failure(let umask) = unprinted.starter().startUnit(Self.inputs, atLogin: false) else { Issue.record("an unprinted umask was taken"); return }
        #expect(umask.text.contains("UMask"), "\(umask)")
    }

    /// The review of S2: the start's journal entry (`beforeStart`) is written only once every check passed, after the
    /// manager's environment is read again and before `enable` and `start`; a refusal before it writes none, and an
    /// entry that can't be written starts nothing.
    @Test(NodeTraits.linuxOnly) func theStartEntryIsWrittenOnlyOnceTheChecksPass() throws {
        let manager = try Manager(scratch)
        try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path))
        _ = try manager.starter().startUnit(Self.inputs, atLogin: true, beforeStart: { manager.note("<entry>"); return nil }).get()
        #expect(manager.calls == [Self.stateCall, "--user daemon-reload", Self.showCall, "--user show-environment", "<entry>",
                                  "--user enable vibeswitcher-node", "--user start vibeswitcher-node"], "\(manager.calls)")

        let dropIn = try Manager(scratch)
        try dropIn.answer(NodeUnit.expectedShow(Self.inputs, unitFile: dropIn.unitFile.path), changing: ["DropInPaths": "/x/vibeswitcher-node.service.d/x.conf"])
        _ = dropIn.starter().startUnit(Self.inputs, atLogin: false, beforeStart: { dropIn.note("<entry>"); return nil })
        #expect(!dropIn.calls.contains("<entry>"), "\(dropIn.calls)")

        let unwritten = try Manager(scratch)
        try unwritten.answer(NodeUnit.expectedShow(Self.inputs, unitFile: unwritten.unitFile.path))
        let refusal = StartRefusal("the start couldn't be written to the journal: nothing was started", exitCode: 1)
        #expect(unwritten.starter().startUnit(Self.inputs, atLogin: true, beforeStart: { refusal }) == .failure(refusal))
        #expect(!unwritten.calls.contains { $0.contains("enable") || $0.hasSuffix("start vibeswitcher-node") }, "\(unwritten.calls)")
    }

    /// The review of S2: a unit that runs (or is starting, stopping or reloading) while its server didn't answer isn't
    /// started again: `systemctl start` would do nothing, and start would say it started a build that may not be what
    /// runs. Refused before anything is written; a failed unit is started.
    @Test(NodeTraits.linuxOnly) func aUnitThatAlreadyRunsIsNotStartedAgainOrClaimed() throws {
        for state in ["active", "activating", "deactivating", "reloading"] {
            let manager = try Manager(scratch)
            try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path))
            try manager.setState(state)
            guard case .failure(let refused) = manager.starter().startUnit(Self.inputs, atLogin: false) else {
                Issue.record("a unit \(state) was started and claimed"); continue
            }
            #expect(refused.text.contains("is \(state)") && refused.text.contains("systemctl --user stop vibeswitcher-node"), "\(refused)")
            #expect(manager.calls == [Self.stateCall], "\(state): \(manager.calls)")
            #expect(!FileManager.default.fileExists(atPath: manager.unitFile.path))
        }
        let failed = try Manager(scratch)
        try failed.answer(NodeUnit.expectedShow(Self.inputs, unitFile: failed.unitFile.path))
        try failed.setState("failed")
        _ = try failed.starter().startUnit(Self.inputs, atLogin: false).get()
        #expect(failed.calls.last == "--user start vibeswitcher-node", "\(failed.calls)")
    }

    /// The review of S2: past `enable`, a start that fails leaves the unit enabled, and the refusal says so and how to
    /// undo it; at the wait's limit the unit may still run, and the refusal says how to stop it.
    @Test(NodeTraits.linuxOnly) func aFailedStartAfterEnableSaysTheUnitStaysEnabled() throws {
        for atLogin in [true, false] {
            let manager = try Manager(scratch)
            try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path))
            try manager.fail("--user start vibeswitcher-node")
            guard case .failure(let refused) = manager.starter().startUnit(Self.inputs, atLogin: atLogin) else { Issue.record("a failed start went on"); continue }
            #expect(refused.text.contains("exited 1"), "\(refused)")
            #expect(refused.text.contains("stays enabled at login: `systemctl --user disable vibeswitcher-node`") == atLogin, "\(atLogin): \(refused)")
        }
        final class Clock: @unchecked Sendable { var now: TimeInterval = 0 }
        let probes: [(NodeStarter.Probe, Bool)] = [(.notYet, true), (.unitEnded(result: "exit-code"), false)]
        for (probe, still) in probes {
            let manager = try Manager(scratch)
            try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path))
            let clock = Clock()
            let starter = NodeStarter(tools: manager.tools, listen: { probe }, now: { clock.now }, pause: { clock.now += $0 })
            guard case .failure(let refused) = starter.startUnit(Self.inputs, atLogin: true) else { Issue.record("\(probe) went on"); continue }
            #expect(refused.text.contains("`systemctl --user disable vibeswitcher-node`"), "\(probe): \(refused)")
            #expect(refused.text.contains("may still run: `systemctl --user stop vibeswitcher-node`") == still, "\(probe): \(refused)")
        }
    }

    /// ST-D4's "says when the unit is found enabled" reads every `.wants`, `.requires` and `.upholds` folder of the
    /// unit folder, a link that points nowhere included; and the start's outcome says it.
    @Test(NodeTraits.linuxOnly) func theEnabledLinksAreFoundInEveryWantsFolder() throws {
        let manager = try Manager(scratch)
        let folder = manager.unitFolder
        #expect(NodeStarter.enabledBy(unitFolder: folder.path) == [])
        for name in ["default.target.wants", "graphical-session.target.requires", "other.target.wants", "vibeswitcher-node.service.d", "x.target.upholds"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("default.target.wants/\(NodeUnit.fileName)").path,
                                                   withDestinationPath: "../\(NodeUnit.fileName)")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("graphical-session.target.requires/\(NodeUnit.fileName)").path,
                                                   withDestinationPath: "/nonexistent/\(NodeUnit.fileName)")
        try Data().write(to: folder.appendingPathComponent("x.target.upholds/\(NodeUnit.fileName)"))
        try Data().write(to: folder.appendingPathComponent("vibeswitcher-node.service.d/\(NodeUnit.fileName)"))
        try Data().write(to: folder.appendingPathComponent("other.target.wants/another.service"))
        #expect(NodeStarter.enabledBy(unitFolder: folder.path) == ["default.target.wants", "graphical-session.target.requires", "x.target.upholds"])
        try manager.answer(NodeUnit.expectedShow(Self.inputs, unitFile: manager.unitFile.path))
        #expect(try manager.starter().startUnit(Self.inputs, atLogin: false).get().enabledAtLogin)
    }

    /// `NodeStarter.run`, which every systemctl and journalctl of the command line goes through in place of
    /// Foundation's `waitUntilExit`: an exit's status and output come back; a program that outlives its timeout, or
    /// leaves a child holding its stdout, comes back nil within its bound, and its whole group is killed.
    @Test(NodeTraits.linuxOnly) func theBoundedRunKillsWhatOutlivesItsTimeout() throws {
        let folder = scratch.url("run")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let quick = folder.appendingPathComponent("quick")
        try ScratchNode.script("#!/bin/sh\nprintf 'said\\n'\nexit 3\n", at: quick)
        let ran = try #require(NodeStarter.run(quick.path, [], environment: ["PATH=/usr/bin:/bin"], timeout: 30))
        #expect(ran.status == 3 && ran.output == "said\n", "\(ran)")

        // In the foreground (the shell waits on its child), and left behind holding stdout after the shell exits. The
        // child sleeps far past the timeout: an answer before it would end by itself is the bound's.
        let sleeps: TimeInterval = 30
        for (name, body) in [("foreground", "sleep \(Int(sleeps)) &\necho $! > '\(folder.path)/foreground.pid'\nwait\n"),
                             ("background", "sleep \(Int(sleeps)) &\necho $! > '\(folder.path)/background.pid'\nexit 0\n")] {
            let program = folder.appendingPathComponent(name)
            try ScratchNode.script("#!/bin/sh\necho $$ > '\(folder.path)/\(name).shell'\n" + body, at: program)
            let began = Date()
            let answer = NodeStarter.run(program.path, [], environment: ["PATH=/usr/bin:/bin"], timeout: 1)
            let took = Date().timeIntervalSince(began)
            #expect(answer == nil, "\(name): \(String(describing: answer))")
            #expect(took < sleeps, "\(name): \(took) s")
            for file in ["\(name).pid", "\(name).shell"] {
                let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), "\(file): \(text)")
                #expect(Self.ended(pid), "\(name): \(file) \(pid) still runs")
            }
        }
    }

    /// Whether `pid` has ended (gone, or a zombie its new parent hasn't collected yet), waited for 10 s at most.
    private static func ended(_ pid: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while true {
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                  let close = stat.lastIndex(of: ")") else { return true }
            if stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("Z") { return true }
            guard Date() < deadline else { return false }
            usleep(20_000)
        }
    }

    /// A recording systemctl for the command line on a scratch root: every call appended to `<test>/calls`, the
    /// facts' `show-environment` and the status's unit state answered as `ScratchNode`'s stand-in answers them.
    private static func recordingSystemctl(in testFolder: URL) throws {
        try ScratchNode.script("""
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(testFolder.path)/calls'
            case "$*" in
              *show-environment*) printf 'HOME=/home/test\\nLANG=C.UTF-8\\nPATH=/usr/bin:/bin\\nUSER=test\\nXDG_RUNTIME_DIR=/run/user/1000\\n' ;;
              *ExecMainStartTimestamp*) printf 'Result=success\\nExecMainStatus=0\\nExecMainStartTimestamp=\\n' ;;
            esac
            exit 0

            """, at: testFolder.appendingPathComponent("systemctl"))
    }

    private static func calls(in testFolder: URL) -> [String] {
        ((try? String(contentsOf: testFolder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test(NodeTraits.linuxOnly) func aScratchNodeIsNotStartedByTheCommandLine() async throws {
        let root = try scratch.shortFolder("vss")
        let testFolder = root.appendingPathComponent("v2/test")
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
        try ScratchNode.standIns(in: testFolder, scopes: ScratchNode.ownScope.map { [$0] })
        try Self.recordingSystemctl(in: testFolder)
        let home = root.appendingPathComponent("home"), xdg = root.appendingPathComponent("xdg-config")
        let environment = scratchEnvironment(root, ["VIBESWITCHER_HOME": root.path, "HOME": home.path, "CFFIXED_USER_HOME": home.path,
                                                    "XDG_CONFIG_HOME": xdg.path, "XDG_RUNTIME_DIR": root.appendingPathComponent("xdg-runtime").path])
        let ran = try await run(commandLine, ["start", "--interop-is-on"], environment: environment)
        #expect(ran.status == 69, "\(ran.output)\(ran.errors)")
        #expect(ran.errors.contains("started by its harness"), "\(ran.errors)")
        // The facts' show-environment, and nothing else: no daemon-reload, enable, start or stop.
        #expect(Self.calls(in: testFolder) == ["--user show-environment"], "\(Self.calls(in: testFolder))")
        // No unit written, in the scratch home or where its XDG_CONFIG_HOME points.
        for folder in [home.appendingPathComponent(".config/systemd/user"), xdg.appendingPathComponent("systemd/user")] {
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(NodeUnit.fileName).path), "\(folder.path)")
        }
    }

    @Test(NodeTraits.linuxOnly) func aNodeAlreadyRunningIsNotStartedAgain() async throws {
        let node = try await ScratchNode(scratch)
        try Self.recordingSystemctl(in: node.testFolder)
        let ran = try await node.runOnTerminal(["start"])
        #expect(ran.status == 0, "\(ran.output)")
        #expect(ran.output.contains("the node runs"), "\(ran.output)")
        let calls = Self.calls(in: node.testFolder)
        #expect(!calls.contains { $0.contains("daemon-reload") || $0.contains("enable") || $0.contains(" start ") || $0.hasSuffix(" start")
            || $0.contains(" stop") }, "\(calls)")
        #expect(!FileManager.default.fileExists(atPath: node.home.appendingPathComponent(".config/systemd/user/\(NodeUnit.fileName)").path))
        // Its environment points XDG_* at scratch folders and drops the bus address (defence in depth, ST-D2).
        let environment = node.environment()
        #expect(environment["XDG_RUNTIME_DIR"]?.hasPrefix(node.root.path) == true && environment["XDG_CONFIG_HOME"]?.hasPrefix(node.root.path) == true)
        #expect(environment["DBUS_SESSION_BUS_ADDRESS"] == nil)
    }
}
