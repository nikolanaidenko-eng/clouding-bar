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
    }

    private struct State {
        var path: String
        var offset: UInt64
        var size: UInt64 = 0
        var mtime: Date?
    }

    private let queue = DispatchQueue(label: "claudebar.transcripts", qos: .utility)
    private var states: [String: State] = [:]  // touched only on `queue`

    /// A long session's transcript runs to many MB; the latest reply is
    /// all we need, so a first look reads only the tail.
    private static let firstReadLimit: UInt64 = 4 << 20

    private static let assistantMark = Data(#""type":"assistant""#.utf8)
    private static let interruptMark = Data("[Request interrupted by user".utf8)

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

        var skipFirstLine = false
        if state.offset == UInt64.max || size < state.offset {
            // First look (or the file was rewritten): start near the end.
            state.offset = size > Self.firstReadLimit ? size - Self.firstReadLimit : 0
            skipFirstLine = state.offset > 0
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        handle.seek(toFileOffset: state.offset)
        var data = handle.readDataToEndOfFile()
        state.size = size
        state.mtime = mtime

        if skipFirstLine, let nl = data.firstIndex(of: 0x0A) {
            state.offset += UInt64(data.distance(from: data.startIndex, to: nl) + 1)
            data = data[data.index(after: nl)...]
        }
        // Only whole lines: the last one may still be being written.
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            states[id] = state
            return nil
        }
        let complete = data[data.startIndex...lastNewline]
        state.offset += UInt64(complete.count)
        states[id] = state

        var update = Update(sessionId: id, modified: mtime ?? Date())
        for line in complete.split(separator: 0x0A) {
            let isAssistant = line.range(of: Self.assistantMark) != nil
            let isInterrupt = !isAssistant && line.range(of: Self.interruptMark) != nil
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
            if let model = (obj["requestedModel"] as? String) ?? (message["model"] as? String) {
                update.model = model
            }
            update.interrupted = false
        }
        return update
    }
}
