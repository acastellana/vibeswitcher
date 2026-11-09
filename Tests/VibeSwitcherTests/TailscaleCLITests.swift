import Foundation
import Testing
@testable import VibeSwitcher

/// `TailscaleCLI` against a fake `tailscale` (`FakeTailscale`): each way setup goes wrong, what it says, and that a
/// mapping that isn't ours is left alone. No real `tailscale` runs here.
extension TailscaleFakeTests { @Suite struct TailscaleCLITests {
    private let scratch = Scratch()
    private let target = "http://127.0.0.1:47823"
    private let versionWarning = #"Warning: client version "1.104.2" != tailscaled server version "1.102.4""# + "\n"

    @Test func notInstalledIsSaidPlainlyAndRunsNothing() throws {
        let fake = try FakeTailscale(scratch: scratch)
        fake.uninstall()
        #expect(TailscaleCLI.executable == nil)
        guard case .failure(.notInstalled) = TailscaleCLI.status() else { Issue.record("not .notInstalled"); return }
        #expect(TailscaleCLI.Failure.notInstalled.description.contains("Install Tailscale"))
        #expect(fake.calls.isEmpty)
    }

    /// The Tailscale service isn't running: the CLI's own words, behind the version warning this Mac really prints.
    @Test func notRunningIsToldApartFromALoggedOutOne() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.statusFails(stderr: versionWarning + "failed to connect to local Tailscale service; is Tailscale running?\n")
        guard case .failure(let failure) = TailscaleCLI.status() else { Issue.record("not a failure"); return }
        #expect(failure.description == TailscaleCLI.Failure.notRunning.description, "\(failure)")
        #expect(fake.calls == ["1|status --json"], "and always with TAILSCALE_BE_CLI=1")
    }

    @Test(arguments: ["NeedsLogin", "Stopped", "NoState", "Starting"])
    func loggedOutOrStoppedIsNotRunning(backend: String) throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.status(backend: backend)
        guard case .failure(.notRunning) = TailscaleCLI.status() else { Issue.record("not .notRunning"); return }
    }

    @Test func httpsOffIsReported() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.status(backend: "Running", https: false)
        let status = try TailscaleCLI.status().get()
        #expect(!status.httpsAvailable)
        #expect(status.dnsName == FakeTailscale.host, "the trailing dot goes")
        #expect(status.login == FakeTailscale.login)
    }

    @Test func aFreePortIsMappedAndChecked() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.onServe(leaves: FakeTailscale.proxy(target))
        #expect(TailscaleCLI.startServing(host: FakeTailscale.host, localTarget: target) == nil)
        #expect(fake.arguments == ["serve status --json", "serve --bg --https=8443 \(target)", "serve status --json"])
    }

    /// A crash or restart leaves the mapping behind: it's ours, so it's kept and nothing is re-run.
    @Test func aMappingLeftBehindByACrashIsReused() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.served(FakeTailscale.proxy(target))
        #expect(TailscaleCLI.startServing(host: FakeTailscale.host, localTarget: target) == nil)
        #expect(!fake.ran("serve --bg"))
    }

    @Test func anotherProxyOnThePortIsPortInUse() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.served(FakeTailscale.proxy("http://127.0.0.1:3000"))
        let failure = TailscaleCLI.startServing(host: FakeTailscale.host, localTarget: target)
        guard case .portInUse(8443, "http://127.0.0.1:3000")? = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(failure!.description.contains("--https=8443 off"), "says how to free it")
        #expect(!fake.ran("serve --bg"))
    }

    /// `tailscale serve` replaces a `/` handler without asking, and adds beside other mounts: these must not look free.
    @Test(arguments: [#""Path":"/Users/me/site""#, #""Text":"hello""#])
    func aFileOrTextServerOnThePortIsPortInUse(handler: String) throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.served(FakeTailscale.web(handler: handler))
        let failure = TailscaleCLI.startServing(host: FakeTailscale.host, localTarget: target)
        guard case .portInUse(8443, _)? = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(!fake.ran("serve --bg"))
    }

    @Test func aHandlerOnASubPathIsPortInUse() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.served(FakeTailscale.web(mount: "/api", handler: #""Proxy":"http://127.0.0.1:3000""#))
        let failure = TailscaleCLI.startServing(host: FakeTailscale.host, localTarget: target)
        guard case .portInUse(8443, _)? = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(failure!.description.contains("--set-path=/api off"), "\(failure!)")
        #expect(!fake.ran("serve --bg"))
    }

    @Test func aTCPForwardOnThePortIsPortInUse() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.served(#"{"TCP":{"8443":{"TCPForward":"127.0.0.1:22"}}}"#)
        let failure = TailscaleCLI.startServing(host: FakeTailscale.host, localTarget: target)
        guard case .portInUse(8443, _)? = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(failure!.description.contains("--tcp=8443 off"), "\(failure!)")
        #expect(!fake.ran("serve --bg"))
    }

    /// Couldn't tell what's on the port: nothing is overwritten.
    @Test func anUnreadableServeConfigOverwritesNothing() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.servedFails()
        let failure = TailscaleCLI.startServing(host: FakeTailscale.host, localTarget: target)
        guard case .command? = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(!fake.ran("serve --bg"))
    }

    /// Serve not enabled for the tailnet: the CLI says where to enable it on stdout, and the version warning is all
    /// that's on stderr. What to do must reach the screen.
    @Test func whatTheCLISaysToDoIsNotHiddenByItsVersionWarning() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        let enable = "Serve is not enabled on your tailnet.\nTo enable, visit:\n\n  https://login.tailscale.com/f/serve?node=abc\n"
        fake.onServeFails(stdout: enable, stderr: versionWarning)
        let failure = try #require(TailscaleCLI.startServing(host: FakeTailscale.host, localTarget: target))
        #expect(failure.description.contains("https://login.tailscale.com/f/serve?node=abc"), "\(failure)")
        #expect(!failure.description.contains("client version"), "\(failure)")
    }

    @Test func stoppingRemovesOurMapping() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.served(FakeTailscale.proxy(target))
        TailscaleCLI.stopServing(host: FakeTailscale.host, localTarget: target)
        #expect(fake.ran("serve --https=8443 off"))
    }

    @Test func stoppingLeavesSomeoneElsesMapping() throws {
        let fake = try FakeTailscale(scratch: scratch)
        defer { fake.uninstall() }
        fake.served(FakeTailscale.proxy("http://127.0.0.1:3000"))
        TailscaleCLI.stopServing(host: FakeTailscale.host, localTarget: target)
        #expect(!fake.ran("serve --https=8443 off"))
    }
} }
