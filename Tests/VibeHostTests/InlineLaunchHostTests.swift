import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// On Linux a role's settings, MCP config and prompt are on its command line (`LinuxLaunch.inline`, 15 to 30 KiB a
/// role). The host runs that command but records it without them (`LinuxLaunch.recorded`): every welcome carries every
/// session's command, ended sessions included for a day, and a day of a team's sessions would otherwise pass a frame's
/// 1 MiB (`HostFrame.maxPayload`). The host would then answer `hello` with an error, and every client, the lead's tool
/// server and the hooks among them, waits for a welcome before its first request.
@Suite(.serialized) struct InlineLaunchHostTests {
    let temp = Scratch()

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's inline launch; the Mac's are files"))
    func aDayOfInlineRoleSessionsStillGetsAWelcome() async throws {
        let dir = temp.url("inline-host")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The project's Claude command: a script that writes what it was given and ends.
        let claude = dir.path + "/claude", given = dir.path + "/given"
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(given)'\n".write(toFile: claude, atomically: true, encoding: .utf8)
        chmod(claude, 0o755)
        let prompt = String(repeating: "Check every line, and say what you found. ", count: 600)
        let launch = try LeadLaunch.prepare(role: .worker, root: dir.path, task: "x", base: claude, prompt: prompt, start: "Go.",
                                            server: "/s", name: "worker-inline", folder: dir.appendingPathComponent("run"), cwd: dir.path,
                                            temporary: dir.appendingPathComponent("tmp"))
        #expect(launch.command.contains("--append-system-prompt ") && launch.command.utf8.count > 25_000)

        let host = try TestHost()
        let app = try TestClient(host)
        defer { app.close() }
        // More than a frame's worth of inline commands, all ended (kept for a day).
        let count = HostFrame.maxPayload / launch.command.utf8.count + 2
        var ids: [UUID] = []
        for _ in 0..<count {
            let session = try await app.spawn(launch.command, cwd: dir.path, label: "Worker: x")
            ids.append(session.id)
            #expect(session.command == LinuxLaunch.recorded(launch.command) && session.command!.utf8.count < 2_000)
        }
        #expect(await eventually { ids.allSatisfy { app.latest($0)?.isLive == false } })
        // Each ran with the whole command: its prompt as given.
        let words = try String(contentsOfFile: given, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(words.firstIndex(of: "--append-system-prompt").map { words[$0 + 1] } == prompt.trimmingCharacters(in: .newlines))

        let (client, _, _, sessions, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        defer { client.close() }
        #expect(Set(sessions.map(\.id)) == Set(ids))
        #expect(sessions.allSatisfy { $0.command.flatMap(LeadLaunch.name(inCommand:)) == "worker-inline" })
    }
}
