import Darwin
import AppKit
import Foundation
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// Phone Access from off to a paired phone against a fake `tailscale` (`FakeTailscale`): the real start path, on a
/// loopback port of its own, with defaults and files in scratch. No real `tailscale` runs; nothing is typed.
extension TailscaleFakeTests { @MainActor @Suite struct PhoneTailscaleFlowTests {
    private let scratch = Scratch()

    /// A loopback port nothing holds right now, below the range the system hands out for port 0: other suites ask for
    /// one of those and bind it a moment later, and this one taking it in between fails them.
    private func freePort() throws -> UInt16 {
        for _ in 0..<100 {
            let port = UInt16.random(in: 40_000..<49_000)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            let length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
            }
            if bound == 0 { return port }
        }
        throw CancellationError()
    }

    private func access() throws -> PhoneAccess {
        AppStatus.enabled = false
        let access = PhoneAccess(store: SessionStore(), defaults: scratch.defaults("phone-flow"))
        access.listenPort = try freePort()
        return access
    }

    private func target(_ access: PhoneAccess) -> String { "http://127.0.0.1:\(access.listenPort)" }

    private func waitOn(_ access: PhoneAccess) async -> Bool { await until { access.state == .on } }

    /// Runs a health check and waits for it to finish, on the main thread too.
    private func checked(_ access: PhoneAccess) async -> Bool {
        access.checkHealth()
        guard await until({ !access.healthCheckRunningForTests }) else { return false }
        // What the check queued (restoring a mapping) has run too.
        var drained = false
        access.afterControlForTests { drained = true }
        return await until { drained }
    }

    private func finish(_ access: PhoneAccess, _ fake: FakeTailscale) async {
        access.enabled = false
        // Its queued `serve off` runs before the fake goes.
        _ = await until { fake.ran("serve --https=8443 off") || !fake.ran("serve --bg") }
        fake.uninstall()
    }

    // MARK: Off to on

    @Test func fromOffToOnMapsThePortAndShowsTheAddress() async throws {
        let fake = try FakeTailscale(scratch: scratch)
        let access = try access()
        fake.onServe(leaves: FakeTailscale.proxy(target(access)))
        access.enabled = true
        #expect(await waitOn(access))
        #expect(access.url?.absoluteString == "https://\(FakeTailscale.host):8443/")
        #expect(fake.calls.allSatisfy { $0.hasPrefix("1|") }, "TAILSCALE_BE_CLI=1 on every call")
        await finish(access, fake)
    }

    @Test func eachSetupProblemSaysWhatToDo() async throws {
        let fake = try FakeTailscale(scratch: scratch)
        let access = try access()
        fake.status(backend: "NeedsLogin")
        access.enabled = true
        #expect(await until { access.state == .failed(TailscaleCLI.Failure.notRunning.description) })
        fake.status(backend: "Running", https: false)
        access.checkHealth()
        #expect(await until { access.state == .failed(TailscaleCLI.Failure.httpsDisabled.description) })
        fake.status(backend: "Running")
        fake.served(FakeTailscale.proxy("http://127.0.0.1:3000"))
        access.checkHealth()
        let inUse = TailscaleCLI.Failure.portInUse(port: 8443, target: "http://127.0.0.1:3000").description
        #expect(await until { access.state == .failed(inUse) })
        #expect(!fake.ran("serve --bg"), "someone else's mapping is left alone")
        await finish(access, fake)
    }

    /// Tailscale comes up after VibeSwitcher at login: the switch stays on and the next check connects.
    @Test func tailscaleComingUpLaterConnectsByItself() async throws {
        let fake = try FakeTailscale(scratch: scratch)
        let access = try access()
        fake.statusFails(stderr: "failed to connect to local Tailscale service; is Tailscale running?\n")
        access.enabled = true
        #expect(await until { if case .failed = access.state { return true } else { return false } })
        #expect(access.enabled)
        fake.status(backend: "Running")
        fake.onServe(leaves: FakeTailscale.proxy(target(access)))
        access.checkHealth()
        #expect(await waitOn(access))
        await finish(access, fake)
    }

    // MARK: Staying on

