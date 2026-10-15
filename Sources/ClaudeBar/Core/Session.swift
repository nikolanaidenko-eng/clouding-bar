import Foundation

/// What the character on the bar shows.
enum Activity: String, Codable {
    case sleep  // idle, or the turn finished
    case work   // between your prompt and Claude's Stop
    case wait   // Claude needs you: a permission, a question
}

/// One Claude Code session, keyed by its session_id.
final class Session {
    let id: String
    var cwd: String?
    var transcriptPath: String?
    /// The Claude process, when the hook could tell. Lets us notice a
    /// session is gone even when SessionEnd never arrived.
    var claudePid: Int32?
    /// "claude-vscode", "cli", … (CLAUDE_CODE_ENTRYPOINT)
    var entrypoint: String?
    var activity: Activity = .sleep
    /// A Notification said Claude is waiting for you.
    var waitingNotice = false
    var lastEvent: Date
    var transcriptChanged: Date?

    // Context: tokens from the transcript; window from the status line,
    // the config, or the model name.
    var model: String?
    var contextTokens: Int?
    var contextWindowSize: Int?
    var statusContextPercent: Double?
    /// "Later" on the context warning: stay quiet until this percent.
    var contextSnoozedUntil: Double?

    init(id: String, now: Date = Date()) {
        self.id = id
        self.lastEvent = now
    }

    var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    var lastSeen: Date { max(lastEvent, transcriptChanged ?? .distantPast) }

    func contextPercent(windowOverride: Int?) -> Double? {
        guard let tokens = contextTokens else { return statusContextPercent }
        var window = contextWindowSize ?? windowOverride
            ?? ((model?.contains("[1m]") ?? false) ? 1_000_000 : 200_000)
        if tokens > window { window = max(window, 1_000_000) }
        return min(100, Double(tokens) / Double(window) * 100)
    }

    /// Alive while its Claude process runs. Without a pid, a session that
    /// has been silent for 12 hours counts as gone.
    func isAlive(now: Date = Date()) -> Bool {
        if let pid = claudePid, pid > 1 {
            return kill(pid, 0) == 0 || errno == EPERM
        }
        return now.timeIntervalSince(lastSeen) < 12 * 3600
    }

    // MARK: Persistence

    struct Record: Codable {
        var id: String
        var cwd: String?
        var transcriptPath: String?
        var claudePid: Int32?
        var entrypoint: String?
        var activity: Activity
        var lastEvent: Date
        var model: String?
        var contextTokens: Int?
        var contextWindowSize: Int?
        var statusContextPercent: Double?
    }

    var record: Record {
        Record(id: id, cwd: cwd, transcriptPath: transcriptPath, claudePid: claudePid,
               entrypoint: entrypoint, activity: activity, lastEvent: lastEvent, model: model,
               contextTokens: contextTokens, contextWindowSize: contextWindowSize,
               statusContextPercent: statusContextPercent)
    }

    convenience init(record r: Record) {
        self.init(id: r.id, now: r.lastEvent)
        cwd = r.cwd
        transcriptPath = r.transcriptPath
        claudePid = r.claudePid
        entrypoint = r.entrypoint
        activity = r.activity
        model = r.model
        contextTokens = r.contextTokens
        contextWindowSize = r.contextWindowSize
        statusContextPercent = r.statusContextPercent
    }
}

/// The 5-hour limit. Account-wide, so the newest report from any session
/// wins. Kept in last-status.json so the bar isn't empty after a restart.
final class Account {
    var sessionPercent: Double?
    var resetsAt: Date?

    private static var fileURL: URL {
        Config.directory.appendingPathComponent("last-status.json")
    }

    private struct Snapshot: Codable {
        var sessionPercent: Double?
        var sessionResetsAt: Date?
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        sessionPercent = snap.sessionPercent
        resetsAt = snap.sessionResetsAt
        expireIfNeeded()
    }

    private func save() {
        let snap = Snapshot(sessionPercent: sessionPercent, sessionResetsAt: resetsAt)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func apply(used: Double?, resetsAt reset: Double?) {
        if let used { sessionPercent = used }
        if let reset { resetsAt = Date(timeIntervalSince1970: reset) }
        save()
    }

    /// Once the window has reset, the old number means nothing.
    @discardableResult
    func expireIfNeeded(now: Date = Date()) -> Bool {
        guard let r = resetsAt, r <= now else { return false }
        sessionPercent = 0
        resetsAt = nil
        save()
        return true
    }

    /// "1:23" (hours:minutes) until the window resets.
    var resetCountdown: String? {
        guard let r = resetsAt else { return nil }
        let seconds = max(0, Int(r.timeIntervalSinceNow))
        return String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }
}
