import Foundation

/// Putting a copy of the app in place (MoveToApplications), and what it needs
/// to know first, from plain values and folders `make test` can make.
enum AppSwap {
    /// The older copy can't be moved aside: it's left as it was.
    struct OldStays: Error {}

    /// `staged` takes `target`'s place. The older copy moves aside, not deleted,
    /// until the new one is in its place (as Updater.put does): a failed move
    /// puts it back. The staged copy goes in every failure.
    static func put(_ staged: URL, over target: URL, aside old: URL) throws {
        let fm = FileManager.default
        let hadOne = fm.fileExists(atPath: target.path)
        if hadOne {
            try? fm.removeItem(at: old)
            do {
                try fm.moveItem(at: target, to: old)
            } catch {
                try? fm.removeItem(at: staged)
                throw OldStays()
            }
        }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            if hadOne { try? fm.moveItem(at: old, to: target) }
            try? fm.removeItem(at: staged)
            throw error
        }
        if hadOne { try? fm.removeItem(at: old) }
    }

    /// Where a copy already is (never a second one beside it), else the shared
    /// folder, or your own when you can't write to the shared one.
    static func folder(name: String, shared: URL, own: URL, exists: (String) -> Bool, writable: (String) -> Bool) -> URL {
        if let existing = [shared, own].first(where: { exists($0.appendingPathComponent(name).path) }) { return existing }
        return writable(shared.path) ? shared : own
    }

    /// Where disk images are mounted, from `hdiutil info -plist`.
    static func mountPoints(hdiutilInfo data: Data) -> [String] {
        guard let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return [] }
        return (info["images"] as? [[String: Any]] ?? []).flatMap { image in
            (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
        }
    }
}

/// When the last update check was (Updater): a day's wait survives a restart.
enum UpdateStamp {
    static func read(_ url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = (o["t"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func write(_ url: URL, now: Date = Date()) {
        try? JSONSerialization.data(withJSONObject: ["t": now.timeIntervalSince1970])
            .write(to: url, options: .atomic)
    }
}
