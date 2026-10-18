import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// What a host and its parsers cost (see `SessionParser`), measured on demand, never in a normal run:
/// `VIBESWITCHER_MEASURE_HOST=<a vibeswitcher-host binary> swift test --filter ParserCostTests`. A scratch host of that
/// build runs 10 sessions (4 idle shells, 4 steady printers, a full-screen program redrawing, one that prints 20,000
/// lines once); it prints the memory of the host and of each parser, and their CPU while idle and while printing.
struct ParserCostTests {
    static let binary = ProcessInfo.processInfo.environment["VIBESWITCHER_MEASURE_HOST"]

    static let printer = "read go; i=0; while :; do i=$((i+1)); echo \"line $i: the quick brown fox jumps over the lazy dog, again and again\"; sleep 0.02; done"
    static let fullScreen = "read go; i=0; printf '\\033[?1049h'; while :; do i=$((i+1)); r=1; while [ $r -le 23 ]; do "
        + "printf '\\033[%d;1H\\033[7mrow %d\\033[0m frame %d \\033[38;5;%dmcolour\\033[0m' $r $r $i $((r*7)); r=$((r+1)); done; sleep 0.1; done"
    static let burst = "read go; seq 1 20000 | sed 's/$/ a longer line that fills most of an eighty column terminal, padding/'; \(keepRunning)"

    struct Sample {
        var rss: Int
        var footprint: Int
        var cpu: TimeInterval
    }

    /// RSS (KB), footprint (KB) and CPU time so far of `pid`.
    static func sample(_ pid: pid_t) -> Sample {
        let ps = run("/bin/ps", ["-o", "rss=,time=", "-p", String(pid)]).split(whereSeparator: \.isWhitespace)
        let rss = ps.first.flatMap { Int($0) } ?? 0
        // "M:SS.ss" or "H:MM:SS.ss"
        let cpu = ps.dropFirst().first.map { $0.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) } } ?? 0
        let footprint = run("/usr/bin/footprint", [String(pid)]).components(separatedBy: "Footprint: ").dropFirst().first.map { text -> Int in
            let parts = text.split(separator: " ")
            let value = Double(parts.first ?? "") ?? 0
            switch parts.dropFirst().first {
            case "MB"?: return Int(value * 1024)
            case "GB"?: return Int(value * 1024 * 1024)
            case "B"?: return Int(value / 1024)
            default: return Int(value)
            }
        } ?? 0
        return Sample(rss: rss, footprint: footprint, cpu: cpu)
    }

    static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output
    }

    static func parsers(of host: pid_t) -> [pid_t] {
        run("/bin/ps", ["-ax", "-o", "pid=,ppid=,command="]).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, pid_t(fields[1]) == host, fields[2].contains("--parse-session") else { return nil }
            return pid_t(fields[0])
        }
    }

    @Test(.enabled(if: binary != nil)) func measure() throws {
        let binary = try #require(Self.binary)
        let dir = "/tmp/vshm-\(UUID().uuidString.prefix(8))", home = dir + "/home", socket = dir + "/h.sock"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let host = Process()
        host.executableURL = URL(fileURLWithPath: binary)
        host.arguments = ["--socket", socket, "--lock", dir + "/h.lock", "--idle-exit", "600", "--log", dir + "/session.log"]
        host.environment = ["HOME": home, "CFFIXED_USER_HOME": home, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "TMPDIR": dir + "/"]
        host.standardError = FileHandle.nullDevice
        try TestHosts.run(host)
        var sessions: [HostSession] = []
        defer {
            for session in sessions where kill(session.childPID, 0) == 0 { kill(-session.childPID, SIGKILL) }
            TestHosts.end(host)
            try? FileManager.default.removeItem(atPath: dir)
        }
        #expect(eventually { FileManager.default.fileExists(atPath: socket) })
        let client = try TestClient(socket: socket)
        let commands: [String?] = [nil, nil, nil, nil, Self.printer, Self.printer, Self.printer, Self.printer, Self.fullScreen, Self.burst]
        sessions = try commands.map { try client.spawn($0) }
        sessions.forEach { client.attach($0.id) }
        let pid = host.processIdentifier
        let hasParsers = !Self.parsers(of: pid).isEmpty
        #expect(eventually { !hasParsers || Self.parsers(of: pid).count == sessions.count })

        func measure(_ phase: String, seconds: TimeInterval = 10) {
            let processes = [pid] + Self.parsers(of: pid)
            let before = processes.map(Self.sample)
            Thread.sleep(forTimeInterval: seconds)
            let after = processes.map(Self.sample)
            let cpu = zip(before, after).map { ($1.cpu - $0.cpu) / seconds * 100 }
            let parserRSS = after.dropFirst().map(\.rss), parserFootprint = after.dropFirst().map(\.footprint)
            var lines = ["[\(phase)] \(binary)",
                         String(format: "  host: RSS %.1f MB, footprint %.1f MB, CPU %.1f%%", Double(after[0].rss) / 1024, Double(after[0].footprint) / 1024, cpu[0])]
            if !parserRSS.isEmpty {
                lines.append("  parsers (\(parserRSS.count)): RSS MB " + parserRSS.map { String(format: "%.1f", Double($0) / 1024) }.joined(separator: " "))
                lines.append("  parsers: footprint MB " + parserFootprint.map { String(format: "%.1f", Double($0) / 1024) }.joined(separator: " "))
                lines.append(String(format: "  parsers: CPU %.1f%% together (max one %.1f%%)", cpu.dropFirst().reduce(0, +), cpu.dropFirst().max() ?? 0))
            }
            lines.append(String(format: "  total host+parsers: RSS %.1f MB, footprint %.1f MB, CPU %.1f%%",
                                Double(after.map(\.rss).reduce(0, +)) / 1024, Double(after.map(\.footprint).reduce(0, +)) / 1024, cpu.reduce(0, +)))
            print(lines.joined(separator: "\n"))
        }

        Thread.sleep(forTimeInterval: 3)
        measure("idle, 10 sessions")
        for session in sessions[4...] { client.send(.input(id: session.id, bytes: Data("go\r".utf8), reply: false)) }
        Thread.sleep(forTimeInterval: 3)
        measure("printing (4 printers, a full-screen redraw, after a 20,000-line burst)")
    }
}
