import Foundation
import CryptoKit

/// Codex's own server (`codex app-server`), for what its files can't give:
/// its limits as they are now, not as of its last reply, and words into a
/// chat by the chat's id — no tab to find, nothing typed (owner, 27.10).
///
/// Codex 0.164 runs one server per user, which every `codex` in a terminal
/// is a client of. Only that one is used, through `codex app-server proxy`,
/// and only while it runs: the proxy just connects to its socket and starts
/// nothing (codex-rs/stdio-to-uds), and a server of our own would be a second
/// writer of a chat's file. What goes over it (docs/protocol.md):
///  - a WebSocket on the proxy's stdin and stdout, one JSON-RPC message per
///    text frame (Codex's own JSON-RPC, without "jsonrpc");
///  - initialize, account/rateLimits/read every few minutes,
///    thread/loaded/list, and turn/start — which reaches only a chat the
///    server has loaded (one it hasn't is "thread not found", never loaded
///    from disk) and, while Codex works there, joins the turn running;
///  - never thread/resume, thread/start or a fork: no chat is subscribed to,
///    so Codex sends its approvals to the chat's own window, not here;
///  - whatever the server asks is refused: no credentials, no approval.
/// Off the main queue; what the app reads is set on the main queue.
final class CodexServer {
    // MARK: What the app reads (main queue)

    /// Past the handshake, and the server answered initialize.
    private(set) var connected = false
    /// The chats (thread ids, lowercased) the server has loaded, as last asked.
    private(set) var loaded: Set<String> = []
    /// For Settings: "Connected", "Codex's server isn't running", …
    private(set) var state = "Not connected yet"
    /// Codex's own limits, as the server says them now.
    var onLimits: ((CodexRollout.Limits) -> Void)?
    /// Connected or not, its chats, or its state changed.
    var onChange: (() -> Void)?
    /// Chats whose turn/start Codex just refused (a subagent's, the server
    /// winding down): not tried again for a minute.
    private var refused: [String: Date] = [:]

    /// Words for this chat can go in now: the server is there, has it
    /// loaded, and didn't just refuse it. Checked again right before sending.
    func canSend(to thread: String) -> Bool {
        let id = thread.lowercased()
        return connected && loaded.contains(id) && Date().timeIntervalSince(refused[id] ?? .distantPast) > 60
    }

    // MARK: How it's reached

    /// The two ends of a connection: `proxy` runs Codex's own; the checks
    /// hand in pipes of theirs.
    struct Link {
        /// What the server says comes out here.
        let incoming: FileHandle
        /// What we say goes in here.
        let outgoing: FileHandle
        /// Ends it.
        let close: () -> Void
        /// What the other end said as it went (an older Codex without `proxy`).
        var complaint: () -> String = { "" }
    }

    enum Opening {
        case link(Link)
        /// Nothing to connect to now, and why — said in Settings, not logged.
        case none(String)
    }

    /// What a message for a chat came to.
    enum Sent: Equatable {
        case sent
        /// Surely not sent: back to the queue.
        case kept(String)
        /// No answer: it may have gone in. Not sent again, lest Codex get it twice.
        case unsure(String)
    }

    struct Failure: Error {
        let message: String
        /// The server answered with an error, so the request did nothing.
        /// Else (no answer in time, the line dropped) it may have.
        let answered: Bool
    }

    /// Codex asks its backend each time: at most every few minutes (owner, 27.10).
    static let limitsEvery: TimeInterval = 300

