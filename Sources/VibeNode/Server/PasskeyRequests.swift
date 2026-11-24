import Foundation
import VibeCore

/// A challenge the node issued for one act at the level `confirm`: what it is bound to (the request's kind, action and
/// arguments, `seen` among them; the page's token; the relying party and the origin), its line, and when it ends.
struct PasskeyChallenge: Sendable {
    var kind: String
    var action: String
    var arguments: String
    var token: String
    var origin: String
    var line: String
    /// On the steady clock (`Platform.Clock.steadyDate`).
    var until: Date
}

/// A registration the terminal asked (`web.passkey`): its challenge and user handle, and what a page answered.
struct PasskeyRegistration: Sendable {
    var challenge: [UInt8]
    var user: [UInt8]
    var until: Date
    /// The credential a page registered (id and X9.63 key, base64url), its page's token.
    var received: (id: String, publicKey: String, token: String)?
}

/// The level `confirm` (the web UI design's step 2): a passkey per acting request. Registered from a terminal only
/// (`web.passkey` asks the confirmed pages on `http://localhost:PORT` to make one, `passkey.registered` brings it, the
/// terminal shows its id and asks the typed code: `web.passkey.add`), kept in the vault (at most 5). Each act asks a
/// challenge first (`act.challenge`), bound to exactly that request; the page shows the line it names, the user's
/// authenticator signs it with user verification, and the request comes with the assertion (`PasskeyVoice`,
/// `passkeyCheck`): its origin, relying party, flags, signature, challenge and count all checked before anything is
/// recorded.
extension Requests {
    /// How long a challenge or a registration waits.
    public static let passkeyWait: TimeInterval = 60
    public static let registrationWait: TimeInterval = 120

    /// The origin a passkey's assertion names: the page's, which must be `http://localhost:PORT`.
    static func passkeyOrigin(_ credentials: PageCredentials) -> String? {
        guard let host = credentials.origin, ActingPages.passkeyHost(host) else { return nil }
        return "http://" + host
    }

    /// A confirmed pairing's passkey request (`Principal.Route.pagePaired`). On `queue`.
    func pagePaired(_ request: NodeWire.Request, credentials: PageCredentials, reply: @escaping (NodeWire.Reply) -> Void) {
        switch request.kind {
        case "act.challenge": actChallenge(request, credentials: credentials, reply: reply)
        case "passkey.registered": passkeyRegistered(request, credentials: credentials, reply: reply)
        default: reply(.init(re: request.id, error: .init(.unknownKind, "this server doesn't take \(ConfigSeal.inert(request.kind, limit: 80))")))
        }
    }

    // MARK: Acts

    /// `act.challenge` `{kind, args, action}`: the request the page is about to send. A challenge bound to it, the keys
    /// that may sign it, and the line the page shows while the user's authenticator asks.
    func actChallenge(_ request: NodeWire.Request, credentials: PageCredentials, reply: @escaping (NodeWire.Reply) -> Void) {
        let refuse = { (code: NodeWire.Code, why: String) in reply(.init(re: request.id, error: .init(code, why))) }
        guard let acting = actingPages, acting.level == "confirm" else { return refuse(.refused, "web_acts isn't confirm: no challenge is asked") }
        guard acting.acts(token: credentials.token, secret: credentials.act, origin: credentials.origin), let origin = Self.passkeyOrigin(credentials) else {
            return refuse(.actsEnded, WebRequestScreen.notActing)
        }
        guard let kind = request.args?["kind"]?.string, let action = request.args?["action"]?.string?.lowercased(), UUID(uuidString: action) != nil,
              case .object(let args)? = request.args?["args"] ?? .object([:]) else {
            return refuse(.badArgs, "act.challenge needs kind, args and action: the request it is for")
        }
        let keys = acting.state?.keys ?? [:]
        guard !keys.isEmpty else { return refuse(.refused, "no passkey is registered: `vibeswitcher web --passkey` in a terminal") }
        let line = approvalLine(kind: kind, args: args)
        let now = Platform.Clock.steadyDate()
        passkeyChallenges = passkeyChallenges.filter { $0.value.until > now }
        guard passkeyChallenges.count < 64 else { return refuse(.refused, "too many challenges wait: send or drop one first") }
        let nonce = WebTokens.randomText(bytes: 32)
        let until = now.addingTimeInterval(Self.passkeyWait)
        let bound = NodeWire.Value.object([
            "rpId": .string(WebAuthn.rpID), "origin": .string(origin), "kind": .string(kind), "action": .string(action),
            "args": .string(Self.argumentsDigest(args)), "token": .string(ActingPages.digest(credentials.token)), "nonce": .string(nonce),
            "expires": .int(Int(until.timeIntervalSince1970)),
        ])
        let challenge = Array(SHA256.hash(data: NodeWire.line(bound)))
        passkeyChallenges[WebAuthn.base64url(challenge)] = PasskeyChallenge(
            kind: kind, action: action, arguments: Self.argumentsDigest(args), token: ActingPages.digest(credentials.token), origin: origin,
            line: line, until: until)
        reply(.init(re: request.id, result: .object([
            "challenge": .string(WebAuthn.base64url(challenge)), "allow": .array(keys.keys.sorted().map(NodeWire.Value.string)),
            "rpId": .string(WebAuthn.rpID), "timeout": .int(Int(Self.passkeyWait * 1000)), "line": .string(line),
        ])))
    }

