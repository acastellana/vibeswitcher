import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A switch's one code (`SwitchSealCheck`, the lead's rule of 2026-11-24) against a scratch host's real vault, whose
/// config home holds a builds folder and a unit folder: the builds folder is sealed only when it is what the install
/// left and it was the accepted one before; the unit folder only when its unit's `ExecStart` is its one change, to the
/// new build; every other held change stays held (the vault's partial accept, `SwitchSeal.partialKey`).
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct SwitchSealTests {
    private let scratch = Scratch()
    static let (a, b) = (String(repeating: "a", count: 40), String(repeating: "b", count: 40))

    /// A host whose home has build A installed (current naming it) and the node's unit for A, all accepted.
    struct Rig {
        let host: NodeTestHost
        var home: String { host.home.path }
        var prefix: String { host.home.appendingPathComponent(".vibeswitcher/v2/builds").path }
        var unitFolder: String { host.home.appendingPathComponent(".config/systemd/user").path }
        var unit: String { (unitFolder as NSString).appendingPathComponent("\(NodeStarter.unitName).service") }

        func unitText(_ commit: String) throws -> String {
            try NodeUnit.text(.init(prefix: prefix, commit: commit, home: home, swiftBin: "/opt/swift/usr/bin", nodeBin: "/opt/node/bin")).get()
        }

        func install(_ commit: String) throws {
            try ScratchBuilds.install(commit: commit, into: URL(fileURLWithPath: prefix))
            let link = (prefix as NSString).appendingPathComponent("current.new")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: commit)
            guard rename(link, (prefix as NSString).appendingPathComponent("current")) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }

        /// `commit` installed and the builds folder sealed as the install left it (rule a).
        func installAndSeal(_ commit: String) throws -> SwitchSealCheck.Sealed {
            let before = SwitchSeal.listingHash(prefix)
            try install(commit)
            return SwitchSealCheck.sealBuilds(prefix: prefix, commit: commit, seen: .init(before: before, after: SwitchSeal.listingHash(prefix)), home: home, vault: host.vault)
        }

        func held() throws -> [String] { ConfigSeal.held(in: try host.vault.guardedRecord(root: home)) }
        var heldNow: [String] { (try? held()) ?? [] }
        func look() throws { _ = try host.vault.checkConfig(root: home) }
    }

    func rig() throws -> Rig {
        let rig = Rig(host: try NodeTestHost(scratch))
        try FileManager.default.createDirectory(atPath: rig.unitFolder, withIntermediateDirectories: true)
        try rig.install(Self.a)
        try rig.unitText(Self.a).write(toFile: rig.unit, atomically: true, encoding: .utf8)
        // The first look records everything as it is: the accepted state.
        try rig.look()
        try #require(try rig.held().isEmpty, "\(rig.heldNow)")
        return rig
    }

    @Test func theInstallsBuildsFolderAndTheUnitsExecStartAreSealedAndNothingElse() throws {
        let rig = try rig()
        let before = SwitchSeal.listingHash(rig.prefix)
        let entriesBefore = SwitchSeal.entries(listing: rig.prefix)
        try rig.install(Self.b)
        let after = SwitchSeal.listingHash(rig.prefix)
        #expect(SwitchSealCheck.installChange(before: entriesBefore, after: SwitchSeal.entries(listing: rig.prefix), commit: Self.b).isEmpty)
        // Something else changed meanwhile, which the code never seals.
        let settings = rig.host.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"env":{"X":"1"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        try rig.look()
        #expect(try rig.held().contains(SwitchSeal.buildsName))

        let builds = SwitchSealCheck.sealBuilds(prefix: rig.prefix, commit: Self.b, seen: .init(before: before, after: after), home: rig.home, vault: rig.host.vault)
        #expect(builds.sealed == [SwitchSeal.buildsName] && builds.refusals.isEmpty, "\(builds)")
        #expect(try !rig.held().contains(SwitchSeal.buildsName) && rig.held().contains("~/.claude/settings.json"), "\(rig.heldNow)")

        // The follow-up's unit: only ExecStart moved, to B.
        try rig.unitText(Self.b).write(toFile: rig.unit, atomically: true, encoding: .utf8)
        try rig.look()
        #expect(try rig.held().contains(SwitchSeal.unitFolderName))
        let unit = SwitchSealCheck.sealUnit(unitFolder: rig.unitFolder, unitFile: "\(NodeStarter.unitName).service", prefix: rig.prefix,
                                            from: Self.a, to: Self.b, home: rig.home, vault: rig.host.vault)
        #expect(unit.sealed == [SwitchSeal.unitFolderName] && unit.refusals.isEmpty, "\(unit)")
        let left = try rig.held()
        #expect(left.contains("~/.claude/settings.json") && !left.contains(SwitchSeal.unitFolderName) && !left.contains(SwitchSeal.buildsName), "\(left)")
    }

    @Test func aPlantBesideTheInstallOrInItsFolderIsNeverSealed() throws {
        let rig = try rig()
        let before = SwitchSeal.listingHash(rig.prefix)
        let entriesBefore = SwitchSeal.entries(listing: rig.prefix)
        try rig.install(Self.b)
        // Another build's folder changed beside the install: said by `update` itself.
        try Data("x".utf8).write(to: URL(fileURLWithPath: rig.prefix).appendingPathComponent("\(Self.a)/planted"))
        let other = SwitchSealCheck.installChange(before: entriesBefore, after: SwitchSeal.entries(listing: rig.prefix), commit: Self.b)
        #expect(other == ["\(Self.a) changed"], "\(other)")
        try FileManager.default.removeItem(atPath: URL(fileURLWithPath: rig.prefix).appendingPathComponent("\(Self.a)/planted").path)

        // A file added in the new build after the install: not as install-node lays one out, and not what was seen.
        let after = SwitchSeal.listingHash(rig.prefix)
        let extra = URL(fileURLWithPath: rig.prefix).appendingPathComponent("\(Self.b)/bin.d")
        try Data("x".utf8).write(to: extra)
        try rig.look()
        let planted = SwitchSealCheck.sealBuilds(prefix: rig.prefix, commit: Self.b, seen: .init(before: before, after: after), home: rig.home, vault: rig.host.vault)
        #expect(planted.sealed.isEmpty && planted.refusals.first?.contains("bin.d isn't part of a build install-node lays out") == true, "\(planted)")
        try FileManager.default.removeItem(at: extra)
        // Removed again, the folder's times aren't the ones seen: still not sealed.
        let again = SwitchSealCheck.sealBuilds(prefix: rig.prefix, commit: Self.b, seen: .init(before: before, after: after), home: rig.home, vault: rig.host.vault)
        #expect(again.sealed.isEmpty && again.refusals.first?.contains("changed after the install") == true, "\(again)")
        // A program swapped with build-info rewritten to match still has another inode and change time.
        let seenNow = SwitchSeal.listingHash(rig.prefix)
        let program = URL(fileURLWithPath: rig.prefix).appendingPathComponent("\(Self.b)/bin/\(BuildInfo.server)")
        let bytes = try Data(contentsOf: program)
        try FileManager.default.removeItem(at: program)
        try bytes.write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let swapped = SwitchSealCheck.sealBuilds(prefix: rig.prefix, commit: Self.b, seen: .init(before: before, after: seenNow), home: rig.home, vault: rig.host.vault)
        #expect(swapped.sealed.isEmpty, "\(swapped)")
        #expect(try rig.held().contains(SwitchSeal.buildsName))

        // The folder before the install wasn't the accepted one: nothing sealed.
        let wrong = SwitchSealCheck.sealBuilds(prefix: rig.prefix, commit: Self.b, seen: .init(before: String(repeating: "0", count: 64), after: SwitchSeal.listingHash(rig.prefix)),
                                               home: rig.home, vault: rig.host.vault)
        #expect(wrong.sealed.isEmpty && wrong.refusals.first?.contains("wasn't the one you last accepted") == true, "\(wrong)")
    }

    @Test func aUnitChangedBeyondItsExecStartIsNeverSealed() throws {
        let rig = try rig()
        let file = "\(NodeStarter.unitName).service"
        func seal() -> SwitchSealCheck.Sealed {
            SwitchSealCheck.sealUnit(unitFolder: rig.unitFolder, unitFile: file, prefix: rig.prefix, from: Self.a, to: Self.b, home: rig.home, vault: rig.host.vault)
        }
        // B not installed yet: the unit naming it is never sealed, whatever it says.
        try rig.unitText(Self.b).write(toFile: rig.unit, atomically: true, encoding: .utf8)
        try rig.look()
        #expect(seal().sealed.isEmpty && seal().refusals.first?.contains("isn't as install-node lays it out") == true, "\(seal())")
        // Installed, but the builds folder holding it not accepted: still not.
        try rig.install(Self.b)
        try rig.look()
        #expect(seal().sealed.isEmpty && seal().refusals.first?.contains("isn't the accepted one yet") == true, "\(seal())")
        // Accepted as the install left it (as an update does: here the folder's state now, both before and after).
        let now = SwitchSeal.listingHash(rig.prefix)
        let buildsRecord = try rig.host.vault.guardedRecord(root: rig.home)
        _ = try rig.host.vault.checkConfig(root: rig.home, shown: [SwitchSeal.buildsKey: try #require(ConfigSeal.heldHashes(in: buildsRecord)[SwitchSeal.buildsKey]),
                                                                   SwitchSeal.partialKey: "1"])
        try #require(try !rig.held().contains(SwitchSeal.buildsName) && SwitchSeal.listingHash(rig.prefix) == now, "\(rig.heldNow)")
        // A line added beside the new ExecStart.
        try (rig.unitText(Self.b) + "Environment=LD_PRELOAD=/var/lib/x.so\n").write(toFile: rig.unit, atomically: true, encoding: .utf8)
        try rig.look()
        #expect(seal().sealed.isEmpty && seal().refusals.first?.contains("changed beyond the unit's ExecStart") == true, "\(seal())")
        // An ExecStart naming another build than the switch's.
        try rig.unitText(String(repeating: "c", count: 40)).write(toFile: rig.unit, atomically: true, encoding: .utf8)
        #expect(seal().sealed.isEmpty && seal().refusals.first?.contains("isn't the one the switch writes") == true, "\(seal())")
        // A drop-in beside the unit: the folder changed beyond it.
        try rig.unitText(Self.b).write(toFile: rig.unit, atomically: true, encoding: .utf8)
        let dropIns = (rig.unitFolder as NSString).appendingPathComponent("\(NodeStarter.unitName).service.d")
        try FileManager.default.createDirectory(atPath: dropIns, withIntermediateDirectories: true)
        try "[Service]\nExecStartPre=/bin/true\n".write(toFile: (dropIns as NSString).appendingPathComponent("x.conf"), atomically: true, encoding: .utf8)
        try rig.look()
        #expect(seal().sealed.isEmpty, "\(seal())")
        #expect(try rig.held().contains(SwitchSeal.unitFolderName))
        // An accept without the partial mark seals nothing while anything else is held (as ever).
        try FileManager.default.removeItem(atPath: dropIns)
        let settings = rig.host.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: settings, atomically: true, encoding: .utf8)
        try rig.look()
        let record = try rig.host.vault.guardedRecord(root: rig.home)
        let unitHash = try #require(ConfigSeal.heldHashes(in: record)[SwitchSeal.unitFolderKey])
        _ = try rig.host.vault.checkConfig(root: rig.home, shown: [SwitchSeal.unitFolderKey: unitHash])
        #expect(try rig.held().contains(SwitchSeal.unitFolderName))
        let sealed = seal()
        #expect(sealed.sealed == [SwitchSeal.unitFolderName], "\(sealed)")
        let left = try rig.held()
        // The settings stay held (named also as the root's own, the home being the root asked).
        #expect(left.contains("~/.claude/settings.json") && !left.contains(SwitchSeal.unitFolderName) && !left.contains(SwitchSeal.buildsName), "\(left)")
    }

    /// A commit is 40 lowercase hex digits before any path is made of it or compared with it, at every entry point:
    /// a traversal or a near miss is refused and nothing is sealed.
    @Test func aTraversalOrANearMissIdSealsNothing() throws {
        let rig = try rig()
        let bad = ["../\(Self.a)", "../../etc", String(repeating: "A", count: 40), String(repeating: "a", count: 39), String(repeating: "a", count: 41),
                   Self.a + "/..", "", String(repeating: "g", count: 40), Self.a.prefix(39) + " "]
        let seen = SwitchSealCheck.InstallSeen(before: SwitchSeal.listingHash(rig.prefix), after: SwitchSeal.listingHash(rig.prefix))
        let unit = Data(try rig.unitText(Self.a).utf8)
        for id in bad {
            #expect(SwitchSealCheck.layoutRefusal(prefix: rig.prefix, commit: id)?.contains("isn't a commit") == true, "\(id)")
            #expect(SwitchSealCheck.installChange(before: [:], after: [:], commit: id).first?.contains("isn't a commit") == true, "\(id)")
            let builds = SwitchSealCheck.sealBuilds(prefix: rig.prefix, commit: id, seen: seen, home: rig.home, vault: rig.host.vault)
            #expect(builds.sealed.isEmpty && builds.refusals.first?.contains("isn't a commit") == true, "\(id): \(builds)")
            #expect(SwitchSealCheck.unitSwap(unit, prefix: rig.prefix, from: id, to: Self.a) == nil && SwitchSealCheck.unitSwap(unit, prefix: rig.prefix, from: Self.b, to: id) == nil)
            for (from, to) in [(id, Self.b), (Self.a, id)] {
                let sealed = SwitchSealCheck.sealUnit(unitFolder: rig.unitFolder, unitFile: "\(NodeStarter.unitName).service", prefix: rig.prefix,
                                                      from: from, to: to, home: rig.home, vault: rig.host.vault)
                #expect(sealed.sealed.isEmpty && sealed.refusals.first?.contains("aren't two commits") == true, "\(from) \(to): \(sealed)")
            }
        }
    }

    /// `build.seal` is taken only for its switch's completed handover to exactly its commit, from the build that
    /// switch recorded (never the caller's word), lately, once. Through the server's own request: a switch it refused
    /// (this world's server has no install root) records no handover, so nothing is sealed after it.
    @Test func buildSealIsTakenOnlyForItsSwitchsCompletedHandoverOnce() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let client = world.world.link.vaultV2
        func seal(_ switchAction: String, commit: String = Self.b, from: String = Self.a) async -> NodeWire.Reply? {
            await world.ask("build.seal", ["commit": .string(commit), "from": .string(from), "switchAction": .string(switchAction)],
                            action: UUID().uuidString.lowercased())
        }
        let switchDigest = LeadVaultV2.digest(String(decoding: NodeWire.line(["commit": NodeWire.Value.string(Self.b)]), as: UTF8.self))

        // No switch at all.
        let alone = try #require(await seal(UUID().uuidString.lowercased()))
        #expect(alone.error?.message.contains("taken only with the action of a switch to \(Self.b)") == true, "\(alone)")
        // A switch the server refused: recorded (its action), no handover.
        let refusedAction = UUID().uuidString.lowercased()
        let refusedSwitch = try #require(await world.ask("build.switch", ["commit": .string(Self.b)], action: refusedAction))
        #expect(!refusedSwitch.ok, "\(refusedSwitch)")
        let afterRefused = try #require(await seal(refusedAction))
        #expect(afterRefused.error?.message.contains("didn't complete a handover") == true, "\(afterRefused)")
        // A failed one: recorded with a failed outcome, no handover.
        let failedAction = UUID().uuidString.lowercased()
        _ = try client.recordUserAction(failedAction, kind: "build.switch", subject: nil, digest: switchDigest)
        try client.finishUserAction(failedAction, kind: "build.switch", outcome: .init(done: false, note: "no build answered", code: "refused"))
        let afterFailed = try #require(await seal(failedAction))
        #expect(afterFailed.error?.message.contains("didn't complete a handover") == true, "\(afterFailed)")
        // A handover to another commit than the seal's.
        let otherAction = UUID().uuidString.lowercased()
        let c = String(repeating: "c", count: 40)
        _ = try client.recordUserAction(otherAction, kind: "build.switch", subject: nil, digest: switchDigest)
        _ = try client.recordUserAction(otherAction, kind: Requests.switchedKind, subject: Self.a, digest: Requests.switchedDigest(from: Self.a, to: c))
        let otherCommit = try #require(await seal(otherAction))
        #expect(otherCommit.error?.message.contains("didn't complete a handover") == true, "\(otherCommit)")
        // A completed handover from A: a caller naming another `from` is refused; A's is taken, once.
        let action = UUID().uuidString.lowercased()
        _ = try client.recordUserAction(action, kind: "build.switch", subject: nil, digest: switchDigest)
        _ = try client.recordUserAction(action, kind: Requests.switchedKind, subject: Self.a, digest: Requests.switchedDigest(from: Self.a, to: Self.b))
        let wrongFrom = try #require(await seal(action, from: c))
        #expect(wrongFrom.error?.message.contains("that switch was from \(Self.a), not \(c)") == true, "\(wrongFrom)")
        let second = UUID().uuidString.lowercased()
        _ = try client.recordUserAction(second, kind: "build.switch", subject: nil, digest: switchDigest)
        _ = try client.recordUserAction(second, kind: Requests.switchedKind, subject: Self.a, digest: Requests.switchedDigest(from: Self.a, to: Self.b))
        let taken = try #require(await seal(second))
        #expect(taken.ok, "\(taken)")
        // Twice (another request, the same switch): refused, nothing sealed again.
        let twice = try #require(await seal(second))
        #expect(twice.error?.message.contains("sealed once already") == true, "\(twice)")
        // Bad ids at the request (and a switch action that isn't an id): refused before anything is read.
        let notAnID = try #require(await world.ask("build.seal", ["commit": .string(Self.b), "from": .string(Self.a), "switchAction": .string("../x")],
                                                   action: UUID().uuidString.lowercased()))
        #expect(notAnID.error?.code == NodeWire.Code.badArgs.rawValue, "\(notAnID)")
        for id in ["../x", String(repeating: "A", count: 40)] {
            let bad = try #require(await seal(UUID().uuidString.lowercased(), commit: id))
            #expect(bad.error?.code == NodeWire.Code.badArgs.rawValue, "\(bad)")
        }
    }

    @Test func aSwappedUnitTextIsTheFollowUpsOnly() {
        let prefix = "/home/u/.vibeswitcher/v2/builds"
        let line = { (commit: String) in "ExecStart=" + NodeUnit.execStart(prefix: prefix, commit: commit).joined(separator: " ") }
        let text = "[Service]\n\(line(Self.b))\nRestart=no\n"
        #expect(SwitchSealCheck.unitSwap(Data(text.utf8), prefix: prefix, from: Self.a, to: Self.b) == Data("[Service]\n\(line(Self.a))\nRestart=no\n".utf8))
        #expect(SwitchSealCheck.unitSwap(Data((text + "ExecStartPre=/bin/true\n").utf8), prefix: prefix, from: Self.a, to: Self.b) == nil)
        #expect(SwitchSealCheck.unitSwap(Data((text + line(Self.b) + "\n").utf8), prefix: prefix, from: Self.a, to: Self.b) == nil)
        #expect(SwitchSealCheck.unitSwap(Data(text.replacingOccurrences(of: " --node ", with: " --node --x ").utf8), prefix: prefix, from: Self.a, to: Self.b) == nil)
    }
}
