// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VibeSwitcher",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Terminal emulator: the window's terminal view and the host's headless terminal.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ],
    targets: [
        // Shared model, status rules, process table and hook installer.
        .target(name: "VibeCore"),
        // The session host's internals: PTYs, replay buffers, the socket server.
        .target(name: "VibeHost", dependencies: ["VibeCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        // The menu bar app.
        .executableTarget(name: "VibeSwitcher", dependencies: ["VibeCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        // Background process that keeps window sessions alive across app restarts.
        .executableTarget(name: "vibeswitcher-host", dependencies: ["VibeHost"]),
        // Tiny binary that Claude Code / Codex hooks invoke on every lifecycle event.
        .executableTarget(name: "vibeswitcher-hook", dependencies: ["VibeCore"]),
        .testTarget(name: "VibeCoreTests", dependencies: ["VibeCore"]),
        // Depends on the host executable too: sessions are started through it (`--pty-exec`).
        .testTarget(name: "VibeHostTests", dependencies: ["VibeHost", "VibeCore", "vibeswitcher-host"]),
    ],
    swiftLanguageModes: [.v5]
)
