import Foundation

/// Tails each session's transcript (the JSONL file Claude Code writes) for
/// what hooks don't carry: how full the context was at the latest reply,
/// the model, and whether you interrupted Claude (no Stop hook fires then).
/// The VS Code panel never runs the status line, so for those sessions the
/// transcript is the only place the context number exists.
final class TranscriptWatcher {
    struct Update {
        let sessionId: String
        var contextTokens: Int?
        var model: String?
        /// Set by "/effort" (the hooks bring it too, from the next turn on).
        var effort: String?
        /// The latest entry is "[Request interrupted by user]".
        var interrupted: Bool?
        var modified: Date
        /// Session totals: fresh input (incl. cache writes) and output.
        var tokensIn = 0
        var tokensOut = 0
        var linesAdded = 0
        var linesRemoved = 0
        /// The chat's title: the one you gave it, else the one Claude Code made up.
        var title: String?
        /// Codex rollouts: the model's context window, and Codex's own limits
        /// (used %, resets at in unix seconds, when reported) for its 5-hour
        /// and weekly windows, and its plan.
        var contextWindow: Int?
        var codexFiveHour: CodexRollout.Window?
        var codexWeek: CodexRollout.Window?
        var codexPlan: String?
        /// Limits of the other buckets Codex meters apart (a model of its
        /// own): kept aside, nothing shows them yet.
        var codexOther: [String: CodexRollout.Limits] = [:]
        /// The latest turn event, and when: working, done, or stopped by you.
        var codexTurn: (state: CodexRollout.Turn, at: Date)?
        /// Fresh input and output of the whole chat, from total_token_usage.
        var codexTokens: (input: Int, output: Int)?
        /// The file's first line, read when it is first looked at.
        var codexMeta: CodexRollout.Meta?
        /// A reply of the last minute with ☁️ in its words, the chat's first:
        /// Claude waving at Cloud (see the note in MascotView.swift).
        var waved = false
    }

    private struct State {
        var path: String
        var offset: UInt64
        var size: UInt64 = 0
        var mtime: Date?
        var tokensIn = 0
        var tokensOut = 0
        var linesAdded = 0
        var linesRemoved = 0
        /// Replies already counted: Claude Code writes one line per block of
        /// a reply (thinking, text, each tool call), each with the reply's
        /// usage, and later writes some replies again whole — so a reply
        /// counts once, however far apart its lines are.
        var counted = Set<String>()
        /// The reply being read: its next blocks still count for the context.
        var lastId: String?
        /// Edits already counted (by line uuid): they're written again too.
        var edits = Set<String>()
        var aiTitle: String?
        var customTitle: String?
        /// Claude has put ☁️ in this chat before (read from the whole file,
        /// so it holds after a restart): Cloud waves back once a chat — a
        /// fork worked on with Claude would get it every reply (owner, 24.10).
        var waved = false
    }

    private let queue = DispatchQueue(label: "cloudingbar.transcripts", qos: .utility)
    private var states: [String: State] = [:]  // touched only on `queue`

    /// Read in slices, so a long session's transcript (many MB) never
    /// sits in memory whole.
    private static let chunk = 8 << 20

