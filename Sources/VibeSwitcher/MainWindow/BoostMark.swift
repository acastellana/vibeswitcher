import SwiftUI
import VibeCore

/// The main window's Boost mark: the menu bar's small orange bolt (`StatusIcon`'s), in the toolbar while Boost mode is
/// on. Its texts come from the decision `BoostWatch` published (no file is read for them: the main thread only reads
/// what the watch holds). A click opens Settings › General at the Boost section.
struct BoostMark: View {
    let state: BoostState
    let open: () -> Void

    /// VoiceOver's: "Boost on: automatic: away, on AC".
    static func label(_ state: BoostState) -> String { "Boost on: \(state.why)" }

    /// The hover help: why it's on, the limits it raised, and where it's set.
    static func help(_ state: BoostState) -> String {
        let limits = state.limits
        return "Boost on (\(state.why))\n"
            + "Raised limits: a load of \(MacLoad.number(limits.loadThreshold)), \(limits.maxSessions) team sessions on this Mac, "
            + "\(limits.maxWorkers) workers per project, \(limits.heavySlots) test and build slots\n"
            + "Click for Settings › General › Boost"
    }

    var body: some View {
        Button(action: open) {
            // The button's label names it.
            Image(systemName: "bolt.fill").accessibilityHidden(true)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Self.help(state))
        .accessibilityLabel(Self.label(state))
        .accessibilityHint("Opens Settings at Boost")
    }
}
