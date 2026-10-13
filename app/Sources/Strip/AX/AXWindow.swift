import AppKit
import ApplicationServices
import StripCore

/// Private but stable API (used by yabai, AeroSpace, Rectangle…) mapping an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func windowID(of element: AXUIElement) -> WindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String, as _: T.Type = T.self) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    /// Global top-left-origin rect (AX space) for an AppKit screen rect (bottom-left origin).
    static func axRect(fromAppKit rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// A top-level window of another application, addressed through the Accessibility API.
@MainActor
final class AXWindow {
    let element: AXUIElement
    let id: WindowID
    let pid: pid_t

    init?(element: AXUIElement, pid: pid_t) {
        guard let id = AX.windowID(of: element) else { return nil }
        self.element = element
        self.id = id
        self.pid = pid
    }

    var role: String? { AX.value(element, kAXRoleAttribute) }
    var subrole: String? { AX.value(element, kAXSubroleAttribute) }
    var title: String { AX.value(element, kAXTitleAttribute) ?? "" }
    var isMinimized: Bool { AX.value(element, kAXMinimizedAttribute) ?? false }
    var isFullscreen: Bool { AX.value(element, "AXFullScreen") ?? false }
    var isResizable: Bool { AX.isSettable(element, kAXSizeAttribute) }
    var isModal: Bool { AX.value(element, kAXModalAttribute) ?? false }

    var isStandardWindow: Bool {
        role == kAXWindowRole && subrole == kAXStandardWindowSubrole
    }

    var frame: CGRect? {
        guard let posValue: AXValue = AX.value(element, kAXPositionAttribute),
              let sizeValue: AXValue = AX.value(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    func setPosition(_ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AX.set(element, kAXPositionAttribute, v) }
    }

    func setSize(_ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AX.set(element, kAXSizeAttribute, v) }
    }

    /// Size → position → size, the same dance Rectangle uses so screen-edge constraints don't clip the result.
    func setFrame(_ rect: CGRect) {
        setSize(rect.size)
        setPosition(rect.origin)
        setSize(rect.size)
    }

    /// Brings the window in front of other windows without activating its app.
    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Raises the window and makes its app frontmost.
    func focus() {
        // App first: activating an app brings its own last key window forward, so the window we
        // want must be made main and raised after that (matters for apps with several windows).
        let app = AXUIElementCreateApplication(pid)
        AX.set(app, kAXFrontmostAttribute, kCFBooleanTrue)
        AX.set(element, kAXMainAttribute, kCFBooleanTrue)
        AX.set(element, kAXFocusedAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}

extension AXUIElement {
    /// Temporarily turns off AXEnhancedUserInterface (set by VoiceOver-ish tools and some apps),
    /// which otherwise makes apps animate or ignore programmatic frame changes.
    @MainActor
    static func withEnhancedUIDisabled(pids: Set<pid_t>, _ body: () -> Void) {
        var restore: [AXUIElement] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            if AX.value(app, "AXEnhancedUserInterface", as: Bool.self) == true {
                AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse)
                restore.append(app)
            }
        }
        body()
        for app in restore { AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
    }
}
