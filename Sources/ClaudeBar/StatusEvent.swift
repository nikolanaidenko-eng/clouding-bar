import Foundation

/// The JSON Claude Code pipes to a status line command. Our status line
/// script relays it to the app's socket untouched. Only the fields the
/// Touch Bar needs are decoded; everything here may be absent or null.
/// See: https://code.claude.com/docs/en/statusline
struct StatusEvent: Decodable {
    let sessionId: String?
    let transcriptPath: String?
    let contextWindow: ContextWindow?
    let rateLimits: RateLimits?

    struct ContextWindow: Decodable {
        let usedPercentage: Double?
        let contextWindowSize: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case contextWindowSize = "context_window_size"
        }
    }

    struct RateLimits: Decodable {
        let fiveHour: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
        }
    }

    struct Window: Decodable {
        let usedPercentage: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case contextWindow = "context_window"
        case rateLimits = "rate_limits"
    }
}

/// Latest numbers shown on the bar. Session limit values are account-wide,
/// so the newest report from any session wins.
final class LiveStatus {
    var sessionPercent: Double?
    var sessionResetsAt: Date?
    var contextPercent: Double?

    private static var fileURL: URL {
        Config.directory.appendingPathComponent("last-status.json")
    }

    private struct Snapshot: Codable {
        var sessionPercent: Double?
        var sessionResetsAt: Date?
        var contextPercent: Double?
    }

    /// Restores the last numbers so the bar isn't empty after a restart.
    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        sessionPercent = snap.sessionPercent
        sessionResetsAt = snap.sessionResetsAt
        contextPercent = snap.contextPercent
        expireIfNeeded()
    }

    func save() {
        let snap = Snapshot(sessionPercent: sessionPercent,
                            sessionResetsAt: sessionResetsAt,
                            contextPercent: contextPercent)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func apply(_ event: StatusEvent) {
        if let window = event.rateLimits?.fiveHour {
            if let p = window.usedPercentage { sessionPercent = p }
            if let r = window.resetsAt { sessionResetsAt = Date(timeIntervalSince1970: r) }
        }
        if let p = event.contextWindow?.usedPercentage { contextPercent = p }
        save()
    }

    /// Context fill worked out from the transcript, for sessions that never
    /// run the status line (the VS Code extension). The window is 1M for
    /// "[1m]" models and 200k otherwise, unless the config pins it.
    func apply(contextTokens: Int, model: String?, windowOverride: Int?) {
        var window = windowOverride ?? ((model?.contains("[1m]") ?? false) ? 1_000_000 : 200_000)
        if contextTokens > window { window = max(window, 1_000_000) }
        contextPercent = min(100, Double(contextTokens) / Double(window) * 100)
        save()
    }

    /// Clears the session window once its reset time has passed.
    func expireIfNeeded(now: Date = Date()) {
        if let r = sessionResetsAt, r <= now {
            sessionPercent = 0
            sessionResetsAt = nil
        }
    }

    /// "1:23" (hours:minutes) until the 5-hour window resets.
    var resetCountdown: String? {
        guard let r = sessionResetsAt else { return nil }
        let seconds = max(0, Int(r.timeIntervalSinceNow))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }
}
