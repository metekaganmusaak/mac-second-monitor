import MSMProtocol
import UIKit

/// USB HID usages (Keyboard/Keypad page) the app sends on its own.
enum HIDUsage {
    static let returnKey: UInt16 = 0x28
    static let escape: UInt16 = 0x29
    static let backspace: UInt16 = 0x2A
    static let tab: UInt16 = 0x2B
    static let rightArrow: UInt16 = 0x4F
    static let leftArrow: UInt16 = 0x50
    static let downArrow: UInt16 = 0x51
    static let upArrow: UInt16 = 0x52
}

/// Turns hardware key presses into KEY events. `UIKey.keyCode` already is a HID usage, so the
/// Mac's active input source decides which character a key produces.
@MainActor
final class HardwareKeyboard {
    private var held: Set<UInt16> = []

    /// Sends a KEY event for each press that carries a key; returns the others for `super`.
    func handle(_ presses: Set<UIPress>, action: KeyAction, send: (InputEvent) -> Void) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let usage = UInt16(exactly: key.keyCode.rawValue), usage != 0 else {
                unhandled.insert(press)
                continue
            }
            if action == .down {
                held.insert(usage)
            } else {
                held.remove(usage)
            }
            send(.key(action: action, usage: usage, modifiers: modifiers(for: key, usage: usage, action: action)))
        }
        return unhandled
    }

    /// Releases keys still down, e.g. when the app loses focus mid-shortcut.
    func releaseAll(send: (InputEvent) -> Void) {
        for usage in held {
            send(.key(action: .up, usage: usage, modifiers: []))
        }
        held.removeAll()
    }

    static func modifiers(_ flags: UIKeyModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.alphaShift) { modifiers.insert(.capsLock) }
        return modifiers
    }

    /// The protocol wants the state *after* the event; for a modifier key itself UIKit may
    /// still report the old state, so derive that bit from the keys being held.
    private func modifiers(for key: UIKey, usage: UInt16, action: KeyAction) -> KeyModifiers {
        var modifiers = Self.modifiers(key.modifierFlags)
        guard let bit = Self.modifierBit(usage) else { return modifiers }
        if action == .down {
            modifiers.insert(bit)
        } else if !held.contains(where: { Self.modifierBit($0) == bit }) {
            modifiers.remove(bit)
        }
        return modifiers
    }

    private static func modifierBit(_ usage: UInt16) -> KeyModifiers? {
        switch usage {
        case 0xE0, 0xE4: .control
        case 0xE1, 0xE5: .shift
        case 0xE2, 0xE6: .option
        case 0xE3, 0xE7: .command
        default: nil
        }
    }
}
