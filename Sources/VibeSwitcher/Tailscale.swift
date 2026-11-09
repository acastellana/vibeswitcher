import Foundation

/// Talks to the Tailscale CLI: who this Mac is on the tailnet, and the `tailscale serve` mapping that
/// makes the loopback-only Phone Access server reachable from your own devices (and nothing else).
enum TailscaleCLI {
    struct Status: Equatable {
        /// e.g. "my-mac.tail1234.ts.net"
        var dnsName: String
        /// The Tailscale account this Mac is logged in as; only requests from it are accepted.
        var login: String
        var httpsAvailable: Bool
    }

    enum Failure: Error, CustomStringConvertible {
        case notInstalled
        case notRunning
        case httpsDisabled
        case portInUse(port: Int, target: String)
        case command(String)

        var description: String {
            switch self {
            case .notInstalled: return "Tailscale isn't installed on this Mac. Install Tailscale from tailscale.com, log in, and this connects by itself."
            case .notRunning: return "Tailscale isn't connected. Open Tailscale and log in."
            case .httpsDisabled: return "Turn on HTTPS certificates for your tailnet (admin console › DNS › HTTPS Certificates)."
            case .portInUse(let port, let target):
                return "Port \(port) is already served by Tailscale (\(target)). Stop that, or run \(Self.freeing(port: port, target: target)), and this connects by itself."
            case .command(let message): return "Tailscale: \(message)"
            }
        }

        /// The command that frees a port, for what `servedTargets` said is on it: each kind takes its own.
        private static func freeing(port: Int, target: String) -> String {
            if target.hasPrefix("a TCP forward") { return "tailscale serve --tcp=\(port) off" }
            if let mount = target.range(of: " at /", options: .backwards), mount.upperBound < target.endIndex {
                return "tailscale serve --https=\(port) --set-path=/\(target[mount.upperBound...]) off"
            }
            return "tailscale serve --https=\(port) off"
        }
    }

    #if DEBUG
    /// Tests: what to run instead of looking for Tailscale (`.some(nil)`: not installed). Once a test sets this, the
    /// real CLI can't run, whatever is on the Mac: every call goes through `executable`.
    private static let testExecutable = NSLock()
    private static var testExecutablePath: String??
    static var executableForTests: String?? {
        get { testExecutable.withLock { testExecutablePath } }
        set { testExecutable.withLock { testExecutablePath = newValue } }
    }
    #endif

