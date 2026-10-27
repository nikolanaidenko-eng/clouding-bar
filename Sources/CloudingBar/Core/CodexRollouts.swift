import Foundation

/// What Clouding Bar reads out of Codex's own session files ("rollouts",
/// ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl): lines of
/// {"timestamp", "type", "payload"}, see docs/protocol.md. The parts here are
/// pure, so the tests feed them lines from the documented formats.
enum CodexRollout {
    /// CLOUDINGBAR_CODEX_HOME stands in for ~/.codex in tests.
    static var home: URL {
        ProcessInfo.processInfo.environment["CLOUDINGBAR_CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    static var sessionsDir: URL { home.appendingPathComponent("sessions", isDirectory: true) }
    static var archivedDir: URL { home.appendingPathComponent("archived_sessions", isDirectory: true) }

    // MARK: Limits

    /// One limit window as a line reported it.
    struct Window: Equatable {
        var percent: Double
        /// Unix seconds. Always known: a window that doesn't say when it
        /// resets is taken to reset at the latest a window's length later.
        var resetsAt: Double?
        /// When the line was written (its "timestamp"): newest wins.
        var reported: Date
    }

    struct Limits: Equatable {
        var fiveHour: Window?
        var week: Window?
        /// "plus", "pro", … (plan_type)
        var plan: String?
    }

    /// The limits a `rate_limits` object carries, and which bucket they are
    /// for: Codex meters some models apart ("codex_other"), and the snapshot
    /// of the last bucket in a response is the one written to the file, so
    /// only an empty or "codex" id is the account's own 5-hour and weekly limit.
    static func limits(from rl: [String: Any], at reported: Date) -> (bucket: String, limits: Limits)? {
        let id = (rl["limit_id"] as? String) ?? ""
        var out = Limits(plan: (rl["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
            let window = Window(percent: used, resetsAt: resetTime(w, at: reported, minutes: minutes), reported: reported)
            // By length, not by name: 300 minutes, a week (10080). One window is
            // possible; one of another length is none of ours.
            if (240...360).contains(minutes) { out.fiveHour = window } else if (9000...11000).contains(minutes) { out.week = window }
        }
        guard out.fiveHour != nil || out.week != nil || out.plan != nil else { return nil }
        return (id.isEmpty ? "codex" : id, out)
    }

    /// resets_at as unix seconds or an ISO string; older files had
    /// resets_in_seconds (from the line's time); failing all, a window's
    /// length after the line is the latest it can reset.
    private static func resetTime(_ w: [String: Any], at reported: Date, minutes: Int) -> Double? {
        if let n = w["resets_at"] as? NSNumber { return n.doubleValue }
        if let s = w["resets_at"] as? String, let d = date(s) { return d.timeIntervalSince1970 }
        if let n = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { return reported.timeIntervalSince1970 + n }
        return minutes > 0 ? reported.timeIntervalSince1970 + Double(minutes) * 60 : nil
    }

    private static let stampFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let stampPlain = ISO8601DateFormatter()

    /// "2026-10-26T09:00:20.123Z", with or without fractions (even
    /// microseconds: "…:37.876641+00:00").
    static func date(_ s: String) -> Date? {
        if let d = stampFraction.date(from: s) ?? stampPlain.date(from: s) { return d }
        guard let dot = s.firstIndex(of: "."),
              let end = s[dot...].dropFirst().firstIndex(where: { !$0.isNumber }) else { return nil }
        let cut = s[s.index(after: dot)..<end].prefix(3)
        return stampFraction.date(from: String(s[..<dot]) + "." + cut + String(s[end...]))
    }

    // MARK: Turns

    enum Turn { case started, done, aborted }

    // MARK: Numbers

    /// The share of the context used, the way Codex works it out (tui/src/token_usage.rs):
    /// the first 12 000 tokens (prompts, tools) are not yours, and it rounds what is left.
    static func contextUsedPercent(tokens: Int, window: Int) -> Double {
        let baseline = 12_000
        guard window > baseline else { return 100 }
        let effective = Double(window - baseline)
        let left = max(0, effective - Double(max(0, tokens - baseline))) / effective * 100
        return 100 - min(100, max(0, left)).rounded()
    }

    /// A terminal tab's title is the one Codex gives this chat (0.164's
    /// default): "[spinner ]<name> | <project>", the name cut to 48
    /// characters and the project — its git root's name, else its folder's
    /// — to 24, with "...", spaces squashed (review, 27.10). "Action
    /// Required" names no chat: not it.
    static func isTabTitle(_ title: String, of name: String, in cwd: String) -> Bool {
        func squash(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func cut(_ s: String, _ n: Int) -> String {
            let s = squash(s)
            return s.count <= n ? s : String(s.prefix(n - 3)) + "..."
        }
        let spinner: ClosedRange<Character> = "\u{2800}"..."\u{28FF}"
        var t = squash(title)
        if let f = t.first, spinner.contains(f) { t = String(t.drop { spinner.contains($0) || $0 == " " }) }
        guard let bar = t.range(of: " | ", options: .backwards) else { return false }
        let shown = String(t[..<bar.lowerBound]), project = String(t[bar.upperBound...])
        guard !name.isEmpty, shown == cut(name, 48) else { return false }
        // The git root is the folder or one it sits in.
        return URL(fileURLWithPath: cwd).standardized.pathComponents.dropFirst().contains { cut($0, 24) == project }
    }

    /// "gpt-5.3-codex" → "GPT-5.3-Codex", the way OpenAI writes it.
    static func modelName(_ id: String) -> String {
        guard id.lowercased().hasPrefix("gpt-") else { return id }
        return id.split(separator: "-").enumerated().map { i, part in
            i == 0 ? "GPT" : (part.first?.isLetter == true ? part.prefix(1).uppercased() + part.dropFirst() : String(part))
        }.joined(separator: "-")
    }

    // MARK: The file's first line

    /// What a rollout's session_meta line says about its chat.
    struct Meta: Equatable {
        var id: String?
        var cwd: String?
        var branch: String?
        var originator: String?
        /// "cli", "vscode", "exec", "subagent", …
        var source: String?

        /// A chat of a person: not a subagent's, `codex exec`'s, an MCP server's.
        var interactive: Bool {
            guard let s = source else { return true }
            return ["cli", "vscode", "custom"].contains(s)
        }

        /// "Terminal", "VS Code" or "App", from who started it.
        var host: String? {
            let o = originator ?? ""
            if o == "codex_cli_rs" || o == "codex-tui" { return "Terminal" }
            if o == "codex_vscode" { return "VS Code" }
            if o.hasPrefix("Codex ") { return "App" }
            return nil
        }
    }

    /// Reads the file's first line (session_meta), at most `limit` bytes.
    static func meta(at path: String, limit: Int = 1 << 20) -> Meta? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count < limit {
            let d = handle.readData(ofLength: 64 << 10)
            if d.isEmpty { break }
            data.append(d)
            if data.contains(0x0A) { break }
        }
        let first = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first ?? data[...]
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(first))) as? [String: Any],
              obj["type"] as? String == "session_meta", let p = obj["payload"] as? [String: Any] else { return nil }
        var m = Meta(id: p["id"] as? String, cwd: p["cwd"] as? String, originator: p["originator"] as? String)
        m.branch = (p["git"] as? [String: Any])?["branch"] as? String
        // A plain word, or {"custom": …} / {"subagent": …} for the ones with more to say.
        m.source = (p["source"] as? String) ?? (p["source"] as? [String: Any])?.keys.first
        return m
    }

    /// The chat's id out of "rollout-2026-10-26T09-00-00-<id>.jsonl".
    static func threadId(ofFile path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), name.count > "rollout-.jsonl".count + 36 else { return nil }
        return String(name.dropLast(".jsonl".count).suffix(36)).lowercased()
    }

    static func isRollout(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }
}

/// Finds Codex's newest session files without any hook: the freshest are
/// where its limits and what its chats are doing can be read. Off the main
/// queue; results come back on it.
final class CodexRollouts {
    struct Found {
        let path: String
        let id: String
        let modified: Date
        /// Only read for the ones fresh enough to be a chat shown.
        let meta: CodexRollout.Meta?
        let archived: Bool
        /// Codex's name for the chat ("Fix the tests"), as its tab shows it.
        var name: String? = nil
    }

