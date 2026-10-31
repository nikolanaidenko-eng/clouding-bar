import Foundation

/// Cowork tasks that run on this Mac, as Claude Desktop keeps them (an
/// organization on the API has them nowhere on claude.ai, owner, 31.10):
/// local-agent-mode-sessions/<account>/<org>/local_<id>.json and, beside it,
/// local_<id>/audit.jsonl, the task's events. Only read, nothing leaves this
/// Mac, no sign-in. Unofficial: every field optional.
enum LocalCowork {
    struct Task {
        var chat: ClaudeAIChats.Chat
        /// Its context and latest answer, from its events.
        var context: ClaudeAIChats.Context?
        var window: Int?
        var costUSD: Double?
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }

    /// What the bar can't do for these tasks, and why: Settings and the tour say it.
    static let limits = "Claude Desktop has no way in from outside for tasks on this Mac, so words go through its window: it has to be open. If it shows another task, the bar switches it there, unless you're using Desktop; closed, words wait, and Send Now opens it. Questions and permissions can be answered from the bar only for the task it shows."

    /// No word from a task at work for this long: not at work any more. (It
    /// may be waiting on you: no event says so, Desktop's window does.)
    static let quiet: TimeInterval = 600

    /// A task, from its file and the end of its events (oldest first).
    /// Dispatch's own session isn't one of them, nor one Desktop keeps off its list.
    static func task(file: Any?, events: [[String: Any]], changed: Date, now: Date = Date()) -> Task? {
        guard let o = file as? [String: Any], let id = o["sessionId"] as? String,
              DesktopSessions.isLocal(id), !id.hasPrefix("local_ditto"), o["sessionType"] as? String != "radar" else { return nil }
        var chat = ClaudeAIChats.Chat(uuid: id)
        chat.local = true
        let first = (o["initialMessage"] as? String)?.split(separator: "\n").first.map(String.init)
        chat.name = ((o["title"] as? String) ?? first).map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        chat.model = (o["model"] as? String).map { String($0.prefix(80)) }
        chat.archived = o["isArchived"] as? Bool == true
        let active = (o["lastActivityAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        chat.updatedAt = max(active ?? .distantPast, changed)

        // What came after the last turn ended: the turn at work.
        let end = events.lastIndex { $0["type"] as? String == "result" }
        let after = events[(end.map { $0 + 1 } ?? 0)...].filter { ["user", "assistant"].contains($0["type"] as? String) }
        let result = end.map { events[$0] }
        chat.settledAt = ClaudeAIChats.date(result?["timestamp"])
        // A tool at work or a question on you says nothing for as long as it takes.
        let waiting = ((after.last?["message"] as? [String: Any])?["content"] as? [Any])?
            .contains { ($0 as? [String: Any])?["type"] as? String == "tool_use" } == true
        if !after.isEmpty, now.timeIntervalSince(changed) < (waiting ? ClaudeAIChats.recent : quiet) {
            chat.running = true
            chat.runningSince = ClaudeAIChats.date(after.first?["timestamp"])
            // Asked you something, in whichever task the window shows. No event says "may I".
            let asks = ((after.last?["message"] as? [String: Any])?["content"] as? [Any])?
                .contains { ($0 as? [String: Any])?["name"] as? String == "AskUserQuestion" } == true
            if asks { chat.needsInput = "question" }
        }
        var task = Task(chat: chat)
        task.context = ClaudeAIChats.context(events: Array(events.reversed()))
        if let context = task.context, chat.model == nil { task.chat.model = context.model }
        let usage = (result?["modelUsage"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        task.window = usage.compactMap { ($0["contextWindow"] as? NSNumber)?.intValue }.max().flatMap { $0 > 0 ? $0 : nil }
        task.costUSD = (result?["total_cost_usd"] as? NSNumber)?.doubleValue
        return task
    }

    /// The events in the end of a file; a first line cut short is left out.
    static func events(tail: Data, cut: Bool) -> [[String: Any]] {
        var lines = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if cut, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }

    /// Reads what changed, off the main thread. Used from one queue at a time.
    final class Reader {
        private var kept: [String: (changed: Date, task: Task?)] = [:]
        /// The end of its events; more if a single line is longer than that.
        private let tailSizes: [UInt64] = [512 * 1024, 8 * 1024 * 1024]

        /// The tasks active in the last half hour.
        func read(in folder: URL = LocalCowork.folder, now: Date = Date()) -> [Task] {
            let fm = FileManager.default
            var found: [Task] = []
            var seen = Set<String>()
            for account in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                    let places = [org, org.appendingPathComponent("agent")]
                    for file in places.flatMap({ (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] })
                    where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                        let audit = file.deletingPathExtension().appendingPathComponent("audit.jsonl")
                        let changed = [file, audit].compactMap { Self.modified($0) }.max() ?? .distantPast
                        guard now.timeIntervalSince(changed) < ClaudeAIChats.recent else { continue }
                        seen.insert(file.path)
                        // A quiet one is looked at again too: "at work" runs out by the clock.
                        if let known = kept[file.path], known.changed == changed, known.task?.chat.running != true {
                            if let task = known.task { found.append(task) }
                            continue
                        }
                        let task = read(file: file, audit: audit, changed: changed, now: now)
                        kept[file.path] = (changed, task)
                        if let task { found.append(task) }
                    }
                }
            }
            kept = kept.filter { seen.contains($0.key) }
            return found
        }

        private func read(file: URL, audit: URL, changed: Date, now: Date) -> Task? {
            guard let data = try? Data(contentsOf: file), data.count < 8_000_000 else { return nil }
            var events: [[String: Any]] = []
            if let handle = try? FileHandle(forReadingFrom: audit) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                for tailSize in tailSizes where events.isEmpty {
                    let start = size > tailSize ? size - tailSize : 0
                    try? handle.seek(toOffset: start)
                    if let tail = try? handle.readToEnd() { events = LocalCowork.events(tail: tail, cut: start > 0) }
                }
            }
            return LocalCowork.task(file: try? JSONSerialization.jsonObject(with: data), events: events, changed: changed, now: now)
        }

        private static func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }
}
