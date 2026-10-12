import AppKit
import Carbon.HIToolbox

/// Global shortcuts via Carbon's RegisterEventHotKey (needs no extra permission).
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private static let signature: OSType = 0x5354_5250 // 'STRP'

    /// Returns false when macOS refuses the combination (already taken by another app).
    @discardableResult
    func register(_ binding: KeyBinding, action: @escaping () -> Void) -> Bool {
        installHandler()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode, binding.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Log.warning("Could not register shortcut \(binding.display) (\(status))")
            return false
        }
        refs.append(ref)
        actions[id] = action
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey
            )
            let id = hotKey.id
            MainActor.assumeIsolated { Hotkeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A key plus modifiers. The key is a physical key code, so shortcuts stay on the same keys on
/// any keyboard layout; the displayed character follows the current layout.
struct KeyBinding: Hashable, Codable {
    var keyCode: UInt32
    var control = true
    var option = true
    var shift = false
    var command = false

    init(keyCode: UInt32, shift: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        control = modifiers.contains(.control)
        option = modifiers.contains(.option)
        shift = modifiers.contains(.shift)
        command = modifiers.contains(.command)
    }

    var carbonModifiers: UInt32 {
        (control ? UInt32(controlKey) : 0) | (option ? UInt32(optionKey) : 0)
            | (shift ? UInt32(shiftKey) : 0) | (command ? UInt32(cmdKey) : 0)
    }

    /// One key cap per modifier plus the key, for the on-screen shortcut caption.
    var keyCaps: [String] {
        (control ? ["⌃"] : []) + (option ? ["⌥"] : []) + (shift ? ["⇧"] : []) + (command ? ["⌘"] : [])
            + [Self.keyName(keyCode)]
    }

    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + Self.keyName(keyCode)
    }

    /// Spelled out for people who don't read the ⌃⌥⇧⌘ symbols.
    var spokenDisplay: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if command { parts.append("Command") }
        parts.append(Self.keyName(keyCode))
        return parts.joined(separator: " + ")
    }

    private static let specialKeys: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_Tab: "Tab", kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Esc", kVK_Delete: "Delete",
        kVK_ForwardDelete: "⌦", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The key's label on the current keyboard layout (AZERTY, QWERTZ, Dvorak, Turkish…).
    static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased(with: Locale.current)
    }
}
