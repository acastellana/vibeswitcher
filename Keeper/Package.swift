// swift-tools-version:6.0
import PackageDescription

// The keeper's package (docs/superpowers/specs/2026-11-27-v2-mac-keeper-design.md, "Its program"): root builds it from
// the commit's own objects, alone, with nothing fetched, so it names no package and its sources import only Foundation,
// Security and the C library (`KeeperLintTests`, in VibeCoreTests). The repository's package names it by path, and
// VibePlatform and VibeCore take `VibeKeep` from it, so each part moved here has one implementation.
let package = Package(
    name: "Keeper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VibeKeep", targets: ["VibeKeep"]),
        .executable(name: "vibeswitcher-keeper", targets: ["vibeswitcher-keeper"]),
    ],
    targets: [
        // What the keeper reads and checks: the node's pins record, the walk of a record only root can write, the
        // dynamic code check by audit token, a socket's peer.
        .target(name: "VibeKeep"),
        // The root-owned keeper itself: links VibeKeep alone.
        .executableTarget(name: "vibeswitcher-keeper", dependencies: ["VibeKeep"]),
    ],
    swiftLanguageModes: [.v5]
)
