import Foundation
import Testing
@testable import VibeCore

/// scripts/e2e/passage-contract.sh, the on-demand check that the installed Passage command line still matches what
/// PassageLink, PassageCommand and scripts/e2e/loop-passage assume, run here against made-up `passage` executables in a
/// scratch folder: one whose help matches (exit 0), ones whose help drifted (exit 1, each difference named), help that
/// can't be read (drift, never a pass), and none found (exit 3). Never the real passage: each run's PATH holds the
/// system folders and a scratch one only, and its app bundles are scratch ones.
struct PassageContractTests {
    let scratch = Scratch()
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let script = repo.appendingPathComponent("scripts/e2e/passage-contract.sh").path

    /// Passage 1.0's `passage help`, as installed 2026-11-10.
    static let help = """
        usage: passage <command> [options]

          peers [--no-discovery] [--json] [--wait S]   paired peers; which ones are reachable now
          send <peer> <file>|- [--yes] [--name N] [--timeout S]
                                                      send a file, or text from stdin, to a peer that is listening
          listen [--json]                             receive from paired peers into the inbox until Ctrl-C
          inbox [peer] [--json]                       list received messages
          unpair <peer>                               forget a pairing (the inbox folder stays)
          version
          help

        <peer> is a peer ID (8 hex characters) or a peer's name. Exit codes: 0 ok, 1 failure, 2 usage,
        3 not paired, 4 not reachable, 5 refused (secret warning not confirmed). Details: README › Command line.

        """

