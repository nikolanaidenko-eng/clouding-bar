import Foundation

// Checks for the core (no UI): which session a window title picks, what the
// bar sends back to Claude, and config defaults. `make test`.
// Never touch the real ~/.cloudingbar.
guard ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"] != nil else {
    print("run through `make test` (it sets CLOUDINGBAR_DIR)")
    exit(2)
}
var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    print(ok ? "ok   \(what)" : "FAIL \(what) (line \(line))")
    if !ok { failures += 1 }
}

// MARK: Active session by window title

let store = SessionStore()
func event(_ id: String, _ cwd: String, _ name: String = "UserPromptSubmit") {
    store.apply(Inbound(raw: ["hook_event_name": name, "session_id": id, "cwd": cwd]))
}
event("a", "/Users/me/Documents/GitHub")
event("b", "/Users/me/claudebar")
event("c", "/Users/me/claudebar/Sources") // newest

check(store.activeSession(windowTitle: "Makefile — claudebar — Visual Studio Code")?.id == "b",
      "title with the project folder picks that session")
check(store.activeSession(windowTitle: "README.md — GitHub — Visual Studio Code")?.id == "a",
      "another window picks the other session")
check(store.activeSession(windowTitle: "Sources — Visual Studio Code")?.id == "c",
      "exact last folder beats a parent folder")
check(store.activeSession(windowTitle: "notes.txt - Untitled (Workspace) - Visual Studio Code")?.id == "c",
      "no match falls back to the latest session")
check(store.activeSession(windowTitle: nil)?.id == "c", "no title falls back to the latest session")
check(store.activeSession(windowTitle: "● main.swift — claudebar (Workspace) — Visual Studio Code")?.id == "b",
      "dirty marker and (Workspace) suffix don't get in the way")

event("c", "/Users/me/claudebar/Sources", "SessionEnd")
check(store.activeSession(windowTitle: "Sources — Visual Studio Code")?.id == "b",
      "an ended session is gone; the parent-folder session matches")

// Activity
event("b", "/Users/me/claudebar", "Stop")
check(store.sessions["b"]?.activity == .sleep, "Stop → sleep")
event("b", "/Users/me/claudebar", "UserPromptSubmit")
check(store.sessions["b"]?.activity == .work, "UserPromptSubmit → work")
store.apply(Inbound(raw: ["hook_event_name": "Notification", "session_id": "b", "notification_type": "permission_prompt"]))
check(store.sessions["b"]?.waitingNotice == true, "permission_prompt notification → waiting")
event("b", "/Users/me/claudebar", "PostToolUse")
check(store.sessions["b"]?.waitingNotice == false, "next tool clears waiting")

// Status messages add numbers but never create sessions
store.apply(Inbound(raw: ["session_id": "zzz", "rate_limits": ["five_hour": ["used_percentage": 52.0, "resets_at": Date().timeIntervalSince1970 + 3600]]]))
check(store.sessions["zzz"] == nil, "status message alone doesn't make a session")
check(store.account.sessionPercent == 52, "five_hour limit lands in the account")
check(store.account.resetCountdown == "0:59" || store.account.resetCountdown == "1:00", "countdown formats h:mm")

// Liveness by pid
let dead = Session(id: "d")
dead.claudePid = 99_999
check(!dead.isAlive(), "a session whose Claude process is gone is dead")
let mine = Session(id: "m")
mine.claudePid = getpid()
check(mine.isAlive(), "a session whose Claude process runs is alive")

// Context percent
let s = Session(id: "x")
s.contextTokens = 310_000
s.model = "claude-opus-5-5[1m]"
check(Int(s.contextPercent(windowOverride: nil) ?? 0) == 31, "[1m] model → 1M window")
s.model = "claude-sonnet-5-5"
s.contextTokens = 100_000
check(Int(s.contextPercent(windowOverride: nil) ?? 0) == 50, "plain model → 200k window")
s.contextWindowSize = 400_000
check(Int(s.contextPercent(windowOverride: nil) ?? 0) == 25, "status line window size wins")

// MARK: Hook output shapes (verified against Claude Code 2.1.296)

func json(_ o: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: o, options: .sortedKeys), encoding: .utf8)!
}
check(json(PendingRequest.allow()) == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#,
      "allow output")
