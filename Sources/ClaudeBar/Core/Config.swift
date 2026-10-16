import Foundation
import CoreGraphics

/// One button on the bar. The type says what a tap does:
///   phrase  — types the text into Claude and presses Return
///   command — the same, for slash commands ("/compact")
///   key     — presses a key or shortcut ("esc", "cmd+k", "shift+tab")
///   link    — opens a URL ("vscode://…", "https://…")
///   screenshot — pick an area of the screen; its file path goes to Claude
struct ButtonSpec: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case phrase, command, key, link, screenshot }
    var label: String
    var type: Kind
    var value: String
    /// A global shortcut for it, like "ctrl+opt+c".
    var hotkey: String? = nil
}

extension ButtonSpec {
    /// A sensible type for a value as it's being typed; the settings
    /// window lets you pick another.
    static func guessType(_ value: String) -> Kind {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.contains("://") { return .link }
        if v.hasPrefix("/") { return .command }
        let keyNames: Set<String> = ["esc", "escape", "return", "enter", "tab", "space", "delete", "up", "down", "left", "right"]
        let parts = v.lowercased().split(separator: "+").map(String.init)
        let mods: Set<String> = ["cmd", "command", "ctrl", "control", "opt", "option", "alt", "shift"]
        if keyNames.contains(v.lowercased()) || (parts.count > 1 && parts.dropLast().allSatisfy(mods.contains)) {
            return .key
        }
        return .phrase
    }

    static func list(_ raw: [[String: Any]]) -> [ButtonSpec] {
        raw.compactMap { b in
            guard let label = b["label"] as? String, let value = b["value"] as? String else { return nil }
            let kind = (b["type"] as? String).flatMap(Kind.init) ?? guessType(value)
            let hotkey = (b["hotkey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ButtonSpec(label: label, type: kind, value: value, hotkey: hotkey)
        }
    }

    var dictionary: [String: String] {
        var d = ["label": label, "type": type.rawValue, "value": value]
        if let hotkey { d["hotkey"] = hotkey }
        return d
    }
}

/// User-editable settings, loaded from ~/.claudebar/config.json.
/// Everything has a default, so the file and every key in it are optional.
struct Config: Equatable {
    /// Apps that count as "where Claude Code runs". The Touch Bar only
    /// takes over while one of these is frontmost.
    var terminalBundleIDs: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.anthropic.claudefordesktop",
        "com.anthropic.claude-code",
    ]

    /// Buttons after the meters. Unset: caveman, compact, office (built
    /// from the three older keys below, so existing configs keep working).
    var buttons: [ButtonSpec] = []

    var summaryPrompt =
        "Перескажи свой последний ответ коротко, по пунктам. Только суть, без воды, вступлений и лишней информации."
    var compactCommand = "/compact"
    var officeURL = "vscode://nikola.agent-office/open"

    /// "auto" (show it when the Mac has one), "on" or "off".
    var touchBar = "auto"

    /// Take the whole Touch Bar, hiding the Control Strip while it's up.
    var hideControlStrip = true

    /// Context fill at which the bar turns red and offers to compact.
    var contextWarnPercent: Double = 80

    /// How long a question from Claude waits on the bar (seconds, renewed
    /// while you interact) before it goes to Claude's own UI.
    var questionHoldSeconds: Double = 15

    /// How long a permission request stays on the bar in VS Code and the
    /// desktop app, where Claude's own dialog is up at the same time and
    /// whichever answer comes first wins. Elsewhere the question hold
    /// applies, since Claude may be waiting on us.
    var permissionHoldSeconds: Double = 600

    /// Context window size, when neither the status line nor the model
    /// name tells (1M for "[1m]" models, 200k otherwise).
    var contextWindowSize: Int?

    /// Older key: slash commands as extra buttons.
    var skills: [String] = []

    /// Button sets per project (the active session's folder name).
    var profiles: [String: [ButtonSpec]] = [:]

    // Floating widget
    var widget = true
    /// The pill stays on screen; off: a thin line until you hover.
    var pillAlwaysVisible = true
    /// What the pill shows besides the session limit: "context", "reset", "cost".
    var pillShows: [String] = ["context", "reset"]
    /// Where the pill was dragged: its top center in screen points.
    /// Unset: top center of the screen, right under the menu bar.
    var widgetPosition: CGPoint?
    /// On Macs with a notch: hang the widget from the notch.
    var widgetAtNotch = false
    var sessionsList = false
    var doNotDisturb = false
    var contextWarning = true
    /// Type /compact by itself at the warning (when Claude is idle and its
    /// window is in front) instead of asking.
    var autoCompact = false
    /// Requests queued in the widget go out one by one after each reply.
    var taskQueue = false
    /// Template phrases in the widget and the menu.
    var templatesEnabled = false
    var templates = [
        "Продолжай",
        "Проверь последние изменения в {project} на ошибки",
        "Закоммить изменения в ветке {branch}",
    ]
    /// The widget's screenshot button.
    var screenshot = false
    /// Small metrics in the widget: "model", "lines", "git", "agents", "cost".
    var metrics: [String] = []

    // Voice: hold the right Option key alone, or the widget's mic.
    var voiceLanguage = Config.defaultVoiceLanguage
    /// Recognition on Apple's servers, for languages this Mac can't do
    /// offline. Off unless you turn it on.
    var voiceAllowServer = false

    static var defaultVoiceLanguage: String {
        Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru-RU" : "en-US"
    }

    /// ~/.claudebar (CLAUDEBAR_DIR overrides it, for the tests).
    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDEBAR_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudebar", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static var socketPath: String {
        directory.appendingPathComponent("claudebar.sock").path
    }

