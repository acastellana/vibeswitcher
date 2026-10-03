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
            case .notInstalled: return "Tailscale isn't installed on this Mac."
            case .notRunning: return "Tailscale isn't connected. Open Tailscale and log in."
            case .httpsDisabled: return "Turn on HTTPS certificates for your tailnet (admin console › DNS › HTTPS Certificates)."
            case .portInUse(let port, let target): return "Port \(port) is already served by Tailscale (to \(target))."
            case .command(let message): return "Tailscale: \(message)"
            }
        }
    }

    static var executable: String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func status() -> Result<Status, Failure> {
        guard executable != nil else { return .failure(.notInstalled) }
        let result = run(["status", "--json"])
        // Tell "couldn't ask Tailscale" apart from "Tailscale says it isn't connected".
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let detail = (result.error.isEmpty ? result.output : result.error).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// What each of this Mac's HTTPS ports proxies to (port → target), or nil if it can't be read.
    static func servedTargets(host: String, timeout: TimeInterval = 10) -> [Int: String]? {
        let result = run(["serve", "status", "--json"], timeout: timeout)
        guard result.status == 0, let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var targets: [Int: String] = [:]
        for (key, value) in json["Web"] as? [String: Any] ?? [:] {
            guard key.hasPrefix("\(host):"), let port = Int(key.dropFirst(host.count + 1)),
                  let site = value as? [String: Any], let handlers = site["Handlers"] as? [String: Any],
                  let root = handlers["/"] as? [String: Any], let proxy = root["Proxy"] as? String else { continue }
            targets[port] = proxy
        }
        return targets
    }

    /// What one HTTPS port currently proxies to, if anything.
    static func servedTarget(host: String, httpsPort: Int = PhoneAccess.httpsPort, timeout: TimeInterval = 10) -> String? {
        servedTargets(host: host, timeout: timeout)?[httpsPort]
    }

    /// Maps https://<this mac>:<httpsPort> on the tailnet to a loopback server. Never `funnel`: tailnet only.
    static func startServing(host: String, httpsPort: Int = PhoneAccess.httpsPort, localTarget: String) -> Failure? {
        if let existing = servedTarget(host: host, httpsPort: httpsPort) {
            return existing == localTarget ? nil : .portInUse(port: httpsPort, target: existing)
        }
        let result = run(["serve", "--bg", "--https=\(httpsPort)", localTarget])
        guard result.status == 0 else { return .command(result.error.isEmpty ? result.output : result.error) }
        return servedTarget(host: host, httpsPort: httpsPort) == localTarget ? nil : .command("serve config didn't take effect")
    }

    /// Removes our mappings (port → our local target), each only if it's still ours. One status read.
    static func stopServing(host: String, mappings: [Int: String], timeout: TimeInterval = 10) {
        guard let served = servedTargets(host: host, timeout: timeout) else { return }
        for (port, target) in mappings where served[port] == target {
            _ = run(["serve", "--https=\(port)", "off"], timeout: timeout)
        }
    }

    static func stopServing(host: String, localTarget: String, timeout: TimeInterval = 10) {
        stopServing(host: host, mappings: [PhoneAccess.httpsPort: localTarget], timeout: timeout)
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
