import Foundation

/// The model the UI reads: every live Claude Code session plus the account
/// limit. Fed by socket messages and the transcripts. Main queue only.
final class SessionStore {
    private(set) var sessions: [String: Session] = [:]
    let account = Account()
    /// Codex's limits, from its rollouts: a different account from Claude's.
    let codexAccount = Account(fileName: "last-status-codex.json", keepsHistory: false)
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
        if let week = m.sevenDay {
            account.applyWeek(used: week.used, resetsAt: week.resetsAt)
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
        // line, cloudingbar-tap) just add numbers to one we already know.
        guard let session = sessions[id] ?? (m.event != nil ? newSession(id, now: now) : nil) else {
            onChange?()
            return
        }
        sessions[id] = session
        if let cwd = m.cwd { session.cwd = cwd }
        if m.event != nil, m.cwd != nil { session.cwdBranch = m.gitBranch }
        if let path = m.transcriptPath { session.transcriptPath = path }
        if let pid = m.claudePid { session.claudePid = pid }
        if let entry = m.entrypoint { session.entrypoint = entry }
        if let p = m.contextUsedPercent { session.statusContextPercent = p }
        if let size = m.contextWindowSize { session.contextWindowSize = size }
        if let model = m.modelId { session.model = model }
        if let cost = m.costUSD { session.costUSD = cost }
        if let effort = m.effort { session.effort = effort }
        // The file it reads or changes: where it works (the main thread only).
        if m.agentId == nil, let path = (m.toolInput["file_path"] ?? m.toolInput["notebook_path"]) as? String,
           path.hasPrefix("/") {
            session.workPath = path
            session.fileBranch = m.fileBranch
        }

        if let event = m.event {
            session.lastEvent = now
            // Subagents: the Agent (formerly Task) tool runs one.
            let agentsBefore = session.agents.map(\.type)
            session.trackAgents(m, now: now)
            if session.agents.map(\.type) != agentsBefore {
                DebugLog.note("subagents in \(session.projectName ?? id): \(session.agents.map(\.type)) (after \(event))")
            }
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

    /// A status line from the Cowork plugin: a session of its own, with the
    /// context numbers the plugin worked out.
    func apply(cowork s: Cowork.Status) {
        let id = "cowork-" + s.session
        let session = sessions[id] ?? newSession(id, now: s.time)
        sessions[id] = session
        session.cwd = "/" + (s.project ?? "Cowork")
        session.entrypoint = "cowork"
        session.contextTokens = s.contextTokens
        session.contextWindowSize = s.contextWindow
        session.model = s.model
        if let title = s.title { session.title = title }
        session.lastEvent = s.time
        session.activity = s.working ? .work : .sleep
        scheduleSave()
        onChange?()
    }

    /// A new session gets the first colour no live session has.
    private func newSession(_ id: String, now: Date) -> Session {
        let s = Session(id: id, now: now)
        let used = alive.map(\.colorIndex)
        s.colorIndex = Session.colors.indices.min { a, b in
            let ua = used.filter { $0 == a }.count, ub = used.filter { $0 == b }.count
            return ua != ub ? ua < ub : a < b
        } ?? 0
        return s
    }

    // MARK: Queries

    var alive: [Session] {
        let now = Date()
        return sessions.values.filter { $0.isAlive(now: now) }
    }

    /// The session the widget and the bar follow:
    ///  - the chat the window in front shows by its title ("Status bar —
    ///    GitHub — Visual Studio Code": VS Code's tab and the terminal carry it);
    ///  - else, of that window's project, the one in `sticky` (picked in the
    ///    widget, or followed before), else the latest active;
    ///  - no session's window in front: the one in `sticky`, else the latest active.
    /// A terminal tab in front (`tty`) names its chat outright.
    /// The Claude desktop app in front (`desktop`): its window doesn't say
    /// which chat it shows, so one of its own (Cowork, Code): the one in
    /// `sticky`, else the latest.
    func focus(windowTitle: String?, tty: String? = nil, sticky: [String], desktop: Bool = false) -> Session? {
        let inApp = desktop ? alive.filter { $0.entrypoint == "cowork" || $0.entrypoint == "claude-desktop" } : []
        if !inApp.isEmpty {
            for id in sticky { if let s = inApp.first(where: { $0.id == id }) { return s } }
            return inApp.max { $0.lastSeen < $1.lastSeen }
        }
        let candidates = alive
        if let tty, let s = candidates.first(where: { $0.tty == tty }) { return s }
        let ranked = windowTitle.map { Self.ranked(title: $0, in: candidates) } ?? []
        if let top = ranked.first {
            if top.score == 3 { return top.session }
            let best = ranked.filter { $0.score == top.score }.map(\.session)
            for id in sticky { if let s = best.first(where: { $0.id == id }) { return s } }
            return best.max { $0.lastSeen < $1.lastSeen }
        }
        for id in sticky { if let s = candidates.first(where: { $0.id == id }) { return s } }
        return candidates.max { $0.lastSeen < $1.lastSeen }
    }

    /// The session whose chat the window in front surely shows: by its
    /// title, or the only one of that project. Nil when it can't be told
    /// (two chats of one project, the window on a file): typing there
    /// could land anywhere.
    func session(inWindow title: String?, tty: String? = nil) -> Session? {
        if let tty, let s = alive.first(where: { $0.tty == tty }) { return s }
        guard let title else { return nil }
        let ranked = Self.ranked(title: title, in: alive)
        guard let top = ranked.first else { return nil }
        if top.score == 3 { return top.session }
        return ranked.filter { $0.score == top.score }.count == 1 ? top.session : nil
    }

    /// The window title's pieces, without what decorates them ("● ",
    /// a terminal's spinner, " (Workspace)").
    static func titleParts(_ title: String) -> [String] {
        var pieces = [title]
        for separator in [" — ", " – ", " - "] {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        return pieces.compactMap { piece in
            let t = String(piece.replacingOccurrences(of: " (Workspace)", with: "")
                .drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
    }

    /// Sessions the window shows, best first: 3 its chat's title, 2 its
    /// project's folder, 1 a parent folder of it.
    private static func ranked(title: String, in sessions: [Session]) -> [(score: Int, session: Session)] {
        let parts = titleParts(title)
        let set = Set(parts)
        let home = FileManager.default.homeDirectoryForCurrentUser.pathComponents
        func titled(_ t: String) -> Bool {
            parts.contains { p in p == t || (p.hasSuffix("…") && t.hasPrefix(String(p.dropLast()))) }
        }
        var list: [(score: Int, session: Session)] = []
        for session in sessions {
            var score = 0
            if let t = session.title, titled(t) {
                score = 3
            } else if let cwd = session.cwd {
                let components = URL(fileURLWithPath: cwd).pathComponents
                if let last = components.last, set.contains(last) {
                    score = 2
                } else if components.dropFirst(home.count).contains(where: set.contains) {
                    score = 1 // the window shows a parent folder of the session
                }
            }
            if score > 0 { list.append((score, session)) }
        }
        return list.sorted { $0.score != $1.score ? $0.score > $1.score : $0.session.lastSeen > $1.session.lastSeen }
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
                s.linesAdded = u.linesAdded
                s.linesRemoved = u.linesRemoved
                if let m = u.model { s.model = m }
                if let e = u.effort { s.effort = e }
                if let w = u.contextWindow { s.contextWindowSize = w }
                if let t = u.title { s.title = t }
                if let l = u.codexFiveHour { self.codexAccount.apply(used: l.percent, resetsAt: l.resetsAt) }
                if let l = u.codexWeek { self.codexAccount.applyWeek(used: l.percent, resetsAt: l.resetsAt) }
                s.transcriptChanged = u.modified
                if u.interrupted == true && s.activity == .work {
                    s.activity = .sleep
                    s.agents.removeAll { !$0.background }
                }
            }
            self.scheduleSave()
            self.onChange?()
        }
    }

    // MARK: Persistence

    func load() {
        account.load()
        codexAccount.load()
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