check(json(PendingRequest.deny()).contains(#""behavior":"deny""#), "deny output")

// MARK: Stage 3 pieces

let named = Session(id: "n")
named.model = "claude-opus-5-5[1m]"
check(named.modelName == "Opus 5.5 1M", "model name: \(named.modelName ?? "nil")")
named.model = "claude-sonnet-4-5-20250929"
check(named.modelName == "Sonnet 4.5", "model name drops the date: \(named.modelName ?? "nil")")

let repo = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
check(Git.branch(at: repo.appendingPathComponent("Sources").path) == "clouding-bar",
      "git branch from .git/HEAD of a parent folder")
check(Git.branch(at: "/") == nil, "no repository, no branch")

check(ButtonSpec.guessType("/compact") == .command, "guess: slash command")
check(ButtonSpec.guessType("vscode://x/open") == .link, "guess: link")
check(ButtonSpec.guessType("cmd+k") == .key, "guess: shortcut")
check(ButtonSpec.guessType("Explain this") == .phrase, "guess: phrase")
check(HotKeys.carbon("ctrl+opt+c") != nil, "hotkey parses")
check(HotKeys.carbon("c") == nil, "a bare key is refused as a global shortcut")
check(HotKeys.display("ctrl+opt+c") == "⌃⌥C", "hotkey shows as ⌃⌥C")

let week = StatsBuilder.build()
check(week.days.count == 7 && week.grid.count == 7, "stats: a 7 × 24 week from local transcripts")
print("     (this week: \(week.headline); \(week.projects.map { "\($0.name) \(Int($0.share * 100))%" }.joined(separator: ", ")))")

// Cowork plugin: built into the test folder, its script run on a fake transcript.
let pluginDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!)
let zip = try? Cowork.makePlugin(mode: "thresholds", into: pluginDir)
check(zip.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "cowork plugin zip is made")
check(FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("clouding-bar-cowork/hooks/status.py").path),
      "cowork plugin has its hook script")

// MARK: Model and effort

check(ModelChoice.alias(of: "claude-opus-5-5[1m]") == "opus[1m]" && ModelChoice.alias(of: "claude-sonnet-5-5") == "sonnet",
      "model id → alias")
check(ModelChoice.modelSet(in: "<local-command-stdout>Set model to `claude-opus-5-5[1m]`</local-command-stdout>") == "claude-opus-5-5[1m]",
      "\"Set model to\" read from the transcript")
check(ModelChoice.modelSet(in: "Set model to \u{1B}[1mclaude-haiku-5-5\u{1B}[22m") == "claude-haiku-5-5", "…with colour codes")
check(ModelChoice.modelSet(in: "<local-command-stdout>Set model to `Opus 5.5 (1M context)` for this session only</local-command-stdout>")
      == "claude-opus-5-5[1m]", "…by name: Opus 5.5 (1M context)")
check(ModelChoice.modelSet(in: "Set model to `Opus 5.5` for this session only") == "claude-opus-5-5", "…by name: Opus 5.5")
check(ModelChoice.modelSet(in: "Set model to Sonnet") == "claude-sonnet", "…by name, no version")
check(ModelChoice.effortSet(in: "<local-command-stdout>Set effort level to high: thinks more</local-command-stdout>") == "high",
      "\"Set effort level to\" read")
check(ModelChoice.effortSet(in: "Set effort level to ultracode (this session only): xhigh + …") == "xhigh", "ultracode is xhigh")
do { // the watcher picks both up from a transcript
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!)
    let file = dir.appendingPathComponent("model-switch.jsonl")
    let lines = [
        #"{"type":"assistant","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":10,"output_tokens":5}}}"#,
        #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to `claude-opus-5-5[1m]`</local-command-stdout>"}}"#,
        #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set effort level to max: deepest</local-command-stdout>"}}"#,
    ]
    try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    let watcher = TranscriptWatcher()
    var got: [TranscriptWatcher.Update] = []
    let done = DispatchSemaphore(value: 0)
    watcher.poll([(id: "m", path: file.path)]) { got = $0; done.signal() }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(got.first?.model == "claude-opus-5-5[1m]" && got.first?.effort == "max", "watcher: /model and /effort switch the session")
}