    static var executable: String? {
        #if DEBUG
        if let override = executableForTests { return override }
        #endif
        return ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func status() -> Result<Status, Failure> {
        guard executable != nil else { return .failure(.notInstalled) }
        let result = run(["status", "--json"])
        // Tell "couldn't ask Tailscale" apart from "Tailscale says it isn't connected".
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let detail = saying(result)
            // The service itself is down (the CLI's own words): the same answer as logged out, open Tailscale.
            if detail.localizedCaseInsensitiveContains("failed to connect to local") { return .failure(.notRunning) }
            return .failure(.command("couldn't read its status (\(detail.isEmpty ? "exit \(result.status)" : String(detail.prefix(160))))"))
        }
        guard json["BackendState"] as? String == "Running",
              let me = json["Self"] as? [String: Any],
              let dnsName = (me["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              let userID = me["UserID"] as? Int,
              let users = json["User"] as? [String: Any], let user = users["\(userID)"] as? [String: Any],
              let login = user["LoginName"] as? String
        else { return .failure(.notRunning) }
        let certDomains = json["CertDomains"] as? [String] ?? []
        return .success(Status(dnsName: dnsName, login: login, httpsAvailable: certDomains.contains(dnsName)))
    }

    /// What each of this Mac's ports serves (port → what), or nil if it can't be read. Every port in use is here, not
    /// only those proxying `/`: `tailscale serve` replaces a `/` handler without asking and adds beside other paths, so
    /// a port that looks free here gets overwritten. A proxy of `/` reads as its target, the one thing that can be ours.
    static func servedTargets(host: String, timeout: TimeInterval = 10) -> [Int: String]? {
        let result = run(["serve", "status", "--json"], timeout: timeout)
        guard result.status == 0, let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var targets: [Int: String] = [:]
        for (key, value) in json["Web"] as? [String: Any] ?? [:] {
            guard key.hasPrefix("\(host):"), let port = Int(key.dropFirst(host.count + 1)) else { continue }
            targets[port] = served(by: (value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:])
        }
        for (key, value) in json["TCP"] as? [String: Any] ?? [:] {
            guard let port = Int(key), let forward = (value as? [String: Any])?["TCPForward"] as? String else { continue }
            targets[port] = "a TCP forward to \(forward)"
        }
        return targets
    }

    /// One web port's handlers, in words: `/`'s proxy target as it is, anything else as what it is and where.
    private static func served(by handlers: [String: Any]) -> String {
        if let proxy = (handlers["/"] as? [String: Any])?["Proxy"] as? String { return proxy }
        guard let (mount, value) = handlers.sorted(by: { $0.key < $1.key }).first, let handler = value as? [String: Any] else {
            return "another web server"
        }
        if let proxy = handler["Proxy"] as? String { return "\(proxy) at \(mount)" }
        if let path = handler["Path"] as? String { return "the files in \(path) at \(mount)" }
        return handler["Text"] != nil ? "a text reply at \(mount)" : "another web server at \(mount)"
    }

    /// What one HTTPS port currently proxies to, if anything.
    static func servedTarget(host: String, httpsPort: Int = PhoneAccess.httpsPort, timeout: TimeInterval = 10) -> String? {
        servedTargets(host: host, timeout: timeout)?[httpsPort]
    }

    /// Maps https://<this mac>:<httpsPort> on the tailnet to a loopback server. Never `funnel`: tailnet only.
    static func startServing(host: String, httpsPort: Int = PhoneAccess.httpsPort, localTarget: String) -> Failure? {
        // Couldn't tell what's on the port: nothing is overwritten on a guess.
        guard let served = servedTargets(host: host) else { return .command("couldn't read which ports it serves") }
        if let existing = served[httpsPort] {
            return existing == localTarget ? nil : .portInUse(port: httpsPort, target: existing)
        }
        let result = run(["serve", "--bg", "--https=\(httpsPort)", localTarget])
        guard result.status == 0 else {
            let detail = saying(result)
            return .command(detail.isEmpty ? "tailscale serve didn't answer (exit \(result.status))" : detail)
        }
        return servedTarget(host: host, httpsPort: httpsPort) == localTarget ? nil : .command("serve config didn't take effect")
    }

    /// Removes our mappings (port → our local target), each only if it's still ours. One status read.
    /// `timeout` bounds the whole call, not each command (quitting waits for it).
    static func stopServing(host: String, mappings: [Int: String], timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        guard let served = servedTargets(host: host, timeout: timeout) else { return }
        for (port, target) in mappings.sorted(by: { $0.key < $1.key }) where served[port] == target {
            let left = deadline.timeIntervalSinceNow
            guard left > 0.2 else { return }
            _ = run(["serve", "--https=\(port)", "off"], timeout: left)
        }
    }

    static func stopServing(host: String, localTarget: String, timeout: TimeInterval = 10) {
        stopServing(host: host, mappings: [PhoneAccess.httpsPort: localTarget], timeout: timeout)
    }

    /// What a failed call said: both streams (a prompt to enable Serve is on stdout), without the CLI's version warning.
    private static func saying(_ result: (output: String, error: String, status: Int32)) -> String {
        [result.error, result.output].map { text in
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("Warning: client version") }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func run(_ arguments: [String], timeout: TimeInterval = 10) -> (output: String, error: String, status: Int32) {
        guard let executable else { return ("", "not installed", -1) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // The Mac app's binary is both the GUI and the CLI, and decides from its environment. Launched
        // from Finder or at login (no terminal), it tries to start the GUI instead and fails.
        var environment = ProcessInfo.processInfo.environment
        environment["TAILSCALE_BE_CLI"] = "1"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return ("", "\(error)", -1) }
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        watchdog.cancel()
        return (String(data: outputData, encoding: .utf8) ?? "", String(data: errorData, encoding: .utf8) ?? "",
                process.terminationStatus)
    }
}
