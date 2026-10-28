import Foundation

/// Cowork runs Claude in a machine of its own, which no hook of ours
/// reaches: its tasks come from claude.ai (ClaudeAIChats) since 1.2.8. What
/// the plugin used to report from a connected folder before that is still
/// kept for Stats (cowork-usage.json).
enum Cowork {
    struct Spent: Equatable, Codable {
        var tokens: Int
        var minutes: Int
    }

    /// Cowork's context window: 1M for a "[1m]" model, else 500k (what its
    /// /context says, 20.10), 200k for Haiku.
    static func window(model: String?) -> Int {
        let m = model ?? ""
        if m.contains("[1m]") { return 1_000_000 }
        return m.contains("haiku") ? 200_000 : 500_000
    }

    /// What each Cowork chat spent, as the plugin reported it until 1.2.8.
    struct Kept: Codable {
        var project: String?
        var title: String?
        var model: String?
        /// Unix hour → spent.
        var usage: [String: Spent]
    }

    private static var keptURL: URL { Config.directory.appendingPathComponent("cowork-usage.json") }

    static func kept() -> [String: Kept] {
        (try? JSONDecoder().decode([String: Kept].self, from: Data(contentsOf: keptURL))) ?? [:]
    }
}
