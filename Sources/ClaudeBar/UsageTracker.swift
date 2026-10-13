import Foundation

/// Tails the active session's transcript (the JSONL file Claude Code writes)
/// and keeps a running token total, so the Touch Bar can show usage live.
final class UsageTracker {
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0

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
        // Same transcript? Keep our place instead of recounting.
        if url != transcriptURL {
            transcriptURL = url
            readOffset = 0
            inputTokens = 0
            outputTokens = 0
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
        readOffset += UInt64(data.count)
        guard !data.isEmpty else { return }

        var changed = false
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            inputTokens += usage["input_tokens"] as? Int ?? 0
            inputTokens += usage["cache_read_input_tokens"] as? Int ?? 0
            inputTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
            outputTokens += usage["output_tokens"] as? Int ?? 0
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