    /// Limits older than a week are over whatever they said.
    static let horizon: TimeInterval = 7 * 24 * 3600
    /// A chat is read for this long after its file last changed (an hour
    /// while a turn is on: a long command writes nothing).
    static let freshness: TimeInterval = 60 * 60

    private let queue = DispatchQueue(label: "cloudingbar.codexrollouts", qos: .utility)
    private var tracked: Set<String> = []          // touched only on `queue`
    private var metas: [String: CodexRollout.Meta?] = [:]
    private var lastDeep = Date.distantPast

    /// `deep` walks every day's folder of the last month (a chat begun
    /// long ago and resumed lives in its old one); the rest looks at the
    /// newest folders and what was found before.
    func scan(now: Date = Date(), deepEvery: TimeInterval = 120, completion: @escaping ([Found]) -> Void) {
        queue.async {
            let deep = now.timeIntervalSince(self.lastDeep) >= deepEvery
            if deep { self.lastDeep = now }
            let found = self.find(now: now, deep: deep)
            DispatchQueue.main.async { completion(found) }
        }
    }

    private func find(now: Date, deep: Bool) -> [Found] {
        let fm = FileManager.default
        var paths = tracked
        for dir in Self.dayFolders(CodexRollout.sessionsDir, limit: deep ? nil : 3, since: deep ? now.addingTimeInterval(-31 * 24 * 3600) : nil) {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                paths.insert(dir.appendingPathComponent(name).path)
            }
        }
        var list: [(path: String, modified: Date, archived: Bool)] = []
        var alive = Set<String>()
        for path in paths {
            guard let m = Self.modified(path), now.timeIntervalSince(m) < Self.horizon else { continue }
            alive.insert(path)
            list.append((path, m, false))
        }
        tracked = alive
        // Archived chats only when newer than everything in sessions.
        let newest = list.map(\.modified).max() ?? .distantPast
        for name in (try? fm.contentsOfDirectory(atPath: CodexRollout.archivedDir.path)) ?? [] where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
            let path = CodexRollout.archivedDir.appendingPathComponent(name).path
            if let m = Self.modified(path), m > newest, now.timeIntervalSince(m) < Self.horizon { list.append((path, m, true)) }
        }
        metas = metas.filter { alive.contains($0.key) }
        let names = Self.threadNames()
        return list.sorted { $0.modified > $1.modified }.map { f in
            var meta: CodexRollout.Meta?
            if !f.archived, now.timeIntervalSince(f.modified) < Self.freshness {
                // Not found isn't kept: the first line may not be written yet.
                if let known = metas[f.path] { meta = known } else {
                    meta = CodexRollout.meta(at: f.path)
                    if meta != nil { metas[f.path] = .some(meta) }
                }
            }
            let id = meta?.id?.lowercased() ?? CodexRollout.threadId(ofFile: f.path) ?? f.path
            return Found(path: f.path, id: id, modified: f.modified, meta: meta, archived: f.archived, name: names[id])
        }
    }

    /// Codex's names for its chats (session_index.jsonl: id, thread_name;
    /// the newest last), from the file's end. Two tabs of one folder are
    /// told apart by them, as the tabs' titles carry them (review, 27.10).
    static func threadNames() -> [String: String] {
        guard let h = try? FileHandle(forReadingFrom: CodexRollout.home.appendingPathComponent("session_index.jsonl")) else { return [:] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 256 << 10 ? size - (256 << 10) : 0)
        guard let data = try? h.readToEnd() else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) { // a line cut at the start doesn't parse: skipped
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = o["id"] as? String, let name = o["thread_name"] as? String, !name.isEmpty else { continue }
            names[id.lowercased()] = name
        }
        return names
    }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// YYYY/MM/DD folders, newest first.
    static func dayFolders(_ root: URL, limit: Int?, since: Date?) -> [URL] {
        let fm = FileManager.default
        func numbered(_ url: URL) -> [(n: Int, url: URL)] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).compactMap { name in
                Int(name).map { (n: $0, url: url.appendingPathComponent(name, isDirectory: true)) }
            }.sorted { $0.n > $1.n }
        }
        var days: [URL] = []
        let cal = Calendar(identifier: .gregorian)
        outer: for y in numbered(root) {
            for m in numbered(y.url) {
                for d in numbered(m.url) {
                    if let since, let day = cal.date(from: DateComponents(year: y.n, month: m.n, day: d.n)),
                       day < since.addingTimeInterval(-24 * 3600) { break outer }
                    days.append(d.url)
                    if let limit, days.count >= limit { break outer }
                }
            }
        }
        return days
    }
}
