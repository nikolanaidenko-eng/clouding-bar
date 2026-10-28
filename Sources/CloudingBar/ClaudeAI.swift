import Foundation

/// Opt-in: your claude.ai account, read with the session key the sign-in
/// window takes (ClaudeAISignIn) — the live 5-hour and weekly limit for the
/// whole account, and Cowork tasks and chats as claude.ai lists them: what
/// each is called, whether it works or waits for you, a Cowork task's
/// context. The key gives full access to the account, so: kept only in
/// the Keychain, sent only to claude.ai, used only to read (GET, no
/// redirect followed). The addresses are unofficial and may stop working.
final class ClaudeAI {
    var onUpdate: ((_ percent: Double, _ resetsAt: Double?) -> Void)?
    /// The weekly (7-day) limit, when the plan has one.
    var onWeek: ((_ percent: Double, _ resetsAt: Double?) -> Void)?
    /// "On", "Signed out by claude.ai…", etc., for Settings.
    var onState: ((String) -> Void)?
    /// The account's latest chats, each time they're read.
    var onChats: (([ClaudeAIChats.Chat]) -> Void)?
    /// A Cowork task's context (by its chat's uuid).
    var onContext: ((String, ClaudeAIChats.Context) -> Void)?
    /// claude.ai turned the key down (401, 403): nothing more is asked.
    var onRejected: (() -> Void)?
    /// The chats too, not the limit alone: a key pasted before 1.2.8 was
    /// given for the limit, and reads the chats only once you say so.
    var readChats = true

    private var timer: Timer?
    private var orgId: String?
    private var nextOrg = Date.distantPast
    private var nextUsage = Date.distantPast
    private var nextChats = Date.distantPast
    private var chats: [ClaudeAIChats.Chat] = []
    /// When each Cowork task's events were read, and the reply's end they saw.
    private var contextRead: [String: (at: Date, settled: Date?)] = [:]
    /// Requests on their way, so a slow answer isn't asked for twice.
    private var asking: Set<String> = []
    /// One more at each stop: an answer to a request from before is dropped.
    private var generation = 0
    /// The newer list first; the older one if claude.ai doesn't know it.
    private var listPath = "chat_conversations_v2?limit=20&offset=0"
    /// claude.ai said "too many" (429): nothing asked until then, the wait
    /// doubling from a minute up to 15.
    private var pausedUntil = Date.distantPast
    private var pause: TimeInterval = 60
    /// What's been written to debug.log already, so it's said once.
    private var logged: Set<String> = []
    private static let service = "Clouding Bar · claude.ai session key"

    // MARK: Keychain

    /// The key goes through cloudingbar-key (inside the app), which stays
    /// the same build after build, so the Keychain's "Always Allow" sticks.
    /// Read once, then kept in memory.
    private static var cached: String?
    private static var helper: URL? { Bundle.main.url(forAuxiliaryExecutable: "cloudingbar-key") }