    /// One unreadable `serve status` (a loaded Mac, a slow daemon) isn't a missing mapping: nothing is re-run and the
    /// phone keeps working.
    @Test func anUnreadableServeConfigDoesNotDropAWorkingConnection() async throws {
        let fake = try FakeTailscale(scratch: scratch)
        let access = try access()
        fake.onServe(leaves: FakeTailscale.proxy(target(access)))
        access.enabled = true
        #expect(await waitOn(access))
        let mapped = fake.arguments.filter { $0.hasPrefix("serve --bg") }.count
        fake.servedFails()
        #expect(await checked(access))
        #expect(access.state == .on)
        #expect(fake.arguments.filter { $0.hasPrefix("serve --bg") }.count == mapped)
        fake.served(FakeTailscale.proxy(target(access)))   // readable again, so turning off can take it down
        await finish(access, fake)
    }

    @Test func aRemovedMappingIsRestored() async throws {
        let fake = try FakeTailscale(scratch: scratch)
        let access = try access()
        fake.onServe(leaves: FakeTailscale.proxy(target(access)))
        access.enabled = true
        #expect(await waitOn(access))
        fake.served("{}")
        #expect(await checked(access))
        #expect(await until { fake.arguments.filter { $0.hasPrefix("serve --bg") }.count == 2 })
        #expect(access.state == .on)
        await finish(access, fake)
    }

    /// A new tailnet name or account shows after two checks in a row (one slow check isn't worth a restart).
    @Test func aChangedNameOrLoginRestartsOnTheNewOne() async throws {
        let fake = try FakeTailscale(scratch: scratch)
        let access = try access()
        fake.onServe(leaves: FakeTailscale.proxy(target(access)))
        access.enabled = true
        #expect(await waitOn(access))
        let renamed = "mac.tail9999.ts.net"
        fake.status(backend: "Running", dnsName: renamed, login: "other@example.com")
        fake.onServe(leaves: FakeTailscale.proxy(target(access)).replacingOccurrences(of: FakeTailscale.host, with: renamed))
        #expect(await checked(access))
        #expect(access.state == .on, "one check isn't enough")
        access.checkHealth()
        #expect(await until { access.url?.host == renamed && access.state == .on })
        await finish(access, fake)
    }

    // MARK: Off and quitting

    @Test func turningOffRemovesTheMapping() async throws {
        let fake = try FakeTailscale(scratch: scratch)
        let access = try access()
        fake.onServe(leaves: FakeTailscale.proxy(target(access)))
        access.enabled = true
        #expect(await waitOn(access))
        access.enabled = false
        #expect(access.state == .off)
        #expect(await until { fake.ran("serve --https=8443 off") })
        fake.uninstall()
    }

    @Test func quittingRemovesTheMapping() async throws {
        let fake = try FakeTailscale(scratch: scratch)
        let access = try access()
        fake.onServe(leaves: FakeTailscale.proxy(target(access)))
        access.enabled = true
        #expect(await waitOn(access))
        access.shutdown()
        #expect(fake.ran("serve --https=8443 off"))
        fake.uninstall()
    }

    // MARK: Pairing

    private let owner = TailscaleCLI.Status(dnsName: FakeTailscale.host, login: FakeTailscale.login, httpsAvailable: true)

