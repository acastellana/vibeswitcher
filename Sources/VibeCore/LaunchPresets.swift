import Foundation

/// Building what a preset runs.
public enum LaunchPlan {
    /// Shell variable names: a letter or underscore, then letters, digits, underscores.
    public static func validEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first),
              name.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) })
        else { return false }
        return first.isASCII
    }
}