    /// A request's arguments as a challenge binds them: SHA-256 of their canonical line.
    static func argumentsDigest(_ args: [String: NodeWire.Value]) -> String {
        BuildInfo.sha256(of: NodeWire.line(NodeWire.Value.object(args)))
    }

    /// What an act approves, in one line the page shows and the vault records: its kind's phrase, and the card's
    /// question (or an approval's commit and subject), or a batch's count.
    func approvalLine(kind: String, args: [String: NodeWire.Value]) -> String {
        var line = ApprovalVoice.action(kind)
        if kind == "approve" {
            let count = args["seen"]?.array?.count ?? 0
            line += ": \(count) item\(count == 1 ? "" : "s")"
        } else if let id = args["card"]?.string, let card = engine?.cards.resolve(id) {
            if let approval = card.approval {
                line += ": commit \(approval.commit.prefix(12))" + (approval.subject.map { " “\(ConfigSeal.inert($0, limit: 80))”" } ?? "")
            } else if let question = card.question {
                line += ": “\(ConfigSeal.inert(question.text.split(separator: "\n").first.map(String.init) ?? question.text, limit: 100))”"
            } else {
                line += ": card \(card.id)"
            }
            if let text = args["text"]?.string { line += " → “\(ConfigSeal.inert(text, limit: 60))”" }
        } else if let session = args["session"]?.string {
            line += ": \(ConfigSeal.inert(session, limit: 60))"
        } else if let key = args["key"]?.string {
            line += ": \(ConfigSeal.inert(key, limit: 40)) = \(ConfigSeal.inert(args["value"]?.string ?? "", limit: 40))"
        }
        return String(line.prefix(160))
    }