    private func request(_ method: String, _ path: String, body: String = "", token: String? = nil) throws -> HTTPRequest {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(FakeTailscale.host):8443\r\nTailscale-User-Login: \(FakeTailscale.login)\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        head += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let parsed) = HTTPParser.parse(Data(head.utf8)) else { throw CancellationError() }
        return parsed
    }

    private func send(_ access: PhoneAccess, _ method: String, _ path: String, body: String = "",
                      token: String? = nil) throws -> (status: Int, json: [String: Any]) {
        var answer: HTTPResponse?
        access.handleForTests(try request(method, path, body: body, token: token)) { answer = $0 }
        let response = try #require(answer)
        return (response.status, (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:])
    }

    private func pairBody(_ code: String) -> String { #"{"code":"\#(code)","name":"Pixel"}"# }

    private func served() throws -> PhoneAccess {
        let access = try access()
        access.serveForTests(owner)
        // The scratch home's devices.json is shared with the suites before this one.
        for device in access.devices { access.remove(device) }
        return access
    }

    @Test func aTypedCodePairsOnceInAnyCaseOrGrouping() throws {
        let access = try served()
        access.setPairingForTests(PairingCode(code: "ABCDEFGH", expires: Date().addingTimeInterval(600)))
        let first = try send(access, "POST", "/api/pair", body: pairBody("abcd-efgh"))
        #expect(first.status == 200)
        #expect(first.json["token"] is String)
        #expect(access.pairing == nil, "single use")
        #expect(access.devices.map(\.name) == ["Pixel"])
        #expect(try send(access, "POST", "/api/pair", body: pairBody("ABCDEFGH")).status == 403)
    }

    @Test func theQRCodeCarriesTheCodeOnTheFragmentOnly() throws {
        let access = try served()
        access.setPairingForTests(PairingCode(code: "ABCDEFGH", expires: Date().addingTimeInterval(600)))
        access.setURLForTests(URL(string: "https://\(FakeTailscale.host):8443/"))
        #expect(access.pairingURL?.absoluteString == "https://\(FakeTailscale.host):8443/#pair=ABCDEFGH")
    }

    @Test func anExpiredCodeSaysToStartAgain() throws {
        let access = try served()
        access.setPairingForTests(PairingCode(code: "ABCDEFGH", expires: Date().addingTimeInterval(-1)))
        let answer = try send(access, "POST", "/api/pair", body: pairBody("ABCDEFGH"))
        #expect(answer.status == 403)
        #expect((answer.json["error"] as? String)?.contains("Start pairing again") == true, "\(answer.json)")
        #expect(access.devices.isEmpty)
    }

    @Test func aWrongCodeIsNotCalledExpired() throws {
        let access = try served()
        access.setPairingForTests(PairingCode(code: "ABCDEFGH", expires: Date().addingTimeInterval(600)))
        let answer = try send(access, "POST", "/api/pair", body: pairBody("WRONGCOD"))
        #expect(answer.status == 403)
        #expect((answer.json["error"] as? String)?.contains("expired") == false, "\(answer.json)")
    }

    @Test func theFifthWrongTryEndsTheCode() throws {
        let access = try served()
        access.setPairingForTests(PairingCode(code: "ABCDEFGH", expires: Date().addingTimeInterval(600)))
        for _ in 1...4 { #expect(try send(access, "POST", "/api/pair", body: pairBody("WRONGCOD")).status == 403) }
        #expect(access.pairing != nil)
        let last = try send(access, "POST", "/api/pair", body: pairBody("WRONGCOD"))
        #expect((last.json["error"] as? String)?.contains("Too many") == true)
        #expect(access.pairing == nil)
        #expect(try send(access, "POST", "/api/pair", body: pairBody("ABCDEFGH")).status == 403, "the right code no longer works")
    }

    private func pairedToken(_ access: PhoneAccess) throws -> String {
        access.setPairingForTests(PairingCode(code: "ABCDEFGH", expires: Date().addingTimeInterval(600)))
        return try #require(try send(access, "POST", "/api/pair", body: pairBody("ABCDEFGH")).json["token"] as? String)
    }

    @Test func aPhoneRemovedInSettingsIsToldItIsUnpaired() throws {
        let access = try served()
        let token = try pairedToken(access)
        #expect(try send(access, "GET", "/api/state", token: token).status == 200)
        access.remove(try #require(access.devices.first))
        let after = try send(access, "GET", "/api/state", token: token)
        #expect(after.status == 401)
        #expect(after.json["error"] as? String == PhoneAccess.unpaired)
    }

    @Test func unpairingFromThePhoneEndsItsAccess() throws {
        let access = try served()
        let token = try pairedToken(access)
        #expect(try send(access, "POST", "/api/unpair", body: "{}", token: token).status == 200)
        #expect(access.devices.isEmpty)
        #expect(try send(access, "GET", "/api/state", token: token).status == 401)
    }

    /// A devices file that can't be read says nothing about who's paired: no phone is told to forget its token, nobody
    /// gets in, the file isn't overwritten, and once it reads again the same phone works.
    @Test func anUnreadableDevicesFileNeitherUnpairsNorAdmits() throws {
        let file = scratch.adopt(scratch.url("devices").appendingPathExtension("json"))
        try Data("{ not json".utf8).write(to: file)
        AppStatus.enabled = false
        let access = PhoneAccess(store: SessionStore(), defaults: scratch.defaults("phone-flow"), devicesFile: file)
        access.listenPort = try freePort()
        access.serveForTests(owner)
        let token = "a-token-of-a-phone-paired-before"
        let answer = try send(access, "GET", "/api/state", token: token)
        #expect(answer.status == 503, "\(answer)")
        #expect(answer.status != 401, "a 401 makes the phone forget a good token")
        #expect((answer.json["error"] as? String)?.isEmpty == false)
        access.setPairingForTests(PairingCode(code: "ABCDEFGH", expires: Date().addingTimeInterval(600)))
        #expect(try send(access, "POST", "/api/pair", body: pairBody("ABCDEFGH")).status == 503)
        #expect(try Data(contentsOf: file) == Data("{ not json".utf8), "pairing must not overwrite the phones it couldn't read")
        // Readable again (a restored backup, say): the same token works.
        let device = PairedDevice(id: "p", name: "Pixel", tokenHash: RemoteAuth.hash(token), tailscaleLogin: FakeTailscale.login, pairedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([device]).write(to: file)
        #expect(try send(access, "GET", "/api/state", token: token).status == 200)
    }

    /// A folder that can't be searched, or a link to nowhere, is an unreadable file too, not a missing one.
    @Test func aDevicesFileThatCannotBeReachedIsUnreadableToo() throws {
        let folder = scratch.url("devices-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inside = folder.appendingPathComponent("devices.json")
        try Data("[]".utf8).write(to: inside)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let blocked = PhoneAccess(store: SessionStore(), defaults: scratch.defaults("phone-flow"), devicesFile: inside)
        blocked.serveForTests(owner)
        #expect(try send(blocked, "GET", "/api/state", token: "a-paired-token").status == 503)

        let link = scratch.url("devices-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: scratch.url("nowhere").path)
        let dangling = PhoneAccess(store: SessionStore(), defaults: scratch.defaults("phone-flow"), devicesFile: link)
        dangling.serveForTests(owner)
        #expect(try send(dangling, "GET", "/api/state", token: "a-paired-token").status == 503)
    }

    @Test func noDevicesFileIsJustNoPhones() throws {
        let file = scratch.adopt(scratch.url("devices").appendingPathExtension("json"))
        AppStatus.enabled = false
        let access = PhoneAccess(store: SessionStore(), defaults: scratch.defaults("phone-flow"), devicesFile: file)
        access.serveForTests(owner)
        #expect(try send(access, "GET", "/api/state", token: "unknown").status == 401)
    }

    /// Settings › Phone, in a window far off every display, as an accessibility client reads it.
    private func shown(_ access: PhoneAccess) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: NSSize(width: 500, height: 700)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PhoneAccessView(access: access))
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        AXClient.attach(window)   // the tree exists once a client has asked for it
        return window
    }

    /// What `window` says once laid out and drawn (nothing else drives it while the test waits).
    private func says(_ window: NSWindow, _ text: String) -> Bool {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date())
        return AXClient.texts(window).contains { $0.contains(text) }
    }

    /// With Tailscale logged out (or the switch off) is when you may need to remove a lost phone.
    @Test func aPhoneCanBeRemovedWhileTheConnectionIsDown() async throws {
        let access = try served()
        _ = try pairedToken(access)
        access.restartForTests()
        let window = shown(access)
        defer { window.close() }
        #expect(await until(timeout: 60) { says(window, "Pixel") })
    }

    @Test func anExpiredCodeOffersANewOne() async throws {
        let access = try served()
        access.setPairingForTests(PairingCode(code: "ABCDEFGH", expires: Date().addingTimeInterval(-1)))
        access.setURLForTests(URL(string: "https://\(FakeTailscale.host):8443/"))
        let window = shown(access)
        defer { window.close() }
        #expect(await until(timeout: 60) { says(window, "New Code") })
    }

    /// Its Tailscale account changed: the old pairing isn't honoured, and the phone hears how to get back in.
    @Test func aPhonePairedFromAnotherAccountIsRefused() throws {
        let access = try served()
        let token = try pairedToken(access)
        access.serveForTests(.init(dnsName: FakeTailscale.host, login: "other@example.com", httpsAvailable: true))
        var head = "GET /api/state HTTP/1.1\r\nHost: \(FakeTailscale.host):8443\r\nTailscale-User-Login: other@example.com\r\n"
        head += "Authorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n"
        guard case .complete(let parsed) = HTTPParser.parse(Data(head.utf8)) else { throw CancellationError() }
        var answer: HTTPResponse?
        access.handleForTests(parsed) { answer = $0 }
        #expect(answer?.status == 401)
    }
} }
