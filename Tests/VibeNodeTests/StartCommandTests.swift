import Foundation
import Testing
import VibeCore
import VibeHost
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

    /// Security follow-up 21: the manager config is read as systemd reads it, backslash continuations joined, so a
    /// `DefaultEnvironment=` can't hide behind one; and fail-closed, so one can't hide in a file `start` can't read
    /// whole (unreadable, not UTF-8, not a regular file, a drop-in that is a link). Each refuses, naming the file.
    @Test(NodeTraits.linuxOnly) func aManagerConfigStartCantReadAsSystemdDoesRefusesStart() throws {
        let home = scratch.url("confhome21")
        let systemd = home.appendingPathComponent(".config/systemd")
        let dropIns = systemd.appendingPathComponent("user.conf.d")
        try FileManager.default.createDirectory(at: dropIns, withIntermediateDirectories: true)
        let conf = systemd.appendingPathComponent("user.conf")
        func refusal() -> StartRefusal? { NodeFolders.managerConfigRefusal(accountHome: home.path) }
        func write(_ text: String, to url: URL? = nil) throws { try Data(text.utf8).write(to: url ?? conf) }
        // Each case checked on its own (no `#require`), so each one this misses is its own issue.
        func expectRefused(naming file: URL, saying words: String, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
            let refused = refusal()
            #expect(refused?.text.contains(file.path) == true && refused?.text.contains(words) == true,
                    "\(comment): \(String(describing: refused))", sourceLocation: sourceLocation)
        }

        // Each sets DefaultEnvironment= as systemd reads it.
        let hidden = [
            // The key's line continued: systemd reads `DefaultEnvironment =GIT_CONFIG_GLOBAL=…`.
            "[Manager]\nDefaultEnvironment\\\n=GIT_CONFIG_GLOBAL=/srv/evil.gitconfig\n",
            "[Manager]\nDefaultEnvironment\\\r\n=GIT_CONFIG_GLOBAL=/srv/evil.gitconfig\r\n",
            "[Manager]\nDefaultEnvironment=\\\nGIT_CONFIG_GLOBAL=/srv/evil.gitconfig\n",
            // Newer systemd skips a comment line inside a continuation.
            "[Manager]\nDefaultEnvironment\\\n# a comment\n=GIT_CONFIG_GLOBAL=/srv/evil.gitconfig\n",
            // A continuation still open at the end is read.
            "[Manager]\nDefaultEnvironment=GIT_CONFIG_GLOBAL=/srv/evil.gitconfig\\",
            // A NUL ends a line; a byte-order mark is dropped.
            "[Manager]\nLogLevel=info\u{0}DefaultEnvironment=GIT_CONFIG_GLOBAL=/srv/evil.gitconfig\n",
            "\u{FEFF}[Manager]\nLogLevel=info\n\u{FEFF}DefaultEnvironment=GIT_CONFIG_GLOBAL=/srv/evil.gitconfig\n",
        ]
        for text in hidden {
            try write(text)
            expectRefused(naming: conf, saying: "sets DefaultEnvironment=", "\(text.debugDescription)")
        }
        // None of these does: a continued empty value (a reset), an escaped backslash (no continuation), and a
        // continuation into another key's value (systemd reads `LogLevel=info  DefaultEnvironment=X`).
        for text in ["[Manager]\nDefaultEnvironment=\\\n", "[Manager]\nLogLevel=info\\\\\n", "[Manager]\nLogLevel=info \\\nDefaultEnvironment=X\n"] {
            try write(text)
            #expect(refusal() == nil, "\(text.debugDescription)")
        }
        try FileManager.default.removeItem(at: conf)
        #expect(refusal() == nil)

        // A user.conf that isn't UTF-8.
        try Data("[Manager]\nLogLevel=info\n".utf8 + [0xFF, 0xFE, 0x0A]).write(to: conf)
        expectRefused(naming: conf, saying: "isn't UTF-8", "notUTF8")
        // One that can't be read (as root, mode 000 still reads).
        try write("[Manager]\nLogLevel=info\n")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: conf.path)
        if geteuid() != 0 {
            expectRefused(naming: conf, saying: "can't be opened", "unreadable")
        }
        try FileManager.default.removeItem(at: conf)
        // A folder named user.conf.
        try FileManager.default.createDirectory(at: conf, withIntermediateDirectories: false)
        expectRefused(naming: conf, saying: "isn't a regular file", "folderConf")
        try FileManager.default.removeItem(at: conf)
        #expect(refusal() == nil)

        // A folder named x.conf in user.conf.d.
        let folderDropIn = dropIns.appendingPathComponent("x.conf")
        try FileManager.default.createDirectory(at: folderDropIn, withIntermediateDirectories: false)
        expectRefused(naming: folderDropIn, saying: "isn't a regular file", "refusedFolder")
        try FileManager.default.removeItem(at: folderDropIn)
        // A drop-in that is a link, even to a harmless file.
        let target = scratch.url("harmless.conf")
        try write("[Manager]\nLogLevel=info\n", to: target)
        let link = dropIns.appendingPathComponent("20-link.conf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        expectRefused(naming: link, saying: "is a link", "refusedLink")
        try FileManager.default.removeItem(at: link)
        // An unreadable drop-in and one that isn't UTF-8.
        let dropIn = dropIns.appendingPathComponent("30-x.conf")
        try Data([0xC3, 0x28]).write(to: dropIn)
        expectRefused(naming: dropIn, saying: "isn't UTF-8", "dropInNotUTF8")
        try write("[Manager]\nLogLevel=info\n", to: dropIn)
        #expect(refusal() == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dropIn.path)
        if geteuid() != 0 {
            expectRefused(naming: dropIn, saying: "can't be opened", "dropInUnreadable")
        }
        try FileManager.default.removeItem(at: dropIn)
        // A continuation-hidden key in a drop-in.
        try write("[Manager]\nManagerEnvironment\\\n  =XDG_CONFIG_HOME=/srv/x\n", to: dropIn)
        expectRefused(naming: dropIn, saying: "ManagerEnvironment=", "a continued key in a drop-in")
        try FileManager.default.removeItem(at: dropIn)
        #expect(refusal() == nil)
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
    static func makeFolder(_ url: URL, below base: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var folder = url.standardizedFileURL
        while folder.path.count > base.standardizedFileURL.path.count {
            chmod(folder.path, 0o755)
            folder.deleteLastPathComponent()
        }
    }

    /// An executable file at `url` holding `text`.
    static func makeProgram(_ url: URL, _ text: String = "#!/bin/sh\nexit 0\n") throws {
        try writeClosedOnExec(text, to: url)
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
    static func makeBuild(prefix: URL, commit: String, folderName: String? = nil) throws -> URL {
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
    /// The detached start's answer (S3), once its `beforeStart` ran.
    var detached: Result<NodeStarter.Started, StartRefusal>?

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
            },
            detached: { inputs, beforeStart in
                self.note("detached:" + inputs.commit)
                self.lock.withLock { self._started.append((inputs, false)) }
                if let refused = beforeStart() { return .failure(refused) }
                self.note("host:start")
                return self.detached ?? .success(NodeStarter.Started(commit: inputs.commit, enabledAtLogin: false))
            })
    }

    func run(_ arguments: StartArguments = StartArguments()) -> Result<StartSequence.Outcome, StartRefusal> {
        StartSequence(steps: steps).run(arguments)
    }

    /// Whether any step after the checks wrote, called or recorded anything.
    var touchedNothing: Bool { !log.contains { $0.hasPrefix("starter:") || $0.hasPrefix("detached:") || $0.hasPrefix("journal:") } && entries.isEmpty }
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

    /// The step 8 sweep: a start that finds the node running applies neither `--at-login` nor `--node-version` (only a
    /// start of the node does), so it says so and exits 1 rather than 0, and changes nothing; on a machine without
    /// systemd it says nothing starts the node at login.
    @Test func aRunningNodeRefusesTheFlagsOnlyAStartApplies() throws {
        for (arguments, kind, says) in [
            (StartArguments(atLogin: true), StartSequence.Kind.node(.systemd), ["--at-login wasn't applied", "`vibeswitcher stop`, then start again with it"]),
            (StartArguments(nodeVersion: "v22.16.0"), .node(.systemd), ["--node-version v22.16.0 wasn't applied", "vibeswitcher stop"]),
            (StartArguments(atLogin: true, nodeVersion: "v22.16.0"), .node(.systemd), ["--at-login and --node-version v22.16.0 weren't applied"]),
            (StartArguments(atLogin: true), .node(.noSystemd), ["without systemd nothing starts the node when you log in", "--at-login wasn't applied"]),
        ] {
            let world = StartWorld()
            world.kind = kind
            world.server = .running
            world.acknowledged = .success(true)
            guard case .failure(let refused) = world.run(arguments) else { Issue.record("\(arguments) on a running node exited 0"); continue }
            #expect(refused.exitCode == 1, "\(refused)")
            for text in says { #expect(refused.text.contains(text), "\(arguments): \(refused.text)") }
            // Never the raw enable, which skips start --at-login's checks of the unit (the step 8 sweep's review).
            #expect(!refused.text.contains("systemctl"), "\(arguments): \(refused.text)")
            #expect(world.touchedNothing && !world.log.contains { $0.hasPrefix("starter:") || $0 == "toolFolders" }, "\(world.log)")
        }
        // A plain start still says the node runs, exit 0.
        let plain = StartWorld()
        plain.server = .running
        plain.acknowledged = .success(true)
        #expect(try plain.run(StartArguments(interopIsOn: true)).get() == .running)
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
        // No systemd: no manager is asked (S3's detached start, `aMachineWithoutSystemdStartsTheNodeDetached`).
        let none = StartWorld()
        none.kind = .node(.noSystemd)
        none.managerEnvironment = .failure(.init("no manager"))
        #expect((try? none.run().get()) == .started(commit: StartWorld.installed), "\(none.log)")
        #expect(!none.log.contains("managerEnvironment") && !none.log.contains("managerConfig"), "\(none.log)")
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

// MARK: - The detached start, the record and `stop` without a server (the start plan's S3)

/// A scratch session host to start detached (S3): a short root whose `home/.vibeswitcher` is a link to it (the host's
/// HOME, the only variable it gets besides PATH, finds its root so), `build/` holding links to the built products and
/// their `build-info` (`ScratchNode.install`), and the host's command line: `ScratchNode`'s arguments (`--socket`, spelled
/// through `<home>/.vibeswitcher` as the server finds its root's host socket,
/// `--lock <root>/scratch-host.lock`, `--node-root`, `--server`, `--exit-with` this process, so it ends with the test
/// process however that goes), no `--node`, then `extra`.
struct DetachedScratch {
    let root: URL
    let home: URL
    let command: [String]
    static let path = "/usr/bin:/bin"

    init(_ scratch: Scratch, extra: [String] = []) throws {
        root = try scratch.shortFolder("vsdt")
        home = root.appendingPathComponent("home", isDirectory: true)
        let nodeRoot = root.appendingPathComponent("build", isDirectory: true)
        for folder in [home, nodeRoot.appendingPathComponent("bin")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".vibeswitcher").path, withDestinationPath: root.path)
        try ScratchNode.install(into: nodeRoot)
        let socket = home.appendingPathComponent(".vibeswitcher/host.sock").path, lock = root.appendingPathComponent(NodeCheck.scratchLock).path
        command = [nodeRoot.appendingPathComponent("bin/vibeswitcher-host").path, "--socket", socket, "--lock", lock, "--idle-exit", "600",
                   "--server", nodeRoot.appendingPathComponent("bin/vibeswitcher-server").path, "--node-root", nodeRoot.path,
                   "--exit-with", String(getpid())] + extra
    }

    func start(settle: TimeInterval = NodeStarter.detachedSettle) -> Result<NodeRecord, StartRefusal> {
        NodeStarter.startDetached(host: command, home: home.path, path: Self.path, root: root.path, lock: lock, isHost: { $0 == command }, settle: settle)
    }

    /// The lock its host holds (`--lock`), which its record is checked against.
    var lock: String { root.appendingPathComponent(NodeCheck.scratchLock).path }

    var log: URL { root.appendingPathComponent("v2/host.log") }

    /// Its server: the host's child named so (started from a sealed copy, known by its argv[0]).
    static func server(of host: pid_t) -> pid_t? {
        Platform.Processes.children(host).first { Platform.Processes.arguments($0).first == "vibeswitcher-server" }
    }

    /// Ends the host `pid` (this process's child, not yet collected) and what is under it, whatever a case left.
    static func end(_ pid: pid_t) {
        let under = ScratchNode.descendants(of: pid)
        kill(pid, SIGKILL)
        _ = collected(pid, by: MacTime.real.awake() + 10)
        ScratchNode.waitForEnd(under)
    }
}

/// What a `StopSequence` stand-in saw, in order: each step's name as it ran (`typed:` with what it showed, `journal:`
/// with the entry's event, `fallback:` and `stopper:` with the mode, `throughServer`), the entries' fields and what
/// was said.
final class StopWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _entries: [[(name: String, value: String)]] = []
    private var _said: [String] = []

    var kind = StartSequence.Kind.node(.systemd)
    var installedBuild: Result<(commit: String, folder: String), StartRefusal> = .success((commit: StartWorld.installed, folder: StartWorld.prefix + "/" + StartWorld.installed))
    var server = StopSequence.ServerAnswer.notRunning("the node isn't running: no server answers at /x/v2/server.sock")
    var typed = TypedOutcome.typed
    var journalWrites = true
    var fallback: Result<String, StartRefusal> = .success(NodeTexts.stopUnit)
    var stopper: Result<Void, StartRefusal> = .success(())
    var throughServer: Result<Void, StartRefusal> = .success(())

    var log: [String] { lock.withLock { _log } }
    var entries: [[(name: String, value: String)]] { lock.withLock { _entries } }
    var said: String { lock.withLock { _said.joined(separator: "\n") } }
    private func note(_ step: String) { lock.withLock { _log.append(step) } }

    var steps: StopSequence.Steps {
        StopSequence.Steps(
            kind: { self.note("kind"); return self.kind },
            installedBuild: { self.note("installedBuild"); return self.installedBuild },
            server: { self.note("server"); return self.server },
            typed: { _, what in self.note("typed:" + what); return self.typed },
            say: { line in self.lock.withLock { self._said.append(line) } },
            journal: { fields in
                self.note("journal:" + (fields.first { $0.name == "VIBESWITCHER_EVENT" }?.value ?? "?"))
                guard self.journalWrites else { return false }
                self.lock.withLock { self._entries.append(fields) }
                return true
            },
            throughServer: { _ in self.note("throughServer"); return self.throughServer },
            fallback: { mode in self.note("fallback:\(mode)"); return self.fallback },
            stopper: { mode in self.note("stopper:\(mode)"); return self.stopper })
    }

    func run() -> Result<StopSequence.Outcome, StartRefusal> { StopSequence(steps: steps).run() }

    /// Whether anything was written, called or recorded.
    var touchedNothing: Bool { !log.contains { $0.hasPrefix("journal:") || $0.hasPrefix("stopper:") || $0 == "throughServer" } && entries.isEmpty }
}

