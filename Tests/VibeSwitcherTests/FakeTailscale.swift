import Foundation
import Testing
@testable import VibeSwitcher

/// The suites that install a `FakeTailscale`, one after another: which executable `TailscaleCLI` runs is one process-wide
/// setting, and Swift Testing runs separate suites at the same time.
@Suite(.serialized) enum TailscaleFakeTests {}

/// A stand-in for the `tailscale` command: a script in scratch that logs each call and answers from files, installed
/// through `TailscaleCLI.executableForTests`. While one exists, and after it goes (`.some(nil)`, not installed), the
/// real CLI can't run: `TailscaleCLI` launches nothing but `executable`.
final class FakeTailscale {
    static let host = "mac.tail1234.ts.net"
    static let login = "me@example.com"

    private let folder: URL

    init(scratch: Scratch) throws {
        folder = scratch.url("fake-tailscale")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("tailscale")
        try """
        #!/bin/sh
        d='\(folder.path)'
        printf '%s|%s\\n' "$TAILSCALE_BE_CLI" "$*" >> "$d/calls"
        case "$*" in
          "status --json") f=status ;;
          "serve status --json") f=served ;;
          "serve --bg --https="*) f=on ;;
          "serve --https="*" off") f=off ;;
          *) f=other ;;
        esac
        [ -f "$d/$f.next" ] && /bin/cp "$d/$f.next" "$d/served.out"
        [ -f "$d/$f.err" ] && /bin/cat "$d/$f.err" >&2
        [ -f "$d/$f.out" ] && /bin/cat "$d/$f.out"
        [ -f "$d/$f.code" ] && exit "$(/bin/cat "$d/$f.code")"
        exit 0

        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        TailscaleCLI.executableForTests = .some(script.path)
        self.status(backend: "Running")
        self.served("{}")
    }

    /// Tests call this at the end: from here on "not installed", so nothing still running can reach a real CLI.
    func uninstall() { TailscaleCLI.executableForTests = .some(nil) }

    private func write(_ text: String, _ name: String) {
        try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func remove(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    /// What `status --json` answers, in the shape the real one has.
    func status(backend: String, https: Bool = true, dnsName: String = FakeTailscale.host, login: String = FakeTailscale.login) {
        let certs = https ? #""CertDomains":["\#(dnsName)"],"# : ""
        write(#"{"BackendState":"\#(backend)",\#(certs)"Self":{"DNSName":"\#(dnsName).","UserID":7},"User":{"7":{"LoginName":"\#(login)"}}}"#, "status.out")
        remove("status.err"); remove("status.code")
    }

    /// `status --json` failing, as when Tailscale doesn't answer.
    func statusFails(stderr: String, code: Int = 1) {
        remove("status.out"); write(stderr, "status.err"); write("\(code)", "status.code")
    }

    /// What `serve status --json` answers.
    func served(_ json: String) { write(json, "served.out"); remove("served.err"); remove("served.code") }

    func servedFails() { remove("served.out"); write("boom\n", "served.err"); write("1", "served.code") }

    /// `serve … <target>` succeeds and leaves `json` as the serve config (nil: leaves it as it was).
    func onServe(leaves json: String?) {
        if let json { write(json, "on.next") } else { remove("on.next") }
        remove("on.err"); remove("on.out"); remove("on.code")
    }

    func onServeFails(stdout: String, stderr: String, code: Int = 1) {
        remove("on.next"); write(stdout, "on.out"); write(stderr, "on.err"); write("\(code)", "on.code")
    }

    func onOff(leaves json: String) { write(json, "off.next") }

    /// The calls so far, each "TAILSCALE_BE_CLI value|arguments".
    var calls: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    var arguments: [String] { calls.map { String($0.drop { $0 != "|" }.dropFirst()) } }

    func ran(_ prefix: String) -> Bool { arguments.contains { $0.hasPrefix(prefix) } }

    /// A serve config with one web handler on `port`.
    static func web(port: Int = 8443, mount: String = "/", handler: String) -> String {
        #"{"TCP":{"\#(port)":{"HTTPS":true}},"Web":{"\#(host):\#(port)":{"Handlers":{"\#(mount)":{\#(handler)}}}}}"#
    }

    static func proxy(_ target: String, port: Int = 8443) -> String { web(port: port, handler: #""Proxy":"\#(target)""#) }
}
