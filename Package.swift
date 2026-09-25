// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VibeSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared model, status rules, process table and hook installer.
        .target(name: "VibeCore"),
        // The menu bar app.
        .executableTarget(name: "VibeSwitcher", dependencies: ["VibeCore"]),
        // Tiny binary that Claude Code / Codex hooks invoke on every lifecycle event.
        .executableTarget(name: "vibeswitcher-hook", dependencies: ["VibeCore"]),
        .testTarget(name: "VibeCoreTests", dependencies: ["VibeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