extension StartCommandTests {
    // MARK: The detached start and its record (Linux: a scratch host started detached)

    @Test(NodeTraits.linuxOnly) func aNodeWithoutSystemdRunsInASessionOfItsOwnAndStopEndsIt() async throws {
        // A machine whose runtime folder is empty and whose pid 1 isn't systemd, by the mode's stand-ins: detached.
        let machine = scratch.url("machine")
        try FileManager.default.createDirectory(at: machine.appendingPathComponent("run-user"), withIntermediateDirectories: true)
        try "init\n".write(to: machine.appendingPathComponent("comm"), atomically: true, encoding: .utf8)
        #expect(NodeFolders.mode(runtimeFolder: machine.appendingPathComponent("run-user").path, systemdSystem: machine.appendingPathComponent("no-systemd").path,
                                 initComm: machine.appendingPathComponent("comm").path) == .noSystemd)

        let host = try DetachedScratch(scratch)
        let record = try host.start().get()
        let pid = record.pid
        var ended = false
        defer { if !ended { DetachedScratch.end(pid) } }
        // A session of its own, with no controlling terminal (tty_nr 0); this process, the spawner, its parent (the
        // command line exits after its wait, and the host is init's).
        #expect(getsid(pid) == pid)
        let link = try #require(Platform.Processes.link(pid))
        #expect(link.terminal == nil && link.parent == getpid(), "\(link)")
        // The record: its pid and start, 0600.
        #expect(record == NodeRecord(pid: pid, startTicks: link.startTicks))
        #expect(NodeRecord.read(root: host.root.path) == record)
        var info = stat()
        #expect(lstat(NodeRecord.path(root: host.root.path), &info) == 0 && info.st_mode & 0o777 == 0o600 && info.st_mode & S_IFMT == S_IFREG)
        #expect(lstat(host.log.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        // The host runs: its server, its child, listens.
        let up = await eventually(timeout: 120) {
            DetachedScratch.server(of: pid) != nil && FileManager.default.fileExists(atPath: host.root.appendingPathComponent("v2/server.sock").path)
        }
        try #require(up, "the detached host's server never came: \((try? String(contentsOf: host.log, encoding: .utf8)) ?? "")")
        let server = try #require(DetachedScratch.server(of: pid))
        #expect(getsid(server) == pid, "the server is in the host's session")
        // Its output (and its server's) is in host.log.
        let said = (try? String(contentsOf: host.log, encoding: .utf8)) ?? ""
        #expect(said.contains("vibeswitcher-host: started") && said.contains("server child pid \(server)"), "\(said)")
        // A second start while the recorded host runs: refused, nothing started.
        guard case .failure(let again) = host.start() else { Issue.record("a second host was started over a live record"); return }
        #expect(again.text.contains("still runs"), "\(again)")
        #expect(NodeRecord.read(root: host.root.path) == record)

        // stop without the server ends it, collects it (this process is its parent), and what was under it.
        let under = ScratchNode.descendants(of: pid)
        #expect(under.contains { $0.pid == server }, "\(under)")
        // The record stop showed for its code is the one it ends: one that changed since ends nothing (the step 8 sweep).
        guard case .failure(let moved) = NodeStopper.stopDetached(root: host.root.path, lock: host.lock, isHost: { $0 == host.command },
                                                                  shown: NodeRecord(pid: record.pid, startTicks: record.startTicks + 1)) else {
            Issue.record("a stop ended a record other than the one it showed"); return
        }
        #expect(moved.text.contains("changed since the stop was shown") && moved.text.contains("nothing ended"), "\(moved)")
        #expect(record.isLive())
        let stopStarted = Date()
        let stopped = NodeStopper.stopDetached(root: host.root.path, lock: host.lock, isHost: { $0 == host.command }, shown: record)
        let stopTook = Int(Date().timeIntervalSince(stopStarted))
        #expect((try? stopped.get()) != nil, "\(stopped)")
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        ended = reaped == -1
        #expect(reaped == -1 && errno == ECHILD, "the host is still this process's child, or a zombie (waitpid \(reaped), state \(String(describing: Platform.Processes.kernelRecord(pid)?.state)))")
        let stillRunning = under.filter(ScratchNode.runs)
        let seen = stillRunning.map { link in
            "\(link.pid): \((try? String(contentsOfFile: "/proc/\(link.pid)/stat", encoding: .utf8))?.prefix(160) ?? "no stat") "
                + "threads \((try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(link.pid)/task"))?.count ?? -1)"
        }
        #expect(stillRunning.isEmpty, "\(stillRunning) \(seen) stop took \(stopTook) s")
        #expect(NodeRecord.read(root: host.root.path) == nil)
    }

    /// The step 8 sweep's review: the record's check knows the host by the lock it holds, and a real host takes that
    /// lock only after its startup checks, which can outlast the settle. A second start while the first waits for the
    /// server (its `listening`) is refused by the start's lock, which the first holds until that wait ends, so the record
    /// isn't replaced and no second host is spawned while the first hasn't taken its lock yet.
    @Test(NodeTraits.linuxOnly) func aStartWhileTheFirstWaitsForItsServerIsRefused() async throws {
        let host = try DetachedScratch(scratch)
        var second: Result<NodeRecord, StartRefusal>?
        var lockedAtSecond: pid_t?
        let first = NodeStarter.startDetached(host: host.command, home: host.home.path, path: DetachedScratch.path, root: host.root.path,
                                              lock: host.lock, isHost: { $0 == host.command }, settle: 0.01, listening: { _ in
                                                  lockedAtSecond = Platform.Processes.exclusiveFlockHolder(path: host.lock)
                                                  second = host.start(settle: 0.01)
                                                  return nil
                                              })
        let record = try first.get()
        defer { DetachedScratch.end(record.pid) }
        if case .success(let other)? = second, other.pid != record.pid { DetachedScratch.end(other.pid) }
        guard case .failure(let refused)? = second else {
            Issue.record("a second start went on while the first waited for its server (the host's lock held by \(String(describing: lockedAtSecond)))"); return
        }
        #expect(refused.text.contains("another start of the node is under way"), "\(refused)")
        #expect(NodeRecord.read(root: host.root.path) == record)
    }

    @Test(NodeTraits.linuxOnly) func theDetachedHostGetsOnlyTheListedEnvironment() async throws {
        // Held dumpable (a scratch host's test flag), so its environment can be read from here. The test process's own
        // variables (the run's VIBESWITCHER_HOME, TMPDIR, CFFIXED_USER_HOME…) stand for what a shell would pass:
        // LD_PRELOAD or GIT_CONFIG_GLOBAL set here would reach every child the suite's other cases start meanwhile.
        let host = try DetachedScratch(scratch, extra: ["--test-stays-dumpable"])
        let record = try host.start().get()
        defer { DetachedScratch.end(record.pid) }
        try #require(await eventually(timeout: 120) { Platform.Processes.isDumpable(record.pid) == true })
        let environment = try #require(Platform.Processes.environment(record.pid))
        let log = NodeStarter.hostLog(root: host.root.path)
        #expect(environment == ["HOME=\(host.home.path)", "PATH=\(DetachedScratch.path)", "SWIFT_BACKTRACE=enable=no",
                                "\(StderrCap.logVariable)=\(log)"], "\(environment)")
        #expect(environment == NodeStarter.detachedEnvironment(home: host.home.path, path: DetachedScratch.path, log: log))
        #expect(ProcessInfo.processInfo.environment.count > 3)
        // A dumpable process isn't the node's host: stop refuses it, and it still runs.
        guard case .failure(let refused) = NodeStopper.stopDetached(root: host.root.path, lock: host.lock, isHost: { $0 == host.command }) else {
            Issue.record("a dumpable recorded process was ended"); return
        }
        #expect(refused.text.contains("is dumpable") && refused.text.contains("nothing ended"), "\(refused)")
        #expect(record.isLive())
    }

    /// The step 8 sweep: a detached host inherits the command line's umask, so one that lets other users write
    /// (`umask 000`, seen on WSL) is refused before anything, as the unit's start refuses such a `UMask`: no folder,
    /// log, lock or record made, nothing started. The umask is read from `/proc/self/status` without changing it.
    @Test(NodeTraits.linuxOnly) func aDetachedStartRefusesAUmaskThatLetsOthersWrite() throws {
        let root = try scratch.shortFolder("vsum")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("started").path
        for mask: mode_t? in [0o000, 0o020, 0o055, nil] {
            guard case .failure(let refused) = NodeStarter.startDetached(host: ["/bin/sh", "-c", "touch \(marker)"], home: home.path,
                                                                         path: DetachedScratch.path, root: root.path,
                                                                         lock: NodeFolders.hostLock(root: root.path), isHost: { _ in false },
                                                                         settle: hangGuard, umask: mask) else {
                Issue.record("umask \(String(describing: mask)) was taken"); continue
            }
            #expect(refused.exitCode == 1 && refused.text.contains("umask"), "\(refused)")
            if mask != nil { #expect(refused.text.contains("writable by other users") && refused.text.contains("umask 022"), "\(refused)") }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("v2").path), "nothing made")
        #expect(!FileManager.default.fileExists(atPath: marker), "nothing started")
        #expect(NodeStarter.umaskRefusal(0o022) == nil && NodeStarter.umaskRefusal(0o077) == nil && NodeStarter.umaskRefusal(0o002) == nil)
        // Read as the kernel says it, never set.
        let status = root.appendingPathComponent("status").path
        try "Name:\tx\nUmask:\t0027\nState:\tR (running)\n".write(toFile: status, atomically: true, encoding: .utf8)
        #expect(NodeStarter.processUmask(status: status) == 0o027)
        #expect(NodeStarter.processUmask() != nil)
    }

    /// The app's `HostClientReapTests.endingAHostByAStalePidLeavesTheProcessNowUnderItAlone` (port-map row 98): a
    /// record whose pid now names another process, by its start or by its command line, ends nothing; that process
    /// stays its own parent's to signal and collect.
    /// The step 8 sweep: a worker's process that gives itself the installed host's command line (`exec -a`) and makes
    /// itself non-dumpable (`PR_SET_DUMPABLE 0`), named in a record the worker wrote with its own start ticks, passes
    /// the tick, the command line and dumpability, but doesn't hold the host's lock: it isn't taken for the host. The
    /// server check refuses it, stop ends nothing and leaves it running, and a start isn't refused for it. Here the
    /// process is this test binary as `VibeHostTests`' hardened helper (`VIBE_HARDENED_TEST_HELPER`), and the host's
    /// lock is held by this test, as the real host holds it.
    @Test(NodeTraits.linuxOnly) func aRecordedProcessThatFakesTheHostIsNeitherTrustedNorSignalled() async throws {
        let root = try scratch.shortFolder("vsfk")
        let prefix = root.appendingPathComponent("builds").path
        let folder = prefix + "/" + String(repeating: "ab", count: 20)
        let forged = NodeUnit.execStart(prefix: prefix, commit: String(repeating: "ab", count: 20))
        #expect(forged[2] == "--node-root" && forged[3] == folder)
        let binary = try #require(Bundle.main.executablePath)
        var output: [Int32] = [-1, -1], input: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&output) == 0 && Sys.pipeClosedOnExec(&input) == 0)
        var spawn = Platform.Spawn(executable: binary, arguments: forged)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["VIBE_HARDENED_TEST_HELPER=1"]
        spawn.stdin = .descriptor(input[0])
        spawn.stdout = .descriptor(output[1])
        spawn.keep = []
        let started = spawn.start()
        Sys.close(input[0])
        Sys.close(output[1])
        defer { Sys.close(output[0]) }
        guard case .success(let pid) = started else { Sys.close(input[1]); throw CancellationError() }
        var ended = false
        defer {
            Sys.close(input[1])
            if !ended { kill(pid, SIGKILL); _ = collected(pid, by: MacTime.real.awake() + 10) }
        }
        var said: [UInt8] = []
        var byte: UInt8 = 0
        while said.last != UInt8(ascii: "\n") {
            let count = read(output[0], &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { break }
            said.append(byte)
        }
        try #require(String(decoding: said, as: UTF8.self) == "hardened true\n", "\(String(decoding: said, as: UTF8.self))")
        // What a reader sees: the installed host's command line, non-dumpable, at its own start.
        #expect(Platform.Processes.arguments(pid) == forged)
        #expect(NodeCheck.isInstalledHost(Platform.Processes.arguments(pid), prefix: prefix))
        #expect(Platform.Processes.isDumpable(pid) == false)
        let ticks = try #require(Platform.Processes.link(pid)?.startTicks)
        try NodeRecord(pid: pid, startTicks: ticks).write(root: root.path)
        // The host's lock, held as the real host holds it (here by this process).
        let lock = NodeFolders.hostLock(root: root.path)
        let fd = open(lock, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let isHost: ([String]) -> Bool = { NodeCheck.isInstalledHost($0, prefix: prefix) }
        func stillRuns() -> Bool {
            var status: Int32 = 0
            return waitpid(pid, &status, WNOHANG) == 0 && Platform.Processes.kernelRecord(pid)?.state != .zombie
        }

        guard case .other(let why) = NodeCheck.recordedHost(NodeRecord.read(root: root.path), isHost: isHost, lock: lock) else {
            Issue.record("a process faking the host's command line and dumpability was taken for the host"); return
        }
        #expect(why.contains("doesn't hold the host's lock"), "\(why)")
        guard case .failure(let shown) = NodeStopper.detachedHost(root: root.path, lock: lock, isHost: isHost) else {
            Issue.record("stop showed the fake as the node's host"); return
        }
        #expect(shown.text.contains("nothing ended"), "\(shown)")
        guard case .failure(let stopped) = NodeStopper.stopDetached(root: root.path, lock: lock, isHost: isHost) else {
            Issue.record("stop ended the fake"); return
        }
        #expect(stopped.text.contains("doesn't hold the host's lock") && stopped.text.contains("nothing ended"), "\(stopped)")
        #expect(stillRuns(), "the fake was signalled")
        // A start isn't kept from running by it: it starts its own over the record (a host that ends at once here).
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        guard case .failure(let replaced) = NodeStarter.startDetached(host: ["/bin/sh", "-c", "exit 3"], home: home.path, path: DetachedScratch.path,
                                                                      root: root.path, lock: lock, isHost: isHost, settle: hangGuard) else {
            Issue.record("a host that ended at once was taken"); return
        }
        #expect(replaced.text.contains("the host ended at once") && !replaced.text.contains("still runs"), "\(replaced)")
        #expect(stillRuns())
        // The helper ends at its stdin's end; collected here.
        Sys.close(input[1])
        input[1] = -1
        #expect(collected(pid, by: MacTime.real.awake() + 30) != nil)
        ended = true
    }

    @Test(NodeTraits.linuxOnly) func stoppingByAStalePidLeavesTheProcessNowUnderItAlone() async throws {
        let root = try scratch.shortFolder("vsrp")
        var spawn = Platform.Spawn(executable: "/bin/sleep", arguments: ["/bin/sleep", "600"])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.keep = []
        let pid = try await startRetrying(spawn)
        var collectedHere = false
        defer { if !collectedHere { kill(pid, SIGKILL); _ = collected(pid, by: MacTime.real.awake() + 10) } }
        let ticks = try #require(Platform.Processes.link(pid)?.startTicks)
        func stillRuns() -> Bool {
            var status: Int32 = 0
            return waitpid(pid, &status, WNOHANG) == 0 && Platform.Processes.kernelRecord(pid)?.state != .zombie
        }

        // The pid given to another process since the record was written: its start isn't the record's.
        try NodeRecord(pid: pid, startTicks: ticks + 1).write(root: root.path)
        guard case .failure(let stale) = NodeStopper.stopDetached(root: root.path, lock: NodeFolders.hostLock(root: root.path), isHost: { _ in true }) else {
            Issue.record("a stale record's pid was ended"); return
        }
        #expect(stale.text.contains("now names another process") && stale.text.contains("nothing ended"), "\(stale)")
        #expect(stillRuns())
        // Its start matching, but the command line isn't the installed host's.
        try NodeRecord(pid: pid, startTicks: ticks).write(root: root.path)
        let prefix = StartWorld.prefix
        guard case .failure(let other) = NodeStopper.stopDetached(root: root.path, lock: NodeFolders.hostLock(root: root.path), isHost: { NodeCheck.isInstalledHost($0, prefix: prefix) }) else {
            Issue.record("a recorded process of another command line was ended"); return
        }
        #expect(other.text.contains("now names another process") && other.text.contains("/bin/sleep 600") && other.text.contains("nothing ended"), "\(other)")
        // It names the file whose removal clears the record (the review of S3: neither stop nor start gets past it).
        #expect(other.text.contains("remove \(NodeRecord.path(root: root.path))"), "\(other)")
        #expect(stillRuns())
        // A start doesn't take that record for a host that still runs: it starts its own over it (here a host that
        // ends at once, refused for that), and the process the record named is left alone.
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        guard case .failure(let replaced) = NodeStarter.startDetached(host: ["/bin/sh", "-c", "exit 3"], home: home.path, path: DetachedScratch.path,
                                                                      root: root.path, lock: NodeFolders.hostLock(root: root.path),
                                                                      isHost: { NodeCheck.isInstalledHost($0, prefix: prefix) },
                                                                      settle: hangGuard) else {
            Issue.record("a host that ended at once was taken"); return
        }
        #expect(replaced.text.contains("the host ended at once") && !replaced.text.contains("still runs"), "\(replaced)")
        #expect(stillRuns())
        // Still this test's to end and collect: nobody signalled or collected it.
        kill(pid, SIGTERM)
        let status = try #require(collected(pid, by: MacTime.real.awake() + 30))
        collectedHere = true
        #expect(status & 0x7f == SIGTERM, "\(status)")

        // The installed host's form, word by word.
        let host = NodeUnit.execStart(prefix: prefix, commit: Self.commit)
        #expect(NodeCheck.isInstalledHost(host, prefix: prefix))
        #expect(NodeCheck.isInstalledHost(host, prefix: prefix + "/"))
        // After a handover (S8): the new image's argv is the host's own words without its folders (`--node`), then the
        // handover's flags, then the new build's folders and the old one's for its fallback (`HandoverMemory`'s
        // `folderArguments`); a fallback's is the old build's image with its own folders back (`fallbackArguments`).
        // `--node-root` names the same build as argv[0], wherever it comes (the review of S3).
        let old = "\(prefix)/\(Self.other)", new = "\(prefix)/\(Self.commit)"
        let handedOver = ["\(new)/bin/vibeswitcher-host", "--node", "--handover", "/proc/self/fd/9", "--handover-fallback", "/proc/self/fd/7",
                          HandoverMemory.fallbackImageFlag, "\(old)/bin/vibeswitcher-host", "--node-root", new, "--server", "\(new)/bin/vibeswitcher-server",
                          HandoverMemory.fallbackNodeRootFlag, old, HandoverMemory.fallbackServerFlag, "\(old)/bin/vibeswitcher-server"]
        let wentBack = ["\(old)/bin/vibeswitcher-host", "--node", "--image-path", "\(old)/bin/vibeswitcher-host"]
            + HandoverMemory.fallbackArguments(started: handedOver)
        #expect(NodeCheck.isInstalledHost(handedOver, prefix: prefix), "\(handedOver)")
        #expect(NodeCheck.isInstalledHost(wentBack, prefix: prefix), "\(wentBack)")
        for bad in [["/bin/sleep", "600"], Array(host.prefix(3)),
                    // Its --node-root another build's, or two of them, or only the fallback's.
                    handedOver.map { $0 == new ? old : $0 },
                    handedOver + ["--node-root", old],
                    ["\(new)/bin/vibeswitcher-host", "--node", HandoverMemory.fallbackNodeRootFlag, new],
                    ["\(new)/bin/vibeswitcher-host", "--node", "--server", "--node-root"],
                    ["\(prefix)/current/bin/vibeswitcher-host", "--node", "--node-root", "\(prefix)/current"],
                    ["\(prefix)/\(Self.commit)/bin/vibeswitcher-host", "--node", "--node-root", "\(prefix)/\(Self.other)"],
                    ["\(prefix)/\(Self.commit)/bin/vibeswitcher-host", "--node-root", "\(prefix)/\(Self.commit)", "--node"],
                    ["/srv/x/\(Self.commit)/bin/vibeswitcher-host", "--node", "--node-root", "/srv/x/\(Self.commit)"]] {
            #expect(!NodeCheck.isInstalledHost(bad, prefix: prefix), "\(bad)")
        }
    }

    /// The app's `HostClientReapTests.aHostWhoseExitEventComesBeforeItCanBeReapedIsStillReaped` (port-map row 98): a
    /// host that ends at once is collected by the start's bounded wait, so no zombie of it is left, and the start is
    /// refused naming its log, which holds what it wrote.
    @Test(NodeTraits.linuxOnly) func aHostThatExitsBeforeItIsWaitedForLeavesNoZombie() throws {
        let root = try scratch.shortFolder("vszb")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // A settle as long as the hang guard: the host's exit, not a time, ends the wait.
        let started = NodeStarter.startDetached(host: ["/bin/sh", "-c", "echo said-out; echo said-err >&2; exit 3"], home: home.path,
                                                path: DetachedScratch.path, root: root.path, lock: NodeFolders.hostLock(root: root.path),
                                                isHost: { _ in false }, settle: hangGuard)
        guard case .failure(let refused) = started else { Issue.record("a host that ended at once was taken: \(started)"); return }
        let log = root.appendingPathComponent("v2/host.log").path
        #expect(refused.text.contains("the host ended at once") && refused.text.contains("exit status 3") && refused.text.contains("see \(log)"), "\(refused)")
        let match = try #require(refused.text.firstMatch(of: try Regex("pid ([0-9]+)")), "\(refused)")
        let pid = try #require(match.output[1].substring.flatMap { pid_t(String($0)) })
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) != pid, "the host was left a zombie child")
        #expect(NodeRecord.read(root: root.path) == nil)
        let said = try String(contentsOfFile: log, encoding: .utf8)
        #expect(said.contains("said-out") && said.contains("said-err"), "\(said)")
        // A command that isn't absolute is refused before anything starts.
        guard case .failure(let relative) = NodeStarter.startDetached(host: ["sh"], home: home.path, path: DetachedScratch.path, root: root.path,
                                                                      lock: NodeFolders.hostLock(root: root.path), isHost: { _ in false }) else {
            Issue.record("a relative host command was started"); return
        }
        #expect(relative.text.contains("absolute"), "\(relative)")
    }

    @Test(NodeTraits.linuxOnly) func aRecordIsReadOnlyFromARegularFileOfItsOwnFormat() throws {
        let root = try scratch.shortFolder("vsrr")
        let record = NodeRecord(pid: 4242, startTicks: 99)
        try record.write(root: root.path)
        #expect(NodeRecord.read(root: root.path) == record)
        let text = try String(contentsOfFile: NodeRecord.path(root: root.path), encoding: .utf8)
        #expect(text == "{\"format\":1,\"pid\":4242,\"startTicks\":99}\n", "\(text)")
        // A link in its place isn't followed, and is replaced by the next write, not written through.
        let elsewhere = root.appendingPathComponent("elsewhere")
        try text.write(to: elsewhere, atomically: true, encoding: .utf8)
        unlink(NodeRecord.path(root: root.path))
        try FileManager.default.createSymbolicLink(atPath: NodeRecord.path(root: root.path), withDestinationPath: elsewhere.path)
        #expect(NodeRecord.read(root: root.path) == nil)
        try NodeRecord(pid: 7, startTicks: 8).write(root: root.path)
        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == text)
        #expect(NodeRecord.read(root: root.path) == NodeRecord(pid: 7, startTicks: 8))
        // Another format, or no pid: none.
        for bad in ["{\"format\":2,\"pid\":7,\"startTicks\":8}", "{\"format\":1,\"pid\":0,\"startTicks\":8}", "7"] {
            try bad.write(toFile: NodeRecord.path(root: root.path), atomically: false, encoding: .utf8)
            #expect(NodeRecord.read(root: root.path) == nil, "\(bad)")
        }
        // Removed only while it is still the one given.
        try record.write(root: root.path)
        NodeRecord.remove(root: root.path, ifStill: NodeRecord(pid: 1, startTicks: 1))
        #expect(NodeRecord.read(root: root.path) == record)
        NodeRecord.remove(root: root.path, ifStill: record)
        #expect(NodeRecord.read(root: root.path) == nil)
    }

    /// The review of S3: two detached starts at once would both pass the record's check, and the second's record would
    /// replace the first's, leaving a host no command reaches. A start holds `<root>/v2/node.pid.lock` from that check
    /// through its settle: another start meanwhile is refused before anything, and the record is left as it was.
    @Test(NodeTraits.linuxOnly) func twoDetachedStartsAtOnceStartOneHost() throws {
        let root = try scratch.shortFolder("vsdl")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v2"), withIntermediateDirectories: true)
        let record = NodeRecord(pid: 4242, startTicks: 99)
        try record.write(root: root.path)
        // The first start, as this test: the lock held (another open file, as another process's would be).
        let lock = NodeStarter.detachedLock(root: root.path)
        #expect(lock == root.appendingPathComponent("v2/node.pid.lock").path)
        let fd = open(lock, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let marker = root.appendingPathComponent("started").path
        let host = ["/bin/sh", "-c", "touch '\(marker)'; exit 3"]
        guard case .failure(let refused) = NodeStarter.startDetached(host: host, home: home.path, path: DetachedScratch.path, root: root.path,
                                                                     lock: NodeFolders.hostLock(root: root.path), isHost: { _ in false }, settle: hangGuard) else {
            Issue.record("a second start went on while the first held the lock"); return
        }
        #expect(refused.text.contains("another start of the node") && refused.text.contains(lock), "\(refused)")
        #expect(!FileManager.default.fileExists(atPath: marker) && NodeRecord.read(root: root.path) == record)
        // Once the first is done, a start goes on (its host ends at once here, refused for that).
        flock(fd, LOCK_UN)
        guard case .failure(let ended) = NodeStarter.startDetached(host: host, home: home.path, path: DetachedScratch.path, root: root.path,
                                                                   lock: NodeFolders.hostLock(root: root.path), isHost: { _ in false }, settle: hangGuard) else {
            Issue.record("a host that ended at once was taken"); return
        }
        #expect(ended.text.contains("the host ended at once"), "\(ended)")
        #expect(FileManager.default.fileExists(atPath: marker))
        var info = stat()
        #expect(lstat(lock, &info) == 0 && info.st_mode & 0o777 == 0o600 && info.st_mode & S_IFMT == S_IFREG)
    }

    /// The review of S3: without systemd no cgroup holds the host's processes, so a detached stop finds them by the
    /// tree. What is under the host is read again while it ends, and what is under each process found is read again
    /// once it has: a child a session starts during the host's grace is ended too.
    @Test(NodeTraits.linuxOnly) func aChildStartedWhileTheHostEndsIsFoundToo() async throws {
        let folder = try scratch.shortFolder("vsgc")
        let go = folder.appendingPathComponent("go").path, said = folder.appendingPathComponent("child").path
        try #require(mkfifo(go, 0o600) == 0)
        // A session's program: once told (a line on the fifo, read by the shell itself), it starts a child and says its
        // pid.
        var spawn = Platform.Spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c",
            "read line < '\(go)'; sleep 600 & echo $! > '\(said).part'; mv '\(said).part' '\(said)'; wait"])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.keep = []
        let session = try await startRetrying(spawn)
        defer { kill(session, SIGKILL); _ = collected(session, by: MacTime.real.awake() + 10) }
        let link = try #require(Platform.Processes.link(session))
        // What a stop knew before (the session), its host gone (nil): nothing new yet.
        #expect(NodeStopper.gathered([link], host: nil).map(\.pid) == [session])
        // Told once it reads (a writer's open with nobody reading fails at once).
        var writer: Int32 = -1
        try #require(await eventually(timeout: 30) { writer = open(go, O_WRONLY | O_NONBLOCK | O_CLOEXEC); return writer >= 0 })
        _ = write(writer, "go\n", 3)
        close(writer)
        try #require(await eventually(timeout: 30) { FileManager.default.fileExists(atPath: said) })
        let child = try #require(pid_t(try String(contentsOfFile: said, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(child, SIGKILL) }
        let found = NodeStopper.gathered([link], host: nil)
        #expect(found.contains { $0.pid == child } && found.filter { $0.pid == session }.count == 1, "\(found)")
        // And under a live host: its own children, added to what was known.
        let underThis = NodeStopper.gathered([], host: getpid())
        #expect(underThis.contains { $0.pid == session } && underThis.contains { $0.pid == child }, "\(underThis)")
    }

    // MARK: stop's unit form (Linux: a recording systemctl)

    @Test(NodeTraits.linuxOnly) func stopWithNoServerStopsTheUnit() async throws {
        let manager = try Manager(scratch)
        #expect((try? NodeStopper.stopUnit(systemctl: manager.systemctl.path, runtimeFolder: manager.runtime.path).get()) != nil)
        #expect(manager.calls == ["--user stop vibeswitcher-node"], "\(manager.calls)")
        #expect(manager.environments == ["XDG_RUNTIME_DIR=\(manager.runtime.path) DBUS_SESSION_BUS_ADDRESS=unset"], "\(manager.environments)")
        #expect(NodeStopper.unitWait == TimeInterval(NodeUnit.timeoutStop + 15))
        try manager.fail("--user stop vibeswitcher-node")
        guard case .failure(let failed) = NodeStopper.stopUnit(systemctl: manager.systemctl.path, runtimeFolder: manager.runtime.path) else {
            Issue.record("a failed systemctl stop was taken"); return
        }
        #expect(failed.text.contains("stop vibeswitcher-node exited 1") && failed.exitCode == 1, "\(failed)")

        // On a scratch node the command line's stop with no server still says the node isn't running (69) and asks
        // its manager nothing (ST-D1).
        let root = try scratch.shortFolder("vsst")
        let testFolder = root.appendingPathComponent("v2/test")
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
        try ScratchNode.standIns(in: testFolder, scopes: ScratchNode.ownScope.map { [$0] })
        try Self.recordingSystemctl(in: testFolder)
        let ran = try await run(commandLine, ["stop"], environment: scratchEnvironment(root, ["VIBESWITCHER_HOME": root.path]))
        #expect(ran.status == 69 && ran.errors.contains("the node isn't running"), "\(ran.output)\(ran.errors)")
        #expect(!Self.calls(in: testFolder).contains { $0.contains("stop") }, "\(Self.calls(in: testFolder))")
    }
}