    /// A made-up passage at `path`: `help` prints `help`, `version` prints `version`; any other command is written to
    /// `<path>.calls` and exits 99 (the script must never run one). With `needsCli`, it answers only after `cli`, as
    /// the app's binary does (anything else would open its window: exit 98).
    func fake(at path: URL, help: String = PassageContractTests.help, version: String = "passage 1.0", needsCli: Bool = false) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try help.write(to: URL(fileURLWithPath: path.path + ".help"), atomically: true, encoding: .utf8)
        let calls = RecentProjects.shellQuote(path.path + ".calls")
        try """
            #!/bin/bash
            \(needsCli ? "[[ ${1:-} == cli ]] || { echo \"$*\" >>\(calls); exit 98; }; shift" : "")
            case ${1:-} in
                help) cat \(RecentProjects.shellQuote(path.path + ".help")) ;;
                version) echo '\(version)' ;;
                *) echo "$*" >>\(calls); exit 99 ;;
            esac

            """.write(to: path, atomically: true, encoding: .utf8)
        chmod(path.path, 0o755)
    }

    /// Runs the script with `arguments`; its PATH is the system's folders after `bin` (when given), and its app
    /// bundles `apps` (none unless given), so the Passage installed on this Mac is never found.
    func check(_ arguments: [String] = [], bin: URL? = nil, apps: [URL] = []) throws -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script, "--apps", apps.isEmpty ? scratch.url("no-app").path + ".app" : apps.map(\.path).joined(separator: ":")] + arguments
        var environment = ["PATH": (bin.map { $0.path + ":" } ?? "") + "/usr/bin:/bin", "HOME": scratch.url("home").path]
        environment["TMPDIR"] = ProcessInfo.processInfo.environment["TMPDIR"]
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        waitForEnd(process)
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// A scratch bin folder with a fake `passage` whose help is `help`.
    func bin(help: String = PassageContractTests.help, version: String = "passage 1.0") throws -> URL {
        let bin = scratch.url("bin")
        try fake(at: bin.appendingPathComponent("passage"), help: help, version: version)
        return bin
    }

    func driftLines(_ out: String) -> [String] { out.components(separatedBy: "\n").filter { $0.hasPrefix("DRIFT") } }

    @Test func helpThatMatchesPassesWithALinePerThingChecked() throws {
        let bin = try bin()
        let ran = try check(bin: bin)
        #expect(ran.status == 0, "\(ran.out)")
        let lines = ran.out.components(separatedBy: "\n")
        #expect(lines.first == "passage  \(bin.path)/passage (on the PATH)")
        for line in ["ok     version: passage 1.0",
                     "ok     send <peer> <file> --name N: `send <peer> <file>|- [--yes] [--name N] [--timeout S]`",
                     "ok     inbox [peer] --json: `inbox [peer] [--json]`",
                     "ok     listen: `listen [--json]`",
                     "ok     peers --no-discovery --json: `peers [--no-discovery] [--json] [--wait S]`",
                     "ok     exit 0 ok", "ok     exit 1 failure", "ok     exit 2 usage", "ok     exit 3 not paired",
                     "ok     exit 4 not reachable", "ok     exit 5 refused",
                     "ok     stand-in send: `send <peer> <file>|- [--name N] [--timeout S]`, as passage's",
                     "ok     stand-in exit 4 not reachable, as passage's"] {
            #expect(lines.contains(line), "no line \"\(line)\" in:\n\(ran.out)")
        }
        #expect(driftLines(ran.out) == [])
        #expect(lines.contains { $0.hasPrefix("passage-contract: all ") && $0.hasSuffix(" checks match") })
        // Only help and version were run.
        #expect(!FileManager.default.fileExists(atPath: bin.path + "/passage.calls"))
    }

    @Test func aChangedExitCodeLineIsDriftNamingTheCode() throws {
        let swapped = Self.help.replacingOccurrences(of: "3 not paired, 4 not reachable", with: "3 not reachable, 4 not paired")
        let ran = try check(bin: try bin(help: swapped))
        #expect(ran.status == 1, "\(ran.out)")
        let drifts = driftLines(ran.out)
        #expect(drifts.contains(#"DRIFT  exit 3: help says "not reachable", VibeSwitcher reads it as "not paired""#), "\(ran.out)")
        #expect(drifts.contains(#"DRIFT  exit 4: help says "not paired", VibeSwitcher reads it as "not reachable""#), "\(ran.out)")
        #expect(ran.out.contains("ok     exit 5 refused"))

        // A code dropped, and one VibeSwitcher doesn't know.
        let other = Self.help.replacingOccurrences(of: "5 refused (secret warning not confirmed)", with: "6 too large")
        let second = try check(bin: try bin(help: other))
        #expect(second.status == 1)
        #expect(driftLines(second.out) == [#"DRIFT  exit 5: help doesn't list it (VibeSwitcher reads it as "refused")"#,
                                           #"DRIFT  exit 6: help lists "too large", a code VibeSwitcher doesn't know"#], "\(second.out)")
    }

    @Test func sendWithoutNameIsDrift() throws {
        let ran = try check(bin: try bin(help: Self.help.replacingOccurrences(of: " [--name N]", with: "")))
        #expect(ran.status == 1, "\(ran.out)")
        let drifts = driftLines(ran.out)
        #expect(drifts.contains("DRIFT  send <peer> <file> --name N: no [--name <value>] option in `send <peer> <file>|- [--yes] [--timeout S]`"), "\(ran.out)")
        // The stand-in still takes --name: it no longer agrees with the real one.
        #expect(drifts.contains { $0.hasPrefix("DRIFT  stand-in send: scripts/e2e/loop-passage says `send <peer> <file>|- [--name N] [--timeout S]`") }, "\(ran.out)")
        #expect(drifts.count == 2)

        // A flag dropped from peers and inbox, and a new required argument to send.
        let changed = Self.help.replacingOccurrences(of: "peers [--no-discovery] [--json]", with: "peers [--json]")
            .replacingOccurrences(of: "inbox [peer] [--json]", with: "inbox [--json]")
            .replacingOccurrences(of: "send <peer> <file>|-", with: "send <peer> <file>|- <channel>")
        let second = try check(bin: try bin(help: changed))
        #expect(second.status == 1)
        #expect(second.out.contains("DRIFT  peers --no-discovery --json: no [--no-discovery] in `peers [--json] [--wait S]`"), "\(second.out)")
        #expect(second.out.contains("DRIFT  inbox [peer] --json: no [peer] in `inbox [--json]`"), "\(second.out)")
        #expect(second.out.contains(#"DRIFT  send <peer> <file> --name N: it requires "<peer> <file>|- <channel>" where VibeSwitcher passes "<peer> <file>" in"#), "\(second.out)")
    }

    @Test func aMissingCommandIsDrift() throws {
        let without = Self.help.components(separatedBy: "\n").filter { !$0.hasPrefix("  listen") }.joined(separator: "\n")
        let ran = try check(bin: try bin(help: without))
        #expect(ran.status == 1, "\(ran.out)")
        #expect(driftLines(ran.out) == ["DRIFT  listen: help lists no `listen` command",
                                        "DRIFT  stand-in listen: scripts/e2e/loop-passage has it, passage's help doesn't"], "\(ran.out)")
    }

    @Test func noPassageFoundHasItsOwnExitCode() throws {
        let ran = try check()
        #expect(ran.status == 3, "\(ran.out)")
        #expect(ran.out.hasPrefix("passage-contract: no Passage found: no passage on the PATH, and no "), "\(ran.out)")
        #expect(ran.out.components(separatedBy: "\n").count == 2)
        // A path given that isn't there, or can't run.
        let missing = scratch.url("missing").appendingPathComponent("passage")
        #expect(try check(["--passage", missing.path]).status == 3)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        #expect(try check(["--passage", missing.path]).status == 3)
        // Usage.
        #expect(try check(["--passage", "relative/passage"]).status == 64)
        #expect(try check(["--frob"]).status == 64)
    }

    /// As PassageCommand.resolve with an empty setting: the PATH first, else the first app bundle whose binary can
    /// run, with `cli`; and --passage read as PassageCommand.forPath reads a path.
    @Test func passageIsFoundAsPassageCommandResolvesIt() throws {
        let app = scratch.url("apps").appendingPathComponent("Passage.app")
        let binary = app.appendingPathComponent("Contents/MacOS/Passage")
        try fake(at: binary, needsCli: true)
        let absent = scratch.url("apps").appendingPathComponent("Passage.app")

        let fromApp = try check(apps: [absent, app])
        #expect(fromApp.status == 0, "\(fromApp.out)")
        #expect(fromApp.out.hasPrefix("passage  \(binary.path) cli (the app, run with cli)\n"), "\(fromApp.out)")

        // The PATH wins over the app.
        let bin = try bin(version: "passage 1.1")
        let fromPath = try check(bin: bin, apps: [app])
        #expect(fromPath.status == 0, "\(fromPath.out)")
        #expect(fromPath.out.hasPrefix("passage  \(bin.path)/passage (on the PATH)\nok     version: passage 1.1\n"), "\(fromPath.out)")

        // --passage: the bundle, its binary, a link to it not named passage (each with cli), and a link named passage
        // (as is: Passage takes that name as its CLI, and this fake, which wants cli, fails the check).
        let link = scratch.url("links").appendingPathComponent("psg")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        for path in [app.path, app.path + "/", binary.path, link.path] {
            let ran = try check(["--passage", path], bin: bin)
            #expect(ran.status == 0, "\(path): \(ran.out)")
            #expect(ran.out.contains(" cli (--passage)\nok     version: passage 1.0\n"), "\(path): \(ran.out)")
        }
        let named = link.deletingLastPathComponent().appendingPathComponent("passage")
        try FileManager.default.createSymbolicLink(at: named, withDestinationURL: binary)
        let asIs = try check(["--passage", named.path])
        #expect(asIs.status == 1, "\(asIs.out)")
        #expect(asIs.out.hasPrefix("passage  \(named.path) (--passage)\nDRIFT  version: `passage version` exited 98"), "\(asIs.out)")
    }

    /// Fail closed: help with no usage line, no command lines, no exit-code sentence or an item that isn't a code, a
    /// help that fails, and a version line that isn't one are each drift.
    @Test func helpThatCannotBeReadIsDrift() throws {
        for (help, says) in [
            ("Passage 2: see `passage --help-all`.\n", "DRIFT  help: no `usage: passage <command>` line: this help can't be read"),
            ("usage: passage <command> [options]\n\nCommands are listed in the README.\n", "DRIFT  help: no command lines under the usage line: this help can't be read"),
            (Self.help.components(separatedBy: "\n\n<peer>")[0] + "\n", "DRIFT  exit codes: no `Exit codes:` sentence: this help can't be read"),
            (Self.help.replacingOccurrences(of: "2 usage,", with: "usage errors,"), #"DRIFT  exit codes: "usage errors" isn't `<code> <meaning>`: this help can't be read"#),
            ("", "DRIFT  help: no `usage: passage <command>` line: this help can't be read"),
        ] {
            let ran = try check(bin: try bin(help: help))
            #expect(ran.status == 1, "\(help)\n\(ran.out)")
            #expect(driftLines(ran.out).contains(says), "\(ran.out)")
            #expect(!ran.out.contains("checks match"))
        }
        let version = try check(bin: try bin(version: "Passage, version one"))
        #expect(version.status == 1)
        #expect(driftLines(version.out) == [#"DRIFT  version: `passage version` printed "Passage, version one", not `passage <version>`"#], "\(version.out)")

        // A help that exits 1.
        let failing = scratch.url("failing").appendingPathComponent("passage")
        try FileManager.default.createDirectory(at: failing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\n[[ $1 == version ]] && { echo 'passage 1.0'; exit 0; }\necho 'passage: no' >&2\nexit 1\n".write(to: failing, atomically: true, encoding: .utf8)
        chmod(failing.path, 0o755)
        let failed = try check(["--passage", failing.path])
        #expect(failed.status == 1)
        #expect(driftLines(failed.out).contains("DRIFT  help: `passage help` exited 1: passage: no"), "\(failed.out)")
    }

    /// The stand-in can't drift unnoticed: one whose help differs from the real one on a command it lists, or on an
    /// exit code, is drift even when the real help is as VibeSwitcher assumes.
    @Test func aStandInThatDisagreesWithTheRealHelpIsDrift() throws {
        let bin = try bin()
        let standIn = scratch.url("stand-in").appendingPathComponent("loop-passage")
        // Without --yes (as the real stand-in), without send's --timeout, and with 4 meaning something else.
        let help = Self.help.replacingOccurrences(of: " [--yes] [--name N] [--timeout S]", with: " [--name N]")
            .replacingOccurrences(of: "4 not reachable, 5 refused (secret warning not confirmed)", with: "4 nobody home")
        try fake(at: standIn, help: help)
        let ran = try check(["--stand-in", standIn.path], bin: bin)
        #expect(ran.status == 1, "\(ran.out)")
        #expect(driftLines(ran.out) == [
            "DRIFT  stand-in send: \(standIn.path) says `send <peer> <file>|- [--name N]`, passage says `send <peer> <file>|- [--yes] [--name N] [--timeout S]`",
            #"DRIFT  stand-in exit 4: \#(standIn.path) says "nobody home", passage says "not reachable""#,
        ], "\(ran.out)")

        // One that lost a command both apps call, and one whose help can't be read.
        try fake(at: standIn, help: Self.help.replacingOccurrences(of: " [--yes]", with: "").components(separatedBy: "\n").filter { !$0.hasPrefix("  inbox") }.joined(separator: "\n"))
        let lost = try check(["--stand-in", standIn.path], bin: bin)
        #expect(lost.status == 1)
        #expect(driftLines(lost.out).contains("DRIFT  stand-in inbox: \(standIn.path)'s help lists no `inbox` command"), "\(lost.out)")
        try fake(at: standIn, help: "see the header\n")
        let unreadable = try check(["--stand-in", standIn.path], bin: bin)
        #expect(unreadable.status == 1)
        #expect(driftLines(unreadable.out).count == 1 && unreadable.out.contains("help can't be read"), "\(unreadable.out)")
    }

    /// The script runs the real binary through `ask` alone, which takes `help` and `version` only: no line of it
    /// runs passage with send, listen, peers, inbox or unpair.
    @Test func theScriptRunsOnlyHelpAndVersionOfTheRealBinary() throws {
        let text = try String(contentsOfFile: Self.script, encoding: .utf8)
        let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        // The binary is named in one command line: ask's.
        let runs = code.filter { $0.contains(#""$exe" $"#) }
        #expect(runs.count == 1 && runs[0].contains(#"exec @ARGV or exit 127' "$exe" $leading "$1" </dev/null"#), "\(runs)")
        #expect(code.contains { $0.contains("case $1 in help|version) ;; *)") && $0.contains("exit 1") })
        let asks = code.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("ask ") }
        #expect(asks == ["ask version", "ask help"])
    }
}
