// swift-tools-version:6.0
import PackageDescription

// Each test target refuses to run on the user's own ~/.vibeswitcher, checked as its bundle loads (`@_section`, an
// initializer: `refuseTheAccountRoot` in its TestSupport.swift).
let testSettings: [SwiftSetting] = [.enableExperimentalFeature("SymbolLinkageMarkers")]

// swift-crypto: CryptoKit's API where there is no CryptoKit. The package names it on both systems, so Package.resolved
// holds the same pins on the Mac and on Linux; VibeCore and VibeHost depend on it only in a build for Linux (the
// condition below), and a build for the Mac uses CryptoKit. Sources/VibeCore/PlatformExport.swift exports the one
// or the other to every file.
let swiftCrypto: Package.Dependency = .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")
let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))

#if os(Linux)
// On Linux (the system this manifest is read on, not the one built for) the package is only the portable targets
// that compile there so far: docs/superpowers/plans/2026-11-12-v2-stage-1-core-on-linux.md. The Mac's package is
// below, whole.
let portableTargets: [Target] = [
    // What Swift can't reach through Glibc's or Musl's module (what the C library shows only under `_GNU_SOURCE`, or
    // has no wrapper for), in C. Imported only by VibePlatform.
    .target(name: "CVibePlatform"),
    // Every system call the shared code makes, one implementation per system.
    .target(name: "VibePlatform", dependencies: ["CVibePlatform"]),
    // Shared model, status rules, process table and hook installer (the plan's Task 11; what only the Mac has is in
    // Sources/VibeCore/MacOnly, compiled there alone).
    .target(name: "VibeCore", dependencies: ["VibePlatform", crypto]),
    // Tiny binary that Claude Code / Codex hooks invoke on every lifecycle event.
    .executableTarget(name: "vibeswitcher-hook", dependencies: ["VibeCore"]),
    // The project lead's tool server (MCP over stdio) for the lead, its workers and its verifiers.
    .executableTarget(name: "vibeswitcher-mcp", dependencies: ["VibeCore"]),
    // PlatformLintPending.txt: the files still to be cleaned, read from the source tree (`PlatformLintTests`).
    .testTarget(name: "VibePlatformTests", dependencies: ["VibePlatform"], exclude: ["PlatformLintPending.txt"],
                swiftSettings: testSettings),
    // Still to come: VibeCoreTests (Task 12), and each of `notYetPortableTargets` when it compiles on Linux (the
    // session host: stage 2).
]
// VIBE_LINUX_ALL=1 adds the portable targets that don't compile on Linux yet, only to count their errors
// (scripts/ci/linux-core-errors.sh). The package's dependencies are the same with and without it, and so is
// Package.resolved.
let measuring = Context.environment["VIBE_LINUX_ALL"] == "1"
let notYetPortableTargets: [Target] = [
    .target(name: "VibeHost", dependencies: ["VibeCore", .product(name: "SwiftTerm", package: "SwiftTerm"), crypto]),
    .executableTarget(name: "vibeswitcher-host", dependencies: ["VibeHost"]),
]

let package = Package(
    name: "VibeSwitcher",
    dependencies: [
        // Both named before a target here uses them, as the Mac's package names them: Package.resolved then holds
        // the same pins on both systems (SwiftPM removes a pin when the package no longer names its dependency).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
        swiftCrypto,
    ],
    targets: portableTargets + (measuring ? notYetPortableTargets : []),
    swiftLanguageModes: [.v5]
)
#else
let package = Package(
    name: "VibeSwitcher",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Terminal emulator: the window's terminal view and the host's headless terminal.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
        swiftCrypto,
    ],
    targets: [
        // Every system call the shared code makes, one implementation per system.
        .target(name: "VibePlatform"),
        // Shared model, status rules, process table and hook installer.
        .target(name: "VibeCore", dependencies: ["VibePlatform", crypto]),
        // The session host's internals: PTYs, replay buffers, the socket server.
        .target(name: "VibeHost", dependencies: ["VibeCore", .product(name: "SwiftTerm", package: "SwiftTerm"), crypto]),
        // The menu bar app.
        .executableTarget(name: "VibeSwitcher", dependencies: ["VibeCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        // Background process that keeps window sessions alive across app restarts.
        .executableTarget(name: "vibeswitcher-host", dependencies: ["VibeHost"]),
        // Tiny binary that Claude Code / Codex hooks invoke on every lifecycle event.
        .executableTarget(name: "vibeswitcher-hook", dependencies: ["VibeCore"]),
        // The project lead's tool server (MCP over stdio) for the lead, its workers and its verifiers.
        .executableTarget(name: "vibeswitcher-mcp", dependencies: ["VibeCore"]),
        // PlatformLintPending.txt: the files still to be cleaned, read from the source tree (`PlatformLintTests`).
        .testTarget(name: "VibePlatformTests", dependencies: ["VibePlatform"], exclude: ["PlatformLintPending.txt"],
                    swiftSettings: testSettings),
        .testTarget(name: "VibeCoreTests", dependencies: ["VibeCore"], swiftSettings: testSettings),
        // Depends on the host executable too: sessions are started through it (`--pty-exec`). Fixtures: terminal
        // output captured from scratch programs.
        .testTarget(name: "VibeHostTests", dependencies: ["VibeHost", "VibeCore", "vibeswitcher-host"],
                    resources: [.copy("Fixtures")], swiftSettings: testSettings),
        // The app's menus and window commands. The host too: a scratch one runs the sessions of a test of the app's client.
        // Fixtures: the chat bench's made-up transcript, read from the source tree (`ChatBenchTests`).
        .testTarget(name: "VibeSwitcherTests", dependencies: ["VibeSwitcher", "VibeCore", "VibeHost", "vibeswitcher-host"],
                    exclude: ["Fixtures"], swiftSettings: testSettings),
    ],
    swiftLanguageModes: [.v5]
)
#endif