extension StartCommandTests {
    // MARK: StopSequence and the detached start's sequence (pure: the Mac runs these)

    @Test func aStopWithAServerThatDoesntAnswerStopsTheUnit() throws {
        for answer in [StopSequence.ServerAnswer.noHello("the node's server sent no hello"),
                       .refusedByCheck("the process listening on the server's socket (pid 9) is dumpable: not the node's server"),
                       .notRunning("the node isn't running: no server answers at /x/v2/server.sock")] {
            let world = StopWorld()
            world.server = answer
            #expect(try world.run().get() == .withoutServer, "\(answer)")
            let log = world.log
            let typed = try #require(log.firstIndex { $0.hasPrefix("typed:") }, "\(log)")
            let stopper = try #require(log.firstIndex(of: "stopper:systemd"), "\(log)")
            #expect(typed < stopper && !log.contains("throughServer"), "\(log)")
            #expect(log.first { $0.hasPrefix("typed:") } == "typed:" + NodeTexts.stopUnit, "\(log)")
            #expect(world.said.contains("stop goes without it"), "\(world.said)")
        }
        // Without systemd, the recorded host's stopper.
        let detached = StopWorld()
        detached.kind = .node(.noSystemd)
        detached.fallback = .success(NodeTexts.stopDetached(pid: 41, arguments: ["/h/bin/vibeswitcher-host", "--node"]))
        #expect(try detached.run().get() == .withoutServer)
        #expect(detached.log.contains("fallback:noSystemd") && detached.log.contains("stopper:noSystemd"), "\(detached.log)")
        #expect(detached.log.contains { $0.hasPrefix("typed:This ends the node's host, pid 41 (/h/bin/vibeswitcher-host --node)") }, "\(detached.log)")

        // A server that answers never falls back: its count in the confirmation, then its own stop.
        let answered = StopWorld()
        answered.server = .answered(live: 3)
        #expect(try answered.run().get() == .throughServer)
        #expect(answered.log == ["kind", "server", "typed:" + NodeTexts.stop(live: 3), "throughServer"], "\(answered.log)")
        // A fallback that finds nothing to stop (the unit inactive, the record stale): refused, nothing asked.
        let nothing = StopWorld()
        nothing.fallback = .failure(StartRefusal("the recorded pid now names another process (…); nothing ended"))
        guard case .failure(let stale) = nothing.run() else { Issue.record("a stale record went on"); return }
        #expect(stale.text.contains("nothing ended") && nothing.touchedNothing && !nothing.log.contains { $0.hasPrefix("typed:") }, "\(nothing.log)")
        // A manager whose socket is missing: refused before what it would stop is read.
        let missing = StopWorld()
        missing.kind = .node(.socketMissing)
        guard case .failure(let socket) = missing.run() else { Issue.record("a missing manager socket went on"); return }
        #expect(socket.text.contains("socket is missing") && missing.touchedNothing && !missing.log.contains { $0.hasPrefix("fallback:") }, "\(missing.log)")
        // A scratch node never falls back: refused as before (69, 1, 77).
        for (answer, code) in [(StopSequence.ServerAnswer.notRunning("the node isn't running: no server"), Int32(69)),
                               (.noHello("the node's server sent no hello"), 1), (.refusedByCheck("is dumpable"), 77)] {
            let scratch = StopWorld()
            scratch.kind = .scratch
            scratch.server = answer
            guard case .failure(let refused) = scratch.run() else { Issue.record("a scratch node fell back"); return }
            #expect(refused.exitCode == code && scratch.touchedNothing && !scratch.log.contains("installedBuild"), "\(answer): \(scratch.log)")
        }
    }

