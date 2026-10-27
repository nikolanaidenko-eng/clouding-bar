import AppKit

/// A chat's short name for the Touch Bar's button (owner, 27.10): 1–3 words
/// that fit, so the name stands still instead of sliding. Made up by Claude
/// Code's Haiku (ShortNamer) from the chat's title and first message.
enum ShortName {
    /// The longest name asked for. Measured against the bar's chat button:
    /// it cuts the name at 130 pt wide, 12 pt type, leaving 99 pt for the
    /// words (18 pt of padding, 13 for the dot). Cyrillic runs about 6.7 pt
    /// a letter at that size, Latin about 6.0: 14 letters is 94 pt in
    /// Russian ("Правка карусели" with 15 is 100), and the Chats tab, 140 pt
    /// of room, takes much more.
    static let maxChars = 14
    /// The room the bar's chat button leaves for the words, in points.
    static let barRoom: CGFloat = 99

    static func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
    }

    /// The model's answer, tidied, if it may be a chat's name: one line, no
    /// quotes or markdown, at most `maxChars` letters, and it fits the
    /// button. Nil otherwise (the bar then cuts the long title with "…").
    static func accept(_ answer: String) -> String? {
        // Quotes, markdown marks and a closing full stop are the model's habit, not part of the name.
        let marks = CharacterSet(charactersIn: "\"'«»“”`*_#.").union(.whitespacesAndNewlines)
        let s = answer.trimmingCharacters(in: marks)
        guard !s.isEmpty, !s.contains("\n"), s.count <= maxChars,
              !s.contains(where: { "*#`[]{}<>|\\".contains($0) }),
              s.split(whereSeparator: \.isWhitespace).count <= 3,
              s.contains(where: \.isLetter), width(s) <= barRoom else { return nil }
        return s
    }

    /// What the model reads: the title Claude Code made up and the first
    /// message, cut to about 400 letters.
    static func input(title: String?, prompt: String?) -> String? {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let p = (prompt ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !t.isEmpty || !p.isEmpty else { return nil }
        var text = ""
        if !t.isEmpty { text += "Title: \(String(t.prefix(200)))\n" }
        if !p.isEmpty { text += "First message: \(String(p.prefix(400)))" }
        return text
    }

    /// What the model is told it may write: under `maxChars`, so that a little
    /// overshoot still fits (Haiku counts letters loosely; 7 real chats, 27.10).
    static let askedChars = 12

    static let instructions = """
        You name chats with a coding agent. From the chat's title and first message, write the chat's short name: \
        the task being done, not the tool, the project or the app.
        Hard limit: \(askedChars) characters in all, spaces included. Count them. One or two short words, three only \
        if tiny. Drop prepositions, "app", and the project's name. A name over \(askedChars) characters is wrong: \
        shorten it before you answer.
        Write it in the language the person writes in. Plain words only: no quotes, no markdown, no full stop, \
        no explanation. Answer with the name alone.
        Examples (title -> name):
        Исправить падение сборки в CI -> Сборка CI
        Redesign the settings screen -> Settings UI
        Add dark mode to the landing page -> Dark mode
        Не приходят пуши на Android -> Пуши Android
        Fix flaky login test in CI -> Login test
        """
}
