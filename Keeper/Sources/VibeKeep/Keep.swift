import Foundation

/// What the keeper reads and checks, in a package of its own with no dependency (the keeper's design, "Its program";
/// docs/superpowers/specs/2026-11-27-v2-mac-keeper-design.md): moved here unchanged from VibePlatform, and called from
/// there by their old names, each a one-line call into this (`NodePins`, from VibeCore, is here whole, and VibeCore's
/// name for it an alias). Each part is the namespace of the platform's that held it:
/// - `Files`: the walk of a record only root can write (`Platform.Files.readRootRecord`);
/// - `Service`: the pins record's place (`Platform.Service.nodePinsRecord`);
/// - `CodeIdentity`: Security's dynamic check by audit token (`Platform.CodeIdentity`'s `runs(_:cdhash:)` and
///   `isHardened`), the Mac's alone;
/// - `Sockets`: a socket's peer (`Platform.Sockets.peerUID` and `peerToken`) and an audit token's fields, the Mac's.
public enum Keep {
    public enum Files {}
    public enum Service {}
    public enum CodeIdentity {}
    public enum Sockets {}
}