    @Test func stopJournalsItsOwnStopBeforeTheManagerIsAsked() throws {
        let world = StopWorld()
        _ = try world.run().get()
        let log = world.log
        let typed = try #require(log.firstIndex { $0.hasPrefix("typed:") }, "\(log)")
        let entry = try #require(log.firstIndex(of: "journal:stop"), "\(log)")
        let stopper = try #require(log.firstIndex { $0.hasPrefix("stopper:") }, "\(log)")
        #expect(typed < entry && entry < stopper, "\(log)")
        // The entry is `NodeJournal.entry(event: "stop", action:)`: stamped as journald stamps a terminal scope's entry,
        // and followed 30 s later by systemd's stop of the unit, it explains that stop.
        let fields = try #require(world.entries.last)
        #expect(fields.contains { $0.name == "VIBESWITCHER_EVENT" && $0.value == "stop" } && fields.contains { $0.name == "VIBESWITCHER_ACTION" })
        var stamped: [String: Any] = ["_UID": "1000", "_SYSTEMD_CGROUP": "/init.scope"]
        for field in fields { stamped[field.name] = field.value }
        let at = NodeJournalTests.start
        let entries = NodeJournalTests.read([NodeJournalTests.line(stamped, at: at), NodeJournalTests.job("stop", at: at.addingTimeInterval(30))])
        let stops = NodeJournal.events(entries)
        #expect(stops.count == 1 && stops.first?.kind == .stop, "\(stops)")
        #expect(NodeJournal.unexplained(starts: stops, entries: entries, rule: NodeJournalTests.rule).isEmpty)

        // An entry that can't be written: through systemd refused, nothing stopped.
        let unwritten = StopWorld()
        unwritten.journalWrites = false
        guard case .failure(let refused) = unwritten.run() else { Issue.record("a stop with no journal entry went on"); return }
        #expect(refused.text.contains("journal") && !unwritten.log.contains { $0.hasPrefix("stopper:") }, "\(unwritten.log)")
        // Without systemd there is no journal: the stop goes on, said not recorded.
        let none = StopWorld()
        none.kind = .node(.noSystemd)
        none.journalWrites = false
        #expect(try none.run().get() == .withoutServer)
        #expect(none.said.contains("isn't recorded"), "\(none.said)")
    }

