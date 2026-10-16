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
        /// The latest entry is "[Request interrupted by user]".
        var interrupted: Bool?
        var modified: Date
        /// Session totals: fresh input (incl. cache writes) and output.
        var tokensIn = 0
        var tokensOut = 0
        var linesAdded = 0
        var linesRemoved = 0
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
    }

    private let queue = DispatchQueue(label: "claudebar.transcripts", qos: .utility)
    private var states: [String: State] = [:]  // touched only on `queue`

    /// Read in slices, so a long session's transcript (many MB) never
    /// sits in memory whole.
    private static let chunk = 8 << 20

    private static let assistantMark = Data(#""type":"assistant""#.utf8)
    private static let interruptMark = Data("[Request interrupted by user".utf8)
    private static let editMark = Data(#""toolUseResult""#.utf8)

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

        if state.offset == UInt64.max || size < state.offset {
            // First look, or the file was rewritten: read it all once.
            state = State(path: path, offset: 0)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        handle.seek(toFileOffset: state.offset)
        state.size = size
        state.mtime = mtime

        var update = Update(sessionId: id, modified: mtime ?? Date())
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

    private func scan(_ complete: Data, into update: inout Update, state: inout State) {
        for line in complete.split(separator: 0x0A) {
            let isAssistant = line.range(of: Self.assistantMark) != nil
            let isInterrupt = !isAssistant && line.range(of: Self.interruptMark) != nil
            if !isAssistant, line.range(of: Self.editMark) != nil,
               let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let result = obj["toolUseResult"] as? [String: Any] {
                countLines(result, into: &state)
            }
            guard isAssistant || isInterrupt,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if obj["isSidechain"] as? Bool == true { continue }

            if isInterrupt, obj["type"] as? String == "user" {
                update.interrupted = true
                continue
            }
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  message["model"] as? String != "<synthetic>" else { continue } // error stubs, zero usage
            let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            let cacheWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
            update.contextTokens = input + cacheWrite + cacheRead
            state.tokensIn += input + cacheWrite
            state.tokensOut += (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            if let model = (obj["requestedModel"] as? String) ?? (message["model"] as? String) {
                update.model = model
            }
            update.interrupted = false
        }
    }
}
