import AppKit
import ApplicationServices

/// Keys for the app in front: how buttons, templates and shortcuts reach a
/// chat (and a message, where its chat has no way in of its own). Claude's
/// requests are answered through its hooks instead. macOS asks once for
/// Accessibility before any key goes anywhere.
enum KeySender {
    static let returnKey: CGKeyCode = 36
    static let escape: CGKeyCode = 53

    /// May Clouding Bar send keys? The first time, macOS puts up its prompt.
    @discardableResult
    static func ensureTrusted() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        return AXIsProcessTrustedWithOptions([prompt: true] as NSDictionary as CFDictionary)
    }

    /// One key down and up, with exactly these modifiers — none by default:
    /// a plain Return or Esc even while a shortcut's own keys are still held.
    static func tap(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// Runs `action` once the modifier keys are up (at most ~1 s), so a
    /// shortcut's ⌘/⌃/⌥ can't turn typed text into commands.
    static func afterModifiersUp(_ action: @escaping () -> Void, waited: Int = 0) {
        let held = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift])
        if held.isEmpty || waited >= 20 {
            action()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { afterModifiersUp(action, waited: waited + 1) }
        }
    }

    /// Text as text, whatever the keyboard layout: carried in key events'
    /// unicode strings, 16 UTF-16 units at a time (an event takes no more),
    /// never splitting a character made of two (an emoji). Then Return, if
    /// asked — a moment later: Claude Code takes a fast burst of keys for a
    /// paste, and a Return inside one makes a new line instead of sending.
    static func type(_ text: String, pressReturn: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var from = 0
        while from < units.count {
            var to = min(from + 16, units.count)
            if to < units.count, UTF16.isLeadSurrogate(units[to - 1]) { to -= 1 }
            let piece = Array(units[from..<to])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
            from = to
        }
        guard pressReturn else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tap(returnKey) }
    }
}

extension KeySender {
    /// Presses a key or shortcut written like "esc", "return", "cmd+k",
    /// "shift+tab" or "ctrl+c" (US key positions). False if it can't be read.
    @discardableResult
    static func press(_ combo: String) -> Bool {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "shift", "⇧": flags.insert(.maskShift)
            default: key = keyCodes[part]
            }
        }
        guard let key else { return false }
        tap(key, flags: flags)
        return true
    }

    static func keyCode(for name: String) -> CGKeyCode? { keyCodes[name.lowercased()] }

    /// The short name for a key code ("k", "esc", "up"), for recorded shortcuts.
    static func keyName(for code: UInt16) -> String? {
        let preferred = ["esc", "return", "tab", "space", "delete", "left", "right", "down", "up", "home", "end", "pageup", "pagedown"]
        for name in preferred where keyCodes[name] == CGKeyCode(code) { return name }
        return keyCodes.first { $0.value == CGKeyCode(code) && $0.key.count == 1 }?.key
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "esc": 53, "escape": 53, "return": 36, "enter": 36, "tab": 48, "space": 49,
            "delete": 51, "backspace": 51, "forwarddelete": 117,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        ]
        let ansi: [(String, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8),
            ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17),
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25),
            ("7", 26), ("-", 27), ("8", 28), ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42),
            (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47), ("`", 50),
        ]
        for (k, v) in ansi { map[k] = v }
        return map
    }()
}
