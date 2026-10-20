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
    }

    /// The status files in a connected folder: one per task, and the one
    /// Claude writes when the plugin can't.
    static func statusFiles(folder: String) -> [URL] {
        let dir = URL(fileURLWithPath: folder).appendingPathComponent(".clouding-bar")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("cowork-") && $0.hasSuffix(".json") }.sorted()
            .map { dir.appendingPathComponent($0) }
    }

    static func read(_ url: URL) -> Status? {
        guard let data = try? Data(contentsOf: url),
              let line = data.split(separator: 0x0A).last,
              let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let session = o["session"] as? String,
              let tokens = (o["context_tokens"] as? NSNumber)?.intValue else { return nil }
        return Status(session: session, project: o["project"] as? String, contextTokens: tokens,
                      contextWindow: (o["context_window"] as? NSNumber)?.intValue ?? 200_000,
                      model: o["model"] as? String,
                      time: (o["t"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date(),
                      working: o["state"] as? String == "working",
                      title: (o["title"] as? String).flatMap { $0.isEmpty ? nil : $0 })
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

    /// Writes the plugin (folder and .zip) into ~/Downloads for upload in
    /// Claude Desktop. Only the mode is baked in (hooks in Cowork can't read
    /// this Mac); it works with whatever folder a task has. Returns the .zip.
    static func makePlugin(mode: String,
                           into downloads: URL = FileManager.default.homeDirectoryForCurrentUser
                               .appendingPathComponent("Downloads")) throws -> URL {
        let root = downloads.appendingPathComponent("clouding-bar-cowork")
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) } // our own previous copy
        try fm.createDirectory(at: root.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("hooks"), withIntermediateDirectories: true)

        let manifest: [String: Any] = [
            "name": "clouding-bar-cowork",
            "version": "2.2.0",
            "description": "Clouding Bar: reports Cowork context use to a connected folder.",
            "license": "MIT",
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(".claude-plugin/plugin.json"))

        let command = #"python3 "${CLAUDE_PLUGIN_ROOT}/hooks/status.py""#
        let hook: [[String: Any]] = [["hooks": [["type": "command", "command": command, "timeout": 10]]]]
        try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": hook, "UserPromptSubmit": hook]],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("hooks/hooks.json"))

        let script = statusScript.replacingOccurrences(of: "@MODE@", with: mode)
        try script.write(to: root.appendingPathComponent("hooks/status.py"), atomically: true, encoding: .utf8)
        try readme(mode: mode).write(to: root.appendingPathComponent("README.md"),
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

    private static func readme(mode: String) -> String {
        """
        # Clouding Bar for Cowork

        When Cowork runs on your Mac, on every message and every reply this plugin's hooks write
        one line of JSON — how full the context is, and whether Claude is working — to
        `.clouding-bar/cowork-<task>.json` in a folder connected to the task (with a `.gitignore`,
        so it never gets committed). Clouding Bar finds the folders you connect in Claude Desktop
        and reads it from there. It costs nothing: Claude isn't involved.

        When Cowork runs in the cloud, the task's folders are copies that reach your Mac only
        when Claude writes, so the hooks ask Claude to write the line. How often: **\(mode)** — \(mode == "every" ? "after every reply (+5–15% usage, +1–3 s per reply)" : "after a task's first reply, at 50, 80 and 90% context, and when a turn of a minute or more ends")

        No network. What it writes: the task id, its title (or your first words in it, so two
        tasks in one folder are told apart), a folder name, the token count and the model.
        To turn it off, remove the plugin in Claude Desktop.
        """
    }

    private static let statusScript = #"""
    #!/usr/bin/env python3
    # Clouding Bar for Cowork, version 2.2. With Cowork on this Mac it writes
    # one line of JSON (context use; working or done) on every message and
    # reply into the folders connected to the task, where Clouding Bar reads
    # it. With Cowork in the cloud, whose folders are copies, it asks Claude to
    # write the line instead (MODE says how often). No network; of what you
    # wrote, only the task's first words, as its name.
    import json, os, sys, time

    MODE = "@MODE@"                # when Claude has to write it: "thresholds" or "every"
    SKIP = {"outputs", "uploads"}  # Cowork's own folders, not the Mac's

    try:
        d = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    sid = d.get("session_id") or "unknown"
    event = d.get("hook_event_name")
    if event not in ("UserPromptSubmit", "Stop"):
        sys.exit(0)

    def words(text):
        text = " ".join((text or "").split())
        return None if not text or text.startswith("<") else text

    def context():
        # Context use, the model, and a name for the task: the title it was
        # given, else the first words you wrote.
        tokens, model, titles, first = 0, None, {}, None
        try:
            for raw in open(d.get("transcript_path") or ""):
                try:
                    o = json.loads(raw)
                except Exception:
                    continue
                kind = o.get("type")
                if kind in ("custom-title", "ai-title", "summary"):
                    titles[kind] = o.get("customTitle") or o.get("aiTitle") or o.get("summary")
                    continue
                if o.get("isSidechain"):
                    continue
                m = o.get("message") or {}
                if kind == "user" and first is None and not o.get("isMeta"):
                    c = m.get("content")
                    if isinstance(c, list):
                        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
                    first = words(c) if isinstance(c, str) else None
                if kind != "assistant":
                    continue
                u = m.get("usage")
                if u and m.get("model") != "<synthetic>":
                    tokens = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
                    model = o.get("requestedModel") or m.get("model") or model
        except Exception:
            pass
        title = (titles.get("custom-title") or titles.get("ai-title") or titles.get("summary")
                 or first or words(d.get("prompt")))
        if title and len(title) > 40:
            title = title[:39].rstrip() + "…"
        return tokens, model, title

    def live():
        # Shared straight from the Mac (Cowork on this Mac): virtiofs, 9p,
        # fuse. Cowork in the cloud works on a copy instead, which reaches the
        # Mac only when Claude writes; there the hook must ask Claude. None:
        # no mount table to tell by (not Linux), take every folder.
        try:
            table = open("/proc/self/mounts").read().splitlines()
        except Exception:
            return None
        points = []
        for line in table:
            f = line.split()
            if len(f) >= 3 and (f[2] in ("virtiofs", "9p") or (f[2].startswith("fuse") and f[2] != "fusectl")):
                points.append(f[1].replace("\\040", " ").rstrip("/") + "/")
        return points

    def folders():
        # The Mac folders connected to this task, as Cowork mounts them.
        found, points = [], live()
        for base in (os.path.join(d.get("cwd") or os.getcwd(), "mnt"), os.path.expanduser("~/mnt")):
            try:
                for n in sorted(os.listdir(base)):
                    p = os.path.realpath(os.path.join(base, n))
                    if n.startswith(".") or n in SKIP or p in found or not os.path.isdir(p):
                        continue
                    if points is None or any((p + "/").startswith(m) for m in points):
                        found.append(p)
            except Exception:
                pass
        return found[:3]

    def write(folder, line):
        # .clouding-bar/cowork-<task>.json, replaced whole; git ignores it.
        try:
            out = os.path.join(folder, ".clouding-bar")
            os.makedirs(out, exist_ok=True)
            ignore = os.path.join(out, ".gitignore")
            if not os.path.exists(ignore):
                with open(ignore, "w") as f:
                    f.write("*\n")
            path = os.path.join(out, "cowork-%s.json" % sid)
            with open(path + ".tmp", "w") as f:
                f.write(line + "\n")
            os.replace(path + ".tmp", path)
            for n in os.listdir(out):  # ours, from tasks long gone
                p = os.path.join(out, n)
                if n.startswith("cowork-") and n != "cowork-status.json" and time.time() - os.path.getmtime(p) > 3 * 86400:
                    os.remove(p)
            return True
        except Exception:
            return False

    tokens, model, title = context()
    window = 1000000 if "[1m]" in (model or "") or tokens > 200000 else 200000
    status = {
        "v": 2, "t": int(time.time()), "session": sid,
        "project": os.path.basename((d.get("cwd") or "").rstrip("/")) or None,
        "context_tokens": tokens, "context_window": window, "model": model, "title": title,
        "state": "working" if event == "UserPromptSubmit" else "done",
    }
    wrote = [write(f, json.dumps(status)) for f in folders()]
    if any(wrote):
        sys.exit(0)

    # No folder shared straight from the Mac: ask Claude, whose writes reach it.
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

    if event == "UserPromptSubmit":
        state["turn_start"] = time.time()
        save()
        sys.exit(0)
    if d.get("stop_hook_active") or not tokens:
        sys.exit(0)  # asked once this turn already

    # Every reply, or: the first one (so a new task shows up at once), the
    # thresholds, and the end of a longer turn.
    pct = tokens * 100.0 / window
    report = MODE == "every" or not state.get("reported")
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
    if report:
        state["reported"] = True
    save()
    if not report:
        sys.exit(0)

    status["via"] = "claude"
    reason = (
        "Clouding Bar status update. If a folder from the user's computer is connected to this task, "
        "write exactly this one line to .clouding-bar/cowork-%s.json in it (the first such folder; "
        "create .clouding-bar if needed and put a .gitignore containing * in it; replace the file). "
        "If no folder is connected, skip it. Don't mention any of this, then stop:\n%s" % (sid, json.dumps(status))
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    """#
}
