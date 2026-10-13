import Foundation

/// User-editable settings, loaded from ~/.claudebar/config.json.
/// Everything has a sensible default so the file is optional.
struct Config: Decodable {
    /// Slash commands (or any text) to expose as one-tap shortcut buttons.
    var skills: [String] = ["/code-review", "/simplify", "/init"]

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
        "com.anthropic.claudefordesktop", // the Claude desktop app
        "com.anthropic.claude-code",
    ]

    /// Show the running token counter for the active session.
    var showUsage: Bool = true

    /// Show the "skip permissions" shortcut button. It types
    /// `claude --dangerously-skip-permissions` into your terminal —
    /// handy, but you should know what that flag does before using it.
    var offerSkipPermissions: Bool = true

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
        case skills, terminalBundleIDs, showUsage, offerSkipPermissions
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? defaults.skills
        terminalBundleIDs = try c.decodeIfPresent([String].self, forKey: .terminalBundleIDs) ?? defaults.terminalBundleIDs
        showUsage = try c.decodeIfPresent(Bool.self, forKey: .showUsage) ?? defaults.showUsage
        offerSkipPermissions = try c.decodeIfPresent(Bool.self, forKey: .offerSkipPermissions) ?? defaults.offerSkipPermissions
    }
}
