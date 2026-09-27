import AppKit
import CryptoKit
import VibeCore

/// Phone Access: the session list, live screens, replies and notifications on your phone, over
/// Tailscale only.
///
/// Security model:
/// - Off by default. The server listens on 127.0.0.1; `tailscale serve` (never `funnel`) is the only
///   way in, so only devices on your tailnet can reach it, over HTTPS.
/// - Every request must come from this Mac's own Tailscale account (the `Tailscale-User-Login`
///   header set by `tailscale serve`) and, except for pairing, carry a device token.
/// - A device gets its token by pairing with a one-time code shown on the Mac (10 min, 5 tries).
/// - Typing into sessions is a separate switch, off by default. Every pairing and remote input is
///   written to an audit log and announced on the Mac.
/// - Credentials are masked in everything sent to the phone; notifications are end-to-end encrypted.
final class PhoneAccess: ObservableObject {
    static let port: UInt16 = 47823
    static let httpsPort = 8443
    static let localTarget = "http://127.0.0.1:\(port)"

    enum State: Equatable {
        case off, starting, on
        case failed(String)
    }

    @Published private(set) var state: State = .off {
        didSet { AppStatus.extras["phoneAccess"] = "\(state)" }
    }
    @Published private(set) var url: URL?
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var pairing: PairingCode?
    @Published private(set) var recentActivity: [String] = []
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: "phoneAccessEnabled")
            enabled ? start() : stop()
        }
    }
    @Published var inputAllowed: Bool {
        didSet {
            guard inputAllowed != oldValue else { return }
            defaults.set(inputAllowed, forKey: "phoneInputAllowed")
            audit("replies \(inputAllowed ? "allowed" : "blocked")")
        }
    }
    @Published var pushOnlyWhenAway: Bool { didSet { defaults.set(pushOnlyWhenAway, forKey: "phonePushOnlyWhenAway") } }

    /// Announces pairings and remote input on the Mac (title, body).
    var onEvent: ((String, String) -> Void)?

    private let defaults = UserDefaults.standard
    private let store: SessionStore
    private var server: RemoteServer?
    private var tailscale: TailscaleCLI.Status?
    private lazy var vapidKey: P256.Signing.PrivateKey = Self.loadOrCreateVapidKey()
    private var screenCache: [String: (at: Date, text: String)] = [:]
    private var failedAuth: [Date] = []
    /// Typing into tabs, one input at a time.
    private let work = DispatchQueue(label: "vibeswitcher.phone-access", qos: .userInitiated)
    /// Reading screens; separate so a slow Terminal read never holds up a key press.
    private let reads = DispatchQueue(label: "vibeswitcher.phone-access.reads", qos: .userInitiated)
    /// Requests waiting for a screen read already in flight, per tty.
    private var screenWaiters: [String: [(HTTPResponse) -> Void]] = [:]

    init(store: SessionStore) {
        self.store = store
        defaults.register(defaults: ["phonePushOnlyWhenAway": true])
        enabled = defaults.bool(forKey: "phoneAccessEnabled")
        inputAllowed = defaults.bool(forKey: "phoneInputAllowed")
        pushOnlyWhenAway = defaults.bool(forKey: "phonePushOnlyWhenAway")
        devices = Self.loadDevices()
        recentActivity = Self.tailOfAuditLog()
        // Network and Tailscale come back a few seconds after wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.checkHealth() }
        }
    }

    func startIfEnabled() { if enabled { start() } }

    /// Sample state for `--snapshot` (nothing is started, stored or served).
    static func preview(store: SessionStore) -> PhoneAccess {
        let access = PhoneAccess(store: store)
        access.state = .on
        access.url = URL(string: "https://my-mac.tail1234.ts.net:\(httpsPort)/")
        access.pairing = .generate()
        var phone = PairedDevice(id: "p", name: "Pixel", tokenHash: "", tailscaleLogin: "", pairedAt: Date().addingTimeInterval(-86400))
        phone.lastSeen = Date().addingTimeInterval(-120)
        access.devices = [phone]
        access.recentActivity = ["2026-09-27T20:02:14Z  Pixel typed into shop: “run the tests” ⏎",
                                 "2026-09-27T19:59:57Z  paired Pixel"]
        return access
    }

    // MARK: - Lifecycle
    //
    // Every start bumps `generation`. Asynchronous steps belonging to an older start (Tailscale calls,
    // listener callbacks) see a different generation and stand down instead of touching current state.

    private var generation = 0
    private var healthTimer: Timer?
    private var healthCheckRunning = false
    /// Consecutive failed checks; one slow `tailscale status` under load isn't worth a restart.
    private var unhealthyChecks = 0
    /// Tailscale CLI calls, one at a time (a stop must never overtake the start it undoes).
    private let control = DispatchQueue(label: "vibeswitcher.phone-access.control")

    private func isCurrent(_ run: Int) -> Bool { enabled && run == generation }

    /// `quiet`: a background retry; keep showing the last problem instead of flashing "Starting…".
    private func start(quiet: Bool = false) {
        generation += 1
        let run = generation
        server?.stop()
        server = nil
        if !quiet { state = .starting }
        scheduleHealthChecks()
        control.async {
            let status = TailscaleCLI.status()
            DispatchQueue.main.async {
                guard self.isCurrent(run) else { return }
                switch status {
                case .failure(let failure):
                    self.fail(failure.description)
                case .success(let status) where !status.httpsAvailable:
                    self.fail(TailscaleCLI.Failure.httpsDisabled.description)
                case .success(let status):
                    self.tailscale = status
                    self.startListener(run: run, host: status.dnsName, attempt: 1)
                }
            }
        }
    }

    private func startListener(run: Int, host: String, attempt: Int) {
        let server = RemoteServer { [weak self] request, respond in
            DispatchQueue.main.async {
                guard let self else { return respond(.error(503, "unavailable")) }
                self.route(request, respond: respond)
            }
        }
        self.server = server
        server.start(port: Self.port, onReady: { [weak self] in
            guard let self, self.isCurrent(run) else { return server.stop() }
            self.startServing(run: run, host: host)
        }, onFailure: { [weak self] message in
            guard let self, self.isCurrent(run) else { return }
            self.server = nil
            // A copy of the app that is still quitting can hold the port for a moment.
            guard attempt < 5 else { return self.fail(message) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if self.isCurrent(run) { self.startListener(run: run, host: host, attempt: attempt + 1) }
            }
        })
    }

    /// "On" only once both halves exist: the listener is ready and Tailscale points at it.
    private func startServing(run: Int, host: String) {
        control.async {
            let failure = TailscaleCLI.startServing(host: host, localTarget: Self.localTarget)
            DispatchQueue.main.async {
                guard self.isCurrent(run) else {
                    // Turned off while this was in flight: take the mapping back down.
                    if failure == nil, !self.enabled {
                        self.control.async { TailscaleCLI.stopServing(host: host, localTarget: Self.localTarget) }
                    }
                    return
                }
                if let failure { return self.fail(failure.description) }
                self.url = URL(string: "https://\(host):\(Self.httpsPort)/")
                if self.state != .on {
                    self.state = .on
                    self.audit("phone access on (\(host))")
                }
            }
        }
    }

    /// Stays enabled: the health check retries (e.g. Tailscale connects a minute after login).
    private func fail(_ message: String) {
        server?.stop()
        server = nil
        url = nil
        if state != .failed(message) { audit("phone access problem: \(message)") }
        state = .failed(message)
    }

    private func stop() {
        generation += 1
        healthTimer?.invalidate()
        healthTimer = nil
        server?.stop()
        server = nil
        pairing = nil
        state = .off
        url = nil
        if let host = tailscale?.dnsName {
            control.async { TailscaleCLI.stopServing(host: host, localTarget: Self.localTarget) }
        }
        audit("phone access off")
    }

    /// On quit: nothing may keep pointing the tailnet at a port we no longer own.
    func shutdown() {
        generation += 1
        healthTimer?.invalidate()
        server?.stop()
        guard enabled, let host = tailscale?.dnsName else { return }
        TailscaleCLI.stopServing(host: host, localTarget: Self.localTarget, timeout: 3)
    }

    private func scheduleHealthChecks() {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkHealth() }
        healthTimer?.tolerance = 5
    }

    /// Every 30 s and after wake, repairs what can go missing behind our back: Tailscale not connected
    /// yet at login, the serve mapping removed (`tailscale serve reset`, another copy of the app quitting),
    /// the listener gone, or this Mac's tailnet name or account changed.
    func checkHealth() {
        guard enabled, !healthCheckRunning else { return }
        switch state {
        case .off, .starting: return
        case .failed: return start(quiet: true)
        case .on: break
        }
        healthCheckRunning = true
        let run = generation
        let listening = server?.isListening == true
        let known = tailscale
        control.async {
            let status = TailscaleCLI.status()
            let served = (try? status.get()).flatMap { TailscaleCLI.servedTarget(host: $0.dnsName) }
            DispatchQueue.main.async {
                self.healthCheckRunning = false
                guard self.isCurrent(run), self.state == .on else { return }
                guard case .success(let current) = status, current == known, listening else {
                    self.unhealthyChecks += 1
                    guard self.unhealthyChecks >= 2 else { return }
                    self.unhealthyChecks = 0
                    self.audit("phone access restarting (Tailscale or local server changed)")
                    return self.start()
                }
                self.unhealthyChecks = 0
                if served != Self.localTarget {
                    self.audit("tailscale serve mapping was missing; restored")
                    self.startServing(run: run, host: current.dnsName)
                }
            }
        }
    }

    // MARK: - Pairing and devices

    func startPairing() {
        pairing = .generate()
        audit("pairing code shown")
    }

    func cancelPairing() { pairing = nil }

    var pairingURL: URL? {
        guard let url, let pairing else { return nil }
        return URL(string: "\(url.absoluteString)#pair=\(pairing.code)")
    }

    func remove(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        saveDevices()
        audit("removed \(device.name)")
    }

    // MARK: - Routing (main thread)

    private func route(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard state == .on, let owner = tailscale?.login else { return respond(.error(503, "phone access is off")) }
        // Only requests relayed by `tailscale serve` for this Mac's own account.
        guard request.header("tailscale-user-login") == owner else { return respond(.error(403, "not your tailnet account")) }
        if request.method == "GET", let asset = WebAssets.response(for: request.path) { return respond(asset) }
        if request.method == "POST", request.path == "/api/pair" { return respond(pair(request, owner: owner)) }
        guard request.path.hasPrefix("/api/") else { return respond(.error(404, "not found")) }
        if isThrottled { return respond(.error(429, "too many failed attempts; wait a minute")) }
        guard let device = RemoteAuth.authenticate(authorization: request.header("authorization"),
                                                   login: request.header("tailscale-user-login"), devices: devices) else {
            failedAuth.append(Date())
            return respond(.error(401, "this device isn't paired"))
        }
        touch(device)
        switch (request.method, request.path) {
        case ("GET", "/api/state"): respond(.json(stateObject(for: device)))
        case ("GET", "/api/screen"): screen(request.query["tty"] ?? "", respond: respond)
        case ("POST", "/api/input"): input(request, device: device, respond: respond)
        case ("POST", "/api/push"): respond(subscribe(request, device: device))
        case ("POST", "/api/push/test"): respond(testPush(device))
        case ("POST", "/api/unpair"):
            remove(device)
            respond(.json(["ok": true]))
        default: respond(.error(404, "not found"))
        }
    }

    private var isThrottled: Bool {
        failedAuth = failedAuth.filter { $0.timeIntervalSinceNow > -60 }
        return failedAuth.count >= 20
    }

    private func body(_ request: HTTPRequest) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
    }

    private func pair(_ request: HTTPRequest, owner: String) -> HTTPResponse {
        guard var code = pairing else { return .error(403, "No pairing code is active. Start pairing on the Mac.") }
        let candidate = body(request)?["code"] as? String ?? ""
        let matched = code.check(candidate)
        pairing = matched || !code.isUsable ? nil : code
        guard matched else {
            audit("pairing attempt failed")
            return .error(403, code.isUsable ? "Wrong or expired code." : "Too many wrong codes. Start pairing again on the Mac.")
        }
        let rawName = (body(request)?["name"] as? String) ?? "Phone"
        let name = String(rawName.filter { !$0.isNewline }.prefix(40)).trimmingCharacters(in: .whitespaces)
        let token = RemoteAuth.newToken()
        let device = PairedDevice(id: Base64URL.encode(WebPush.randomBytes(9)), name: name.isEmpty ? "Phone" : name,
                                  tokenHash: RemoteAuth.hash(token), tailscaleLogin: owner, pairedAt: Date())
        devices.append(device)
        saveDevices()
        audit("paired \(device.name)")
        onEvent?("\(device.name) paired with VibeSwitcher", "It can now see your sessions. Remove it in Phone Access.")
        return .json(["token": token, "device": ["id": device.id, "name": device.name],
                      "vapidPublicKey": Base64URL.encode(vapidKey.publicKey.x963Representation)])
    }

    private func touch(_ device: PairedDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        let last = devices[index].lastSeen ?? .distantPast
        devices[index].lastSeen = Date()
        if Date().timeIntervalSince(last) > 300 { saveDevices() }
    }

    private func stateObject(for device: PairedDevice) -> [String: Any] {
        let sessions: [[String: Any]] = store.sessions.enumerated().map { index, session in
            var row: [String: Any] = [
                "tty": session.tty, "number": index + 1, "name": Redaction.secrets(in: session.displayName),
                "project": session.project, "agent": session.agent.rawValue, "status": session.status.rawValue,
                "statusLabel": session.status.label, "inTerminal": session.inTerminalApp, "viewing": session.isCurrent,
            ]
            if session.statusSince > Date.distantPast.addingTimeInterval(1) { row["since"] = session.statusSince.timeIntervalSince1970 }
            if let task = session.task { row["task"] = Redaction.secrets(in: task) }
            if let detail = session.detail { row["detail"] = Redaction.secrets(in: detail) }
            if let activity = session.activity, let since = session.activitySince {
                row["activity"] = Redaction.secrets(in: activity)
                row["activitySince"] = since.timeIntervalSince1970
            }
            if let desktop = session.screenPosition?.desktop { row["desktop"] = desktop }
            return row
        }
        let today = store.today
        return [
            "sessions": sessions,
            "today": ["agentsWorking": today.agentsWorking, "waitingOnYou": today.waitingOnYou,
                      "projects": today.byProject().prefix(8).map { ["project": $0.project, "working": $0.working,
                                                                      "waiting": $0.waiting, "background": $0.background] }],
            "inputAllowed": inputAllowed,
            "device": ["id": device.id, "name": device.name, "push": device.push != nil],
            "vapidPublicKey": Base64URL.encode(vapidKey.publicKey.x963Representation),
            "mac": Host.current().localizedName ?? "Mac",
            "now": Date().timeIntervalSince1970,
        ]
    }

    private func screen(_ tty: String, respond: @escaping (HTTPResponse) -> Void) {
        guard TerminalBridge.isValidTTY(tty), let session = store.sessions.first(where: { $0.tty == tty }) else {
            return respond(.error(404, "no such session"))
        }
        guard session.inTerminalApp else { return respond(.error(409, "This session isn't in a Terminal tab.")) }
        if let cached = screenCache[tty], cached.at.timeIntervalSinceNow > -0.8 {
            return respond(.json(["tty": tty, "text": cached.text]))
        }
        // Several phones (or a slow read) must not stack up AppleScript calls: join the one in flight.
        if screenWaiters[tty] != nil {
            screenWaiters[tty]?.append(respond)
            return
        }
        screenWaiters[tty] = [respond]
        reads.async {
            let raw = TerminalBridge.screens(for: [tty])[tty]
            // Visible screen only, credentials masked, trailing blank lines dropped.
            var lines = Redaction.secrets(in: raw ?? "").components(separatedBy: "\n")
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                let waiters = self.screenWaiters.removeValue(forKey: tty) ?? []
                // Forget screens of sessions that are gone.
                let live = Set(self.store.sessions.map(\.tty))
                self.screenCache = self.screenCache.filter { live.contains($0.key) }
                let response: HTTPResponse
                if raw == nil {
                    response = .error(503, "Couldn't read that tab right now.")
                } else {
                    self.screenCache[tty] = (Date(), text)
                    response = .json(["tty": tty, "text": text])
                }
                waiters.forEach { $0(response) }
            }
        }
    }

    private func input(_ request: HTTPRequest, device: PairedDevice, respond: @escaping (HTTPResponse) -> Void) {
        guard inputAllowed else {
            return respond(.error(403, "Replying from the phone is off. Turn it on in VibeSwitcher › Phone Access."))
        }
        let object = body(request) ?? [:]
        let tty = object["tty"] as? String ?? ""
        guard let session = store.sessions.first(where: { $0.tty == tty }), session.inTerminalApp else {
            return respond(.error(404, "no such session"))
        }
        let text = object["text"] as? String
        let submit = object["submit"] as? Bool ?? true
        var key: RemoteInput.Key?
        if let name = object["key"] as? String {
            guard let parsed = RemoteInput.Key(rawValue: name) else { return respond(.error(400, "unknown key")) }
            key = parsed
        }
        guard text != nil || key != nil else { return respond(.error(400, "nothing to send")) }
        let summary = text.map { "“\(Redaction.secrets(in: String($0.prefix(60))))”" + (submit ? " ⏎" : "") } ?? key!.rawValue
        work.async {
            let failure = RemoteInput.send(tty: tty, text: text, submit: submit, key: key)
            DispatchQueue.main.async {
                if let failure {
                    self.audit("input to \(session.displayName) from \(device.name) refused: \(failure)")
                    return respond(.error(failure == .locked ? 423 : 409, failure.description))
                }
                self.audit("\(device.name) typed into \(session.displayName): \(summary)")
                self.onEvent?("\(device.name) typed into \(session.displayName)", summary)
                self.store.refresh(forceTerminal: true)
                respond(.json(["ok": true]))
            }
        }
    }

    // MARK: - Push notifications

    private func subscribe(_ request: HTTPRequest, device: PairedDevice) -> HTTPResponse {
        let object = body(request) ?? [:]
        let keys = object["keys"] as? [String: Any] ?? [:]
        guard let endpoint = object["endpoint"] as? String, (try? WebPush.validatedEndpoint(endpoint)) != nil,
              let p256dh = keys["p256dh"] as? String, Base64URL.decode(p256dh)?.count == 65,
              let auth = keys["auth"] as? String, Base64URL.decode(auth)?.count == 16,
              let index = devices.firstIndex(where: { $0.id == device.id })
        else { return .error(400, "invalid push subscription") }
        devices[index].push = WebPush.Subscription(endpoint: endpoint, p256dh: p256dh, auth: auth)
        saveDevices()
        audit("\(device.name) turned on notifications")
        return .json(["ok": true])
    }

    private func testPush(_ device: PairedDevice) -> HTTPResponse {
        guard let current = devices.first(where: { $0.id == device.id }), current.push != nil else {
            return .error(409, "notifications aren't set up on this device")
        }
        deliver(["title": "VibeSwitcher", "body": "Notifications from \(Host.current().localizedName ?? "your Mac") work.",
                 "tag": "test"], to: [current])
        return .json(["ok": true])
    }

    /// Mirrors a Mac alert to paired phones (by default only while you're away from the Mac).
    func notify(title: String, body: String, tty: String) {
        // Pushes go straight to the push service: they don't need the tailnet server to be up.
        guard enabled, !(pushOnlyWhenAway && UserPresence.isPresent()) else { return }
        let targets = devices.filter { $0.push != nil }
        guard !targets.isEmpty else { return }
        deliver(["title": Redaction.secrets(in: title), "body": Redaction.secrets(in: body), "tty": tty, "tag": tty],
                to: targets)
    }

    private func deliver(_ message: [String: Any], to targets: [PairedDevice]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        let key = vapidKey
        for device in targets {
            guard let subscription = device.push, let endpoint = try? WebPush.validatedEndpoint(subscription.endpoint),
                  let body = try? WebPush.encrypt(payload, for: subscription),
                  let authorization = try? WebPush.vapidAuthorization(endpoint: endpoint, key: key,
                                                                       subject: "mailto:vibeswitcher@users.noreply.github.com")
            else { continue }
            var request = URLRequest(url: endpoint, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("3600", forHTTPHeaderField: "TTL")
            request.setValue("high", forHTTPHeaderField: "Urgency")
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // 404/410: the browser dropped this subscription. 403: it was made for another key of ours.
                // Either way it's dead; the phone subscribes again the next time the app opens.
                guard [403, 404, 410].contains(status) else { return }
                DispatchQueue.main.async {
                    guard let self, let index = self.devices.firstIndex(where: { $0.id == device.id }) else { return }
                    self.devices[index].push = nil
                    self.saveDevices()
                }
            }.resume()
        }
    }

    // MARK: - Storage (~/.vibeswitcher/remote, private to you)

    private static var directory: URL { VibePaths.root.appendingPathComponent("remote") }
    private static var devicesURL: URL { directory.appendingPathComponent("devices.json") }
    private static var vapidURL: URL { directory.appendingPathComponent("vapid.key") }
    private static var auditURL: URL { directory.appendingPathComponent("audit.log") }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func writePrivate(_ data: Data, to url: URL) {
        ensureDirectory()
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func loadDevices() -> [PairedDevice] {
        guard let data = try? Data(contentsOf: devicesURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PairedDevice].self, from: data)) ?? []
    }

    private func saveDevices() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(devices) { Self.writePrivate(data, to: Self.devicesURL) }
    }

    private static func loadOrCreateVapidKey() -> P256.Signing.PrivateKey {
        if let data = try? Data(contentsOf: vapidURL), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        writePrivate(key.rawRepresentation, to: vapidURL)
        return key
    }

    private func audit(_ event: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(event)"
        recentActivity = Array(([line] + recentActivity).prefix(20))
        work.async {
            Self.ensureDirectory()
            let url = Self.auditURL
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
                let old = Self.directory.appendingPathComponent("audit.log.1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    private static func tailOfAuditLog() -> [String] {
        guard let text = try? String(contentsOf: auditURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(20).reversed().map(String.init))
    }
}
