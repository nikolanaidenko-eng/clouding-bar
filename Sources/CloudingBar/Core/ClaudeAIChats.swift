import Foundation

/// Cowork tasks and claude.ai chats, as claude.ai lists them for the
/// signed-in account (its sidebar's list): what each is called, whether it
/// works or waits for you, and a Cowork task's context from its events — no
/// plugin, no folder, nothing asked of Claude (owner, 28.10). Unofficial
/// answers: every field optional, numbers kept sane.
enum ClaudeAIChats {
    struct Chat: Equatable {
        let uuid: String
        var name: String?
        var model: String?
        /// A Cowork task's session ("cse_…"): its events hold the context.
        var workspace: String?
        /// Claude is replying (`live_status` "running").
        var running = false
        var runningSince: Date?
        /// "permission" or "question"; "input" when it doesn't say which.
        var needsInput: String?
        /// When its last reply ended.
        var settledAt: Date?
        var updatedAt: Date?
        /// Archived in claude.ai or Claude Desktop: not shown.
        var archived = false

        var isCowork: Bool { workspace != nil }
        var lastActive: Date? { [updatedAt, settledAt, runningSince].compactMap { $0 }.max() }
        /// Its page in Claude Desktop, as DesktopChat reads it.
        var page: String { "/chat/" + uuid }
    }

    /// How long a chat that's done is shown after it was last active (3 hours
    /// till 28.10; owner: closed chats stayed in the list).
    static let recent: TimeInterval = 30 * 60

    /// What claude.ai shows a chat in, by the session id the app keeps.
    static func sessionId(_ chat: Chat) -> String { (chat.isCowork ? "cowork-" : "claudeai-") + chat.uuid }

    /// The list: an array, or `{"data": [...]}` (chat_conversations_v2).
    static func chats(_ json: Any?) -> [Chat] {
        items(json).compactMap { o in
            guard let uuid = o["uuid"] as? String, isId(uuid) else { return nil }
            var chat = Chat(uuid: uuid)
            chat.name = (o["name"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
                .flatMap { $0.isEmpty ? nil : $0 }
            chat.model = (o["model"] as? String).map { String($0.prefix(80)) }
            chat.workspace = (o["workspace_session_id"] as? String).flatMap { isId($0) ? $0 : nil }
            chat.running = o["live_status"] as? String == "running"
            chat.runningSince = date(o["live_status_started_at"])
            if o["needs_input"] as? Bool == true {
                let kind = o["needs_input_kind"] as? String
                chat.needsInput = kind == "permission" || kind == "question" ? kind : "input"
            }
            chat.settledAt = date(o["last_settled_at"])
            chat.updatedAt = date(o["updated_at"])
            chat.archived = o["is_archived"] as? Bool == true
            return chat
        }
    }

    struct Context: Equatable {
        let tokens: Int
        let model: String?
    }

    /// A Cowork task's context: what its latest reply was given (input +
    /// cache read + cache written), and the model. Events come newest
    /// first, `{"data": [...]}`; a subagent's replies aren't the task's.
    static func context(events json: Any?) -> Context? {
        for e in items(json) {
            let payload = e["payload"] as? [String: Any] ?? e
            guard (e["type"] as? String ?? payload["type"] as? String) == "assistant",
                  !(payload["parent_tool_use_id"] is String),
                  let message = payload["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .map { clamp(usage[$0] as? NSNumber) }.reduce(0, +)
            guard tokens > 0 else { continue }
            return Context(tokens: min(tokens, 10_000_000), model: (message["model"] as? String).map { String($0.prefix(80)) })
        }
        return nil
    }

    /// The objects of an array, or of `{"data": [...]}`; anything else in it left out.
    static func items(_ json: Any?) -> [[String: Any]] {
        (json as? [Any] ?? (json as? [String: Any])?["data"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// A chat's or session's id: letters, digits, "-" and "_" — it goes into
    /// a URL's path.
    static func isId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 80 && s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Microseconds ("…:05.123456+00:00"): cut to milliseconds.
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let digits = s[s.index(after: dot)...].prefix { $0.isNumber }
        let rest = s[s.index(after: dot)...].dropFirst(digits.count)
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: String(s[..<dot]) + "." + digits.prefix(3) + rest)
    }

    private static func clamp(_ n: NSNumber?) -> Int {
        guard let d = n?.doubleValue, d.isFinite, d > 0 else { return 0 }
        return Int(min(d, 10_000_000))
    }
}
