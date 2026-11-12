// swift-tools-version:6.0
import PackageDescription

// Each test target refuses to run on the user's own ~/.vibeswitcher, checked as its bundle loads (`@_section`, an
// initializer: `refuseTheAccountRoot` in its TestSupport.swift).
let testSettings: [SwiftSetting] = [.enableExperimentalFeature("SymbolLinkageMarkers")]

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
    // PlatformLintPending.txt: the files still to be cleaned, read from the source tree (`PlatformLintTests`).
    .testTarget(name: "VibePlatformTests", dependencies: ["VibePlatform"], exclude: ["PlatformLintPending.txt"],
                swiftSettings: testSettings),
    // Each of `notYetPortableTargets` moves up here when it compiles on Linux: VibeCore (the plan's Task 11, with
    // VibeCoreTests in Task 12), then VibeHost and the three executables (Task 13).
]
// VIBE_LINUX_ALL=1 adds the portable targets that don't compile on Linux yet, only to count their errors, and with
// them swift-crypto: CryptoKit's API where there is no CryptoKit. A build with it adds swift-crypto's pins to
// Package.resolved, which is the Mac's file too: put the file back after it (`git restore Package.resolved`). The
// pins aren't committed while the Mac's package doesn't name swift-crypto, since a Mac build can take them out again.
let measuring = Context.environment["VIBE_LINUX_ALL"] == "1"
let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")
let notYetPortableTargets: [Target] = [
    .target(name: "VibeCore", dependencies: ["VibePlatform", crypto]),
    .target(name: "VibeHost", dependencies: ["VibeCore", .product(name: "SwiftTerm", package: "SwiftTerm"), crypto]),
    .executableTarget(name: "vibeswitcher-host", dependencies: ["VibeHost"]),
    .executableTarget(name: "vibeswitcher-hook", dependencies: ["VibeCore"]),
    .executableTarget(name: "vibeswitcher-mcp", dependencies: ["VibeCore"]),
]

let package = Package(
    name: "VibeSwitcher",
    dependencies: [
        // Named before a target here uses it, as the Mac's package names it: Package.resolved then holds the same
        // pins on both systems (SwiftPM removes the file when a package names no dependency).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ] + (measuring ? [.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")] : []),
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
    ],
    targets: [
        // Every system call the shared code makes, one implementation per system.
        .target(name: "VibePlatform"),
        // Shared model, status rules, process table and hook installer.
        .target(name: "VibeCore", dependencies: ["VibePlatform"]),
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
