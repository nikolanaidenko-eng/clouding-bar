import Foundation

/// Claude Code chats of the Claude desktop app, from its own files
/// (~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json).
/// A chat's hooks know it by Claude Code's session id; the app by its own
/// ("local_…", which `claude://code/continue?session=` opens), and
/// claude.ai by its Remote Control session, when it has one — words go
/// there without its window in front. Unofficial: every field optional.
enum DesktopSessions {
    struct Entry: Equatable {
        /// The app's id for it: its link opens it.
        let local: String
        /// Its Remote Control session ("cse_…"), the newest it had.
        let bridge: String?
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// What each file said, by its path and when it last changed: only a
    /// changed one is read again (review, 29.10: they run to a megabyte).
    /// Used from one queue at a time.
    final class Cache {
        fileprivate var files: [String: (changed: Date, read: (cli: String, entry: Entry)?)] = [:]
        init() {}
    }

    /// Every chat not archived, by Claude Code's session id.
    static func read(in folder: URL = folder, cache: Cache = Cache()) -> [String: Entry] {
        let fm = FileManager.default
        var found: [String: Entry] = [:]
        var seen = Set<String>()
        for account in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    seen.insert(file.path)
                    let read: (cli: String, entry: Entry)?
                    if let known = cache.files[file.path], known.changed == changed {
                        read = known.read
                    } else {
                        let data = try? Data(contentsOf: file)
                        read = data.flatMap { $0.count < 4_000_000 ? entry(try? JSONSerialization.jsonObject(with: $0)) : nil }
                        cache.files[file.path] = (changed, read)
                    }
                    if let read { found[read.cli] = read.entry }
                }
            }
        }
        cache.files = cache.files.filter { seen.contains($0.key) }
        return found
    }

    static func entry(_ json: Any?) -> (cli: String, entry: Entry)? {
        guard let o = json as? [String: Any], o["isArchived"] as? Bool != true,
              let local = o["sessionId"] as? String, isLocal(local),
              let cli = o["cliSessionId"] as? String, ClaudeAIChats.isId(cli) else { return nil }
        let bridge = (o["bridgeSessionIds"] as? [Any])?.compactMap { $0 as? String }.last
            .map(ClaudeAIChats.cse).flatMap { ClaudeAIChats.isId($0) && $0.hasPrefix("cse_") ? $0 : nil }
        return (cli, Entry(local: local, bridge: bridge))
    }

    /// As the app's link takes it: "local_" and up to 64 letters, digits and "-".
    static func isLocal(_ s: String) -> Bool {
        s.hasPrefix("local_") && s.count > 6 && s.count <= 70
            && s.dropFirst(6).unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// The app's link to it.
    static func link(_ local: String) -> URL? {
        isLocal(local) ? URL(string: "claude://code/continue?session=" + local) : nil
    }
}

/// Claude Code's own record of a running chat (~/.claude/sessions/<pid>.json):
/// with Remote Control on (`/remote-control`, or `remoteControlAtStartup`),
/// it writes there the session it has on claude.ai — a Terminal chat then
/// takes words through claude.ai as a desktop one does.
enum ClaudeSessions {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    /// The Remote Control session of the chat `session` that Claude `pid` runs.
    static func bridge(pid: Int32, session: String, in folder: URL = folder) -> String? {
        guard pid > 1, let data = try? Data(contentsOf: folder.appendingPathComponent("\(pid).json")), data.count < 1_000_000,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["sessionId"] as? String == session,
              let bridge = (o["bridgeSessionId"] as? String).map(ClaudeAIChats.cse),
              bridge.hasPrefix("cse_"), ClaudeAIChats.isId(bridge) else { return nil }
        return bridge
    }
}
