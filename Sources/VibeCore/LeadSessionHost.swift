import Foundation

/// The session host as the lead's code drives it, whoever holds the connection: the app's `HostClient`, or the node's
/// link. Only what that code uses through it so far: a session's screen, and keys typed into it as one unit.
public protocol LeadSessionHost: AnyObject {
    /// The screen of session `id` as text (nil: the host couldn't say).
    func screen(_ id: UUID, completion: @escaping (String?) -> Void)
    /// Types `writes` into session `id` as one unit, after the session's units before it: `gate` is asked before each
    /// write (by its index) and answers when it likes, false stops the unit there; `confirmed` hears whether it all went.
    func type(_ writes: [HostInput.Write], into id: UUID, gate: ((Int, @escaping (Bool) -> Void) -> Void)?,
              confirmed: @escaping (Bool) -> Void)
}
