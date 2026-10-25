import Foundation
import CoreGraphics

/// One button on the bar. The type says what a tap does:
///   phrase  — types the text into Claude and presses Return
///   text    — types the text without Return, to finish it (once templates)
///   command — the same as phrase, for slash commands ("/compact")
///   key     — presses a key or shortcut ("esc", "cmd+k", "shift+tab")
///   link    — opens a URL ("vscode://…", "https://…")
///   screenshot — pick an area of the screen; its file path goes to Claude
/// In a phrase or a text, {project}, {branch}, {clipboard} and {date} are
/// filled in.
struct ButtonSpec: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case phrase, text, command, key, link, screenshot }
    var label: String
    var type: Kind
    var value: String
    /// A global shortcut for it, like "ctrl+opt+c".
    var hotkey: String? = nil
    /// Tucked into the menu button's list instead of the row (owner, 25.10).
    var menu = false
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
            return ButtonSpec(label: label, type: kind, value: value, hotkey: hotkey, menu: b["menu"] as? Bool ?? false)
        }
    }

    var dictionary: [String: Any] {
        var d: [String: Any] = ["label": label, "type": type.rawValue, "value": value]
        if let hotkey { d["hotkey"] = hotkey }
        if menu { d["menu"] = true }
        return d
    }

    /// A name for a long text: its first words, up to 24 characters.
    static func label(for text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 24 else { return t }
        var words: [Substring] = []
        for word in t.split(separator: " ") {
            guard words.map(\.count).reduce(words.count, +) + word.count <= 23 else { break }
            words.append(word)
        }
        // Not ending on "в", "to" or "a".
        if words.count > 1, let last = words.last, last.count <= 2 { words.removeLast() }
        return (words.isEmpty ? String(t.prefix(23)) : words.joined(separator: " ")) + "…"
    }
}

