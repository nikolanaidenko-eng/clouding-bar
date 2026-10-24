import Foundation

/// Cowork runs Claude in a machine of its own, so its hooks can't reach the
/// app. Instead the plugin's hooks write one JSON line — context use, and
/// whether Claude is working — to `.clouding-bar/cowork-<session>.json` in a
/// folder connected to the task, on every message and every reply; the app
/// watches the connected folders. Only when no connected folder is visible
/// to the hook does it ask Claude to write `.clouding-bar/cowork-status.json`:
///
///   thresholds  — after a task's first reply, at 50, 80 and 90%, and when a
///                 turn of a minute or more ends
///   every       — after every reply (+5–15% usage, +1–3 s per reply)
enum Cowork {
    struct Status: Equatable {
        let session: String
        let project: String?
        let contextTokens: Int
        let contextWindow: Int
        let model: String?
        let time: Date
        /// Between your message and Claude's reply.
        var working = false
        /// The task's title, else its first words.
        var title: String? = nil
        /// For Stats, by unix hour: tokens spent, minutes with a reply.
        var usage: [Int: Spent] = [:]
    }

    struct Spent: Equatable, Codable {
        var tokens: Int
        var minutes: Int
    }

    /// Cowork's context window: 1M for a "[1m]" model, else 500k (what its
    /// /context says, 20.10), 200k for Haiku. What the plugin reported is a
    /// guess of its own (it used to take 200k).
    static func window(model: String?) -> Int {
        let m = model ?? ""
        if m.contains("[1m]") { return 1_000_000 }
        return m.contains("haiku") ? 200_000 : 500_000
    }

    /// The status files in a connected folder: one per task, and the one
    /// Claude writes when the plugin can't.
    /// What each Cowork chat spent, kept in cowork-usage.json: the plugin's
    /// own files go after 3 days, and Stats wants them longer.
    struct Kept: Codable {
        var project: String?
        var title: String?
        var model: String?
        /// Unix hour → spent.
        var usage: [String: Spent]
    }

    private static var keptURL: URL { Config.directory.appendingPathComponent("cowork-usage.json") }

    static func kept() -> [String: Kept] {
        (try? JSONDecoder().decode([String: Kept].self, from: Data(contentsOf: keptURL))) ?? [:]
    }

