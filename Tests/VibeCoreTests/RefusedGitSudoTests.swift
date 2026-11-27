import Foundation
import Testing
@testable import VibeCore

/// The audit of the-command-guard-fails (round 3, F5): the guard knew only sudo's `-u` and `-g` as options taking a
/// value, so the value of any other (`-D dir`, `-C num`, `-h host`, `-p prompt`, `-R dir`, `-r role`, `-t type`,
/// `-T timeout`, `-U user`; sudo 1.9.17p2) was read as the program and the real one never was: `sudo -D /tmp git -C
/// /tmp status`, `sudo -C 3 setsid ls` and `sudo -h localhost setsid ls` were allowed. Now each of sudo's valued
/// options takes its value, spelled short, long (to a prefix that names it alone, `--use root`), or last in a run of
/// short options (`-nu root`), and `-h` takes the next word as its host unless it's an option (`-h` alone is sudo's
/// help). Lines are only read: nothing here runs sudo.
struct RefusedGitSudoTests {
    let temp = Scratch()
    typealias Guard = RefusedGitSpellingsTests.Guard

    /// The finding's lines, and a git and a launcher behind each of sudo's valued options, in each spelling.
    static let finding = ["sudo -D /tmp git -C /tmp status", "sudo -C 3 setsid ls", "sudo -h localhost setsid ls"]
    static let options = ["-C 3", "-D /var/empty", "-g staff", "-h localhost", "-p pw:", "-R /", "-r role", "-t type", "-T 60", "-U root",
                          "-u root", "--close-from 3", "--chdir /var/empty", "--group staff", "--host localhost", "--prompt pw:",
                          "--chroot /", "--role role", "--type type", "--command-timeout 60", "--other-user root", "--user root",
                          "-nu root", "-nD /var/empty", "-EHC 3", "-bh localhost", "-n -D /var/empty", "-D /var/empty -u root", "-h -u root", "--chdir=/var/empty",
                          "-D/var/empty", "-nuroot", "-D /var/empty --",
                          "-hlocalhost", "--host=localhost", "--use root", "--command-t 60", "-E --preserve-env=PATH -u root"]

    @Test func eachOfSudosValuedOptionsTakesItsValue() {
        for line in Self.finding {
            #expect(RefusedGit.refusal(in: line) != nil, "allowed: \(line)")
        }
        for option in Self.options {
            #expect(RefusedGit.refusal(in: "sudo \(option) git -C /var/empty status") == .option("-C"), "sudo \(option) git -C /var/empty status")
            #expect(RefusedGit.refusal(in: "sudo \(option) setsid ls") == .unreadable(.launcher("setsid")), "sudo \(option) setsid ls")
            #expect(RefusedGit.refusal(in: "sudo \(option) security list-keychains") == .keychain, "sudo \(option) security list-keychains")
            #expect(RefusedGit.refusal(in: "sudo \(option) make install") == nil, "refused: sudo \(option) make install")
        }
    }

    /// The hook, as the audit probed it: the finding's git line is denied, as `sudo -u root …` already was.
    @Test func theHookDeniesTheFindingsLines() throws {
        let worker = try Guard(.worker, temp: temp)
        for line in Self.finding + ["sudo -u root git -C /var/empty status", "sudo -T 60 git push origin main", "sudo -nD /var/empty git push origin main"] {
            #expect(try worker.hookDenies(line, cwd: worker.root), "allowed: \(line)")
        }
    }
}