/// User-editable settings, loaded from ~/.cloudingbar/config.json.
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

    /// Buttons after the meters. Unset: summary and compact (built
    /// from the three older keys below, so existing configs keep working).
    var buttons: [ButtonSpec] = []

    var summaryPrompt = "Sum up your last answer in a few short bullet points: just the essentials."
    var compactCommand = "/compact"
    /// A link button after the defaults (unset: none).
    var officeURL = ""

    /// "auto" (show it when the Mac has one), "on" or "off".
    var touchBar = "auto"

    /// Take the whole Touch Bar, hiding the Control Strip while it's up.
    var hideControlStrip = true
    /// Claude's bar in every app, not only while a terminal, VS Code or
    /// Claude is in front (there, next to the Control Strip).
    var touchBarEverywhere = false
    /// Dictated text waits in the widget to be checked and sent; off: it's
    /// typed into the app in front at once.
    var voiceReview = true
    /// Outside Claude's apps: "short" (the chat and the meters, beside
    /// Apple's brightness and volume) or "whole" (the whole Touch Bar).
    var touchBarOutside = "short"

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
    /// How much the pill shows: "full" (bars and numbers), "numbers", "icon".
    /// The old setting; `pillWidth` replaces it once the pill is resized.
    var pillDensity = "full"
    /// The pill's width budget in points, set by pulling its edge: it shows
    /// whatever fits, from the character alone up to every metric and button.
    /// 0: not resized yet, so it comes from `pillDensity`.
    var pillWidth: Double = 0
    /// Rows the pill may use (the old setting; `pillHeight` replaces it).
    var pillRows = 1
    /// The pill's height in points, set by pulling its top or bottom edge;
    /// taller than wide, it stands up as a column. 0: from `pillRows`.
    var pillHeight: Double = 0
    /// The order of the pill's and the panel's items, by id ("session",
    /// "metric:model", "button:<label>", "chat", "mic", …), set by dragging
    /// one onto another. Items not listed keep their place after these.
    var itemOrder: [String] = []
    /// Hovering the pill for 2 s opens the full panel; off: only a click does.
    var hoverOpens = true
    /// The chat in front finished while another is at work: "done" for a
    /// moment, then the widget and the bar show the one at work.
    var followWorking = true
    /// Another chat than the one shown is done: Cloud pops out and says
    /// which (the widget and the Touch Bar).
    var doneAlerts = true
    /// Achievements unlocked: "claude-wave" (Claude said ☁️ — Cloud's colours).
    var achievements: [String] = []
    /// Cloud's colour (CloudColor), once the wave has unlocked them.
    var cloudColor = "classic"
    /// What the Touch Bar shows next to its character button (requests
    /// always show): "session", "reset", "context", "buttons", "mic", "shot".
    var touchBarShows: [String] = ["session", "reset", "context", "buttons"]
    /// The bar arranged by hand in Settings, per bar ("whole", "short"):
    /// the order of its blocks ("name", "meters", "chat", "model", …) and
    /// the width of each one dragged wider or narrower, in points.
    var touchBarOrder: [String: [String]] = [:]
    var touchBarWidths: [String: [String: Double]] = [:]
    /// The pill's items dragged wider or narrower by their right edge, in
    /// points, by id ("session", "chat", "mic", …).
    var itemWidths: [String: Double] = [:]
    /// The open panel's blocks top to bottom, as dragged by their grips:
    /// "meters", "details", "box" (the chats stay on top).
    var panelOrder: [String] = []
    /// What the pill (and the panel) shows besides the session limit:
    /// "context", "reset", "cost".
    var pillShows: [String] = ["context", "reset"]
    /// What the widget leaves out of what it always used to show:
    /// "session" (the 5-hour limit), "buttons", "mic".
    var widgetHides: [String] = []
    /// Where the pill was dragged: its top center in screen points.
    /// Unset: top center of the screen, right under the menu bar.
    var widgetPosition: CGPoint?
    /// The tour has opened once (it does by itself on the first launch).
    var tourShown = false
    /// The settings window: "auto" (the system's), "light" or "dark".
    var appearance = "auto"
    /// Its buttons, tabs and icons: "color", or "gray" with no bright colours.
    var buttonColors = "color"
    /// "Not Now" to connecting to Claude Code: don't ask at every launch.
    var setupDeclined = false
    /// Docked in the notch (a drawn one on Macs without it).
    var widgetAtNotch = false
    /// The island's size in the notch, set by pulling its ends or bottom:
    /// wider, it shows the pill's items around the camera. 0: compact.
    var notchWidth: Double = 0
    var notchHeight: Double = 0
    var sessionsList = false
    var doNotDisturb = false
    var contextWarning = true
    /// Type /compact by itself at the warning (when Claude is idle and its
    /// window is in front) instead of asking.
    var autoCompact = false
    /// Requests queued in the widget go out one by one after each reply.
    var taskQueue = false
    /// The template phrases a config with templates on but none of its own
    /// had; they move into the menu (`moveTemplates`).
    static let oldTemplates = [
        "Продолжай",
        "Проверь последние изменения в {project} на ошибки",
        "Закоммить изменения в ветке {branch}",
    ]
    /// The widget's screenshot button.
    var screenshot = false
    /// Small metrics in the widget: "model", "lines", "git", "agents", "cost".
    var metrics: [String] = []

    /// Cowork status through the plugin: "off", "thresholds", "every".
    var coworkMode = "off"
    /// You picked the Cowork mode yourself (else the plugin installed in
    /// Claude Desktop turns it on, at "thresholds").
    var coworkModeSet = false
    /// The Mac folder connected in Cowork, where the status file lands.
    var coworkFolder: String?

    /// Once a day, ask GitHub whether a newer release is out (a release
    /// build only; nothing about you is sent).
    var checkUpdates = true
    /// The plugin opens the app when a Claude session starts (its
    /// hooks/run.sh reads this key from the file).
    var openWithClaude = true

    // Voice: hold the right Option key alone, or the widget's mic.
    var voiceLanguage = Config.defaultVoiceLanguage
    /// Recognition on Apple's servers, for languages this Mac can't do
    /// offline. Off unless you turn it on.
    var voiceAllowServer = false

    static var defaultVoiceLanguage: String {
        Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru-RU" : "en-US"
    }

    /// ~/.cloudingbar (CLOUDINGBAR_DIR overrides it, for the tests).
    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudingbar", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static var socketPath: String {
        directory.appendingPathComponent("cloudingbar.sock").path
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
            ButtonSpec(label: "summary", type: .phrase, value: summaryPrompt),
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
        if let v = obj["pillDensity"] as? String { config.pillDensity = v }
        if let v = obj["pillWidth"] as? NSNumber { config.pillWidth = v.doubleValue }
        if let v = obj["pillRows"] as? Int { config.pillRows = v }
        if let v = obj["pillHeight"] as? NSNumber { config.pillHeight = v.doubleValue }
        if let v = obj["itemOrder"] as? [String] { config.itemOrder = v }
        if let v = obj["pillShows"] as? [String] { config.pillShows = v }
        if let v = obj["widgetHides"] as? [String] { config.widgetHides = v }
        if let v = obj["hoverOpens"] as? Bool { config.hoverOpens = v }
        if let v = obj["followWorking"] as? Bool { config.followWorking = v }
        if let v = obj["doneAlerts"] as? Bool { config.doneAlerts = v }
        if let v = obj["achievements"] as? [String] { config.achievements = v }
        if let v = obj["cloudColor"] as? String { config.cloudColor = v }
        if let v = obj["touchBarShows"] as? [String] { config.touchBarShows = v }
        if let v = obj["touchBarOrder"] as? [String: [String]] { config.touchBarOrder = v }
        if let v = obj["panelOrder"] as? [String] { config.panelOrder = v }
        if let v = obj["itemWidths"] as? [String: NSNumber] { config.itemWidths = v.mapValues { min(max($0.doubleValue, 20), 600) } }
        if let v = obj["touchBarWidths"] as? [String: [String: NSNumber]] {
            config.touchBarWidths = v.mapValues { $0.mapValues { min(max($0.doubleValue, 24), 800) } }
        }
        if let v = obj["widgetPosition"] as? [NSNumber], v.count == 2 {
            config.widgetPosition = CGPoint(x: v[0].doubleValue, y: v[1].doubleValue)
        }
        if let v = obj["widgetAtNotch"] as? Bool { config.widgetAtNotch = v }
        if let v = obj["tourShown"] as? Bool { config.tourShown = v }
        if let v = obj["appearance"] as? String, ["auto", "light", "dark"].contains(v) { config.appearance = v }
        if let v = obj["buttonColors"] as? String, ["color", "gray"].contains(v) { config.buttonColors = v }
        if let v = obj["setupDeclined"] as? Bool { config.setupDeclined = v }
        if let v = obj["notchWidth"] as? NSNumber { config.notchWidth = v.doubleValue }
        if let v = obj["notchHeight"] as? NSNumber { config.notchHeight = v.doubleValue }
        if let v = obj["sessionsList"] as? Bool { config.sessionsList = v }
        if let v = obj["doNotDisturb"] as? Bool { config.doNotDisturb = v }
        if let v = obj["contextWarning"] as? Bool { config.contextWarning = v }
        if let v = obj["autoCompact"] as? Bool { config.autoCompact = v }
        if let v = obj["taskQueue"] as? Bool { config.taskQueue = v }
        if let v = obj["screenshot"] as? Bool { config.screenshot = v }
        if let v = obj["metrics"] as? [String] { config.metrics = v }
        if let v = obj["coworkMode"] as? String { config.coworkMode = v; config.coworkModeSet = true }
        if let v = obj["checkUpdates"] as? Bool { config.checkUpdates = v }
        if let v = obj["openWithClaude"] as? Bool { config.openWithClaude = v }
        if let v = obj["coworkFolder"] as? String { config.coworkFolder = v }
        if let v = obj["voiceLanguage"] as? String { config.voiceLanguage = v }
        if let v = obj["voiceAllowServer"] as? Bool { config.voiceAllowServer = v }
        if let v = obj["summaryPrompt"] as? String { config.summaryPrompt = v }
        if let v = obj["compactCommand"] as? String { config.compactCommand = v }
        if let v = obj["officeURL"] as? String { config.officeURL = v }
        if let v = obj["touchBar"] as? String { config.touchBar = v }
        if let v = obj["touchBar"] as? Bool { config.touchBar = v ? "on" : "off" }
        if let v = obj["hideControlStrip"] as? Bool { config.hideControlStrip = v }
        if let v = obj["touchBarEverywhere"] as? Bool { config.touchBarEverywhere = v }
        if let v = obj["voiceReview"] as? Bool { config.voiceReview = v }
        if let v = obj["touchBarOutside"] as? String { config.touchBarOutside = v }
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
        write(obj)
    }

    private static func write(_ obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Templates became buttons in the menu (owner, 25.10): a text put in
    /// the message to finish, not sent. Once, when the app starts: the
    /// phrases join the end of every list of buttons, the old keys go.
    /// Your own phrases with templates off move too, the menu hidden.
    static func moveTemplates() {
        guard let data = try? Data(contentsOf: fileURL),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["templates"] != nil || obj["templatesEnabled"] != nil else { return }
        let on = obj["templatesEnabled"] as? Bool == true
        let phrases = obj["templates"] as? [String] ?? (on ? oldTemplates : [])
        let items = phrases.map { ButtonSpec(label: ButtonSpec.label(for: $0), type: .text, value: $0, menu: true).dictionary }
        if !items.isEmpty {
            // No list of its own (or none that reads): the defaults, written
            // out, come first.
            let own = obj["buttons"] as? [[String: Any]] ?? []
            obj["buttons"] = (ButtonSpec.list(own).isEmpty ? load().effectiveButtons.map(\.dictionary) : own) + items
            if let profiles = obj["profiles"] as? [String: [[String: Any]]] {
                obj["profiles"] = profiles.mapValues { $0 + items }
            }
        }
        if !on && !items.isEmpty {
            obj["widgetHides"] = (obj["widgetHides"] as? [String] ?? []) + ["menu"]
            if let shows = obj["touchBarShows"] as? [String] { obj["touchBarShows"] = shows.filter { $0 != "templates" } }
        }
        obj["templates"] = nil
        obj["templatesEnabled"] = nil
        write(obj)
    }
}
