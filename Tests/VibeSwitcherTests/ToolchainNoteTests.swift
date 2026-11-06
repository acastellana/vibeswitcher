import AppKit
import Foundation
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

@MainActor
@Suite(.serialized)
struct ToolchainNoteTests {
    let temp = Scratch()

    final class Reader: @unchecked Sendable {
        let lock = NSLock()
        private var changed = false
        func change() { lock.withLock { changed = true } }
        func read() -> ToolchainSnapshot {
            #expect(!Thread.isMainThread)
            return lock.withLock {
                ToolchainSnapshot(developerDir: "/Applications/Xcode.app/Contents/Developer", swift: changed ? "Swift 6.4.2" : "Swift 6.4.1",
                                  sdkPath: "/SDKs/MacOSX27.sdk", sdkVersion: "27", commandLineTools: "27.0", xcodeExists: true)
            }
        }
    }

    @Test func backgroundCheckNotifiesOnceAndKeepsTheWindowNote() async throws {
        let folder = temp.url("toolchain-app")
        let host = HostClient(socketPath: folder.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { folder }, cwd: { _ in nil }, arguments: { _ in [] }))
        let vault = LeadVault(folder: folder.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") })
        let controller = LeadController(host: host, store: store, vault: vault, inbox: folder, home: folder.path) { _ in "true" }
        let reader = Reader()
        var banners: [String] = []
        controller.tellUser = { _, body in banners.append(body) }
        controller.watchToolchain(ToolchainWatch(file: folder.appendingPathComponent("toolchain.json"), read: reader.read))
        await withCheckedContinuation { continuation in controller.lookAtToolchain { continuation.resume() } }
        #expect(banners.isEmpty)
        reader.change()
        await withCheckedContinuation { continuation in controller.lookAtToolchain { continuation.resume() } }
        #expect(banners.count == 1)
        #expect(controller.toolchainNote == banners.first)
        #expect(controller.toolchainNote?.contains("Swift 6.4.1 → Swift 6.4.2") == true)
        await withCheckedContinuation { continuation in controller.lookAtToolchain { continuation.resume() } }
        #expect(banners.count == 1)
    }

    @Test func noteRendersInLightAndDark() throws {
        let before = ToolchainSnapshot(developerDir: "/Library/Developer/CommandLineTools", swift: "Swift 6.4.1", sdkPath: "/SDKs/MacOSX27.sdk",
                                       sdkVersion: "27", commandLineTools: "27.0", xcodeExists: true)
        var after = before
        after.swift = "Swift 6.4.2"
        after.sdkVersion = "27.2"
        let note = try #require(LeadWitness.toolchainText(before: before, after: after))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSHostingView(rootView: ToolchainNoteView(note: note))
            view.appearance = NSAppearance(named: appearance)
            let size = view.fittingSize
            #expect(size.width == 480)
            #expect(size.height > 100 && size.height < 700)
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(!png.isEmpty)
            if let output = ProcessInfo.processInfo.environment["TOOLCHAIN_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("toolchain-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
}
