#if canImport(Darwin)
import VibeCore
import Foundation
import Testing

/// scripts/lib/install-app.sh, the --install step of scripts/build-app.sh: after it, the process running is the one just
/// installed, or it says plainly that it isn't and exits 1. 2026-10-30: three installs printed "Installed and launched"
/// while the app process stayed the one started at 13:08 (it ignores SIGTERM at the signal level and quits on it only
/// when its main queue gets to it; the 10 s wait gave up silently, and `open` activated the old process over the
/// replaced bundle). Driven here against a scratch stand-in, never the user's app: the process name, the quit request
/// and the launch are the script's injectable parts.
///
/// The stand-in is a bundle-shaped folder whose Contents/MacOS/<name> is a symlink to bash: pgrep -x sees a process by
/// the name it was started under, and a copy of bash is killed by the kernel outside the system volume. Its script
/// quits, or doesn't, on the quit request (SIGUSR1 here, where the app gets a quit Apple Event) and on SIGTERM, as the
/// bundle's mode file says. The launcher stands in for `open`: it starts the bundle's process when none of the name is
/// running, and only "activates" (does nothing) when one is, which is what let the old script report over a stale one.
struct InstallRelaunchTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let script = repo.appendingPathComponent("scripts/lib/install-app.sh")
    let temp = Scratch()

    final class StandIn {
        let name: String
        let root: URL
        let installed: URL
        let built: URL
        let ready: URL
        let launcher: URL
        /// Stands in for `codesign -v`: a bundle passes when the files under Contents are the ones its seal
        /// (Contents/_CodeSignature/seal, written by `seal`) lists, byte for byte.
        let verifier: URL
        /// Put first on the script's PATH: the stand-ins for the commands it finds there (`blindPgrep`, `failingPs`).
        let shims: URL
        let old: Process

        var oldPid: pid_t { old.processIdentifier }
        var installedVersion: String? { try? String(contentsOf: installed.appendingPathComponent("Contents/Resources/version"), encoding: .utf8) }

        /// The installed bundle holds a process of `mode` (started here, its traps set before this returns); the built
        /// bundle, a "new" one that quits when asked.
        init(_ scratch: Scratch, mode: String) async throws {
            root = scratch.url("install")
            name = "VSStandin" + String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
            installed = root.appendingPathComponent("Installed/\(name).app")
            built = root.appendingPathComponent("build/\(name).app")
            ready = root.appendingPathComponent("ready")
            launcher = root.appendingPathComponent("launch.sh")
            shims = root.appendingPathComponent("shims")
            verifier = root.appendingPathComponent("verify.sh")
            try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
            try """
                #!/bin/bash
                # verify.sh APP: APP's files are the ones its seal lists, as `codesign -v` checks a signature's sealed
                # resources. verify.sh seal APP: writes the seal.
                listing() { (cd "$1/Contents" && find . -path ./_CodeSignature -prune -o -type f -print0 | sort -z | xargs -0 shasum); }
                if [[ $1 == seal ]]; then mkdir -p "$2/Contents/_CodeSignature" && listing "$2" >"$2/Contents/_CodeSignature/seal"; exit; fi
                listing "$1" | diff "$1/Contents/_CodeSignature/seal" - >&2 || { echo "$1: a sealed resource is missing or invalid" >&2; exit 1; }

                """.write(to: verifier, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: verifier.path)
            try Self.makeBundle(installed, name: name, mode: mode, version: "old")
            try Self.makeBundle(built, name: name, mode: "quits-when-asked", version: "new")
            #expect(try Self.runVerifier(verifier, ["seal", installed.path]) == 0)
            #expect(try Self.runVerifier(verifier, ["seal", built.path]) == 0)
            try """
                #!/bin/bash
                # Stands in for `open APP`: starts APP's process when none of its name is running; when one is, only
                # activates it, which is to say does nothing.
                /usr/bin/pgrep -x "$VS_INSTALL_PROCESS" >/dev/null && exit 0
                "$1/Contents/MacOS/$VS_INSTALL_PROCESS" "$1/Contents/Resources/main.sh" "$VS_STANDIN_READY" </dev/null >/dev/null 2>&1 &
                exit 0

                """.write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            old = Process()
            old.executableURL = installed.appendingPathComponent("Contents/MacOS/\(name)")
            old.arguments = [installed.appendingPathComponent("Contents/Resources/main.sh").path, ready.path]
            old.standardInput = FileHandle.nullDevice
            old.standardOutput = FileHandle.nullDevice
            old.standardError = FileHandle.nullDevice
            try old.run()
            #expect(await waitReady(oldPid), "the old stand-in (pid \(oldPid)) never set its traps")
        }

        static func makeBundle(_ bundle: URL, name: String, mode: String, version: String) throws {
            let resources = bundle.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("Contents/MacOS/\(name)"), withDestinationURL: URL(fileURLWithPath: "/bin/bash"))
            try mode.write(to: resources.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            try version.write(to: resources.appendingPathComponent("version"), atomically: true, encoding: .utf8)
            try """
                #!/bin/bash
                # The stand-in's process: says it's ready (its traps set) by a file named by its pid, then waits. $1: the
                # ready folder. The mode file: what it does on the quit request (SIGUSR1) and on SIGTERM.
                ready=$1
                mode=$(cat "$(dirname "$0")/mode")
                case $mode in
                    quits-when-asked) trap 'exit 0' USR1; trap '' TERM;;
                    quits-on-sigterm) trap '' USR1; trap 'exit 0' TERM;;
                    ignores-all) trap '' USR1; trap '' TERM;;
                    *) echo "unknown mode $mode" >&2; exit 2;;
                esac
                touch "$ready/$$"
                while :; do sleep 0.2; done

                """.write(to: resources.appendingPathComponent("main.sh"), atomically: true, encoding: .utf8)
        }

        /// Runs the verifier: `seal` writes `bundle`'s seal; otherwise, 0 when `bundle` passes it.
        @discardableResult
        func runVerifier(_ arguments: [String]) throws -> Int32 { try Self.runVerifier(verifier, arguments) }
        @discardableResult
        static func runVerifier(_ verifier: URL, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = verifier
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        func seal(_ bundle: URL) throws { #expect(try runVerifier(["seal", bundle.path]) == 0) }
        func passesVerify(_ bundle: URL) throws -> Bool { try runVerifier([bundle.path]) == 0 }
        var staged: URL { URL(fileURLWithPath: installed.path + ".installing") }
        var aside: URL { URL(fileURLWithPath: installed.path + ".replaced") }

        /// The process of `pid` has set its traps.
        func waitReady(_ pid: pid_t) async -> Bool {
            await eventually { FileManager.default.fileExists(atPath: ready.appendingPathComponent("\(pid)").path) }
        }

        /// The script's pgrep sees no process at all, as from the sandboxed shell of 2026-10-31 (pgrep -x VibeSwitcher
        /// exited 1 there while ps listed the app). The launcher and these tests use /usr/bin/pgrep, not this one.
        func blindPgrep() throws { try shim("pgrep", "#!/bin/bash\nexit 1\n") }

        /// The script's ps can't read the process list.
        func failingPs() throws { try shim("ps", "#!/bin/bash\necho 'ps: the process list is out of reach here' >&2\nexit 1\n") }

        /// The script's signals to any process are refused (EPERM), as a sandbox that allows signals only within itself
        /// does; the quit request (SIGUSR1 here, an Apple Event for the app) still goes through. `kill` is a bash builtin,
        /// so this is a function the script's bash loads from BASH_ENV.
        func refusedSignals() throws {
            try "kill() { [[ $1 == -USR1 ]] && { builtin kill \"$@\"; return; }; echo \"kill: operation not permitted\" >&2; return 1; }\n"
                .write(to: shims.appendingPathComponent("refused-signals.bash"), atomically: true, encoding: .utf8)
            bashEnv = shims.appendingPathComponent("refused-signals.bash").path
        }
        var bashEnv: String?

        /// The script's osascript, for a run with its default quit command: it records its arguments, one per line, in
        /// `osascriptArgs`, and passes the quit on (SIGUSR1, as the app gets the Apple Event) only when it's given the
        /// whole script, telling the app at the installed bundle's path to quit. Anything else gets what osascript gave
        /// the 2026-11-03 runs, whose script was just `quit`: an error, and no quit.
        func quittingOsascript() throws {
            try shim("osascript", """
                #!/bin/bash
                printf '%s\\n' "$@" >"$VS_STANDIN_OSASCRIPT_ARGS"
                if [[ $# == 7 && $1 == -e && $2 == 'on run argv' && $3 == -e && $4 == 'tell application (item 1 of argv) to quit' &&
                      $5 == -e && $6 == 'end run' && $7 == "$VS_STANDIN_DEST" ]]; then
                    /usr/bin/pgrep -x "$VS_INSTALL_PROCESS" | while read -r pid; do builtin kill -USR1 "$pid"; done
                    exit 0
                fi
                echo "osascript (stand-in): not a quit to $VS_STANDIN_DEST: $*" >&2
                exit 1

                """)
        }
        var osascriptArgs: URL { root.appendingPathComponent("osascript-args") }

        private func shim(_ command: String, _ body: String) throws {
            let file = shims.appendingPathComponent(command)
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        /// The pids pgrep -x finds under the stand-in's name (/usr/bin/pgrep, not a shim).
        func running() throws -> [pid_t] {
            let pgrep = Process(), out = Pipe()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-x", name]
            pgrep.standardOutput = out
            try pgrep.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            waitForEnd(pgrep)
            return text.split(separator: "\n").compactMap { pid_t($0) }.sorted()
        }

        /// Runs the install step with the stand-in's parts, waiting `wait` seconds at each of its waits.
        /// `defaultQuit`: VS_INSTALL_QUIT unset, so the script's own quit command runs (see `quittingOsascript`).
        func install(wait: Int, defaultQuit: Bool = false) throws -> (status: Int32, output: String) {
            let process = Process(), out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [InstallRelaunchTests.script.path, built.path, installed.path]
            var environment = ProcessInfo.processInfo.environment
            environment["VS_INSTALL_PROCESS"] = name
            if defaultQuit {
                environment["VS_INSTALL_QUIT"] = nil
                environment["VS_STANDIN_DEST"] = installed.path
                environment["VS_STANDIN_OSASCRIPT_ARGS"] = osascriptArgs.path
            } else {
                environment["VS_INSTALL_QUIT"] = "kill -USR1 \"$@\""
            }
            environment["VS_INSTALL_LAUNCH"] = "\"\(launcher.path)\" \"$1\""
            environment["VS_INSTALL_WAIT"] = "\(wait)"
            environment["VS_INSTALL_VERIFY"] = "\"\(verifier.path)\" \"$1\""
            environment["VS_STANDIN_READY"] = ready.path
            environment["BASH_ENV"] = bashEnv
            environment["PATH"] = shims.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = out
            try process.run()
            let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            waitForEnd(process)
            return (process.terminationStatus, output)
        }

        /// "running as pid N" in the script's last line.
        static func launchedPid(in output: String) -> pid_t? {
            output.firstMatch(of: #/running as pid (\d+)/#).flatMap { pid_t($0.1) }
        }

        /// Ends every process of the stand-in's name (SIGKILL: one may ignore the rest) and waits for them to go.
        /// Blocking, for a `defer`: short, as a SIGKILL's processes end at once, and bounded by the hang guard.
        func cleanUp() {
            for pid in (try? running()) ?? [] { kill(pid, SIGKILL) }
            if old.isRunning { kill(oldPid, SIGKILL) }
            waitForEnd(old)
            let deadline = MacTime.real.awake() + hangGuard
            var left = (try? running()) ?? []
            while !left.isEmpty, MacTime.real.awake() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
                left = (try? running()) ?? []
            }
            #expect(left.isEmpty, "stand-ins of \(name) left running")
        }
    }

    /// The app ignores the quit request and SIGTERM (the stuck main queue of 2026-10-30): the script says so, exits 1,
    /// and leaves the installed bundle and the process as they were. Nothing says "Installed and launched".
    @Test func anAppThatWontQuitIsLeftAsItWasAndTheInstallFailsClosed() async throws {
        let stand = try await StandIn(temp, mode: "ignores-all")
        defer { stand.cleanUp() }
        let run = try await offPool { try stand.install(wait: 2) }
        #expect(run.status == 1, Comment(rawValue: run.output))
        #expect(run.output.contains("Asking \(stand.name) (pid \(stand.oldPid), started "), Comment(rawValue: run.output))
        #expect(run.output.contains("didn't quit within 2s of being asked; sending SIGTERM"), Comment(rawValue: run.output))
        #expect(run.output.contains("\(stand.name) is still running (pid \(stand.oldPid), started ") && run.output.contains("2s after a quit request and 2s after SIGTERM"), Comment(rawValue: run.output))
        #expect(run.output.contains("Nothing was installed: \(stand.installed.path) is the one that was there. Quit it yourself"), Comment(rawValue: run.output))
        #expect(!run.output.contains("Installed and launched"), Comment(rawValue: run.output))
        #expect(stand.installedVersion == "old")
        #expect(try stand.running() == [stand.oldPid])
    }

    /// The app quits when asked (what ⌘Q and the quit Apple Event do): the bundle is replaced, the new one launched, and
    /// the message names the new process, started after the copy, and the one before.
    @Test func anAppThatQuitsWhenAskedIsReplacedAndRelaunched() async throws {
        let stand = try await StandIn(temp, mode: "quits-when-asked")
        defer { stand.cleanUp() }
        let run = try await offPool { try stand.install(wait: 10) }
        #expect(run.status == 0, Comment(rawValue: run.output))
        #expect(run.output.contains("Asking \(stand.name) (pid \(stand.oldPid), started ") && run.output.contains("\n\(stand.name) quit.\n"), Comment(rawValue: run.output))
        #expect(!run.output.contains("SIGTERM"), Comment(rawValue: run.output))
        let launched = try #require(StandIn.launchedPid(in: run.output), Comment(rawValue: run.output))
        #expect(run.output.contains("Installed and launched \(stand.installed.path): running as pid \(launched), started "), Comment(rawValue: run.output))
        #expect(run.output.contains(", after the copy at ") && run.output.contains("(before: pid \(stand.oldPid), started "), Comment(rawValue: run.output))
        #expect(launched != stand.oldPid)
        #expect(stand.installedVersion == "new")
        #expect(try stand.running() == [launched], "the one running is the one launched")
        #expect(await stand.waitReady(launched), "the launched process is the new bundle's")
        #expect(!stand.old.isRunning)
        #expect(try stand.passesVerify(stand.installed))
        #expect(!FileManager.default.fileExists(atPath: stand.staged.path) && !FileManager.default.fileExists(atPath: stand.aside.path))
    }

    /// 2026-11-07: the copy into /Applications failed partway (`fcopyfile failed: Input/output error` on a file in a test
    /// bundle) after the old bundle was removed, which left an installed app failing `codesign -v` and nothing running.
    /// Here a file of the built bundle can't be read, so cp copies the rest and fails: the installed bundle is the old one
    /// and still passes its check, the partial copy is gone, the old app is relaunched, and the exit status is 1.
    @Test func aCopyThatFailsPartwayLeavesTheOldAppInstalledAndRelaunchesIt() async throws {
        let stand = try await StandIn(temp, mode: "quits-when-asked")
        defer { stand.cleanUp() }
        let fixture = stand.built.appendingPathComponent("Contents/Resources/Fixtures/suggestion.raw")
        try FileManager.default.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "raw".write(to: fixture, atomically: true, encoding: .utf8)
        try stand.seal(stand.built)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.path) }
        let run = try stand.install(wait: 10)
        #expect(run.status == 1, Comment(rawValue: run.output))
        #expect(run.output.contains("suggestion.raw"), Comment(rawValue: run.output))
        #expect(run.output.contains("Copying \(stand.built.path) to \(stand.staged.path) failed"), Comment(rawValue: run.output))
        #expect(run.output.contains("Nothing was installed: \(stand.installed.path) is the one that was there."), Comment(rawValue: run.output))
        #expect(run.output.contains("Relaunched the old \(stand.installed.path)."), Comment(rawValue: run.output))
        #expect(!run.output.contains("Installed and launched"), Comment(rawValue: run.output))
        #expect(stand.installedVersion == "old")
        #expect(try stand.passesVerify(stand.installed), "the installed bundle no longer passes its check")
        #expect(!FileManager.default.fileExists(atPath: stand.staged.path), "the partial copy was left")
        #expect(!stand.old.isRunning)
        #expect(await eventually { ((try? stand.running()) ?? []).count == 1 }, "the old app wasn't relaunched")
        let relaunched = try #require(try stand.running().first)
        #expect(relaunched != stand.oldPid)
        #expect(await stand.waitReady(relaunched), "the relaunched process never started")
    }

    /// The copy completes but doesn't pass the signature check: the same, nothing swapped in, the old app relaunched.
    @Test func aCopyThatFailsItsSignatureCheckIsNotSwappedIn() async throws {
        let stand = try await StandIn(temp, mode: "quits-when-asked")
        defer { stand.cleanUp() }
        try "tampered".write(to: stand.built.appendingPathComponent("Contents/Resources/extra"), atomically: true, encoding: .utf8)
        let run = try stand.install(wait: 10)
        #expect(run.status == 1, Comment(rawValue: run.output))
        #expect(run.output.contains("The copy at \(stand.staged.path) doesn't pass its signature check"), Comment(rawValue: run.output))
        #expect(run.output.contains("Relaunched the old \(stand.installed.path)."), Comment(rawValue: run.output))
        #expect(stand.installedVersion == "old")
        #expect(try stand.passesVerify(stand.installed))
        #expect(!FileManager.default.fileExists(atPath: stand.staged.path))
        #expect(await eventually { ((try? stand.running()) ?? []).count == 1 }, "the old app wasn't relaunched")
        let relaunched = try #require(try stand.running().first)
        #expect(await stand.waitReady(relaunched))
    }

    /// 2026-11-03: the default quit command had lost its quotes to the ${VS_INSTALL_QUIT:-…} it was written in, so
    /// osascript got `-e quit app VibeSwitcher`, a script of just `quit` (-1708), and every install waited out the 10 s
    /// and fell back to SIGTERM. Run with that default, the quit now reaches the app at once: osascript is given the
    /// whole script and the installed bundle's path, and SIGTERM is never sent.
    @Test func theDefaultQuitCommandAsksTheInstalledAppToQuit() async throws {
        let stand = try await StandIn(temp, mode: "quits-when-asked")
        defer { stand.cleanUp() }
        try stand.quittingOsascript()
        let run = try await offPool { try stand.install(wait: 10, defaultQuit: true) }
        let args = (try? String(contentsOf: stand.osascriptArgs, encoding: .utf8)) ?? "(osascript wasn't run)"
        #expect(args == "-e\non run argv\n-e\ntell application (item 1 of argv) to quit\n-e\nend run\n\(stand.installed.path)\n", Comment(rawValue: args))
        #expect(run.status == 0, Comment(rawValue: run.output))
        #expect(run.output.contains("Asking \(stand.name) (pid \(stand.oldPid), started ") && run.output.contains("\n\(stand.name) quit.\n"), Comment(rawValue: run.output))
        #expect(!run.output.contains("SIGTERM") && !run.output.contains("not a quit"), Comment(rawValue: run.output))
        let launched = try #require(StandIn.launchedPid(in: run.output), Comment(rawValue: run.output))
        #expect(!stand.old.isRunning)
        #expect(stand.installedVersion == "new")
        #expect(try stand.running() == [launched])
    }

    /// The app doesn't answer the quit request (no Apple Events reach it) but quits on SIGTERM, the fallback: replaced
    /// and relaunched too, and the message says which it took.
    @Test func anAppThatQuitsOnlyOnSIGTERMIsReplacedAfterTheFallback() async throws {
        let stand = try await StandIn(temp, mode: "quits-on-sigterm")
        defer { stand.cleanUp() }
        let run = try await offPool { try stand.install(wait: 3) }
        #expect(run.status == 0, Comment(rawValue: run.output))
        #expect(run.output.contains("didn't quit within 3s of being asked; sending SIGTERM.\n\(stand.name) quit on SIGTERM.\n"), Comment(rawValue: run.output))
        let launched = try #require(StandIn.launchedPid(in: run.output), Comment(rawValue: run.output))
        #expect(run.output.contains("Installed and launched \(stand.installed.path): running as pid \(launched), started "), Comment(rawValue: run.output))
        #expect(launched != stand.oldPid)
        #expect(stand.installedVersion == "new")
        #expect(try stand.running() == [launched])
    }

    /// No process of the name after the launch (`open` dropped on an app still quitting, or a launch that fails): the
    /// script says the bundle is installed but nothing new is up, and exits 1 rather than "Installed and launched".
    @Test func aLaunchThatStartsNothingIsReportedAndFails() async throws {
        let stand = try await StandIn(temp, mode: "quits-when-asked")
        defer { stand.cleanUp() }
        try "#!/bin/bash\nexit 0\n".write(to: stand.launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stand.launcher.path)
        let run = try await offPool { try stand.install(wait: 2) }
        #expect(run.status == 1, Comment(rawValue: run.output))
        #expect(run.output.contains("Installed \(stand.installed.path), but no new \(stand.name) process is up 2s after the launch"), Comment(rawValue: run.output))
        #expect(run.output.contains("Open it yourself: open \(stand.installed.path)"), Comment(rawValue: run.output))
        #expect(!run.output.contains("Installed and launched"), Comment(rawValue: run.output))
        #expect(stand.installedVersion == "new")
        #expect(try stand.running() == [])
    }

    /// 2026-10-31: from a sandboxed shell pgrep saw no process at all, so the script said "VibeSwitcher isn't running",
    /// removed and replaced the bundle under the live app, and `open` only brought the old process forward. Now the
    /// script finds the app with ps, by its executable inside the installed bundle: it's asked to quit like any other
    /// run, and the one running afterwards is the one just installed.
    @Test func anAppPgrepCantSeeIsStillAskedToQuitBeforeItsBundleIsReplaced() async throws {
        let stand = try await StandIn(temp, mode: "quits-when-asked")
        defer { stand.cleanUp() }
        try stand.blindPgrep()
        let run = try await offPool { try stand.install(wait: 10) }
        #expect(!run.output.contains("isn't running"), Comment(rawValue: run.output))
        #expect(run.output.contains("Asking \(stand.name) (pid \(stand.oldPid), started ") && run.output.contains("\n\(stand.name) quit.\n"), Comment(rawValue: run.output))
        #expect(run.status == 0, Comment(rawValue: run.output))
        let launched = try #require(StandIn.launchedPid(in: run.output), Comment(rawValue: run.output))
        #expect(launched != stand.oldPid)
        #expect(!stand.old.isRunning, "the old process outlived the replacement of its bundle")
        #expect(stand.installedVersion == "new")
        #expect(try stand.running() == [launched], "the one running is the one launched")
    }

    /// The same blind pgrep, and an app that won't quit: nothing is copied over it.
    @Test func anAppPgrepCantSeeThatWontQuitKeepsItsBundle() async throws {
        let stand = try await StandIn(temp, mode: "ignores-all")
        defer { stand.cleanUp() }
        try stand.blindPgrep()
        let run = try await offPool { try stand.install(wait: 2) }
        #expect(run.status == 1, Comment(rawValue: run.output))
        #expect(run.output.contains("Nothing was installed: \(stand.installed.path) is the one that was there."), Comment(rawValue: run.output))
        #expect(!run.output.contains("Installed and launched"), Comment(rawValue: run.output))
        #expect(stand.installedVersion == "old")
        #expect(try stand.running() == [stand.oldPid])
    }

    /// The process list can't be read at all: the script can't tell whether the app is up, so it copies nothing and
    /// says why, rather than taking "none found" for "not running".
    @Test func anUnreadableProcessListInstallsNothing() async throws {
        let stand = try await StandIn(temp, mode: "quits-when-asked")
        defer { stand.cleanUp() }
        try stand.blindPgrep()
        try stand.failingPs()
        let run = try await offPool { try stand.install(wait: 2) }
        #expect(run.status == 1, Comment(rawValue: run.output))
        #expect(run.output.contains("Couldn't read the process list"), Comment(rawValue: run.output))
        #expect(run.output.contains("Nothing was installed: \(stand.installed.path) is the one that was there."), Comment(rawValue: run.output))
        #expect(!run.output.contains("isn't running"), Comment(rawValue: run.output))
        #expect(stand.installedVersion == "old")
        #expect(stand.old.isRunning)
    }

    /// The sandboxed shell may refuse the script's signals to the app as well (kill -0 fails with EPERM on a live pid):
    /// that must read as "still up", never as "quit", so an app that won't quit keeps its bundle.
    @Test func anAppTheScriptCantSignalIsStillUpUntilPsSaysItsGone() async throws {
        let stand = try await StandIn(temp, mode: "ignores-all")
        defer { stand.cleanUp() }
        try stand.blindPgrep()
        try stand.refusedSignals()
        let run = try await offPool { try stand.install(wait: 2) }
        #expect(run.status == 1, Comment(rawValue: run.output))
        #expect(!run.output.contains("\n\(stand.name) quit"), Comment(rawValue: run.output))
        #expect(run.output.contains("Nothing was installed: \(stand.installed.path) is the one that was there."), Comment(rawValue: run.output))
        #expect(stand.installedVersion == "old")
        #expect(try stand.running() == [stand.oldPid])
    }

    /// The same refused signals and an app that quits when asked: ps sees it go, and the install carries on.
    @Test func anAppTheScriptCantSignalIsReplacedOnceItQuits() async throws {
        let stand = try await StandIn(temp, mode: "quits-when-asked")
        defer { stand.cleanUp() }
        try stand.blindPgrep()
        try stand.refusedSignals()
        let run = try await offPool { try stand.install(wait: 10) }
        #expect(run.status == 0, Comment(rawValue: run.output))
        #expect(run.output.contains("\n\(stand.name) quit.\n"), Comment(rawValue: run.output))
        let launched = try #require(StandIn.launchedPid(in: run.output), Comment(rawValue: run.output))
        #expect(!stand.old.isRunning)
        #expect(stand.installedVersion == "new")
        #expect(try stand.running() == [launched])
    }
}
#endif
