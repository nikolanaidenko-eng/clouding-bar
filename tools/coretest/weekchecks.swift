import Foundation

// The Stats tab's week, from transcripts of the checks' own in a home of the
// checks' own, and a short name asked of a stand-in for Claude Code.

func runStatsChecks() {
    let fm = FileManager.default
    let cal = Calendar.current
    // A Wednesday, the clocks settled: the week has no change of hour in it.
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15))!
    let today = cal.startOfDay(for: now)
    func at(_ daysBack: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: cal.date(byAdding: .day, value: -daysBack, to: today)!)!
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    func reply(_ id: String, _ when: Date, model: String = "claude-opus-5-5", cwd: String = "/x/alpha", tokens: (Int, Int, Int) = (0, 0, 0), tool: String? = nil) -> String {
        let usage: [String: Any] = ["input_tokens": tokens.0, "cache_creation_input_tokens": tokens.1, "cache_read_input_tokens": 999_999, "output_tokens": tokens.2]
        var message: [String: Any] = ["id": id, "model": model, "usage": usage]
        if let tool { message["content"] = [["type": "tool_use", "name": tool]] }
        let line: [String: Any] = ["type": "assistant", "timestamp": iso.string(from: when), "cwd": cwd, "message": message]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: line)) ?? Data(), as: UTF8.self)
    }

    withShortFolder("stats") { dir in
        withAppFolder(dir) { withHome(dir) {
            let projects = dir.appendingPathComponent(".claude/projects")
            func transcript(_ path: String, _ lines: [String], changed: Date) -> URL {
                let url = projects.appendingPathComponent(path)
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.modificationDate: changed], ofItemAtPath: url.path)
                return url
            }

            let empty = StatsBuilder.build(now: now)
            check(empty.isEmpty && empty.headline == "No Claude Code this week" && empty.days.count == 7 && empty.busiest == nil && empty.projects.isEmpty,
                  "stats: no transcripts: an empty week, no crash")
            check(empty.days.last == today && empty.days.first == cal.date(byAdding: .day, value: -6, to: today), "stats: the last seven days, today last")

            let alphaLines = [
                reply("r1", at(0, 14), tokens: (100, 50, 25), tool: "Read"),
                reply("r1", at(0, 14, 1), tokens: (100, 50, 25), tool: "Agent"), // the same reply's next block
                reply("r2", at(0, 14, 2), model: "claude-sonnet-5-5", tokens: (5, 0, 5), tool: "Read"),
                reply("syn", at(0, 14, 3), model: "<synthetic>", tokens: (7777, 0, 0)),
                reply("r3", at(1, 9), tokens: (5, 0, 0)),
                reply("r0", at(8, 9), tokens: (1000, 0, 0)),
                #"{"type":"assistant","timestamp":"not a time","message":{"id":"x","usage":{"input_tokens":5555}}}"#,
                #"{"type":"user","cwd":"/x/alpha","message":{"content":"says \"type\":\"assistant\" in its words"}}"#,
                "not json at all \"type\":\"assistant\"",
            ]
            let alpha = transcript("-x-alpha/s1.jsonl", alphaLines, changed: at(0, 14, 5))
            _ = transcript("-x-beta/s2/subagents/agent-1.jsonl",
                           [reply("sub", at(0, 14, 3), model: "claude-haiku-5-5", cwd: "/x/beta", tokens: (300, 0, 0), tool: "Bash")], changed: at(0, 14, 5))
            let old = transcript("-x-gamma/old.jsonl", [reply("o", at(30, 12), cwd: "/x/gamma", tokens: (77, 0, 0))], changed: at(30, 12))
            _ = transcript("-x-alpha/notes.txt", [reply("t", at(0, 14), tokens: (123, 0, 0))], changed: at(0, 14))

            // A day already on record with more than the transcripts give now.
            let yesterday = DayStats.key(at(1, 9))
            let fuller = [yesterday: DayStats(tokens: 9999, minutes: 999, sessions: ["kept"], longest: 999)]
            try? JSONEncoder().encode(fuller).write(to: dir.appendingPathComponent("stats-days.json"))

            // The limit, on its way up and down today.
            let limits = [(10, 0, 96), (10, 5, 99), (10, 10, 99), (11, 30, 50), (12, 0, 99)]
                .map { #"{"t":\#(Int(at(0, $0.0, $0.1).timeIntervalSince1970)),"p":\#($0.2)}"# }.joined(separator: "\n") + "\n"
            try? limits.write(to: dir.appendingPathComponent("limit-history.jsonl"), atomically: true, encoding: .utf8)

            let week = StatsBuilder.build(now: now)
            check(week.weekTokens == 175 + 10 + 5 + 300, "stats: each reply once; cache reads, stand-in replies and unreadable lines don't count")
            check(week.todayTokens == 175 + 10 + 300, "stats: today's share")
            check(week.grid[6][14] == 485 && week.grid[5][9] == 5, "stats: by day and hour")
            check(week.grid.flatMap { $0 }.reduce(0, +) == week.weekTokens, "stats: an older reply in a recent file isn't this week's")
            check(week.todaySessions == 1 && week.todayProjects == ["alpha"], "stats: today's chats, not its subagents")
            let projects2 = Dictionary(uniqueKeysWithValues: week.projects.map { ($0.name, $0.share) })
            check(abs((projects2["beta"] ?? 0) - 300.0 / 490) < 0.001 && abs((projects2["alpha"] ?? 0) - 190.0 / 490) < 0.001 && projects2["gamma"] == nil,
                  "stats: projects' shares, from the folder in the transcript")
            let models = Dictionary(uniqueKeysWithValues: week.models.map { ($0.name, $0.share) })
            check(abs((models["Opus 5.5"] ?? 0) - 180.0 / 490) < 0.001 && abs((models["Haiku 5.5"] ?? 0) - 300.0 / 490) < 0.001 && models["Sonnet 5.5"] != nil,
                  "stats: models' shares, by the names people use")
            check(week.subagents == 1 && week.tools.first?.name == "Read" && week.tools.first?.count == 2 && !week.tools.contains { $0.name == "Agent" } && week.tools.contains { $0.name == "Bash" },
                  "stats: tools, each block once, subagents apart")
            check(week.activeMinutes == 10, "stats: minutes at work, a span shared by a chat and its subagent once")
            check(week.cellMinutes[6][14] == 5 && week.cellProjects[6][14]["beta"] == 300, "stats: the heat map's hover")
            check(week.activeByProject.map(\.minutes).max() == 10 && week.activeByProject.count == 2, "stats: minutes by project")
            check(week.busiest?.hasPrefix("Busiest: ") == true && week.busiest?.hasSuffix(" afternoons") == true && week.busiest?.contains(" and ") == true, "stats: the two busiest days, and when")

            let k = DayStats.key(at(0, 14))
            check(week.history[k]?.tokens == 485 && week.history[k]?.minutes == 5 && week.history[k]?.sessions == ["s1"] && week.history[k]?.longest == 5,
                  "stats history: a day's numbers, its subagents' tokens but not as a chat")
            check(week.history[k]?.projects == ["alpha": 5, "beta": 5] && week.history[k]?.hours[14] == 485, "stats history: by project and hour")
            check(week.history[DayStats.key(at(8, 9))]?.tokens == 1000 && week.history[DayStats.key(at(30, 12))]?.tokens == 77, "stats history: older days too, from older transcripts")
            check(week.history[yesterday]?.tokens == 9999 && week.history[yesterday]?.sessions == ["kept"], "stats history: a day keeps its fuller record")

            check(week.limitHits == 2 && week.headline == "Hit the 5-hour limit twice this week", "limit: a hit each time it reaches the top, not for each reading")
            check(week.limitHours.contains(6 * 24 + 10) && week.limitHours.contains(6 * 24 + 12) && !week.limitHours.contains(6 * 24 + 11), "limit: hours at 95% or more")
            check(week.todayPeak == 99 && week.cellLimit[6][10] == 99 && week.cellLimit[6][11] == 50, "limit: today's peak, and each hour's")
            check(week.limitLine.count == 5, "limit: the last day's readings")

            // Another reply, and a transcript gone: read again, forgotten, its days kept.
            let longer = alphaLines + [reply("r4", at(0, 14, 4), tokens: (1, 0, 0))]
            _ = transcript("-x-alpha/s1.jsonl", longer, changed: at(0, 14, 6))
            try? fm.removeItem(at: old)
            let again = StatsBuilder.build(now: now)
            check(again.weekTokens == 491 && again.history[k]?.tokens == 486, "stats: a transcript that grew is read again")
            check(again.history[DayStats.key(at(30, 12))]?.tokens == 77, "stats: Claude Code cleans up an old transcript: its day stays on record")
            let cache = (try? String(contentsOf: dir.appendingPathComponent("stats-cache.json"), encoding: .utf8)) ?? ""
            check(!cache.contains("old.jsonl") && cache.contains("s1.jsonl"), "stats: the cache forgets what's gone")
            try? "not json".write(to: dir.appendingPathComponent("stats-cache.json"), atomically: true, encoding: .utf8)
            try? "not json".write(to: dir.appendingPathComponent("stats-days.json"), atomically: true, encoding: .utf8)
            check(StatsBuilder.build(now: now).weekTokens == 491, "stats: its files spoiled: read again from the transcripts")
            try? fm.setAttributes([.modificationDate: at(9, 9)], ofItemAtPath: alpha.path)
            check(StatsBuilder.build(now: now).weekTokens == 300, "stats: a transcript untouched since before the week: not looked at for it")
        } }
    }

    var words = WeekStats()
    check(words.headline == "No Claude Code this week" && words.isEmpty, "stats headline: nothing")
    words.grid[0][0] = 1
    check(words.headline == "Didn't hit the 5-hour limit this week", "stats headline: worked, no limit")
    words.limitHits = 1
    check(words.headline == "Hit the 5-hour limit once this week", "stats headline: once")
    words.limitHits = 5
    check(words.headline == "Hit the 5-hour limit 5 times this week", "stats headline: more")

    var a = DayStats(tokens: 10, minutes: 5, sessions: ["a"], longest: 5)
    a.projects = ["p": 5]
    a.models = ["m": 10]
    a.hours[3] = 10
    var b = DayStats(tokens: 1, minutes: 20, sessions: ["b"], longest: 20)
    b.projects = ["p": 1, "q": 2]
    b.hours[3] = 1
    let both = a.adding(b)
    check(both.tokens == 11 && both.minutes == 25 && both.sessions == ["a", "b"] && both.longest == 20 && both.projects == ["p": 6, "q": 2] && both.hours[3] == 11,
          "stats: two records of a day as one")
    check(DayStats.merged(["d": a], ["d": b, "e": b]) == ["d": both, "e": b], "stats: Claude Code's and Cowork's days together")

    // MARK: A short name, asked of a stand-in for Claude Code

    withShortFolder("namer") { dir in
        withHome(dir) {
            let bin = dir.appendingPathComponent(".local/bin")
            try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let script = bin.appendingPathComponent("claude")
            let heard = dir.appendingPathComponent("heard.txt"), args = dir.appendingPathComponent("args.txt")
            func standIn(_ reply: String) {
                let text = "#!/bin/sh\ncat > '\(heard.path)'\nprintf '%s\\n' \"$@\" > '\(args.path)'\necho \"$CLOUDINGBAR_NAMING\" >> '\(args.path)'\nprintf '%s' '\(reply)'\n"
                try? text.write(to: script, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            }
            standIn(#"{"result":"Short name","is_error":false}"#)
            // Only ever that stand-in: nothing here may reach the real one.
            let found = ShortNamer.executable()?.path
            check(found == script.path, "namer: found in the home folder")
            guard found == script.path else { return }
            check(ShortNamer.askClaude("name this chat") == "Short name", "namer: the answer from its JSON")
            check((try? String(contentsOf: heard, encoding: .utf8)) == "name this chat", "namer: the words on its input")
            let said = (try? String(contentsOf: args, encoding: .utf8)) ?? ""
            check(said.contains("--no-session-persistence") && said.contains("haiku") && said.hasSuffix("1\n"), "namer: no transcript left; its hook told to keep quiet")
            standIn(#"{"result":"Bad","is_error":true}"#)
            check(ShortNamer.askClaude("x") == nil, "namer: an error isn't a name")
            standIn("not json")
            check(ShortNamer.askClaude("x") == nil, "namer: what can't be read isn't a name")
            try? fm.removeItem(at: script)
        }
    }
}
