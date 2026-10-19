import Foundation

/// The models and effort levels the widget and the Touch Bar offer. Picking
/// one types `/model <alias>` or `/effort <level>` into Claude's chat, the
/// way a button does; Claude Code switches at once and notes it in the
/// transcript ("Set model to …"), which is how the new one shows up here.
enum ModelChoice {
    static let models: [(alias: String, label: String)] = [
        ("opus[1m]", "Opus 1M"), ("opus", "Opus"),
        ("sonnet[1m]", "Sonnet 1M"), ("sonnet", "Sonnet"),
        ("haiku", "Haiku"), ("fable", "Fable"),
    ]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// The alias a model id answers to: "claude-opus-5-5[1m]" → "opus[1m]".
    static func alias(of modelId: String?) -> String? {
        guard let id = modelId?.lowercased(),
              let family = ["opus", "sonnet", "haiku", "fable"].first(where: { id.contains($0) }) else { return nil }
        return family + (id.contains("[1m]") ? "[1m]" : "")
    }

    /// The model (and effort) on one short line: "Opus 5.5 1M · xhigh".
    static func label(model: String?, effort: String?) -> String? {
        guard let model else { return nil }
        return model + (effort.map { " · \($0)" } ?? "")
    }

    /// From a transcript's command output: the model "/model" set
    /// ("Set model to `claude-opus-5-5[1m]`").
    static func modelSet(in text: String) -> String? {
        let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        guard let r = clean.range(of: "Set model to `?([A-Za-z0-9._\\[\\]-]+)", options: .regularExpression) else { return nil }
        let id = clean[r].replacingOccurrences(of: "Set model to ", with: "").replacingOccurrences(of: "`", with: "")
        return id.isEmpty ? nil : id
    }

    /// From a transcript's command output: the level "/effort" set ("Set
    /// effort level to high: …"). Ultracode runs at xhigh.
    static func effortSet(in text: String) -> String? {
        let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).lowercased()
        guard let r = clean.range(of: "set effort level to [a-z ]+", options: .regularExpression) else { return nil }
        let level = clean[r].replacingOccurrences(of: "set effort level to ", with: "").trimmingCharacters(in: .whitespaces)
        if level.hasPrefix("ultracode") { return "xhigh" }
        if level.hasPrefix("extra high") { return "xhigh" }
        return efforts.first { level == $0 || level.hasPrefix($0 + " ") }
    }
}
