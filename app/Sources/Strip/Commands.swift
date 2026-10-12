import Carbon.HIToolbox

enum Command: Hashable {
    case focusLeft, focusRight, focusFirst, focusLast
    case screenLeft, screenRight
    case focusIndex(Int)
    case moveLeft, moveRight
    case focusUp, focusDown, moveUp, moveDown
    case stackLeft, stackRight, popOutLeft, popOutRight, toggleTabbed
    case taller, shorter, equalizeHeights
    case cycleWidth, fullWidth, center, wider, narrower
    case toggleFloat
    case sendToNextDisplay
    case toggleEnabled

    /// Localized name shown in Settings, the menu and the Raycast commands.
    var title: String {
        switch self {
        case .focusLeft: L("Focus window on the left")
        case .focusRight: L("Focus window on the right")
        case .screenLeft: L("Slide to previous screen")
        case .screenRight: L("Slide to next screen")
        case .focusFirst: L("First window")
        case .focusLast: L("Last window")
        case .focusIndex(let i): L("Jump to window %d", i + 1)
        case .focusUp: L("Window above in stack / previous tab")
        case .focusDown: L("Window below in stack / next tab")
        case .moveUp: L("Move window up in stack")
        case .moveDown: L("Move window down in stack")
        case .stackLeft: L("Stack into column on the left")
        case .stackRight: L("Stack into column on the right")
        case .popOutLeft: L("Pop out of stack to the left")
        case .popOutRight: L("Pop out of stack to the right")
        case .toggleTabbed: L("Show stack as tabs / rows")
        case .taller: L("Taller in stack")
        case .shorter: L("Shorter in stack")
        case .equalizeHeights: L("Equalize stack heights")
        case .moveLeft: L("Move window left")
        case .moveRight: L("Move window right")
        case .cycleWidth: L("Cycle preset widths")
        case .fullWidth: L("Full width")
        case .center: L("Center column")
        case .wider: L("Wider")
        case .narrower: L("Narrower")
        case .toggleFloat: L("Float / tile window")
        case .sendToNextDisplay: L("Send window to next display")
        case .toggleEnabled: L("Stop / start window management")
        }
    }

    /// Stable name used for saved shortcuts, the strip:// URL scheme and the command-line tool.
    var id: String {
        switch self {
        case .focusLeft: "focus-left"
        case .focusRight: "focus-right"
        case .screenLeft: "screen-left"
        case .screenRight: "screen-right"
        case .focusFirst: "focus-first"
        case .focusLast: "focus-last"
        case .focusIndex(let i): "focus-\(i + 1)"
        case .focusUp: "focus-up"
        case .focusDown: "focus-down"
        case .moveUp: "move-up"
        case .moveDown: "move-down"
        case .stackLeft: "stack-left"
        case .stackRight: "stack-right"
        case .popOutLeft: "pop-out-left"
        case .popOutRight: "pop-out-right"
        case .toggleTabbed: "toggle-tabs"
        case .taller: "taller"
        case .shorter: "shorter"
        case .equalizeHeights: "equalize-heights"
        case .moveLeft: "move-left"
        case .moveRight: "move-right"
        case .cycleWidth: "cycle-width"
        case .fullWidth: "full-width"
        case .center: "center"
        case .wider: "wider"
        case .narrower: "narrower"
        case .toggleFloat: "toggle-float"
        case .sendToNextDisplay: "send-to-next-display"
        case .toggleEnabled: "toggle"
        }
    }

    init?(id: String) {
        guard let command = Self.all.first(where: { $0.id == id }) else { return nil }
        self = command
    }

    /// Every command, in the order the Shortcuts page lists them.
    static var all: [Command] { defaults.map(\.0) }

    var defaultBindings: [KeyBinding] {
        Self.defaults.first { $0.0 == self }?.1 ?? []
    }

    /// Default bindings (several keys may map to one command). All use Control-Option.
    static let defaults: [(Command, [KeyBinding])] = {
        func k(_ code: Int, shift: Bool = false) -> KeyBinding { KeyBinding(keyCode: UInt32(code), shift: shift) }
        var list: [(Command, [KeyBinding])] = [
            (.screenLeft, [k(kVK_LeftArrow)]),
            (.screenRight, [k(kVK_RightArrow)]),
            (.focusLeft, [k(kVK_ANSI_H)]),
            (.focusRight, [k(kVK_ANSI_L)]),
            (.moveLeft, [k(kVK_ANSI_H, shift: true), k(kVK_LeftArrow, shift: true)]),
            (.moveRight, [k(kVK_ANSI_L, shift: true), k(kVK_RightArrow, shift: true)]),
            (.focusUp, [k(kVK_ANSI_K), k(kVK_UpArrow)]),
            (.focusDown, [k(kVK_ANSI_J), k(kVK_DownArrow)]),
            (.moveUp, [k(kVK_ANSI_K, shift: true), k(kVK_UpArrow, shift: true)]),
            (.moveDown, [k(kVK_ANSI_J, shift: true), k(kVK_DownArrow, shift: true)]),
            (.stackLeft, [k(kVK_ANSI_LeftBracket)]),
            (.stackRight, [k(kVK_ANSI_RightBracket)]),
            (.popOutLeft, [k(kVK_ANSI_LeftBracket, shift: true)]),
            (.popOutRight, [k(kVK_ANSI_RightBracket, shift: true)]),
            (.toggleTabbed, [k(kVK_ANSI_T, shift: true)]),
            (.taller, [k(kVK_ANSI_Equal, shift: true)]),
            (.shorter, [k(kVK_ANSI_Minus, shift: true)]),
            (.equalizeHeights, [k(kVK_ANSI_0)]),
            (.focusFirst, [k(kVK_Home)]),
            (.focusLast, [k(kVK_End)]),
            (.cycleWidth, [k(kVK_ANSI_R)]),
            (.fullWidth, [k(kVK_ANSI_F)]),
            (.center, [k(kVK_ANSI_C)]),
            (.wider, [k(kVK_ANSI_Equal)]),
            (.narrower, [k(kVK_ANSI_Minus)]),
            (.toggleFloat, [k(kVK_ANSI_T)]),
            (.sendToNextDisplay, [k(kVK_ANSI_N)]),
            (.toggleEnabled, [k(kVK_ANSI_Q)]),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, code) in digits.enumerated() { list.append((.focusIndex(i), [k(code)])) }
        return list
    }()
}
