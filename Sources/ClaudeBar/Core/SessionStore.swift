import Foundation

/// The model the UI reads: every live Claude Code session plus the account
/// limit. Fed by socket messages and the transcripts. Main queue only.
final class SessionStore {
    private(set) var sessions: [String: Session] = [:]
    let account = Account()
    private let transcripts = TranscriptWatcher()
    private var saveScheduled = false

    /// Fires after anything changed.
    var onChange: (() -> Void)?

    private static var fileURL: URL {
        Config.directory.appendingPathComponent("sessions.json")
    }

    // MARK: Messages

    /// Applies one socket message.
    func apply(_ m: Inbound, now: Date = Date()) {
        if let used = m.fiveHour {
            account.apply(used: used.used, resetsAt: used.resetsAt)
        }
        guard let id = m.sessionId else {
            onChange?()
            return
        }
        if m.event == "SessionEnd" {
            sessions[id] = nil
            scheduleSave()
            onChange?()
            return
        }

        // Only hook events start a session; status messages (the status
        // line, claudebar-tap) just add numbers to one we already know.
        guard let session = sessions[id] ?? (m.event != nil ? Session(id: id, now: now) : nil) else {
            onChange?()
            return
        }
        sessions[id] = session
        if let cwd = m.cwd { session.cwd = cwd }
        if let path = m.transcriptPath { session.transcriptPath = path }
        if let pid = m.claudePid { session.claudePid = pid }
        if let entry = m.entrypoint { session.entrypoint = entry }
        if let p = m.contextUsedPercent { session.statusContextPercent = p }
        if let size = m.contextWindowSize { session.contextWindowSize = size }
        if let model = m.modelId { session.model = model }
        if let cost = m.costUSD { session.costUSD = cost }

        if let event = m.event {
            session.lastEvent = now
            switch event {
            case "SessionStart", "Stop":
                session.activity = .sleep
                session.waitingNotice = false
            case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
                session.activity = .work
                session.waitingNotice = false
            case "Notification":
                switch m.notificationType {
                case "permission_prompt", "elicitation_dialog", "agent_needs_input":
                    session.waitingNotice = true
                case nil where m.message?.localizedCaseInsensitiveContains("permission") == true:
                    session.waitingNotice = true // older Claude Code without notification_type
                default:
                    break
                }
            default:
                break
            }
        }
        scheduleSave()
        onChange?()
        pollTranscripts()
    }

    // MARK: Queries

    var alive: [Session] {
        let now = Date()
        return sessions.values.filter { $0.isAlive(now: now) }
    }

    /// The session whose project is open in the frontmost window, judged by
    /// the window title ("file — project — Visual Studio Code"). Falls back
    /// to the session that was active last.
    func activeSession(windowTitle: String?) -> Session? {
        let candidates = alive
        if let title = windowTitle, let match = Self.bestMatch(title: title, in: candidates) {
            return match
        }
        return candidates.max { $0.lastSeen < $1.lastSeen }
    }

    private static func bestMatch(title: String, in sessions: [Session]) -> Session? {
        var parts = Set<String>()
        var pieces = [title]
        for separator in [" — ", " – ", " - "] {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " (Workspace)", with: "")
            if !trimmed.isEmpty { parts.insert(trimmed) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.pathComponents

        var best: (score: Int, session: Session)?
        for session in sessions {
            guard let cwd = session.cwd else { continue }
            let components = URL(fileURLWithPath: cwd).pathComponents
            var score = 0
            if let last = components.last, parts.contains(last) {
                score = 2
            } else if components.dropFirst(home.count).contains(where: parts.contains) {
                score = 1 // the window shows a parent folder of the session
            }
            guard score > 0 else { continue }
            if best == nil || score > best!.score
                || (score == best!.score && session.lastSeen > best!.session.lastSeen) {
                best = (score, session)
            }
        }
        return best?.session
    }

    // MARK: Upkeep

    /// Drops sessions whose Claude is gone. Returns the ids dropped.
    @discardableResult
    func prune() -> [String] {
        let now = Date()
        let dead = sessions.values.filter { !$0.isAlive(now: now) }.map(\.id)
        guard !dead.isEmpty else { return [] }
        for id in dead { sessions[id] = nil }
        scheduleSave()
        onChange?()
        return dead
    }

    /// Reads new transcript lines for every live session.
    func pollTranscripts() {
        let list = alive.compactMap { s in s.transcriptPath.map { (id: s.id, path: $0) } }
        guard !list.isEmpty else { return }
        transcripts.poll(list) { [weak self] updates in
            guard let self else { return }
            for u in updates {
                guard let s = self.sessions[u.sessionId] else { continue }
                if let t = u.contextTokens { s.contextTokens = t }
                s.tokensIn = u.tokensIn
                s.tokensOut = u.tokensOut
                if let m = u.model { s.model = m }
                s.transcriptChanged = u.modified
                if u.interrupted == true && s.activity == .work {
                    s.activity = .sleep
                }
            }
            self.scheduleSave()
            self.onChange?()
        }
    }

    // MARK: Persistence

    func load() {
        account.load()
        guard let data = try? Data(contentsOf: Self.fileURL),
              let records = try? JSONDecoder().decode([Session.Record].self, from: data) else { return }
        for r in records {
            let s = Session(record: r)
            // After a restart nothing is mid-turn as far as we know.
            if s.activity == .wait { s.activity = .sleep }
            if s.isAlive() { sessions[s.id] = s }
        }
        pollTranscripts()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let records = self.sessions.values.map(\.record)
            if let data = try? JSONEncoder().encode(records) {
                try? data.write(to: Self.fileURL, options: .atomic)
            }
        }
    }
}
