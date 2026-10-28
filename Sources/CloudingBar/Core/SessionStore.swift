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
            // The first message of a chat, for its short name (not a /command).
            if event == "UserPromptSubmit", session.firstPrompt == nil, m.agentId == nil,
               let prompt = (m.raw["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty, !prompt.hasPrefix("/") {
                session.firstPrompt = String(prompt.prefix(600))
                session.firstPromptAt = now
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

    /// Cowork tasks and claude.ai chats as claude.ai lists them: each one
    /// that runs, waits for you or was active in the last half hour is a
    /// session of its own, known by its chat in Claude Desktop. One the
    /// list no longer has, or has archived, is gone at once.
    func apply(claudeAI chats: [ClaudeAIChats.Chat], now: Date = Date()) {
        var changed = false
        // Left to `prune`, which also drops what was asked in them. An empty
        // list (or one not read right) takes nothing away (review, 28.10).
        let listed = Set(chats.filter { !$0.archived }.map(ClaudeAIChats.sessionId))
        for s in sessions.values where s.fromClaudeAI && !listed.contains(s.id) && !chats.isEmpty {
            s.lastEvent = .distantPast
            changed = true
        }
        for chat in chats where !chat.archived {
            let id = ClaudeAIChats.sessionId(chat)
            let active = min(chat.lastActive ?? .distantPast, now)
            guard chat.running || chat.needsInput != nil || now.timeIntervalSince(active) < ClaudeAIChats.recent else { continue }
            let session = sessions[id] ?? newSession(id, now: active)
            sessions[id] = session
            session.entrypoint = chat.isCowork ? "cowork" : "claude-ai"
            session.cwd = chat.isCowork ? "/Cowork" : "/claude.ai"
            session.title = chat.name ?? session.title
            if let model = chat.model { session.model = model }
            if session.desktopChat != chat.page { link(session, desktopChat: chat.page, title: nil) }
            // Working or waiting is now, however long ago it began.
            session.lastEvent = max(session.lastEvent, chat.running || chat.needsInput != nil ? now : active)
            // Waiting for you, as with a hook's Notification: the turn isn't over.
            let activity: Activity = chat.running || chat.needsInput != nil ? .work : .sleep
            if session.activity != activity {
                session.activity = activity
                if activity == .work, let since = chat.runningSince { session.activitySince = min(since, now) }
                changed = true
            }
            if session.waitingNotice != (chat.needsInput != nil) {
                session.waitingNotice = chat.needsInput != nil
                changed = true
            }
        }
        if changed { scheduleSave() }
        onChange?()
    }

    /// Signed out of claude.ai: its chats aren't followed any more.
    func forgetClaudeAI() {
        let ids = sessions.values.filter(\.fromClaudeAI).map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { sessions[id] = nil }
        scheduleSave()
        onChange?()
    }

    /// A Cowork task's context, from its events.
    func apply(claudeAIContext c: ClaudeAIChats.Context, chat uuid: String) {
        guard let session = sessions["cowork-" + uuid] else { return }
        session.contextTokens = c.tokens
        if let model = c.model { session.model = model }
        session.contextWindowSize = Cowork.window(model: session.model)
        scheduleSave()
        onChange?()
    }

    /// A new session gets the first colour no live session has.
    private func newSession(_ id: String, now: Date) -> Session {
        let s = Session(id: id, now: now)
        s.shortName = SessionTitle.entry(id, base: Config.directory)?.name
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
        // A chat from claude.ai's list lives in Claude Desktop, never in this window.
        let ranked = windowTitle.map { Self.ranked(title: $0, in: candidates.filter { !$0.fromClaudeAI }, halves: true) } ?? []
        if let top = ranked.first {
            // The same name on two chats ("Review"): not told apart by it, so on to
            // the one picked or last seen, never the first found (review, 27.10).
            let best = ranked.filter { $0.score == top.score }.map(\.session)
            for id in sticky { if let s = best.first(where: { $0.id == id }) { return s } }
            return best.max { $0.lastSeen < $1.lastSeen }
        }
        for id in sticky { if let s = candidates.first(where: { $0.id == id }) { return s } }
        return candidates.max { $0.lastSeen < $1.lastSeen }
    }

    /// The Claude desktop app's chat its window shows: by the chat, else by
    /// its title — only among chats whose page isn't known: one known by its
    /// page is that page alone, so another chat of a like name shown there
    /// isn't taken for it (review, 28.10: a queued message went into it).
    func session(inDesktop shown: String?, chat: String? = nil) -> Session? {
        let inApp = alive.filter(\.inDesktopApp)
        if let chat, let s = inApp.first(where: { $0.desktopChat == chat }) { return s }
        guard let shown else { return nil }
        // The closest title; none when two are as close.
        let scored = inApp.filter { $0.desktopChat == nil }.map { s in
            (score: ([s.desktopTitle].compactMap { $0 } + s.windowTitles).map { Self.titleScore(shown, $0) }.max() ?? 0, session: s)
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
        if let tty {
            // A terminal tab in front that's no chat's we know (a shell,
            // Codex): none, whatever its title says (review, 27.10).
            return alive.first(where: { $0.tty == tty })
        }
        guard let title else { return nil }
        // A chat found only in Codex's files has no tab or process to tell
        // its window by: a folder's name alone matched a shell or an editor
        // there, and words went into it. Never in front.
        // Nor one from claude.ai's list: it lives in Claude Desktop.
        let ranked = Self.ranked(title: title, in: alive.filter { !$0.ambient && !$0.fromClaudeAI })
        guard let top = ranked.first else { return nil }
        // Short names made two chats' titles equal: words go only to the one chat
        // the title tells, at any score (review, 27.10).
        return ranked.filter { $0.score == top.score }.count == 1 ? top.session : nil
    }

    /// The window title's pieces, without what decorates them ("● ",
    /// a terminal's spinner, " (Workspace)").
    static func titleParts(_ title: String, halves: Bool = false) -> [String] {
        var pieces = [title]
        for separator in [" — ", " – ", " - "] {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        // Codex names its tab "<what it does> | <folder>" (owner, 27.10):
        // both halves too, the whole kept for a chat's title with a "|" —
        // only to follow a chat, never to type: the folder half made a
        // Claude chat of that folder "in front" of Codex's tab (review, 27.10).
        if halves { pieces += pieces.flatMap { p in p.contains(" | ") ? p.components(separatedBy: " | ") : [] } }
        return pieces.compactMap { piece in
            let t = String(piece.replacingOccurrences(of: " (Workspace)", with: "")
                .drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
    }

    /// Sessions the window shows, best first: 3 its chat's title, 2 its
    /// project's folder, 1 a parent folder of it.
    private static func ranked(title: String, in sessions: [Session], halves: Bool = false) -> [(score: Int, session: Session)] {
        let parts = titleParts(title, halves: halves)
        let set = Set(parts)
        let home = FileManager.default.homeDirectoryForCurrentUser.pathComponents
        func titled(_ t: String) -> Bool {
            parts.contains { p in p == t || (p.hasSuffix("…") && t.hasPrefix(String(p.dropLast()))) }
        }
        var list: [(score: Int, session: Session)] = []
        for session in sessions {
            var score = 0
            if session.windowTitles.contains(where: titled) {
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
        // A Codex closed in its terminal says nothing, and its file stays
        // fresh for up to an hour: gone once no Codex runs in its folder (28.10).
        // One running in a folder no chat has (`codex -C dir`, `codex resume`
        // from elsewhere) may be any chat's: then their files decide, as before (review, 28.10).
        var shut = Set<String>()
        let inTerminal = sessions.values.filter { $0.ambient && $0.entrypoint == "codex" && $0.codexHost == "Terminal" }
        if !inTerminal.isEmpty {
            let running = Set(codexTerminalFolders())
            let folders = Set(inTerminal.compactMap { $0.cwd.map(Tty.realPath) })
            if running.isSubset(of: folders) {
                shut = Set(inTerminal.filter { !($0.cwd.map { running.contains(Tty.realPath($0)) } ?? false) }.map(\.id))
            }
        }
        // A Claude in a terminal or VS Code runs one chat at a time: an older
        // one on its process (another chat opened in its tab, no SessionEnd) is gone (28.10).
        let oneChat = sessions.values.filter { ($0.entrypoint == "cli" || $0.entrypoint == "claude-vscode") && $0.claudePid != nil }
        var newest: [Int32: Session] = [:]
        for s in oneChat {
            let pid = s.claudePid!
            if let n = newest[pid], n.lastEvent >= s.lastEvent { continue }
            newest[pid] = s
        }
        for s in oneChat where newest[s.claudePid!] !== s { shut.insert(s.id) }
        let dead = sessions.values.filter { !$0.isAlive(now: now) || shut.contains($0.id) }.map(\.id)
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
        if let t = u.aiTitle { s.aiTitle = t }
        if let t = u.customTitle { s.customTitle = t }
        if let meta = u.codexMeta {
            s.codexHost = meta.host
            if s.cwd == nil { s.cwd = meta.cwd }
        }
        s.transcriptChanged = u.modified
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

    /// Codex's limits as its own server says them now (CodexServer): the
    /// same account and rules as the files' — the newest report wins,
    /// whichever way it came.
    func applyCodexServerLimits(_ l: CodexRollout.Limits) {
        if let w = l.fiveHour { codexAccount.apply(used: w.percent, resetsAt: w.resetsAt, reported: w.reported) }
        if let w = l.week { codexAccount.applyWeek(used: w.percent, resetsAt: w.resetsAt, reported: w.reported) }
        if let p = l.plan { codexAccount.setPlan(p) }
        onChange?()
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
            // Codex's names for its chats: the widget shows them, and a tab
            // is told by its own (two of one folder looked the same).
            var renamed = false
            for f in found {
                guard let name = f.name, let s = self.sessions[f.id], s.entrypoint == "codex", s.title != name else { continue }
                s.title = name
                renamed = true
            }
            self.markOpenCodexChats()
            if added || renamed { self.scheduleSave(); self.onChange?() }
            if added { self.pollTranscripts() }
        }
    }

    /// The folders a Codex program runs in, in a terminal (tests stand in for it).
    var codexFoldersOpen: (Set<String>) -> Set<String> = Tty.codexFolders
    /// Every Codex program's folder in a terminal, as the kernel gives it (tests stand in for it).
    var codexTerminalFolders: () -> [String] = Tty.codexTerminalFolders

    /// A Codex chat takes words from its server only while a Codex runs in
    /// its folder: closed, its chat stays loaded in Codex's server for up to
    /// half an hour, and what was sent would run with no window to answer
    /// its questions in (review, 27.10).
    func markOpenCodexChats() {
        let chats = alive.filter { $0.entrypoint == "codex" }
        guard !chats.isEmpty else { return }
        let open = codexFoldersOpen(Set(chats.compactMap(\.cwd)))
        for s in chats { s.codexWindowOpen = s.cwd.map(open.contains) ?? false }
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
        s.title = f.name
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
            s.shortName = SessionTitle.entry(r.id, base: Config.directory)?.name
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
