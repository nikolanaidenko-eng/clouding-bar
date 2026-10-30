import Foundation

/// Cowork runs Claude in a machine of its own, which no hook of ours
/// reaches: its tasks come from claude.ai (ClaudeAIChats) since 1.2.8. What
/// Stats shows for them is kept in cowork-usage.json: from the task's card
/// on claude.ai (CoworkLedger, since 1.2.20), and, before 1.2.8, from what
/// the plugin reported.
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

    /// What each Cowork chat spent. The fields after `usage` came with
    /// 1.2.20 (older files have none).
    struct Kept: Codable, Equatable {
        var project: String?
        var title: String?
        var model: String?
        /// Unix hour → spent.
        var usage: [String: Spent]
        /// The card's running total at the last read: the next read adds
        /// the difference, so a restart doesn't count it twice.
        var total: Int?
        /// Seconds of work short of a minute, carried to the next.
        var carry: Int?
    }

    static var keptURL: URL { Config.directory.appendingPathComponent("cowork-usage.json") }

    static func kept() -> [String: Kept] {
        (try? JSONDecoder().decode([String: Kept].self, from: Data(contentsOf: keptURL))) ?? [:]
    }

    // MARK: What a read of a task's card adds

    /// What one read of a card adds to the task's record.
    struct Step: Equatable {
        /// Tokens to add, to the unix hour `tokenHour`.
        var tokens = 0
        var tokenHour = 0
        /// Whole minutes of work to add, to the hour of the read.
        var minutes = 0
        /// Seconds of work not yet a minute.
        var carry = 0
        /// The running total to keep for the next read.
        var total: Int?
    }

    /// The longest gap between two reads that counts as work: a Mac asleep
    /// between them isn't (owner, 30.10).
    static let longestGap: TimeInterval = 60

    static func hour(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 3600)) }

    /// What a read adds, from the card's running total (`total`, nil if it
    /// has none), the one kept from the read before (`last`, nil: never
    /// read), when the task began, and the time of the read before
    /// (`since`; nil: none in this run).
    ///  - First read: everything so far goes to the hour the task began (else
    ///    to this hour), so the sum is right and the past isn't doubled.
    ///  - Later: the difference, to this hour. The same total again: nothing.
    ///  - A total below the last: nothing, and the highest stays the mark. A
    ///    card that's short or behind once mustn't count it all again (review,
    ///    30.10: 500k, 499k, 501k came to 1M); a count begun over counts again
    ///    from where it passes the mark — too little, never too much.
    ///  - Minutes: the time since the read before, while it works, at most
    ///    `longestGap` per read; seconds short of a minute carry on.
    static func step(total: Int?, last: Int?, created: Date?, now: Date, working: Bool,
                     since: Date?, carry: Int = 0) -> Step {
        var s = Step(tokenHour: hour(now), carry: carry, total: last)
        if let total {
            if let last {
                s.total = max(total, last)
                s.tokens = max(total - last, 0)
            } else {
                s.total = total
                s.tokens = total
                if let created, created <= now { s.tokenHour = hour(created) }
            }
        }
        if working, let since {
            let gap = min(max(now.timeIntervalSince(since), 0), longestGap)
            let seconds = carry + Int(gap.rounded())
            s.minutes = seconds / 60
            s.carry = seconds % 60
        }
        return s
    }
}

/// Cowork's record for Stats, written from the task cards claude.ai gives
/// (owner, 30.10: for Cowork all that can be, comes from claude.ai). Kept in
/// cowork-usage.json, in memory too; written only when something changed,
/// and atomically (Stats reads it from another thread).
final class CoworkLedger {
    private let url: URL
    private var kept: [String: Cowork.Kept]
    /// When each task's card was last read in this run.
    private var seen: [String: Date] = [:]

    init(url: URL = Cowork.keptURL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else {
            kept = [:]
            return
        }
        if let read = try? JSONDecoder().decode([String: Cowork.Kept].self, from: data) {
            kept = read
        } else {
            // Can't be read: put aside, not written over — it's the only copy
            // of what's been counted (review, 30.10).
            kept = [:]
            let aside = url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
        }
    }

    /// A read of a task's card (by its chat's id). True if the file changed.
    @discardableResult
    func record(_ card: ClaudeAIChats.Remote, task id: String, model: String?, now: Date = Date()) -> Bool {
        let before = kept[id]
        let step = Cowork.step(total: card.usedTokens, last: before?.total, created: card.created, now: now,
                               working: card.working, since: seen[id], carry: before?.carry ?? 0)
        seen[id] = now
        guard before != nil || step.total != nil || step.minutes > 0 else { return false }
        var task = before ?? Cowork.Kept(usage: [:])
        if let model, !model.isEmpty { task.model = String(model.prefix(80)) }
        func add(_ hour: Int, tokens: Int, minutes: Int) {
            var spent = task.usage[String(hour)] ?? Cowork.Spent(tokens: 0, minutes: 0)
            spent.tokens += tokens
            spent.minutes += minutes
            task.usage[String(hour)] = spent
        }
        if step.tokens > 0 { add(step.tokenHour, tokens: step.tokens, minutes: 0) }
        if step.minutes > 0 { add(Cowork.hour(now), tokens: 0, minutes: step.minutes) }
        task.total = step.total
        task.carry = step.carry
        // The seconds short of a minute stay in memory until something else is written.
        var onDisk = task
        onDisk.carry = before?.carry
        let changed = before.map { onDisk != $0 } ?? true
        kept[id] = task
        if changed { save() }
        return changed
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