    /// The buttons for a project: its profile, else the main list.
    func buttons(for project: String?) -> [ButtonSpec] {
        if let project, let list = profiles[project] { return list }
        return effectiveButtons
    }

    /// The buttons to show: the configured list, or the defaults.
    var effectiveButtons: [ButtonSpec] {
        if !buttons.isEmpty { return buttons }
        var list = [
            ButtonSpec(label: "caveman", type: .phrase, value: summaryPrompt),
            ButtonSpec(label: "compact", type: .command, value: compactCommand),
        ]
        if !officeURL.isEmpty {
            list.append(ButtonSpec(label: "office", type: .link, value: officeURL))
        }
        list += skills.map { ButtonSpec(label: $0, type: .command, value: $0) }
        return list
    }

    static func load() -> Config {
        var config = Config()
        guard let data = try? Data(contentsOf: fileURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return config
        }
        if let v = obj["terminalBundleIDs"] as? [String] { config.terminalBundleIDs = v }
        if let v = obj["buttons"] as? [[String: Any]] { config.buttons = ButtonSpec.list(v) }
        if let v = obj["profiles"] as? [String: [[String: Any]]] {
            config.profiles = v.mapValues(ButtonSpec.list)
        }
        if let v = obj["widget"] as? Bool { config.widget = v }
        if let v = obj["pillAlwaysVisible"] as? Bool { config.pillAlwaysVisible = v }
        if let v = obj["pillShows"] as? [String] { config.pillShows = v }
        if let v = obj["widgetPosition"] as? [NSNumber], v.count == 2 {
            config.widgetPosition = CGPoint(x: v[0].doubleValue, y: v[1].doubleValue)
        }
        if let v = obj["widgetAtNotch"] as? Bool { config.widgetAtNotch = v }
        if let v = obj["sessionsList"] as? Bool { config.sessionsList = v }
        if let v = obj["doNotDisturb"] as? Bool { config.doNotDisturb = v }
        if let v = obj["contextWarning"] as? Bool { config.contextWarning = v }
        if let v = obj["autoCompact"] as? Bool { config.autoCompact = v }
        if let v = obj["taskQueue"] as? Bool { config.taskQueue = v }
        if let v = obj["templatesEnabled"] as? Bool { config.templatesEnabled = v }
        if let v = obj["templates"] as? [String] { config.templates = v }
        if let v = obj["screenshot"] as? Bool { config.screenshot = v }
        if let v = obj["metrics"] as? [String] { config.metrics = v }
        if let v = obj["voiceLanguage"] as? String { config.voiceLanguage = v }
        if let v = obj["voiceAllowServer"] as? Bool { config.voiceAllowServer = v }
        if let v = obj["summaryPrompt"] as? String { config.summaryPrompt = v }
        if let v = obj["compactCommand"] as? String { config.compactCommand = v }
        if let v = obj["officeURL"] as? String { config.officeURL = v }
        if let v = obj["touchBar"] as? String { config.touchBar = v }
        if let v = obj["touchBar"] as? Bool { config.touchBar = v ? "on" : "off" }
        if let v = obj["hideControlStrip"] as? Bool { config.hideControlStrip = v }
        if let v = (obj["contextWarnPercent"] as? NSNumber)?.doubleValue { config.contextWarnPercent = v }
        if let v = (obj["questionHoldSeconds"] as? NSNumber)?.doubleValue { config.questionHoldSeconds = max(0, v) }
        if let v = (obj["permissionHoldSeconds"] as? NSNumber)?.doubleValue { config.permissionHoldSeconds = max(0, v) }
        if let v = (obj["contextWindowSize"] as? NSNumber)?.intValue { config.contextWindowSize = v }
        if let v = obj["skills"] as? [String] { config.skills = v }
        return config
    }

    /// Sets one key in config.json, keeping everything else in the file.
    /// NSNull removes the key.
    static func save(_ key: String, _ value: Any) {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj = existing
        }
        obj[key] = value is NSNull ? nil : value
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
