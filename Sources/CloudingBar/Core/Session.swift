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
    var claudePid: Int32? {
        didSet { if claudePid != oldValue { tty = claudePid.flatMap(Tty.of(pid:)) } }
    }
    /// Its terminal ("/dev/ttys003"): a terminal chat is told apart by it.
    private(set) var tty: String?
    /// "claude-vscode", "cli", … (CLAUDE_CODE_ENTRYPOINT)
    var entrypoint: String?
    var activity: Activity = .sleep {
        didSet { if activity != oldValue { activitySince = Date() } }
    }
    /// When the current activity began ("Working · 2 min").
    var activitySince = Date()
    /// A Notification said Claude is waiting for you.
    var waitingNotice = false
    var lastEvent: Date
    var transcriptChanged: Date?
    /// The chat's title ("Status bar"): the one you gave it, else Claude
    /// Code's. VS Code's tab and window and the terminal show the same.
    var title: String?
    /// Its colour in the widget (an index into `Session.colors`), so two
    /// chats of one project are told apart at a glance.
    var colorIndex = 0
    /// The last file Claude read or changed: where it really works when
    /// it was started in a parent folder (for the git branch).
    var workPath: String?
    /// The branches the hook read for `cwd` and `workPath`.
    var cwdBranch: String?
    var fileBranch: String?

    // Context: tokens from the transcript; window from the status line,
    // the config, or the model name.
    var model: String?
    var contextTokens: Int?
    var contextWindowSize: Int?
    var statusContextPercent: Double?
    /// "Later" on the context warning: stay quiet until this percent.
    var contextSnoozedUntil: Double?
    /// Session totals from the transcript (input includes cache writes).
    var tokensIn: Int?
    var tokensOut: Int?
    /// API cost so far, from the status line (terminal sessions only).
    var costUSD: Double?
    /// Reasoning effort (CLAUDE_EFFORT), e.g. "xhigh".
    var effort: String?
    /// Lines added and removed by Claude's edits in this session.
    var linesAdded = 0
    var linesRemoved = 0
    /// Subagents running right now (`trackAgents`).
    var agents: [RunningAgent] = []
    var runningAgents: Int { agents.count }

    /// "Opus 5.5 1M", from "claude-opus-5-5[1m]".
    var modelName: String? {
        guard let m = model, !m.isEmpty else { return nil }
        return Self.displayName(m)
    }

    /// "claude-opus-5-5[1m]" → "Opus 5.5 1M"; a date stamp is dropped.
    static func displayName(_ id: String) -> String {
        var m = id
        let big = m.contains("[1m]")
        m = m.replacingOccurrences(of: "[1m]", with: "").replacingOccurrences(of: "claude-", with: "")
        var words: [String] = []
        for part in m.split(separator: "-").map(String.init) {
            if let last = words.last, Int(part) != nil, part.count <= 2, last.first?.isNumber == true, !last.contains(".") {
                words[words.count - 1] = last + "." + part  // 5-5 → 5.5
            } else if part.count >= 8, Int(part) != nil {
                continue // a date stamp
            } else {
                words.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        return words.joined(separator: " ") + (big ? " 1M" : "")
    }

    init(id: String, now: Date = Date()) {
        self.id = id
        self.lastEvent = now
    }

    var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// What the widget calls it: its title, else its project.
    var displayName: String { title ?? projectName ?? "Claude" }

    /// Distinct on the dark widget, none of them the orange of "needs you".
    static let colors: [UInt32] = [0x0A84FF, 0xBF5AF2, 0x40C8E0, 0x30D158, 0xFF6EB4, 0xFFD60A, 0x7D7AFF, 0x63E6BE]

    /// "Code: main": where it works, from the folder it started in or the
    /// file it touched last.
    /// Read live where macOS doesn't ask, else as the hook last read it.
    var branch: String? {
        if let cwd, Git.readable(cwd), let b = Git.branch(at: cwd) { return b }
        if let b = cwdBranch { return b }
        guard let path = workPath else { return nil }
        if Git.readable(path) { return Git.branch(at: (path as NSString).deletingLastPathComponent) }
        return fileBranch
    }

    var lastSeen: Date { max(lastEvent, transcriptChanged ?? .distantPast) }

    func contextPercent(windowOverride: Int?) -> Double? {
        guard let tokens = contextTokens else { return statusContextPercent }
        return min(100, Double(tokens) / Double(contextWindow(override: windowOverride)) * 100)
    }

    /// The model's context window, in tokens.
    func contextWindow(override: Int?) -> Int {
        var window = contextWindowSize ?? override
            ?? ((model?.contains("[1m]") ?? false) ? 1_000_000 : 200_000)
        if let tokens = contextTokens, tokens > window { window = max(window, 1_000_000) }
        return window
    }

    /// Alive while its Claude process runs. Without a pid, a session that
    /// has been silent for 12 hours counts as gone.
    func isAlive(now: Date = Date()) -> Bool {
        if let pid = claudePid, pid > 1 {
            return kill(pid, 0) == 0 || errno == EPERM
        }
        // Cowork reports only now and then; without news for 3 hours it's over.
        return now.timeIntervalSince(lastSeen) < (entrypoint == "cowork" ? 3 : 12) * 3600
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
        var title: String?
        var colorIndex: Int?
        var workPath: String?
    }

    var record: Record {
        Record(id: id, cwd: cwd, transcriptPath: transcriptPath, claudePid: claudePid,
               entrypoint: entrypoint, activity: activity, lastEvent: lastEvent, model: model,
               contextTokens: contextTokens, contextWindowSize: contextWindowSize,
               statusContextPercent: statusContextPercent, title: title, colorIndex: colorIndex, workPath: workPath)
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
        title = r.title
        colorIndex = r.colorIndex ?? 0
        workPath = r.workPath
    }
}

/// The 5-hour limit. Account-wide, so the newest report from any session
/// wins. Kept in last-status.json so the bar isn't empty after a restart.
final class Account {
    var sessionPercent: Double?
    var resetsAt: Date?
    /// The weekly (7-day) limit, when the plan has one.
    var weekPercent: Double?
    var weekResetsAt: Date?
    /// When the limit was last reported ("Session · 2 h ago").
    var updatedAt: Date?

    /// Claude's (last-status.json) or Codex's (last-status-codex.json).
    private let fileName: String
    /// Claude's limit is kept over time for Stats.
    private let keepsHistory: Bool
    private var fileURL: URL { Config.directory.appendingPathComponent(fileName) }

    init(fileName: String = "last-status.json", keepsHistory: Bool = true) {
        self.fileName = fileName
        self.keepsHistory = keepsHistory
    }

    private struct Snapshot: Codable {
        var sessionPercent: Double?
        var sessionResetsAt: Date?
        var updatedAt: Date?
        var weekPercent: Double?
        var weekResetsAt: Date?
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        sessionPercent = snap.sessionPercent
        resetsAt = snap.sessionResetsAt
        updatedAt = snap.updatedAt
        weekPercent = snap.weekPercent
        weekResetsAt = snap.weekResetsAt
        expireIfNeeded()
    }

    private func save() {
        let snap = Snapshot(sessionPercent: sessionPercent, sessionResetsAt: resetsAt, updatedAt: updatedAt,
                            weekPercent: weekPercent, weekResetsAt: weekResetsAt)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func apply(used: Double?, resetsAt reset: Double?) {
        if let used { sessionPercent = used }
        if let reset { resetsAt = Date(timeIntervalSince1970: reset) }
        updatedAt = Date()
        save()
        if let used, keepsHistory { LimitHistory.record(used) }
    }

    func applyWeek(used: Double?, resetsAt reset: Double?) {
        if let used { weekPercent = used }
        if let reset { weekResetsAt = Date(timeIntervalSince1970: reset) }
        save()
    }

    /// Once a window has reset, the old number means nothing.
    @discardableResult
    func expireIfNeeded(now: Date = Date()) -> Bool {
        var changed = false
        if let w = weekResetsAt, w <= now {
            weekPercent = 0
            weekResetsAt = nil
            changed = true
        }
        if let r = resetsAt, r <= now {
            sessionPercent = 0
            resetsAt = nil
            changed = true
        }
        if changed { save() }
        return changed
    }

    /// When the weekly limit resets: "Thu 14:00".
    var weekResetLong: String? {
        guard let r = weekResetsAt else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = Calendar.current.isDateInToday(r) ? "'today' HH:mm" : "EEE HH:mm"
        return f.string(from: r)
    }

    /// "1 h 23 min" until the window resets.
    var resetLong: String? {
        guard let r = resetsAt else { return nil }
        let minutes = max(0, Int(r.timeIntervalSinceNow) / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// "1:23" (hours:minutes) until the window resets.
    var resetCountdown: String? {
        guard let r = resetsAt else { return nil }
        let seconds = max(0, Int(r.timeIntervalSinceNow))
        return String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }
}

/// A subagent at work: what it was asked (the main thread's Agent call)
/// and what it's doing now (the hooks it fires itself).
struct RunningAgent: Equatable {
    /// The Agent tool call that started it, if it was seen.
    var toolUseId: String?
    /// Its own id, from SubagentStart or its first hook.
    var agentId: String?
    /// "Explore", "general-purpose", …
    var type: String
    /// The call's short description ("Find the hook code").
    var task: String?
    /// Runs on after the call returns, until SubagentStop.
    var background = false
    var started: Date
    /// Its latest tool: "Read · Session.swift".
    var doing: String?
}

extension Session {
    /// Keeps `agents` up to date from one hook event:
    ///   Agent call (main thread)   PreToolUse adds it; PostToolUse removes it,
    ///                              unless it runs in the background
    ///   SubagentStart / its hooks  give it its id and what it's doing
    ///   SubagentStop               removes it
    ///   Stop                       ends what the turn started in the foreground
    func trackAgents(_ m: Inbound, now: Date) {
        let agentTool = m.toolName == "Agent" || m.toolName == "Task"
        let event = m.event ?? ""
        if agentTool && m.agentId == nil && event == "PreToolUse" {
            let input = m.toolInput
            agents.append(RunningAgent(toolUseId: m.toolUseId,
                                       type: input["subagent_type"] as? String ?? "general-purpose",
                                       task: input["description"] as? String,
                                       background: input["run_in_background"] as? Bool ?? false,
                                       started: now))
        } else if agentTool && m.agentId == nil && (event == "PostToolUse" || event == "PostToolUseFailure") {
            if let i = agents.firstIndex(where: { $0.toolUseId != nil && $0.toolUseId == m.toolUseId }) {
                if agents[i].background && event == "PostToolUse" {
                    // Launched: it works on until SubagentStop.
                    if agents[i].agentId == nil { agents[i].agentId = Self.launchedId(m.toolResponse) }
                } else {
                    agents.remove(at: i)
                }
            } else if let i = agents.firstIndex(where: { !$0.background }) {
                agents.remove(at: i) // no id to go by: the oldest in the foreground
            }
        } else if event == "SubagentStart", let id = m.agentId {
            attach(id, type: m.agentType, now: now)
        } else if event == "SubagentStop", let id = m.agentId {
            agents.removeAll { $0.agentId == id }
        } else if event == "Stop" {
            agents.removeAll { !$0.background }
        } else if event == "SessionStart" {
            agents.removeAll()
        } else if event == "PreToolUse", let id = m.agentId, let tool = m.toolName {
            let i = attach(id, type: m.agentType, now: now)
            agents[i].doing = Self.summary(tool, m.toolInput)
        }
        // Background ones whose end never came (SubagentStop not hooked up).
        agents.removeAll { $0.background && now.timeIntervalSince($0.started) > 3 * 3600 }
    }

    /// The agent with this id, else the oldest unclaimed call of its type,
    /// else a new one (started before we were watching).
    @discardableResult
    private func attach(_ id: String, type: String?, now: Date) -> Int {
        if let i = agents.firstIndex(where: { $0.agentId == id }) { return i }
        if let i = agents.firstIndex(where: { $0.agentId == nil && (type == nil || $0.type == type) }) {
            agents[i].agentId = id
            return i
        }
        agents.append(RunningAgent(agentId: id, type: type ?? "agent", started: now))
        return agents.count - 1
    }

    /// A background agent's id from the Agent call's result ("agentId: …").
    static func launchedId(_ response: Any?) -> String? {
        if let d = response as? [String: Any], let id = (d["agentId"] ?? d["agent_id"]) as? String { return id }
        let text = String(describing: response ?? "")
        guard let re = try? NSRegularExpression(pattern: "agent_?[iI]d[\"':= ]+([A-Za-z0-9_-]{4,})"),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// A tool call in a few words: "Read · Session.swift", "Bash · make test".
    static func summary(_ tool: String, _ input: [String: Any]) -> String {
        func line(_ s: String) -> String {
            String(s.split(separator: "\n", omittingEmptySubsequences: true).first ?? "").prefix(48).description
        }
        var detail: String?
        if let path = (input["file_path"] ?? input["notebook_path"]) as? String {
            detail = (path as NSString).lastPathComponent
        } else if let url = input["url"] as? String {
            detail = URL(string: url)?.host
        } else if let text = ["pattern", "command", "query", "description"].lazy.compactMap({ input[$0] as? String }).first {
            detail = line(text)
        }
        guard let detail, !detail.isEmpty else { return tool }
        return tool + " · " + detail
    }
}
