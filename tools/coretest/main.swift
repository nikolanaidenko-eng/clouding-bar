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
store.sessions["a2"]?.title = "Сайт ordermeshop portfolio"
check(focus("Status bar — GitHub") == "a", "VS Code's chat tab: the chat by its title")
check(focus("Сайт ordermeshop portfolio — GitHub — Visual Studio Code", ["a"]) == "a2", "the title beats the one followed")
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
    let mac = task.appendingPathComponent("mnt/24H")
    try? FileManager.default.removeItem(at: task)
    try? FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
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
    store.apply(cowork: Cowork.Status(session: "c1", project: "24H", contextTokens: 1000, contextWindow: 200_000,
                                      model: nil, time: Date(), title: "Bots landing"))
    store.apply(cowork: Cowork.Status(session: "c2", project: "24H", contextTokens: 9000, contextWindow: 200_000,
                                      model: nil, time: Date().addingTimeInterval(-60), title: "Mail drafts"))
    check(store.sessions["cowork-c1"]?.displayName == "Bots landing" && store.sessions["cowork-c2"]?.displayName == "Mail drafts",
          "two Cowork tasks in one folder, told apart by name")
    check(Cowork.window(model: "claude-sonnet-5-5") == 500_000 && Cowork.window(model: "claude-opus-5-5[1m]") == 1_000_000
          && Cowork.window(model: "claude-haiku-5-5") == 200_000, "Cowork's window: 500k, 1M for [1m], 200k for Haiku")
    check(store.focus(windowTitle: "Claude", sticky: [], desktop: true)?.id == "cowork-c1"
          && store.focus(windowTitle: "Claude", sticky: ["cowork-c2"], desktop: true)?.id == "cowork-c2"
          && store.focus(windowTitle: "Claude", sticky: ["a"], desktop: true)?.id == "cowork-c1",
          "Claude Desktop in front: its chats, the picked one or the latest")
    check(SessionStore.sameTitle("⚡ Threads: поиск лидов", "threads: поиск лидов")
          && SessionStore.sameTitle("Fix the landing page for the bots, and check", "Fix the landing page for the bots, and…")
          && !SessionStore.sameTitle("Bots", "Bots landing")
          && SessionStore.sameTitle("Cowork task summary", "Cowork task summary export")
          && SessionStore.titleScore("Threads: сбор постов за неделю", "Сбор постов Threads") == 1,
          "titles: emoji, case and \"…\" aside; Claude Desktop's shorter name")
    check(store.focus(windowTitle: "⚡ Mail drafts", sticky: ["cowork-c1"], desktop: true)?.id == "cowork-c2",
          "Claude Desktop shows a chat by its title: that one, over the picked one")
    store.link(store.sessions["cowork-c1"]!, desktopChat: "/chat/aaa", title: "⚡ Threads: поиск лидов")
    check(store.sessions["cowork-c1"]?.displayName == "Threads: поиск лидов"
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
do { // ☁️ in Claude's words just now: Cloud waves back; old replies and code don't count
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]!)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func waved(_ blocks: String, at date: Date) -> Bool {
        let file = dir.appendingPathComponent("wave-\(UUID().uuidString).jsonl")
        let line = #"{"type":"assistant","timestamp":"\#(f.string(from: date))","message":{"id":"w1","model":"claude-opus-5-5","content":\#(blocks),"usage":{"input_tokens":1,"output_tokens":1}}}"#
        try? (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        let watcher = TranscriptWatcher()
        var got: [TranscriptWatcher.Update] = []
        let done = DispatchSemaphore(value: 0)
        watcher.poll([(id: "w", path: file.path)]) { got = $0; done.signal() }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return got.first?.waved == true
    }
    let words = #"[{"type":"text","text":"Done ☁️"}]"#
    let code = #"[{"type":"tool_use","name":"Write","input":{"content":"// ☁️ hello"}}]"#
    check(waved(words, at: Date()) && !waved(words, at: Date().addingTimeInterval(-600)) && !waved(code, at: Date()),
          "☁️ in a fresh reply's words waves; an old reply or code doesn't")
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

// MARK: Config

let config = Config()
check(config.effectiveButtons.map(\.label) == ["summary", "compact"], "default buttons")
check(config.questionHoldSeconds == 15, "question hold defaults to 15 s")
check(config.contextWarnPercent == 80, "context warning at 80%")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
