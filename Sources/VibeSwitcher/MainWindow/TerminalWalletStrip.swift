import SwiftUI

/// The selected session's wallet cards under its terminal, for a session with no chat to pin them under (see
/// `WindowModel.walletUnderTerminal(for:)`). Nothing filed: nothing drawn, and the terminal keeps its full height.
struct TerminalWalletStrip: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var desk: WalletDesk
    /// After a card's button: the keyboard goes back to the terminal.
    let acted: () -> Void

    var body: some View {
        if let session = model.walletUnderTerminal(for: model.selectedRow), !desk.cards(for: session).isEmpty {
            VStack(spacing: 0) {
                Divider()
                WalletRequestStrip(desk: desk, session: session, acted: acted)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
