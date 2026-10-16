import Foundation
import Testing
@testable import VibeCore

struct FuzzyMatchTests {
    @Test func charactersMustAppearInOrder() {
        #expect(FuzzyMatch.score("gs", "genswap") != nil)
        #expect(FuzzyMatch.score("GS", "genswap") != nil)
        #expect(FuzzyMatch.score("sg", "genswap") == nil)
        #expect(FuzzyMatch.score("x", "genswap") == nil)
        #expect(FuzzyMatch.score("", "genswap") == 0)
    }

    @Test func wordStartsWin() {
        let ranked = FuzzyMatch.rank(["genswap session", "New Session"], query: "ns") { $0 }
        #expect(ranked.first == "New Session")
        #expect(FuzzyMatch.score("vs", "VibeSwitcher")! > FuzzyMatch.score("vs", "devserver")!)
    }

    @Test func consecutiveBeatsScattered() {
        #expect(FuzzyMatch.score("swap", "genswap")! > FuzzyMatch.score("swap", "sxwxaxpx")!)
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