    @Test func aStopFallbackWithNoTerminalIsRefused() {
        for answer in [StopSequence.ServerAnswer.notRunning("the node isn't running"), .answered(live: 2)] {
            let world = StopWorld()
            world.server = answer
            world.typed = .noTerminal
            guard case .failure(let refused) = world.run() else { Issue.record("a stop with no terminal went on"); return }
            #expect(refused.text == TypedOutcome.noTerminal.refusal, "\(refused)")
            #expect(world.touchedNothing, "\(answer): \(world.log)")
        }
    }

    @Test func aCommandLineBuiltInDotBuildRefusesTheStopFallbackBeforeAnyWrite() {
        let world = StopWorld()
        world.installedBuild = .failure(StartRefusal("start runs only from an installed build: this command line is /src/.build/debug/vibeswitcher-cli"))
        guard case .failure(let refused) = world.run() else { Issue.record("a command line under .build stopped the node"); return }
        #expect(refused.text.contains("runs only from an installed build") && refused.exitCode == 77, "\(refused)")
        // The server was asked (a connection, as before S3), then the check, and nothing after it: no fallback read,
        // no code, no entry, no stop.
        #expect(world.log == ["kind", "server", "installedBuild"], "\(world.log)")
        // Through the server, no installed build is needed (as before S3).
        let answered = StopWorld()
        answered.server = .answered(live: 0)
        answered.installedBuild = world.installedBuild
        #expect((try? answered.run().get()) == .throughServer)
        #expect(!answered.log.contains("installedBuild"), "\(answered.log)")
    }

