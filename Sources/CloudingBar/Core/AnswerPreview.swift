import Foundation

/// The start of a chat's latest answer, shown when the chat is done (owner,
/// 29.10): Cloud's bubble and the Touch Bar say what Claude answered. Its
/// first lines as plain text — markdown and code left out — or, on macOS 26
/// with Apple Intelligence, a short form of it made by Apple's model on this
/// Mac (ModelShortener), if that form keeps to what the answer says.
enum AnswerPreview {
    /// The first lines are cut to this many characters.
    static let limit = 160
    /// The model is given the answer's start only: its context is small.
    static let modelInput = 2_000
    /// An answer kept in memory is cut to this (a whole report can be long).
    static let kept = 20_000

    /// The answer's first lines as one plain line, cut with "…" to `limit`;
    /// nil when there are no words in it.
    static func firstLines(_ answer: String, limit: Int = limit) -> String? {
        let text = joined(plainLines(answer))
        guard !text.isEmpty else { return nil }
        return cut(text, to: limit)
    }

    /// Long enough that a shorter form helps: its first lines don't fit.
    static func worth(_ answer: String) -> Bool { joined(plainLines(answer)).count > limit }

    /// What the model is given: the answer's plain lines, from its start.
    static func input(_ answer: String) -> String {
        String(plainLines(answer).joined(separator: "\n").prefix(modelInput))
    }

    /// The model's answer, tidied, if it may stand in for `answer`; else nil
    /// and the first lines show. One or two plain sentences, shorter than the
    /// answer, in its language, not a refusal, and with nothing made up: each
    /// number, path or file name in it is in the answer too.
    static func accept(_ summary: String, for answer: String) -> String? {
        let lines = plainLines(summary)
        guard !lines.isEmpty, lines.count <= 2 else { return nil }
        let quotes = CharacterSet(charactersIn: "\"'«»“”`").union(.whitespaces)
        var s = lines.joined(separator: " ").trimmingCharacters(in: quotes)
        if let re = try? NSRegularExpression(pattern: #"^(summary|short version|tl;?dr|in short|кратко|коротко|резюме|пересказ|суть)\s*[:—–-]\s*"#,
                                             options: .caseInsensitive) {
            let labelled = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
            // "Кратко: сделал…" → "Сделал…"
            if labelled != s { s = labelled.prefix(1).uppercased() + labelled.dropFirst() }
        }
        s = s.trimmingCharacters(in: quotes)
        let original = joined(plainLines(answer))
        guard !s.isEmpty, s.count <= limit, s.count < original.count,
              s.split(whereSeparator: \.isWhitespace).count <= 28,
              ShortQuestion.cyrillic(s) == ShortQuestion.cyrillic(original),
              !refusal(s) else { return nil }
        let words = original.lowercased()
        for word in s.split(whereSeparator: \.isWhitespace) {
            let w = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "?!,;:()[]«»“”\"'`."))
            let inner = w.dropLast().dropFirst()
            guard w.contains(where: \.isNumber) || w.contains("/") || inner.contains(".") else { continue }
            if !words.contains(w.lowercased()) { return nil }
        }
        return s
    }

    /// The model said no, or spoke about itself, instead of retelling.
    static func refusal(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["i'm sorry", "i am sorry", "sorry,", "i can't", "i cannot", "i'm unable", "as an ai",
                "извините", "к сожалению, я", "я не могу", "простите"].contains { t.hasPrefix($0) }
    }

    // MARK: Plain text

    /// The answer's lines with the markdown taken out: no code blocks, no
    /// rules, no table separators, no empty lines; a table row's cells
    /// joined with " · ". Only code? Then its lines.
    static func plainLines(_ text: String) -> [String] {
        var prose: [String] = []
        var code: [String] = []
        var inCode = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            if inCode {
                if !line.isEmpty { code.append(collapse(line)) }
                continue
            }
            let p = plain(line)
            if !p.isEmpty { prose.append(p) }
        }
        return prose.isEmpty ? code : prose
    }

    /// One line of markdown as plain text ("" for a rule or a table's separator).
    static func plain(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { return "" }
        if s.hasPrefix("|") || s.hasSuffix("|") {
            let cells = s.trimmingCharacters(in: CharacterSet(charactersIn: "|")).split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil || $0.isEmpty }) { return "" }
            s = cells.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        for (pattern, template) in [
            (#"^(>\s?)+"#, ""),                                   // a quote
            (#"^#{1,6}\s+"#, ""),                                 // a heading
            (#"^[-*+•]\s+(\[[ xX]\]\s+)?"#, ""),                  // a bullet, a task's box
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),                   // an image: its words
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),                    // a link: its words
            (#"`([^`]*)`"#, "$1"),                                // code in a line
            (#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "$2"),            // bold
            (#"~~(?=\S)(.+?)(?<=\S)~~"#, "$1"),                   // struck out
            (#"(?<![\w*])\*(?=[^\s*])([^*\n]+?)(?<=\S)\*(?![\w*])"#, "$1"), // *italic*
            (#"(?<![\w_])_(?=[^\s_])([^_\n]+?)(?<=\S)_(?![\w_])"#, "$1"),   // _italic_, not snake_case
            (#"<br\s*/?>"#, " "),
        ] {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return collapse(s)
    }

    /// The lines as one: after a sentence's end a space, else " · " (a list's items).
    static func joined(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            if out.isEmpty { out = line; continue }
            let ends = out.last.map { ".!?:;…".contains($0) } ?? true
            out += (ends ? " " : " · ") + line
        }
        return out
    }

    /// Cut to `n` characters at a word's end, with "…".
    static func cut(_ text: String, to n: Int) -> String {
        guard text.count > n else { return text }
        var head = String(text.prefix(n - 1))
        if let space = head.lastIndex(where: \.isWhitespace), head.distance(from: head.startIndex, to: space) > n / 2 {
            head = String(head[..<space])
        }
        return head.trimmingCharacters(in: CharacterSet(charactersIn: " ·,;:—–-")) + "…"
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
