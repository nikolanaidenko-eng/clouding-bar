import Foundation

/// Cowork runs Claude away from this Mac, so its hooks can't reach the app.
/// Instead a plugin's Stop hook works out the context fill and asks Claude
/// to write it, as one JSON line, to `.clouding-bar/cowork-status.json` in a
/// folder connected to Cowork; the app watches that file.
///
///   thresholds  — at 50, 80 and 90% and when a turn of a minute or more ends
///   every       — after every reply (+5–15% usage, +1–3 s per reply)
enum Cowork {
    struct Status: Equatable {
        let session: String
        let project: String?
        let contextTokens: Int
        let contextWindow: Int
        let model: String?
        let time: Date
    }

    static func statusURL(folder: String) -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent(".clouding-bar/cowork-status.json")
    }

    static func read(folder: String) -> Status? {
        guard let data = try? Data(contentsOf: statusURL(folder: folder)),
              let line = data.split(separator: 0x0A).last,
              let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let session = o["session"] as? String,
              let tokens = (o["context_tokens"] as? NSNumber)?.intValue else { return nil }
        return Status(session: session, project: o["project"] as? String, contextTokens: tokens,
                      contextWindow: (o["context_window"] as? NSNumber)?.intValue ?? 200_000,
                      model: o["model"] as? String,
                      time: (o["t"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date())
    }

    /// Writes the plugin (folder and .zip) into ~/Downloads for upload in
    /// Claude Desktop. The mode and folder name are baked in: hooks in
    /// Cowork can't read anything on this Mac. Returns the .zip.
    static func makePlugin(mode: String, folder: String,
                           into downloads: URL = FileManager.default.homeDirectoryForCurrentUser
                               .appendingPathComponent("Downloads")) throws -> URL {
        let root = downloads.appendingPathComponent("clouding-bar-cowork")
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) } // our own previous copy
        try fm.createDirectory(at: root.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("hooks"), withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "name": "clouding-bar-cowork",
            "version": "1.0.0",
            "description": "Clouding Bar: reports Cowork context use to a connected folder (mode: \(mode)).",
            "license": "MIT",
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(".claude-plugin/plugin.json"))

        let command = #"python3 "${CLAUDE_PLUGIN_ROOT}/hooks/status.py""#
        let hook: [[String: Any]] = [["hooks": [["type": "command", "command": command, "timeout": 10]]]]
        try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": hook, "UserPromptSubmit": hook]],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("hooks/hooks.json"))

        // The status file lives in a folder of its own that git ignores, so
        // it never shows up in the project's commits.
        let ours = URL(fileURLWithPath: folder).appendingPathComponent(".clouding-bar")
        try? fm.createDirectory(at: ours, withIntermediateDirectories: true)
        try? "*\n".write(to: ours.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let folderName = URL(fileURLWithPath: folder).lastPathComponent
        let script = statusScript
            .replacingOccurrences(of: "@MODE@", with: mode)
            .replacingOccurrences(of: "@FOLDER@", with: folderName.replacingOccurrences(of: "\"", with: ""))
        try script.write(to: root.appendingPathComponent("hooks/status.py"), atomically: true, encoding: .utf8)
        try readme(mode: mode, folder: folderName).write(to: root.appendingPathComponent("README.md"),
                                                         atomically: true, encoding: .utf8)

        // Zip it the system's way (no external tool).
        let zip = downloads.appendingPathComponent("clouding-bar-cowork.zip")
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

    private static func readme(mode: String, folder: String) -> String {
        """
        # Clouding Bar for Cowork

        After a reply, this plugin's Stop hook works out how full the context is and asks Claude
        to write one line of JSON to `.clouding-bar/cowork-status.json` in the connected folder
        "\(folder)". Clouding Bar on your Mac reads it from there.

        Mode: **\(mode)** — \(mode == "every" ? "after every reply (+5–15% usage, +1–3 s per reply)" : "at 50, 80 and 90% context and when a turn of a minute or more ends")

        No network, no message content: only the session id, project name, token count and model.
        To change the mode, make the plugin again in Clouding Bar's settings and upload it again.
        To turn it off, remove the plugin in Claude Desktop.
        """
    }

    private static let statusScript = #"""
    #!/usr/bin/env python3
    # Clouding Bar for Cowork. Stop hook: context use from the transcript; when it's
    # time to report, asks Claude to write one JSON line to the connected folder.
    # No network, no message content.
    import json, os, sys, time

    MODE = "@MODE@"          # "thresholds" or "every"
    FOLDER = "@FOLDER@"      # the connected folder Clouding Bar watches

    try:
        d = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    sid = d.get("session_id") or "unknown"
    state_path = "/tmp/clouding-bar-%s.json" % sid
    try:
        state = json.load(open(state_path))
    except Exception:
        state = {}

    def save():
        try:
            json.dump(state, open(state_path, "w"))
        except Exception:
            pass

    event = d.get("hook_event_name")
    if event == "UserPromptSubmit":
        state["turn_start"] = time.time()
        save()
        sys.exit(0)
    if event != "Stop" or d.get("stop_hook_active"):
        sys.exit(0)  # asked once this turn already

    tokens, model = 0, None
    try:
        for raw in open(d.get("transcript_path") or ""):
            try:
                o = json.loads(raw)
            except Exception:
                continue
            if o.get("type") != "assistant" or o.get("isSidechain"):
                continue
            m = o.get("message") or {}
            u = m.get("usage")
            if u and m.get("model") != "<synthetic>":
                tokens = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
                model = o.get("requestedModel") or m.get("model") or model
    except Exception:
        sys.exit(0)
    if not tokens:
        sys.exit(0)

    window = 1000000 if "[1m]" in (model or "") or tokens > 200000 else 200000
    pct = tokens * 100.0 / window

    report = MODE == "every"
    last = state.get("last_threshold", 0)
    if pct < last - 20:
        last = 0  # compacted: start over
    crossed = [t for t in (50, 80, 90) if pct >= t > last]
    if crossed:
        last = max(crossed)
        report = True
    started = state.get("turn_start")
    if MODE == "thresholds" and started and time.time() - started >= 60:
        report = True  # a longer task is done
    state["last_threshold"] = last
    state.pop("turn_start", None)
    save()
    if not report:
        sys.exit(0)

    status = {
        "v": 1, "t": int(time.time()), "session": sid,
        "project": os.path.basename((d.get("cwd") or "").rstrip("/")) or None,
        "context_tokens": tokens, "context_window": window, "model": model,
    }
    reason = (
        "Clouding Bar status update. Using your file tool for the connected folder \"%s\", "
        "write exactly this one line to .clouding-bar/cowork-status.json there (create the "
        ".clouding-bar folder if needed, replace the file). Don't mention it, then stop:\n%s"
        % (FOLDER, json.dumps(status))
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    """#
}