    /// The level `confirm`'s check of `request`'s assertion (`PasskeyVoice`): its challenge one this node issued for
    /// exactly this request and page (kind, action, arguments, token), live and unused; its key a registered one; its
    /// origin, relying party, presence, verification and signature right; its count past the kept one (the vault's
    /// `usePasskey`, off the queue). `done` with nil when it passes (its line kept for the record), else why. On `queue`.
    func passkeyCheck(_ request: NodeWire.Request, page: PageAct, done: @escaping @Sendable (NodeWire.Failure?) -> Void) {
        let failed = { (why: String) in done(.init(.passkey, why)) }
        let needed = { (why: String) in done(.init(.assertionNeeded, why)) }
        // A repeat of an action this server answered, or is doing now (a reconnect resending it): answered as before by
        // `voiced` (`kept` gives the earlier reply only to the same arguments), its challenge not asked again.
        if let action = request.action?.lowercased(), replies[action] != nil || doing[action] != nil { return done(nil) }
        guard let acting = actingPages, let origin = Self.passkeyOrigin(page.credentials) else { return failed("acting needs a passkey, at http://localhost") }
        guard case .object(let assertion)? = request.assertion else { return needed("this act needs your passkey: ask act.challenge, then send it again with its assertion") }
        guard let id = assertion["id"]?.string, let clientData = assertion["clientDataJSON"]?.string.flatMap(WebAuthn.bytes(base64url:)),
              let authData = assertion["authenticatorData"]?.string.flatMap(WebAuthn.bytes(base64url:)),
              let signature = assertion["signature"]?.string.flatMap(WebAuthn.bytes(base64url:)) else {
            return failed("its assertion isn't whole")
        }
        // The challenge the client data names: taken (once only), and bound to exactly this request.
        guard let object = try? JSONSerialization.jsonObject(with: Data(clientData)) as? [String: Any], let named = object["challenge"] as? String,
              let challenge = WebAuthn.bytes(base64url: named) else {
            return failed("its client data names no challenge")
        }
        let key = WebAuthn.base64url(challenge)
        guard let issued = passkeyChallenges.removeValue(forKey: key) else {
            return usedChallenges.contains(key) ? failed("its challenge was used already") : needed("its challenge ran out or isn't one this node issued: ask again")
        }
        usedChallenges.insert(key)
        if usedChallenges.count > 256 { usedChallenges.removeAll() }
        guard issued.until > Platform.Clock.steadyDate() else { return needed("its challenge ran out: ask again") }
        guard issued.kind == request.kind, issued.action == request.action?.lowercased(), issued.arguments == Self.argumentsDigest(request.args ?? [:]),
              issued.token == ActingPages.digest(page.credentials.token), issued.origin == origin else {
            return failed("its challenge was for another request")
        }
        guard let stored = acting.state?.keys[id], let publicKey = WebAuthn.bytes(base64url: stored.publicKey) else { return failed("its passkey isn't registered") }
        let queue = self.queue, action = issued.action, line = issued.line
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checked = Result {
                let count = try WebAuthn.assertion(clientDataJSON: clientData, authenticatorData: authData, signature: signature, publicKey: publicKey,
                                                   challenge: challenge, origin: origin)
                try acting.usePasskey(id: id, count: count)
            }
            queue.async {
                switch checked {
                case .failure(let error): failed("the passkey's check failed: \(error)")
                case .success:
                    self?.approvedLines[action] = line
                    done(nil)
                }
            }
        }
    }

    // MARK: Registration

    /// `web.passkey` (the terminal's): with no `register`, a registration asked of every confirmed page on
    /// `http://localhost:PORT` (the `passkey` message); with one, where it stands. On `queue`.
    func webPasskey(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let now = Platform.Clock.steadyDate()
        passkeyRegistrations = passkeyRegistrations.filter { $0.value.until > now }
        if let id = request.args?["register"]?.string {
            guard let registration = passkeyRegistrations[id] else {
                return reply(.init(re: request.id, typed: WireKinds.WebPasskey.Result(register: id, state: "gone")))
            }
            let received = registration.received.map { String($0.id.prefix(12)) }
            return reply(.init(re: request.id, typed: WireKinds.WebPasskey.Result(register: id, state: received == nil ? "waiting" : "received", id: received)))
        }
        guard let acting = actingPages, let seat = pairings else { return reply(.init(re: request.id, error: .init(.refused, "this server has no web page"))) }
        guard (acting.state?.keys.count ?? 0) < LeadVaultV2.passkeysKept else {
            return reply(.init(re: request.id, error: .init(.refused, "at most \(LeadVaultV2.passkeysKept) passkeys: forget one first (vibeswitcher web --passkey --forget ID)")))
        }
        let id = UUID().uuidString.lowercased()
        let challenge = [UInt8](WebAuthn.bytes(base64url: WebTokens.randomText(bytes: 32)) ?? [])
        let user = Array(SHA256.hash(data: Data("vibeswitcher:\(root.path)".utf8)))
        passkeyRegistrations[id] = PasskeyRegistration(challenge: challenge, user: user, until: now.addingTimeInterval(Self.registrationWait))
        // The page's clock's date it is shown as (no guard: the node ends the offer on its own steady clock, below).
        let expires = Date(timeIntervalSinceNow: Self.registrationWait)
        let message = NodeWire.Value.object([
            "v": .int(NodeWire.version), "kind": .string("passkey"), "op": .string("register"), "register": .string(id), "expires": .date(expires),
            "challenge": .string(WebAuthn.base64url(challenge)),
            "rp": .object(["id": .string(WebAuthn.rpID), "name": .string("VibeSwitcher")]),
            "user": .object(["id": .string(WebAuthn.base64url(user)), "name": .string("vibeswitcher"), "displayName": .string("VibeSwitcher on this machine")]),
            "exclude": .array((acting.state?.keys.keys.sorted() ?? []).map(NodeWire.Value.string)),
        ])
        let pages = seat.toPasskeyPages(NodeWire.message(message))
        // Run out: every page holding the offer told it ended (unless a page answered it first: told then).
        queue.asyncAfter(deadline: .now() + Self.registrationWait) { [weak self] in
            guard let self, let left = self.passkeyRegistrations[id], left.received == nil else { return }
            self.passkeyRegistrations[id] = nil
            self.endOffer(id)
        }
        reply(.init(re: request.id, typed: WireKinds.WebPasskey.Result(register: id, pages: pages, state: "waiting")))
    }

    /// `passkey.registered` `{register, id, clientDataJSON, attestationObject}` from a confirmed page on localhost: the
    /// credential checked against the registration the terminal asked, and kept until the terminal adds it. On `queue`.
    func passkeyRegistered(_ request: NodeWire.Request, credentials: PageCredentials, reply: @escaping (NodeWire.Reply) -> Void) {
        let refuse = { (why: String) in reply(.init(re: request.id, error: .init(.voice, why))) }
        guard let origin = Self.passkeyOrigin(credentials) else { return refuse("a passkey is registered from http://localhost only") }
        guard actingPages?.watches(token: credentials.token, secret: credentials.act) == true else { return refuse(WebRequestScreen.notActing) }
        guard let id = request.args?["register"]?.string, var registration = passkeyRegistrations[id], registration.until > Platform.Clock.steadyDate() else {
            return refuse("no registration of that id waits: run `vibeswitcher web --passkey` again")
        }
        guard registration.received == nil else { return refuse("that registration was answered already") }
        guard let credential = request.args?["id"]?.string, let clientData = request.args?["clientDataJSON"]?.string.flatMap(WebAuthn.bytes(base64url:)),
              let attestation = request.args?["attestationObject"]?.string.flatMap(WebAuthn.bytes(base64url:)) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "passkey.registered needs register, id, clientDataJSON and attestationObject")))
        }
        do {
            let made = try WebAuthn.registration(clientDataJSON: clientData, attestationObject: attestation, challenge: registration.challenge, origin: origin)
            guard WebAuthn.base64url(made.id) == credential else { return refuse("the credential's id isn't its own") }
            registration.received = (credential, WebAuthn.base64url(made.publicKey), ActingPages.digest(credentials.token))
            passkeyRegistrations[id] = registration
            // Answered: the offer ends on every page that holds it.
            endOffer(id)
            note("a page registered a passkey (\(credential.prefix(12))): the terminal confirms it")
            reply(.init(re: request.id, result: .object(["id": .string(String(credential.prefix(12)))])))
        } catch {
            refuse("the passkey's registration didn't check: \(error)")
        }
    }

    /// The registration offer `id` ended (answered, run out): every page holding it told, so its button goes.
    func endOffer(_ id: String) {
        let message = NodeWire.Value.object(["v": .int(NodeWire.version), "kind": .string("passkey"), "op": .string("ended"), "register": .string(id)])
        _ = pairings?.toPasskeyPages(NodeWire.message(message))
    }

    /// `web.passkey.add` `{register}` (the user's voice, recorded): the passkey a page registered kept in the vault.
    func webPasskeyAdd(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let acting = actingPages, let id = request.args?["register"]?.string, let received = passkeyRegistrations[id]?.received else {
            return reply(.init(re: request.id, error: .init(.gone, "no page registered a passkey for that: run `vibeswitcher web --passkey` again")))
        }
        passkeyRegistrations[id] = nil
        let queue = self.queue, note = self.note
        DispatchQueue.global(qos: .userInitiated).async {
            let kept = Result { try acting.addPasskey(id: received.id, publicKey: received.publicKey) }
            queue.async {
                switch kept {
                case .failure(let error): reply(.init(re: request.id, error: .init(.refused, ConfigSeal.inert("\(error)", limit: 400))))
                case .success(let acts):
                    note("a passkey added for acting from the page: \(received.id.prefix(12))")
                    reply(.init(re: request.id, typed: WireKinds.WebPasskeyAdd.Result(id: String(received.id.prefix(12)), keys: acts.keys.count)))
                }
            }
        }
    }

    /// `web.passkey.forget` `{id}` (the user's voice, recorded): the passkeys whose id starts with it dropped (`all`:
    /// every one). Forgetting the last one at `confirm` leaves no act possible until one is added again.
    func webPasskeyForget(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let acting = actingPages, let given = request.args?["id"]?.string, !given.isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "web.passkey.forget needs id (or all)")))
        }
        let ids = (acting.state?.keys.keys.sorted() ?? []).filter { given == "all" || $0.hasPrefix(given) }
        guard !ids.isEmpty else { return reply(.init(re: request.id, error: .init(.gone, "no passkey's id starts with \(ConfigSeal.inert(given, limit: 40))"))) }
        let queue = self.queue
        DispatchQueue.global(qos: .userInitiated).async {
            let dropped = Result { try acting.dropPasskeys(ids) }
            queue.async {
                switch dropped {
                case .failure(let error): reply(.init(re: request.id, error: .init(.refused, ConfigSeal.inert("\(error)", limit: 400))))
                case .success(let acts):
                    reply(.init(re: request.id, typed: WireKinds.WebPasskeyForget.Result(forgotten: ids.map { String($0.prefix(12)) }, keys: acts.keys.count)))
                }
            }
        }
    }
}