    static var hasKey: Bool { readKey() != nil }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        guard let out = runHelper("save", input: Data(key.utf8)), out.status == 0 else { return false }
        cached = key
        return true
    }

    static func deleteKey() {
        cached = nil
        _ = runHelper("delete")
    }

    private static func readKey() -> String? {
        if let cached { return cached }
        guard let out = runHelper("read"), out.status == 0,
              let key = String(data: out.data, encoding: .utf8), !key.isEmpty else { return nil }
        cached = key
        return key
    }

    /// Runs the helper; nil if it isn't there or won't start.
    private static func runHelper(_ command: String, input: Data? = nil) -> (status: Int32, data: Data)? {
        guard let helper else {
            DebugLog.note("claude.ai key: cloudingbar-key is missing from the app")
            return nil
        }
        let p = Process()
        p.executableURL = helper
        p.arguments = [command]
        let stdout = Pipe(), stdin = Pipe()
        p.standardOutput = stdout
        p.standardInput = stdin
        do { try p.run() } catch { return nil }
        if let input { stdin.fileHandleForWriting.write(input) }
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus >= 2 { DebugLog.note("claude.ai key: \(command) failed (\(p.terminationStatus))") }
        return (p.terminationStatus, data)
    }

    // MARK: Polling

    /// The limit every minute; the chats every 20 s while one works or
    /// waits for you (or did a moment ago), else every minute; a Cowork
    /// task's events while it works and once after each reply.
    func start() {
        stop()
        guard Self.hasKey else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        asking = []
        orgId = nil
        chats = []
        contextRead = [:]
        nextOrg = .distantPast
        nextUsage = .distantPast
        nextChats = .distantPast
    }

    private var busy: Bool {
        chats.contains { $0.running || $0.needsInput != nil || Date().timeIntervalSince($0.lastActive ?? .distantPast) < 120 }
    }

    private func tick() {
        guard let key = Self.readKey() else { stop(); return }
        guard Date() >= pausedUntil else { return }
        guard let org = orgId else {
            // Once — again only a minute after it didn't work.
            guard Date() >= nextOrg else { return }
            nextOrg = Date().addingTimeInterval(60)
            get("/api/organizations", key: key) { [weak self] status, json in
                guard let self, self.accepted(status, what: "organizations") else { return }
                // The first organization that can chat (a personal account has one).
                let orgs = json as? [[String: Any]] ?? []
                let chat = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") ?? false } ?? orgs.first
                guard let id = chat?["uuid"] as? String, ClaudeAIChats.isId(id) else {
                    self.onState?("No organization found for this account")
                    return
                }
                self.orgId = id
                self.tick()
            }
            return
        }
        let now = Date()
        if now >= nextUsage {
            nextUsage = now.addingTimeInterval(60)
            fetchUsage(org: org, key: key)
        }
        if readChats, now >= nextChats {
            nextChats = now.addingTimeInterval(busy ? 20 : 60)
            fetchChats(org: org, key: key)
        }
    }

    private func fetchUsage(org: String, key: String) {
        get("/api/organizations/\(org)/usage", key: key) { [weak self] status, json in
            guard let self, self.accepted(status, what: "usage") else { return }
            guard let window = (json as? [String: Any])?["five_hour"] as? [String: Any],
                  let utilization = (window["utilization"] as? NSNumber)?.doubleValue else {
                self.onState?("Unexpected answer from claude.ai")
                return
            }
            func resets(_ w: [String: Any]) -> Double? { ClaudeAIChats.date(w["resets_at"])?.timeIntervalSince1970 }
            self.onUpdate?(utilization, resets(window))
            if let week = (json as? [String: Any])?["seven_day"] as? [String: Any],
               let used = (week["utilization"] as? NSNumber)?.doubleValue {
                self.onWeek?(used, resets(week))
            }
            self.onState?("On")
        }
    }

    private func fetchChats(org: String, key: String) {
        let path = listPath
        get("/api/organizations/\(org)/\(path)", key: key) { [weak self] status, json in
            guard let self else { return }
            if status == 404, path.hasPrefix("chat_conversations_v2") {
                self.listPath = "chat_conversations?limit=20"
                self.note("chats: the newer list isn't there, the older one from now on")
                self.nextChats = .distantPast
                return
            }
            guard status == 200 else {
                self.note("chats: HTTP \(status)")
                return
            }
            let chats = ClaudeAIChats.chats(json)
            // Which fields claude.ai gives, once: names only, never values.
            let first = ClaudeAIChats.items(json).first
            self.note("chats: \(chats.count) read, fields \(first?.keys.sorted().joined(separator: ",") ?? "none")")
            self.chats = chats
            self.onChats?(chats)
            self.fetchContexts(org: org, key: key)
        }
    }

    /// A Cowork task's events: while it works (every 30 s), after a reply
    /// ended, or once if never read.
    private func fetchContexts(org: String, key: String) {
        let now = Date()
        let due = chats.filter { chat in
            guard chat.isCowork, now.timeIntervalSince(chat.lastActive ?? .distantPast) < ClaudeAIChats.recent else { return false }
            guard let read = contextRead[chat.uuid] else { return true }
            if chat.running { return now.timeIntervalSince(read.at) >= 30 }
            return chat.settledAt != read.settled
        }
        for chat in due.prefix(3) {
            guard let workspace = chat.workspace else { continue }
            contextRead[chat.uuid] = (now, chat.settledAt)
            // As claude.ai's own page asks (without the organization: 401), newest
            // first, without the kinds that carry no reply.
            let skip = ["stream_event", "tool_progress", "tool_use_summary", "keep_alive", "thinking_trace",
                        "transcript", "env_manager_log"].map { "&exclude_types=" + $0 }.joined()
            get("/v1/code/sessions/\(workspace)/events?limit=30&sort_order=desc" + skip, key: key,
                headers: ["anthropic-version": "2023-06-01", "anthropic-beta": "ccr-byoc-2025-07-29",
                          "anthropic-client-feature": "ccr", "x-organization-uuid": org]) { [weak self] status, json in
                guard let self else { return }
                guard status == 200 else {
                    self.note("cowork events: HTTP \(status)")
                    return
                }
                if let context = ClaudeAIChats.context(events: json) {
                    self.onContext?(chat.uuid, context)
                } else {
                    let first = ClaudeAIChats.items(json).first
                    self.note("cowork events: no reply with usage, fields \(first?.keys.sorted().joined(separator: ",") ?? "none")")
                }
            }
        }
    }

    /// The account's own answers (organizations, usage): a 401 or 403 is
    /// claude.ai saying the key is no good — not asked again.
    private func accepted(_ status: Int, what: String) -> Bool {
        switch status {
        case 200: return true
        case 0: onState?("Can't reach claude.ai")
        case 429: onState?("claude.ai asked to slow down: trying again in a while")
        case 401, 403:
            onState?("Signed out by claude.ai (HTTP \(status)). Sign in again.")
            stop()
            onRejected?()
        default: onState?("claude.ai answered HTTP \(status) (\(what))")
        }
        return false
    }

    private func note(_ line: String) {
        guard logged.insert(line).inserted else { return }
        if logged.count > 200 { logged = [line] }
        DebugLog.note("claude.ai " + line)
    }

    /// Never follows a redirect: the cookie would go along to wherever it
    /// points. A redirect comes back as it is, and counts as no answer.
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// A read-only GET to claude.ai with the session cookie. Calls back on
    /// the main queue with the HTTP status (0: no answer) and the JSON.
    private func get(_ path: String, key: String, headers: [String: String] = [:],
                     _ done: @escaping (Int, Any?) -> Void) {
        guard let u = URL(string: "https://claude.ai" + path), u.host == "claude.ai",
              asking.insert(path).inserted else { return }
        let generation = self.generation
        var request = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpShouldHandleCookies = false
        Self.session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                // Stopped meanwhile (signed out): the answer is dropped.
                guard let self, self.generation == generation, self.timer != nil else { return }
                self.asking.remove(path)
                let status = error == nil ? (response as? HTTPURLResponse)?.statusCode ?? 0 : 0
                if status == 429 {
                    self.pausedUntil = Date().addingTimeInterval(self.pause)
                    self.note("too many requests: quiet for \(Int(self.pause)) s")
                    self.pause = min(self.pause * 2, 15 * 60)
                } else if status == 200 {
                    self.pause = 60
                }
                done(status, status == 200 ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) } : nil)
            }
        }.resume()
    }
}
