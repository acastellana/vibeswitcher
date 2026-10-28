import Foundation
import Testing
@testable import VibeCore

struct FuzzyMatchTests {
    @Test func charactersMustAppearInOrder() {
        #expect(FuzzyMatch.score("pj", "project-c") != nil)
        #expect(FuzzyMatch.score("PJ", "project-c") != nil)
        #expect(FuzzyMatch.score("jp", "project-c") == nil)
        #expect(FuzzyMatch.score("x", "project-c") == nil)
        #expect(FuzzyMatch.score("", "project-c") == 0)
    }

    @Test func wordStartsWin() {
        let ranked = FuzzyMatch.rank(["project-c sessions", "New Session"], query: "ns") { $0 }
        #expect(ranked.first == "New Session")
        #expect(FuzzyMatch.score("vs", "VibeSwitcher")! > FuzzyMatch.score("vs", "devserver")!)
    }

    @Test func consecutiveBeatsScattered() {
        #expect(FuzzyMatch.score("ject", "project-c")! > FuzzyMatch.score("ject", "jxexcxtx")!)
    }

    @Test func shorterWinsTies() {
        let ranked = FuzzyMatch.rank(["alpha project long name here", "alpha"], query: "alp") { $0 }
        #expect(ranked == ["alpha", "alpha project long name here"])
    }

    @Test func rankDropsMisses_keepsOrderOnEqualScores_andEmptyQueryIsIdentity() {
        #expect(FuzzyMatch.rank(["ab", "zz", "ab"].enumerated().map { $0 }, query: "ab") { $0.element }.map(\.offset) == [0, 2])
        #expect(FuzzyMatch.rank(["b", "a"], query: "") { $0 } == ["b", "a"])
    }
}
