import Foundation

/// The current git branch of a folder, read from .git/HEAD — no git
/// command runs. Works for worktrees too (.git as a "gitdir:" file).
enum Git {
    /// Whether the app can read here without macOS asking first: not in
    /// Documents, Desktop, Downloads, iCloud Drive, cloud storage or on
    /// another disk. There the hook reads the branch instead (it runs
    /// inside Claude Code, which already may).
    static func readable(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let asked = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { home + "/" + $0 }
        return !path.hasPrefix("/Volumes/") && !asked.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func branch(at path: String) -> String? {
        var dir = URL(fileURLWithPath: path)
        for _ in 0..<12 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue,
                   let text = try? String(contentsOf: dotGit, encoding: .utf8),
                   let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") {
                    let p = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: p, relativeTo: dir).standardizedFileURL
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
                return String(head.prefix(7)) // detached HEAD: the commit
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
