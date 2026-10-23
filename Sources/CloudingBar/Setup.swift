import Foundation

/// Connects Clouding Bar to Claude Code — what install.sh does for a build
/// from source, done by the app itself for a download:
///   - the hook programs and scripts it carries go to ~/.cloudingbar
///     (replaced by rename, so running sessions never see half a file);
///   - its hook, for every event it listens to, and its status line go into
///     ~/.claude/settings.json: merged into what's there, the file backed up
///     first, an existing status line kept and called through ours;
///   - on request, VS Code runs Claude through the wrapper, so the 5-hour
///     limit reaches the bar from the VS Code panel too.
enum Setup {
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification",
                         "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
                         "SubagentStart", "SubagentStop"]
    /// Seconds Claude Code gives the hook before cancelling it; the hook
    /// gives up on its own well before (docs/protocol.md).
    static let timeouts = ["PermissionRequest": 960, "PreToolUse": 330]

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var dir: URL { Config.directory }
    /// CLOUDINGBAR_CLAUDE_SETTINGS and CLOUDINGBAR_VSCODE_SETTINGS stand in for the real files in tests.
    static var settingsURL: URL {
        ProcessInfo.processInfo.environment["CLOUDINGBAR_CLAUDE_SETTINGS"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude/settings.json")
    }
    static var hook: String { dir.appendingPathComponent("cloudingbar-hook").path }
    static var statusLine: String { dir.appendingPathComponent("cloudingbar-statusline.sh").path }
    static var wrapper: String { dir.appendingPathComponent("cloudingbar-wrapper.sh").path }
    static var vscodeSettings: URL {
        ProcessInfo.processInfo.environment["CLOUDINGBAR_VSCODE_SETTINGS"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Application Support/Code/User/settings.json")
    }

    /// What the app carries: the programs next to it, the scripts in its
    /// resources. Empty for a bare build (install.sh did it then).
    private static var bundled: [(name: String, url: URL)] {
        var list: [(String, URL)] = []
        for name in ["cloudingbar-hook", "cloudingbar-tap"] {
            if let url = Bundle.main.url(forAuxiliaryExecutable: name) { list.append((name, url)) }
        }
        for name in ["cloudingbar-statusline.sh", "cloudingbar-wrapper.sh"] {
            if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "hooks") { list.append((name, url)) }
        }
        return list
    }

    // MARK: Programs

    /// Puts the hook programs and scripts in ~/.cloudingbar when they're
    /// missing or differ from the app's own (a newer app). Every launch.
    @discardableResult
    static func updateHelpers() -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var changed = 0
        for (name, source) in bundled {
            let dest = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: source),
                  (try? Data(contentsOf: dest)) != data else { continue }
            let temp = dir.appendingPathComponent(name + ".new")
            do {
                try data.write(to: temp)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
                _ = try fm.replaceItemAt(dest, withItemAt: temp)
                changed += 1
            } catch {
                try? fm.removeItem(at: temp)
                DebugLog.note("setup: couldn't put \(name) in place — \(error.localizedDescription)")
            }
        }
        if changed > 0 { DebugLog.note("setup: \(changed) helper(s) updated in \(dir.path)") }
        return changed
    }

    // MARK: Claude Code settings

    /// Claude Code reaches Clouding Bar — through the plugin, or our hook
    /// in settings.json for every event — and its status line is ours.
    static var isConnected: Bool {
        guard hooksInSettings || pluginActive else { return false }
        return ((readSettings()?["statusLine"] as? [String: Any])?["command"] as? String) == statusLine
    }

    /// Our hook is in settings.json for every event Clouding Bar listens to.
    static var hooksInSettings: Bool {
        guard let hooks = (readSettings()?["hooks"]) as? [String: Any] else { return false }
        return events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == hook }
            }
        }
    }

    // MARK: The plugin

    /// Clouding Bar's plugin is on in Claude Code: installed from its
    /// marketplace (/plugin install clouding-bar@clouding-bar), or with your
    /// account from Claude Desktop (synced). Its hooks are the link then.
    static var pluginActive: Bool {
        if let enabled = readSettings()?["enabledPlugins"] as? [String: Any],
           enabled.contains(where: { $0.key.hasPrefix("clouding-bar@") && ($0.value as? Bool) == true }) {
            return true
        }
        return pluginSynced
    }

    /// The plugin comes with your account (installed in Claude Desktop):
    /// in Cowork too, then.
    static var pluginSynced: Bool { syncedPlugins.contains("clouding-bar") }

    /// The Cowork-only plugin of version 1.0 is still installed in Claude
    /// Desktop: two plugins would report each Cowork reply twice.
    static var oldCoworkPlugin: Bool { syncedPlugins.contains("clouding-bar-cowork") }

    /// The plugins your account brings to Claude Code: what each
    /// ~/.claude/plugins/synced/<account>/manifest.json lists.
    private static var syncedPlugins: Set<String> {
        let root = settingsURL.deletingLastPathComponent().appendingPathComponent("plugins/synced")
        var names = Set<String>()
        for account in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: account.appendingPathComponent("manifest.json")),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for plugin in o["plugins"] as? [[String: Any]] ?? [] {
                if let name = plugin["name"] as? String { names.insert(name) }
            }
        }
        return names
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    enum SetupError: LocalizedError {
        case unreadable
        var errorDescription: String? {
            "~/.claude/settings.json isn't plain JSON, so it was left alone. Add the hooks by hand (see the README)."
        }
    }

    /// Adds our status line to ~/.claude/settings.json, and our hooks too
    /// unless the plugin brings them (a plugin can't bring a status line).
    static func connect() throws {
        updateHelpers()
        let fm = FileManager.default
        let before = try? Data(contentsOf: settingsURL)
        var settings: [String: Any] = [:]
        if before != nil {
            guard let s = readSettings() else { throw SetupError.unreadable }
            settings = s
        }

        // Ours from an older install (the relay, the pre-rename folder) count too.
        let oldDir = home.appendingPathComponent(".claudebar").path
        let ours: Set<String> = [hook, dir.appendingPathComponent("cloudingbar-relay.sh").path,
                                 oldDir + "/claudebar-relay.sh", oldDir + "/claudebar-hook"]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        // Hooks already in settings.json stay (the plugin then steps aside).
        let withPlugin = pluginActive && !hooksInSettings
        for event in events where !withPlugin {
            var entries = hooks[event] as? [[String: Any]] ?? []
            var found = false
            for i in entries.indices {
                guard var list = entries[i]["hooks"] as? [[String: Any]] else { continue }
                for j in list.indices where ours.contains(list[j]["command"] as? String ?? "") {
                    list[j]["command"] = hook
                    if let t = timeouts[event] { list[j]["timeout"] = t }
                    found = true
                }
                entries[i]["hooks"] = list
            }
            if !found {
                var h: [String: Any] = ["type": "command", "command": hook]
                if let t = timeouts[event] { h["timeout"] = t }
                entries.append(["hooks": [h]])
            }
            hooks[event] = entries
        }
        if !hooks.isEmpty { settings["hooks"] = hooks }

        // The status line: a custom one stays, called through ours.
        var line = settings["statusLine"] as? [String: Any] ?? [:]
        if let current = line["command"] as? String, current != statusLine,
           !current.hasSuffix("/claudebar-statusline.sh") {
            try? current.write(to: dir.appendingPathComponent("statusline-original"), atomically: true, encoding: .utf8)
        }
        line["type"] = "command"
        line["command"] = statusLine
        line["refreshInterval"] = 5 // the bar keeps up without waiting for a message
        settings["statusLine"] = line

        let after = try JSONSerialization.data(withJSONObject: settings,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard after != before else { return }
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let before {
            let backups = dir.appendingPathComponent("backups", isDirectory: true)
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            try before.write(to: backups.appendingPathComponent("settings-\(stamp.string(from: Date())).json"))
        }
        try (after + Data("\n".utf8)).write(to: settingsURL, options: .atomic)
        DebugLog.note(withPlugin ? "setup: status line registered (the plugin brings the hooks)"
                                 : "setup: Claude Code hooks and status line registered")
    }

    // MARK: Codex

    /// Codex (OpenAI's coding agent) takes nearly the same hooks, in
    /// ~/.codex/hooks.json: the same command, marked --codex. It runs them
    /// only once you've trusted them in Codex (/hooks). CLOUDINGBAR_CODEX_HOME
    /// stands in for ~/.codex in tests.
    static var codexHome: URL {
        ProcessInfo.processInfo.environment["CLOUDINGBAR_CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
    }
    static var codexHooksURL: URL { codexHome.appendingPathComponent("hooks.json") }
    static var codexCommand: String { hook + " --codex" }
    /// Codex has no Notification or PostToolUseFailure.
    static let codexEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "PreToolUse",
                              "PostToolUse", "PermissionRequest", "SubagentStart", "SubagentStop"]

    static var hasCodex: Bool { FileManager.default.fileExists(atPath: codexHome.path) }

    static var codexConnected: Bool {
        guard let data = try? Data(contentsOf: codexHooksURL),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = o["hooks"] as? [String: Any] else { return false }
        return codexEvents.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == codexCommand }
            }
        }
    }

    /// Adds our hook, for every event Codex has, to ~/.codex/hooks.json
    /// (merged, backed up first).
    static func connectCodex() throws {
        updateHelpers()
        let fm = FileManager.default
        let before = try? Data(contentsOf: codexHooksURL)
        var file: [String: Any] = [:]
        if let before, !before.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let o = (try? JSONSerialization.jsonObject(with: before)) as? [String: Any] else {
                throw SetupError.unreadable
            }
            file = o
        }
        var hooks = file["hooks"] as? [String: Any] ?? [:]
        for event in codexEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let ours = entries.contains { (($0["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == codexCommand } }
            if !ours {
                var h: [String: Any] = ["type": "command", "command": codexCommand]
                if let t = timeouts[event] { h["timeout"] = t }
                entries.append(["hooks": [h]])
            }
            hooks[event] = entries
        }
        file["hooks"] = hooks
        let after = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard after != before else { return }
        try fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
        if let before {
            let backups = dir.appendingPathComponent("backups", isDirectory: true)
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            try before.write(to: backups.appendingPathComponent("codex-hooks-\(stamp.string(from: Date())).json"))
        }
        try (after + Data("\n".utf8)).write(to: codexHooksURL, options: .atomic)
        DebugLog.note("setup: Codex hooks registered")
    }

    // MARK: VS Code

    /// VS Code runs Claude through our wrapper (claudeCode.claudeProcessWrapper).
    static var vscodeWrapped: Bool {
        guard let text = try? String(contentsOf: vscodeSettings, encoding: .utf8) else { return false }
        return text.contains("\"claudeCode.claudeProcessWrapper\"") && text.contains(wrapper)
    }

    static var hasVSCode: Bool { FileManager.default.fileExists(atPath: vscodeSettings.deletingLastPathComponent().path) }

    /// Sets claudeCode.claudeProcessWrapper in VS Code's settings by editing
    /// the text, so its comments and layout stay as they are. Backed up first.
    static func wrapVSCode() throws {
        let fm = FileManager.default
        let url = vscodeSettings
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "{\n}\n"
        if fm.fileExists(atPath: url.path) {
            let backups = dir.appendingPathComponent("backups", isDirectory: true)
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            try text.write(to: backups.appendingPathComponent("vscode-settings-\(stamp.string(from: Date())).json"),
                           atomically: true, encoding: .utf8)
        }
        let entry = "\"claudeCode.claudeProcessWrapper\": \"\(wrapper)\""
        if let r = text.range(of: "\"claudeCode.claudeProcessWrapper\"\\s*:\\s*\"[^\"]*\"", options: .regularExpression) {
            text.replaceSubrange(r, with: entry)
        } else if let brace = text.firstIndex(of: "{") {
            // First in the object; a comma after it unless the object was empty.
            let rest = text[text.index(after: brace)...]
            let empty = rest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
            text.insert(contentsOf: "\n    " + entry + (empty ? "" : ","), at: text.index(after: brace))
        } else {
            text = "{\n    \(entry)\n}\n"
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        DebugLog.note("setup: VS Code runs Claude through the wrapper")
    }
}
