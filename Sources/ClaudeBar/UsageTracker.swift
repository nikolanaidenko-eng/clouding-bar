import Foundation

/// Tails the active session's transcript (the JSONL file Claude Code writes)
/// and keeps a running token total, so the Touch Bar can show usage live.
/// Cache reads are left out of the total: they are re-read every turn and
/// would make it climb far beyond the tokens actually processed fresh.
///
/// It also remembers how full the context window was at the latest reply.
/// The VS Code extension never runs the status line command, so for those
/// sessions the transcript is the only place that number exists.
final class UsageTracker {
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    /// Tokens in the context at the latest reply: fresh input plus
    /// everything read from or written to the prompt cache.
    private(set) var contextTokens: Int?
    /// Model the latest reply was requested with, e.g. "claude-opus-5-5[1m]".
    private(set) var requestedModel: String?

    var onUpdate: (() -> Void)?

    private var transcriptURL: URL?
    private var readOffset: UInt64 = 0
    private var timer: Timer?

    /// Compact summary for the Touch Bar, e.g. "▲ 41k ▼ 2.3k".
    var summary: String {
        "▲ \(Self.compact(inputTokens)) ▼ \(Self.compact(outputTokens))"
    }

    func watch(transcriptPath: String) {
        let url = URL(fileURLWithPath: transcriptPath)
        // Same transcript and already polling? Keep our place.
        if url == transcriptURL && timer != nil { return }
        if url != transcriptURL {
            transcriptURL = url
            readOffset = 0
            inputTokens = 0
            outputTokens = 0
            contextTokens = nil
            requestedModel = nil
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let url = transcriptURL,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        handle.seek(toFileOffset: readOffset)
        let data = handle.readDataToEndOfFile()
        // Only consume whole lines: the last one may still be being written.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        readOffset += UInt64(complete.count)

        var changed = false
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let input = usage["input_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            inputTokens += input + cacheWrite
            outputTokens += usage["output_tokens"] as? Int ?? 0
            if obj["isSidechain"] as? Bool != true {
                contextTokens = input + cacheWrite + cacheRead
                if let model = obj["requestedModel"] as? String { requestedModel = model }
            }
            changed = true
        }
        if changed {
            DispatchQueue.main.async { self.onUpdate?() }
        }
    }

    private static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}
