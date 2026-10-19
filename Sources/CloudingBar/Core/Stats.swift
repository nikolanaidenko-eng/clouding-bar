import Foundation

/// The week in numbers for the Stats tab, from the local Claude Code
/// transcripts (~/.claude/projects) and the limit history. Tokens count
/// fresh input, cache writes and output — not cache reads, which repeat
/// every turn and would drown everything else. Each reply counts once:
/// Claude Code writes it as several lines (one per block), each with the
/// reply's usage.
struct WeekStats {
    /// The last 7 days, oldest first (start of each day).
    var days: [Date] = []
    /// Tokens per day and hour: grid[day][hour].
    var grid: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    /// Hours (day * 24 + hour) when the 5-hour limit was at 95% or more.
    var limitHours: Set<Int> = []
    var limitHits = 0
    /// Biggest projects by tokens, with their share (0…1); the rest as "other".
    var projects: [(name: String, share: Double)] = []
    /// The same for models ("Opus 5.5", "Sonnet 5.5").
    var models: [(name: String, share: Double)] = []
    var busiest: String?
    var todaySessions = 0
    var todayProjects: [String] = []
    var todayPeak: Double?
    var weekTokens = 0
    var todayTokens = 0
    /// Minutes with Claude replying (5-minute spans), all and by project.
    var activeMinutes = 0
    var activeByProject: [(name: String, minutes: Int)] = []
    /// The tools Claude used most this week (subagents' too), and how many
    /// subagents it started.
    var tools: [(name: String, count: Int)] = []
    var subagents = 0
    /// The 5-hour limit over the last 24 hours.
    var limitLine: [LimitHistory.Sample] = []
    /// Per day and hour, for the heat map's hover: minutes Claude worked,
    /// tokens by project, and the highest the 5-hour limit got.
    var cellMinutes: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    var cellProjects: [[[String: Int]]] = Array(repeating: Array(repeating: [:], count: 24), count: 7)
    var cellLimit: [[Double?]] = Array(repeating: Array(repeating: nil, count: 24), count: 7)

    var isEmpty: Bool { grid.allSatisfy { $0.allSatisfy { $0 == 0 } } }

    var headline: String {
        switch limitHits {
        case 0: return isEmpty ? "No Claude Code this week" : "Didn't hit the 5-hour limit this week"
        case 1: return "Hit the 5-hour limit once this week"
        case 2: return "Hit the 5-hour limit twice this week"
        default: return "Hit the 5-hour limit \(limitHits) times this week"
        }
    }
}

enum StatsBuilder {
    /// Per-file results, so a transcript is parsed again only when it grows.
    private struct FileStats: Codable {
        static let format = 2
        var v: Int
        var size: UInt64
        var mtime: Double
        var project: String?
        var isSubagent: Bool
        /// Unix hour → tokens.
        var hours: [String: Int]
        /// Unix hour → model → tokens.
        var models: [String: [String: Int]]
        /// Unix hour → tool → uses.
        var tools: [String: [String: Int]]
        /// 5-minute spans (unix seconds / 300) with a reply.
        var spans: [Int]
    }

    private static var cacheURL: URL { Config.directory.appendingPathComponent("stats-cache.json") }
    private static let assistantMark = Data(#""type":"assistant""#.utf8)

    /// Slow (reads transcripts): call off the main thread.
    static func build(now: Date = Date()) -> WeekStats {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -6, to: today)!
        var stats = WeekStats()
        stats.days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }

        var cache = (try? JSONDecoder().decode([String: FileStats].self, from: Data(contentsOf: cacheURL))) ?? [:]
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var seen = Set<String>()
        var projectTokens: [String: Int] = [:]
        var modelTokens: [String: Int] = [:]
        var toolUses: [String: Int] = [:]
        var spans = Set<Int>()
        var projectSpans: [String: Set<Int>] = [:]
        var todayFiles = 0
        var todayProjects = Set<String>()
        let firstHour = Int(start.timeIntervalSince1970 / 3600)

