import Foundation
import Testing
import VibePlatform

/// The install's Mac signing (scripts/lib/mac-sign.sh, the review of 2026-11-21): a copy of the built server and command
/// line, signed as the install signs them, carries the Hardened Runtime as Security reads it from disk
/// (`Platform.CodeIdentity.isSignedHardened`), so the processes they start can pass `isHardened` (the voice's caller
/// check, the command line's server check). A copy signed without it doesn't. The Mac runner's: Linux signs nothing.
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's code signing"))
struct MacSigningTests {
    let scratch = Scratch()

    private func sign(_ file: URL) async throws -> CommandRun {
        let lib = packageFolder.appendingPathComponent("scripts/lib/mac-sign.sh").path
        return try await run(URL(fileURLWithPath: "/bin/bash"), ["-c", "source \"$1\" && mac_sign_hardened \"$2\"", "sign", lib, file.path],
                             environment: ["PATH": "/usr/bin:/bin"])
    }

    private func copy(_ product: String, into folder: URL) throws -> URL {
        let file = folder.appendingPathComponent(product)
        try FileManager.default.copyItem(at: builtProducts.appendingPathComponent(product), to: file)
        return file
    }

    @Test func theInstallsSigningGivesTheServerAndCommandLineTheHardenedRuntime() async throws {
        let folder = scratch.url("mac-sign")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for product in ["vibeswitcher-server", "vibeswitcher-cli"] {
            let file = try copy(product, into: folder)
            let signed = try await sign(file)
            #expect(signed.status == 0, "\(product): \(signed.errors)")
            #expect(Platform.CodeIdentity.isSignedHardened(atPath: file.path) == true, "\(product)")
            #expect(Platform.CodeIdentity.cdhash(atPath: file.path) != nil, "\(product)")
        }
    }

    /// Signed ad hoc without `--options runtime` (as a plain `swift build` links it): not hardened; and the lib signs
    /// nothing through a link.
    @Test func aCopySignedWithoutTheRuntimeIsntHardened() async throws {
        let folder = scratch.url("mac-sign-plain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try copy("vibeswitcher-server", into: folder)
        let plain = try await run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", file.path], environment: [:])
        #expect(plain.status == 0, "\(plain.errors)")
        #expect(Platform.CodeIdentity.isSignedHardened(atPath: file.path) == false)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let refused = try await sign(link)
        #expect(refused.status == 1 && refused.errors.contains("not a regular file"))
        #expect(Platform.CodeIdentity.isSignedHardened(atPath: file.path) == false)
    }
}