    private let open: () -> Opening
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 15, open: @escaping () -> Opening = { CodexServer.proxy() }) {
        self.timeout = timeout
        self.open = open
    }

    // MARK: The connection (on `queue`)

    private let queue = DispatchQueue(label: "cloudingbar.codexserver", qos: .utility)
    private enum Phase { case idle, upgrading, starting, ready }
    private var phase = Phase.idle
    private var link: Link?
    /// A connection's number: what an older one still delivers is dropped.
    private var generation = 0
    private var key = ""
    private var head: [UInt8] = []
    private var reader = WebSocket.Reader()
    private var nextId = 1
    private var waiting: [Int: (Result<Any, Failure>) -> Void] = [:]
    private var nextAttempt = Date.distantPast
    private var backoff: TimeInterval = 5
    private var lastLimits = Date.distantPast
    private var limitsTrouble: String?
    private var loadedNow: Set<String> = []

    /// Every few seconds from the app: connects when it's time, reads the
    /// limits when they're due, and which chats the server has.
    func poll(now: Date = Date()) {
        queue.async {
            switch self.phase {
            case .idle where now >= self.nextAttempt:
                self.connect(now: now)
            case .ready:
                if now.timeIntervalSince(self.lastLimits) >= Self.limitsEvery { self.readLimits(now: now) }
                self.readLoaded()
            default:
                break
            }
        }
    }

    /// Lets go of the server (the setting turned off). The next poll
    /// connects again.
    func stop() {
        queue.async {
            self.drop("Off", retryIn: 0, quiet: true)
        }
    }

    private func connect(now: Date) {
        let l: Link
        switch open() {
        case .none(let why):
            nextAttempt = now.addingTimeInterval(30)
            publish(state: why)
            return
        case .link(let opened):
            l = opened
        }
        generation += 1
        let g = generation
        link = l
        phase = .upgrading
        head = []
        reader = WebSocket.Reader()
        // A write after the other end went must fail, not kill the app.
        _ = fcntl(l.outgoing.fileDescriptor, F_SETNOSIGPIPE, 1)
        l.incoming.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { self?.received(data, generation: g) }
        }
        key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        put(WebSocket.upgrade(key: key))
        // The whole start, initialize answered, in time — else again later.
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.generation == g, self.phase != .ready else { return }
            self.drop("No answer from Codex's server")
        }
        publish(state: "Connecting…")
    }

    private func received(_ data: Data, generation g: Int) {
        guard g == generation, link != nil else { return }
        guard !data.isEmpty else {
            return drop(phase == .ready ? "Codex's server closed the connection" : "Codex's server isn't running")
        }
        var bytes = [UInt8](data)
        if phase == .upgrading {
            head += bytes
            guard let end = WebSocket.headEnd(head) else {
                if head.count > 16_384 { drop("Codex's server didn't answer as expected") }
                return
            }
            let answer = String(decoding: head[..<end], as: UTF8.self)
            bytes = Array(head[(end + 4)...])
            head = []
            guard WebSocket.upgraded(answer, key: key) else { return drop("Codex's server refused the connection") }
            phase = .starting
            initialize()
        }
        reader.feed(bytes)
        do {
            while g == generation, let frame = try reader.next() {
                switch frame.opcode {
                case 0x1:
                    if let msg = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any] { handle(msg) }
                case 0x8:
                    return drop("Codex's server closed the connection")
                case 0x9:
                    put(WebSocket.frame(frame.payload, opcode: 0xA))
                default:
                    break // a pong; binary isn't spoken without compression, never asked for
                }
            }
        } catch {
            drop("Garbled data from Codex's server")
        }
    }

    private func initialize() {
        let g = generation
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        call("initialize", ["clientInfo": ["name": "clouding-bar", "title": "Clouding Bar", "version": version]]) { [weak self] result in
            guard let self, self.generation == g else { return }
            guard case .success = result else { return self.drop("Codex's server didn't let us in") }
            self.post(["method": "initialized"])
            self.phase = .ready
            self.backoff = 5
            self.log("connected")
            self.publish(state: "Connected")
            self.readLimits(now: Date())
            self.readLoaded()
        }
    }

    /// One message from the server: a request it makes, a notification, or
    /// the answer to one of ours.
    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String
        if let method, let id = msg["id"] {
            // It asks us something. Nothing is ever approved or handed over here.
            post(["id": id, "error": Self.refusal(method)])
            log("refused its \(method)")
            return
        }
        if let method {
            notification(method, msg["params"] as? [String: Any] ?? [:])
            return
        }
        guard let id = (msg["id"] as? NSNumber)?.intValue, let done = waiting.removeValue(forKey: id) else { return }
        if let error = msg["error"] as? [String: Any] {
            done(.failure(Failure(message: error["message"] as? String ?? "refused", answered: true)))
        } else {
            done(.success(msg["result"] ?? NSNull()))
        }
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        switch method {
        case "account/rateLimits/updated":
            // Sent to a chat's own clients in 0.164; taken whenever it comes.
            if let snapshot = params["rateLimits"] as? [String: Any], let l = Self.limits(snapshot: snapshot) { deliver(l) }
        case "account/updated" where params["authMode"] as? String == "chatgptAuthTokens":
            // Another app hands Codex its sign-in and answers its refreshes,
            // which go to every client: our refusal could come first and
            // fail one. Not connected then.
            drop("Codex's sign-in comes from another app: not connected", retryIn: 30 * 60)
        case "thread/closed":
            if let id = params["threadId"] as? String {
                loadedNow.remove(id.lowercased())
                publish()
            }
        default:
            break
        }
    }

    private func readLimits(now: Date) {
        lastLimits = now
        let g = generation
        call("account/rateLimits/read", ["excludeResetCreditDetails": true], timeout: max(timeout, 30)) { [weak self] result in
            guard let self, self.generation == g else { return }
            switch result {
            case .success(let value):
                self.limitsTrouble = nil
                if let l = Self.limits(response: value as? [String: Any] ?? [:]) { self.deliver(l) }
            case .failure(let f):
                // An API key has no limits to read: said once, not every few minutes.
                if self.limitsTrouble != f.message { self.log("limits: \(f.message)") }
                self.limitsTrouble = f.message
            }
        }
    }

    /// Asks which chats the server has loaded; `then` gets them (nil: no answer).
    private func readLoaded(then: @escaping ((set: Set<String>, ids: [String])?) -> Void = { _ in }) {
        let g = generation
        call("thread/loaded/list", [:]) { [weak self] result in
            guard let self, self.generation == g,
                  case .success(let value) = result, let ids = (value as? [String: Any])?["data"] as? [String] else {
                return then(nil)
            }
            self.loadedNow = Set(ids.map { $0.lowercased() })
            self.publish()
            then((self.loadedNow, ids))
        }
    }

    // MARK: Sending

    /// The words into that chat, as yours: turn/start, by its id, and only
    /// once the server says right now that it has the chat loaded — it never
    /// loads one, so no second copy of a chat is ever made. While Codex works
    /// there they join the turn running (codex-rs start_or_steer_turn).
    func send(_ text: String, to thread: String, done: @escaping (Sent) -> Void) {
        let wanted = thread.lowercased()
        let finish = { (sent: Sent, refusedNow: Bool) in
            DispatchQueue.main.async {
                if refusedNow { self.refused[wanted] = Date() }
                done(sent)
            }
        }
        queue.async {
            guard self.phase == .ready else { return finish(.kept("Codex's server isn't connected"), false) }
            self.readLoaded { found in
                guard let found else { return finish(.kept("Codex's server didn't say which chats it has"), false) }
                // Its id as the server spells it.
                guard found.set.contains(wanted), let id = found.ids.first(where: { $0.lowercased() == wanted }) else {
                    return finish(.kept("Codex's server doesn't have this chat loaded"), false)
                }
                self.call("turn/start", ["threadId": id, "input": [["type": "text", "text": text]]]) { result in
                    switch result {
                    case .success: finish(.sent, false)
                    case .failure(let f) where f.answered: finish(.kept("Codex refused it: " + f.message), true)
                    case .failure(let f): finish(.unsure(f.message), false)
                    }
                }
            }
        }
    }

    // MARK: Plumbing

    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval? = nil,
                      _ done: @escaping (Result<Any, Failure>) -> Void) {
        let id = nextId
        nextId += 1
        waiting[id] = done
        post(["id": id, "method": method, "params": params])
        let g = generation
        queue.asyncAfter(deadline: .now() + (timeout ?? self.timeout)) { [weak self] in
            guard let self, self.generation == g, let done = self.waiting.removeValue(forKey: id) else { return }
            done(.failure(Failure(message: "No answer to \(method)", answered: false)))
        }
    }

    private func post(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        put(WebSocket.frame(data)) // masked, as a client's must be
    }

    private func put(_ data: Data) {
        guard let fd = link?.outgoing.fileDescriptor else { return }
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var done = 0
            while done < raw.count {
                let n = write(fd, base + done, raw.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                done += n
            }
            return true
        }
        if !ok {
            // Not from inside whatever is writing: on its own turn.
            let g = generation
            queue.async { if self.generation == g { self.drop("Codex's server went away") } }
        }
    }

    /// Ends the connection; anything waiting on it is told, and the next try
    /// is after `retryIn` (else a backoff, 5 s doubling to 5 min).
    private func drop(_ why: String, retryIn: TimeInterval? = nil, quiet: Bool = false) {
        let old = link
        generation += 1
        link = nil
        phase = .idle
        old?.incoming.readabilityHandler = nil
        old?.close()
        var why = why, retry = retryIn
        let complaint = old?.complaint() ?? ""
        if complaint.contains("unrecognized subcommand") || complaint.contains("unexpected argument") {
            // An older Codex, without `proxy`: as before, from its files.
            why = "This Codex has no server to connect to"
            retry = 6 * 3600
        }
        let pending = waiting
        waiting = [:]
        loadedNow = []
        head = []
        reader = WebSocket.Reader()
        nextAttempt = Date().addingTimeInterval(retry ?? backoff)
        if retry == nil { backoff = min(backoff * 2, 300) }
        for done in pending.values { done(.failure(Failure(message: why, answered: false))) }
        if old != nil && !quiet { log(why) }
        publish(state: why)
    }

    private func publish(state: String? = nil) {
        let isConnected = phase == .ready, ids = loadedNow
        DispatchQueue.main.async {
            let changed = self.connected != isConnected || self.loaded != ids || (state != nil && state != self.state)
            self.connected = isConnected
            self.loaded = ids
            if let state { self.state = state }
            if changed { self.onChange?() }
        }
    }

    private func deliver(_ limits: CodexRollout.Limits) {
        DispatchQueue.main.async { self.onLimits?(limits) }
    }

    private func log(_ text: String) {
        DispatchQueue.main.async { DebugLog.note("codex server: " + text) }
    }

    // MARK: What is said (pure, for the checks)

    /// Our answer to whatever the server asks: no. For an approval Codex
    /// reads an error as declined (codex-rs app-server: "approval request
    /// failed" → denied), and there is nothing here to sign in with.
    static func refusal(_ method: String) -> [String: Any] {
        let credentials = method.hasPrefix("account/") || method.hasPrefix("attestation/") || method.lowercased().contains("auth")
        return ["code": -32601,
                "message": credentials ? "Clouding Bar holds no credentials and hands none out"
                                       : "Clouding Bar approves nothing: answer in Codex"]
    }

    /// The account's own limits out of account/rateLimits/read: the "codex"
    /// bucket (others meter some models apart).
    static func limits(response r: [String: Any], at now: Date = Date()) -> CodexRollout.Limits? {
        if let snapshot = (r["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any] {
            return limits(snapshot: snapshot, at: now)
        }
        return (r["rateLimits"] as? [String: Any]).flatMap { limits(snapshot: $0, at: now) }
    }

    /// One snapshot, put in the files' words and read by the files' rules
    /// (CodexRollout.limits): windows by their length, only the account's
    /// bucket, reported now.
    static func limits(snapshot s: [String: Any], at now: Date = Date()) -> CodexRollout.Limits? {
        var rl: [String: Any] = [:]
        rl["limit_id"] = s["limitId"] as? String
        rl["plan_type"] = s["planType"] as? String
        for key in ["primary", "secondary"] {
            guard let w = s[key] as? [String: Any] else { continue }
            rl[key] = ["used_percent": w["usedPercent"] ?? NSNull(), "window_minutes": w["windowDurationMins"] ?? NSNull(),
                       "resets_at": w["resetsAt"] ?? NSNull()]
        }
        guard let read = CodexRollout.limits(from: rl, at: now), read.bucket == "codex" else { return nil }
        return read.limits
    }

    // MARK: Codex's own server, through its proxy

    /// `codex app-server proxy` to the server that runs — only when one does;
    /// else why not, and nothing is started.
    static func proxy(home: URL = CodexRollout.home) -> Opening {
        guard let codex = executable(home: home) else { return .none("Codex isn't installed") }
        guard let socket = daemonSocket(home: home) else { return .none("Codex's server isn't running") }
        let p = Process()
        p.executableURL = codex
        // Its socket by name: the one just checked, not one it works out itself.
        p.arguments = ["app-server", "proxy", "--sock", socket]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        do { try p.run() } catch { return .none("Codex couldn't be started") }
        return .link(Link(incoming: output.fileHandleForReading, outgoing: input.fileHandleForWriting, close: {
            try? input.fileHandleForWriting.close() // the proxy ends with its stdin
            if p.isRunning { p.terminate() }
        }, complaint: {
            for _ in 0..<10 where p.isRunning { usleep(50_000) }
            guard !p.isRunning else { return "" }
            return String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(4000), as: UTF8.self)
        }))
    }

    /// Codex itself, without a shell's PATH: the server's own copy first
    /// (the same version as the server), then the installers' places.
    static func executable(home: URL = CodexRollout.home) -> URL? {
        let user = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            home.appendingPathComponent("packages/app-server-daemon/current/bin/codex").path,
            home.appendingPathComponent("packages/standalone/current/bin/codex").path,
            home.appendingPathComponent("packages/standalone/current/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            user + "/.local/bin/codex",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    /// The running server's socket: where Codex keeps it
    /// (app-server-control/app-server-control.sock, a link into
    /// /tmp/codex-daemon-<uid>), a socket there, and — when the server has
    /// its pid file — that process alive. Nil when no server runs.
    static func daemonSocket(home: URL) -> String? {
        let path = home.appendingPathComponent("app-server-control/app-server-control.sock").path
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK else { return nil }
        for name in ["daemon.pid", "app-server.pid"] {
            guard let data = FileManager.default.contents(atPath: home.appendingPathComponent("app-server-daemon/" + name).path) else { continue }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = (json?["pid"] as? NSNumber)?.int32Value ?? Int32(text), pid > 1 else { return nil }
            return kill(pid, 0) == 0 || errno == EPERM ? path : nil
        }
        // A server started by hand has no pid file: its socket is enough.
        return path
    }
}

extension CodexServer {
    /// RFC 6455, the part a client needs: one upgrade, then frames.
    enum WebSocket {
        static func accept(key: String) -> String {
            Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        }

        /// The upgrade, always to "/": "/daemon/shutdown" on the same socket
        /// stops Codex's server.
        static func upgrade(key: String) -> Data {
            Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8)
        }

        /// Where the answer's head ends (its "\r\n\r\n"), once it's all in.
        static func headEnd(_ bytes: [UInt8]) -> Int? {
            guard bytes.count >= 4 else { return nil }
            for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
                return i
            }
            return nil
        }

        /// 101 Switching Protocols, with the accept that goes with our key.
        static func upgraded(_ head: String, key: String) -> Bool {
            let lines = head.components(separatedBy: "\r\n")
            guard let status = lines.first, status.hasPrefix("HTTP/1.1 101") else { return false }
            let want = accept(key: key)
            return lines.dropFirst().contains { line in
                let parts = line.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept"
                    && parts[1].trimmingCharacters(in: .whitespaces) == want
            }
        }

        /// One whole frame. A client's are masked; a server's (and the
        /// checks' stand-in's) aren't.
        static func frame(_ payload: Data, opcode: UInt8 = 0x1,
                          mask: [UInt8]? = (0..<4).map { _ in UInt8.random(in: 0...255) }) -> Data {
            var out: [UInt8] = [0x80 | opcode]
            let masked: UInt8 = mask == nil ? 0 : 0x80
            let n = payload.count
            if n < 126 {
                out.append(masked | UInt8(n))
            } else if n <= 0xFFFF {
                out += [masked | 126, UInt8(n >> 8), UInt8(n & 0xFF)]
            } else {
                out.append(masked | 127)
                out += (0..<8).reversed().map { UInt8((UInt64(n) >> (8 * UInt64($0))) & 0xFF) }
            }
            if let mask {
                out += mask
                out += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
            } else {
                out += payload
            }
            return Data(out)
        }

        struct Frame: Equatable {
            let opcode: UInt8
            let payload: Data
        }

        struct Garbled: Error {}

        /// Frames out of bytes that come in pieces: a frame once it's whole,
        /// a message in several frames once its last is in; a ping or a close
        /// between them as it comes.
        struct Reader {
            /// The server's own limit for one message.
            static let maxMessage = 16 << 20
            private var buffer: [UInt8] = []
            private var start = 0
            private var pieces: (opcode: UInt8, data: [UInt8])?

            mutating func feed(_ bytes: [UInt8]) { buffer += bytes }

            mutating func next() throws -> Frame? {
                while true {
                    let available = buffer.count - start
                    guard available >= 2 else { return nil }
                    let b0 = buffer[start], b1 = buffer[start + 1]
                    let fin = b0 & 0x80 != 0, opcode = b0 & 0x0F
                    var length = Int(b1 & 0x7F), at = start + 2
                    if length == 126 {
                        guard available >= 4 else { return nil }
                        length = Int(buffer[at]) << 8 | Int(buffer[at + 1])
                        at += 2
                    } else if length == 127 {
                        guard available >= 10 else { return nil }
                        var v: UInt64 = 0
                        for i in 0..<8 { v = v << 8 | UInt64(buffer[at + i]) }
                        guard v <= UInt64(Self.maxMessage) else { throw Garbled() }
                        length = Int(v)
                        at += 8
                    }
                    guard length <= Self.maxMessage else { throw Garbled() }
                    var mask: [UInt8]?
                    if b1 & 0x80 != 0 {
                        guard buffer.count >= at + 4 else { return nil }
                        mask = Array(buffer[at..<(at + 4)])
                        at += 4
                    }
                    guard buffer.count >= at + length else { return nil }
                    var payload = Array(buffer[at..<(at + length)])
                    if let mask { for i in payload.indices { payload[i] ^= mask[i % 4] } }
                    start = at + length
                    if start == buffer.count || start > 1 << 16 {
                        buffer.removeFirst(start)
                        start = 0
                    }
                    if opcode >= 0x8 { return Frame(opcode: opcode, payload: Data(payload)) } // never in pieces
                    if opcode == 0x0 {
                        guard var p = pieces else { throw Garbled() }
                        p.data += payload
                        guard p.data.count <= Self.maxMessage else { throw Garbled() }
                        if fin {
                            pieces = nil
                            return Frame(opcode: p.opcode, payload: Data(p.data))
                        }
                        pieces = p
                        continue
                    }
                    guard pieces == nil else { throw Garbled() }
                    if fin { return Frame(opcode: opcode, payload: Data(payload)) }
                    pieces = (opcode, payload)
                }
            }
        }
    }
}
