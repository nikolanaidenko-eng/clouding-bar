import Foundation

/// How dictated words join up, from plain strings (VoiceInput's own state
/// stays with it).
enum VoiceText {
    static func join(_ a: String, _ b: String) -> String {
        [a, b].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The new transcription isn't a revision of the last one: it began again.
    /// Punctuation aside: a comma the recognizer adds on second thought
    /// ("Ну вот" → "Ну, вот") doesn't make it a new one.
    static func startedOver(_ new: String, after old: String) -> Bool {
        let bare = { (s: String) in Array(s.lowercased().filter { !$0.isPunctuation }) }
        let a = bare(new), b = bare(old)
        guard !a.isEmpty, !b.isEmpty, a.count < b.count else { return false }
        var same = 0
        while same < min(a.count, b.count), a[same] == b[same] { same += 1 }
        return same < min(4, a.count)
    }

    /// The macOS 26 dictation's pieces: a space only where none is.
    static func glue(_ a: String, _ b: String) -> String {
        guard !a.isEmpty, !b.isEmpty else { return a + b }
        return a.last!.isWhitespace || b.first!.isWhitespace ? a + b : a + " " + b
    }
}

/// claude.ai's own cookie domain, and no other's.
enum ClaudeAICookie {
    static func isClaudeAI(_ domain: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return d == "claude.ai"
    }
}

/// What Terminal and iTerm answer about their tabs (Terminals).
enum TerminalTabs {
    /// A tty left safe to put in an AppleScript string.
    static func safe(_ tty: String) -> String { tty.replacingOccurrences(of: "\"", with: "") }

    /// "tty <tab> title" lines → the tabs; anything else isn't one.
    static func parse(_ text: String) -> [(tty: String, title: String)] {
        var list: [(tty: String, title: String)] = []
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: "\t", maxSplits: 1)
            guard pair.count == 2, pair[0].hasPrefix("/dev/") else { continue }
            list.append((String(pair[0]), String(pair[1])))
        }
        return list
    }

    /// Only a device's path counts as the tab in front.
    static func frontTTY(_ answer: String?) -> String? {
        answer.flatMap { $0.hasPrefix("/dev/") ? $0 : nil }
    }
}

/// What the Stats tab says in words.
enum StatsText {
    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h" + (minutes % 60 > 0 ? " \(minutes % 60) min" : "") : "\(minutes) min"
    }

    /// "Mostly Opus 5.5 · peak hour 14:00 · busiest on Tuesdays"
    static func subline(_ s: StatsSummary, rangeName: String) -> String {
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US")
        let parts: [String?] = [
            s.favoriteModel.map { "Mostly \($0)" },
            s.peakHour.map { "peak hour \($0):00" },
            s.busiestWeekday.map { "busiest on \(weekday.weekdaySymbols[$0 - 1])s" },
        ]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? "Nothing yet \(rangeName)" : text
    }

    /// The grid's days: [week][weekday], nil after today.
    static func gridDays(weeks: Int, now: Date = Date(), calendar: Calendar = .current) -> [[Date?]] {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let today = cal.startOfDay(for: now)
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let first = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!
        return (0..<weeks).map { w in
            (0..<7).map { d in
                let day = cal.date(byAdding: .day, value: w * 7 + d, to: first)!
                return day <= today ? day : nil
            }
        }
    }
}