// MARK: Subagents

do {
    let s = Session(id: "agents")
    func hook(_ raw: [String: Any]) { s.trackAgents(Inbound(raw: raw), now: Date()) }
    hook(["hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_use_id": "t1",
          "tool_input": ["subagent_type": "Explore", "description": "Find the hook code"]])
    hook(["hook_event_name": "PreToolUse", "tool_name": "Agent", "tool_use_id": "t2",
          "tool_input": ["description": "Long check", "run_in_background": true]])
    check(s.agents.map(\.type) == ["Explore", "general-purpose"] && s.agents[0].task == "Find the hook code", "agents: two calls")
    hook(["hook_event_name": "SubagentStart", "agent_id": "a1", "agent_type": "Explore"])
    hook(["hook_event_name": "PreToolUse", "agent_id": "a1", "agent_type": "Explore", "tool_name": "Read",
          "tool_input": ["file_path": "/x/Session.swift"]])
    check(s.agents[0].agentId == "a1" && s.agents[0].doing == "Read · Session.swift", "agents: what one is doing")
    hook(["hook_event_name": "PreToolUse", "agent_id": "a2", "agent_type": "general-purpose", "tool_name": "Bash",
          "tool_input": ["command": "make test\nmake install"]])
    check(s.agents[1].agentId == "a2" && s.agents[1].doing == "Bash · make test", "agents: the other one, by its hooks")
    hook(["hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_use_id": "t2",
          "tool_response": ["status": "async_launched", "agentId": "a2"]])
    check(s.agents.count == 2, "agents: a background one stays after its call returns")
    hook(["hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_use_id": "t1"])
    check(s.agents.map(\.agentId) == ["a2"], "agents: a foreground one ends with its call")
    hook(["hook_event_name": "Stop"])
    check(s.runningAgents == 1, "agents: Stop keeps the background one")
    hook(["hook_event_name": "SubagentStop", "agent_id": "a2", "agent_type": "general-purpose"])
    check(s.runningAgents == 0, "agents: SubagentStop ends it")
    check(Session.launchedId("Async agent launched successfully. agentId: abc123 (use it)") == "abc123", "agents: id from the launch text")
}

// MARK: Codex

do {
    var u = TranscriptWatcher.Update(sessionId: "c", modified: Date())
    let usage = #"{"timestamp":"2026-10-19T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":900000},"last_token_usage":{"total_tokens":54400},"model_context_window":272000},"rate_limits":{"primary":{"used_percent":37.5,"window_minutes":300,"resets_at":1800000000},"secondary":{"used_percent":12,"window_minutes":10080,"resets_at":1800500000}}}}"#
    let turn = #"{"timestamp":"2026-10-19T12:00:01Z","type":"turn_context","payload":{"model":"gpt-6-luna","effort":"high"}}"#
    TranscriptWatcher.scanCodex(Data(usage.utf8)[...], into: &u)
    TranscriptWatcher.scanCodex(Data(turn.utf8)[...], into: &u)
    check(u.contextTokens == 54400 && u.contextWindow == 272000, "codex: context from the latest reply, not the total")
    check(u.codexFiveHour?.percent == 37.5 && u.codexWeek?.percent == 12, "codex: its 5-hour and weekly limits, by window length")
    check(u.model == "gpt-6-luna" && u.effort == "high", "codex: model and effort from the turn")
    let req = Inbound(raw: ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "ls"],
                            "claude_entrypoint": "codex", "permission_suggestions": [["type": "addRules"]]])
    let pending = PendingRequest(req, responder: Responder())
    let always = pending?.always()["hookSpecificOutput"] as? [String: Any]
    check((always?["decision"] as? [String: Any])?["updatedPermissions"] == nil, "codex: Always is a plain allow (no remembered rules)")
    check(pending?.hostAnswersInParallel == false, "codex: Codex waits on the hook, so it's held briefly")
}

// MARK: Config

let config = Config()
check(config.effectiveButtons.map(\.label) == ["summary", "compact"], "default buttons")
check(config.questionHoldSeconds == 15, "question hold defaults to 15 s")
check(config.contextWarnPercent == 80, "context warning at 80%")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
