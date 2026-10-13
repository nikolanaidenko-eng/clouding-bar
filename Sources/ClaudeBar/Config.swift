import Foundation

/// User-editable settings, loaded from ~/.claudebar/config.json.
/// Everything has a sensible default so the file is optional.
struct Config: Decodable {
    /// Slash commands (or any text) to expose as one-tap shortcut buttons.
    var skills: [String] = []

    /// Apps that count as "a terminal running Claude Code". The Touch Bar
    /// only takes over while one of these is frontmost.
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
        "com.anthropic.claudefordesktop", // the Claude desktop app
        "com.anthropic.claude-code",
    ]

    /// Show the running token counter for the active session.
    var showUsage: Bool = true

    /// Show the "skip permissions" shortcut button. It types
    /// `claude --dangerously-skip-permissions` into your terminal —
    /// handy, but you should know what that flag does before using it.
    var offerSkipPermissions: Bool = false

    /// Text the "TL;DR" button sends to Claude Code (followed by Return).
    var summaryPrompt: String =
        "Перескажи свой последний ответ коротко, по пунктам. Только суть, без воды, вступлений и лишней информации."

    /// Command the compact button sends (followed by Return).
    var compactCommand: String = "/compact"

    /// Take the whole Touch Bar, hiding the Control Strip (volume,
    /// brightness, Siri) while Claude mode is on.
    var hideControlStrip: Bool = true

    /// Link the "office" button opens (the Agent Office tab in VS Code).
    /// Empty string hides the button.
    var officeURL: String = "vscode://nikola.agent-office/open"

    /// Context window size for the Context meter when it is worked out from
    /// the transcript. Leave unset to go by the model (1M for "[1m]" models,
    /// 200k otherwise).
    var contextWindowSize: Int?

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudebar", isDirectory: true)
    }

    static var socketPath: String {
        directory.appendingPathComponent("claudebar.sock").path
    }

    static func load() -> Config {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return Config()
        }
        return config
    }

    // Let people omit keys they don't care about in config.json.
    private enum CodingKeys: String, CodingKey {
        case skills, terminalBundleIDs, showUsage, offerSkipPermissions, summaryPrompt, compactCommand, hideControlStrip, officeURL, contextWindowSize
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? defaults.skills
        terminalBundleIDs = try c.decodeIfPresent([String].self, forKey: .terminalBundleIDs) ?? defaults.terminalBundleIDs
        showUsage = try c.decodeIfPresent(Bool.self, forKey: .showUsage) ?? defaults.showUsage
        offerSkipPermissions = try c.decodeIfPresent(Bool.self, forKey: .offerSkipPermissions) ?? defaults.offerSkipPermissions
        summaryPrompt = try c.decodeIfPresent(String.self, forKey: .summaryPrompt) ?? defaults.summaryPrompt
        compactCommand = try c.decodeIfPresent(String.self, forKey: .compactCommand) ?? defaults.compactCommand
        hideControlStrip = try c.decodeIfPresent(Bool.self, forKey: .hideControlStrip) ?? defaults.hideControlStrip
        officeURL = try c.decodeIfPresent(String.self, forKey: .officeURL) ?? defaults.officeURL
        contextWindowSize = try c.decodeIfPresent(Int.self, forKey: .contextWindowSize)
    }
}
