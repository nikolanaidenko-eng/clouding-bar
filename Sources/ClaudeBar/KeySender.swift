import AppKit
import ApplicationServices

/// Sends keystrokes to whatever app is frontmost (your terminal).
/// This is how Touch Bar buttons answer Claude's prompts — macOS requires
/// the one-time Accessibility permission for it.
enum KeySender {
    static let escape: CGKeyCode = 53
    static let returnKey: CGKeyCode = 36

    /// Ask macOS for Accessibility access, showing the system prompt the
    /// first time. Returns whether we currently have it.
    @discardableResult
    static func ensureTrusted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func tap(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// Type arbitrary text using unicode key events, optionally pressing
    /// Return afterwards. Works regardless of keyboard layout.
    static func type(_ text: String, pressReturn: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        // CGEvent caps the unicode payload, so send in small chunks.
        for chunk in text.chunked(into: 16) {
            let chars = Array(chunk.utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            up?.post(tap: .cghidEventTap)
        }
        if pressReturn {
            // Claude Code treats a fast burst of keys as a paste, and a
            // Return inside a paste becomes a newline instead of "send".
            // A short pause makes the Return a separate keypress.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                KeySender.tap(KeySender.returnKey)
            }
        }
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
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
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

private extension String {
    func chunked(into size: Int) -> [String] {
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<end]))
            index = end
        }
        return result
    }
}
