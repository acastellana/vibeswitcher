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
        // The project lead's tool server (MCP over stdio) for the lead, its workers and its verifiers.
        .executableTarget(name: "vibeswitcher-mcp", dependencies: ["VibeCore"]),
        .testTarget(name: "VibeCoreTests", dependencies: ["VibeCore"]),
        // Depends on the host executable too: sessions are started through it (`--pty-exec`). Fixtures: terminal
        // output captured from scratch programs.
        .testTarget(name: "VibeHostTests", dependencies: ["VibeHost", "VibeCore", "vibeswitcher-host"],
                    resources: [.copy("Fixtures")]),
        // The app's menus and window commands. The host too: a scratch one runs the sessions of a test of the app's client.
        .testTarget(name: "VibeSwitcherTests", dependencies: ["VibeSwitcher", "VibeCore", "VibeHost", "vibeswitcher-host"]),
    ],
    swiftLanguageModes: [.v5]
)
