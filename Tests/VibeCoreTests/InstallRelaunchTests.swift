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
        let old: Process

        var oldPid: pid_t { old.processIdentifier }
        var installedVersion: String? { try? String(contentsOf: installed.appendingPathComponent("Contents/Resources/version"), encoding: .utf8) }

        /// The installed bundle holds a process of `mode` (started here, its traps set before this returns); the built
        /// bundle, a "new" one that quits when asked.
        init(_ scratch: Scratch, mode: String) throws {
            root = scratch.url("install")
            name = "VSStandin" + String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
            installed = root.appendingPathComponent("Installed/\(name).app")
            built = root.appendingPathComponent("build/\(name).app")
            ready = root.appendingPathComponent("ready")
            launcher = root.appendingPathComponent("launch.sh")
            try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
            try Self.makeBundle(installed, name: name, mode: mode, version: "old")
            try Self.makeBundle(built, name: name, mode: "quits-when-asked", version: "new")
            try """
                #!/bin/bash
                # Stands in for `open APP`: starts APP's process when none of its name is running; when one is, only
                # activates it, which is to say does nothing.
                pgrep -x "$VS_INSTALL_PROCESS" >/dev/null && exit 0
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
            #expect(waitReady(oldPid), "the old stand-in (pid \(oldPid)) never set its traps")
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

        /// The process of `pid` has set its traps.
        func waitReady(_ pid: pid_t) -> Bool {
            eventually { FileManager.default.fileExists(atPath: ready.appendingPathComponent("\(pid)").path) }
        }

        /// The pids pgrep -x finds under the stand-in's name, as the script sees them.
        func running() throws -> [pid_t] {
            let pgrep = Process(), out = Pipe()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-x", name]
            pgrep.standardOutput = out
            try pgrep.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            pgrep.waitUntilExit()
            return text.split(separator: "\n").compactMap { pid_t($0) }.sorted()
        }

        /// Runs the install step with the stand-in's parts, waiting `wait` seconds at each of its waits.
        func install(wait: Int) throws -> (status: Int32, output: String) {
            let process = Process(), out = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [InstallRelaunchTests.script.path, built.path, installed.path]
            var environment = ProcessInfo.processInfo.environment
            environment["VS_INSTALL_PROCESS"] = name
            environment["VS_INSTALL_QUIT"] = "kill -USR1 \"$@\""
            environment["VS_INSTALL_LAUNCH"] = "\"\(launcher.path)\" \"$1\""
            environment["VS_INSTALL_WAIT"] = "\(wait)"
            environment["VS_STANDIN_READY"] = ready.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = out
            try process.run()
            let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, output)
        }

        /// "running as pid N" in the script's last line.
        static func launchedPid(in output: String) -> pid_t? {
            output.firstMatch(of: #/running as pid (\d+)/#).flatMap { pid_t($0.1) }
        }

        /// Ends every process of the stand-in's name (SIGKILL: one may ignore the rest) and waits for them to go.
        func cleanUp() {
            for pid in (try? running()) ?? [] { kill(pid, SIGKILL) }
            if old.isRunning { kill(oldPid, SIGKILL) }
            old.waitUntilExit()
            #expect(eventually { ((try? running()) ?? []).isEmpty }, "stand-ins of \(name) left running")
        }
    }

    /// The app ignores the quit request and SIGTERM (the stuck main queue of 2026-10-30): the script says so, exits 1,
    /// and leaves the installed bundle and the process as they were. Nothing says "Installed and launched".
    @Test func anAppThatWontQuitIsLeftAsItWasAndTheInstallFailsClosed() throws {
        let stand = try StandIn(temp, mode: "ignores-all")
        defer { stand.cleanUp() }
        let run = try stand.install(wait: 2)
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
    @Test func anAppThatQuitsWhenAskedIsReplacedAndRelaunched() throws {
        let stand = try StandIn(temp, mode: "quits-when-asked")
        defer { stand.cleanUp() }
        let run = try stand.install(wait: 10)
        #expect(run.status == 0, Comment(rawValue: run.output))
        #expect(run.output.contains("Asking \(stand.name) (pid \(stand.oldPid), started ") && run.output.contains("\n\(stand.name) quit.\n"), Comment(rawValue: run.output))
        #expect(!run.output.contains("SIGTERM"), Comment(rawValue: run.output))
        let launched = try #require(StandIn.launchedPid(in: run.output), Comment(rawValue: run.output))
        #expect(run.output.contains("Installed and launched \(stand.installed.path): running as pid \(launched), started "), Comment(rawValue: run.output))
        #expect(run.output.contains(", after the copy at ") && run.output.contains("(before: pid \(stand.oldPid), started "), Comment(rawValue: run.output))
        #expect(launched != stand.oldPid)
        #expect(stand.installedVersion == "new")
        #expect(try stand.running() == [launched], "the one running is the one launched")
        #expect(stand.waitReady(launched), "the launched process is the new bundle's")
        #expect(!stand.old.isRunning)
    }

    /// The app doesn't answer the quit request (no Apple Events reach it) but quits on SIGTERM, the fallback: replaced
    /// and relaunched too, and the message says which it took.
    @Test func anAppThatQuitsOnlyOnSIGTERMIsReplacedAfterTheFallback() throws {
        let stand = try StandIn(temp, mode: "quits-on-sigterm")
        defer { stand.cleanUp() }
        let run = try stand.install(wait: 3)
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
    @Test func aLaunchThatStartsNothingIsReportedAndFails() throws {
        let stand = try StandIn(temp, mode: "quits-when-asked")
        defer { stand.cleanUp() }
        try "#!/bin/bash\nexit 0\n".write(to: stand.launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stand.launcher.path)
        let run = try stand.install(wait: 2)
        #expect(run.status == 1, Comment(rawValue: run.output))
        #expect(run.output.contains("Installed \(stand.installed.path), but no new \(stand.name) process is up 2s after the launch"), Comment(rawValue: run.output))
        #expect(run.output.contains("Open it yourself: open \(stand.installed.path)"), Comment(rawValue: run.output))
        #expect(!run.output.contains("Installed and launched"), Comment(rawValue: run.output))
        #expect(stand.installedVersion == "new")
        #expect(try stand.running() == [])
    }
}
