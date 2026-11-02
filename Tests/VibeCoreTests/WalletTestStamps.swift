import Foundation
import VibeCore

/// A lead vault standing in for the session host's: it stamps a test's wallet requests for the session each names, as
/// the host does for a process in a session of the user's (see `WalletStamp`), and checks stamps for a test's desk.
enum WalletTestStamps {
    static let book = LeadVault.Book()

    struct Refused: Error {}

    /// The vault's stamp on `request` for the session it names, sealed as that session's process asks for it.
    static func stamp(_ request: WalletRequest) throws -> WalletStamp {
        let session = request.requestedBy.session.lowercased()
        let digest = WalletStamp.digest(try request.encoded())
        guard case .seal(let seal) = book.answer(.sealWalletRequest(session: session, digest: digest), from: .session(session), userOpened: true) else { throw Refused() }
        return WalletStamp(session: session, digest: digest, seal: seal)
    }

    /// Which of `stamps` carry the vault's seal (a desk's `verifyStamps`).
    static func verify(_ stamps: [WalletStamp]) throws -> [Bool] {
        guard case .verified(let valid) = book.answer(.verifyWalletRequests(stamps), from: .app) else { throw Refused() }
        return valid
    }
}

extension WalletAsk {
    /// Files `request` with `WalletTestStamps`' stamp for the session it names, as `vs-wallet request` does from it.
    static func file(_ request: WalletRequest, in folder: URL) throws {
        try file(request, stamp: WalletTestStamps.stamp(request), in: folder)
    }
}
