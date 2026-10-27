import Foundation

/// Messages straight into Claude's input — for VS Code chats started through
/// the wrapper, where cloudingbar-tap --input listens beside the extension
/// (Sources/CloudingBarTap/Input.swift). No window is brought forward and no
/// key is typed: the widget's message, a dictated one or a screenshot reaches
/// the chat wherever you are, and Claude echoes it into the chat as yours.
enum Inject {
    /// The door is named by Claude's process id.
    static func socketPath(pid: Int32) -> String {
        Config.directory.appendingPathComponent("inject/\(pid).sock").path
    }

    /// This chat's Claude takes messages that way (a VS Code chat begun since
    /// the wrapper learned it; older ones, terminals and Claude Desktop don't).
    static func available(pid: Int32?) -> Bool {
        guard let pid, pid > 1, kill(pid, 0) == 0 || errno == EPERM else { return false }
        return FileManager.default.fileExists(atPath: socketPath(pid: pid))
    }

    /// Pictures go as pictures up to this size (the API's limit is 5 MB once
    /// encoded); bigger ones, and other files, by their path.
    static let maxImageBytes = 3_700_000

    /// The message as Claude Code's stream-json input takes it — the shape
    /// the extension itself sends: your words, then the pictures.
    static func message(_ text: String, files: [String] = []) -> Data? {
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var pictures: [[String: Any]] = []
        for path in files {
            if let picture = imageBlock(path) {
                pictures.append(picture)
            } else {
                words += (words.isEmpty ? "" : " ") + (path.contains(where: \.isWhitespace) ? "\"\(path)\"" : path)
            }
        }
        let content = (words.isEmpty ? [] : [["type": "text", "text": words]]) + pictures
        guard !content.isEmpty else { return nil }
        let message: [String: Any] = [
            "type": "user",
            "uuid": UUID().uuidString.lowercased(),
            "session_id": "",
            "parent_tool_use_id": NSNull(),
            "message": ["role": "user", "content": content],
        ]
        return try? JSONSerialization.data(withJSONObject: message)
    }

    private static func imageBlock(_ path: String) -> [String: Any]? {
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        guard let type = types[(path as NSString).pathExtension.lowercased()],
              let data = FileManager.default.contents(atPath: path), data.count <= maxImageBytes else { return nil }
        return ["type": "image", "source": ["type": "base64", "media_type": type, "data": data.base64EncodedString()]]
    }

    /// Hands it over; true once Claude's side said it took it. Blocking (a
    /// few milliseconds; at most a few seconds): call it off the main thread.
    static func send(_ data: Data, pid: Int32) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath(pid: pid).utf8)
        guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        var line = data
        line.append(UInt8(ascii: "\n"))
        let wrote: Bool = line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
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
        guard wrote else { return false }
        shutdown(fd, SHUT_WR)
        var reply = [UInt8](repeating: 0, count: 8)
        let n = read(fd, &reply, reply.count)
        return n >= 2 && reply[0] == UInt8(ascii: "o") && reply[1] == UInt8(ascii: "k")
    }
}

/// Where a message for a chat goes right now (the widget's box, a button,
/// your voice, Send now) — AppDelegate's queue, in one place for the checks.
enum Delivery: Equatable {
    /// Straight in: Claude's input (Inject), or Codex's own server (CodexServer).
    case now
    /// The queue: out one at a time as the chat gets free (owner, 27.10).
    case queue

    /// - direct: its chat takes messages straight in
    /// - free: the agent there has finished its reply and asks nothing
    /// - queuedBefore: a message of yours for it waits already
    /// - waits: it holds while the agent works. The widget's always do; a
    ///   button's or your voice's only for Codex, whose turn/start would join
    ///   the turn running, where Claude Code keeps it for after by itself.
    /// - sendNow: Send now, at once whatever it's doing
    static func route(direct: Bool, free: Bool, queuedBefore: Bool, waits: Bool, sendNow: Bool = false) -> Delivery {
        guard direct else { return .queue }
        if sendNow || !waits { return .now }
        return free && !queuedBefore ? .now : .queue
    }
}
