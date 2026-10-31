import Foundation

/// Makes up short names for chats (owner, 27.10), once a chat, in the
/// background: Haiku through the person's own Claude Code (`claude -p`, no
/// hooks, no transcript left), from the chat's title and first message.
/// One call at a time; a made name is kept in `names/<id>.json` (so a
/// restart doesn't ask again, and the hook can hand it to Claude Code).
/// Used on the main thread.
final class ShortNamer {
    /// Named: the bar and the widget redraw.
    var changed: () -> Void = {}
    /// Config.shortNames.
    var enabled: () -> Bool = { true }
    /// The model's answer to an input; replaced in the tests.
    var ask: (String) -> String? = ShortNamer.askClaude
    /// Where the names are kept.
    var base: URL = Config.directory

    static let timeout: TimeInterval = 30
    /// A message alone (no title yet) waits this long for Claude Code's own title.
    static let titleWait: TimeInterval = 8
    private static let maxAttempts = 2
    private static let retryAfter: TimeInterval = 300
    private static let pauseAfter = 3
    private static let pause: TimeInterval = 1800

    /// Handled for this run: queued, asked, named, or short enough already.
    private var handled = Set<String>()
    private var attempts: [String: Int] = [:]
    private var retryAt: [String: Date] = [:]
    private var queue: [(id: String, input: String, claude: Bool)] = []
    private var running = false
    private var failures = 0
    private var pausedUntil = Date.distantPast

    /// Looks at the chats: the ones that want a name are queued.
    func consider(_ sessions: [Session], now: Date = Date()) {
        guard enabled() else { return }
        var later: TimeInterval?
        for s in sessions where !handled.contains(s.id) && s.shortName == nil {
            // Named by the person, or by Cowork's own first words: not ours.
            guard s.customTitle == nil, !s.fromList else { continue }
            // Codex's chats get no name: their words would go to Anthropic, a
            // recipient they never had (review, 27.10).
            guard s.entrypoint != "codex", !s.ambient else { continue }
            if let at = retryAt[s.id], now < at { later = min(later ?? .infinity, at.timeIntervalSince(now)); continue }
            let title = s.aiTitle ?? s.title ?? s.desktopTitle
            // A message alone is asked for after a moment: Claude Code's title
            // comes within seconds of the first reply and tells more.
            if title == nil {
                guard let at = s.firstPromptAt else { continue }
                if now.timeIntervalSince(at) < Self.titleWait {
                    later = min(later ?? .infinity, Self.titleWait - now.timeIntervalSince(at) + 0.5)
                    continue
                }
            }
            guard let input = ShortName.input(title: title, prompt: s.firstPrompt) else { continue }
            // Already short: nothing to make up.
            if let title, ShortName.accept(title) != nil { handled.insert(s.id); continue }
            handled.insert(s.id)
            let claude = s.transcriptPath != nil && !s.inDesktopApp
            queue.append((s.id, input, claude))
        }
        if let later { DispatchQueue.main.asyncAfter(deadline: .now() + later) { [weak self] in self?.recheck() } }
        next(now: now)
    }

    /// Set by whoever owns the chats: what to look at on a timer.
    var chats: () -> [Session] = { [] }
    private func recheck() { consider(chats()) }

    private func next(now: Date = Date()) {
        // Switched off while chats waited: the queue goes, nothing is asked (review, 27.10).
        guard enabled() else {
            for job in queue { handled.remove(job.id) }
            queue.removeAll()
            return
        }
        guard !running, now >= pausedUntil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = true
        let ask = self.ask
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let answer = ask(job.input)
            DispatchQueue.main.async { self?.finish(job, answer) }
        }
    }

    private func finish(_ job: (id: String, input: String, claude: Bool), _ answer: String?) {
        running = false
        defer { next() }
        guard let name = answer.flatMap(ShortName.accept) else {
            attempts[job.id, default: 0] += 1
            failures += 1
            if failures >= Self.pauseAfter {
                pausedUntil = Date().addingTimeInterval(Self.pause)
                failures = 0
                DebugLog.note("short names: \(Self.pauseAfter) failures in a row, paused for 30 min")
            }
            if attempts[job.id, default: 0] < Self.maxAttempts {
                handled.remove(job.id)
                retryAt[job.id] = Date().addingTimeInterval(Self.retryAfter)
            }
            DebugLog.note("short names: none for a chat (\(answer == nil ? "no answer" : "answer not used"))")
            return
        }
        failures = 0
        guard enabled() else { return }
        // The chat may have been named by the person while Haiku thought.
        let all = chats()
        let chat = all.first { $0.id == job.id }
        if let chat, chat.customTitle != nil { return }
        // A name another live chat has, or the folder's, tells nothing apart and
        // would make the window ambiguous: none, and the bar cuts the long title
        // with "…" (review, 27.10).
        var taken = Set<String>()
        for other in all where other.id != job.id {
            for t in [other.shortName, other.title, other.customTitle] { if let t { taken.insert(t.lowercased()) } }
        }
        if let folder = chat?.projectName { taken.insert(folder.lowercased()) }
        if taken.contains(name.lowercased()) {
            DebugLog.note("short names: the name is taken, none for this chat")
            return
        }
        SessionTitle.save(SessionTitle.Entry(name: name, claude: job.claude), for: job.id, base: base)
        chat?.shortName = name
        DebugLog.note("short names: made one")
        changed()
    }

    // MARK: Claude Code

    /// Where `claude` was found (the shell is asked once).
    private static var found: URL?
    private static let foundLock = NSLock()

    /// Claude Code itself, without a shell's PATH.
    static func executable() -> URL? {
        foundLock.lock(); defer { foundLock.unlock() }
        if let found, FileManager.default.isExecutableFile(atPath: found.path) { return found }
        found = locate()
        return found
    }

    private static func locate() -> URL? {
        let user = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [user + "/.local/bin/claude", user + "/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", user + "/.npm-global/bin/claude", user + "/.bun/bin/claude"]
        if let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) { return URL(fileURLWithPath: found) }
        // Else where the person's shell finds it.
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        sh.standardOutput = out
        sh.standardError = FileHandle.nullDevice
        guard (try? sh.run()) != nil else { return nil }
        // A login shell can hang on the person's profile: 5 s, then none (review, 27.10).
        let killer = DispatchWorkItem { if sh.isRunning { sh.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        defer { killer.cancel() }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        sh.waitUntilExit()
        guard let text, text.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: text) else { return nil }
        return URL(fileURLWithPath: text)
    }

    /// The arguments: no session kept, no tools, no hooks of the person's
    /// (project settings only, and the folder is empty), JSON out.
    static func arguments() -> [String] {
        ["-p", "--model", "haiku", "--no-session-persistence", "--tools", "", "--setting-sources", "project",
         "--output-format", "json", "--system-prompt", ShortName.instructions]
    }

    /// One call. Blocking: run off the main thread. Nil on any trouble.
    static func askClaude(_ input: String) -> String? {
        guard let exe = executable() else { return nil }
        // An empty folder of our own: no project settings to load, no CLAUDE.md.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloudingbar-names", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = exe
        p.arguments = arguments()
        p.currentDirectoryURL = dir
        // The hook ignores a call with this set, in case one is ever loaded.
        var env = ProcessInfo.processInfo.environment
        env["CLOUDINGBAR_NAMING"] = "1"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return result(from: data)
    }

    /// `.result` of `--output-format json`, unless it says it is an error.
    static func result(from data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["is_error"] as? Bool != true else { return nil }
        return obj["result"] as? String
    }
}
