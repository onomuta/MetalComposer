import SwiftUI
#if os(macOS)
import AppKit
#else
import GameController
import UIKit
#endif

/// Modifier keys held right now, read during a drag or click (no event at hand). On iPad they
/// come from a hardware keyboard; without one, none are held.
enum HeldKeys {
    static var option: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        isPressed(.leftAlt) || isPressed(.rightAlt)
        #endif
    }

    static var shift: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        isPressed(.leftShift) || isPressed(.rightShift)
        #endif
    }

    static var command: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        isPressed(.leftGUI) || isPressed(.rightGUI)
        #endif
    }

    #if !os(macOS)
    private static func isPressed(_ key: GCKeyCode) -> Bool {
        GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: key)?.isPressed ?? false
    }
    #endif
}

/// The pointer shape over a resize handle or knob. iPad's pointer has no such shapes.
enum ResizeCursor {
    case leftRight, upDown

    func set(_ inside: Bool) {
        #if os(macOS)
        if inside {
            (self == .leftRight ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
            NSCursor.pop()
        }
        #endif
    }
}

extension Color {
    /// Thin lines between panes.
    static var separatorLine: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }

    /// The face of a control such as a knob.
    static var controlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
