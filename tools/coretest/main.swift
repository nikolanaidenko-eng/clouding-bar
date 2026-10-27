import Foundation

// Checks for the core (no UI): which session a window title picks, what the
// bar sends back to Claude, and config defaults. `make test`.
// Never touch the real ~/.cloudingbar.
guard ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"] != nil else {
    print("run through `make test` (it sets CLOUDINGBAR_DIR)")
    exit(2)
}
// Nothing here reads the real ~/.codex either.
if ProcessInfo.processInfo.environment["CLOUDINGBAR_CODEX_HOME"] == nil {
    setenv("CLOUDINGBAR_CODEX_HOME", ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]! + "/no-codex", 1)
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

func focus(_ title: String?, _ sticky: [String] = []) -> String? { store.focus(windowTitle: title, sticky: sticky)?.id }
check(focus("Makefile — claudebar — Visual Studio Code") == "b", "title with the project folder picks that session")
check(focus("README.md — GitHub — Visual Studio Code") == "a", "another window picks the other session")
check(focus("Sources — Visual Studio Code") == "c", "exact last folder beats a parent folder")
check(focus("notes.txt - Untitled (Workspace) - Visual Studio Code") == "c", "no match falls back to the latest session")
check(focus(nil) == "c", "no title falls back to the latest session")
check(focus(nil, ["a"]) == "a", "no title: the one followed before stays")
check(focus("notes.txt - Untitled (Workspace) - Visual Studio Code", ["b"]) == "b", "no match: the one followed before stays")
check(focus("● main.swift — claudebar (Workspace) — Visual Studio Code") == "b",
      "dirty marker and (Workspace) suffix don't get in the way")

// Two chats in one project: told apart by their titles.
event("a2", "/Users/me/Documents/GitHub")
store.sessions["a"]?.title = "Status bar"
store.sessions["a2"]?.title = "Portfolio site redesign"
check(focus("Status bar — GitHub") == "a", "VS Code's chat tab: the chat by its title")
check(focus("Portfolio site redesign — GitHub — Visual Studio Code", ["a"]) == "a2", "the title beats the one followed")
check(focus("README.md — GitHub — Visual Studio Code", ["a"]) == "a", "on a file: the chat followed before")
check(focus("README.md — GitHub — Visual Studio Code") == "a2", "on a file, nothing followed: the latest of them")
check(focus("⠂ Status bar") == "a", "a terminal's spinner before the title")
check(store.session(inWindow: "README.md — GitHub — Visual Studio Code") == nil, "two chats, a file in front: can't tell")
check(store.session(inWindow: "Status bar — GitHub")?.id == "a", "…its chat in front: that one")
check(store.session(inWindow: "Makefile — claudebar — Visual Studio Code")?.id == "b", "the only chat of a project")
check(Set(["a", "a2", "b", "c"].compactMap { store.sessions[$0]?.colorIndex }).count == 4, "each chat its own colour")
event("a2", "/Users/me/Documents/GitHub", "SessionEnd")

event("c", "/Users/me/claudebar/Sources", "SessionEnd")
check(focus("Sources — Visual Studio Code") == "b", "an ended session is gone; the parent-folder session matches")

// Where it works: the branch of the file it touched last.
do {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!).appendingPathComponent("repo")
    try? FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try? "ref: refs/heads/feature-x\n".write(to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    store.apply(Inbound(raw: ["hook_event_name": "PreToolUse", "session_id": "a", "cwd": "/Users/me/Documents/GitHub",
                              "tool_name": "Edit", "tool_input": ["file_path": dir.appendingPathComponent("main.swift").path]]))
    check(store.sessions["a"]?.branch == "feature-x", "branch: from the file it edits when its folder isn't a repo")
}

// In Documents the app doesn't read .git (macOS would ask): the hook's branch.
do {
    let home = NSHomeDirectory()
    check(!Git.readable(home + "/Documents/GitHub/app") && !Git.readable(home + "/Desktop")
          && !Git.readable("/Volumes/Disk/app") && Git.readable(home + "/claudebar") && Git.readable(home + "/Documents2"),
          "readable: not Documents, Desktop or another disk")
    store.apply(Inbound(raw: ["hook_event_name": "UserPromptSubmit", "session_id": "d", "cwd": home + "/Documents/GitHub/app",
                              "git_branch": "release"]))
    check(store.sessions["d"]?.branch == "release", "branch: as the hook read it, in Documents")
    store.apply(Inbound(raw: ["hook_event_name": "PreToolUse", "session_id": "e", "cwd": home + "/Documents",
                              "tool_name": "Edit", "tool_input": ["file_path": home + "/Documents/site/index.html"],
                              "file_branch": "main"]))
    check(store.sessions["e"]?.branch == "main", "branch: of the file it edits, as the hook read it")
}

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

// The folder a VS Code chat started in, after it went elsewhere with cd (owner, 27.10)
let moved = Session(id: "mv")
moved.cwd = "/Users/me/GitHub/clouding-bar-promo/out"
moved.transcriptPath = "/Users/me/.claude/projects/-Users-me-GitHub/mv.jsonl"
check(moved.startFolder == "/Users/me/GitHub", "start folder: the one the transcripts' folder is named after, not where cd went")
moved.cwd = "/Users/me/my.app/src"
moved.transcriptPath = "/Users/me/.claude/projects/-Users-me-my-app/mv.jsonl"
check(moved.startFolder == "/Users/me/my.app", "start folder: a dot in a name reads as Claude Code writes it")
moved.transcriptPath = "/Users/me/.claude/projects/-Users-me-elsewhere/mv.jsonl"
check(moved.startFolder == nil, "start folder: none of its folders: unknown (the cwd is used)")
moved.cwd = "/Users/me/elsewhere/x/../y"
check(moved.startFolder == "/Users/me/elsewhere", "start folder: a path with .. is read as it resolves, never looped on")
moved.cwd = "/.."
check(moved.startFolder == nil, "start folder: the root: none")

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
do { // the summary, as /stats: sessions once each, days in a row, the range
    let cal = Calendar.current
    let now = Date()
    func key(_ back: Int) -> String { DayStats.key(cal.date(byAdding: .day, value: -back, to: now)!) }
    var h: [String: DayStats] = [:]
    for back in [0, 1, 2, 5, 6, 7, 8, 40] {
        var d = DayStats(tokens: 1000, minutes: 30, sessions: ["s\(back % 3)"], longest: 30)
        d.projects = ["GitHub": 20, "bots": 10]; d.models = ["Opus 5.5": 900, "Haiku 5.5": 100]
        d.hours[14] = 1000
        h[key(back)] = d
    }
    let week = StatsSummary.of(h, days: 7, now: now)
    let all = StatsSummary.of(h, days: nil, now: now)
    check(week.activeDays == 5 && week.minutes == 150 && week.sessions == 3 && week.currentStreak == 3 && all.longestStreak == 4
          && all.activeDays == 8 && week.favoriteModel == "Opus 5.5" && week.peakHour == 14 && week.projects.first?.name == "GitHub",
          "stats summary: sessions once, streaks, the week against all")
}
print("     (this week: \(week.headline); \(week.projects.map { "\($0.name) \(Int($0.share * 100))%" }.joined(separator: ", ")))")

// Cowork plugin: built into the test folder, its script run on a fake transcript.
let pluginDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!)
// /usr/bin/python3 waits for the Xcode license after a macOS update; the
// Command Line Tools' own runs regardless.
let python3 = ["/Library/Developer/CommandLineTools/usr/bin/python3", "/usr/bin/python3"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }!
let zip = try? Cowork.makePlugin(into: pluginDir)
check(zip?.lastPathComponent == "clouding-bar-plugin.zip" && zip.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
      "the plugin's zip is made, for upload in Claude Desktop")
