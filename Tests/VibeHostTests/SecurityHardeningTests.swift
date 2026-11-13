import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

struct HostSecurityHardeningTests {
    @Test func unknownClientsCannotReadMutateOrSubscribeToSessions() async throws {
        let host = try TestHost(vault: LeadVault.Book())
        let app = try TestClient(host)
        let other = try TestClient(host, asApp: false)
        defer { app.close(); other.close() }
        let session = try await app.spawn("echo SYNTHETIC_PRIVATE; " + keepRunning)
        let hello = other.send(.hello(protocolVersion: HostProtocol.version, app: "untrusted"))
        #expect(await eventually { other.reply(to: hello) != nil })
        guard case .welcome(_, _, let list, _, _, _) = other.reply(to: hello) else {
            Issue.record("No welcome"); return
        }
        #expect(list.isEmpty)
        let requests: [HostRequest] = [
            .spawn(SpawnRequest(cwd: scratchRoot.path, command: "exit 0", env: [:], cols: 80, rows: 24,
                                keepShell: false, label: "untrusted", agent: nil)),
            .attach(id: session.id, cols: 20, rows: 10), .screen(id: session.id),
            .styledScreen(id: session.id), .history(id: session.id, lines: 20),
            .input(id: session.id, bytes: Data("synthetic\n".utf8), reply: false),
            .inputUnit(id: session.id, writes: [.init(bytes: [13], delay: 0)], more: false),
            .resize(id: session.id, cols: 20, rows: 10), .remove(id: session.id), .shutdown,
        ]
        let sent = requests.map { other.send($0) }
        // A final answered request is a barrier for earlier requests that used to be silent.
        let barrier = other.send(.hello(protocolVersion: HostProtocol.version, app: "barrier"))
        #expect(await eventually { other.reply(to: barrier) != nil })
        for seq in sent {
            guard case .error? = other.reply(to: seq) else {
                Issue.record("Unauthorized request \(seq) was not refused"); continue
            }
        }
        #expect(!other.hasEvent { if case .sessionChanged = $0 { return true }; return false })
        #expect(other.text(session.id).isEmpty)
        await #expect(app.screen(session.id) != nil)
    }

