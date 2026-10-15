import Foundation

// Checks for the core (no UI): which session a window title picks, what the
// bar sends back to Claude, and config defaults. `make test`.
// Never touch the real ~/.claudebar.
guard ProcessInfo.processInfo.environment["CLAUDEBAR_DIR"] != nil else {
    print("run through `make test` (it sets CLAUDEBAR_DIR)")
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

// MARK: Config

let config = Config()
check(config.effectiveButtons.map(\.label) == ["caveman", "compact", "office"], "default buttons")
check(config.questionHoldSeconds == 15, "question hold defaults to 15 s")
check(config.contextWarnPercent == 80, "context warning at 80%")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