    /// Keeps a status's usage (each status carries the chat's whole usage).
    static func keep(_ s: Status) {
        guard !s.usage.isEmpty else { return }
        var all = kept()
        var record = all[s.session] ?? Kept(project: nil, title: nil, model: nil, usage: [:])
        record.project = s.project ?? record.project
        record.title = s.title ?? record.title
        record.model = s.model ?? record.model
        for (hour, spent) in s.usage {
            let k = String(hour)
            // A later report covers more of the same hour.
            if spent.tokens >= (record.usage[k]?.tokens ?? 0) { record.usage[k] = spent }
        }
        all[s.session] = record
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: keptURL, options: .atomic) }
    }

    static func statusFiles(folder: String) -> [URL] {
        let dir = URL(fileURLWithPath: folder).appendingPathComponent(".clouding-bar")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("cowork-") && $0.hasSuffix(".json") }.sorted()
            .map { dir.appendingPathComponent($0) }
    }

    private static func usage(_ value: Any?) -> [Int: Spent] {
        var out: [Int: Spent] = [:]
        for (key, pair) in value as? [String: Any] ?? [:] {
            guard let hour = Int(key), (0...1_000_000).contains(hour), let p = pair as? [NSNumber], p.count >= 2 else { continue }
            out[hour] = Spent(tokens: clamp(p[0], 0...100_000_000), minutes: clamp(p[1], 0...60))
        }
        return out
    }

    /// The file is written in a folder anyone's repo could bring along:
    /// numbers kept sane, so a 9e18 can't bring the app down.
    private static func clamp(_ n: NSNumber?, _ range: ClosedRange<Int>) -> Int {
        guard let d = n?.doubleValue, d.isFinite else { return range.lowerBound }
        return Int(min(max(d, Double(range.lowerBound)), Double(range.upperBound)))
    }

    static func read(_ url: URL) -> Status? {
        guard let data = try? Data(contentsOf: url),
              let line = data.split(separator: 0x0A).last,
              let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let session = o["session"] as? String,
              let tokens = o["context_tokens"] as? NSNumber else { return nil }
        return Status(session: session, project: o["project"] as? String, contextTokens: clamp(tokens, 0...10_000_000),
                      contextWindow: o["context_window"] == nil ? 200_000 : clamp(o["context_window"] as? NSNumber, 1_000...10_000_000),
                      model: o["model"] as? String,
                      time: (o["t"] as? NSNumber).map { Date(timeIntervalSince1970: Double(clamp($0, 0...4_102_444_800))) } ?? Date(),
                      working: o["state"] as? String == "working",
                      title: (o["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                      usage: usage(o["usage"]))
    }

    /// Folders connected to Cowork, from Claude Desktop's own records — its
    /// "spaces" and, for each task, the folders given to it — so nobody has
    /// to pick them by hand.
    static func connectedFolders() -> [String] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        var found = Set<String>()
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            if walker!.level > 3 { walker!.skipDescendants(); continue }
            let name = url.lastPathComponent
            guard name == "spaces.json" || name == "remote-session-spaces.json",
                  let data = try? Data(contentsOf: url),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            // A space: {"folders": [{"path": …}]}; a task: {"folders": ["…"]}.
            for space in o["spaces"] as? [[String: Any]] ?? [] {
                for f in space["folders"] as? [[String: Any]] ?? [] {
                    if let path = f["path"] as? String, FileManager.default.fileExists(atPath: path) { found.insert(path) }
                }
            }
            for task in o["entries"] as? [[String: Any]] ?? [] {
                for path in task["folders"] as? [String] ?? [] where FileManager.default.fileExists(atPath: path) {
                    found.insert(path)
                }
            }
        }
        return found.sorted()
    }

    /// Clouding Bar's plugin, as the app carries it (Resources/plugin) —
    /// or the repository's own folder (CLOUDINGBAR_PLUGIN), for the tests.
    static var pluginSource: URL? {
        if let path = ProcessInfo.processInfo.environment["CLOUDINGBAR_PLUGIN"] { return URL(fileURLWithPath: path) }
        return Bundle.main.url(forResource: "plugin", withExtension: nil)
    }

    /// The plugin as a .zip in ~/Downloads (clouding-bar-plugin.zip), for
    /// upload in Claude Desktop → Customize → Plugins: the one its GitHub
    /// marketplace gives, for Claude Code and Cowork alike. How often Cowork
    /// reports is set here, in the folder (setMode), not baked in.
    static func makePlugin(into downloads: URL = FileManager.default.homeDirectoryForCurrentUser
                               .appendingPathComponent("Downloads")) throws -> URL {
        guard let source = pluginSource else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("clouding-bar-plugin-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        let root = stage.appendingPathComponent("clouding-bar")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: root)

        // Zip it the system's way (no external tool).
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let zip = downloads.appendingPathComponent("clouding-bar-plugin.zip")
        var coordinated: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordinated) { tmp in
            do {
                if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
                try fm.copyItem(at: tmp, to: zip)
            } catch { thrown = error }
        }
        if let e = coordinated ?? thrown { throw e }
        return zip
    }

    /// Tells the plugin in Cowork how to report, in each folder connected to
    /// it: .clouding-bar/mode — "off", "thresholds" or "every" (cowork.py
    /// reads it). "Off" goes only where the plugin has written already.
    static func setMode(_ mode: String, folders: [String]) {
        let fm = FileManager.default
        for folder in folders {
            let dir = URL(fileURLWithPath: folder).appendingPathComponent(".clouding-bar")
            let file = dir.appendingPathComponent("mode")
            let current = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if current == mode || (mode == "off" && !fm.fileExists(atPath: dir.path)) { continue }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let ignore = dir.appendingPathComponent(".gitignore")
            if !fm.fileExists(atPath: ignore.path) { try? "*\n".write(to: ignore, atomically: true, encoding: .utf8) }
            try? (mode + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
