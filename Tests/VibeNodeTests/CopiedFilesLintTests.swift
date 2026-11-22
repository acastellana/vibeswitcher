import Foundation
import Testing

/// The node's verbatim copies of the Mac app's code (the port map's "Copied from the app"; the architecture review's
/// row 17) held to their originals: a change to either side fails here until the other is brought in step, or the
/// difference is listed below with why. Comments and blank lines aren't compared (a copy says where it came from);
/// each line is compared trimmed, so indentation may differ.
@Suite struct CopiedFilesLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A declaration in a file, by its keyword and name (`struct WitnessWork`, `func usageWaits`): from its line to the
    /// brace that closes it. nil: the whole file.
    struct Part {
        var original: String?
        var copy: String?
    }

    /// A line the copy may have otherwise than its original (`original` nil: a line only the copy has; `copy` nil: a
    /// line only the original has), and why.
    struct Difference {
        var original: String?
        var copy: String?
        var why: String
    }

    struct Copy {
        var copy: String
        var original: String
        var parts: [Part]
        /// The copy is public where the original is internal: a leading `public ` on the copy's lines isn't compared.
        var madePublic = false
        var differences: [Difference] = []
    }

    static let app = "Sources/VibeSwitcher/"
    static let node = "Sources/VibeNode/"
    static let whole = [Part(original: nil, copy: nil)]

    static let copies: [Copy] = [
        Copy(copy: node + "Stats/StatisticsCompared.swift", original: app + "Statistics/StatisticsCompared.swift", parts: whole),
        Copy(copy: node + "Stats/StatisticsQuality.swift", original: app + "Statistics/StatisticsQuality.swift", parts: whole),
        Copy(copy: node + "Stats/StatisticsScorecard.swift", original: app + "Statistics/StatisticsScorecard.swift", parts: whole),
        // `StatisticsModel` itself is the window's, not copied.
        Copy(copy: node + "Stats/StatisticsPage.swift", original: app + "Statistics/StatisticsModel.swift",
             parts: [Part(original: "enum StatisticsRange", copy: "enum StatisticsRange"), Part(original: "struct StatisticsPage", copy: "struct StatisticsPage")]),
        Copy(copy: node + "Engine/UsageWaits.swift", original: app + "MainWindow/Lead/TeamRows.swift",
             parts: [Part(original: "struct ReviewUsageWait", copy: "struct ReviewUsageWait"), Part(original: "func usageWaits", copy: "func reviews")],
             madePublic: true, differences: [
                Difference(original: "struct ReviewUsageWait: Equatable {", copy: "struct ReviewUsageWait: Equatable, Sendable {",
                           why: "public, for the node's lead values, and Sendable across the engine's queues"),
                Difference(original: nil, copy: "init(model: String?, resetsAt: Double?) {", why: "public, so its memberwise init is spelled out"),
                Difference(original: nil, copy: "self.model = model", why: "the init"),
                Difference(original: nil, copy: "self.resetsAt = resetsAt", why: "the init"),
                Difference(original: nil, copy: "}", why: "the init's end"),
                Difference(original: "static func usageWaits(_ board: LeadBoard, team: TeamReading, now: Date, root: String? = nil) -> [String: ReviewUsageWait] {",
                           copy: "static func reviews(_ board: LeadBoard, team: TeamReading, now: Date, root: String? = nil) -> [String: ReviewUsageWait] {",
                           why: "`UsageWaits.reviews`, the node's name for `TeamRows.usageWaits`"),
             ]),
        Copy(copy: node + "Engine/WitnessWork.swift", original: app + "MainWindow/Lead/LeadController.swift",
             parts: [Part(original: "struct WitnessWork", copy: "struct WitnessWork")]),
        Copy(copy: node + "Engine/TeamReading.swift", original: app + "MainWindow/Lead/LeadController.swift",
             parts: [Part(original: "struct TeamReading", copy: "struct TeamReading")], differences: [
                Difference(original: "var reviewUsageWaits: [String: ReviewUsageWait]?", copy: "var reviewUsageWaits: [String: ReviewUsageWait] = [:]",
                           why: "always worked out on the node"),
                Difference(original: "observer: LeadObserver, workerModel: String? = nil) -> TeamReading {",
                           copy: "observer: LeadObserver, inbox: URL, lock: TestLock?, account: NodeUsage.Reading = NodeUsage.Reading()) -> TeamReading {",
                           why: "the steer inboxes under the engine's root, the test lock and the account's usage given, not read from the Mac's files"),
                Difference(original: "team.usage = AccountUsageStore().load()", copy: "team.usage = account.usage", why: "the account given"),
                Difference(original: "team.workerModel = workerModel", copy: "team.workerModel = account.workerModel", why: "the account given"),
                Difference(original: "team.ignoreUsageLimits = MacLimits.load().ignoreUsageLimits", copy: "team.ignoreUsageLimits = account.ignoring",
                           why: "the node's setting, given"),
                Difference(original: "team.held[id] = SteerInbox.pending(tty: session.tty).filter { $0.agentPid == session.pid }.min { $0.at < $1.at }",
                           copy: "team.held[id] = SteerInbox.pending(tty: session.tty, root: inbox).filter { $0.agentPid == session.pid }.min { $0.at < $1.at }",
                           why: "the inboxes under the engine's root"),
                Difference(original: "if !folders.isEmpty, let lock = TestLock.standard() {", copy: "if !folders.isEmpty, let lock {", why: "the lock given"),
                Difference(original: "team.reviewUsageWaits = TeamRows.usageWaits(board, team: team, now: Date(), root: root)",
                           copy: "team.reviewUsageWaits = UsageWaits.reviews(board, team: team, now: account.now, root: root)",
                           why: "the node's copy (UsageWaits.swift), on the given clock"),
             ]),
    ]

    // MARK: Reading

    /// The code of `text`: each line trimmed, no blank line, no comment line.
    static func code(_ text: String, madePublic: Bool = false) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return nil }
            if madePublic, trimmed.hasPrefix("public ") { trimmed.removeFirst("public ".count) }
            return trimmed
        }
    }

    static let quoted = try! Regex(#""(?:\\.|[^"\\])*""#)

    /// The declaration `spec` (`struct Name`, `func name`) in `text`, from its line to the brace that closes it.
    static func declaration(_ spec: String, in text: String) -> String? {
        let words = spec.split(separator: " ")
        guard words.count == 2 else { return nil }
        let start = try! Regex(#"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|final|static|nonisolated)\s+)*"#
                               + words[0] + #"\s+"# + NSRegularExpression.escapedPattern(for: String(words[1])) + #"\b"#)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).firstMatch(of: start) != nil }) else { return nil }
        var depth = 0, opened = false
        for index in first..<lines.count {
            var bare = lines[index].replacing(quoted, with: "\"\"")
            if let comment = bare.range(of: "//") { bare = String(bare[..<comment.lowerBound]) }
            depth += bare.filter { $0 == "{" }.count - bare.filter { $0 == "}" }.count
            opened = opened || bare.contains("{")
            if opened && depth <= 0 { return lines[first...index].joined(separator: "\n") }
        }
        return nil
    }

    /// What differs between `copy`'s part and its original's that isn't listed, said.
    static func problems(_ copy: Copy, original: String, copied: String) -> [String] {
        var found: [String] = []
        for part in copy.parts {
            let name = part.copy ?? "the whole file"
            guard let from = part.original.map({ declaration($0, in: original) }) ?? original else {
                found.append("\(copy.original): no \(part.original ?? "") (the copy's \(name)): moved or renamed?"); continue
            }
            guard let to = part.copy.map({ declaration($0, in: copied) }) ?? copied else {
                found.append("\(copy.copy): no \(name)"); continue
            }
            let changes = code(to, madePublic: copy.madePublic).difference(from: code(from))
            for change in changes {
                switch change {
                case .remove(_, let line, _) where !copy.differences.contains(where: { $0.original == line }):
                    found.append("\(copy.copy) \(name): the original's line isn't in the copy: \(line)")
                case .insert(_, let line, _) where !copy.differences.contains(where: { $0.copy == line }):
                    found.append("\(copy.copy) \(name): the copy's line isn't the original's: \(line)")
                default: break
                }
            }
        }
        return found
    }

    // MARK: The checks

    @Test func eachCopyIsItsOriginalButWhatIsListed() throws {
        for copy in Self.copies {
            let original = try String(contentsOf: Self.repo.appendingPathComponent(copy.original), encoding: .utf8)
            let copied = try String(contentsOf: Self.repo.appendingPathComponent(copy.copy), encoding: .utf8)
            let found = Self.problems(copy, original: original, copied: copied)
            #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n") + "\nBring the copy in step with \(copy.original), or list the difference here with why."))
        }
    }

    /// A listed difference that no longer differs hides the next one: the list stays exact.
    @Test func everyListedDifferenceStillDiffers() throws {
        for copy in Self.copies where !copy.differences.isEmpty {
            let original = try String(contentsOf: Self.repo.appendingPathComponent(copy.original), encoding: .utf8)
            let copied = try String(contentsOf: Self.repo.appendingPathComponent(copy.copy), encoding: .utf8)
            var removed: Set<String> = [], inserted: Set<String> = []
            for part in copy.parts {
                guard let from = part.original.map({ Self.declaration($0, in: original) }) ?? original,
                      let to = part.copy.map({ Self.declaration($0, in: copied) }) ?? copied else { continue }
                for change in Self.code(to, madePublic: copy.madePublic).difference(from: Self.code(from)) {
                    switch change {
                    case .remove(_, let line, _): removed.insert(line)
                    case .insert(_, let line, _): inserted.insert(line)
                    }
                }
            }
            for difference in copy.differences {
                if let line = difference.original { #expect(removed.contains(line), "\(copy.copy): listed, but the original no longer has it: \(line)") }
                if let line = difference.copy { #expect(inserted.contains(line), "\(copy.copy): listed, but the copy no longer has it: \(line)") }
            }
        }
    }

    /// The lint fires: a line changed on either side, a declaration gone, and a listed difference taken.
    @Test func theLintFindsADrift() {
        let original = """
            // The original.
            struct Thing {
                var a = 1
                func b() -> String { "{" }
            }
            struct Other {}
            """
        let copy = Copy(copy: "copy.swift", original: "original.swift", parts: [Part(original: "struct Thing", copy: "struct Thing")],
                        differences: [Difference(original: "var a = 1", copy: "var a = 2", why: "a test's")])
        let same = original.replacingOccurrences(of: "// The original.", with: "// A copy, its comment its own.").replacingOccurrences(of: "var a = 1", with: "    var a = 2")
        #expect(Self.problems(copy, original: original, copied: same).isEmpty, "\(Self.problems(copy, original: original, copied: same))")
        let drifted = same.replacingOccurrences(of: "func b()", with: "func c()")
        #expect(Self.problems(copy, original: original, copied: drifted).count == 2)
        #expect(Self.problems(copy, original: original, copied: "struct Elsewhere {}").count == 1)
        #expect(Self.declaration("struct Thing", in: original)?.hasSuffix("}") == true)
        #expect(Self.declaration("struct Thing", in: original)?.contains("Other") == false, "the string's brace doesn't end it early, nor late")
    }
}