let coworkScript = Cowork.pluginSource!.appendingPathComponent("hooks/cowork.py").path
check(FileManager.default.fileExists(atPath: coworkScript), "the plugin has its Cowork script")
do { // the hook writes into the connected folder itself: working, then done
    let task = pluginDir.appendingPathComponent("cowork-task")
    let mac = task.appendingPathComponent("mnt/Notes")
    try? FileManager.default.removeItem(at: task)
    try? FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: task.appendingPathComponent("mnt/outputs"), withIntermediateDirectories: true)  // Cowork's own folder: the sign of Cowork
    let transcript = task.appendingPathComponent("t.jsonl")
    try? #"{"type":"assistant","timestamp":"2026-10-20T10:02:00.000Z","message":{"id":"r1","model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_read_input_tokens":40000,"cache_creation_input_tokens":5,"output_tokens":90}}}"#
        .appending("\n").write(to: transcript, atomically: true, encoding: .utf8)
    func hook(_ event: String, cwd: URL, session: String = "s1", prompt: String? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python3)
        p.arguments = ["-I", coworkScript]
        p.environment = ["HOME": cwd.path, "PATH": "/usr/bin:/bin", "CLOUDING_BAR_TEST": "1"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output
        try? p.run()
        var event: [String: Any] = ["hook_event_name": event, "session_id": session, "cwd": cwd.path,
                                    "transcript_path": transcript.path]
        if let prompt { event["prompt"] = prompt }
        input.fileHandleForWriting.write(try! JSONSerialization.data(withJSONObject: event))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    let out = hook("UserPromptSubmit", cwd: task, prompt: "  Fix the landing page for the bots, and check the forms too  ")
    let files = Cowork.statusFiles(folder: mac.path)
    let working = files.first.flatMap(Cowork.read)
    check(out.isEmpty && files.map(\.lastPathComponent) == ["cowork-s1.json"] && working?.working == true
          && working?.contextTokens == 40010, "cowork hook: on a message, \"working\" written to the folder itself")
    _ = hook("Stop", cwd: task)
    let done = Cowork.statusFiles(folder: mac.path).first.flatMap(Cowork.read)
    check(done?.working == false && done?.session == "s1", "cowork hook: on the reply, \"done\"")
    check(working?.title == "Fix the landing page for the bots, and…", "cowork hook: named by your first words")
    let hour = Int(ISO8601DateFormatter().date(from: "2026-10-20T10:02:00Z")!.timeIntervalSince1970 / 3600)
    check(working?.usage[hour] == Cowork.Spent(tokens: 100, minutes: 5), "cowork hook: what it spent by hour, for Stats")
    if let w = working { Cowork.keep(w) }
    let days = DayStats.cowork(Cowork.kept())
    let day = days[DayStats.key(Date(timeIntervalSince1970: Double(hour) * 3600))]
    check(day?.tokens == 100 && day?.minutes == 5 && day?.sessions == ["cowork-s1"]
          && DayStats.merged([DayStats.key(Date(timeIntervalSince1970: Double(hour) * 3600)): DayStats(tokens: 1, minutes: 10)], days)
            .values.first?.minutes == 15,
          "Cowork's days kept and added to Claude Code's")
    if let h = try? FileHandle(forWritingTo: transcript) {
        h.seekToEndOfFile(); h.write(Data((#"{"type":"ai-title","aiTitle":"Bots landing"}"# + "\n").utf8)); try? h.close()
    }
    _ = hook("Stop", cwd: task)
    check(Cowork.statusFiles(folder: mac.path).first.flatMap(Cowork.read)?.title == "Bots landing", "…or by its title")
    store.apply(cowork: Cowork.Status(session: "c1", project: "Notes", contextTokens: 1000, contextWindow: 200_000,
                                      model: nil, time: Date(), title: "Bots landing"))
    store.apply(cowork: Cowork.Status(session: "c2", project: "Notes", contextTokens: 9000, contextWindow: 200_000,
                                      model: nil, time: Date().addingTimeInterval(-60), title: "Mail drafts"))
    check(store.sessions["cowork-c1"]?.displayName == "Bots landing" && store.sessions["cowork-c2"]?.displayName == "Mail drafts",
          "two Cowork tasks in one folder, told apart by name")
    check(Cowork.window(model: "claude-sonnet-5-5") == 500_000 && Cowork.window(model: "claude-opus-5-5[1m]") == 1_000_000
          && Cowork.window(model: "claude-haiku-5-5") == 200_000, "Cowork's window: 500k, 1M for [1m], 200k for Haiku")
    check(store.focus(windowTitle: "Claude", sticky: [], desktop: true)?.id == "cowork-c1"
          && store.focus(windowTitle: "Claude", sticky: ["cowork-c2"], desktop: true)?.id == "cowork-c2"
          && store.focus(windowTitle: "Claude", sticky: ["a"], desktop: true)?.id == "cowork-c1",
          "Claude Desktop in front: its chats, the picked one or the latest")
    check(SessionStore.sameTitle("⚡ Блог: черновики постов", "блог: черновики постов")
          && SessionStore.sameTitle("Fix the landing page for the bots, and check", "Fix the landing page for the bots, and…")
          && !SessionStore.sameTitle("Bots", "Bots landing")
          && SessionStore.sameTitle("Cowork task summary", "Cowork task summary export")
          && SessionStore.titleScore("Блог: сбор идей за неделю", "Сбор идей Блог") == 1,
          "titles: emoji, case and \"…\" aside; Claude Desktop's shorter name")
    check(store.focus(windowTitle: "⚡ Mail drafts", sticky: ["cowork-c1"], desktop: true)?.id == "cowork-c2",
          "Claude Desktop shows a chat by its title: that one, over the picked one")
    store.link(store.sessions["cowork-c1"]!, desktopChat: "/chat/aaa", title: "⚡ Блог: черновики постов")
    check(store.sessions["cowork-c1"]?.displayName == "Блог: черновики постов"
          && store.focus(windowTitle: nil, sticky: ["cowork-c2"], desktop: true, desktopChat: "/chat/aaa")?.id == "cowork-c1",
          "a chat learned: named as Claude Desktop names it, followed by its page")
    store.link(store.sessions["cowork-c2"]!, desktopChat: "/chat/aaa", title: "Other")
    check(store.sessions["cowork-c1"]?.desktopChat == nil && store.session(inDesktop: nil, chat: "/chat/aaa")?.id == "cowork-c2",
          "one chat, one session")

    check(FileManager.default.fileExists(atPath: mac.appendingPathComponent(".clouding-bar/.gitignore").path),
          "cowork hook: git ignores it")
    // Off in Clouding Bar (Settings → Cowork): the folder says so, the plugin is quiet.
    Cowork.setMode("off", folders: [mac.path])
    _ = hook("UserPromptSubmit", cwd: task, session: "s-off")
    check(!FileManager.default.fileExists(atPath: mac.appendingPathComponent(".clouding-bar/cowork-s-off.json").path),
          "cowork hook: quiet when Cowork is off in Clouding Bar")
    Cowork.setMode("thresholds", folders: [mac.path])
    _ = hook("UserPromptSubmit", cwd: task, session: "s-on")
    check(FileManager.default.fileExists(atPath: mac.appendingPathComponent(".clouding-bar/cowork-s-on.json").path),
          "…and reports again when it's on")
    let untouched = pluginDir.appendingPathComponent("cowork-untouched")
    try? FileManager.default.createDirectory(at: untouched, withIntermediateDirectories: true)
    Cowork.setMode("off", folders: [untouched.path])
    check(!FileManager.default.fileExists(atPath: untouched.appendingPathComponent(".clouding-bar").path),
          "Cowork off: nothing written where the plugin never was")
    let server = pluginDir.appendingPathComponent("linux-server")
    try? FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
    check(hook("Stop", cwd: server, session: UUID().uuidString).isEmpty, "cowork hook: quiet on a Linux that isn't Cowork")
    let lonely = pluginDir.appendingPathComponent("cowork-nofolder")
    try? FileManager.default.createDirectory(at: lonely.appendingPathComponent("mnt/outputs"), withIntermediateDirectories: true)
    do { // on the Mac (Claude Code, not Cowork) it does nothing
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python3)
        p.arguments = ["-I", coworkScript]
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output
        try? p.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"mac","transcript_path":"\#(transcript.path)"}"#.utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        check(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "cowork hook: quiet in Claude Code on the Mac")
    }
    check(hook("Stop", cwd: lonely, session: UUID().uuidString).contains("\"decision\": \"block\""), "cowork hook: no folder in reach, Claude is asked")
}

// MARK: The plugin and Claude Code's settings

do {
    let fm = FileManager.default
    let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!).appendingPathComponent("claude-home")
    try? fm.removeItem(at: home)
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    let settings = home.appendingPathComponent("settings.json")
    setenv("CLOUDINGBAR_CLAUDE_SETTINGS", settings.path, 1)
    try? "{}".write(to: settings, atomically: true, encoding: .utf8)
    check(!Setup.pluginActive && !Setup.isConnected, "settings: nothing of ours yet")
    try? Setup.connect()
    check(Setup.hooksInSettings && Setup.isConnected, "Connect without the plugin: hooks and status line")

    try? #"{"enabledPlugins": {"clouding-bar@clouding-bar": true}}"#.write(to: settings, atomically: true, encoding: .utf8)
    check(Setup.pluginActive && !Setup.isConnected, "the plugin is on, the status line not yet")
    try? Setup.connect()
    check(!Setup.hooksInSettings && Setup.isConnected, "Connect with the plugin: the status line only, the plugin brings the hooks")

    try? "{}".write(to: settings, atomically: true, encoding: .utf8)
    let account = home.appendingPathComponent("plugins/synced/account")
    try? fm.createDirectory(at: account, withIntermediateDirectories: true)
    try? #"{"plugins": [{"name": "clouding-bar"}, {"name": "clouding-bar-cowork"}]}"#
        .write(to: account.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    check(Setup.pluginActive && Setup.pluginSynced && Setup.oldCoworkPlugin,
          "the plugin from Claude Desktop (synced) counts; the old Cowork one is noticed")
    unsetenv("CLOUDINGBAR_CLAUDE_SETTINGS")

    // The plugin's hook script on the Mac: to the app's hook program, or aside.
    let runSh = Cowork.pluginSource!.appendingPathComponent("hooks/run.sh").path
    let fakeHome = home.appendingPathComponent("user")
    let ours = fakeHome.appendingPathComponent(".cloudingbar")
    try? fm.createDirectory(at: ours, withIntermediateDirectories: true)
    try? fm.createDirectory(at: fakeHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    func run(_ event: String, root: String = "/x/.claude/plugins/cache/clouding-bar/clouding-bar/1.1.0") -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [runSh, event]
        p.environment = ["HOME": fakeHome.path, "PATH": "/usr/bin:/bin", "CLAUDE_PLUGIN_ROOT": root]
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output
        try? p.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"\#(event)"}"#.utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    check(run("PreToolUse").isEmpty, "plugin hook: no app yet, nothing in the way")
    let program = ours.appendingPathComponent("cloudingbar-hook")
    try? "#!/bin/sh\necho forwarded; cat\n".write(to: program, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    check(run("PreToolUse") == "forwarded\n{\"hook_event_name\":\"PreToolUse\"}", "plugin hook: the event goes to the app's hook program")
    let userSettings = fakeHome.appendingPathComponent(".claude/settings.json")
    try? #"{"enabledPlugins": {"clouding-bar@clouding-bar": true}}"#.write(to: userSettings, atomically: true, encoding: .utf8)
    check(run("PreToolUse", root: "/x/.claude/plugins/synced/acc/clouding-bar").isEmpty,
          "plugin hook: the copy from Claude Desktop steps aside for the one installed in Claude Code")
    try? #"{"hooks": {"PreToolUse": [{"hooks": [{"command": "/u/.cloudingbar/cloudingbar-hook"}]}]}}"#
        .write(to: userSettings, atomically: true, encoding: .utf8)
    check(run("PreToolUse").isEmpty, "plugin hook: steps aside for the hook in settings.json (no event twice)")
}

// MARK: Messages straight into Claude (VS Code, through the wrapper)

do {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!)
    func parse(_ d: Data?) -> [String: Any]? { d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
    let plain = parse(Inject.message("Fix the header"))
    let content = (plain?["message"] as? [String: Any])?["content"] as? [[String: Any]]
    check(plain?["type"] as? String == "user" && plain?["parent_tool_use_id"] is NSNull
          && content?.first?["text"] as? String == "Fix the header", "inject: a message the way the extension sends them")
    let png = dir.appendingPathComponent("shot test.png")
    try? Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).write(to: png)
    let big = dir.appendingPathComponent("big.png")
    try? Data(count: Inject.maxImageBytes + 1).write(to: big)
    let withFiles = (parse(Inject.message("Look", files: [png.path, big.path]))?["message"] as? [String: Any])?["content"] as? [[String: Any]]
    check(withFiles?.count == 2 && withFiles?[1]["type"] as? String == "image"
          && (withFiles?[0]["text"] as? String)?.contains("big.png") == true,
          "inject: a screenshot as a picture; a too big one by its path")
    check(Inject.message("  ") == nil && !Inject.available(pid: nil) && !Inject.available(pid: getpid()),
          "inject: nothing to send; no door, no sending that way")

    // Through the real relay (cloudingbar-tap --input): the door named by its
    // parent's id (here this test's), lines kept whole and in order.
    let tap = Process()
    tap.executableURL = URL(fileURLWithPath: "build/cloudingbar-tap")
    tap.arguments = ["--input"]
    let input = Pipe(), output = Pipe()
    tap.standardInput = input
    tap.standardOutput = output
    try? tap.run()
    let door = Inject.socketPath(pid: getpid())
    for _ in 0..<50 where !fm.fileExists(atPath: door) { usleep(20_000) }
    input.fileHandleForWriting.write(Data(#"{"type":"user","message":{"role":"user","content":"from the extension"}}"#.utf8 + [0x0A]))
    usleep(100_000)
    let sent = Inject.send(Inject.message("from Clouding Bar")!, pid: getpid())
    let refused = Inject.send(Data(#"{"type":"control_request"}"#.utf8), pid: getpid())
    try? input.fileHandleForWriting.close()
    tap.waitUntilExit()
    let lines = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.split(separator: "\n") ?? []
    check(sent && !refused && lines.count == 2 && lines[0].contains("from the extension") && lines[1].contains("from Clouding Bar")
          && !fm.fileExists(atPath: door), "inject: through the relay, between the extension's lines; only user messages; door gone after")
}

// MARK: Updates

do {
    func release(_ tag: String, _ assets: [String], draft: Bool = false, pre: Bool = false) -> [String: Any] {
        ["tag_name": tag, "draft": draft, "prerelease": pre, "html_url": "https://github.com/r/releases/tag/\(tag)",
         "assets": assets.map { ["name": $0, "browser_download_url": "https://github.com/r/releases/download/\(tag)/\($0)"] }]
    }
    let list: [[String: Any]] = [
        release("windows-beta-3", ["Clouding-Bar-Windows-beta-3.zip"]),
        release("v2.0.0", ["Clouding-Bar-2.0.0.dmg"], draft: true),
        release("v1.9.9", ["Clouding-Bar-1.9.9.dmg"], pre: true),
        release("v1.0.1", ["Clouding-Bar-1.0.1.dmg"]),
        release("v1.10.0", ["Clouding-Bar-1.10.0.dmg"]),
        release("mac-beta-2", ["Clouding-Bar-1.0.0-beta.dmg"]),
    ]
    let newest = UpdateCheck.newest(in: try! JSONSerialization.data(withJSONObject: list))
    check(newest?.version == "1.10.0" && newest?.dmg.lastPathComponent == "Clouding-Bar-1.10.0.dmg"
          && newest?.page?.lastPathComponent == "v1.10.0",
          "updates: the newest Mac release — no drafts, pre-releases, betas or Windows")
    check(UpdateCheck.isNewer("1.10.0", than: "1.9.3") && !UpdateCheck.isNewer("1.0.1", than: "1.0.1")
          && !UpdateCheck.isNewer("1.0.0", than: "1.0.1") && UpdateCheck.isNewer("1.1", than: "1.0.9"),
          "updates: versions compared number by number")
    check(UpdateCheck.version(ofDMG: "Clouding-Bar-1.2.3.dmg") == "1.2.3" && UpdateCheck.version(ofDMG: "Clouding-Bar-1.2.dmg") == nil
          && UpdateCheck.version(ofDMG: "Clouding-Bar-1.0.0-beta.dmg") == nil, "updates: a release's disk image by its name")
    check(UpdateCheck.due(lastCheck: nil) && !UpdateCheck.due(lastCheck: Date().addingTimeInterval(-3600))
          && UpdateCheck.due(lastCheck: Date().addingTimeInterval(-21 * 3600)), "updates: once a day")
    check(UpdateCheck.newest(in: Data("{\"message\": \"Not Found\"}".utf8)) == nil, "updates: GitHub's \"not found\" is no release")
}

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
do { // ☁️ in Claude's words just now: Cloud waves back, once a chat; old replies and code don't count
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func reply(_ blocks: String, at date: Date = Date()) -> String {
        #"{"type":"assistant","timestamp":"\#(f.string(from: date))","message":{"id":"\#(UUID().uuidString)","model":"claude-opus-5-5","content":\#(blocks),"usage":{"input_tokens":1,"output_tokens":1}}}"#
    }
    /// One chat's transcript, growing by each batch of replies: whether each look waved.
    func waves(_ batches: [String]...) -> [Bool] {
        let file = dir.appendingPathComponent("wave-\(UUID().uuidString).jsonl")
        let watcher = TranscriptWatcher()
        var text = ""
        return batches.map { replies in
            text += replies.map { $0 + "\n" }.joined()
            try? text.write(to: file, atomically: true, encoding: .utf8)
            var got: [TranscriptWatcher.Update] = []
            let done = DispatchSemaphore(value: 0)
            watcher.poll([(id: "w", path: file.path)]) { got = $0; done.signal() }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return got.first?.waved == true
        }
    }
    let words = #"[{"type":"text","text":"Done ☁️"}]"#
    let code = #"[{"type":"tool_use","name":"Write","input":{"content":"// ☁️ hello"}}]"#
    let old = Date().addingTimeInterval(-600)
    check(waves([reply(words)]) == [true] && waves([reply(words, at: old)]) == [false] && waves([reply(code)]) == [false],
          "☁️ in a fresh reply's words waves; an old reply or code doesn't")
    check(waves([reply(words)], [reply(words)]) == [true, false] && waves([reply(words, at: old), reply(words)]) == [false]
          && waves([reply(code)], [reply(words)]) == [false, true],
          "Cloud waves back once a chat: not again, nor after an earlier ☁️ (an app restart reads it)")
}
do { // a reply counts once, even written again much later; the title is read
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!)
    let file = dir.appendingPathComponent("dupes.jsonl")
    func reply(_ id: String, _ ctx: Int) -> String {
        #"{"type":"assistant","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(ctx),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":10}}}"#
    }
    let lines = [reply("m1", 1000), reply("m1", 1000), #"{"type":"user","message":{"content":"x"}}"#, reply("m1", 1000),
                 reply("m2", 5000), #"{"type":"ai-title","aiTitle":"Status bar","sessionId":"t"}"#,
                 reply("m1", 1000), // m1 written again, long after
                 #"{"type":"custom-title","customTitle":"My bar","sessionId":"t"}"#,
                 #"{"type":"user","uuid":"e1","toolUseResult":{"type":"create","content":"a\nb"}}"#,
                 #"{"type":"user","uuid":"e1","toolUseResult":{"type":"create","content":"a\nb"}}"#]
    try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    let watcher = TranscriptWatcher()
    var got: [TranscriptWatcher.Update] = []
    let done = DispatchSemaphore(value: 0)
    watcher.poll([(id: "t", path: file.path)]) { got = $0; done.signal() }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(got.first?.tokensIn == 6000 && got.first?.tokensOut == 20, "watcher: each reply counted once")
    check(got.first?.contextTokens == 5000, "watcher: an old reply written again doesn't set the context")
    check(got.first?.title == "My bar", "watcher: the title you gave wins over Claude's")
    check(got.first?.linesAdded == 2, "watcher: an edit written again counts once")
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

// MARK: Codex: limits, status, files (fixtures follow the documented rollout and hook formats)

do {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!).appendingPathComponent("codex")
    try? fm.removeItem(at: base)
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func stamp(_ d: Date) -> String { iso.string(from: d) }
    func line(_ ts: Date, _ type: String, _ payload: String) -> String { #"{"timestamp":"\#(stamp(ts))","type":"\#(type)","payload":\#(payload)}"# }
    func event(_ ts: Date, _ payload: String) -> String { line(ts, "event_msg", payload) }
    func counts(_ ts: Date, last: Int = 41900, window: Int = 258400, limits: String?) -> String {
        event(ts, #"{"type":"token_count","info":{"total_token_usage":{"input_tokens":120000,"cached_input_tokens":90000,"output_tokens":3200,"reasoning_output_tokens":1500,"total_tokens":123200},"last_token_usage":{"input_tokens":41000,"cached_input_tokens":38000,"output_tokens":900,"reasoning_output_tokens":400,"total_tokens":\#(last)},"model_context_window":\#(window)},"rate_limits":\#(limits ?? "null")}"#)
    }
    func windows(id: String = "codex", five: String? = #""used_percent":12.0,"window_minutes":300,"resets_at":1793020000"#,
                 week: String? = #""used_percent":4.0,"window_minutes":10080,"resets_at":1793600000"#, plan: String = "plus") -> String {
        #"{"limit_id":"\#(id)","limit_name":null,"primary":\#(five.map { "{" + $0 + "}" } ?? "null"),"secondary":\#(week.map { "{" + $0 + "}" } ?? "null"),"credits":{"has_credits":false,"unlimited":false,"balance":null},"plan_type":"\#(plan)"}"#
    }
    func scan(_ lines: [String]) -> TranscriptWatcher.Update {
        var u = TranscriptWatcher.Update(sessionId: "t", modified: Date())
        for l in lines { TranscriptWatcher.scanCodex(Data(l.utf8)[...], into: &u) }
        return u
    }
    func spin(_ done: () -> Bool, seconds: Double = 5) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    let t0 = Date(timeIntervalSince1970: 1_792_999_000) // 2026-10-26, fixed: parsing doesn't look at the clock

    // Limits, as the lines say them
    let modern = scan([counts(t0, limits: windows())])
    check(modern.codexFiveHour?.percent == 12 && modern.codexFiveHour?.resetsAt == 1793020000
          && modern.codexWeek?.percent == 4 && modern.codexPlan == "plus", "codex files: 5-hour, weekly and plan from a token_count")
    check(abs((modern.codexFiveHour?.reported.timeIntervalSince(t0) ?? 99)) < 0.01, "codex files: a limit is reported at its line's time")
    let spark = scan([counts(t0, limits: windows()), counts(t0.addingTimeInterval(1), limits: windows(id: "codex_other", five: #""used_percent":88,"window_minutes":300,"resets_at":1793021111"#))])
    check(spark.codexFiveHour?.percent == 12 && spark.codexOther["codex_other"]?.fiveHour?.percent == 88,
          "codex files: another bucket's snapshot is kept aside, never the account's limit")
    check(scan([counts(t0, limits: windows(id: "codex_other"))]).codexFiveHour == nil, "codex files: only another bucket's limit: no account limit")
    check(scan([counts(t0, limits: windows(id: ""))]).codexFiveHour?.percent == 12, "codex files: an empty limit_id is the account's")
    let legacy = scan([counts(t0, limits: windows(five: #""used_percent":2,"window_minutes":300,"resets_in_seconds":1800"#, week: nil))])
    check(legacy.codexFiveHour?.resetsAt == t0.timeIntervalSince1970 + 1800 && legacy.codexWeek == nil, "codex files: resets_in_seconds counts from the line, no weekly window is fine")
    let isoReset = scan([counts(t0, limits: windows(five: #""used_percent":3,"window_minutes":300,"resets_at":"2025-10-19T13:51:37.876641+00:00""#, week: nil))])
    check(abs((isoReset.codexFiveHour?.resetsAt ?? 0) - 1_760_881_897.9) < 1, "codex files: resets_at as an ISO string, microseconds too")
    let unknownReset = scan([counts(t0, limits: windows(five: #""used_percent":3,"window_minutes":300"#, week: nil))])
    check(unknownReset.codexFiveHour?.resetsAt == t0.timeIntervalSince1970 + 300 * 60, "codex files: no reset time: at the latest a window's length later")
    let weekly = scan([counts(t0, limits: windows(five: nil))])
    check(weekly.codexFiveHour == nil && weekly.codexWeek?.percent == 4, "codex files: a plan with only the weekly window")
    check(scan([counts(t0, limits: windows(five: #""used_percent":50,"window_minutes":120,"resets_at":1793020000"#, week: nil))]).codexFiveHour == nil,
          "codex files: a window of some other length is not called 5-hour")
    check(scan([counts(t0, limits: "null")]).codexFiveHour == nil && scan([counts(t0, limits: "null")]).contextTokens == 41900, "codex files: no rate_limits (API key): context still read")

    // Turns
    let turns = scan([event(t0, #"{"type":"task_started","turn_id":"t1","model_context_window":258400}"#),
                      event(t0.addingTimeInterval(9), #"{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}"#)])
    check(turns.codexTurn?.state == .aborted && turns.contextWindow == 258400, "codex files: the latest turn event wins; the window from task_started")
    check(scan([event(t0, #"{"type":"task_started","turn_id":"t1"}"#), event(t0, #"{"type":"task_complete","turn_id":"t1","last_agent_message":"ok"}"#)]).codexTurn?.state == .done, "codex files: task_complete is done")
    check(scan([event(t0, #"{"type":"task_started","turn_id":"t2"}"#)]).codexTurn?.state == .started, "codex files: task_started is at work")
    check(modern.codexTokens?.input == 30000 && modern.codexTokens?.output == 3200, "codex files: tokens in (not cached) and out of the whole chat")

    // Numbers
    check(CodexRollout.contextUsedPercent(tokens: 41900, window: 258400) == 12, "codex context: 12 000 tokens are not yours (41 900 of 258 400 reads 12 %)")
    check(CodexRollout.contextUsedPercent(tokens: 5000, window: 258400) == 0 && CodexRollout.contextUsedPercent(tokens: 258400, window: 258400) == 100
          && CodexRollout.contextUsedPercent(tokens: 1, window: 10000) == 100, "codex context: from 0 to 100, and a window under the baseline is full")
    let cs = Session(id: "cx"); cs.entrypoint = "codex"; cs.contextTokens = 41900; cs.contextWindowSize = 258400; cs.model = "gpt-5.3-codex"
    check(cs.contextPercent(windowOverride: nil) == 12 && cs.modelName == "GPT-5.3-Codex", "codex session: context and model as Codex says them")
    check(CodexRollout.modelName("gpt-5.1-codex-max") == "GPT-5.1-Codex-Max" && CodexRollout.modelName("o4-mini") == "o4-mini"
          && Session.displayName("claude-opus-5-5[1m]") == "Opus 5.5 1M", "model names: GPT with its dashes; Claude's as before")
    check(Inbound(raw: ["model": "gpt-5.3-codex", "claude_entrypoint": "codex"]).modelId == "gpt-5.3-codex"
          && Inbound(raw: ["model": "claude-opus-5-5"]).modelId == nil
          && Inbound(raw: ["model": ["id": "claude-opus-5-5"]]).modelId == "claude-opus-5-5", "model from a hook: Codex's plain string; Claude's unchanged")

    // The account: newest report wins, a passed reset reads as reset
    let acct = Account(fileName: "codex-test-account.json", keepsHistory: false)
    let soon = Date().addingTimeInterval(3600).timeIntervalSince1970
    acct.apply(used: 10, resetsAt: soon, reported: Date().addingTimeInterval(-100))
    acct.apply(used: 50, resetsAt: soon, reported: Date().addingTimeInterval(-500))
    check(acct.sessionPercent == 10, "codex account: an older report never replaces a newer one")
    acct.apply(used: 20, resetsAt: soon, reported: Date().addingTimeInterval(-10))
    check(acct.sessionPercent == 20 && acct.updatedAt.map { Date().timeIntervalSince($0) < 15 } == true, "codex account: a newer one does, and 'last seen' is its time")
    acct.apply(used: 70, resetsAt: Date().addingTimeInterval(-5).timeIntervalSince1970, reported: Date().addingTimeInterval(-1))
    check(acct.sessionPercent == 0 && acct.resetsAt == nil, "codex account: a window whose reset has passed reads as reset (0 %, no number from before)")
    acct.applyWeek(used: 30, resetsAt: soon, reported: Date().addingTimeInterval(-60))
    acct.applyWeek(used: 90, resetsAt: Date().addingTimeInterval(-60).timeIntervalSince1970, reported: Date())
    check(acct.weekPercent == 0 && acct.weekResetsAt == nil, "codex account: the weekly window the same")
    acct.setPlan("pro")
    let again = Account(fileName: "codex-test-account.json", keepsHistory: false)
    again.load()
    check(again.plan == "pro" && again.weekPercent == 0, "codex account: kept across restarts, plan too")
    let claude = Account(fileName: "codex-test-claude.json", keepsHistory: false)
    claude.apply(used: 5, resetsAt: Date().addingTimeInterval(-60).timeIntervalSince1970)
    check(claude.sessionPercent == 5, "claude account: applied as before (no report time, no passed-reset reading)")
    // 1.1.4 kept the time it read any line, of any bucket (review, 27.10)
    try? #"{"sessionPercent":88,"updatedAt":\#(Date().timeIntervalSinceReferenceDate)}"#
        .write(to: Config.directory.appendingPathComponent("codex-test-old.json"), atomically: true, encoding: .utf8)
    let older = Account(fileName: "codex-test-old.json", keepsHistory: false)
    older.load()
    older.apply(used: 12, resetsAt: soon, reported: Date().addingTimeInterval(-60))
    check(older.sessionPercent == 12, "codex account: a number an older version kept doesn't hold back a true report")
    let working = Session(id: "w"); working.entrypoint = "codex"; working.activity = .work
    working.activitySince = Date().addingTimeInterval(-120)
    let back = Session(record: working.record)
    check(back.activity == .work && abs(back.activitySince.timeIntervalSince(working.activitySince)) < 0.01,
          "codex: when a turn began is kept across a restart, so its task_complete written meanwhile still ends it")

    // Hooks
    func session(_ store: SessionStore, _ id: String, path: String? = nil) -> Session {
        var raw: [String: Any] = ["session_id": id, "hook_event_name": "SessionStart", "cwd": "/Users/me/proj",
                                  "claude_entrypoint": "codex", "claude_pid": Int(getpid())]
        if let path { raw["transcript_path"] = path }
        store.apply(Inbound(raw: raw))
        return store.sessions[id]!
    }
    func hook(_ store: SessionStore, _ id: String, _ name: String, _ extra: [String: Any] = [:]) {
        var raw: [String: Any] = ["session_id": id, "hook_event_name": name, "claude_entrypoint": "codex", "claude_pid": Int(getpid())]
        for (k, v) in extra { raw[k] = v }
        store.apply(Inbound(raw: raw))
    }
    do {
        let store = SessionStore()
        let s = session(store, "w1")
        hook(store, "w1", "UserPromptSubmit")
        hook(store, "w1", "PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"]])
        hook(store, "w1", "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm x"]])
        check(s.waitingNotice && s.activity == .work, "codex status: a PermissionRequest is Codex asking")
        hook(store, "w1", "PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "pwd"]])
        check(s.waitingNotice, "codex status: another call's start doesn't end the asking")
        hook(store, "w1", "PostToolUse", ["tool_name": "Bash"])
        check(!s.waitingNotice, "codex status: the tool's end does")
        for end in ["Stop", "Interrupt", "UserPromptSubmit"] {
            hook(store, "w1", "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "x"]])
            hook(store, "w1", end)
            check(!s.waitingNotice && (end == "UserPromptSubmit" || s.activity == .sleep), "codex status: \(end) ends the asking")
        }
        hook(store, "w1", "UserPromptSubmit")
        hook(store, "w1", "SubagentStart", ["agent_id": "a1", "agent_type": "explorer"])
        hook(store, "w1", "Interrupt")
        check(s.activity == .sleep && s.runningAgents == 0, "codex status: Interrupt ends the turn (no Stop comes) and its subagents")
        let c = SessionStore(), cs = Session(id: "claude-1")
        c.apply(Inbound(raw: ["session_id": "claude-1", "hook_event_name": "PermissionRequest", "claude_entrypoint": "cli", "tool_name": "Bash"]))
        check(!(c.sessions["claude-1"]?.waitingNotice ?? true) && cs.entrypoint == nil, "claude status: PermissionRequest leaves waitingNotice to the Notification, as before")
    }

    // Status from the file
    func rollName(_ id: String, _ time: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return "rollout-\(f.string(from: time))-\(id).jsonl"
    }
    let ids = (1...9).map { "019a0000-0000-7000-8000-00000000000\($0)" }
    func write(_ lines: [String], to path: String, modified: Date? = nil) {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
    }
    do {
        let store = SessionStore()
        let path = base.appendingPathComponent(rollName(ids[0])).path
        let s = session(store, ids[0], path: path)
        hook(store, ids[0], "UserPromptSubmit")
        Thread.sleep(forTimeInterval: 0.05)
        let t = Date()
        write([event(t, #"{"type":"task_started","turn_id":"t1","model_context_window":258400}"#),
               counts(t.addingTimeInterval(0.1), limits: windows()),
               event(t.addingTimeInterval(0.5), #"{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}"#)], to: path)
        store.pollTranscripts()
        spin { s.activity == .sleep }
        check(s.activity == .sleep && s.finishedAt != nil, "codex status: Esc in Codex (turn_aborted in the file) ends the eternal Working")
        check(s.contextTokens == 41900 && s.contextWindowSize == 258400 && s.tokensIn == 30000 && s.tokensOut == 3200, "codex status: context window and tokens from the file")

        let late = SessionStore()
        let p2 = base.appendingPathComponent(rollName(ids[1])).path
        let s2 = session(late, ids[1], path: p2)
        hook(late, ids[1], "UserPromptSubmit")
        write([event(Date().addingTimeInterval(-60), #"{"type":"task_complete","turn_id":"t0"}"#)], to: p2)
        late.pollTranscripts()
        spin { s2.transcriptChanged != nil }
        check(s2.activity == .work, "codex status: a turn's end older than the hook's word changes nothing")

        let start = SessionStore()
        let p3 = base.appendingPathComponent(rollName(ids[2])).path
        let s3 = session(start, ids[2], path: p3)
        Thread.sleep(forTimeInterval: 0.05)
        write([event(Date(), #"{"type":"task_started","turn_id":"t1"}"#)], to: p3)
        start.pollTranscripts()
        spin { s3.activity == .work }
        check(s3.activity == .work, "codex status: task_started alone is at work")
    }

    // Bounded reads
    do {
        let path = base.appendingPathComponent(rollName(ids[3])).path
        var head = [line(t0, "session_meta", #"{"id":"\#(ids[3])","cwd":"/Users/me/big","originator":"codex_cli_rs","source":"cli"}"#),
                    line(t0, "turn_context", #"{"turn_id":"t1","model":"early-model","effort":"low"}"#)]
        let filler = line(t0, "response_item", #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(String(repeating: "x", count: 2000))"}]}"#)
        head += Array(repeating: filler, count: 6000) // ~12 MB
        head.append(counts(t0.addingTimeInterval(5), last: 60000, limits: windows()))
        write(head, to: path)
        let w = TranscriptWatcher()
        var got: TranscriptWatcher.Update?
        let began = Date()
        w.poll([(id: "big", path: path)]) { got = $0.first }
        spin { got != nil }
        check(got?.contextTokens == 60000 && got?.codexFiveHour?.percent == 12, "codex files: a 12 MB file's end read")
        check(got?.model == nil && got?.codexMeta?.cwd == "/Users/me/big" && got?.codexMeta?.host == "Terminal",
              "codex files: only the last 3 MB on first sight (the early turn isn't read), the first line for who and where")
        check(Date().timeIntervalSince(began) < 3, "codex files: a big file reads fast")
        // a line still being written
        let h = FileHandle(forWritingAtPath: path)!
        h.seekToEndOfFile()
        let whole = counts(t0.addingTimeInterval(9), last: 70000, limits: windows())
        h.write(Data(whole.prefix(60).utf8))
        got = nil
        w.poll([(id: "big", path: path)]) { got = $0.first }
        spin({ got != nil }, seconds: 0.5)
        check(got?.contextTokens == nil || got?.contextTokens == 60000 && got?.model == nil, "codex files: half a line is waited for")
        h.write(Data((String(whole.dropFirst(60)) + "\n").utf8))
        try? h.close()
        got = nil
        w.poll([(id: "big", path: path)]) { got = $0.first }
        spin { got != nil }
        check(got?.contextTokens == 70000, "codex files: and read once whole")
    }

    // Finding the files without hooks
    do {
        let day = DateFormatter(); day.dateFormat = "yyyy/MM/dd"
        let dir = base.appendingPathComponent("home/sessions/" + day.string(from: Date()), isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let archived = base.appendingPathComponent("home/archived_sessions", isDirectory: true)
        try? fm.createDirectory(at: archived, withIntermediateDirectories: true)
        setenv("CLOUDINGBAR_CODEX_HOME", base.appendingPathComponent("home").path, 1)
        func meta(_ id: String, _ originator: String, _ source: String) -> String {
            line(t0, "session_meta", #"{"id":"\#(id)","cwd":"/Users/me/proj","originator":"\#(originator)","cli_version":"0.164.0","source":\#(source),"git":{"branch":"main"}}"#)
        }
        let now = Date()
        let fresh = dir.appendingPathComponent(rollName(ids[4])).path
        write([meta(ids[4], "codex_vscode", #""vscode""#), event(now.addingTimeInterval(-30), #"{"type":"task_started","turn_id":"t1"}"#),
               line(now.addingTimeInterval(-29), "turn_context", #"{"turn_id":"t1","cwd":"/Users/me/proj","model":"gpt-5.3-codex","effort":"high"}"#),
               counts(now.addingTimeInterval(-20), limits: windows(five: #""used_percent":12,"window_minutes":300,"resets_at":\#(Int(now.timeIntervalSince1970) + 3600)"#,
                                                                    week: #""used_percent":4,"window_minutes":10080,"resets_at":\#(Int(now.timeIntervalSince1970) + 86400)"#))], to: fresh, modified: now)
        write([meta(ids[5], "codex_cli_rs", #"{"subagent":"review"}"#), event(now, #"{"type":"task_started","turn_id":"s"}"#)], to: dir.appendingPathComponent(rollName(ids[5])).path, modified: now)
        write([meta(ids[6], "codex_exec", #""exec""#)], to: dir.appendingPathComponent(rollName(ids[6])).path, modified: now)
        write([meta(ids[7], "codex_cli_rs", #""cli""#), event(now.addingTimeInterval(-9000), #"{"type":"task_complete","turn_id":"o"}"#)], to: dir.appendingPathComponent(rollName(ids[7])).path, modified: now.addingTimeInterval(-3 * 3600))
        try? "zstd".write(toFile: dir.appendingPathComponent(rollName(ids[8]) + ".zst").path, atomically: true, encoding: .utf8)
        write([meta(ids[8], "codex_cli_rs", #""cli""#)], to: archived.appendingPathComponent(rollName(ids[8])).path, modified: now.addingTimeInterval(-7200))

        let finder = CodexRollouts()
        var found: [CodexRollouts.Found] = []
        var done = false
        finder.scan { found = $0; done = true }
        spin { done }
        let names = Set(found.map { ($0.path as NSString).lastPathComponent })
        check(names.contains(rollName(ids[4])) && !names.contains(where: { $0.hasSuffix(".zst") }), "codex files: rollouts found, compressed ones skipped")
        check(!found.contains { $0.archived }, "codex files: an archived chat older than the newest isn't taken")
        write([meta(ids[8], "codex_cli_rs", #""cli""#)], to: archived.appendingPathComponent(rollName(ids[8])).path, modified: now.addingTimeInterval(60))
        done = false
        CodexRollouts().scan { found = $0; done = true }
        spin { done }
        check(found.first?.archived == true, "codex files: an archived one newer than all is")
        try? fm.removeItem(at: archived.appendingPathComponent(rollName(ids[8])))

        let store = SessionStore()
        store.pollCodexRollouts()
        spin { store.sessions[ids[4]] != nil }
        let list = store.alive
        check(list.count == 1 && list[0].id == ids[4], "codex files: one chat shown — not the subagent's, `codex exec`'s, nor the idle old one")
        let a = store.sessions[ids[4]]
        check(a?.entrypoint == "codex" && a?.ambient == true && a?.codexHost == "VS Code" && a?.cwd == "/Users/me/proj" && a?.cwdBranch == "main",
              "codex files: its folder, branch and where it runs read from session_meta")
        spin { a?.model != nil }
        check(a?.model == "gpt-5.3-codex" && a?.activity == .work && a?.contextPercent(windowOverride: nil) == 12,
              "codex files: model, at work and context from the file, with no hook")
        check(store.codexAccount.sessionPercent == 12 && store.codexAccount.weekPercent == 4, "codex files: its limits too")
        let rec = a.map { Session(record: $0.record) }
        check(rec?.ambient == true && rec?.codexHost == "VS Code", "codex files: kept across a restart")
        store.apply(Inbound(raw: ["session_id": ids[4], "hook_event_name": "SessionEnd", "claude_entrypoint": "codex"]))
        store.pollCodexRollouts()
        spin({ store.sessions[ids[4]] != nil }, seconds: 0.6)
        check(store.sessions[ids[4]] == nil, "codex files: a chat that ended isn't brought back by its file")
        let known = SessionStore()
        _ = session(known, ids[4], path: fresh)
        known.pollCodexRollouts()
        spin({ known.sessions.count > 1 }, seconds: 0.6)
        check(known.sessions.count == 1 && known.sessions[ids[4]]?.ambient == false, "codex files: a chat a hook knows isn't added twice")
        let idle = Session(id: "idle"); idle.entrypoint = "codex"; idle.ambient = true
        idle.lastEvent = Date().addingTimeInterval(-1200); idle.transcriptChanged = Date().addingTimeInterval(-1200)
        check(!idle.isAlive(), "codex files: a chat whose file stopped changing is gone after a quarter of an hour")
        idle.activity = .work
        check(idle.isAlive(), "codex files: an hour while a turn is on")

        // Never typed into (review, 27.10): a shell or an editor on its folder isn't its window
        let typing = SessionStore()
        typing.pollCodexRollouts()
        spin { typing.sessions[ids[4]] != nil }
        check(typing.sessions[ids[4]]?.ambient == true && typing.session(inWindow: "proj — -zsh — 80×24") == nil
              && typing.session(inWindow: "main.swift — proj") == nil, "codex files: a chat found in them is never the window in front")
        typing.apply(Inbound(raw: ["session_id": "claude-cli", "hook_event_name": "SessionStart", "cwd": "/Users/me/proj",
                                   "claude_entrypoint": "cli", "claude_pid": Int(getpid())]))
        check(typing.session(inWindow: "proj — -zsh — 80×24")?.id == "claude-cli", "codex files: nor does it hide a Claude chat of that folder")
        // Its Codex closed with no SessionEnd: pruned, and not brought back
        let closed = SessionStore()
        session(closed, ids[4], path: fresh).claudePid = 99_999
        closed.prune()
        closed.pollCodexRollouts()
        spin({ closed.sessions[ids[4]] != nil }, seconds: 0.6)
        check(closed.sessions[ids[4]] == nil, "codex files: a chat whose Codex closed without SessionEnd isn't brought back by its file")
        // A first line written late is read on the next look
        let lateId = "019a0000-0000-7000-8000-000000000010"
        let latePath = dir.appendingPathComponent(rollName(lateId)).path
        write([], to: latePath, modified: Date())
        let looker = CodexRollouts()
        done = false
        looker.scan { found = $0; done = true }
        spin { done }
        write([meta(lateId, "codex_cli_rs", #""cli""#)], to: latePath, modified: Date())
        done = false
        looker.scan { found = $0; done = true }
        spin { done }
        check(found.first { $0.path == latePath }?.meta?.interactive == true, "codex files: a file whose first line came late is read again")
        try? fm.removeItem(atPath: latePath)

        // Its tab (owner, 27.10): the one Codex program in a terminal in its folder
        func termMeta(_ id: String) -> String {
            line(t0, "session_meta", #"{"id":"\#(id)","cwd":"/Users/me/term","originator":"codex_cli_rs","cli_version":"0.164.0","source":"cli"}"#)
        }
        let termId = "019a0000-0000-7000-8000-000000000011", twinId = "019a0000-0000-7000-8000-000000000012"
        let termPath = dir.appendingPathComponent(rollName(termId)).path, twinPath = dir.appendingPathComponent(rollName(twinId)).path
        write([termMeta(termId)], to: termPath, modified: Date())
        let tabs = SessionStore()
        var running: Set<String> = ["/dev/ttys042"]
        tabs.codexTerminals = { $0 == "/Users/me/term" ? running : [] }
        tabs.pollCodexRollouts()
        spin { tabs.sessions[termId]?.tty != nil }
        check(tabs.sessions[termId]?.tty == "/dev/ttys042" && tabs.session(inWindow: "zsh", tty: "/dev/ttys042")?.id == termId,
              "codex files: a chat in a terminal gets the tab of the one Codex in its folder — it opens, and takes words there")
        check(tabs.sessions[ids[4]].map { $0.tty == nil } != false, "codex files: one in VS Code gets none")
        running = ["/dev/ttys042", "/dev/ttys043"]
        tabs.findCodexTerminals()
        check(tabs.sessions[termId]?.tty == nil, "codex files: two Codex programs in its folder: no tab, never a guess")
        running = ["/dev/ttys042"]
        write([termMeta(twinId)], to: twinPath, modified: Date())
        tabs.pollCodexRollouts()
        spin { tabs.sessions[twinId] != nil }
        check(tabs.sessions[termId]?.tty == nil && tabs.sessions[twinId]?.tty == nil, "codex files: two chats in that folder: no tab for either")
        try? fm.removeItem(atPath: termPath)
        try? fm.removeItem(atPath: twinPath)
    }

    // Connect: only what's new is added
    do {
        let home = base.appendingPathComponent("connect")
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("CLOUDINGBAR_CODEX_HOME", home.path, 1)
        let url = home.appendingPathComponent("hooks.json")
        try Setup.connectCodex()
        var file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = file["hooks"] as! [String: Any]
        hooks["Interrupt"] = nil // as an older version left it
        hooks["Stop"] = [["hooks": [["type": "command", "command": "/usr/local/bin/mine"]]]] + (hooks["Stop"] as! [[String: Any]])
        file["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        check(!Setup.codexConnected, "codex connect: a connection from before lacks Interrupt")
        let before = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["hooks"] as! [String: Any]
        try Setup.connectCodex()
        let after = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any])["hooks"] as! [String: Any]
        let untouched = before.keys.allSatisfy { NSArray(array: before[$0] as! [Any]).isEqual(to: after[$0] as! [Any]) }
        check(untouched && after["Interrupt"] != nil && Setup.codexConnected, "codex connect: Interrupt added, every entry that was there as it was (yours too)")
        let bytes = try Data(contentsOf: url)
        try Setup.connectCodex()
        check(try Data(contentsOf: url) == bytes, "codex connect: nothing to add, the file isn't rewritten")
    }

    // The permission card for apply_patch
    let patch = "*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n-old\n+new\n*** Add File: docs/new.md\n+hi\n*** Delete File: old.txt\n*** End Patch"
    let ap = PendingRequest(Inbound(raw: ["hook_event_name": "PermissionRequest", "session_id": "x", "tool_name": "apply_patch",
                                          "tool_input": ["command": patch], "claude_entrypoint": "codex"]), responder: Responder())!
    check(ap.summary.verb == "Edit" && ap.summary.detail == "App.swift, new.md, old.txt", "codex card: apply_patch names its files")
    check(ap.fullDetail == "Update Sources/App.swift\nAdd docs/new.md\nDelete old.txt" && !ap.canRemember, "codex card: the list with what happens to each; no Always")
    let claudeAsk = PendingRequest(Inbound(raw: ["hook_event_name": "PermissionRequest", "session_id": "x", "tool_name": "Bash", "tool_input": ["command": "ls"]]), responder: Responder())!
    check(claudeAsk.canRemember && claudeAsk.summary.verb == "Run", "claude card: Always stays, Bash as before")
}

// MARK: Safety

do { // settings.json as a link (dotfiles): Connect writes the file it points to, the link stays
    let fm = FileManager.default
    let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!).appendingPathComponent("linked")
    try? fm.removeItem(at: base)
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    let real = base.appendingPathComponent("dotfiles-settings.json"), link = base.appendingPathComponent("settings.json")
    try? "{}".write(to: real, atomically: true, encoding: .utf8)
    try? fm.createSymbolicLink(at: link, withDestinationURL: real)
    let saved = ProcessInfo.processInfo.environment["CLOUDINGBAR_CLAUDE_SETTINGS"]
    setenv("CLOUDINGBAR_CLAUDE_SETTINGS", link.path, 1)
    try? Setup.connect()
    let kept = (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
    check(kept && ((try? String(contentsOf: real, encoding: .utf8)) ?? "").contains("cloudingbar"),
          "settings.json behind a link: written through it, the link kept")
    if let saved { setenv("CLOUDINGBAR_CLAUDE_SETTINGS", saved, 1) } else { unsetenv("CLOUDINGBAR_CLAUDE_SETTINGS") }
}
do { // a Cowork status file with absurd numbers (anyone's repo could bring one): read within bounds, no crash
    let f = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!).appendingPathComponent("cowork-huge.json")
    try? #"{"session":"x","context_tokens":9e18,"context_window":1,"t":1e300,"usage":{"5":[9e18,9e18]}}"#
        .write(to: f, atomically: true, encoding: .utf8)
    let st = Cowork.read(f)
    check(st?.contextTokens == 10_000_000 && st?.contextWindow == 1_000, "Cowork file with absurd numbers: kept in bounds")
}

do { // Connect sets VS Code's wrapper only where none of your own is: absent → ours, ours from before → ours, yours → left
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!).appendingPathComponent("vscode-user")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("settings.json")
    setenv("CLOUDINGBAR_VSCODE_SETTINGS", file.path, 1)
    try? "{\n    \"editor.fontSize\": 13\n}\n".write(to: file, atomically: true, encoding: .utf8)
    if case .done = Setup.wrapVSCodeIfFree() {} else { check(false, "VS Code: no wrapper yet → ours") }
    check(Setup.vscodeWrapped && ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("editor.fontSize"),
          "VS Code: ours set, the rest kept")
    if case .already = Setup.wrapVSCodeIfFree() {} else { check(false, "VS Code: ours already → nothing to do") }
    let own = "{\n    \"claudeCode.claudeProcessWrapper\": \"/Users/me/bin/claude-proxy.sh\"\n}\n"
    try? own.write(to: file, atomically: true, encoding: .utf8)
    if case .others = Setup.wrapVSCodeIfFree() {} else { check(false, "VS Code: your own wrapper → reported") }
    check((try? String(contentsOf: file, encoding: .utf8)) == own, "VS Code: your own wrapper left as it is")
    try? "{\"claudeCode.claudeProcessWrapper\": \"/Users/x/.claudebar/claudebar-wrapper.sh\"}".write(to: file, atomically: true, encoding: .utf8)
    if case .done = Setup.wrapVSCodeIfFree() {} else { check(false, "VS Code: ours from before → replaced") }
    check(Setup.vscodeWrapped, "VS Code: the old wrapper replaced by ours")
    let latin = Data("{\n    // caf\u{E9}\n}\n".data(using: .isoLatin1)!)
    try? latin.write(to: file)
    if case .failed = Setup.wrapVSCodeIfFree() {} else { check(false, "VS Code: settings not in UTF-8 → reported") }
    check((try? Data(contentsOf: file)) == latin, "VS Code: settings not in UTF-8 left as they are")
    unsetenv("CLOUDINGBAR_VSCODE_SETTINGS")
}

do { // a question put shorter for the Touch Bar: only if it keeps what the asking part names
    let repo = "Репозиторий сейчас закрытый. Установщик плагина и ссылка на файл приложения скачивают с GitHub без входа в аккаунт, а из закрытого репозитория так нельзя. Честно проверить установку «как у чужого человека» получится только после публикации. Как делаем?"
    check(ShortQuestion.worth(repo) && !ShortQuestion.worth("Which storage?"), "short form: only for a long question")
    check(ShortQuestion.accept("Публикуем репозиторий, чтобы проверить установку?", for: repo) != nil,
          "short form: the question asked, kept (the quoted words were in the explanation, not the question)")
    check(ShortQuestion.accept("«Публикуем репозиторий?»\n", for: repo) == "Публикуем репозиторий?", "short form: quotes and line ends tidied away")
    check(ShortQuestion.accept("Публикуем репозиторий", for: repo) == nil, "short form: must end as a question")
    check(ShortQuestion.accept("Here is a shorter version of the question you asked me to rewrite, keeping all of its meaning and its tone?", for: repo) == nil,
          "short form: more than 14 words, not used")
    let build = "Сборка падает на старом кэше. Удалить `build/cache` и пересобрать с флагом -O3? Это займёт около 5 минут."
    check(ShortQuestion.keyTokens(in: build).contains("build/cache") && ShortQuestion.keyTokens(in: build).contains("-O3"),
          "short form: code and a flag with a digit in the question are kept tokens")
    check(ShortQuestion.accept("Пересобрать с нуля?", for: build) == nil, "short form: lost the folder and the flag, the original stays")
    check(ShortQuestion.accept("Удалить build/cache и пересобрать с -O3?", for: build) != nil, "short form: keeps them, used")
    let swap = "Should I delete Config.swift and keep only Settings.swift, or the other way round? It decides where the defaults live."
    check(ShortQuestion.keyTokens(in: swap).contains("Config.swift") && ShortQuestion.keyTokens(in: swap).contains("Settings.swift"),
          "short form: a file name's dot doesn't end the sentence")
    check(ShortQuestion.accept("Delete Settings.swift and keep Config.swift?", for: swap) == nil, "short form: the names swapped round, not used")
    check(ShortQuestion.accept("Delete Config.swift, keep Settings.swift?", for: swap) != nil, "short form: the names in their order, used")
    check(ShortQuestion.accept("Should we make the repository public?", for: repo) == nil, "short form: another language than the question's, not used")
}

// MARK: Config

let config = Config()
check(config.effectiveButtons.map(\.label) == ["summary", "compact"], "default buttons")
check(config.questionHoldSeconds == 15, "question hold defaults to 15 s")
check(config.contextWarnPercent == 80, "context warning at 80%")
check(ButtonSpec.label(for: "Проверь последние изменения в {project} на ошибки") == "Проверь последние…", "a long text's name: its first words")
check(ButtonSpec.label(for: "Закоммить изменения в ветке {branch}") == "Закоммить изменения…", "a long text's name: not ending on a short word")

do { // templates move into the menu once: the defaults when it had none of its own, every list, then the keys go
    let saved = try? Data(contentsOf: Config.fileURL)
    try? #"{"templatesEnabled":true,"buttons":[{"label":"go","type":"phrase","value":"Go"}],"profiles":{"app":[{"label":"x","type":"key","value":"esc"}]}}"#
        .write(to: Config.fileURL, atomically: true, encoding: .utf8)
    Config.moveTemplates()
    var c = Config.load()
    check(c.buttons.map(\.label) == ["go"] + Config.oldTemplates.map(ButtonSpec.label(for:))
          && c.buttons.dropFirst().allSatisfy { $0.menu && $0.type == .text } && !c.buttons[0].menu,
          "templates: into the menu, after your own buttons")
    check(c.profiles["app"]?.count == 4 && c.profiles["app"]?.last?.value == Config.oldTemplates.last, "templates: into each profile too")
    Config.moveTemplates()
    c = Config.load()
    let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Config.fileURL))) as? [String: Any]
    check(c.buttons.count == 4 && raw?["templatesEnabled"] == nil, "templates: moved once, the old keys gone")
    try? #"{"templatesEnabled":false}"#.write(to: Config.fileURL, atomically: true, encoding: .utf8)
    Config.moveTemplates()
    check(Config.load().effectiveButtons.map(\.label) == ["summary", "compact"], "templates off, none of its own: nothing added")
    try? #"{"templatesEnabled":false,"templates":["Mine {branch}"],"touchBarShows":["session","templates"]}"#
        .write(to: Config.fileURL, atomically: true, encoding: .utf8)
    Config.moveTemplates()
    c = Config.load()
    check(c.buttons.last?.value == "Mine {branch}" && c.widgetHides == ["menu"] && c.touchBarShows == ["session"],
          "templates off but your own: kept in the menu, the menu hidden")
    try? #"{"templatesEnabled":true,"buttons":[{"label":"broken"}]}"#.write(to: Config.fileURL, atomically: true, encoding: .utf8)
    Config.moveTemplates()
    check(Config.load().buttons.filter { !$0.menu }.map(\.label) == ["summary", "compact"], "templates and only broken buttons: the defaults kept")
    try? #"{"templatesEnabled":true,"templates":["Explain {clipboard}"]}"#.write(to: Config.fileURL, atomically: true, encoding: .utf8)
    Config.moveTemplates()
    check(Config.load().buttons.map(\.label) == ["summary", "compact", "Explain {clipboard}"], "templates and no buttons: the defaults written out first")
    if let saved { try? saved.write(to: Config.fileURL) } else { try? FileManager.default.removeItem(at: Config.fileURL) }
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
