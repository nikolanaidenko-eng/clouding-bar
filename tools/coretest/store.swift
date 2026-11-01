import Foundation

// What's asked, what a session and the account remember, and SessionStore
// across a restart.

func runRequestChecks() {
    func request(_ tool: String, _ input: [String: Any], event: String = "PermissionRequest", extra: [String: Any] = [:]) -> PendingRequest? {
        let raw: [String: Any] = ["hook_event_name": event, "session_id": "r", "tool_name": tool, "tool_input": input]
        return PendingRequest(Inbound(raw: raw.merging(extra) { $1 }), responder: Responder())
    }
    func decision(_ output: [String: Any]) -> [String: Any]? {
        (output["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    }

    // MARK: What the bar and the card say

    check(request("mcp__github__create_issue", ["title": "Bug"])?.summary.verb == "Use"
          && request("mcp__github__create_issue", ["title": "Bug"])?.summary.detail == "github · create_issue", "summary: an MCP tool by its server and name")
    check(request("Whatever", ["note": "one\ntwo"])?.summary.verb == "Whatever" && request("Whatever", ["note": "one\ntwo"])?.summary.detail == "one ⏎ two",
          "summary: any other tool, its words on one line")
    check(request("Whatever", ["n": 3])?.summary.detail == "", "summary: nothing in words to show")
    check(request("Bash", ["command": "ls\npwd"])?.summary.detail == "ls ⏎ pwd", "summary: a command on one line")
    check(request("Edit", ["file_path": "/a/b/Makefile"])?.summary.detail == "Makefile" && request("Write", [:])?.summary.detail == "",
          "summary: a file by its name, or nothing")
    check(request("NotebookEdit", ["notebook_path": "/x/n.ipynb"])?.summary.detail == "n.ipynb" && request("WebFetch", ["url": "https://a.b"])?.summary.verb == "Fetch"
          && request("WebSearch", ["query": "q"])?.summary.detail == "q", "summary: notebooks, fetches and searches")

    check(request("Bash", ["command": "rm -rf build\nmake"])?.fullDetail == "rm -rf build\nmake", "card: the whole command, so Allow isn't pressed blind")
    check(request("Bash", [:])?.fullDetail == "", "card: a command missing: nothing, no crash")
    let longOld = String(repeating: "o", count: 500)
    let edit = request("Edit", ["file_path": "/a/f.txt", "old_string": longOld, "new_string": "new"])?.fullDetail ?? ""
    check(edit.hasPrefix("/a/f.txt\n− ") && edit.hasSuffix("…\n+ new") && edit.count < 450, "card: an edit's file, what goes (cut at 400) and what comes")
    check(request("Edit", ["file_path": "/a/f.txt"])?.fullDetail == "/a/f.txt", "card: an edit with nothing more: its file")
    check(request("MultiEdit", ["file_path": "/f", "edits": [1, 2]])?.fullDetail == "/f · 2 changes" && request("MultiEdit", ["file_path": "/f", "edits": [1]])?.fullDetail == "/f · 1 change"
          && request("MultiEdit", [:])?.fullDetail == " · 0 changes", "card: how many changes")
    let written = request("Write", ["file_path": "/f", "content": String(repeating: "c", count: 700)])?.fullDetail ?? ""
    check(written.hasPrefix("/f\nccc") && written.hasSuffix("…") && written.count == 3 + 600 + 1, "card: a new file's start")
    let tool = request("mcp__x__y", ["b": ["k": 1], "a": "plain", "c": String(repeating: "z", count: 500)])?.fullDetail ?? ""
    let toolLines = tool.components(separatedBy: "\n")
    check(toolLines[0] == "x · y" && toolLines[1] == "a: plain" && toolLines[2] == #"b: {"k":1}"# && toolLines[3].hasSuffix("…") && toolLines[3].count == 3 + 400 + 1,
          "card: every argument, sorted, each cut at 400")

    // MARK: Patches

    let patch = "*** Begin Patch\n*** Update File: a/old.swift\n*** Move to: b/new.swift\n@@\n-x\n+y\n*** Add File: c.txt\n*** Delete File: d.txt\n*** End Patch"
    let files = PendingRequest.patchFiles(in: patch)
    check(files.map(\.action) == ["Update", "Add", "Delete"] && files.map(\.path) == ["b/new.swift", "c.txt", "d.txt"], "patch: each file, a move by its new path")
    check(PendingRequest.patchFiles(in: "*** Move to: nowhere").isEmpty, "patch: a move with no file before it: nothing, no crash")
    check(PendingRequest.patchFiles(in: "").isEmpty, "patch: empty")
    check(request("apply_patch", ["input": "*** Add File: a\n*** Add File: b"])?.summary.verb == "Write", "patch: all new: Write")
    check(request("apply_patch", ["input": "*** Delete File: a"])?.summary.verb == "Delete", "patch: all gone: Delete")
    let four = request("apply_patch", ["command": "*** Update File: /x/1\n*** Add File: /x/2\n*** Update File: /x/3\n*** Update File: /x/4"])
    check(four?.summary.verb == "Edit" && four?.summary.detail == "1, 2, +2 more", "patch: a few files by name, the rest counted")
    let many = (0..<15).map { "*** Add File: f\($0)" }.joined(separator: "\n")
    let manyDetail = request("apply_patch", ["input": many])?.fullDetail ?? ""
    check(manyDetail.components(separatedBy: "\n").count == 13 && manyDetail.hasSuffix("… +3 more"), "patch: twelve on the card, the rest counted")
    check(request("apply_patch", ["input": "no files here"])?.summary.verb == "apply_patch", "patch: none read: as any other tool")

    // MARK: Questions

    let askInput: [String: Any] = ["questions": [
        ["question": "Which?", "options": [["label": "A", "description": "first"], ["label": "B"], ["no label": 1]], "multiSelect": true],
        ["question": "Sure?", "options": []],
        ["no question": "skipped"],
    ]]
    let asked = request("AskUserQuestion", askInput, event: "PreToolUse")
    check(asked?.kind == .question && asked?.questions.count == 2, "question: read; one with no words isn't one")
    check(asked?.questions[0].options == ["A", "B"] && asked?.questions[0].descriptions == ["first", ""] && asked?.questions[0].multiSelect == true,
          "question: an option needs its label, its description may be missing")
    check(asked?.questions[1].multiSelect == false, "question: one at a time unless it says so")
    check(request("AskUserQuestion", [:], event: "PreToolUse") == nil && request("AskUserQuestion", ["questions": [["no question": 1]]]) == nil,
          "question: none in it: nothing to show")
    if let asked {
        check(asked.current?.text == "Which?" && !asked.answerCurrent("A"), "question: the first answered, one to go")
        check(asked.current?.text == "Sure?" && asked.answerCurrent("Yes") && asked.current == nil, "question: the last one answered: done")
        check(asked.answerCurrent("more"), "question: answered past the end: still done")
        let viaTool = asked.answerOutput()["hookSpecificOutput"] as? [String: Any]
        let answers = (viaTool?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]
        check(viaTool?["hookEventName"] as? String == "PreToolUse" && viaTool?["permissionDecision"] as? String == "allow"
              && answers == ["Which?": "A", "Sure?": "Yes"] && (viaTool?["updatedInput"] as? [String: Any])?["questions"] != nil,
              "question: PreToolUse's answer: allowed, the answers beside what was asked")
    }
    let viaPermission = request("AskUserQuestion", askInput)
    _ = viaPermission?.answerCurrent("A")
    let allowed = viaPermission.map { decision($0.answerOutput()) } ?? nil
    check(allowed?["behavior"] as? String == "allow" && ((allowed?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]) == ["Which?": "A"],
          "question: PermissionRequest's answer, its own shape")

    // MARK: Allow, always, deny

    check(decision(PendingRequest.allow())?["behavior"] as? String == "allow" && decision(PendingRequest.deny())?["behavior"] as? String == "deny",
          "allow and deny")
    let rule: [Any] = [["type": "addRules"]]
    let always = request("Bash", ["command": "ls"], extra: ["permission_suggestions": rule])?.always() ?? [:]
    check((decision(always)?["updatedPermissions"] as? [Any])?.count == 1, "always: remembered the way Claude suggested")
    check(decision(request("Bash", [:])?.always() ?? [:])?["updatedPermissions"] == nil, "always: no suggestion: a plain allow")
    let codexAlways = request("Bash", [:], extra: ["permission_suggestions": rule, "claude_entrypoint": "codex"])
    check(decision(codexAlways?.always() ?? [:])?["updatedPermissions"] == nil && codexAlways?.canRemember == false, "always: Codex refuses a rule: a plain allow, not offered")

    // MARK: Who else answers, and telling two apart

    check(request("Bash", [:], extra: ["claude_entrypoint": "claude-vscode"])?.hostAnswersInParallel == true
          && request("Bash", [:], extra: ["claude_entrypoint": "cli"])?.hostAnswersInParallel == false, "VS Code answers alongside; a terminal waits on the hook")
    let shown = PendingRequest(desktopQuestion: "Which?", options: ["A", "B"], multiSelect: false, sessionId: nil, key: "k")
    check(shown.hostAnswersInParallel && shown.desktopKey == "k" && shown.questions.count == 1, "a question in Claude Desktop's window")
    let permissionShown = PendingRequest(desktopPermission: "Run it?", sessionId: "s1", key: "p")
    check(permissionShown.kind == .permission && permissionShown.toolInput["detail"] as? String == "Run it?", "a permission in Claude Desktop's window, in its words")

    func remote(session: String = "s1", tool: String, input: [String: Any] = [:]) -> PendingRequest? {
        PendingRequest(remote: ClaudeAIChats.Pending(requestId: "req", tool: tool, input: input), sessionId: session) { _ in }
    }
    let far = remote(tool: "AskUserQuestion", input: ["questions": [["question": "Which?", "options": [["label": "A"], ["label": "B"]]]]])
    check(far?.canRemember == false && far?.hostAnswersInParallel == true, "what a Cowork task asks: nothing to remember, it waits on its own")
    if let far {
        check(permissionShown.sameAsk(as: far), "same ask: of the same chat, the same")
        let otherChat = PendingRequest(desktopPermission: "x", sessionId: "s2", key: "p")
        check(!otherChat.sameAsk(as: far), "same ask: another chat's isn't")
        let bareQuestion = PendingRequest(desktopQuestion: "Header words", options: ["B", "A"], multiSelect: false, sessionId: nil, key: "k")
        check(bareQuestion.sameAsk(as: far), "same ask: chat unknown, the same choices")
        check(shown.sameAsk(as: far), "same ask: chat unknown, the same words")
        let different = PendingRequest(desktopQuestion: "Other?", options: ["C"], multiSelect: false, sessionId: nil, key: "k")
        check(!different.sameAsk(as: far), "same ask: neither words nor choices: another")
        let noChoices = PendingRequest(desktopQuestion: "Other?", options: [], multiSelect: false, sessionId: nil, key: "k")
        check(!noChoices.sameAsk(as: far), "same ask: no choices to go by, other words: another")
        let permissionNoChat = PendingRequest(desktopPermission: "x", sessionId: nil, key: "p")
        check(!permissionNoChat.sameAsk(as: far), "same ask: chat unknown, another kind: another")
        if let farPermission = remote(tool: "Bash") { check(permissionNoChat.sameAsk(as: farPermission), "same ask: chat unknown, both permissions") }
    }
    check(remote(tool: "AskUserQuestion") == nil, "what a Cowork task asks: no question in it: nothing to show")

    // MARK: The other end

    var said: [[String: Any]] = []
    let elsewhere = Responder(answered: { said.append($0) })
    elsewhere.pass()
    check(said.isEmpty, "answered elsewhere: pass leaves it waiting there")
    elsewhere.answer(["a": 1])
    elsewhere.answer(["a": 2])
    check(said.count == 1 && said[0]["a"] as? Int == 1, "answered elsewhere: one answer, the first")
    let nowhere = Responder()
    nowhere.hold(5); nowhere.answer([:]); nowhere.pass()
    check(true, "nowhere to answer: nothing happens, no crash")
}

func runSessionChecks() {
    // MARK: What arrives

    check(Inbound(data: Data(#"{"session_id":"s"}"#.utf8))?.sessionId == "s" && Inbound(data: Data("not json".utf8)) == nil && Inbound(data: Data("[1]".utf8)) == nil
          && Inbound(data: Data()) == nil, "inbound: a JSON object, nothing else")
    func inbound(_ raw: [String: Any]) -> Inbound { Inbound(raw: raw) }
    check(inbound(["hook_event_name": "PermissionRequest"]).isRequest && inbound(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"]).isRequest,
          "inbound: a permission and a question wait for an answer")
    check(!inbound(["hook_event_name": "PreToolUse", "tool_name": "Bash"]).isRequest && !inbound(["hook_event_name": "Stop"]).isRequest && !inbound([:]).isRequest,
          "inbound: nothing else does")
    check(inbound(["rate_limits": ["seven_day": ["used_percentage": 12.5, "resets_at": 99]]]).sevenDay?.used == 12.5
          && inbound(["rate_limits": ["seven_day": ["used_percentage": 12.5, "resets_at": 99]]]).sevenDay?.resetsAt == 99, "inbound: the weekly limit")
    check(inbound(["rate_limits": ["five_hour": ["resets_at": "soon"]]]).fiveHour?.used == nil && inbound(["rate_limits": "x"]).fiveHour == nil
          && inbound(["rate_limits": ["five_hour": 3]]).fiveHour == nil, "inbound: a limit of another shape isn't read")
    check(inbound(["claude_pid": 123]).claudePid == 123 && inbound(["claude_pid": "123"]).claudePid == nil, "inbound: the pid, a number")
    check(inbound(["claude_pid": Int64(1) << 40]).claudePid == 0, "inbound: a pid too big for its type comes out as none alive, not a crash")
    check(inbound(["model": ["id": "claude-x"]]).modelId == "claude-x" && inbound(["model": "gpt", "claude_entrypoint": "codex"]).modelId == "gpt"
          && inbound(["model": "gpt"]).modelId == nil, "inbound: the status line's model object; a plain string only Codex's")
    check(inbound(["last_assistant_message": ""]).lastAssistantMessage == nil && inbound(["last_assistant_message": String(repeating: "x", count: AnswerPreview.kept + 5)]).lastAssistantMessage?.count == AnswerPreview.kept,
          "inbound: an empty answer is none, a long one cut")
    check(inbound(["tool_input": "text"]).toolInput.isEmpty && inbound(["context_window": ["used_percentage": 3, "context_window_size": 200]]).contextWindowSize == 200
          && inbound(["cost": ["total_cost_usd": 1.5]]).costUSD == 1.5 && inbound(["message": "m"]).message == "m" && inbound(["tool_response": 7]).toolResponse as? Int == 7,
          "inbound: what else it carries")

    // MARK: Its subagents

    let now = Date()
    func hook(_ s: Session, _ event: String, _ extra: [String: Any], at: Date = now) {
        s.trackAgents(Inbound(raw: ["hook_event_name": event].merging(extra) { $1 }), now: at)
    }
    let s = Session(id: "agents", now: now)
    hook(s, "PreToolUse", ["tool_name": "Agent", "tool_use_id": "u1", "tool_input": ["subagent_type": "Explore", "description": "Look"]])
    hook(s, "PreToolUse", ["tool_name": "Task", "tool_use_id": "u2", "tool_input": [:]])
    check(s.agents.map(\.type) == ["Explore", "general-purpose"] && s.agents[0].task == "Look", "subagents: from the Agent call, by either name")
    hook(s, "PostToolUse", ["tool_name": "Agent"])
    check(s.agents.map(\.type) == ["general-purpose"], "subagents: a call's end with no id to go by: the oldest in the foreground")
    hook(s, "PostToolUse", ["tool_name": "Agent", "tool_use_id": "u2"])
    check(s.agents.isEmpty, "subagents: its end by its id")
    hook(s, "PostToolUse", ["tool_name": "Agent", "tool_use_id": "nobody"])
    check(s.agents.isEmpty, "subagents: an end with nothing running: nothing happens")
    hook(s, "PreToolUse", ["tool_name": "Agent", "tool_use_id": "b1", "tool_input": ["run_in_background": true]])
    hook(s, "PostToolUse", ["tool_name": "Agent", "tool_use_id": "b1", "tool_response": ["agentId": "aaaa1"]])
    check(s.agents.count == 1 && s.agents[0].agentId == "aaaa1", "subagents: in the background it stays past its call, its id from the result")
    hook(s, "PostToolUse", ["tool_name": "Agent"])
    check(s.agents.count == 1, "subagents: an end with no id never takes a background one")
    hook(s, "PreToolUse", ["agent_id": "aaaa1", "tool_name": "Read", "tool_input": ["file_path": "/a/b.swift"]])
    check(s.agents[0].doing == "Read · b.swift", "subagents: what it's doing, from its own hooks")
    hook(s, "Stop", [:])
    check(s.agents.count == 1, "subagents: the turn's end leaves a background one")
    hook(s, "PreToolUse", ["agent_id": "new1", "agent_type": "Plan", "tool_name": "Bash", "tool_input": ["command": "ls"]])
    check(s.agents.count == 2 && s.agents[1].type == "Plan", "subagents: one started before we were watching appears")
    hook(s, "SubagentStop", ["agent_id": "new1"])
    check(s.agents.map(\.agentId) == ["aaaa1"], "subagents: its stop by its id")
    hook(s, "SubagentStart", ["agent_id": "aaaa1"])
    check(s.agents.count == 1, "subagents: started twice is one")
    hook(s, "PostToolUse", ["tool_name": "Read"], at: now.addingTimeInterval(3 * 3600 + 1))
    check(s.agents.isEmpty, "subagents: a background one whose end never came: gone after three hours")
    hook(s, "SubagentStart", ["agent_id": "z"])
    hook(s, "SessionStart", [:])
    check(s.agents.isEmpty, "subagents: a new session starts with none")
    hook(s, "PreToolUse", ["tool_name": "Agent", "tool_use_id": "f1", "tool_input": ["subagent_type": "Plan"]])
    hook(s, "SubagentStart", ["agent_id": "f-id", "agent_type": "Explore"])
    check(s.agents.count == 2, "subagents: a start of another type doesn't claim the call")
    hook(s, "SubagentStart", ["agent_id": "p-id", "agent_type": "Plan"])
    check(s.agents.count == 2 && s.agents[0].agentId == "p-id", "subagents: one of its type does")
    hook(s, "PostToolUseFailure", ["tool_name": "Agent", "tool_use_id": "f1"])
    check(s.agents.map(\.agentId) == ["f-id"], "subagents: a failed call ends it")

    check(Session.launchedId(["agent_id": "abc1"]) == "abc1" && Session.launchedId("started agentId: xyz-123 ok") == "xyz-123"
          && Session.launchedId(#"{"agent_id":"quoted_1"}"#) == "quoted_1" && Session.launchedId("no id here") == nil && Session.launchedId(nil) == nil
          && Session.launchedId("agentId: ab") == nil, "subagents: an id from the call's result, whatever its shape")
    check(Session.summary("Read", ["file_path": "/a/b.txt"]) == "Read · b.txt" && Session.summary("Edit", ["notebook_path": "/n.ipynb"]) == "Edit · n.ipynb",
          "tool in words: a file by its name")
    check(Session.summary("WebFetch", ["url": "https://claude.ai/x?y"]) == "WebFetch · claude.ai" && Session.summary("WebFetch", ["url": "not a url"]) == "WebFetch",
          "tool in words: a page by its host; no host, the tool alone")
    let longLine = String(repeating: "x", count: 60)
    check(Session.summary("Bash", ["command": "\n" + longLine + "\nsecond"]) == "Bash · " + String(repeating: "x", count: 48), "tool in words: a command's first line, cut")
    check(Session.summary("Grep", ["pattern": "p", "command": "c"]) == "Grep · p" && Session.summary("X", [:]) == "X" && Session.summary("X", ["command": "\n"]) == "X",
          "tool in words: in that order; nothing to say, the tool alone")

    // MARK: Its names and numbers

    check(Session.displayName("claude-haiku-4-5") == "Haiku 4.5" && Session.displayName("claude-opus-4-1-20250805") == "Opus 4.1"
          && Session.displayName("gpt-5") == "Gpt 5" && Session.displayName("") == "", "model name: the words people use")
    check(Session.projectKey("/Users/me/my.app") == "-Users-me-my-app" && Session.projectKey("/Users/я/x") == "-Users---x", "project key: as Claude Code names its folders")
    let started = Session(id: "f")
    started.cwd = "/Users/me/my.app/Sources/deep"
    started.transcriptPath = "/x/-Users-me-my-app/t.jsonl"
    check(started.startFolder == "/Users/me/my.app", "start folder: the one its transcripts are named after, however far it went")
    started.transcriptPath = "/x/-Elsewhere/t.jsonl"
    check(started.startFolder == nil, "start folder: not on its way: none")
    started.cwd = "/"
    check(started.startFolder == nil, "start folder: at the top: none")

    let named = Session(id: "n")
    check(named.displayName == "Claude", "chat's name: nothing known")
    named.cwd = "/x/proj"
    check(named.displayName == "proj", "chat's name: its folder")
    named.title = "T"
    named.desktopTitle = "D"
    check(named.displayName == "D", "chat's name: Claude Desktop's over the title")
    named.shortName = "S"
    check(named.displayName == "S", "chat's name: the short one first")
    Session.useShortNames = false
    check(named.displayName == "D", "chat's name: short names off")
    Session.useShortNames = true
    named.customTitle = "Mine"
    check(named.displayName == "D" && named.shownShortName == nil, "chat's name: yours beats the short one")
    named.customTitle = "S"
    named.aiTitle = "T"
    check(named.windowTitles == ["T", "S"], "chat's name: a window told by any of them, each once")

    let context = Session(id: "c")
    check(context.contextPercent(windowOverride: nil) == nil, "context: nothing known")
    context.statusContextPercent = 12
    check(context.contextPercent(windowOverride: nil) == 12, "context: the status line's, with no tokens")
    context.contextTokens = 50_000
    check(context.contextPercent(windowOverride: nil) == 25, "context: tokens of the usual window")
    check(context.contextPercent(windowOverride: 100_000) == 50, "context: tokens of the window set")
    context.model = "claude-opus-5-5[1m]"
    check(context.contextPercent(windowOverride: nil) == 5, "context: a 1M model's window")
    context.model = nil
    context.contextTokens = 300_000
    check(context.contextWindow(override: nil) == 1_000_000, "context: more than the window: it must be the big one")
    context.contextWindowSize = 100_000
    context.contextTokens = 2_000_000
    check(context.contextPercent(windowOverride: nil) == 100, "context: never over 100%")

    let alive = Session(id: "al", now: now)
    check(alive.isAlive(now: now.addingTimeInterval(12 * 3600 - 1)) && !alive.isAlive(now: now.addingTimeInterval(12 * 3600 + 1)), "alive: no pid: for 12 silent hours")
    alive.transcriptChanged = now.addingTimeInterval(3600)
    check(alive.isAlive(now: now.addingTimeInterval(12 * 3600 + 1)), "alive: its transcript changing counts")
    let withPid = Session(id: "p", now: .distantPast)
    withPid.claudePid = getpid()
    check(withPid.isAlive(now: now), "alive: its process runs, however long it's been quiet")
    withPid.claudePid = 1
    check(!withPid.isAlive(now: now), "alive: pid 1 is nobody's Claude")
    let listed = Session(id: "l", now: now)
    listed.entrypoint = "claude-ai"
    check(listed.isAlive(now: now.addingTimeInterval(ClaudeAIChats.recent - 1)) && !listed.isAlive(now: now.addingTimeInterval(ClaudeAIChats.recent + 1)),
          "alive: from claude.ai's list: only while recent")
    let ambient = Session(id: "am", now: now)
    ambient.ambient = true
    check(ambient.isAlive(now: now.addingTimeInterval(CodexRollouts.freshness / 4 - 1)) && !ambient.isAlive(now: now.addingTimeInterval(CodexRollouts.freshness / 4 + 1)),
          "alive: found in Codex's files: at rest, a little while")
    ambient.activity = .work
    check(ambient.isAlive(now: now.addingTimeInterval(CodexRollouts.freshness - 1)) && !ambient.isAlive(now: now.addingTimeInterval(CodexRollouts.freshness + 1)),
          "alive: at work there, longer")

    let turns = Session(id: "t")
    turns.answer = "old"
    turns.activity = .work
    check(turns.answer == nil && turns.finishedAt == nil, "a new turn: the last one's answer is over")
    turns.activity = .sleep
    check(turns.finishedAt != nil, "a turn's end is noted")

    // MARK: The account

    withShortFolder("account") { dir in
        withAppFolder(dir) {
            let a = Account(fileName: "a.json", keepsHistory: false)
            let soon = Date().addingTimeInterval(3700)
            a.apply(used: 40, resetsAt: soon.timeIntervalSince1970)
            check(a.sessionPercent == 40 && a.updatedAt != nil && a.resetLong == "1 h 1 min" && a.resetCountdown == "1:01", "limit: as reported, and when it resets")
            a.resetsAt = Date().addingTimeInterval(59 * 60 + 30)
            check(a.resetLong == "59 min" && a.resetCountdown == "0:59", "limit: under the hour")
            a.resetsAt = Date().addingTimeInterval(-10)
            check(a.resetLong == "0 min" && a.resetCountdown == "0:00", "limit: its time past: never negative")
            let t = Date(timeIntervalSince1970: 2_000_000_000)
            a.resetsAt = t
            check(!a.expireIfNeeded(now: t.addingTimeInterval(-1)) && a.sessionPercent == 40, "limit: until it resets it stands")
            check(a.expireIfNeeded(now: t) && a.sessionPercent == 0 && a.resetsAt == nil, "limit: reset: back to 0, its old number means nothing")
            check(!a.expireIfNeeded(now: t), "limit: reset once")
            a.weekPercent = 30
            a.weekResetsAt = t
            check(a.expireIfNeeded(now: t) && a.weekPercent == 0 && a.weekResetsAt == nil, "week: the same")

            let reported = Date()
            a.apply(used: 70, resetsAt: nil, reported: reported)
            a.apply(used: 10, resetsAt: nil, reported: reported.addingTimeInterval(-60))
            check(a.sessionPercent == 70, "limit: an older report never replaces a newer one")
            a.apply(used: 80, resetsAt: Date().addingTimeInterval(-5).timeIntervalSince1970, reported: reported.addingTimeInterval(1))
            check(a.sessionPercent == 0 && a.resetsAt == nil, "limit: a report whose window has reset by now reads as reset")
            a.apply(used: nil, resetsAt: nil)
            check(a.sessionPercent == 0, "limit: a report with no number keeps the one there")
            a.applyWeek(used: 50, resetsAt: nil, reported: reported)
            a.applyWeek(used: 5, resetsAt: nil, reported: reported.addingTimeInterval(-60))
            check(a.weekPercent == 50, "week: an older report never replaces a newer one")
            a.applyWeek(used: 60, resetsAt: Date().addingTimeInterval(-5).timeIntervalSince1970, reported: reported.addingTimeInterval(1))
            check(a.weekPercent == 0 && a.weekResetsAt == nil, "week: reset by now reads as reset")
            a.weekResetsAt = Date().addingTimeInterval(3600)
            let week = a.weekResetLong ?? ""
            check(week.contains(":") && week.count >= 8, "week: when it resets, in words")
            a.weekResetsAt = nil
            check(a.weekResetLong == nil && Account(fileName: "n.json").resetLong == nil && Account(fileName: "n.json").resetCountdown == nil, "limit: no time known, none shown")

            a.setPlan("pro")
            let later = Date().addingTimeInterval(7200)
            a.apply(used: 33, resetsAt: later.timeIntervalSince1970)
            a.applyWeek(used: 44, resetsAt: later.timeIntervalSince1970)
            let back = Account(fileName: "a.json", keepsHistory: false)
            back.load()
            check(back.sessionPercent == 33 && back.weekPercent == 44 && back.plan == "pro" && abs((back.resetsAt ?? .distantPast).timeIntervalSince(later)) < 1,
                  "limit: across a restart")
            back.apply(used: 99, resetsAt: nil, reported: reported.addingTimeInterval(-3600))
            check(back.sessionPercent == 99 || back.sessionPercent == 33, "limit: reported times come back from the file")
            let expired = Account(fileName: "e.json", keepsHistory: false)
            expired.apply(used: 90, resetsAt: Date().addingTimeInterval(0.2).timeIntervalSince1970)
            usleep(300_000)
            let reread = Account(fileName: "e.json", keepsHistory: false)
            reread.load()
            check(reread.sessionPercent == 0 && reread.resetsAt == nil, "limit: reset while the app was away reads as reset")
            try? "not json".write(to: dir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
            let bad = Account(fileName: "bad.json", keepsHistory: false)
            bad.load()
            check(bad.sessionPercent == nil, "limit: a file that doesn't read: none known, no crash")
            let plain = Account(fileName: "h.json", keepsHistory: true)
            plain.apply(used: 12, resetsAt: nil)
            let history = (try? String(contentsOf: dir.appendingPathComponent("limit-history.jsonl"), encoding: .utf8)) ?? ""
            check(history.contains(#""p":12"#), "limit: Claude's goes into its history")
            let none = Account(fileName: "nh.json", keepsHistory: false)
            none.apply(used: 77, resetsAt: nil)
            let historyAfter = (try? String(contentsOf: dir.appendingPathComponent("limit-history.jsonl"), encoding: .utf8)) ?? ""
            check(!historyAfter.contains(#""p":77"#), "limit: Codex's doesn't")
        }
    }
}

func runStoreChecks() {
    let fm = FileManager.default
    // What earlier checks' stores have to save lands first, not over this.
    RunLoop.main.run(until: Date().addingTimeInterval(2.2))
    withShortFolder("store") { dir in
        withAppFolder(dir) {
            let file = dir.appendingPathComponent("sessions.json")

            // MARK: Saved, and read back

            let first = SessionStore()
            first.apply(Inbound(raw: ["hook_event_name": "UserPromptSubmit", "session_id": "live", "cwd": "/x/proj", "claude_pid": Int(getpid()),
                                      "claude_entrypoint": "cli", "prompt": "SECRET-PROMPT words", "model": ["id": "claude-opus-5-5"]]))
            first.sessions["live"]?.title = "A title"
            first.sessions["live"]?.answer = "SECRET-ANSWER words"
            first.sessions["live"]?.colorIndex = 7
            check(!fm.fileExists(atPath: file.path), "save: not at every event")
            check(spin(4) { fm.fileExists(atPath: file.path) }, "save: within seconds of a change")
            let saved = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            check(saved.contains("A title") && !saved.contains("SECRET-ANSWER") && !saved.contains("SECRET-PROMPT"),
                  "save: a chat's answer and first message are never written down")
            let second = SessionStore()
            second.load()
            let back = second.sessions["live"]
            check(back?.title == "A title" && back?.colorIndex == 7 && back?.cwd == "/x/proj" && back?.entrypoint == "cli" && back?.model == "claude-opus-5-5",
                  "load: the chat as it was")
            check(back?.answer == nil && back?.firstPrompt == nil, "load: what wasn't saved isn't there")

            func write(_ records: [Session.Record]) { try? JSONEncoder().encode(records).write(to: file, options: .atomic) }
            func record(_ id: String, activity: Activity = .sleep, last: Date = Date(), pid: Int32? = nil, entry: String? = nil) -> Session.Record {
                let s = Session(id: id, now: last)
                s.entrypoint = entry
                s.claudePid = pid
                var r = s.record
                r.activity = activity
                return r
            }
            write([record("fresh"), record("old", last: Date().addingTimeInterval(-13 * 3600)),
                   record("waiting", activity: .wait), record("gone", pid: 999_999)])
            let third = SessionStore()
            third.load()
            check(third.sessions["fresh"] != nil, "load: a recent chat")
            check(third.sessions["old"] == nil, "load: silent past 12 hours: gone")
            check(third.sessions["gone"] == nil, "load: its Claude no longer runs: gone")
            check(third.sessions["waiting"]?.activity == .sleep, "load: nothing's still waiting after a restart")

            let hadTurn = SessionStore()
            write([record("turn", activity: .work, pid: getpid(), entry: "cli")])
            hadTurn.load()
            knownBug(hadTurn.sessions["turn"]?.activity == .sleep,
                     "load says \"after a restart nothing is mid-turn\" but only clears .wait, which sessions no longer use: a Claude chat at work when the app quit, whose Stop came while it was away, shows Working until its next event")

            var task = record("cowork-t", entry: "cowork")
            task.coworkSession = "cse_1"
            task.coworkWindow = 500_000
            var notTask = record("cli-t", entry: "cli")
            notTask.coworkSession = "cse_2"
            write([task, notTask])
            let fourth = SessionStore()
            fourth.load()
            check(fourth.sessions["cowork-t"]?.remoteSession == "cse_1" && fourth.sessions["cowork-t"]?.cardWindow == 500_000,
                  "load: a Cowork task's session and window")
            check(fourth.sessions["cli-t"]?.remoteSession == nil, "load: another's is left out")

            try? "not json".write(to: file, atomically: true, encoding: .utf8)
            let fifth = SessionStore()
            fifth.load()
            check(fifth.sessions.isEmpty, "load: a file that doesn't read: no chats, no crash")
            try? fm.removeItem(at: file)
            let sixth = SessionStore()
            sixth.load()
            check(sixth.sessions.isEmpty, "load: no file: no chats")

            // MARK: What the hooks say

            let store = SessionStore()
            var changes = 0
            store.onChange = { changes += 1 }
            func send(_ raw: [String: Any]) { store.apply(Inbound(raw: raw)) }
            send(["rate_limits": ["seven_day": ["used_percentage": 21.0], "five_hour": ["used_percentage": 3.0]]])
            check(store.account.weekPercent == 21 && store.account.sessionPercent == 3 && changes == 1 && store.sessions.isEmpty, "a limit with no session: the account's, nothing more")
            send(["session_id": "nobody", "context_window": ["used_percentage": 5]])
            check(store.sessions["nobody"] == nil, "a status line for a chat not known: no chat from it")
            send(["hook_event_name": "SessionStart", "session_id": "s", "cwd": "/x/s"])
            send(["session_id": "s", "context_window": ["used_percentage": 5, "context_window_size": 300], "cost": ["total_cost_usd": 2.5], "claude_effort": "high"])
            let s = store.sessions["s"]
            check(s?.statusContextPercent == 5 && s?.contextWindowSize == 300 && s?.costUSD == 2.5 && s?.effort == "high", "a status line adds its numbers to a known chat")
            send(["hook_event_name": "Notification", "session_id": "s", "message": "Claude needs your permission to use Bash"])
            check(s?.waitingNotice == true, "an older Claude Code's notification, by its words")
            send(["hook_event_name": "Stop", "session_id": "s"])
            check(s?.waitingNotice == false && s?.activity == .sleep, "Stop: it isn't waiting any more")
            send(["hook_event_name": "Notification", "session_id": "s", "message": "Claude is idle"])
            check(s?.waitingNotice == false, "a notification of anything else: no")
            send(["hook_event_name": "Notification", "session_id": "s", "notification_type": "idle_prompt", "message": "permission"])
            check(s?.waitingNotice == false, "a notification's type says, over its words")
            send(["hook_event_name": "Notification", "session_id": "s", "notification_type": "elicitation_dialog"])
            check(s?.waitingNotice == true, "a question in a dialog")
            send(["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "  /clear  "])
            check(s?.firstPrompt == nil && s?.waitingNotice == false, "a /command isn't a chat's first message")
            send(["hook_event_name": "UserPromptSubmit", "session_id": "s", "agent_id": "a", "prompt": "inside a subagent"])
            check(s?.firstPrompt == nil, "nor a subagent's")
            send(["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": String(repeating: "p", count: 700)])
            check(s?.firstPrompt?.count == 600 && s?.firstPromptAt != nil, "the first message, cut")
            send(["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "later"])
            check(s?.firstPrompt?.hasPrefix("ppp") == true, "and only the first")
            send(["hook_event_name": "PreToolUse", "session_id": "s", "agent_id": "a", "tool_name": "Read", "tool_input": ["file_path": "/sub/x"]])
            check(s?.workPath == nil, "where it works: not where a subagent looks")
            send(["hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Read", "tool_input": ["file_path": "relative/x"]])
            check(s?.workPath == nil, "where it works: not a relative path")
            send(["hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "NotebookEdit", "tool_input": ["notebook_path": "/w/n.ipynb"]])
            check(s?.workPath == "/w/n.ipynb", "where it works: the file it touched")
            send(["hook_event_name": "Stop", "session_id": "s", "agent_id": "a", "last_assistant_message": "from the subagent"])
            check(s?.answer == nil, "a subagent's last words aren't the chat's answer")
            send(["hook_event_name": "Stop", "session_id": "s", "last_assistant_message": "done it"])
            check(s?.answer == "done it", "the chat's answer")
            send(["hook_event_name": "StopFailure", "session_id": "s", "last_assistant_message": "API error"])
            check(s?.answer == "done it" && s?.activity == .sleep, "a turn ended on an error: asleep, the error isn't its answer")
            send(["hook_event_name": "SomethingNew", "session_id": "s"])
            check(store.sessions["s"] != nil, "an event not known changes nothing")
            send(["hook_event_name": "SessionEnd", "session_id": "s"])
            check(store.sessions["s"] == nil, "SessionEnd: gone")
            send(["hook_event_name": "SessionEnd", "session_id": "never"])
            check(store.sessions["never"] == nil, "SessionEnd of a chat not known: nothing")

            // A new chat gets the colour least in use.
            let colors = SessionStore()
            for i in 0..<Session.colors.count { colors.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "c\(i)"])) }
            check(Set(colors.sessions.values.map(\.colorIndex)).count == Session.colors.count, "colours: each chat its own, while they last")
            colors.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "extra"]))
            check(colors.sessions["extra"]?.colorIndex == 0, "colours: all taken: from the first again")

            // MARK: Claude Desktop's chats

            let desktop = SessionStore()
            func inApp(_ id: String, title: String?, page: String? = nil) {
                desktop.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": id, "claude_entrypoint": "claude-desktop"]))
                desktop.sessions[id]?.title = title
                desktop.sessions[id]?.desktopChat = page
            }
            inApp("d1", title: "Fix the widget")
            inApp("d2", title: "Write the docs")
            inApp("d3", title: "Known by page", page: "/chat/3")
            check(desktop.session(inDesktop: nil)?.id == nil, "desktop: no title, no page: can't tell")
            check(desktop.session(inDesktop: "✳ Fix the widget")?.id == "d1", "desktop: by its title, an emoji before it")
            check(desktop.session(inDesktop: "Fix the widget and more words")?.id == "d1", "desktop: one the start of the other")
            check(desktop.session(inDesktop: "Known by page") == nil, "desktop: one known by its page is that page alone")
            check(desktop.session(inDesktop: "Nothing like it") == nil, "desktop: none close")
            check(desktop.session(inDesktop: "whatever", chat: "/chat/3")?.id == "d3", "desktop: by its page first")
            inApp("d4", title: "Fix the widget")
            check(desktop.session(inDesktop: "Fix the widget") == nil, "desktop: two as close: neither (words could land in the wrong one)")
            desktop.link(desktop.sessions["d1"]!, desktopChat: "/chat/1", title: "✳ Fix the widget")
            check(desktop.sessions["d1"]?.desktopTitle == "Fix the widget" && desktop.session(inDesktop: "Fix the widget")?.id == "d4", "desktop: linked, it's out of the running by title")
            desktop.link(desktop.sessions["d2"]!, desktopChat: "/chat/1", title: nil)
            check(desktop.sessions["d1"]?.desktopChat == nil && desktop.sessions["d1"]?.desktopTitle == nil && desktop.sessions["d2"]?.desktopChat == "/chat/1",
                  "desktop: a page is one chat's: the other lets go of it")
            check(desktop.focus(windowTitle: nil, sticky: ["d4"], desktop: true)?.id == "d4", "desktop: can't tell: the one followed")
            check(desktop.inFront(windowTitle: nil, desktop: true) == Set(desktop.sessions.keys), "desktop: its page not read: any of its own counts as in front")
            check(desktop.inFront(windowTitle: nil, desktop: true, desktopChat: "/chat/none").isEmpty, "desktop: another page in front: none of them")
            desktop.apply(desktop: ["d4": DesktopSessions.Entry(local: "local_1", bridge: "cse_9")])
            check(desktop.sessions["d4"]?.desktopLocal == "local_1" && desktop.sessions["d4"]?.remoteSession == "cse_9" && desktop.sessions["d2"]?.desktopLocal == nil,
                  "desktop: its own ids for its chats")

            check(SessionStore.titleScore("A b", "a B") == 3 && SessionStore.titleScore("", "x") == 0 && SessionStore.titleScore("✳", "x") == 0, "titles: the same but for case; nothing's like nothing")
            check(SessionStore.titleScore("Fix the wid…", "Fix the widget") == 2 && SessionStore.titleScore("Fix the widget", "Fix the wid…") == 2, "titles: cut short with …")
            check(SessionStore.titleScore("Fix", "Fix the widget") == 0, "titles: one word at its start says little")
            check(SessionStore.titleScore("Fix widget fast now", "Widget fix fast") == 1, "titles: mostly the same words")
            check(SessionStore.titleScore("alpha beta gamma delta", "alpha beta other words") == 0, "titles: too few in common")
            check(SessionStore.sameTitle("A b c", "a b c d") && !SessionStore.sameTitle("A b", "c d"), "titles: the same chat")

            // MARK: Who's gone

            let prune = SessionStore()
            func at(_ id: String, entry: String, pid: Int32? = nil, cwd: String? = nil, last: Date = Date()) {
                prune.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": id, "cwd": cwd ?? "/x", "claude_entrypoint": entry]), now: last)
                prune.sessions[id]?.claudePid = pid
            }
            check(prune.prune().isEmpty, "prune: nothing to drop")
            at("older", entry: "cli", pid: getpid(), last: Date().addingTimeInterval(-60))
            at("newer", entry: "cli", pid: getpid())
            at("vs", entry: "claude-vscode", pid: 1)
            check(prune.prune().contains("older") && prune.sessions["newer"] != nil, "prune: one Claude runs one chat: the older on its process is gone")
            let quiet = SessionStore()
            quiet.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "q"]), now: Date().addingTimeInterval(-13 * 3600))
            check(quiet.prune() == ["q"] && quiet.sessions.isEmpty, "prune: silent too long")

            let codex = SessionStore()
            codex.codexTerminalFolders = { ["/tmp"] }
            func ambient(_ id: String, _ cwd: String) {
                codex.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": id, "cwd": cwd, "claude_entrypoint": "codex"]))
                codex.sessions[id]?.ambient = true
                codex.sessions[id]?.codexHost = "Terminal"
            }
            ambient("open", "/tmp")
            ambient("shut", "/var/empty")
            codex.codexTerminalFolders = { [Tty.realPath("/tmp")] }
            check(codex.prune() == ["shut"] && codex.sessions["open"] != nil, "prune: a Codex in a terminal: gone once none runs in its folder")
            ambient("elsewhere", "/var/empty")
            codex.codexTerminalFolders = { ["/some/other/folder"] }
            check(codex.prune().isEmpty, "prune: one runs in a folder no chat has: it may be any chat's, all stay")
            codex.codexFoldersOpen = { $0.filter { $0 == "/tmp" } }
            codex.markOpenCodexChats()
            check(codex.sessions["open"]?.codexWindowOpen == true && codex.sessions["elsewhere"]?.codexWindowOpen == false, "Codex: words only while one runs in its folder")

            // MARK: Which chat a window is

            let front = SessionStore()
            front.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "one", "cwd": "/x/alpha"]))
            front.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "two", "cwd": "/x/beta"]))
            front.sessions["one"]?.title = "Cut it — short"
            check(front.session(inWindow: "Cut it — short — alpha")?.id == "one", "window: a name with a dash in it, whole")
            check(front.session(inWindow: nil) == nil, "window: no title: can't tell")
            check(front.session(inWindow: "Unrelated") == nil, "window: nothing it names")
            front.sessions["two"]?.title = "Cut it — short"
            check(front.session(inWindow: "Cut it — short") == nil, "window: two by that name: neither")
            front.sessions["two"]?.title = "Long title of two"
            check(front.session(inWindow: "Long title of…")?.id == "two", "window: a tab's name cut short")
            check(front.session(inWindow: "file.txt — beta", naming: true)?.id == "two", "window: naming, the only chat of that folder")
            front.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "three", "cwd": "/y/beta"]))
            check(front.session(inWindow: "file.txt — beta", naming: true) == nil, "window: naming, another of that folder could be the one open: none")
            check(front.session(inWindow: "file.txt — beta") == nil, "window: two of that folder, a file in front: can't tell")
            let listed = SessionStore()
            listed.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "list", "cwd": "/x/alpha", "claude_entrypoint": "cowork"]))
            check(listed.session(inWindow: "alpha") == nil && listed.focus(windowTitle: "alpha", sticky: [])?.id == "list",
                  "window: a chat from a list lives in Claude Desktop, never in this window (only the last resort)")
            let ambientChat = SessionStore()
            ambientChat.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "a", "cwd": "/x/alpha"]))
            ambientChat.sessions["a"]?.ambient = true
            check(ambientChat.session(inWindow: "alpha") == nil && ambientChat.inFront(windowTitle: "alpha") == ["a"],
                  "window: found only in Codex's files: never typed into, but a word can count it as in front")

            // MARK: Signed out, and other lists

            let signedOut = SessionStore()
            signedOut.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "ai", "claude_entrypoint": "claude-ai"]))
            signedOut.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "local", "claude_entrypoint": "cli"]))
            var told = 0
            signedOut.onChange = { told += 1 }
            signedOut.forgetClaudeAI()
            check(signedOut.sessions["ai"] == nil && signedOut.sessions["local"] != nil && told == 1, "signed out: claude.ai's chats go, the others stay")
            signedOut.forgetClaudeAI()
            check(told == 1, "signed out again: nothing to tell")
            signedOut.apply(Inbound(raw: ["hook_event_name": "SessionStart", "session_id": "t", "claude_entrypoint": "cli"]))
            signedOut.apply(terminalBridges: ["t": "cse_2"], checked: ["t", "local"])
            check(signedOut.sessions["t"]?.remoteSession == "cse_2" && signedOut.sessions["local"]?.remoteSession == nil, "Remote Control: from Claude Code's record")
            signedOut.apply(terminalBridges: [:], checked: ["t"])
            check(signedOut.sessions["t"]?.remoteSession == nil, "Remote Control: off again")
            signedOut.markSent("t")
            check(signedOut.sessions["t"]?.sentAt == nil, "words sent: only chats from a list wait on one")
            signedOut.keepLocalCowork("not-a-task")
            check(signedOut.sessions["not-a-task"] == nil, "words held: only for a local task")
            signedOut.applyCodexServerLimits(CodexRollout.Limits(fiveHour: nil, week: nil, plan: "plus"))
            check(signedOut.codexAccount.plan == "plus", "Codex's server: its plan")
        }
    }
}