        /// The day (0…6) an hour falls on, or nil outside the week.
        func day(_ hour: Int) -> (d: Int, h: Int)? {
            guard hour >= firstHour else { return nil }
            let date = Date(timeIntervalSince1970: Double(hour) * 3600)
            let d = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: date)).day ?? -1
            return (0..<7).contains(d) ? (d, cal.component(.hour, from: date)) : nil
        }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let mtime = values.contentModificationDate, mtime >= start,
                      let size = values.fileSize.map(UInt64.init) else { continue }
                let path = url.path
                seen.insert(path)
                var file = cache[path]
                if file == nil || file!.v != FileStats.format || file!.size != size || file!.mtime != mtime.timeIntervalSince1970 {
                    file = parse(url, size: size, mtime: mtime)
                    cache[path] = file
                }
                guard let file else { continue }
                let project = file.project ?? "other"
                var activeToday = false
                for (key, tokens) in file.hours {
                    guard let hour = Int(key), let at = day(hour) else { continue }
                    stats.grid[at.d][at.h] += tokens
                    stats.cellProjects[at.d][at.h][project, default: 0] += tokens
                    projectTokens[project, default: 0] += tokens
                    stats.weekTokens += tokens
                    if at.d == 6 { activeToday = true; stats.todayTokens += tokens }
                }
                for (key, byModel) in file.models {
                    guard let hour = Int(key), day(hour) != nil else { continue }
                    for (m, t) in byModel { modelTokens[m, default: 0] += t }
                }
                for (key, byTool) in file.tools {
                    guard let hour = Int(key), day(hour) != nil else { continue }
                    for (tool, n) in byTool { toolUses[tool, default: 0] += n }
                }
                for span in file.spans where day(span / 12) != nil {
                    spans.insert(span)
                    projectSpans[project, default: []].insert(span)
                }
                if activeToday && !file.isSubagent {
                    todayFiles += 1
                    if let p = file.project { todayProjects.insert(p) }
                }
            }
        }
        // Forget files that are gone or too old.
        cache = cache.filter { seen.contains($0.key) }
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }

        stats.projects = shares(projectTokens)
        stats.models = shares(modelTokens)
        stats.activeMinutes = spans.count * 5
        for span in spans {
            if let at = day(span / 12) { stats.cellMinutes[at.d][at.h] += 5 }
        }
        stats.activeByProject = projectSpans.map { (name: $0.key, minutes: $0.value.count * 5) }
            .sorted { $0.minutes > $1.minutes }.prefix(3).map { $0 }
        stats.subagents = (toolUses["Agent"] ?? 0) + (toolUses["Task"] ?? 0)
        stats.tools = toolUses.filter { $0.key != "Agent" && $0.key != "Task" }
            .sorted { $0.value > $1.value }.prefix(5).map { (name: $0.key, count: $0.value) }

        // The limit: hours at 95%+, and how many times it hit the top.
        var wasAtLimit = false
        var lastTime = Date.distantPast
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        for s in LimitHistory.load(since: start) {
            let d = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: s.time)).day ?? -1
            if (0..<7).contains(d) {
                let h = cal.component(.hour, from: s.time)
                if s.percent >= 95 { stats.limitHours.insert(d * 24 + h) }
                stats.cellLimit[d][h] = max(stats.cellLimit[d][h] ?? 0, s.percent)
            }
            let atLimit = s.percent >= 99
            if atLimit && (!wasAtLimit || s.time.timeIntervalSince(lastTime) > 3600) { stats.limitHits += 1 }
            wasAtLimit = atLimit
            lastTime = s.time
            if d == 6 { stats.todayPeak = max(stats.todayPeak ?? 0, s.percent) }
            if s.time >= dayAgo { stats.limitLine.append(s) }
        }

        stats.todaySessions = todayFiles
        stats.todayProjects = todayProjects.sorted()
        stats.busiest = busiest(stats)
        return stats
    }

    /// The top three by share, and the rest as "other".
    private static func shares(_ totals: [String: Int]) -> [(name: String, share: Double)] {
        let total = totals.values.reduce(0, +)
        guard total > 0 else { return [] }
        let sorted = totals.sorted { $0.value > $1.value }
        var list = sorted.prefix(3).map { (name: $0.key, share: Double($0.value) / Double(total)) }
        let rest = sorted.dropFirst(3).reduce(0) { $0 + $1.value }
        if rest > 0 { list.append((name: "other", share: Double(rest) / Double(total))) }
        return list
    }

    private static func parse(_ url: URL, size: UInt64, mtime: Date) -> FileStats? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var file = FileStats(v: FileStats.format, size: size, mtime: mtime.timeIntervalSince1970, project: nil,
                             isSubagent: url.path.contains("/subagents/"), hours: [:], models: [:], tools: [:], spans: [])
        var counted = Set<String>()
        var spans = Set<Int>()
        for line in data.split(separator: 0x0A) {
            if file.project == nil, let r = line.range(of: Data(#""cwd":""#.utf8)) {
                let rest = line[r.upperBound...]
                if let end = rest.firstIndex(of: UInt8(ascii: "\"")),
                   let cwd = String(data: rest[rest.startIndex..<end], encoding: .utf8) {
                    file.project = URL(fileURLWithPath: cwd).lastPathComponent
                }
            }
            guard line.range(of: assistantMark) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let stamp = obj["timestamp"] as? String, let date = iso.date(from: stamp),
                  let message = obj["message"] as? [String: Any],
                  message["model"] as? String != "<synthetic>" else { continue }
            let hour = String(Int(date.timeIntervalSince1970 / 3600))
            spans.insert(Int(date.timeIntervalSince1970 / 300))
            // Its tool calls (each line carries its own block).
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String { file.tools[hour, default: [:]][name, default: 0] += 1 }
            }
            // Its usage, once per reply.
            guard let usage = message["usage"] as? [String: Any] else { continue }
            if let id = message["id"] as? String {
                guard !counted.contains(id) else { continue }
                counted.insert(id)
            }
            func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            let tokens = n("input_tokens") + n("cache_creation_input_tokens") + n("output_tokens")
            file.hours[hour, default: 0] += tokens
            if let model = message["model"] as? String {
                file.models[hour, default: [:]][Session.displayName(model), default: 0] += tokens
            }
        }
        file.spans = spans.sorted()
        return file
    }

    /// "Busiest: Tuesday and Thursday afternoons"
    private static func busiest(_ s: WeekStats) -> String? {
        let totals = s.grid.map { $0.reduce(0, +) }
        let ranked = totals.indices.filter { totals[$0] > 0 }.sorted { totals[$0] > totals[$1] }.prefix(2)
        guard !ranked.isEmpty else { return nil }
        var parts = [0, 0, 0, 0] // morning, afternoon, evening, night
        for d in ranked {
            for h in 0..<24 {
                let i = (5..<12).contains(h) ? 0 : (12..<17).contains(h) ? 1 : (17..<22).contains(h) ? 2 : 3
                parts[i] += s.grid[d][h]
            }
        }
        let part = parts.indices.max { parts[$0] < parts[$1] }!
        let names = ["morning", "afternoon", "evening", "night"]
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEEE"
        let days = ranked.sorted().map { fmt.string(from: s.days[$0]) }
        let plural = days.count > 1 ? (part == 3 ? "nights" : names[part] + "s") : names[part]
        return "Busiest: " + days.joined(separator: " and ") + " " + plural
    }
}
