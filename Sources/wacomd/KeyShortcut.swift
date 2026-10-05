import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// A keyboard chord ready to be posted as CGEvents.
struct KeyChord {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

/// What a shortcut string from the config resolves to.
enum ParsedShortcut {
    /// A key with modifiers : `cmd+shift+z`, `space`, `num7`.
    case key(KeyChord)
    /// Modifiers only, held as long as the button : `shift`, `cmd+alt`.
    case modifiers(CGEventFlags)
    /// A mouse click with held modifiers : `shift+middleClick`.
    case click(CGMouseButton, CGEventFlags)
}

/// Parses shortcut strings from the config (`"cmd+shift+z"`, `"cmd+="`,
/// `"space"`, `"shift"`, `"shift+middleClick"`…).
///
/// Characters are resolved against the *current* keyboard layout : a virtual
/// key code designates a physical key, so hard-coding `kVK_ANSI_Z` would send
/// ⌘W on an AZERTY keyboard. Must be called on the main thread (TIS API).
enum KeyShortcut {

    static let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand, CGKeyCode(kVK_Command)), (.maskShift, CGKeyCode(kVK_Shift)),
        (.maskAlternate, CGKeyCode(kVK_Option)), (.maskControl, CGKeyCode(kVK_Control)),
    ]

    static func parse(_ spec: String) -> ParsedShortcut? {
        var tokens = spec.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        if spec.hasSuffix("++") { tokens.append("+") }
        guard let keyToken = tokens.popLast(), !keyToken.isEmpty else { return nil }

        var flags: CGEventFlags = []
        for mod in tokens {
            guard let flag = modifierFlag(mod) else { return nil }
            flags.insert(flag)
        }

        if let flag = modifierFlag(keyToken) {
            return .modifiers(flags.union(flag))
        }
        switch keyToken {
        case "leftclick":   return .click(.left, flags)
        case "rightclick":  return .click(.right, flags)
        case "middleclick": return .click(.center, flags)
        default: break
        }
        if let code = namedKeys[keyToken] {
            return .key(KeyChord(keyCode: code, flags: flags))
        }
        guard keyToken.count == 1, let (code, extraFlags) = keyCode(forCharacter: keyToken) else {
            return nil
        }
        return .key(KeyChord(keyCode: code, flags: flags.union(extraFlags)))
    }

    private static func modifierFlag(_ token: String) -> CGEventFlags? {
        switch token {
        case "cmd", "command", "⌘":        return .maskCommand
        case "shift", "⇧":                 return .maskShift
        case "alt", "opt", "option", "⌥":  return .maskAlternate
        case "ctrl", "control", "⌃":       return .maskControl
        default:                           return nil
        }
    }

    private static let namedKeys: [String: CGKeyCode] = [
        "space": CGKeyCode(kVK_Space), "tab": CGKeyCode(kVK_Tab),
        "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
        "esc": CGKeyCode(kVK_Escape), "escape": CGKeyCode(kVK_Escape),
        "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
        // Numeric keypad (Blender views), layout-independent.
        "num0": CGKeyCode(kVK_ANSI_Keypad0), "num1": CGKeyCode(kVK_ANSI_Keypad1),
        "num2": CGKeyCode(kVK_ANSI_Keypad2), "num3": CGKeyCode(kVK_ANSI_Keypad3),
        "num4": CGKeyCode(kVK_ANSI_Keypad4), "num5": CGKeyCode(kVK_ANSI_Keypad5),
        "num6": CGKeyCode(kVK_ANSI_Keypad6), "num7": CGKeyCode(kVK_ANSI_Keypad7),
        "num8": CGKeyCode(kVK_ANSI_Keypad8), "num9": CGKeyCode(kVK_ANSI_Keypad9),
        "num.": CGKeyCode(kVK_ANSI_KeypadDecimal), "num+": CGKeyCode(kVK_ANSI_KeypadPlus),
        "num-": CGKeyCode(kVK_ANSI_KeypadMinus), "num*": CGKeyCode(kVK_ANSI_KeypadMultiply),
        "num/": CGKeyCode(kVK_ANSI_KeypadDivide), "numenter": CGKeyCode(kVK_ANSI_KeypadEnter),
    ]

    /// Finds the physical key producing `character` in the current layout and
    /// the modifiers needed to type it : none, then ⇧, ⌥, ⌥⇧ (on AZERTY
    /// `[` and `]` live behind ⌥⇧).
    private static func keyCode(forCharacter character: String) -> (CGKeyCode, CGEventFlags)? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> (CGKeyCode, CGEventFlags)? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            let shift = UInt32((shiftKey >> 8) & 0xff)
            let option = UInt32((optionKey >> 8) & 0xff)
            let candidates: [(UInt32, CGEventFlags)] = [
                (0, []), (shift, .maskShift), (option, .maskAlternate), (shift | option, [.maskShift, .maskAlternate])
            ]

            for (modifierState, extraFlags) in candidates {
                for code in 0..<UInt16(128) {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown),
                                                modifierState, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                                &deadKeyState, chars.count, &length, &chars)
                    if status == noErr, length > 0,
                       String(utf16CodeUnits: chars, count: length) == character {
                        return (CGKeyCode(code), extraFlags)
                    }
                }
            }
            return nil
        }
    }
}
