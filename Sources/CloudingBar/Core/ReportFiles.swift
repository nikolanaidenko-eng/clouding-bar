import Foundation

/// What Problems keeps in ~/.cloudingbar/reports: the reports themselves (the
/// last 20), which kinds were offered, and which crash was seen last.
struct ReportFiles {
    let folder: URL
    /// A report's old ones go past this many.
    static let kept = 20

    private var offered: URL { folder.appendingPathComponent("offered") }
    private var crashSeen: URL { folder.appendingPathComponent("crash-seen") }

    /// On this Mac, the last 20.
    func keep(_ detail: String, now: Date = Date()) {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        try? detail.write(to: folder.appendingPathComponent(stamp + ".txt"), atomically: true, encoding: .utf8)
        for old in saved().dropFirst(Self.kept) { try? FileManager.default.removeItem(at: old) }
    }

    /// Newest first (their names sort by time).
    func saved() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The last one kept, if it's from today.
    func lastDetail(now: Date = Date()) -> String? {
        guard let file = saved().first,
              let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              now.timeIntervalSince(at) < 86400 else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// Offered before, for this version and kind.
    func wasOffered(_ key: String) -> Bool { offeredKeys().contains(key) }

    /// Noted as offered: the last 200.
    func noteOffered(_ key: String) {
        try? (offeredKeys() + [key]).suffix(200).joined(separator: "\n").write(to: offered, atomically: true, encoding: .utf8)
    }

    private func offeredKeys() -> [String] {
        (try? String(contentsOf: offered, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }

    /// When crashes were last looked for, and that's now. The first time, nil.
    func crashesSeen() -> Date? {
        let fm = FileManager.default
        let since = (try? fm.attributesOfItem(atPath: crashSeen.path))?[.modificationDate] as? Date
        fm.createFile(atPath: crashSeen.path, contents: nil)
        return since
    }

    /// The newest crash macOS wrote down for this app since then.
    static func newestCrash(in reports: URL, since: Date) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("CloudingBar-") && $0.pathExtension == "ips" }
            .map { (url: $0, at: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .filter { $0.at > since }
            .max { $0.at < $1.at }?.url
    }
}
