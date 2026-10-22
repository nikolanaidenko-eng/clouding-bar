import Foundation

// cloudingbar-tap --input — sits on Claude Code's stdin when the VS Code
// extension starts Claude through hooks/cloudingbar-wrapper.sh.
//
// It copies the extension's lines through as they come, whole lines at a
// time, and between them lets in messages from Clouding Bar — the widget's
// message box, a dictated message, a screenshot — so they reach Claude
// without its window being brought forward or a key being typed. They come
// over ~/.cloudingbar/inject/<pid>.sock, <pid> being Claude's: this
// process's parent, the wrapper that became Claude. Claude echoes them back
// (the extension runs it with --replay-user-messages), so the chat shows
// them as yours.

/// Never returns: runs until the extension closes Claude's input.
func runInputRelay() -> Never {
    let base = ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudingbar")
    let dir = base.appendingPathComponent("inject")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let path = dir.appendingPathComponent("\(getppid()).sock").path
    let lock = NSLock()

    /// A whole line out, never interleaved with another.
    func emit(_ bytes: UnsafeRawBufferPointer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let p = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
        return writeAll(p, bytes.count)
    }

    // The door for Clouding Bar's messages. If it can't be opened, the
    // extension's lines still go through untouched.
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var listening = false
    if listener >= 0 {
        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        if bytes.count < MemoryLayout.size(ofValue: addr.sun_path) {
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if bound == 0 {
                chmod(path, 0o600)
                listening = listen(listener, 4) == 0
            }
        }
    }
    if listening {
        Thread.detachNewThread {
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 {
                    if errno == EINTR { continue }
                    return
                }
                var nosigpipe: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                // One message per connection, up to the sender's end.
                var data = [UInt8]()
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while data.count < 48 * 1024 * 1024 {
                    let n = read(c, &chunk, chunk.count)
                    if n > 0 { data.append(contentsOf: chunk[0..<n]) } else if n < 0 && errno == EINTR { continue } else { break }
                }
                while data.last == UInt8(ascii: "\n") || data.last == UInt8(ascii: "\r") { data.removeLast() }
                // Only a user message, on one line, as the extension sends them.
                let ok: Bool
                if !data.isEmpty, !data.contains(UInt8(ascii: "\n")),
                   let obj = (try? JSONSerialization.jsonObject(with: Data(data))) as? [String: Any],
                   obj["type"] as? String == "user", obj["message"] is [String: Any] {
                    data.append(UInt8(ascii: "\n"))
                    ok = data.withUnsafeBytes { emit($0) }
                } else {
                    ok = false
                }
                let reply = Array((ok ? "ok\n" : "no\n").utf8)
                _ = reply.withUnsafeBytes { write(c, $0.baseAddress, reply.count) }
                close(c)
            }
        }
    }

    // The extension's lines: through as soon as each is whole.
    let size = 64 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    var pending = [UInt8]()
    var open = true
    while open {
        let n = read(0, buffer, size)
        if n < 0 {
            if errno == EINTR { continue }
            break
        }
        if n == 0 { break }
        pending.append(contentsOf: UnsafeBufferPointer(start: buffer, count: n))
        if let last = pending.lastIndex(of: UInt8(ascii: "\n")) {
            open = pending[...last].withUnsafeBytes { emit($0) }
            pending.removeSubrange(...last)
        }
    }
    if !pending.isEmpty { _ = pending.withUnsafeBytes { emit($0) } }
    if listening { unlink(path) }
    close(1) // Claude sees the end of its input
    exit(0)
}
