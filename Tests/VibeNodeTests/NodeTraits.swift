import Testing
import VibeCore

/// The traits the engine's suites share (the engine plan's Global Constraints).
enum NodeTraits {
    /// A suite that needs a scratch host (`NodeTestHost`: its app is a connector's connections, which only Linux has),
    /// the server child or `/proc`: Linux only. The Mac's core job runs the rest of `VibeNodeTests`.
    static let linuxOnly: ConditionTrait = .enabled(if: !Platform.CodeIdentity.isAvailable,
                                                    "Linux only: a scratch host's app is its connector's connections, which the Mac has none of")
}
