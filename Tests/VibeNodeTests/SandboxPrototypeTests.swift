import Foundation
import Testing
import VibeCore

/// `Tests/Fixtures/sandbox/prototype.sh`: the throwaway box of the session sandbox plan's SB0, built by hand with
/// unshare(1) over scratch folders, for measuring what the shim's box must give (the inventory's "The session sandbox,
/// measured"). Nothing in the product runs it. These hold what the measurements rest on: it never runs on the account's
/// own home, and its box shows a program the user's uid with no capability, its worktree and nothing else of the home.
struct SandboxPrototypeTests {
    private let scratch = Scratch()

    @Test func thePrototypeRefusesTheAccountsHome() async throws {
        let account = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) })
        let worktree = scratch.url("prototype-worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let temporary = scratch.url("prototype-tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let marker = worktree.appendingPathComponent("ran").path
        // The account's home itself, its folder spelled through a link, and a folder that holds it.
        let link = scratch.url("prototype-link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: account)
        let holder = (account as NSString).deletingLastPathComponent
        for home in [account, link, holder] {
            let ran = try await PrototypeBox.run(home: home, worktree: worktree.path, temporary: temporary.path,
                                                 command: ["/usr/bin/touch", marker])
            #expect(ran.status == 64, "\(home): \(ran.status) \(ran.errors)")
            #expect(ran.errors.contains("refusing"), "\(home): \(ran.errors)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker))
        // It made nothing before refusing: no root folder of a box left in its temporary folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }

    @Test(.enabled(if: PrototypeBox.unavailable == nil, "needs an unprivileged user namespace: \(PrototypeBox.unavailable ?? "")"))
    func aProgramInThePrototypeIsTheUserWithNoCapabilityAndSeesOnlyItsBox() async throws {
        let account = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) })
        let home = scratch.url("prototype-home"), worktree = scratch.url("prototype-worktree")
        for folder in [home, worktree] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let probe = """
            echo "uid $(id -u) gid $(id -g)"
            grep -E '^(CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs):' /proc/self/status | tr -d '\\t'
            for path in "\(account)" /run /mnt /init /sys "\(scratchRoot.path)/elsewhere"; do
                [ -e "$path" ] && echo "present $path" || echo "absent $path"
            done
            touch made && echo "worktree writable"
            touch /usr/made 2>/dev/null || echo "usr read-only"
            echo "processes $(ls /proc | grep -c '^[0-9]')"
            """
        let ran = try await PrototypeBox.run(home: home.path, worktree: worktree.path, temporary: scratchRoot.path,
                                             command: ["/bin/sh", "-c", probe])
        #expect(ran.status == 0, "\(ran.errors)")
        let lines = Set(ran.output.split(separator: "\n").map(String.init))
        #expect(lines.contains("uid \(getuid()) gid \(getgid())"), "\(ran.output)")
        for set in ["CapPrm", "CapEff", "CapBnd", "CapAmb"] { #expect(lines.contains("\(set):0000000000000000"), "\(ran.output)") }
        #expect(lines.contains("NoNewPrivs:1"), "\(ran.output)")
        for path in [account, "/run", "/mnt", "/init", "/sys"] { #expect(lines.contains("absent \(path)"), "\(ran.output)") }
        #expect(lines.contains("worktree writable") && lines.contains("usr read-only"), "\(ran.output)")
        // The shell and the commands it runs as it counts: a pid namespace of the box's own.
        let processes = ran.output.split(separator: "\n").first { $0.hasPrefix("processes ") }.flatMap { Int($0.dropFirst(10)) }
        #expect((processes ?? 99) <= 4, "\(ran.output)")
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("made").path))
    }
}

/// Runs `prototype.sh`, and says whether this machine can.
enum PrototypeBox {
    static let script = packageFolder.appendingPathComponent("Tests/Fixtures/sandbox/prototype.sh")

    /// Why no box can be built here (the kernel refuses an unprivileged user namespace: GitHub's Ubuntu 24.04
    /// runners, through AppArmor); nil when one can.
    static let unavailable: String? = {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/unshare") else { return "no /usr/bin/unshare" }
        let status = try? runToEnd("/usr/bin/unshare", ["--user", "--map-current-user", "--mount", "--pid", "--fork", "/bin/true"],
                                   output: .path("/dev/null", flags: O_WRONLY), limit: 30)
        return status == 0 ? nil : "unshare --user --mount --pid: \(status.map(String.init) ?? "didn't start")"
    }()

    /// `prototype.sh HOME WORKTREE - OPTIONS -- COMMAND`, with TMPDIR `temporary` (where it makes the box's root).
    static func run(home: String, worktree: String, temporary: String, options: [String] = [],
                    command: [String]) async throws -> CommandRun {
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporary
        return try await VibeNodeTests.run(URL(fileURLWithPath: "/bin/bash"), [script.path, home, worktree, "-"] + options + ["--"] + command,
                                           environment: environment, limit: 120)
    }
}