    private static let assistantMark = Data(#""type":"assistant""#.utf8)
    private static let cloudMark = Data("☁".utf8)
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let interruptMark = Data("[Request interrupted by user".utf8)
    private static let editMark = Data(#""toolUseResult""#.utf8)
    /// What "/model" and "/effort" print: "Set model to …", "Set effort level to …".
    private static let commandMark = Data("<local-command-stdout>Set ".utf8)
    /// Codex's rollout: usage and limits, and each turn's model and effort.
    private static let codexUsageMark = Data(#""type":"token_count""#.utf8)
    private static let codexTurnMark = Data(#""type":"turn_context""#.utf8)
    private static let codexMarks = ["task_started", "task_complete", "turn_aborted"].map { Data(#""type":"\#($0)""#.utf8) }
    /// A Codex rollout is read from its last 3 MB on first sight: a chat's
    /// file can run to hundreds, and what is wanted is at its end.
    static let codexTail: UInt64 = 3 << 20
    /// The chat's title, as VS Code's tab and the terminal show it.
    private static let aiTitleMark = Data(#""type":"ai-title""#.utf8)
    private static let customTitleMark = Data(#""type":"custom-title""#.utf8)

    /// Reads what was appended since the last poll. `completion` runs on
    /// the main queue with one update per transcript that changed.
    func poll(_ sessions: [(id: String, path: String)], completion: @escaping ([Update]) -> Void) {
        queue.async {
            var updates: [Update] = []
            let wanted = Set(sessions.map(\.id))
            self.states = self.states.filter { wanted.contains($0.key) }
            for (id, path) in sessions {
                if let update = self.read(id: id, path: path) { updates.append(update) }
            }
            if !updates.isEmpty {
                DispatchQueue.main.async { completion(updates) }
            }
        }
    }

    private func read(id: String, path: String) -> Update? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        let mtime = attrs[.modificationDate] as? Date

        var state = states[id] ?? State(path: path, offset: UInt64.max)
        if state.path != path { state = State(path: path, offset: UInt64.max) }
        if state.offset != UInt64.max && size == state.size && mtime == state.mtime { return nil }

        let codex = CodexRollout.isRollout(path)
        var first = false
        if state.offset == UInt64.max || size < state.offset {
            // First look, or the file was rewritten: read it all once.
            state = State(path: path, offset: 0)
            first = true
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        if codex && first && size > Self.codexTail {
            // Only its end, from the next whole line.
            state.offset = size - Self.codexTail
            handle.seek(toFileOffset: state.offset)
            var skipped: UInt64 = 0
            while skipped < 8 << 20 {
                let d = handle.readData(ofLength: 1 << 20)
                if d.isEmpty { break }
                if let nl = d.firstIndex(of: 0x0A) { skipped += UInt64(nl - d.startIndex + 1); break }
                skipped += UInt64(d.count)
            }
            state.offset += skipped
        }
        handle.seek(toFileOffset: state.offset)
        state.size = size
        state.mtime = mtime

        var update = Update(sessionId: id, modified: mtime ?? Date())
        if codex && first { update.codexMeta = CodexRollout.meta(at: path) }
        var carry = Data()
        var sawLines = false
        while true {
            let data = handle.readData(ofLength: Self.chunk)
            if data.isEmpty { break }
            carry.append(data)
            // Only whole lines: the last one may still be being written.
            guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
            let complete = carry[carry.startIndex...lastNewline]
            state.offset += UInt64(complete.count)
            scan(complete, into: &update, state: &state)
            carry = Data(carry[carry.index(after: lastNewline)...])
            sawLines = true
        }
        states[id] = state
        guard sawLines else { return nil }
        update.tokensIn = state.tokensIn
        update.tokensOut = state.tokensOut
        update.linesAdded = state.linesAdded
        update.linesRemoved = state.linesRemoved
        update.title = state.customTitle ?? state.aiTitle
        return update
    }

    /// ±lines from an edit's result: the diff hunks, or a new file's lines.
    private func countLines(_ result: [String: Any], into state: inout State) {
        if let hunks = result["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            for hunk in hunks {
                for l in hunk["lines"] as? [String] ?? [] {
                    if l.hasPrefix("+") { state.linesAdded += 1 } else if l.hasPrefix("-") { state.linesRemoved += 1 }
                }
            }
        } else if result["type"] as? String == "create", let content = result["content"] as? String {
            state.linesAdded += content.split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    /// One line of a Codex rollout ({"timestamp", "type", "payload"}): a
    /// token_count event (the latest reply's usage over the model's window,
    /// and the limits), a turn's start or end, or a turn's context (its model
    /// and effort).
    static func scanCodex(_ line: Data.SubSequence, into update: inout Update) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return }
        if obj["type"] as? String == "turn_context" {
            if let m = payload["model"] as? String { update.model = m }
            if let e = payload["effort"] as? String { update.effort = e }
            return
        }
        guard obj["type"] as? String == "event_msg" else { return }
        let at = (obj["timestamp"] as? String).flatMap(CodexRollout.date) ?? Date()
        switch payload["type"] as? String {
        case "task_started":
            update.codexTurn = (.started, at)
            if let window = (payload["model_context_window"] as? NSNumber)?.intValue { update.contextWindow = window }
        case "task_complete":
            update.codexTurn = (.done, at)
        case "turn_aborted":
            update.codexTurn = (.aborted, at)
        case "token_count":
            if let info = payload["info"] as? [String: Any] {
                if let last = info["last_token_usage"] as? [String: Any],
                   let total = (last["total_tokens"] as? NSNumber)?.intValue {
                    update.contextTokens = total
                }
                if let window = (info["model_context_window"] as? NSNumber)?.intValue { update.contextWindow = window }
                if let all = info["total_token_usage"] as? [String: Any] {
                    func n(_ k: String) -> Int { (all[k] as? NSNumber)?.intValue ?? 0 }
                    update.codexTokens = (max(0, n("input_tokens") - n("cached_input_tokens")), n("output_tokens"))
                }
            }
            if let rl = payload["rate_limits"] as? [String: Any], let (bucket, limits) = CodexRollout.limits(from: rl, at: at) {
                if bucket == "codex" {
                    if let w = limits.fiveHour { update.codexFiveHour = w }
                    if let w = limits.week { update.codexWeek = w }
                    if let p = limits.plan { update.codexPlan = p }
                } else {
                    update.codexOther[bucket] = limits
                }
            }
        default:
            break
        }
    }

    private func scan(_ complete: Data, into update: inout Update, state: inout State) {
        for line in complete.split(separator: 0x0A) {
            if line.range(of: Self.codexUsageMark) != nil || line.range(of: Self.codexTurnMark) != nil
                || Self.codexMarks.contains(where: { line.range(of: $0) != nil }) {
                Self.scanCodex(line, into: &update)
                if let t = update.codexTokens { state.tokensIn = t.input; state.tokensOut = t.output }
                continue
            }
            if line.range(of: Self.aiTitleMark) != nil || line.range(of: Self.customTitleMark) != nil {
                if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                    if let t = obj["customTitle"] as? String, !t.isEmpty { state.customTitle = t }
                    if let t = obj["aiTitle"] as? String, !t.isEmpty { state.aiTitle = t }
                }
                continue
            }
            let isAssistant = line.range(of: Self.assistantMark) != nil
            let isInterrupt = !isAssistant && line.range(of: Self.interruptMark) != nil
            if !isAssistant, line.range(of: Self.commandMark) != nil,
               let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               obj["isSidechain"] as? Bool != true,
               let message = obj["message"] as? [String: Any] {
                let content = message["content"]
                let text = content as? String
                    ?? (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
                if let model = ModelChoice.modelSet(in: text) { update.model = model }
                if let effort = ModelChoice.effortSet(in: text) { update.effort = effort }
                continue
            }
            if !isAssistant, line.range(of: Self.editMark) != nil,
               let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let result = obj["toolUseResult"] as? [String: Any],
               (obj["uuid"] as? String).map({ state.edits.insert($0).inserted }) ?? true {
                countLines(result, into: &state)
            }
            guard isAssistant || isInterrupt,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if obj["isSidechain"] as? Bool == true { continue }

            if isInterrupt, obj["type"] as? String == "user" {
                update.interrupted = true
                continue
            }
            // ☁️ in what Claude says (not in code it writes): the chat's
            // first, and just now.
            if isAssistant, !state.waved, line.range(of: Self.cloudMark) != nil,
               let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]],
               // ☁ itself, with or without the emoji selector after it
               blocks.contains(where: { $0["type"] as? String == "text"
                   && ($0["text"] as? String)?.unicodeScalars.contains("\u{2601}") == true }) {
                state.waved = true
                if let when = (obj["timestamp"] as? String).flatMap(Self.stamp.date(from:)),
                   Date().timeIntervalSince(when) < 60 {
                    update.waved = true
                }
            }
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  message["model"] as? String != "<synthetic>" else { continue } // error stubs, zero usage
            let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            let cacheWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
            let id = message["id"] as? String
            if id.map({ state.counted.insert($0).inserted }) ?? true {
                state.tokensIn += input + cacheWrite
                state.tokensOut += (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            } else if id != state.lastId {
                continue // an old reply written again: not where the chat is now
            }
            state.lastId = id
            update.contextTokens = input + cacheWrite + cacheRead
            if let model = (obj["requestedModel"] as? String) ?? (message["model"] as? String) {
                update.model = model
            }
            update.interrupted = false
        }
    }
}
