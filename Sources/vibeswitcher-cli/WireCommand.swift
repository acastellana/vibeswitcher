import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher wire-vectors --out DIR`, hidden like `install-record`: the web client's validators and vectors written
/// from `VibeNode`'s own schema and encoders (the live plan's LW-D10 and E1, lane E's file), `WireVectors.files()` into
/// DIR, a folder that exists (it makes none), each file replaced whole through `VibePaths.writePrivate` (git keeps no
/// mode but the executable bit, so a checked-in file is the same). The repository's are `WebApp/wire`, and `WireVectorsTests` fails
/// while they differ from what this writes. It reads nothing and asks no server.
enum WireCommand {
    static let usage = "usage: vibeswitcher wire-vectors --out DIR"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2, arguments[0] == "--out", !arguments[1].isEmpty else {
            Platform.Stdio.error(usage + "\n")
            return 64
        }
        let folder = URL(fileURLWithPath: arguments[1])
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            Platform.Stdio.error("vibeswitcher wire-vectors: no folder \(folder.path)\n")
            return 73
        }
        do {
            for (name, data) in WireVectors.files().sorted(by: { $0.key < $1.key }) {
                let file = folder.appendingPathComponent(name)
                try VibePaths.writePrivate(data, to: file)
                Platform.Stdio.output("wrote \(file.path)\n")
            }
        } catch {
            Platform.Stdio.error("vibeswitcher wire-vectors: \(error.localizedDescription)\n")
            return 73
        }
        return 0
    }
}
