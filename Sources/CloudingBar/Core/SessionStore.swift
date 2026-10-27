import Foundation

/// The model the UI reads: every live Claude Code session plus the account
/// limit. Fed by socket messages and the transcripts. Main queue only.
final class SessionStore {
    private(set) var sessions: [String: Session] = [:]
    let account = Account()
    /// Codex's limits, from its rollouts: a different account from Claude's.
    let codexAccount = Account(fileName: "last-status-codex.json", keepsHistory: false)
    private let transcripts = TranscriptWatcher()
    /// Codex's own files, read without any hook (CodexRollouts): the freshest
    /// give its limits whether a chat is known or not.
    private let rollouts = CodexRollouts()
    private let limitWatcher = TranscriptWatcher()
    /// Chats whose SessionEnd came, so their still-fresh file doesn't bring them back.
    private var ended: [String: Date] = [:]
    private var saveScheduled = false

    /// Fires after anything changed.
    var onChange: (() -> Void)?
    /// Claude put ☁️ in a reply (MascotView's note): Cloud waves back.
    var onCloudWave: (() -> Void)?

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
            ended[id] = now
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
        if let pid = m.claudePid { session.claudePid = pid; session.ambient = false }
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
            case "SessionStart", "Stop", "Interrupt", "StopFailure":
                // Interrupt is Codex's: you stopped a turn, and no Stop follows.
                // StopFailure: a turn that ended on an API error.
                session.activity = .sleep
                session.waitingNotice = false
            case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
                session.activity = .work
                // Codex has no Notification: its PermissionRequest says it's asking
                // (below), and only the tool's end, Stop, Interrupt or a new prompt
                // say it's over (owner, 26.10); another call's start doesn't.
                if !(event == "PreToolUse" && session.entrypoint == "codex") { session.waitingNotice = false }
            case "PermissionRequest":
                if session.entrypoint == "codex" { session.waitingNotice = true }
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
        session.contextWindowSize = Cowork.window(model: s.model)
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
    func focus(windowTitle: String?, tty: String? = nil, sticky: [String], desktop: Bool = false,
               desktopChat: String? = nil) -> Session? {
        let inApp = desktop ? alive.filter(\.inDesktopApp) : []
        if !inApp.isEmpty {
            if let s = session(inDesktop: windowTitle, chat: desktopChat) { return s }
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

    /// The Claude desktop app's chat its window shows: by the chat, else by
    /// its title.
    func session(inDesktop shown: String?, chat: String? = nil) -> Session? {
        let inApp = alive.filter(\.inDesktopApp)
        if let chat, let s = inApp.first(where: { $0.desktopChat == chat }) { return s }
        guard let shown else { return nil }
        // The closest title; none when two are as close.
        let scored = inApp.map { s in
            (score: [s.desktopTitle, s.title].compactMap { $0 }.map { Self.titleScore(shown, $0) }.max() ?? 0, session: s)
        }.filter { $0.score > 0 }.sorted { $0.score > $1.score }
        guard let top = scored.first, scored.filter({ $0.score == top.score }).count == 1 else { return nil }
        return top.session
    }

    /// This session is that chat of the Claude desktop app (and no other
    /// session is).
    func link(_ session: Session, desktopChat chat: String, title: String?) {
        for other in sessions.values where other !== session && other.desktopChat == chat {
            other.desktopChat = nil
            other.desktopTitle = nil
        }
        session.desktopChat = chat
        if let title { session.desktopTitle = String(title.drop { !$0.isLetter && !$0.isNumber }) }
        scheduleSave()
        onChange?()
    }

    /// Two titles of one chat: the same but for case and an emoji before
    /// it, or one the start of the other (cut short with "…", or Claude
    /// Desktop's "Cowork task summary" for "Cowork task summary export").
    static func sameTitle(_ a: String, _ b: String) -> Bool { titleScore(a, b) >= 2 }

    /// 3 the same, 2 one starts the other, 1 mostly the same words, 0 not.
    static func titleScore(_ a: String, _ b: String) -> Int {
        func bare(_ s: String) -> String {
            String(s.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces).lowercased()
        }
        let a = bare(a), b = bare(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 3 }
        if b.hasSuffix("…"), a.hasPrefix(String(b.dropLast())) { return 2 }
        if a.hasSuffix("…"), b.hasPrefix(String(a.dropLast())) { return 2 }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        if short.split(separator: " ").count >= 2, long.hasPrefix(short + " ") { return 2 }
        let words = { (s: String) in Set(s.split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
        let wa = words(a), wb = words(b)
        let common = wa.intersection(wb).count
        return common >= 2 && Double(common) / Double(wa.union(wb).count) >= 0.6 ? 1 : 0
    }

    /// The session whose chat the window in front surely shows: by its
    /// title, or the only one of that project. Nil when it can't be told
    /// (two chats of one project, the window on a file): typing there
    /// could land anywhere.
    func session(inWindow title: String?, tty: String? = nil) -> Session? {
        if let tty, let s = alive.first(where: { $0.tty == tty }) { return s }
        guard let title else { return nil }
        // A chat found only in Codex's files has no tab or process to tell
        // its window by: a folder's name alone matched a shell or an editor
        // there, and words went into it. Never in front.
        let ranked = Self.ranked(title: title, in: alive.filter { !$0.ambient })
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
        ended = ended.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
        let dead = sessions.values.filter { !$0.isAlive(now: now) }.map(\.id)
        guard !dead.isEmpty else { return [] }
        for id in dead {
            // A Codex chat closed with no SessionEnd: its file, still fresh,
            // would bring it back as found in the files.
            if sessions[id]?.entrypoint == "codex" { ended[id] = now }
            sessions[id] = nil
        }
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
                self.applyCodexLimits(u)
                guard let s = self.sessions[u.sessionId] else { continue }
                self.apply(u, to: s)
            }
            self.scheduleSave()
            self.onChange?()
        }
    }

    private func apply(_ u: TranscriptWatcher.Update, to s: Session) {
        if let t = u.contextTokens { s.contextTokens = t }
        s.tokensIn = u.tokensIn
        s.tokensOut = u.tokensOut
        s.linesAdded = u.linesAdded
        s.linesRemoved = u.linesRemoved
        if let m = u.model { s.model = m }
        if let e = u.effort { s.effort = e }
        if let w = u.contextWindow { s.contextWindowSize = w }
        if let t = u.title { s.title = t }
        if let meta = u.codexMeta {
            s.codexHost = meta.host
            if s.cwd == nil { s.cwd = meta.cwd }
        }
        s.transcriptChanged = u.modified
        if u.waved { onCloudWave?() }
        // Interrupted: Claude's permission menu, if any, is gone.
        if u.interrupted == true { s.waitingNotice = false }
        if u.interrupted == true && s.activity == .work {
            s.activity = .sleep
            s.agents.removeAll { !$0.background }
        }
        // Codex's turns: what its file says, unless a hook has said more since
        // (a Stop comes before the file's task_complete; the older line changes nothing).
        if let t = u.codexTurn, t.at > s.activitySince, Date().timeIntervalSince(t.at) < CodexRollouts.freshness {
            switch t.state {
            case .started:
                if s.activity != .work { s.activity = .work; s.activitySince = t.at }
            case .done, .aborted:
                s.waitingNotice = false
                if s.activity == .work {
                    s.activity = .sleep
                    s.finishedAt = t.at
                    s.agents.removeAll { !$0.background }
                }
            }
        }
    }

    /// Codex's limits are the account's, whichever chat's file they were read
    /// from: the newest report wins.
    private func applyCodexLimits(_ u: TranscriptWatcher.Update) {
        if let l = u.codexFiveHour { codexAccount.apply(used: l.percent, resetsAt: l.resetsAt, reported: l.reported) }
        if let l = u.codexWeek { codexAccount.applyWeek(used: l.percent, resetsAt: l.resetsAt, reported: l.reported) }
        if let p = u.codexPlan { codexAccount.setPlan(p) }
    }

    // MARK: Codex without hooks

    /// Looks at Codex's newest session files (every few seconds from the
    /// app): their limits go to `codexAccount`, and a chat of a person that
    /// is at work there and that no hook has spoken for is added, marked
    /// `ambient` (no permissions to answer, no process to watch). Nothing
    /// is shown for a Mac without Codex.
    func pollCodexRollouts(now: Date = Date()) {
        rollouts.scan(now: now) { [weak self] found in
            guard let self else { return }
            // Subagents' files too: the limits are the account's, and they may be the newest.
            let probes = found.prefix(4).map { (id: "codex-file:" + $0.path, path: $0.path) }
            if !probes.isEmpty {
                self.limitWatcher.poll(probes) { [weak self] updates in
                    guard let self else { return }
                    updates.forEach(self.applyCodexLimits)
                    self.onChange?()
                }
            }
            var added = false
            for f in found where !f.archived { added = self.adopt(f, now: now) || added }
            if added { self.scheduleSave(); self.onChange?(); self.pollTranscripts() }
        }
    }

    private func adopt(_ f: CodexRollouts.Found, now: Date) -> Bool {
        guard let meta = f.meta, meta.interactive,
              sessions[f.id] == nil, !sessions.values.contains(where: { $0.transcriptPath == f.path }),
              now.timeIntervalSince(f.modified) < CodexRollouts.freshness / 4 else { return false }
        if let end = ended[f.id], f.modified <= end.addingTimeInterval(30) { return false }
        let s = newSession(f.id, now: f.modified)
        s.entrypoint = "codex"
        s.ambient = true
        s.cwd = meta.cwd
        s.cwdBranch = meta.branch
        s.codexHost = meta.host
        s.transcriptPath = f.path
        s.transcriptChanged = f.modified
        s.activitySince = .distantPast // what its file says about the turn counts
        sessions[f.id] = s
        return true
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
