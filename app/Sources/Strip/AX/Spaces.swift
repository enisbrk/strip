import AppKit
import StripCore

// Private SkyLight calls (used by yabai, AeroSpace, Amethyst…) to tell which Space a window is on.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: Int32) -> UInt64

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
private func CGSManagedDisplayGetCurrentSpace(_ cid: Int32, _ displayUUID: CFString) -> UInt64

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?

typealias SpaceID = UInt64

enum Spaces {
    private static let connection = CGSMainConnectionID()

    static func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The Space currently shown on a display.
    static func current(onDisplay id: CGDirectDisplayID) -> SpaceID {
        if let uuid = displayUUID(id) {
            let space = CGSManagedDisplayGetCurrentSpace(connection, uuid as CFString)
            if space != 0 { return space }
        }
        // "Displays have separate Spaces" turned off: one Space across all displays.
        return CGSGetActiveSpace(connection)
    }

    /// The Space a window is on (nil for windows on every Space or unknown windows).
    static func space(of window: WindowID) -> SpaceID? {
        let all: Int32 = 0x7
        guard let spaces = CGSCopySpacesForWindows(connection, all, [NSNumber(value: window)] as CFArray)?
            .takeRetainedValue() as? [NSNumber], spaces.count == 1 else { return nil }
        return spaces[0].uint64Value
    }
}
