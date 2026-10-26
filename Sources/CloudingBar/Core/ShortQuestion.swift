import Foundation

/// A question put shorter for the Touch Bar (owner, 26.10): only a question
/// in words — never a permission's command, never an answer's label — and
/// only if it keeps what the asking part names.
enum ShortQuestion {
    /// Long enough to be worth putting shorter on the bar.
    static func worth(_ text: String) -> Bool { text.count > 60 }

    /// The model's answer, tidied, if it may stand in for `original`; else nil
    /// and the bar shows the original.
    static func accept(_ answer: String, for original: String) -> String? {
        let s = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”`*"))
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains("\n"), s.count < original.count, s.count <= 100, s.hasSuffix("?"),
              s.split(whereSeparator: \.isWhitespace).count <= 14,
              // In the question's own language: Cyrillic for Cyrillic.
              cyrillic(s) == cyrillic(original) else { return nil }
        // Every key token kept, and in the same order: "delete A, keep B"
        // never comes back as "delete B, keep A".
        let lower = s.lowercased()
        var from = lower.startIndex
        for token in keyTokens(in: original) {
            guard let r = lower.range(of: token.lowercased(), range: from..<lower.endIndex) else { return nil }
            from = r.upperBound
        }
        return s
    }

    static func cyrillic(_ text: String) -> Bool { text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }

    /// What the asking part names and must keep: code, quoted words, and
    /// words with a digit, a slash or a dot inside (5-hour, ~/path, file.swift).
    static func keyTokens(in text: String) -> [String] {
        let asking = sentences(text).filter { $0.contains("?") }.joined(separator: " ")
        var tokens: [String] = []
        for pattern in ["`([^`]+)`", "«([^»]+)»", "“([^”]+)”", "\"([^\"]+)\""] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = asking as NSString
            for m in re.matches(in: asking, range: NSRange(location: 0, length: ns.length)) {
                tokens.append(ns.substring(with: m.range(at: 1)))
            }
        }
        for word in asking.split(whereSeparator: \.isWhitespace) {
            let w = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "?!,;:()[]«»“”\"'`"))
            let inner = w.dropLast().dropFirst()
            if w.contains(where: \.isNumber) || w.contains("/") || inner.contains(".") { tokens.append(w) }
        }
        // Each once, in the order the question has them.
        var seen = Set<String>()
        return tokens.filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { (asking.range(of: $0)?.lowerBound ?? asking.endIndex) < (asking.range(of: $1)?.lowerBound ?? asking.endIndex) }
    }

    /// The sentences, each with its own ending: a sentence ends at . ! ? …
    /// followed by a space or the end, not at the dot in Config.swift or v1.2.
    static func sentences(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "(?<=[.!?…])\\s+") else { return [text] }
        let ns = text as NSString
        var parts: [String] = []
        var start = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: start))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