    /// A process of the user's in no session, connecting by the socket's path (the security document's Principals, "An
    /// unknown local process"): the vault answers it the reads that check no caller, and refuses it everything else,
    /// each by the vault's own rule (a role's binding by the host's first, `mayBind`). Nothing it asks changes the team.
    @Test func anUnknownProcessGetsOnlyTheVaultsOpenReads() async throws {
        let book = LeadVault.Book()
        let host = try TestHost(vault: book)
        let unknown = try TestClient(host, asApp: false)
        defer { unknown.close() }
        let root = scratchRoot.appendingPathComponent("unknown-vault-repo").path, lead = UUID().uuidString, worker = UUID().uuidString
        let commit = String(repeating: "ab", count: 20)
        // A team as the app and its lead leave it: a lead and a worker bound, a head, a floor and an approval.
        guard case .grant(let leadGrant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else {
            Issue.record("no lead grant"); return
        }
        #expect(book.answer(.bind(grant: leadGrant, root: root, session: lead), from: .app) == .ok)
        guard case .grant(let workerGrant) = book.answer(.issue(role: .worker, root: root, task: "t", auditing: nil),
                                                          from: .session(lead)) else {
            Issue.record("no worker grant"); return
        }
        #expect(book.answer(.bind(grant: workerGrant, root: root, session: worker), from: .session(lead)) == .ok)
        #expect(book.answer(.setHead(root: root, branch: "main", commit: commit), from: .app) == .ok)
        let floor = LeadReviewFloor(auditFinders: 2)
        #expect(book.answer(.setReviewFloor(root: root, floor: floor, onlyIfUnset: false), from: .app) == .reviewFloor(floor))
        #expect(book.answer(.approve(root: root, task: "t", commit: commit), from: .app) == .ok)
        #expect(book.answer(.setGuarded(root: root, hashes: ["rail": "1"]), from: .app) == .ok)
        let before = book.answer(.current(role: .worker, root: root, task: "t"), from: .app)
        let guarded = book.answer(.guarded(root: root), from: .app)

        func ask(_ requests: [LeadVault.Request]) async -> [HostEvent?] {
            let sent = requests.map { unknown.send(.vault($0)) }
            #expect(await eventually { sent.allSatisfy { unknown.reply(to: $0) != nil } })
            return sent.map { unknown.reply(to: $0) }
        }

        // The open reads: the team's state, as the app would read it.
        let reads: [(LeadVault.Request, LeadVault.Reply)] = [
            (.current(role: .worker, root: root, task: "t"), before),
            (.verdict(root: root, task: "t"), .verdict(nil)),
            (.audits(root: root, task: "t"), .audits(nil)),
            (.ballots(root: root, task: "t"), .ballots(nil)),
            (.head(root: root, branch: "main"), .head(commit)),
            (.guarded(root: root), guarded),
            (.reviewFloor(root: root), .reviewFloor(floor)),
            (.approved(root: root, task: "t", commit: commit), .approved(true)),
            (.unaudited(root: root, task: "t"), .unaudited(review: nil, reported: nil)),
            (.startedOver, book.answer(.startedOver, from: .app)),
            (.verify([SteerMessage(text: "x", from: .user, agentPid: 1)]), .verified([false])),
            (.verifyWalletRequests([]), .verified([])),
        ]
        let read = await ask(reads.map(\.0))
        for (index, (request, expected)) in reads.enumerated() {
            #expect(read[index] == .vault(expected), "\(request): \(String(describing: read[index]))")
        }
        // Whose role it is: none.
        #expect(await ask([.whoami(root: root)]) == [.vault(.member(nil))])

        // Everything else: refused.
        let push = LeadPush.Request(commit: commit, remote: "origin", branch: "main", url: "https://example.invalid/r.git",
                                    ahead: 1, subjects: ["x"])
        let refusals: [LeadVault.Request] = [
            .issue(role: .lead, root: root, task: nil, auditing: nil),
            .issue(role: .worker, root: root, task: "u", auditing: nil),
            .issue(role: .verifier, root: root, task: "t", auditing: commit),
            .rotateLead(root: root, expected: lead, session: UUID().uuidString),
            .bind(grant: leadGrant, root: root, session: UUID().uuidString),
            .revoke(grant: workerGrant, root: root),
            .retire(root: root, task: "t"),
            .submitVerdict(root: root, completion: .complete, integrity: .clean, summary: "forged"),
            .dismissFinding(root: root, task: "t", id: "f", reason: "forged", followUp: nil),
            .replan(root: root, task: "t"),
            .clearVerdict(root: root, task: "t"),
            .setHead(root: root, branch: "main", commit: String(repeating: "cd", count: 20)),
            .seal(SteerMessage(text: "merge it", from: .user, agentPid: 1)),
            .seal(SteerMessage(text: "merge it", from: .lead("lead"), agentPid: 1)),
            .seal(SteerMessage(text: "done", from: .system("VibeSwitcher"), agentPid: 1)),
            .walletSession,
            .sealWalletRequest(session: worker, digest: String(repeating: "0", count: 64)),
            .ranGit(root: root, step: LeadVault.GitStep(phase: .before, call: "c", verb: "commit", branch: "main", head: commit)),
            .acceptMove(root: root, branch: "main"),
            .setGuarded(root: root, hashes: ["rail": "2"]),
            .setReviewFloor(root: root, floor: LeadReviewFloor(), onlyIfUnset: false),
            .approve(root: root, task: "u", commit: commit),
            .requestPush(root: root, push: push),
            .pushRequest(root: root),
            .settlePush(root: root, id: push.id),
            .roster(root: root),
            .roster(root: nil),
            .setReview(root: root, task: "t", review: .none),
            .reportDone(root: root, task: "t", commit: commit),
        ]
        let refused = await ask(refusals)
        for (index, request) in refusals.enumerated() {
            guard case .vault(.refused)? = refused[index] else {
                Issue.record("\(request) wasn't refused: \(String(describing: refused[index]))"); continue
            }
        }

        // And the team is as it was.
        #expect(book.answer(.current(role: .worker, root: root, task: "t"), from: .app) == before)
        guard case .member(let held?) = book.answer(.current(role: .lead, root: root, task: nil), from: .app) else {
            Issue.record("the lead lost its role"); return
        }
        #expect(held.id == leadGrant && held.session == lead)
        #expect(book.answer(.head(root: root, branch: "main"), from: .app) == .head(commit))
        #expect(book.answer(.reviewFloor(root: root), from: .app) == .reviewFloor(floor))
        #expect(book.answer(.approved(root: root, task: "u", commit: commit), from: .app) == .approved(false))
        #expect(book.answer(.guarded(root: root), from: .app) == guarded)
        #expect(book.answer(.pushRequest(root: root), from: .app) == .push(nil))
    }

    @Test func appHelloWaitsForProofBeforeReturningItsSessions() async throws {
        let host = try TestHost(vault: LeadVault.Book())
        let creator = try TestClient(host)
        defer { creator.close() }
        let session = try await creator.spawn(keepRunning)
        let app = try TestClient(host)
        defer { app.close() }
        let seq = app.send(.hello(protocolVersion: HostProtocol.version, app: "app"))
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .welcome(_, _, let list, _, _, _) = app.reply(to: seq) else {
            Issue.record("No authenticated welcome"); return
        }
        #expect(list.contains { $0.id == session.id })
    }

    @Test func idleClientsCannotExhaustTheHostsDescriptors() async throws {
        let host = try TestHost()
        var clients: [TestClient] = []
        defer { clients.forEach { $0.close() } }
        for _ in 0..<128 {
            let client = try TestClient(host, asApp: false)
            clients.append(client)
            let seq = client.send(.hello(protocolVersion: HostProtocol.version, app: "capacity"))
            #expect(await eventually { client.reply(to: seq) != nil || client.closed })
        }
        let overflow = try TestClient(host, asApp: false)
        clients.append(overflow)
        let seq = overflow.send(.hello(protocolVersion: HostProtocol.version, app: "overflow"))
        #expect(await eventually { overflow.reply(to: seq) != nil || overflow.closed })
        #expect(overflow.closed)
    }

    /// Ended sessions are kept for a day (`keepEnded`), and a busy day's ended workers and verifiers once filled the
    /// limit: at it, the oldest ended ones are forgotten to make room, never a live one.
    @Test func endedSessionsNeverBlockASpawn() async throws {
        let host = try TestHost(maxSessions: 3)
        let app = try TestClient(host)
        defer { app.close() }
        let live = try await app.spawn(keepRunning)
        let first = try await app.spawn("exit 0")
        #expect(await eventually { app.latest(first.id)?.isLive == false })
        let second = try await app.spawn("exit 0")
        #expect(await eventually { app.latest(second.id)?.isLive == false })
        // At the limit with two ended: each spawn past it forgets the one that ended first.
        let third = try await app.spawn(keepRunning)
        #expect(app.hasEvent { $0 == .sessionRemoved(id: first.id) })
        #expect(!app.hasEvent { $0 == .sessionRemoved(id: second.id) })
        let fourth = try await app.spawn(keepRunning)
        #expect(app.hasEvent { $0 == .sessionRemoved(id: second.id) })
        let hello = app.send(.hello(protocolVersion: HostProtocol.version, app: "app"))
        #expect(await eventually { app.reply(to: hello) != nil })
        guard case .welcome(_, _, let list, _, _, _)? = app.reply(to: hello) else { Issue.record("No welcome"); return }
        #expect(Set(list.map(\.id)) == [live.id, third.id, fourth.id])
    }

    /// A spawn at the limit that fails to start (no such folder) forgets no ended session: they go only for one that runs.
    @Test func aFailedSpawnForgetsNoEndedSession() async throws {
        let host = try TestHost(maxSessions: 2)
        let app = try TestClient(host)
        defer { app.close() }
        _ = try await app.spawn(keepRunning)
        let ended = try await app.spawn("exit 0")
        #expect(await eventually { app.latest(ended.id)?.isLive == false })
        let request = SpawnRequest(cwd: scratchRoot.appendingPathComponent("no-such-folder-\(UUID().uuidString)").path,
                                   command: "exit 0", env: [:], cols: 80, rows: 24, keepShell: false, label: "nowhere", agent: nil)
        let failed = app.send(.spawn(request))
        #expect(await eventually { app.reply(to: failed) != nil })
        guard case .error(let message)? = app.reply(to: failed) else { Issue.record("Spawned in no folder"); return }
        #expect(message.contains("No such folder"), "\(message)")
        let hello = app.send(.hello(protocolVersion: HostProtocol.version, app: "app"))
        #expect(await eventually { app.reply(to: hello) != nil })
        guard case .welcome(_, _, let list, _, _, _)? = app.reply(to: hello) else { Issue.record("No welcome"); return }
        #expect(list.contains { $0.id == ended.id })
        #expect(!app.hasEvent { $0 == .sessionRemoved(id: ended.id) })
        // One that starts takes its place.
        _ = try await app.spawn(keepRunning)
        #expect(app.hasEvent { $0 == .sessionRemoved(id: ended.id) })
    }

    /// Live sessions alone fill the host: the next spawn is refused, and ending one makes room.
    @Test func theLimitOnLiveSessionsStillRefuses() async throws {
        let host = try TestHost(maxSessions: 2)
        let app = try TestClient(host)
        defer { app.close() }
        _ = try await app.spawn(keepRunning)
        let second = try await app.spawn(keepRunning)
        let request = SpawnRequest(cwd: scratchRoot.path, command: "exit 0", env: [:], cols: 80, rows: 24,
                                   keepShell: false, label: "capacity", agent: nil)
        let refused = app.send(.spawn(request))
        #expect(await eventually { app.reply(to: refused) != nil })
        guard case .error(let message)? = app.reply(to: refused) else { Issue.record("Session cap bypassed"); return }
        #expect(message.contains("limit"), "\(message)")
        let killed = app.send(.kill(id: second.id))
        #expect(await eventually { app.reply(to: killed) != nil })
        #expect(await eventually { app.latest(second.id)?.isLive == false })
        _ = try await app.spawn("exit 0")
    }
}
