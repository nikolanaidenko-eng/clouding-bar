import Foundation

/// The week in numbers for the Stats tab, from the local Claude Code
/// transcripts (~/.claude/projects) and the limit history. Tokens count
/// fresh input, cache writes and output — not cache reads, which repeat
/// every turn and would drown everything else.
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
    var busiest: String?
    var todaySessions = 0
    var todayProjects: [String] = []
    var todayPeak: Double?

    var isEmpty: Bool { grid.allSatisfy { $0.allSatisfy { $0 == 0 } } }

    var headline: String {
        switch limitHits {
        case 0: return isEmpty ? "No Claude Code this week" : "Didn't hit the limit this week"
        case 1: return "Hit the limit once this week"
        case 2: return "Hit the limit twice this week"
        default: return "Hit the limit \(limitHits) times this week"
        }
    }
}

enum StatsBuilder {
    /// Per-file results, so a transcript is parsed again only when it grows.
    private struct FileStats: Codable {
        var size: UInt64
        var mtime: Double
        var project: String?
        /// Unix hour → tokens.
        var hours: [String: Int]
        var isSubagent: Bool
    }

    private static var cacheURL: URL { Config.directory.appendingPathComponent("stats-cache.json") }
    private static let usageMark = Data(#""usage""#.utf8)

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
        var todayFiles = 0
        var todayProjects = Set<String>()

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let mtime = values.contentModificationDate, mtime >= start,
                      let size = values.fileSize.map(UInt64.init) else { continue }
                let path = url.path
                seen.insert(path)
                var file = cache[path]
                if file == nil || file!.size != size || file!.mtime != mtime.timeIntervalSince1970 {
                    file = parse(url, size: size, mtime: mtime)
                    cache[path] = file
                }
                guard let file else { continue }
                var activeToday = false
                for (key, tokens) in file.hours {
                    guard let hour = Double(key) else { continue }
                    let date = Date(timeIntervalSince1970: hour * 3600)
                    guard date >= start else { continue }
                    let d = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: date)).day ?? -1
                    guard (0..<7).contains(d) else { continue }
                    stats.grid[d][cal.component(.hour, from: date)] += tokens
                    projectTokens[file.project ?? "other", default: 0] += tokens
                    if d == 6 { activeToday = true }
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

        // Projects: the top three and the rest.
        let total = projectTokens.values.reduce(0, +)
        if total > 0 {
            let sorted = projectTokens.sorted { $0.value > $1.value }
            stats.projects = sorted.prefix(3).map { ($0.key, Double($0.value) / Double(total)) }
            let rest = sorted.dropFirst(3).reduce(0) { $0 + $1.value }
            if rest > 0 { stats.projects.append(("other", Double(rest) / Double(total))) }
        }

        // The limit: hours at 95%+, and how many times it hit the top.
        var wasAtLimit = false
        var lastTime = Date.distantPast
        for s in LimitHistory.load(since: start) {
            let d = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: s.time)).day ?? -1
            if (0..<7).contains(d), s.percent >= 95 {
                stats.limitHours.insert(d * 24 + cal.component(.hour, from: s.time))
            }
            let atLimit = s.percent >= 99
            if atLimit && (!wasAtLimit || s.time.timeIntervalSince(lastTime) > 3600) { stats.limitHits += 1 }
            wasAtLimit = atLimit
            lastTime = s.time
            if d == 6 { stats.todayPeak = max(stats.todayPeak ?? 0, s.percent) }
        }

        stats.todaySessions = todayFiles
        stats.todayProjects = todayProjects.sorted()
        stats.busiest = busiest(stats)
        return stats
    }

    private static func parse(_ url: URL, size: UInt64, mtime: Date) -> FileStats? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var hours: [String: Int] = [:]
        var project: String?
        for line in data.split(separator: 0x0A) {
            if project == nil, let r = line.range(of: Data(#""cwd":""#.utf8)) {
                let rest = line[r.upperBound...]
                if let end = rest.firstIndex(of: UInt8(ascii: "\"")),
                   let cwd = String(data: rest[rest.startIndex..<end], encoding: .utf8) {
                    project = URL(fileURLWithPath: cwd).lastPathComponent
                }
            }
            guard line.range(of: usageMark) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let stamp = obj["timestamp"] as? String, let date = iso.date(from: stamp),
                  let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            let tokens = n("input_tokens") + n("cache_creation_input_tokens") + n("output_tokens")
            hours[String(Int(date.timeIntervalSince1970 / 3600)), default: 0] += tokens
        }
        return FileStats(size: size, mtime: mtime.timeIntervalSince1970, project: project, hours: hours,
                         isSubagent: url.path.contains("/subagents/"))
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
