import AppKit
import Carbon.HIToolbox

/// Global shortcuts for buttons ("ctrl+opt+c"), through the system's hot
/// key service: they work in any app and need no extra permission.
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var signature = ""
    private var handlerInstalled = false

    /// Registers `shortcuts` (combo → action), replacing the previous set.
    /// Unchanged sets are left alone.
    func set(_ shortcuts: [(combo: String, action: () -> Void)]) {
        let sig = shortcuts.map(\.combo).joined(separator: "|")
        if sig == signature {
            // Same keys; refresh the actions (they capture the current buttons).
            for (i, s) in shortcuts.enumerated() { actions[UInt32(i + 1)] = s.action }
            return
        }
        signature = sig
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        installHandler()
        for (i, s) in shortcuts.enumerated() {
            guard let (code, mods) = Self.carbon(s.combo) else { continue }
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x43424152), id: id) // "CBAR"
            if RegisterEventHotKey(code, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[id] = s.action
            } else {
                DebugLog.note("hotkey \(s.combo) is taken by another app")
            }
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, me, nil)
    }

    /// "ctrl+opt+c" → key code and Carbon modifiers.
    static func carbon(_ combo: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "shift": mods |= UInt32(shiftKey)
            default: key = KeySender.keyCode(for: part)
            }
        }
        guard let key, mods != 0 else { return nil } // a bare key would steal normal typing
        return (UInt32(key), mods)
    }

    /// The combo for a key press in the shortcut recorder.
    static func combo(from event: NSEvent) -> String? {
        guard let name = KeySender.keyName(for: event.keyCode) else { return nil }
        let f = event.modifierFlags
        var parts: [String] = []
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("opt") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        guard !parts.isEmpty else { return nil }
        return (parts + [name]).joined(separator: "+")
    }

    /// "ctrl+opt+c" → "⌃⌥C".
    static func display(_ combo: String) -> String {
        combo.split(separator: "+").map { part -> String in
            switch part.lowercased() {
            case "ctrl", "control": return "⌃"
            case "opt", "option", "alt": return "⌥"
            case "shift": return "⇧"
            case "cmd", "command": return "⌘"
            default: return part.count == 1 ? part.uppercased() : part.capitalized
            }
        }.joined()
    }
}
