import Foundation

/// `vibeswitcher web [--revoke]`: a pairing code for the web page, or every token dropped (the live plan's F1, lane F's
/// file). A stub until F1 builds it.
enum WebCommand {
    static func run(_ arguments: [String]) -> Int32 {
        try? FileHandle.standardError.write(contentsOf: Data("vibeswitcher web: not built yet\n".utf8))
        return 69
    }
}
