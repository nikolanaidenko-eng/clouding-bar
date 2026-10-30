import Foundation

/// Opt-in: your claude.ai account, read with the session key the sign-in
/// window takes (ClaudeAISignIn) — the live 5-hour and weekly limit for the
/// whole account, and Cowork tasks and chats as claude.ai lists them: what
/// each is called, whether it works or waits for you, a Cowork task's
/// context. The key gives full access to the account, so: kept only in
/// the Keychain, sent only to claude.ai, no redirect followed; it reads
/// (GET), and writes only what you send — your words to a Cowork task, a chat or a
/// desktop Code chat's Remote Control, your answer to what one asks
/// (owner, 29.10: not typed into a window that must be in front). The
/// addresses are unofficial and may stop working. Anthropic's terms don't
/// allow this (ClaudeAINotice): the app says so before the sign-in. Its chat
/// messages name the web client, and its sign-in window Safari: disclosed in
/// docs/privacy.md (owner, 30.10: kept, not submitted to the directory).
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
    /// A session's card (by its "cse_…"): a Cowork task waiting on you, a
    /// Remote Control one in `bridges`.
    var onRemote: ((String, ClaudeAIChats.Remote) -> Void)?
    /// The desktop Code chats' Remote Control sessions: whether each is on
    /// the line, read every 30 s.
    var bridges: Set<String> = []
    /// The chats too, not the limit alone: a key pasted before 1.2.8 was
    /// given for the limit, and reads the chats only once you say so.
    var readChats = true
    /// Cowork tasks the app already knows (chat uuid → "cse_…"): after a
    /// restart a task the list still shows as a plain chat stays one (review, 29.10).
    var known: (() -> [String: String])?

    private var timer: Timer?
    private var orgId: String?
    private var nextOrg = Date.distantPast
    private var nextUsage = Date.distantPast
    private var nextChats = Date.distantPast
    private var chats: [ClaudeAIChats.Chat] = []
    /// When each Cowork task's events were read, and the reply's end they saw.
    private var contextRead: [String: (at: Date, settled: Date?)] = [:]
    /// When each Remote Control card was read.
    private var cardRead: [String: Date] = [:]
    /// Cowork sessions found by their chat (ClaudeAIChats.session), and when
    /// each chat without one was last asked about.
    private var found: [String: String] = [:]
    private var lookedUp: [String: Date] = [:]
    /// What each Cowork task's card said last, and when words last went to
    /// it: read every 5 s while it works, waits or was just written to, else
    /// every 15 s (ClaudeAIChats.Pace).
    private var cardState: [String: (working: Bool, waiting: String?)] = [:]
    private var nudged: [String: Date] = [:]
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
    private typealias Pace = ClaudeAIChats.Pace

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

    /// The limit every minute; the chats every 5 s while one works or waits
    /// for you (or did a moment ago), else every 15 s; a Cowork task's card
    /// the same way; its events every 30 s while it works and once after
    /// each reply (ClaudeAIChats.Pace).
    func start() {
        stop()
        guard Self.hasKey else { return }
        timer = Timer.scheduledTimer(withTimeInterval: ClaudeAIChats.Pace.tick, repeats: true) { [weak self] _ in self?.tick() }
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
        cardRead = [:]
        found = [:]
        lookedUp = [:]
        cardState = [:]
        nudged = [:]
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
                // Which ones there are and which was taken: no names, no key.
                let list = orgs.map { o -> String in
                    let caps = (o["capabilities"] as? [String] ?? []).joined(separator: "+")
                    return "\((o["uuid"] as? String ?? "?").prefix(8)) [\(caps)] \(o["raven_type"] as? String ?? "-") \(o["billing_type"] as? String ?? "-")"
                }.joined(separator: ", ")
                self.note("organizations: \(list); taken \(id.prefix(8))")
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
            // A new chat, a question, a task done: on the bar within seconds
            // while one is going on (owner, 29.10: a minute was too long);
            // 15 s at rest.
            nextChats = now.addingTimeInterval(Pace.gap(Pace.chats(busy: busy)))
            fetchChats(org: org, key: key)
        }
        let due = readChats ? bridges.filter { now.timeIntervalSince(cardRead[$0] ?? .distantPast) >= 30 } : []
        if !due.isEmpty { fetchCards(Array(due.prefix(5)), org: org, key: key) }
        // Cowork tasks of the last half hour: their cards, whatever the list
        // says — at work, a question, done (owner, 30.10: "everything from
        // claude.ai"; a task started in Claude Desktop woke nothing).
        let tasks = readChats ? chats.filter { $0.isCowork && !$0.archived && now.timeIntervalSince($0.lastActive ?? .distantPast) < ClaudeAIChats.recent } : []
        // At work by the list or its card, waiting, or just written to: first.
        let hot = { (chat: ClaudeAIChats.Chat) -> Bool in
            guard let ws = chat.workspace else { return false }
            return chat.running || chat.needsInput != nil || self.cardState[ws].map { $0.working || $0.waiting != nil } == true
                || now.timeIntervalSince(self.nudged[ws] ?? .distantPast) < 120
        }
        let cards = (tasks.filter(hot) + tasks.filter { !hot($0) }).compactMap { chat -> String? in
            guard let ws = chat.workspace,
                  Pace.due(last: self.cardRead[ws] ?? .distantPast, every: Pace.card(hot: hot(chat)), now: now) else { return nil }
            return ws
        }
        if !cards.isEmpty { fetchCards(Array(cards.prefix(3)), org: org, key: key) }
    }

    /// Signed in, the account known, and the key given for the chats too:
    /// words and answers can go.
    var canSend: Bool { ClaudeAIChats.writes(signedIn: timer != nil && orgId != nil, readChats: readChats) }

    /// The list again in a few seconds (something was just sent).
    func lookSoon() {
        nextChats = min(nextChats, Date().addingTimeInterval(3))
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
            self.found.merge(self.known?() ?? [:]) { mine, _ in mine }
            let chats = ClaudeAIChats.merged(ClaudeAIChats.chats(json), previous: self.chats, found: self.found)
            // Which fields claude.ai gives, once: names only, never values.
            let first = ClaudeAIChats.items(json).first
            self.note("chats: \(chats.count) read, fields \(first?.keys.sorted().joined(separator: ",") ?? "none")")
            self.note("chats: \(chats.filter(\.isCowork).count) of \(chats.count) are Cowork tasks in \(org.prefix(8))")
            self.chats = chats
            self.onChats?(ClaudeAIChats.withCards(chats, self.cardState))
            self.lookUpSessions(org: org, key: key)
            self.fetchContexts(org: org, key: key)
            // What a Cowork task waiting on you asks: only its card has it.
            // Not twice at once (its context's read takes it too), but a
            // question within seconds (review, 29.10).
            let waiting = chats.filter { $0.needsInput != nil && !$0.archived }.compactMap(\.workspace)
                .filter { Pace.due(last: self.cardRead[$0] ?? .distantPast, every: Pace.active) }
            if !waiting.isEmpty { self.fetchCards(Array(waiting.prefix(5)), org: org, key: key) }
        }
    }

    /// Sessions' cards: whether each is on the line, what it waits on you for.
    /// A Remote Control one that can't be read counts as off the line.
    private func fetchCards(_ ids: [String], org: String, key: String) {
        let now = Date()
        for id in ids where ClaudeAIChats.isId(id) {
            cardRead[id] = now
            get("/v1/code/sessions/\(id)", key: key, headers: ccr(org)) { [weak self] status, json in
                guard let self else { return }
                if status == 200, let card = ClaudeAIChats.remote(session: json) {
                    self.onRemote?(id, card)
                    let state = (working: card.working, waiting: card.pending.map { $0.tool == "AskUserQuestion" ? "question" : "permission" })
                    if self.chats.contains(where: { $0.workspace == id }),
                       self.cardState[id]?.working != state.working || self.cardState[id]?.waiting != state.waiting {
                        self.cardState[id] = state
                        self.onChats?(ClaudeAIChats.withCards(self.chats, self.cardState))
                    }
                    return
                }
                // Read but not a card: which fields came, names only, never values.
                let fields = status == 200 ? ", fields " + ((json as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "none") : ""
                self.note("session card: HTTP \(status)\(fields)")
                if self.bridges.contains(id) { self.onRemote?(id, ClaudeAIChats.Remote(bridge: true, connected: false)) }
            }
        }
    }

    /// A chat active now without a Cowork session in the list: asked of
    /// claude.ai's sessions by its tag — a task Claude Desktop just started
    /// comes in the list as a plain chat for minutes, and its words then
    /// waited for its window (owner, 29.10). A plain chat has none: asked
    /// again a minute later (5 once quiet), at most three at a time.
    private func lookUpSessions(org: String, key: String) {
        let now = Date()
        let due = chats.filter { chat in
            let idle = now.timeIntervalSince(chat.lastActive ?? .distantPast)
            let active = chat.running || chat.needsInput != nil || idle < 120
            // One quiet a while is shown too (half an hour): asked every 5 minutes (review, 29.10).
            return chat.workspace == nil && !chat.archived && (active || idle < ClaudeAIChats.recent)
                && now.timeIntervalSince(lookedUp[chat.uuid] ?? .distantPast) >= (active ? 60 : 300)
        }
        for chat in due.prefix(3) {
            lookedUp[chat.uuid] = now
            let tag = "bard-conversation:" + chat.uuid
            get("/v1/code/sessions?limit=1&tags=" + tag, key: key, headers: ccr(org)) { [weak self] status, json in
                guard let self else { return }
                guard status == 200, let cse = ClaudeAIChats.session(found: json, chat: chat.uuid) else {
                    self.note("cowork: asked by its chat \(chat.uuid.prefix(8)): HTTP \(status), no task")
                    return
                }
                self.found[chat.uuid] = cse
                self.note("cowork: a task found by its chat")
                self.chats = ClaudeAIChats.merged(self.chats, previous: [], found: self.found)
                self.onChats?(ClaudeAIChats.withCards(self.chats, self.cardState))
                self.fetchContexts(org: org, key: key)
                let waiting = self.chats.filter { $0.needsInput != nil && $0.uuid == chat.uuid }.compactMap(\.workspace)
                if !waiting.isEmpty { self.fetchCards(waiting, org: org, key: key) }
            }
        }
    }

    private func ccr(_ org: String) -> [String: String] {
        ["anthropic-version": "2023-06-01", "anthropic-beta": "ccr-byoc-2025-07-29",
         "anthropic-client-feature": "ccr", "x-organization-uuid": org]
    }

    // MARK: What you send

    enum Sent: Equatable {
        case sent
        /// claude.ai said no: not taken, safe to keep and send another way.
        case kept(String)
        /// No answer, or claude.ai's own fault: it may have gone in — not sent again.
        case unsure(String)
        /// No connection at all: it surely didn't go, and may later.
        case offline
    }

    /// Your words into a Cowork task or a Remote Control session, as Claude
    /// Code sends them; Claude there echoes them into its chat as yours.
    func send(_ content: [[String: Any]], to session: String, done: @escaping (Sent) -> Void) {
        nudged[session] = Date()
        post("/v1/code/sessions/\(session)/events", body: ClaudeAIChats.message(content, session: session), done: done)
    }

    /// This run's mutations, as claude.ai's page numbers its own.
    private let mutationSession = "sess_" + (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    private var mutationSeq = 0

    /// Your words into the chat itself, as its page sends them: shown there,
    /// passed on to its Cowork task by claude.ai (signed, as typed).
    func sendToChat(_ text: String, chat uuid: String, done: @escaping (Sent) -> Void) {
        guard Self.readKey() != nil, orgId != nil, canSend else {
            done(.kept("not signed in to claude.ai"))
            return
        }
        mutationSeq += 1
        if let ws = chats.first(where: { $0.uuid == uuid })?.workspace { nudged[ws] = Date() }
        let body = ClaudeAIChats.chatMessage(text, chat: uuid, mutation: (mutationSession, mutationSeq))
        postProto("/claudeai-rpc/anthropic.bard.api.v1alpha.ConversationService/PerformAction", body: body, chat: uuid, done: done)
    }

    /// Your answer to what it waits on (its card's request id).
    func answer(_ decision: [String: Any], request: String, in session: String, done: @escaping (Sent) -> Void) {
        post("/v1/code/sessions/\(session)/events", body: ClaudeAIChats.answer(decision, request: request), done: done)
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
            // Its card too: the context of its real window, and its cost.
            if now.timeIntervalSince(cardRead[workspace] ?? .distantPast) >= 10 { fetchCards([workspace], org: org, key: key) }
            // As claude.ai's own page asks (without the organization: 401), newest
            // first, without the kinds that carry no reply.
            let skip = ["stream_event", "tool_progress", "tool_use_summary", "keep_alive", "thinking_trace",
                        "transcript", "env_manager_log"].map { "&exclude_types=" + $0 }.joined()
            get("/v1/code/sessions/\(workspace)/events?limit=30&sort_order=desc" + skip, key: key,
                headers: ccr(org)) { [weak self] status, json in
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

    /// A GET to claude.ai with the session cookie. Calls back on
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

    /// Calls back on the main queue: taken, refused (with claude.ai's
    /// reason), or no telling.
    /// Nothing reached claude.ai: no network, no such host, no connection made.
    private static func neverLeft(_ error: Error?) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(code)
    }

    /// A POST of protobuf to claude.ai's RPC, as its page makes it. Turned down
    /// (4xx), the words are `.kept` and go the older way (the task's session, or keys).
    private func postProto(_ path: String, body: Data, chat: String, done: @escaping (Sent) -> Void) {
        guard let key = Self.readKey(), let org = orgId, canSend else {
            done(.kept("not signed in to claude.ai"))
            return
        }
        guard let u = URL(string: "https://claude.ai" + path), u.host == "claude.ai", ClaudeAIChats.isId(chat) else {
            done(.kept("nothing to send"))
            return
        }
        var request = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue(org, forHTTPHeaderField: "x-organization-uuid")
        request.setValue(chat, forHTTPHeaderField: "anthropic-chat-conversation-uuid")
        request.httpShouldHandleCookies = false
        Self.session.dataTask(with: request) { data, response, error in
            let status = error == nil ? (response as? HTTPURLResponse)?.statusCode ?? 0 : 0
            // Connect's error: {"code", "message"}.
            let reason = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["message"] as? String }
                .map { " — " + String($0.prefix(200)) } ?? ""
            DispatchQueue.main.async {
                switch status {
                case 200..<300: done(.sent)
                case 0: done(Self.neverLeft(error) ? .offline : .unsure("no answer from claude.ai"))
                case 500...: done(.unsure("claude.ai answered HTTP \(status)" + reason))
                default: done(.kept("HTTP \(status)" + reason))
                }
            }
        }.resume()
    }

    /// A POST to claude.ai with the session cookie — only what you send.
    private func post(_ path: String, body: [String: Any], done: @escaping (Sent) -> Void) {
        guard let key = Self.readKey(), let org = orgId, canSend else {
            done(.kept("not signed in to claude.ai"))
            return
        }
        guard let u = URL(string: "https://claude.ai" + path), u.host == "claude.ai",
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            done(.kept("nothing to send"))
            return
        }
        var request = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in ccr(org) { request.setValue(value, forHTTPHeaderField: name) }
        request.httpShouldHandleCookies = false
        Self.session.dataTask(with: request) { data, response, error in
            let status = error == nil ? (response as? HTTPURLResponse)?.statusCode ?? 0 : 0
            // claude.ai's reason, when it gives one: the error's message alone.
            let reason = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                .map { " — " + String($0.prefix(200)) } ?? ""
            DispatchQueue.main.async {
                switch status {
                case 200..<300: done(.sent)
                case 0: done(Self.neverLeft(error) ? .offline : .unsure("no answer from claude.ai"))
                case 500...: done(.unsure("claude.ai answered HTTP \(status)" + reason))
                default: done(.kept("HTTP \(status)" + reason))
                }
            }
        }.resume()
    }
}
