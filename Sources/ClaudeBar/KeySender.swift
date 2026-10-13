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
            tap(returnKey)
        }
    }
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
