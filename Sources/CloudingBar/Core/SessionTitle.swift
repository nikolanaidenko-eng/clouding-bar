import Foundation

/// The short name of a Claude Code chat, handed to Claude Code itself (owner,
/// 27.10): the app writes `names/<session id>.json` when Haiku has made one
/// up; on the chat's next message the hook (cloudingbar-hook) answers with
/// `sessionTitle`, and Claude Code writes it as the chat's title — the tab in
/// VS Code and the terminal's title follow. Plain Foundation: the hook is
/// built from this file too, so it works with the app closed.
enum SessionTitle {
    /// What the app wrote for one chat.
    struct Entry: Codable, Equatable {
        var name: String
        /// Claude Code may be told it (not Codex, not the desktop app's chats).
        var claude: Bool
    }

    /// Told at most this many times: if Claude Code doesn't take it, it
    /// isn't offered on every message.
    static let maxSends = 3

    static func directory(base: URL) -> URL { base.appendingPathComponent("names", isDirectory: true) }

    /// A session id is a file name here: nothing else gets through.
    static func isSafe(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func entry(_ id: String, base: URL) -> Entry? {
        guard isSafe(id), let data = try? Data(contentsOf: directory(base: base).appendingPathComponent(id + ".json")),
              let e = try? JSONDecoder().decode(Entry.self, from: data), !e.name.isEmpty else { return nil }
        return e
    }

    static func save(_ entry: Entry, for id: String, base: URL) {
        guard isSafe(id), let data = try? JSONEncoder().encode(entry) else { return }
        let dir = directory(base: base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(id + ".json"), options: .atomic)
    }

    /// How many times the hook has offered the name.
    static func sent(_ id: String, base: URL) -> Int {
        guard isSafe(id), let text = try? String(contentsOf: directory(base: base).appendingPathComponent(id + ".sent"), encoding: .utf8)
        else { return 0 }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func markSent(_ id: String, base: URL) {
        guard isSafe(id) else { return }
        let dir = directory(base: base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? String(sent(id, base: base) + 1).write(to: dir.appendingPathComponent(id + ".sent"), atomically: true, encoding: .utf8)
    }

    /// The name the chat last got by /rename, "Rename session tab" or a
    /// sessionTitle: the last `custom-title` line of the transcript. Read
    /// from the end; a line that only mentions it (a message) is skipped.
    static func lastCustomTitle(inTranscript path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        let mark = Data(#""type":"custom-title""#.utf8)
        var end = data.endIndex
        for _ in 0..<20 {
            guard let hit = data.range(of: mark, options: .backwards, in: data.startIndex..<end) else { return nil }
            let from = data[data.startIndex..<hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let to = data[hit.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            if let obj = (try? JSONSerialization.jsonObject(with: data[from..<to])) as? [String: Any],
               obj["type"] as? String == "custom-title" {
                return (obj["customTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            end = hit.lowerBound
        }
        return nil
    }

    /// Removes what is older than `days` (the app, at launch): the folder
    /// would only grow (review, 27.10).
    static func prune(base: URL, days: Double = 30, now: Date = Date()) {
        let dir = directory(base: base)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(date) > days * 86400 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Config.shortNames is false.
    static func switchedOff(base: URL) -> Bool {
        guard let data = try? Data(contentsOf: base.appendingPathComponent("config.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return obj["shortNames"] as? Bool == false
    }

    /// The hook's output for one event: the title to set, or nil (nothing
    /// to say — the usual answer, and always when anything is unclear).
    /// Only on a message of a Claude Code chat that has a made-up name, that
    /// no one has renamed, that Claude Code doesn't have yet.
    static func hookOutput(for event: [String: Any], codex: Bool, base: URL) -> Data? {
        guard !codex, !switchedOff(base: base), event["hook_event_name"] as? String == "UserPromptSubmit",
              let id = event["session_id"] as? String, let e = entry(id, base: base), e.claude,
              sent(id, base: base) < maxSends else { return nil }
        // A custom title already there is ours (done) or the person's (never
        // overwritten): either way, nothing to say.
        if let path = event["transcript_path"] as? String, lastCustomTitle(inTranscript: path) != nil { return nil }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "sessionTitle": e.name]]
        guard var data = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        markSent(id, base: base)
        data.append(0x0A)
        return data
    }
}