    /// The review of S3: the Mac has no `/run/systemd/system`, so `NodeFolders.mode` says `.noSystemd` there, but no
    /// node runs detached on the Mac. Its `stop` with no server refuses as before S3 (69, "the node isn't running"),
    /// without the installed-build check or any fallback.
    @Test func theMacsStopWithNoServerSaysTheNodeIsntRunning() {
        var modeRead = false
        #expect(StopSequence.kind(isScratch: false, onTheMac: true, mode: { modeRead = true; return .noSystemd }) == .scratch)
        #expect(!modeRead)
        #expect(StopSequence.kind(isScratch: true, onTheMac: false, mode: { .systemd }) == .scratch)
        #expect(StopSequence.kind(isScratch: false, onTheMac: false, mode: { .noSystemd }) == .node(.noSystemd))
        #expect(StopSequence.kind(isScratch: false, onTheMac: false, mode: { .systemd }) == .node(.systemd))
        let world = StopWorld()
        world.kind = StopSequence.kind(isScratch: false, onTheMac: true, mode: { .noSystemd })
        world.installedBuild = .failure(StartRefusal("start runs only from an installed build: /proc/self/exe can't be read"))
        guard case .failure(let refused) = world.run() else { Issue.record("the Mac's stop went on with no server"); return }
        #expect(refused.exitCode == 69 && refused.text.contains("the node isn't running"), "\(refused)")
        #expect(world.log == ["kind", "server"] && world.touchedNothing, "\(world.log)")
    }

