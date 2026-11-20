import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// push_remote on a node (`PushAsks.swift`, `Requests.push`; the app's `PushRequests`): the lead's open request is on
/// its value and in `status` while it's open, saying the commands; `push` and `push.decline`, the user's voice recorded
/// in the vault, settle exactly the request the command showed through the vault (the node's server as its app), push
/// it from the server to the pinned remote, and tell the lead the outcome. On a scratch host, the request recorded as
/// the lead's tool server records it, the remote a bare repository in the scratch.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct PushAsksTests {
    private let scratch = Scratch()

    /// What reached the lead with `text` in it: waiting in its inbox, or typed in.
    private func heard(_ world: DeliveryWorld, _ lead: NodeHarness, _ text: String) -> Int {
        world.pending(lead).filter { $0.text.contains(text) }.count + world.prompts(lead).filter { $0.contains(text) }.count
    }

    /// `request` recorded as the lead's tool server records it, and seen by a refresh: on the lead's value.
    private func ask(_ world: CardWorld, _ lead: NodeHarness, _ request: LeadPush.Request) async throws {
        let (book, folder, repo, leadID) = (world.host.book, world.host.folder, world.repo, lead.session.id.uuidString)
        try await offPool { try book.vault(folder: folder, as: { .session(leadID) }).requestPush(request, root: repo) }
        let seen = await eventually(timeout: 60) {
            world.engine.refresh()
            return world.queue.sync { world.engine.leads.leads[world.project]?.push?.id == request.id }
        }
        let kept = world.queue.sync { world.engine.leads.leads[world.project]?.push }
        try #require(seen, "\(String(describing: kept))")
    }

    private func request(commit: String = String(repeating: "a", count: 40), url: String = "https://example.invalid/r.git",
                         ahead: Int = 2) -> LeadPush.Request {
        LeadPush.Request(commit: commit, remote: "origin", branch: "main", url: url, ahead: ahead,
                         subjects: Array(["aaaaaaa One", "bbbbbbb Two"].prefix(ahead)))
    }

    private func settle(_ world: CardWorld, _ id: String, push: Bool, action: String = UUID().uuidString.lowercased(),
                        from facts: PeerFacts = CardWorld.user) async -> NodeWire.Reply? {
        await world.ask(push ? "push" : "push.decline", ["folder": .string(world.repo), "request": .string(id)], action: action, from: facts)
    }

    @Test func anOpenRequestIsOnTheLeadAndInStatusWithTheCommandsAndTheLeadIsToldNothing() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.world.lead(idle: false)
        let request = request()
        try await ask(world, lead, request)
        let repo = world.repo
        #expect(await eventually(timeout: 60) {
            world.engine.refresh()
            return world.queue.sync { world.engine.notices[repo]?.contains { $0.contains("asked you to push main at aaaaaaaa (2 commits)")
                && $0.contains("`vibeswitcher push \(repo)` pushes it") } == true }
        }, "\(world.queue.sync { world.engine.notices })")
        let value = world.queue.sync { world.engine.leads.leads[world.project]?.value }
        #expect(value?["push"]?["id"]?.string == request.id && value?["push"]?["subjects"]?.array?.count == 2, "\(value as Any)")
        // The command line finds it from status's leads, from a folder inside the project too.
        let shown = try #require(PushText.lead(for: repo + "/docs", in: [value ?? .null, .object(["root": .string("/elsewhere")])]))
        let words = PushText.what(try #require(shown["push"]), root: repo, approve: true)
        #expect(words.contains("This pushes main at aaaaaaaa (2 commits) to origin/main, https://example.invalid/r.git"), "\(words)")
        #expect(words.contains("  bbbbbbb Two"), "\(words)")
        await world.drained()
        #expect(heard(world.world, lead, request.id) == 0, "The lead's tool told it already; nothing more until the user settles it")
        // Settled elsewhere: no longer listed.
        try await offPool { _ = try world.host.vault.settlePush(id: request.id, root: repo) }
        #expect(await eventually(timeout: 60) {
            world.engine.refresh()
            return world.queue.sync { world.engine.notices[repo]?.contains { $0.contains("asked you to push") } != true
                && world.engine.leads.leads[world.project]?.push == nil }
        }, "\(world.queue.sync { world.engine.notices })")
    }

    @Test func aDeclineSettlesTheRequestThroughTheVaultRecordedAndTellsTheLead() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.world.lead(idle: false)
        let request = request()
        try await ask(world, lead, request)
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await settle(world, request.id, push: false, action: action))
        #expect(reply.ok && reply.result?["settled"]?.string == "declined" && reply.result?["ok"]?.bool == true, "\(reply)")
        let (vault, repo) = (world.host.vault, world.repo)
        #expect(try await offPool { try vault.pushRequest(root: repo) } == nil, "The vault handed it over")
        #expect(await eventually(timeout: 60) { heard(world.world, lead, "The user declined your push request \(request.id)") == 1 },
                "\(world.world.pending(lead).map(\.text))")
        #expect(world.world.pending(lead).first { $0.text.contains("declined") }?.from == .system("push"))
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["push.decline"])
        let progress = try String(contentsOfFile: BoardStore(root: repo).recordPath("progress.md"), encoding: .utf8)
        #expect(progress.contains("The user declined the push of main at aaaaaaaa (2 commits) to origin/main"))
        #expect(world.queue.sync { world.engine.leads.leads[world.project]?.push == nil })
    }

    @Test func aPushPushesTheRequestedCommitToThePinnedRemoteAndTellsTheLead() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.world.lead(idle: false)
        let repo = world.repo
        let origin = world.host.folder.appendingPathComponent("origin.git").path
        let commit: String = try await offPool {
            let identity = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"]
            for (arguments, folder) in [(["init", "-q", "--bare", "-b", "main", origin], repo), (["remote", "add", "origin", origin], repo),
                                        (["-c", "protocol.file.allow=always", "push", "-q", "origin", "main"], repo),
                                        (identity + ["commit", "-q", "--allow-empty", "-m", "Second"], repo)] {
                let ran = Git.run(arguments, in: folder)
                guard ran.ok else { throw HostCall.Failure(description: "git \(arguments.joined(separator: " ")): \(ran.error)") }
            }
            return Git.run(["rev-parse", "HEAD"], in: repo).output
        }
        // The URL the lead fetched from, pinned in the vault as fetch_remote pins it.
        let vault = world.host.vault
        try await offPool { try vault.setGuardedSettings([LeadRemote.urlKey("origin"): LeadVault.hash(origin)], root: repo) }
        let request = request(commit: commit, url: origin, ahead: 1)
        try await ask(world, lead, request)
        // A request the lead replaced since isn't pushed on a code typed for it.
        let stale = try #require(await settle(world, "0ld1d", push: true))
        #expect(stale.ok && stale.result?["settled"]?.string == "gone" && stale.result?["ok"]?.bool == false, "\(stale)")
        #expect(try await offPool { try vault.pushRequest(root: repo)?.id } == request.id, "The open request stays open")
        let reply = try #require(await settle(world, request.id, push: true))
        #expect(reply.ok && reply.result?["settled"]?.string == "pushed", "\(reply)")
        #expect(reply.result?["said"]?.string == "Pushed \(request.short) to origin/main. The lead was told.", "\(reply)")
        let tip = Git.run(["--git-dir", origin, "rev-parse", "refs/heads/main"], in: repo)
        #expect(tip.output == commit, "origin's main is the requested commit: \(tip.output) \(tip.error)")
        #expect(await eventually(timeout: 60) { heard(world.world, lead, "The user clicked Push on your push request \(request.id)") == 1 },
                "\(world.world.pending(lead).map(\.text))")
        #expect(heard(world.world, lead, "0ld1d") == 0, "The lead hears nothing of a request the vault didn't hand over")
    }

    @Test func noSessionNorWebPageSettlesARequest() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.world.lead(idle: false)
        let request = request()
        try await ask(world, lead, request)
        let reply = try #require(await settle(world, request.id, push: true, from: CardWorld.toolServer(of: lead.session)))
        #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
        let (vault, repo) = (world.host.vault, world.repo)
        #expect(try await offPool { try vault.pushRequest(root: repo)?.id } == request.id)
        for kind in ["push", "push.decline"] {
            #expect(NodeWire.kinds[kind] == .user && NodeWire.changesState(kind) && Requests.recorded.contains(kind))
            let refused = WebAccess.refusal(for: NodeWire.Request(id: "1", kind: kind, args: ["folder": .string("/r"), "request": .string("x")]),
                                            rights: [.read, .draft])
            #expect(refused?.error?.code == NodeWire.Code.voice.rawValue, "\(String(describing: refused))")
        }
        // Only the server's own connection to the vault, the app's, settles: never the lead that asked.
        let (book, folder, leadID) = (world.host.book, world.host.folder, lead.session.id.uuidString)
        #expect(throws: (any Error).self) { try book.vault(folder: folder, as: { .session(leadID) }).settlePush(id: request.id, root: repo) }
    }

    /// Through the command line on a scratch node: with no request open there's nothing to settle and no code is asked;
    /// a folder no lead holds is refused; a wrong form is the usage.
    @Test func theCommandLineRefusesWithNoRequestOpenAndNoLeadThere() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let lead = try await node.askingLead("Name the parser?", options: ["Parser", "Reader"])
        let none = try await node.runOnTerminal(["push", lead.repo.path])
        #expect(none.status == 77, "\(none.output)\(none.errors)\n\(node.said)")
        #expect((none.output + none.errors).contains("has no push request open: nothing to push"), "\(none.output)\(none.errors)")
        let other = node.root.appendingPathComponent("other")
        try await scratchRepository(other)
        let elsewhere = try await node.runOnTerminal(["decline-push", other.path])
        #expect(elsewhere.status == 77 && (elsewhere.output + elsewhere.errors).contains("no lead on this node holds"),
                "\(elsewhere.output)\(elsewhere.errors)")
        let usage = try await node.run(["decline-push"])
        #expect(usage.status == 64 && usage.errors.contains("usage: vibeswitcher decline-push FOLDER"), "\(usage.output)\(usage.errors)")
    }

    /// A remote's credentials never leave the node: not on the wire (every page with a read token), not in what the
    /// command line shows or prints, not in the reply, the log or the lead's message (its chat is the page's), however
    /// the URL carries them; an scp-like login name stays.
    @Test func aURLsCredentialsAreNeverShown() async throws {
        let secret = "hunter2-token"
        #expect(PushText.displayURL("https://someone:\(secret)@example.invalid/r.git") == "https://example.invalid/r.git")
        #expect(PushText.displayURL("https://\(secret)@example.invalid/r.git?access_token=\(secret)#x") == "https://example.invalid/r.git")
        #expect(PushText.displayURL("ssh://git:\(secret)@example.invalid:22/r.git") == "ssh://example.invalid:22/r.git")
        #expect(PushText.displayURL("git@example.invalid:r.git") == "git@example.invalid:r.git")
        #expect(PushText.displayURL("someone:\(secret)@example.invalid:r.git") == "…@example.invalid:r.git")
        #expect(PushText.displayURL("/srv/git/r.git") == "/srv/git/r.git")
        #expect(PushText.scrub("fatal: unable to access 'https://a@b:\(secret)@example.invalid/r.git/': 403") == "fatal: unable to access 'https://example.invalid/r.git/': 403")

        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.world.lead(idle: false)
        let url = "https://someone:\(secret)@example.invalid/r.git"
        let request = request(url: url)
        try await ask(world, lead, request)
        let value = try #require(world.queue.sync { world.engine.leads.leads[world.project]?.value })
        let wire = String(decoding: NodeWire.line(value), as: UTF8.self)
        #expect(!wire.contains(secret) && wire.contains("https://example.invalid/r.git"), "\(wire)")
        let words = PushText.what(try #require(value["push"]), root: world.repo, approve: true)
        #expect(!words.contains(secret) && words.contains("https://example.invalid/r.git"), "\(words)")
        // git's own words carry the URL whole: the outcome is shown without it, everywhere.
        world.queue.sync {
            world.engine.pushSettle = { id, root, _, vault in
                (try? vault.settlePush(id: id, root: root), .failed("fatal: unable to access '\(url)/': The requested URL returned error: 403"))
            }
        }
        // The log's line is the reply's `said`.
        let reply = try #require(await settle(world, request.id, push: true))
        let replied = String(decoding: NodeWire.line(reply.result ?? .null), as: UTF8.self)
        #expect(reply.result?["settled"]?.string == "failed" && !replied.contains(secret), "\(replied)")
        #expect(await eventually(timeout: 60) { heard(world.world, lead, "git push failed") == 1 }, "\(world.world.pending(lead).map(\.text))")
        let told = world.world.pending(lead).map(\.text) + world.world.prompts(lead)
        #expect(!told.contains { $0.contains(secret) }, "\(told)")
    }
}
