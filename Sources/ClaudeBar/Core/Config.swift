import Foundation

/// One button on the bar. The type says what a tap does:
///   phrase  — types the text into Claude and presses Return
///   command — the same, for slash commands ("/compact")
///   key     — presses a key or shortcut ("esc", "cmd+k", "shift+tab")
///   link    — opens a URL ("vscode://…", "https://…")
struct ButtonSpec: Codable, Equatable {
    enum Kind: String, Codable { case phrase, command, key, link }
    var label: String
    var type: Kind
    var value: String
}

/// User-editable settings, loaded from ~/.claudebar/config.json.
/// Everything has a default, so the file and every key in it are optional.
struct Config {
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
        if let v = obj["buttons"] as? [[String: Any]] {
            config.buttons = v.compactMap { b in
                guard let label = b["label"] as? String, let value = b["value"] as? String else { return nil }
                let kind = (b["type"] as? String).flatMap(ButtonSpec.Kind.init) ?? .phrase
                return ButtonSpec(label: label, type: kind, value: value)
            }
        }
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
    static func save(_ key: String, _ value: Any) {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj = existing
        }
        obj[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
