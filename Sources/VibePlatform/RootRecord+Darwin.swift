#if canImport(Darwin)
import Foundation

extension Platform.Files {
    /// Whether the file `fd` names carries an extended ACL with any entry (`acl_get_fd_np`, `ACL_TYPE_EXTENDED`): mode bits
    /// don't show an ACL's grant (`chmod +a "everyone allow add_file"`). nil when it can't be read.
    public static func hasExtendedACL(_ fd: Int32) -> Bool? {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT ? false : nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
    }
}
#endif