    @Test func aMachineWithoutSystemdStartsTheNodeDetached() throws {
        let world = StartWorld()
        world.kind = .node(.noSystemd)
        world.existingUnit = "a unit naming \(Self.other)"
        world.current = Self.other
        #expect(try world.run().get() == .started(commit: StartWorld.installed))
        let log = world.log
        // No manager, no unit, no link folders: the command line's own build, detached.
        for step in ["managerEnvironment", "managerConfig", "existingUnit", "unitBuild", "enabledBy"] {
            #expect(!log.contains(step), "\(step): \(log)")
        }
        #expect(!log.contains { $0.hasPrefix("starter:") }, "\(log)")
        let (inputs, atLogin) = try #require(world.started.first)
        #expect(inputs == NodeUnit.Inputs(prefix: StartWorld.prefix, commit: StartWorld.installed, home: StartWorld.home,
                                          swiftBin: StartWorld.swiftBin, nodeBin: StartWorld.nodeBin) && !atLogin)
        // The list and its code first, then the start's code, then the entry before the host starts.
        let ack = try #require(log.firstIndex(of: "journal:" + NotPromised.ackEvent), "\(log)")
        let typed = try #require(log.lastIndex { $0.hasPrefix("typed:") }, "\(log)")
        let entry = try #require(log.firstIndex(of: "journal:start"), "\(log)")
        let detached = try #require(log.firstIndex { $0.hasPrefix("detached:") }, "\(log)")
        let started = try #require(log.firstIndex(of: "host:start"), "\(log)")
        #expect(ack < typed && typed < detached && detached < entry && entry < started, "\(log)")
        // The confirmation: detached, its command, its environment, its log and its record, the weaker rule.
        let said = world.said
        #expect(said.contains("No systemd here: this starts the node detached") && said.contains(NodeUnit.execStart(prefix: StartWorld.prefix, commit: StartWorld.installed).joined(separator: " ")), "\(said)")
        #expect(said.contains("SWIFT_BACKTRACE=enable=no") && said.contains(NodeFolders.nodeRoot(accountHome: StartWorld.home) + "/v2/host.log")
                    && said.contains(NodeFolders.nodeRoot(accountHome: StartWorld.home) + "/v2/node.pid"), "\(said)")
        #expect(said.contains(NodeTexts.weakerRule) && said.contains("current is \(Self.other)"), "\(said)")

        // --at-login: refused, nothing asked.
        let login = StartWorld()
        login.kind = .node(.noSystemd)
        guard case .failure(let refused) = login.run(StartArguments(atLogin: true)) else { Issue.record("a detached start enabled at login"); return }
        #expect(refused.text.contains("nothing starts the node when you log in") && login.touchedNothing, "\(login.log)")
        // No journal (none without systemd): the list and its code at each start, the start said not recorded.
        let none = StartWorld()
        none.kind = .node(.noSystemd)
        none.acknowledged = .failure(.init("journalctl --user didn't answer"))
        none.journalWrites = false
        #expect(try none.run().get() == .started(commit: StartWorld.installed))
        #expect(none.log.contains("showList") && none.log.filter { $0.hasPrefix("typed:") }.count == 2, "\(none.log)")
        #expect(none.said.contains("can't be recorded") && none.said.contains("this start isn't recorded"), "\(none.said)")
        // The code for the list typed wrong: nothing started.
        let wrong = StartWorld()
        wrong.kind = .node(.noSystemd)
        wrong.typed = [.wrong]
        guard case .failure = wrong.run() else { Issue.record("a wrong code started the node detached"); return }
        #expect(wrong.touchedNothing, "\(wrong.log)")
        // The host that didn't come: its refusal.
        let failed = StartWorld()
        failed.kind = .node(.noSystemd)
        failed.acknowledged = .success(true)
        failed.detached = .failure(StartRefusal("the host ended at once (pid 7, exit status 1); see /home/u/.vibeswitcher/v2/host.log", exitCode: 1))
        guard case .failure(let ended) = failed.run() else { Issue.record("a host that ended was taken"); return }
        #expect(ended.text.contains("ended at once"), "\(ended)")
    }

    /// The app's `HostRestartTests.anyOtherSaysHowManySessionsInAllProjectsItEndsAndAsksFirst` (port-map row 100),
    /// restated on `stop`'s confirmation: how many sessions in all projects it ends; nothing live, it says so.
    @Test func anyOtherSaysHowManySessionsInAllProjectsItEndsAndAsksFirst() {
        #expect(NodeTexts.stop(live: 3) == "This ends 3 sessions in all projects (the leads first), then stops its host.")
        #expect(NodeTexts.stop(live: 1) == "This ends 1 session in all projects (the leads first), then stops its host.")
        #expect(NodeTexts.stop(live: 3).contains("ends 3 sessions in all projects"))
        #expect(NodeTexts.stop(live: 0) == "No session is live; this stops the host.")
        // Each is asked first: the confirmation is what the typed code is asked with.
        let world = StopWorld()
        world.server = .answered(live: 1)
        _ = world.run()
        #expect(world.log.contains("typed:" + NodeTexts.stop(live: 1)), "\(world.log)")
    }

    @Test func statusSaysTheWeakerRuleWithoutSystemd() throws {
        #expect(NodeTexts.statusLines(mode: .detached(record: NodeRecord(pid: 4, startTicks: 5))) == [NodeTexts.weakerRule])
        #expect(NodeTexts.statusLines(mode: .detached(record: nil)) == [NodeTexts.weakerRule])
        #expect(NodeTexts.statusLines(mode: .node).isEmpty && NodeTexts.statusLines(mode: .scratch(root: "/srv/x")).isEmpty)
        #expect(NodeTexts.weakerRule.contains("weaker voice rule") && NodeTexts.weakerRule.contains("pid file") && NodeTexts.weakerRule.contains("any worker"))
        // `status` adds them after the facts, in both forms (the command line can't be put on a machine without
        // systemd here: its code is read).
        let status = try String(contentsOf: ServerLintTests.repo.appendingPathComponent("Sources/vibeswitcher-cli/Status.swift"), encoding: .utf8)
        #expect(status.contains("NodeTexts.statusLines(mode: context.mode)") && status.contains("facts.lines + modeLines"))
    }
}
