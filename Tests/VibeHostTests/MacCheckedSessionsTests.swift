import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// What a checked Mac node's sessions are given back of the user's environment (`CheckedSessions`, the node on the Mac's
/// design, "The LaunchAgent", "Sessions' environment"), on a scratch host shaped as a checked node
/// (`--test-checked-shape HOME`: the checked start's own reset, `HOME` a scratch home whose `.zprofile` the login
/// shell reads, never the user's).
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's checked node"))
struct MacCheckedSessionsTests {
    /// A session started by a checked-shaped scratch host sees its login shell's `PATH` (the scratch `.zprofile`'s
    /// folder), launchd's own `SSH_AUTH_SOCK` (not the starter's), a locale, launchd's text encoding, `SWIFT_BACKTRACE`
    /// off and the umask 022, and doesn't see what the starter planted (its `SSH_AUTH_SOCK`, `LANG` and `SWIFT_BACKTRACE`;
    /// a name no session takes, `PLANTED_BY_STARTER`, would be dropped by the session's list anyway). Red before:
    /// the session had no `SSH_AUTH_SOCK`, no text encoding, no `SWIFT_BACKTRACE` and the host's umask 077.
    @Test func aCheckedNodesSessionHasTheUsersEnvironmentAndNotTheStarters() async throws {
        var home = ""
        let host = try await ScratchHostProcess(environment: ["PLANTED_BY_STARTER": "yes", "SSH_AUTH_SOCK": "/planted/agent.sock",
                                                              "LANG": "xx_PLANTED.UTF-8", "SWIFT_BACKTRACE": "enable=yes"],
                                                prepare: { dir in
                                                    home = dir + "/shaped"
                                                    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
                                                    try "export PATH=\"$PATH:/vs-login-marker\"\n".write(toFile: home + "/.zprofile", atomically: true, encoding: .utf8)
                                                }, late: { [CheckedSessions.testShapeFlag, home] })
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let session = try await client.spawn("env; echo umask=$(umask); echo core=$(ulimit -c),$(ulimit -Hc); echo DONE-ENV", cwd: home)
        await client.attach(session.id)
        #expect(await eventually { client.text(session.id).contains("DONE-ENV") }, "\(client.text(session.id))\n\(host.log)")
        let text = client.text(session.id).replacingOccurrences(of: "\r", with: "")
        let lines = Set(text.split(separator: "\n").map(String.init))
        func value(_ name: String) -> String? { lines.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } }
        #expect(value("PATH")?.split(separator: ":").contains("/vs-login-marker") == true, "PATH=\(value("PATH") ?? "none")")
        #expect(value("PLANTED_BY_STARTER") == nil, "the starter's variable reached the session")
        let launchd = Self.launchdSocket()
        #expect(value("SSH_AUTH_SOCK") == launchd, "SSH_AUTH_SOCK=\(value("SSH_AUTH_SOCK") ?? "none"), launchd's \(launchd ?? "none")")
        #expect(value("LANG") == "en_US.UTF-8", "LANG=\(value("LANG") ?? "none")")
        #expect(value("__CF_USER_TEXT_ENCODING")?.hasPrefix(String(format: "0x%X:", getuid())) == true,
                "__CF_USER_TEXT_ENCODING=\(value("__CF_USER_TEXT_ENCODING") ?? "none")")
        #expect(value("SWIFT_BACKTRACE") == "enable=no", "SWIFT_BACKTRACE=\(value("SWIFT_BACKTRACE") ?? "none")")
        // zsh says `022`, sh `0022`: the number.
        #expect(value("umask").flatMap { Int($0, radix: 8) } == 0o022, "umask=\(value("umask") ?? "none")")
        #expect(value("core")?.hasPrefix("0,") == true, "core=\(value("core") ?? "none")")
        #expect(!host.log.contains("not started"), "\(host.log)")
    }

    /// launchd's own `SSH_AUTH_SOCK` for this user's domain, nil when it has none.
    static func launchdSocket() -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        ps.arguments = ["getenv", "SSH_AUTH_SOCK"]
        let out = Pipe()
        ps.standardOutput = out
        try? ps.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
