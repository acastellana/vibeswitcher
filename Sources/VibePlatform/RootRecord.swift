import Foundation
import VibeKeep

// The walk of a record only root can write, and its refusal, live in the keeper's package (the keeper reads the pins
// record through it): Keeper/Sources/VibeKeep/RootRecord.swift, with RootRecord+Darwin.swift and RootRecord+Linux.swift
// (`hasExtendedACL`), moved there unchanged. Each name here is a one-line call into it.
extension Platform.Files {
    /// Why a root-owned record couldn't be taken: said in one plain line, naming the path and what is wrong with it.
    public typealias RootRecordRefusal = Keep.Files.RootRecordRefusal

    /// The bytes of a record only root can write, or why it isn't one: `Keep.Files.readRootRecord`, which says how.
    public static func readRootRecord(_ components: [String], base: String = "/", maxBytes: Int,
                                      owner: (String, uid_t) -> uid_t = { $1 }) -> Result<Data, RootRecordRefusal> {
        Keep.Files.readRootRecord(components, base: base, maxBytes: maxBytes, owner: owner)
    }

    /// Whether the file `fd` names carries an extended ACL with any entry (Linux: false): `Keep.Files.hasExtendedACL`.
    public static func hasExtendedACL(_ fd: Int32) -> Bool? { Keep.Files.hasExtendedACL(fd) }
}
