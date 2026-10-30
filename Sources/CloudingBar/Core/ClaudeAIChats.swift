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

    /// A list read, each chat's Cowork session kept: a task stays one, as
    /// read before or looked up by its chat (`found`, ClaudeAI). (Every other
    /// read leaves out the fields that are empty — 32, then 17 — so the
    /// rest reads the same.)
    static func merged(_ chats: [Chat], previous: [Chat], found: [String: String] = [:]) -> [Chat] {
        let before = Dictionary(previous.map { ($0.uuid, $0.workspace) }, uniquingKeysWith: { a, _ in a })
        return chats.map { chat in
            var c = chat
            if c.workspace == nil { c.workspace = before[c.uuid].flatMap { $0 } ?? found[c.uuid] }
            return c
        }
    }

    /// The list with what the tasks' cards say: at work, or waiting on you.
    static func withCards(_ chats: [Chat], _ cards: [String: (working: Bool, waiting: String?)]) -> [Chat] {
        chats.map { chat in
            guard let ws = chat.workspace, let card = cards[ws] else { return chat }
            var c = chat
            c.running = c.running || card.working
            if c.needsInput == nil { c.needsInput = card.waiting }
            return c
        }
    }

    /// The Cowork session of a chat, from claude.ai's list of sessions asked
    /// by the chat's tag (`bard-conversation:<uuid>`): a new task's chat
    /// comes in the chat list without it for minutes (29.10).
    static func session(found json: Any?, chat: String) -> String? {
        // Its tag on it too: were the filter ever left out, the account's
        // newest session (a terminal's) isn't taken for this chat (review, 29.10).
        guard let s = items(json).first, let id = s["id"] as? String, isId(id),
              (s["tags"] as? [Any])?.contains(where: { $0 as? String == "bard-conversation:" + chat }) == true else { return nil }
        let cse = cse(id)
        return cse.hasPrefix("cse_") ? cse : nil
    }

    struct Context: Equatable {
        let tokens: Int
        let model: String?
        /// The text of its latest answer (AnswerPreview), in memory only.
        var answer: String?
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
            return Context(tokens: min(tokens, 10_000_000), model: (message["model"] as? String).map { String($0.prefix(80)) },
                           answer: answer(events: json))
        }
        return nil
    }

    /// The text of a Cowork task's latest answer: its newest reply of its own
    /// (not a subagent's), every text block of that reply in order. A reply
    /// without words (a tool call) has no answer yet.
    static func answer(events json: Any?) -> String? {
        var reply: String?? // the newest reply's id, once met
        var texts: [String] = []
        for e in items(json) {
            let payload = e["payload"] as? [String: Any] ?? e
            guard (e["type"] as? String ?? payload["type"] as? String) == "assistant",
                  !(payload["parent_tool_use_id"] is String),
                  let message = payload["message"] as? [String: Any] else { continue }
            let id = message["id"] as? String
            // An older reply (or one that can't be told apart): the newest is whole.
            if let r = reply, r == nil || r != id { break }
            reply = .some(id)
            let blocks = (message["content"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            let words = message["content"] as? String
                ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            // Newest first: this block came before the ones read already.
            if !words.isEmpty { texts.insert(words, at: 0) }
        }
        let text = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(AnswerPreview.kept))
    }

    /// A session's card on claude.ai (`/v1/code/sessions/<cse>`), as Claude
    /// Code itself reads it: a Cowork task's, or a Remote Control one's.
    struct Remote {
        /// Remote Control: a Claude Code on this Mac, reached through claude.ai.
        var bridge = false
        /// Its Claude Code is on the line. Words for a Remote Control one
        /// that isn't would wait on claude.ai till it comes back.
        var connected = true
        var archived = false
        /// What it waits on you for (`worker_status` "requires_action").
        var pending: Pending?
        /// Its context as Claude counts it, of its real window (a new
        /// account's 1M showed as 200k, owner 29.10), and what it cost —
        /// on an API-billed account what there is instead of a limit.
        var contextUsed: Int?
        var contextMax: Int?
        var costUSD: Double?
        /// Claude is at it (`worker_status` "running"): the list says so only
        /// now and then, and a reply of a few seconds slipped by (30.10).
        var working = false
    }

    /// A question or permission waiting there (`pending_action`).
    struct Pending {
        let requestId: String
        let tool: String
        let input: [String: Any]
    }

    /// The card; nil if it isn't one.
    static func remote(session json: Any?) -> Remote? {
        guard var o = json as? [String: Any] else { return nil }
        // Wrapped as Claude Code unwraps it (2.1.312: `response_shape ?? session`):
        // claude.ai answers with `response_shape` now, so no question ever
        // reached the bar (29.10).
        // (A null `response_shape` beside `session`: JS's ?? skips it, so here too.)
        if o["id"] == nil, let inner = (o["response_shape"] as? [String: Any]) ?? (o["session"] as? [String: Any]) { o = inner }
        guard o["id"] is String else { return nil }
        var r = Remote()
        r.bridge = o["environment_kind"] as? String == "bridge"
        r.connected = o["connection_status"] as? String != "disconnected"
        r.archived = o["status"] as? String == "archived"
        r.working = o["worker_status"] as? String == "running"
        let meta = o["external_metadata"] as? [String: Any]
        if let usage = meta?["context_usage"] as? [String: Any] {
            let used = clamp(usage["used_tokens"] as? NSNumber), max = clamp(usage["max_tokens"] as? NSNumber)
            if max >= 1_000, max <= 10_000_000 {
                r.contextMax = max
                r.contextUsed = min(used, max)
            }
        }
        if let cost = ((meta?["usage"] as? [String: Any])?["cost_usd"] as? NSNumber)?.doubleValue,
           cost.isFinite, cost >= 0, cost < 1_000_000 { r.costUSD = cost }
        if o["worker_status"] as? String == "requires_action",
           let p = meta?["pending_action"] as? [String: Any],
           let tool = p["tool_name"] as? String, !tool.isEmpty, tool.count <= 128,
           // A dialog (an MCP server's form…) isn't a permission: Claude Code
           // itself leaves those to the computer.
           !tool.hasPrefix("dialog:"),
           let request = requestId(p, tool: tool) {
            r.pending = Pending(requestId: request, tool: tool, input: p["input"] as? [String: Any] ?? [:])
        }
        return r
    }

    /// The request to answer. A question's comes as `suppressed_request_id`
    /// (`request_id` empty: "tap to answer" on claude.ai), and Claude Code
    /// takes either; anything else kept for the computer alone (an empty
    /// `request_id`) isn't answered from here.
    private static func requestId(_ p: [String: Any], tool: String) -> String? {
        let given = p["request_id"] as? String ?? ""
        let id = !given.isEmpty ? given : tool == "AskUserQuestion" ? p["suppressed_request_id"] as? String ?? "" : ""
        return !id.isEmpty && id.count <= 200 ? id : nil
    }

    /// The bar writes to claude.ai only for a key that reads the chats too:
    /// one given for the limit alone (before 1.2.8, "Only the Limit") does
    /// nothing else (review, 29.10).
    static func writes(signedIn: Bool, readChats: Bool) -> Bool { signedIn && readChats }

    /// The id the sessions' addresses take: "session_X" is "cse_X" there.
    static func cse(_ id: String) -> String {
        id.hasPrefix("session_") ? "cse_" + id.dropFirst("session_".count) : id
    }

    /// Your words for a session, as Claude Code sends them to one
    /// (POST `/v1/code/sessions/<cse>/events`).
    static func message(_ content: [[String: Any]], session: String, uuid: String = UUID().uuidString.lowercased()) -> [String: Any] {
        ["events": [["payload": [
            "uuid": uuid, "session_id": session, "type": "user", "parent_tool_use_id": NSNull(),
            "message": ["role": "user", "content": content],
        ] as [String: Any]]]]
    }

    /// Your answer to what it waits on: Claude Code's control_response,
    /// the decision as a PermissionRequest hook gives it.
    static func answer(_ decision: [String: Any], request: String, uuid: String = UUID().uuidString.lowercased()) -> [String: Any] {
        ["events": [["payload": [
            "uuid": uuid, "type": "control_response",
            "response": ["subtype": "success", "request_id": request, "response": decision] as [String: Any],
        ] as [String: Any]]]]
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

    /// Your words into a chat as claude.ai's own page sends them (owner,
    /// 30.10: sent to a Cowork task's session they reached Claude but not
    /// the chat, which showed only its answers). ConversationService's
    /// PerformAction, as protobuf (`application/proto`), read off the page:
    /// 1 the chat — 1 the mutation (this app's `sess_…` and a count; the
    /// server wants one), 2 its uuid, 3 and 7 as the page sets them, 14 the
    /// locale; 2 the message — 1 its new uuid, 2 the uuid Claude's reply
    /// will have (the page makes both up; not a server's: 400, 30.10),
    /// 3 the words, 12 the time zone, 13 the language.
    static func chatMessage(_ text: String, chat: String, mutation: (session: String, seq: Int),
                            message: String = UUID().uuidString.lowercased(),
                            reply: String = UUID().uuidString.lowercased(),
                            timeZone: String = TimeZone.current.identifier,
                            language: String = (Locale.preferredLanguages.first ?? "en").components(separatedBy: "-")[0]) -> Data {
        let flags = [1, 2, 3, 6, 8, 10, 22, 24, 28, 33].flatMap { Proto.varint($0, 1) }
        let context = Proto.message(1, Proto.message(1, Proto.string(1, mutation.session) + Proto.varint(2, mutation.seq))
            + Proto.string(2, chat) + Proto.varint(3, 3) + Proto.message(7, flags) + Proto.string(14, "en-US"))
        let send = Proto.message(2, Proto.string(1, message) + Proto.string(2, reply) + Proto.string(3, text)
            + Proto.string(12, timeZone) + Proto.string(13, language) + Proto.varint(18, 1))
        return Data(context + send)
    }

    /// Protobuf's wire format, the little of it PerformAction needs.
    enum Proto {
        static func varint(_ value: Int) -> [UInt8] {
            var v = UInt64(max(0, value)), out: [UInt8] = []
            while v > 127 {
                out.append(UInt8(v & 127) | 128)
                v >>= 7
            }
            return out + [UInt8(v)]
        }
        static func varint(_ field: Int, _ value: Int) -> [UInt8] { varint(field << 3) + varint(value) }
        static func bytes(_ field: Int, _ b: [UInt8]) -> [UInt8] { varint(field << 3 | 2) + varint(b.count) + b }
        static func string(_ field: Int, _ s: String) -> [UInt8] { bytes(field, Array(s.utf8)) }
        static func message(_ field: Int, _ inner: [UInt8]) -> [UInt8] { bytes(field, inner) }
    }

    private static func clamp(_ n: NSNumber?) -> Int {
        guard let d = n?.doubleValue, d.isFinite, d > 0 else { return 0 }
        return Int(min(d, 10_000_000))
    }
}
