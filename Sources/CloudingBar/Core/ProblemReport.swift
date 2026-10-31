import Foundation

/// What a problem report says, from plain text (no AppKit, so `make test` can
/// check it). Nothing here sends anything: the report stays on this Mac until
/// you've read it and sent it yourself (owner, 31.10). Public once sent, so
/// only what's known to carry no words of yours goes in.
enum ProblemReport {
    // MARK: The log

    /// The log's lines that may go along: the app's own doings. Anything else
    /// (a chat's name, a project's, a button's) stays out, whatever it says;
    /// a new kind of line is left out until it's added here.
    private static let safe = [
        "launch trusted=", "connect to Claude Code", "open Accessibility settings",
        "note: claude.ai organizations:", "note: claude.ai chats:", "note: claude.ai usage:", "note: claude.ai:",
        "note: claude.ai sign-in:", "note: claude.ai key:", "note: claude.ai session card:",
        "note: claude.ai cowork events:", "note: claude.ai cowork:",
        "claude.ai signed", "note: setup:", "note: update", "note: screens:", "note: widget: put", "note: pull:",
        "note: the socket", "note: local cowork:", "note: desktop prompt: no claude.ai page", "note: desktop prompt: answered",
        "note: desktop prompt: couldn't", "note: problem:",
    ]

    /// The lines that may go, oldest first, each said once in a row. Without
    /// the app in front at the time. `claudeAI` off: nothing about claude.ai,
    /// as a line of it says you signed in, in public under your name.
    static func safeLog(_ log: String, claudeAI: Bool = false, last: Int = 60) -> [String] {
        var kept: [String] = []
        var said = ""
        for line in log.split(separator: "\n").map(String.init) {
            // "2026-10-31 10:01:06 +0000 what happened"
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, parts[2] == "+0000", safe.contains(where: parts[3].hasPrefix),
                  claudeAI || !parts[3].contains("claude.ai") else { continue }
            if parts[3] == said { continue }
            said = parts[3]
            kept.append(scrub(line.replacingOccurrences(of: " front=[^ ]+", with: "", options: .regularExpression)))
        }
        return Array(kept.suffix(last))
    }

    private static let scrubs: [(pattern: String, with: String)] = [
        ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>"),
        ("/(Users|home|Volumes|private)/[^\\s,:;)]+", "<path>"),
        ("~/[^\\s,:;)]+", "<path>"),
        ("\\b(cse|local|session)_[A-Za-z0-9_-]+", "<id>"),
        ("\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b", "<id>"),
        ("(?<![.\\d])\\b[0-9a-f]{8}\\b", "<id>"),
    ]

    /// No address, no name in a path, no id.
    static func scrub(_ text: String) -> String {
        scrubs.reduce(text) { $0.replacingOccurrences(of: $1.pattern, with: $1.with, options: .regularExpression) }
    }

    // MARK: What's worth offering

    /// An answer from claude.ai that says the app asked wrongly. Not the ones
    /// that are nobody's fault here: its own trouble (5xx), no connection (0),
    /// "too many", a key gone (401, 403), a task gone (404).
    static func worthOffering(status: Int) -> Bool {
        (400..<500).contains(status) && ![401, 403, 404, 429].contains(status)
    }

    // MARK: A crash

    struct Crash: Equatable {
        /// The same crash again is the same kind: offered once for a version.
        let kind: String
        let text: String
    }

    /// From the report macOS leaves in ~/Library/Logs/DiagnosticReports (.ips:
    /// a line of JSON, then the rest): what stopped it and where. Not its
    /// paths, other threads or list of processes.
    static func crash(ips: String) -> Crash? {
        guard let newline = ips.firstIndex(of: "\n"),
              let head = object(String(ips[..<newline])),
              let body = object(String(ips[ips.index(after: newline)...])) else { return nil }
        let exception = body["exception"] as? [String: Any]
        let what = [exception?["type"], exception?["signal"], exception?["subtype"]].compactMap { $0 as? String }
        var lines = ["Crash: " + (what.isEmpty ? "no reason given" : what.joined(separator: " "))]
        if let version = head["app_version"] as? String { lines.append("Version: " + version) }
        if let os = head["os_version"] as? String { lines.append("macOS: " + os) }
        let notes = (body["asi"] as? [String: Any])?.values.compactMap { $0 as? [Any] }.joined().compactMap { $0 as? String } ?? []
        if let message = notes.first { lines.append("Message: " + scrub(String(message.prefix(300)))) }
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        let frames = threads.indices.contains(faulting) ? threads[faulting]["frames"] as? [[String: Any]] ?? [] : []
        let shown = frames.prefix(16).map { frame -> String in
            let index = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) ? images[index] : "?"
            let symbol = (frame["symbol"] as? String).map { " " + scrub(String($0.prefix(120))) } ?? ""
            let offset = frame["imageOffset"] as? Int ?? 0
            return "  \(scrub(image)) +0x\(String(offset, radix: 16))\(symbol)"
        }
        if !shown.isEmpty { lines.append("Where:\n" + shown.joined(separator: "\n")) }
        // Where in this app, for telling one crash from another.
        let here = shown.first { $0.contains("CloudingBar") } ?? shown.first ?? ""
        let kind = "crash " + what.first.map { $0 + " " }.orEmpty + here.trimmingCharacters(in: .whitespaces)
        return Crash(kind: kind, text: lines.joined(separator: "\n"))
    }

    private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    // MARK: The report

    /// For you to read, change and send. The newest of the log first, as a
    /// long one is cut at its end.
    static func text(detail: String?, about: [String], log: [String], claudeAI: Bool = false) -> String {
        var parts = ["What were you doing? (Add it here, or delete this line.)"]
        if let detail {
            parts.append("## Problem\n" + (claudeAI || !detail.contains("claude.ai") ? detail : "An error about claude.ai: tick the box below to include it."))
        }
        parts.append("## This Mac\n" + about.map { "- " + $0 }.joined(separator: "\n"))
        if !log.isEmpty { parts.append("## Log, newest first\n```\n" + log.reversed().joined(separator: "\n") + "\n```") }
        return parts.joined(separator: "\n\n")
    }

    /// A new issue on GitHub, its text empty: you paste the report in, so
    /// nothing goes until you submit it (a text in the address reaches GitHub
    /// as the page opens, and past 5000 characters it answers with an error).
    static func issueURL(repo: String, version: String) -> URL? {
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")
        c?.queryItems = [URLQueryItem(name: "title", value: "Problem report (\(version))")]
        return c?.url
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
