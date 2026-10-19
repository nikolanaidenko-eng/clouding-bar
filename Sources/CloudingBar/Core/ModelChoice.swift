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

    /// From a transcript's command output: the model "/model" set, as an
    /// id. Claude Code prints the id ("Set model to `claude-opus-5-5[1m]`")
    /// or, lately, the name ("Set model to `Opus 5.5 (1M context)` for this
    /// session only").
    static func modelSet(in text: String) -> String? {
        let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        guard let start = clean.range(of: "Set model to ") else { return nil }
        var rest = clean[start.upperBound...]
        let name: Substring
        if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
            name = rest[rest.index(after: rest.startIndex)..<close]
        } else {
            rest = rest.prefix { !$0.isWhitespace && $0 != "<" }
            name = rest
        }
        return id(fromName: String(name))
    }

    /// "claude-opus-5-5[1m]" stays; "Opus 5.5 (1M context)" → "claude-opus-5-5[1m]".
    static func id(fromName name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.lowercased().hasPrefix("claude-") { return n }
        let lower = n.lowercased()
        guard let family = ["opus", "sonnet", "haiku", "fable"].first(where: { lower.contains($0) }) else { return nil }
        var id = "claude-" + family
        if let r = lower.range(of: family + " *[0-9]+(\\.[0-9]+)?", options: .regularExpression) {
            let version = lower[r].replacingOccurrences(of: family, with: "").trimmingCharacters(in: .whitespaces)
            id += "-" + version.replacingOccurrences(of: ".", with: "-")
        }
        return id + (lower.contains("1m") ? "[1m]" : "")
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
