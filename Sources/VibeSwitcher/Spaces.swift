import Darwin
import Foundation

/// Which desktop (Space) each window is on, numbered like Mission Control: 1, 2, 3… across displays.
///
/// macOS has no public API for this, so it uses the same private SkyLight calls as yabai and
/// Hammerspoon. They're resolved at runtime with dlsym: if a future macOS drops them, `ordinals`
/// returns nothing and sessions fall back to on-screen position order instead of the app crashing.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let functions: (MainConnection, CopyDisplaySpaces, CopySpacesForWindows)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "SLSMainConnectionID"),
              let displays = dlsym(handle, "CGSCopyManagedDisplaySpaces") ?? dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let forWindows = dlsym(handle, "CGSCopySpacesForWindows") ?? dlsym(handle, "SLSCopySpacesForWindows")
        else { return nil }
        return (unsafeBitCast(main, to: MainConnection.self),
                unsafeBitCast(displays, to: CopyDisplaySpaces.self),
                unsafeBitCast(forWindows, to: CopySpacesForWindows.self))
    }()

    struct Placement {
        let desktop: Int
        /// The window has a full-screen space of its own.
        let fullscreen: Bool
    }

    /// Desktop number (1-based) for each window id; windows it can't place are left out.
    static func ordinals(forWindowIDs windowIDs: [Int]) -> [Int: Int] {
        placements(forWindowIDs: windowIDs).mapValues(\.desktop)
    }

    static func placements(forWindowIDs windowIDs: [Int]) -> [Int: Placement] {
        guard let (mainConnection, copyDisplaySpaces, copySpacesForWindows) = functions, !windowIDs.isEmpty else { return [:] }
        let connection = mainConnection()
        guard let displays = copyDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return [:] }

        var ordinalBySpace: [Int: Int] = [:]
        var fullscreenSpaces: Set<Int> = []
        var next = 1
        for display in displays {
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = space["ManagedSpaceID"] as? Int ?? space["id64"] as? Int else { continue }
                ordinalBySpace[id] = next
                if space["type"] as? Int == 4 { fullscreenSpaces.insert(id) } // 4 = full-screen app space
                next += 1
            }
        }

        var result: [Int: Placement] = [:]
        for windowID in windowIDs {
            // Mask 0x7: current, other and fullscreen spaces.
            let spaces = copySpacesForWindows(connection, 0x7, [windowID] as CFArray)?.takeRetainedValue() as? [Int] ?? []
            if let space = spaces.min(by: { (ordinalBySpace[$0] ?? .max) < (ordinalBySpace[$1] ?? .max) }),
               let ordinal = ordinalBySpace[space] {
                result[windowID] = Placement(desktop: ordinal, fullscreen: fullscreenSpaces.contains(space))
            }
        }
        return result
    }
}
